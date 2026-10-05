#import "CSAudioEngine.h"
#import <AppKit/AppKit.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>

// The largest region handed to the file player at once, in frames.
//
// A region is one file played N times over (mLoopCount = N - 1). The header
// documents mLoopCount only as "0 = don't loop" -- there is no documented value
// for "forever" -- and the region's total length is the file's length times
// that count. Rather than bet on how the player does that multiplication, each
// region is kept to 2^30 frames, a little over six hours at 44.1 kHz, which
// fits comfortably in any integer type it might use. Regions are queued back to
// back, sample-accurately, and topped up as they play; see -topUpSchedule.
#define CS_DEFAULT_MAX_REGION_FRAMES   (1LL << 30)

// Frames per device I/O cycle requested of the output. See the header.
#define CS_DEVICE_BUFFER_FRAMES        4096

// The player is pulled by the output in slices of up to the device buffer size.
// Its default ceiling is smaller than that, and exceeding it is a render error
// that plays as silence, so it is raised before the unit is initialised.
#define CS_MAX_FRAMES_PER_SLICE        8192

static SInt64 sMaxRegionFrames = 0;

// Test seam: the output refuses to start. See +setOutputStartFailsForTesting:.
static BOOL sOutputStartFailsForTesting = NO;

NSString *const CSAudioEngineDidPauseForSleepNotification =
    @"CSAudioEngineDidPauseForSleepNotification";

// The engine's own clock: frames the player has produced since its queue was
// last built, counted on the audio thread as each slice is rendered.
//
// The player can report this itself (kAudioUnitProperty_CurrentPlayTime), and
// the first version asked it. But the counter, the reel packs, pausing and the
// schedule top-up all hang off this one number, and how that property behaves
// -- whether it sets its valid flag, what it counts from -- could only be
// observed on this machine, not on the 10.9 one that matters. If it misreports
// there, the counter freezes, a pause resumes from the top and the queue is
// never topped up. Counting rendered frames depends on nothing but the render
// callback every audio unit has had since 10.0. It also has no lag: it is the
// end of the last slice, where the property gave its start.
//
// One 64-bit counter, written with an atomic add from the audio thread and read
// with an atomic load from the main thread; nothing is locked and nothing is
// allocated in the render path.
typedef struct { volatile int64_t frames; } CSRenderCount;

static OSStatus CSCountRenderedFrames(void *refCon, AudioUnitRenderActionFlags *flags,
                                      const AudioTimeStamp *time, UInt32 bus,
                                      UInt32 frames, AudioBufferList *data)
{
    (void)time; (void)bus; (void)data;
    if ((*flags & kAudioUnitRenderAction_PostRender) &&
        !(*flags & kAudioUnitRenderAction_PostRenderError))
        __sync_fetch_and_add(&((CSRenderCount *)refCon)->frames, (int64_t)frames);
    return noErr;
}

static NSError *CSAudioError(OSStatus status, NSString *message, NSString *detail)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    [info setObject:message forKey:NSLocalizedDescriptionKey];
    if (detail) [info setObject:detail forKey:NSLocalizedRecoverySuggestionErrorKey];
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:info];
}

@implementation CSAudioEngine
{
    AudioUnit    _output;          // NULL when rendering offline
    AudioUnit    _player;
    AudioFileID  _file;
    NSURL       *_url;
    NSString    *_title;
    NSString    *_artist;
    double       _sampleRate;
    SInt64       _passFrames;
    UInt32       _passesPerRegion;
    Float64      _baseFrames;      // tape position when the current queue was built
    Float64      _scheduledEnd;    // player-timeline frame where the queue runs out
    Float64      _offlineTime;
    BOOL         _offline;
    BOOL         _playing;
    BOOL         _needsSchedule;   // paused: the queue must be rebuilt from _baseFrames
    float        _volume;
    NSTimer     *_topUpTimer;
    CSRenderCount *_rendered;
}

@synthesize URL = _url, title = _title, artist = _artist, isPlaying = _playing;

+ (void)setMaximumRegionFramesForTesting:(SInt64)frames
{
    sMaxRegionFrames = frames > 0 ? frames : 0;
}

+ (void)setOutputStartFailsForTesting:(BOOL)fails
{
    sOutputStartFailsForTesting = fails;
}

#pragma mark - What the system can read

+ (NSArray *)readableTypes
{
    CFArrayRef utis = NULL;
    UInt32 size = sizeof(utis);
    OSStatus st = AudioFileGetGlobalInfo(kAudioFileGlobalInfo_AllUTIs, 0, NULL, &size, &utis);
    if (st != noErr || !utis) return [NSArray arrayWithObject:@"public.audio"];
    return [(NSArray *)utis autorelease];
}

+ (BOOL)canProbablyReadURL:(NSURL *)url
{
    if (![url isFileURL]) return NO;
    static NSSet *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFArrayRef list = NULL;
        UInt32 size = sizeof(list);
        NSMutableSet *set = [NSMutableSet set];
        if (AudioFileGetGlobalInfo(kAudioFileGlobalInfo_AllExtensions, 0, NULL,
                                   &size, &list) == noErr && list) {
            for (NSString *e in (NSArray *)list) [set addObject:[e lowercaseString]];
            CFRelease(list);
        }
        if ([set count] == 0)
            [set addObjectsFromArray:[NSArray arrayWithObjects:@"aif", @"aiff", @"aifc",
                                      @"wav", @"mp3", @"m4a", @"aac", @"caf", nil]];
        extensions = [set copy];
    });
    return [extensions containsObject:[[url pathExtension] lowercaseString]];
}

#pragma mark - Lifecycle

- (id)initOffline:(BOOL)offline
{
    self = [super init];
    if (self) {
        _offline = offline;
        _volume = 1.0f;
        if (!offline) {
            NSNotificationCenter *ws = [[NSWorkspace sharedWorkspace] notificationCenter];
            [ws addObserver:self selector:@selector(systemWillSleep:)
                       name:NSWorkspaceWillSleepNotification object:nil];
        }
    }
    return self;
}

- (id)init { return [self initOffline:NO]; }
- (id)initForOfflineRendering { return [self initOffline:YES]; }

- (void)dealloc
{
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self eject];
    if (_output) {
        AudioOutputUnitStop(_output);
        AudioUnitUninitialize(_output);
        AudioComponentInstanceDispose(_output);
    }
    if (_player) {
        AudioUnitRemoveRenderNotify(_player, CSCountRenderedFrames, _rendered);
        AudioUnitUninitialize(_player);
        AudioComponentInstanceDispose(_player);
    }
    free(_rendered);
    [super dealloc];
}

- (BOOL)hasTape { return _file != NULL; }
- (double)duration { return (_file && _sampleRate > 0) ? (double)_passFrames / _sampleRate : 0; }
- (UInt32)passesPerRegion { return _passesPerRegion; }
- (SInt64)framesPerPass { return _passFrames; }
- (double)sampleRate { return _sampleRate; }

#pragma mark - The units

static OSStatus CSNewUnit(OSType type, OSType subtype, AudioUnit *out)
{
    AudioComponentDescription d;
    memset(&d, 0, sizeof(d));
    d.componentType         = type;
    d.componentSubType      = subtype;
    d.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent c = AudioComponentFindNext(NULL, &d);
    if (!c) return kAudioUnitErr_InvalidElement;
    return AudioComponentInstanceNew(c, out);
}

- (OSStatus)createUnits
{
    if (_player) return noErr;
    OSStatus st = CSNewUnit(kAudioUnitType_Generator, kAudioUnitSubType_AudioFilePlayer, &_player);
    if (st != noErr) { _player = NULL; return st; }

    UInt32 maxFrames = CS_MAX_FRAMES_PER_SLICE;
    AudioUnitSetProperty(_player, kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));

    if (!_rendered) _rendered = (CSRenderCount *)calloc(1, sizeof(CSRenderCount));
    st = _rendered ? AudioUnitAddRenderNotify(_player, CSCountRenderedFrames, _rendered)
                   : (OSStatus)kAudioUnitErr_FailedInitialization;
    if (st != noErr) {
        AudioComponentInstanceDispose(_player);
        _player = NULL;
        return st;
    }
    if (_offline) return noErr;

    st = CSNewUnit(kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, &_output);
    if (st != noErr) {
        _output = NULL;
        AudioUnitRemoveRenderNotify(_player, CSCountRenderedFrames, _rendered);
        AudioComponentInstanceDispose(_player);
        _player = NULL;
    }
    return st;
}

// Sets both ends of the connection to the file's own sample rate, so the only
// rate conversion anywhere is the one the output does to reach the hardware.
// Formats can only change while a unit is uninitialised, so this tears both
// down and brings them back.
- (OSStatus)configureForSampleRate:(double)rate
{
    if (_output) {
        AudioOutputUnitStop(_output);
        AudioUnitUninitialize(_output);
    }
    AudioUnitUninitialize(_player);

    // Two channels whatever the file has: the player's converter spreads a mono
    // file across both, where a one-channel stream would play in the left ear.
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate       = rate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    f.mBitsPerChannel   = 32;
    f.mChannelsPerFrame = 2;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = 4;
    f.mBytesPerPacket   = 4;

    OSStatus st = AudioUnitSetProperty(_player, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 0, &f, sizeof(f));
    if (st != noErr) return st;

    if (_output) {
        st = AudioUnitSetProperty(_output, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 0, &f, sizeof(f));
        if (st != noErr) return st;
        AudioUnitConnection link = { _player, 0, 0 };
        st = AudioUnitSetProperty(_output, kAudioUnitProperty_MakeConnection,
                                  kAudioUnitScope_Input, 0, &link, sizeof(link));
        if (st != noErr) return st;
    }

    st = AudioUnitInitialize(_player);
    if (st != noErr) return st;
    if (_output) {
        st = AudioUnitInitialize(_output);
        if (st != noErr) return st;
        [self requestLargeDeviceBuffer];
        [self applyVolume];
    }
    return noErr;
}

// Best effort. A device that will not take 4096 frames is tried at half that,
// and one that refuses both keeps whatever it had; playback is correct either
// way, it just wakes more often.
- (void)requestLargeDeviceBuffer
{
    UInt32 frames;
    for (frames = CS_DEVICE_BUFFER_FRAMES; frames >= 1024; frames /= 2) {
        if (AudioUnitSetProperty(_output, kAudioDevicePropertyBufferFrameSize,
                                 kAudioUnitScope_Global, 0, &frames, sizeof(frames)) == noErr)
            return;
    }
}

#pragma mark - Loading

// The number of frames of sound in the file, not counting the encoder's
// priming and padding. ExtAudioFile reads the packet table to work that out,
// which is what makes an AAC loop meet itself without a gap.
static SInt64 CSFrameCount(NSURL *url, AudioFileID file, const AudioStreamBasicDescription *fmt)
{
    SInt64 frames = 0;
    ExtAudioFileRef ext = NULL;
    if (ExtAudioFileOpenURL((CFURLRef)url, &ext) == noErr && ext) {
        UInt32 size = sizeof(frames);
        if (ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames,
                                    &size, &frames) != noErr)
            frames = 0;
        ExtAudioFileDispose(ext);
    }
    if (frames > 0) return frames;

    AudioFilePacketTableInfo table;
    UInt32 size = sizeof(table);
    if (AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr &&
        table.mNumberValidFrames > 0)
        return table.mNumberValidFrames;

    UInt64 packets = 0;
    size = sizeof(packets);
    if (AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &packets) == noErr &&
        fmt->mFramesPerPacket > 0)
        return (SInt64)(packets * fmt->mFramesPerPacket);
    return 0;
}

static NSString *CSInfoString(NSDictionary *info, const char *key)
{
    id v = [info objectForKey:[NSString stringWithUTF8String:key]];
    if (![v isKindOfClass:[NSString class]]) return nil;
    NSString *s = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [s length] ? s : nil;
}

- (BOOL)loadURL:(NSURL *)url error:(NSError **)outError
{
    NSString *name = [[NSFileManager defaultManager] displayNameAtPath:[url path]];
    NSString *formats = @"Cassette plays what OS X can decode: AIFF, WAV, MP3, AAC and "
                        @"Apple Lossless (.m4a), Core Audio (.caf) and a few others.";

    // Everything about the new file is checked before the current tape is
    // touched, so a bad choice leaves the deck exactly as it was.
    AudioFileID file = NULL;
    OSStatus st = ([url isFileURL]
        ? AudioFileOpenURL((CFURLRef)url, kAudioFileReadPermission, 0, &file)
        : (OSStatus)kAudioFileUnspecifiedError);
    if (st != noErr || !file) {
        if (outError) *outError = CSAudioError(st, [NSString stringWithFormat:
            @"“%@” isn’t an audio file this Mac can play.", name], formats);
        return NO;
    }

    AudioStreamBasicDescription fmt;
    UInt32 size = sizeof(fmt);
    memset(&fmt, 0, sizeof(fmt));
    st = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &fmt);
    SInt64 frames = (st == noErr && fmt.mSampleRate > 0) ? CSFrameCount(url, file, &fmt) : 0;
    if (frames <= 0) {
        AudioFileClose(file);
        if (outError) *outError = CSAudioError(st ? st : (OSStatus)kAudioFileInvalidFileError,
            [NSString stringWithFormat:@"“%@” doesn’t contain any sound Cassette can play.", name],
            formats);
        return NO;
    }
    // The player counts a region's frames in 32 bits. A file longer than that
    // (27 hours at 44.1 kHz) loops its first 27 hours.
    if (frames > (SInt64)UINT32_MAX) frames = (SInt64)UINT32_MAX;

    NSString *title = nil, *artist = nil;
    CFDictionaryRef info = NULL;
    size = sizeof(info);
    if (AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info) == noErr && info) {
        title  = CSInfoString((NSDictionary *)info, kAFInfoDictionary_Title);
        artist = CSInfoString((NSDictionary *)info, kAFInfoDictionary_Artist);
        CFRelease(info);
    }
    if (!title) title = [name stringByDeletingPathExtension];

    // From here on the new tape replaces the old one.
    [self eject];

    st = [self createUnits];
    if (st == noErr) st = [self configureForSampleRate:fmt.mSampleRate];
    if (st != noErr) {
        AudioFileClose(file);
        if (outError) *outError = CSAudioError(st, @"Cassette couldn’t open the sound output.",
            @"Check that an output device is selected in System Preferences > Sound.");
        return NO;
    }

    _file       = file;
    _url        = [url retain];
    _title      = [title retain];
    _artist     = [artist retain];
    _sampleRate = fmt.mSampleRate;
    _passFrames = frames;

    SInt64 maxRegion = sMaxRegionFrames > 0 ? sMaxRegionFrames : CS_DEFAULT_MAX_REGION_FRAMES;
    SInt64 passes = maxRegion / frames;
    _passesPerRegion = (UInt32)(passes < 1 ? 1 : passes);

    st = [self rewind];
    if (st != noErr) {
        [self eject];
        if (outError) *outError = CSAudioError(st, [NSString stringWithFormat:
            @"Cassette couldn’t start reading “%@”.", name], nil);
        return NO;
    }
    return YES;
}

#pragma mark - Scheduling

// Queues `frames` frames of the file from `start`, played `loops` times over,
// at the end of what is already queued.
- (BOOL)scheduleFrames:(SInt64)frames from:(SInt64)start loops:(UInt32)loops
{
    ScheduledAudioFileRegion region;
    memset(&region, 0, sizeof(region));
    region.mTimeStamp.mFlags      = kAudioTimeStampSampleTimeValid;
    region.mTimeStamp.mSampleTime = _scheduledEnd;
    region.mAudioFile             = _file;
    region.mLoopCount             = loops - 1;
    region.mStartFrame            = start;
    region.mFramesToPlay          = (UInt32)frames;
    if (AudioUnitSetProperty(_player, kAudioUnitProperty_ScheduledFileRegion,
                             kAudioUnitScope_Global, 0, &region, sizeof(region)) != noErr)
        return NO;
    _scheduledEnd += (Float64)frames * loops;
    return YES;
}

- (void)scheduleRegion
{
    [self scheduleFrames:_passFrames from:0 loops:_passesPerRegion];
}

// Stops the output and rebuilds the queue so that playback, when it starts,
// begins `total` frames into the tape: the rest of the current pass, then
// whole regions of passes. The first of it is read from disk before this
// returns, so starting is immediate.
//
// This is also how pausing works, and it has to be. The output unit's clock
// starts again from zero every time the output is started, and the file player
// measures its position against that clock, so an output that is simply
// stopped and restarted plays the file from the top. The position is kept here
// instead, in _baseFrames, and the queue is rebuilt from it.
- (OSStatus)scheduleFromFrame:(Float64)total
{
    if (_output) AudioOutputUnitStop(_output);
    [self disarmTopUpTimer];

    AudioUnitReset(_player, kAudioUnitScope_Global, 0);
    OSStatus st = AudioUnitSetProperty(_player, kAudioUnitProperty_ScheduledFileIDs,
                                       kAudioUnitScope_Global, 0, &_file, sizeof(_file));
    if (st != noErr) return st;

    if (!(total >= 0)) total = 0;
    _baseFrames     = total;
    _needsSchedule  = NO;
    _scheduledEnd   = 0;
    _offlineTime    = 0;
    // The output is stopped (above), so nothing is rendering to race with.
    __sync_lock_test_and_set(&_rendered->frames, (int64_t)0);
    SInt64 into = (SInt64)fmod(total, (double)_passFrames);
    if (into > 0 && ![self scheduleFrames:_passFrames - into from:into loops:1])
        return kAudioUnitErr_InvalidPropertyValue;
    [self scheduleRegion];
    [self scheduleRegion];
    if (_scheduledEnd <= 0) return kAudioUnitErr_InvalidPropertyValue;

    UInt32 prime = 0;   // the player's default amount
    AudioUnitSetProperty(_player, kAudioUnitProperty_ScheduledFilePrime,
                         kAudioUnitScope_Global, 0, &prime, sizeof(prime));

    AudioTimeStamp start;
    memset(&start, 0, sizeof(start));
    start.mFlags      = kAudioTimeStampSampleTimeValid;
    start.mSampleTime = -1;   // whenever the output next asks for audio
    return AudioUnitSetProperty(_player, kAudioUnitProperty_ScheduleStartTimeStamp,
                                kAudioUnitScope_Global, 0, &start, sizeof(start));
}

- (OSStatus)rewind
{
    _playing = NO;
    return [self scheduleFromFrame:0];
}

// Frames the player has rendered since its queue was last built.
- (Float64)playerFrames
{
    return _rendered ? (Float64)__sync_fetch_and_add(&_rendered->frames, (int64_t)0) : 0;
}

- (Float64)elapsedFrames
{
    if (!_file) return 0;
    if (_needsSchedule) return _baseFrames;
    return _baseFrames + [self playerFrames];
}

- (double)elapsed
{
    return _sampleRate > 0 ? [self elapsedFrames] / _sampleRate : 0;
}

// The queue holds between one and two regions beyond the play head, which is
// six to twelve hours of audio. The timer that calls this fires every hour, so
// it would have to miss six in a row for the music to stop.
- (void)topUpSchedule
{
    if (!_file || _needsSchedule) return;
    Float64 region = (Float64)_passFrames * _passesPerRegion;
    Float64 now = [self playerFrames];
    int guard = 0;
    while (_scheduledEnd - now <= region && guard++ < 64) {
        Float64 before = _scheduledEnd;
        [self scheduleRegion];
        if (_scheduledEnd == before) break;   // the player refused; try again next time
    }
}

- (void)topUpTimerFired:(NSTimer *)timer
{
    (void)timer;
    [self topUpSchedule];
}

- (void)armTopUpTimer
{
    if (_topUpTimer || _offline) return;
    double regionSeconds = (double)_passFrames * _passesPerRegion / _sampleRate;
    double interval = regionSeconds / 4;
    if (interval > 3600) interval = 3600;
    if (interval < 60) interval = 60;
    _topUpTimer = [[NSTimer timerWithTimeInterval:interval target:self
                                         selector:@selector(topUpTimerFired:)
                                         userInfo:nil repeats:YES] retain];
    // Generous slack lets the system fold this into a wakeup it was making anyway.
    [_topUpTimer setTolerance:interval * 0.25];
    [[NSRunLoop mainRunLoop] addTimer:_topUpTimer forMode:NSRunLoopCommonModes];
}

- (void)disarmTopUpTimer
{
    [_topUpTimer invalidate];
    [_topUpTimer release];
    _topUpTimer = nil;
}

#pragma mark - Transport

// Rebuilds the queue if a pause left it stale, then lets the output run.
//
// A failure leaves the position noted and the queue marked stale, exactly as a
// pause does, so the next attempt rebuilds the queue from where the tape is
// rather than starting whatever is left of it. -scheduleFromFrame: clears
// _needsSchedule before it schedules anything, so one that failed partway used
// to leave a half-built queue looking current: the next Play started the output
// over it, and the counter ran on through silence.
- (BOOL)startOutput
{
    if (_needsSchedule && [self scheduleFromFrame:_baseFrames] != noErr) {
        [self stopOutputKeepingPosition];
        return NO;
    }
    [self topUpSchedule];
    if (sOutputStartFailsForTesting ||
        (_output && AudioOutputUnitStart(_output) != noErr)) {
        [self stopOutputKeepingPosition];
        return NO;
    }
    [self armTopUpTimer];
    return YES;
}

// Stops the output and notes exactly where the tape got to.
//
// Stopped FIRST, then read, and the order is the whole of "exactly". The
// count is advanced on the audio thread at the end of each slice, and a slice
// can be mid-render at the instant this runs: read first, and that slice
// lands after the read but before the stop, so the position recorded is one
// device buffer (up to 4096 frames, ~93 ms) short of what was rendered, and
// resuming plays that stretch again. AudioOutputUnitStop does not return while
// a render is in progress, so once it has, the count is final. Measured
// against the default output with a render that takes a few milliseconds:
// read-then-stop moved the count after the read in 23 pauses of 40,
// stop-then-read in none.
- (void)stopOutputKeepingPosition
{
    if (_output) AudioOutputUnitStop(_output);
    _baseFrames = [self elapsedFrames];
    _needsSchedule = YES;
    [self disarmTopUpTimer];
}

- (BOOL)play
{
    if (!_file) return NO;
    if (_playing) return YES;
    if (![self startOutput]) return NO;
    _playing = YES;
    return YES;
}

- (void)pause
{
    if (!_playing) return;
    [self stopOutputKeepingPosition];
    _playing = NO;
}

- (void)stop
{
    if (_file) [self rewind];
}

- (void)eject
{
    if (_output) AudioOutputUnitStop(_output);
    _playing = NO;
    _needsSchedule = NO;
    [self disarmTopUpTimer];
    if (_player) AudioUnitReset(_player, kAudioUnitScope_Global, 0);
    if (_file) {
        AudioFileClose(_file);
        _file = NULL;
    }
    [_url release];    _url = nil;
    [_title release];  _title = nil;
    [_artist release]; _artist = nil;
    _passFrames = 0;
    _baseFrames = 0;
    _scheduledEnd = 0;
}

#pragma mark - Sleep

// A tape playing when the machine goes to sleep is paused, and comes back that
// way. This used to start it again on wake, which turned any wake at all into
// music -- a mouse nudged in the night included -- and a playing tape holds the
// machine awake (Core Audio keeps idle sleep off while the output runs), so one
// such wake kept the Mac up behind a dark screen until someone pressed PAUSE.
//
// The pause is also what keeps the place. The output stops while the machine
// sleeps, and its clock may start again from zero on wake -- which, as above,
// would send the player back to the top of the file. A pause notes the position
// on the way down, and the next PLAY rebuilds the queue from it.
- (void)systemWillSleep:(NSNotification *)note
{
    if (!_playing || _offline) return;
    [self pause];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:CSAudioEngineDidPauseForSleepNotification object:self];
}

#pragma mark - Volume

- (float)volume { return _volume; }

- (void)setVolume:(float)volume
{
    if (!(volume >= 0)) volume = 0;
    if (volume > 1) volume = 1;
    _volume = volume;
    [self applyVolume];
}

- (void)applyVolume
{
    if (_output)
        AudioUnitSetParameter(_output, kHALOutputParam_Volume, kAudioUnitScope_Global, 0, _volume, 0);
}

#pragma mark - Offline rendering

- (OSStatus)renderOffline:(float *)left right:(float *)right frames:(UInt32)frames
{
    if (!_offline || !_player || !_file) return kAudioUnitErr_Uninitialized;
    struct { AudioBufferList list; AudioBuffer second; } buffers;
    buffers.list.mNumberBuffers = 2;
    buffers.list.mBuffers[0].mNumberChannels = 1;
    buffers.list.mBuffers[0].mDataByteSize   = frames * sizeof(float);
    buffers.list.mBuffers[0].mData           = left;
    buffers.list.mBuffers[1].mNumberChannels = 1;
    buffers.list.mBuffers[1].mDataByteSize   = frames * sizeof(float);
    buffers.list.mBuffers[1].mData           = right;

    AudioTimeStamp ts;
    memset(&ts, 0, sizeof(ts));
    ts.mFlags      = kAudioTimeStampSampleTimeValid;
    ts.mSampleTime = _offlineTime;
    AudioUnitRenderActionFlags flags = 0;
    OSStatus st = AudioUnitRender(_player, &flags, &ts, 0, frames, &buffers.list);
    _offlineTime += frames;
    return st;
}

@end
