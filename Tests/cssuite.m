// cssuite -- every automated check for Cassette, one subcommand per suite.
//
//   cssuite unit               the power policy, the tape model, the geometry,
//                              the artwork cache
//   cssuite audio <dir>        the engine: sample-exact looping, regions, errors
//   cssuite deck               a real controller: does the policy reach the reels?
//   cssuite snapshot <dir>     render the deck to PNGs for a person to look at
//
// Built for the shipping target (x86_64, 10.9) and linked against the same
// objects as the app, so what passes here is the code that ships.

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import "CSPower.h"
#import "CSTape.h"
#import "CSArtwork.h"
#import "CSAudioEngine.h"
#import "CSDeckView.h"
#import "CSDeckWindow.h"
#import "CSArtworkCache.h"
#import "CSPlayerController.h"
#import "CSAppDelegate.h"
#include <math.h>
#include <unistd.h>

static int sPassed, sFailed;

static void OK(BOOL cond, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void OK(BOOL cond, NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[[NSString alloc] initWithFormat:fmt arguments:ap] autorelease];
    va_end(ap);
    if (cond) sPassed++;
    else { sFailed++; fprintf(stderr, "  FAIL: %s\n", [msg UTF8String]); }
}

static void Section(const char *name) { printf("-- %s\n", name); }

static int Finish(const char *suite)
{
    printf("%s: %d passed, %d failed\n", suite, sPassed, sFailed);
    return sFailed ? 1 : 0;
}

static void Pump(double seconds)
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSAnyEventMask untilDate:until
                                           inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e) [NSApp sendEvent:e];
    }
}

static BOOL Near(double a, double b, double tol) { return fabs(a - b) <= tol; }

#pragma mark - unit

static void TestPowerStrings(void)
{
    Section("power source strings");
    OK(CSPowerSourceFromString(@"AC Power") == CSPowerAC, @"'AC Power' is AC");
    OK(CSPowerSourceFromString(@"Battery Power") == CSPowerBattery, @"'Battery Power' is battery");
    OK(CSPowerSourceFromString(@" ac ") == CSPowerAC, @"'ac' is AC");
    OK(CSPowerSourceFromString(@"battery") == CSPowerBattery, @"'battery' is battery");
    OK(CSPowerSourceFromString(@"UPS Power") == CSPowerUnknown, @"a UPS is not AC");
    OK(CSPowerSourceFromString(@"") == CSPowerUnknown, @"empty is unknown");
    OK(CSPowerSourceFromString(nil) == CSPowerUnknown, @"nil is unknown");
    OK(CSPowerSourceFromString((NSString *)[NSNumber numberWithInt:2]) == CSPowerUnknown,
       @"a non-string is unknown");

    CSSetPowerSourceOverride(CSPowerBattery, YES);
    OK(CSCurrentPowerSource() == CSPowerBattery, @"override pins battery");
    CSSetPowerSourceOverride(CSPowerAC, YES);
    OK(CSCurrentPowerSource() == CSPowerAC, @"override pins AC");
    CSSetPowerSourceOverride(CSPowerUnknown, NO);
    CSPowerSource real = CSCurrentPowerSource();
    printf("   this machine reports: %s\n",
           real == CSPowerAC ? "AC" : real == CSPowerBattery ? "battery" : "unknown");
}

static CSUIState State(BOOL playing, BOOL open, BOOL onScreen, BOOL active)
{
    CSUIState s = { playing, open, onScreen, active };
    return s;
}

static void TestPolicy(void)
{
    Section("reel policy: the specification, case by case");
    // AC: continuous while playing, whatever the focus.
    OK(CSReelsShouldSpin(CSPowerAC, State(YES, YES, YES, YES)), @"AC, frontmost: spin");
    OK(CSReelsShouldSpin(CSPowerAC, State(YES, YES, YES, NO)), @"AC, background but visible: spin");
    OK(CSReelsShouldSpin(CSPowerAC, State(YES, YES, NO, NO)), @"AC, background and covered: spin");
    OK(!CSReelsShouldSpin(CSPowerAC, State(NO, YES, YES, YES)), @"AC, paused: still");
    // Battery: only while visible AND in focus.
    OK(CSReelsShouldSpin(CSPowerBattery, State(YES, YES, YES, YES)), @"battery, frontmost and visible: spin");
    OK(!CSReelsShouldSpin(CSPowerBattery, State(YES, YES, YES, NO)), @"battery, background: still");
    OK(!CSReelsShouldSpin(CSPowerBattery, State(YES, YES, NO, YES)), @"battery, focused but minimised: still");
    OK(!CSReelsShouldSpin(CSPowerBattery, State(YES, YES, NO, NO)), @"battery, hidden: still");
    OK(!CSReelsShouldSpin(CSPowerBattery, State(NO, YES, YES, YES)), @"battery, paused: still");
    // Unknown is battery, never AC.
    OK(!CSReelsShouldSpin(CSPowerUnknown, State(YES, YES, YES, NO)), @"unknown, background: still");
    OK(CSReelsShouldSpin(CSPowerUnknown, State(YES, YES, YES, YES)), @"unknown, frontmost: spin");
    // No window, nothing to animate.
    OK(!CSReelsShouldSpin(CSPowerAC, State(YES, NO, NO, YES)), @"AC, window closed: still");

    Section("reel policy: all 48 combinations");
    int power, bits, mismatches = 0;
    for (power = 0; power < 3; power++) {
        for (bits = 0; bits < 16; bits++) {
            CSUIState s = State(bits & 1, (bits >> 1) & 1, (bits >> 2) & 1, (bits >> 3) & 1);
            BOOL expect = s.playing && s.windowOpen &&
                          (power == CSPowerAC || (s.appActive && s.windowOnScreen));
            if (CSReelsShouldSpin((CSPowerSource)power, s) != expect) mismatches++;
        }
    }
    OK(mismatches == 0, @"%d combinations disagree with the specification", mismatches);
}

static void TestTape(void)
{
    Section("tape model");
    OK(CSPassesPerSide(180) == 10, @"a 3-minute song is 10 passes a side (got %lu)", (unsigned long)CSPassesPerSide(180));
    OK(CSPassesPerSide(1800) == 1, @"exactly 30 minutes is one pass");
    OK(CSPassesPerSide(2700) == 1, @"45 minutes is one pass");
    OK(CSPassesPerSide(900) == 2, @"15 minutes is two passes");
    OK(CSPassesPerSide(7) == 258, @"7 seconds is 258 passes (got %lu)", (unsigned long)CSPassesPerSide(7));
    OK(CSPassesPerSide(0) == 1 && CSPassesPerSide(NAN) == 1 && CSPassesPerSide(-3) == 1,
       @"nonsense lengths are one pass");

    CSTapeState s = CSTapeStateAt(0, 180);
    OK(Near(s.leftRadius, CS_FULL_RADIUS_MM, 1e-9) && Near(s.rightRadius, CS_HUB_RADIUS_MM, 1e-9),
       @"a rewound tape is all on the left");
    OK(s.direction == 1 && s.leftOmega > 0 && s.rightOmega > 0, @"forward play turns both reels counter-clockwise");
    OK(s.passSeconds == 0 && s.counter == 0, @"the counter starts at zero");

    double duration = 180, side = 1800;
    double hub2 = CS_HUB_RADIUS_MM * CS_HUB_RADIUS_MM, full2 = CS_FULL_RADIUS_MM * CS_FULL_RADIUS_MM;
    int bad = 0, i;
    for (i = 0; i <= 4000; i++) {
        double t = i * 1.37;
        CSTapeState u = CSTapeStateAt(t, duration);
        double area = u.leftRadius * u.leftRadius + u.rightRadius * u.rightRadius;
        if (!Near(area, hub2 + full2, 1e-6)) bad++;
        if (!Near(fabs(u.leftOmega) * u.leftRadius, CS_TAPE_SPEED_MM_S, 1e-9)) bad++;
        if (!Near(fabs(u.rightOmega) * u.rightRadius, CS_TAPE_SPEED_MM_S, 1e-9)) bad++;
        if (u.leftRadius < CS_HUB_RADIUS_MM - 1e-9 || u.leftRadius > CS_FULL_RADIUS_MM + 1e-9) bad++;
        if (!Near(u.passSeconds, fmod(t, duration), 1e-9)) bad++;
        if (u.counter != (NSUInteger)fmod(floor(t), 1000.0)) bad++;
    }
    OK(bad == 0, @"tape area is conserved, both reels run at tape speed, the counter is seconds played (%d violations)", bad);

    // The case that looked broken: a short sound on a loop.
    OK(CSTapeStateAt(3.5, 1.0).counter == 3 && CSTapeStateAt(59.99, 1.6).counter == 59,
       @"the counter keeps counting across loops of a short file");
    OK(CSTapeStateAt(1000.5, 180).counter == 0 && CSTapeStateAt(1234.9, 180).counter == 234,
       @"and rolls over after 999, as three drums do");
    OK(CSTapeStateAt(1800 + 12.5, 180).counter == 812, @"it counts up on the reverse side too");

    s = CSTapeStateAt(side / 2, duration);
    OK(Near(s.leftRadius, s.rightRadius, 1e-9), @"half way through a side the packs are equal");

    CSTapeState before = CSTapeStateAt(side - 1e-6, duration), after = CSTapeStateAt(side + 1e-6, duration);
    OK(before.direction == 1 && after.direction == -1, @"the deck reverses at the end of the side");
    OK(Near(before.rightRadius, after.rightRadius, 1e-4) && Near(before.leftRadius, after.leftRadius, 1e-4),
       @"the packs do not jump when it reverses");
    OK(after.leftOmega < 0 && after.rightOmega < 0, @"in reverse both reels turn clockwise");
    OK(Near(fmod(side, duration), 0, 1e-9), @"a side ends exactly on a loop boundary");
    CSTapeState back = CSTapeStateAt(2 * side + 1e-6, duration);
    OK(back.direction == 1 && Near(back.leftRadius, CS_FULL_RADIUS_MM, 1e-4), @"and back again after two sides");

    double ratio = CSTapeStateAt(0, duration).rightOmega / CSTapeStateAt(0, duration).leftOmega;
    OK(Near(ratio, CS_FULL_RADIUS_MM / CS_HUB_RADIUS_MM, 1e-9), @"an empty hub turns %.2fx as fast as a full one", ratio);
    double fastest = CS_TAPE_SPEED_MM_S / CS_HUB_RADIUS_MM / (2 * M_PI);
    double slowest = CS_TAPE_SPEED_MM_S / CS_FULL_RADIUS_MM / (2 * M_PI);
    OK(fastest < 0.75 && slowest > 0.28, @"reels turn between %.2f and %.2f rev/s, as on a real deck", slowest, fastest);
    printf("   reel speed: %.2f rev/s (full) to %.2f rev/s (empty)\n", slowest, fastest);

    s = CSTapeStateAt(125.5, 0);
    OK(s.passSeconds == 125.5 && s.counter == 125 && s.direction == 1, @"unknown length: counter shows total time");
}

static void TestGeometry(void)
{
    Section("geometry");
    OK(CS_WINDOW_R_MM > CS_HUB_RADIUS_MM, @"the hubs are wholly inside the window");
    OK(CS_FULL_RADIUS_MM + CS_HUB_RADIUS_MM < CS_HUB_SPACING_MM, @"a full pack never touches the other reel");
    OK(CS_HUB_Y_MM + CS_FULL_RADIUS_MM < CS_SHELL_H_MM, @"a full pack fits inside the shell");
    CGRect cassette = CSCassetteRect(), well = CSWellRect();
    OK(CGRectContainsRect(well, cassette), @"the cassette fits in the well");
    OK(CGRectContainsRect(CSDoorRect(), well), @"the well is inside the door");
    int k;
    for (k = 0; k + 1 < CSKeyCount; k++)
        OK(!CGRectIntersectsRect(CSKeyHitRect((CSKey)k), CSKeyHitRect((CSKey)(k + 1))), @"keys %d and %d are apart", k, k + 1);
    OK(!CGRectIntersectsRect(CSKeyRect(CSKeyEject), CSDoorRect()), @"keys sit below the door");
    CGPoint o = CSKnobCentre();
    OK(o.x + CSKnobRadius() + 30 < CS_DECK_WIDTH - CS_CHEEK_WIDTH, @"the knob and its scale clear the right cheek");
    OK(CSDoorRect().origin.x > CS_CHEEK_WIDTH + 12, @"the door clears the left cheek");
    OK(CSHubCentre(0).x < CSHubCentre(1).x, @"left hub is on the left");
}

static BOOL SamePixels(CGImageRef a, CGImageRef b)
{
    if (!a || !b || CGImageGetWidth(a) != CGImageGetWidth(b) || CGImageGetHeight(a) != CGImageGetHeight(b))
        return NO;
    CFDataRef da = CGDataProviderCopyData(CGImageGetDataProvider(a));
    CFDataRef db = CGDataProviderCopyData(CGImageGetDataProvider(b));
    BOOL same = da && db && CGImageGetBytesPerRow(a) == CGImageGetBytesPerRow(b) &&
                CFDataGetLength(da) == CFDataGetLength(db) &&
                memcmp(CFDataGetBytePtr(da), CFDataGetBytePtr(db), (size_t)CFDataGetLength(da)) == 0;
    if (da) CFRelease(da);
    if (db) CFRelease(db);
    return same;
}

static void TestArtworkCache(void)
{
    Section("artwork cache");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"cassette-cache-test"];
    [fm removeItemAtPath:root error:NULL];
    NSString *dir = [root stringByAppendingPathComponent:@"Artwork/this-build"];
    NSString *old = [root stringByAppendingPathComponent:@"Artwork/an-older-build"];
    [fm createDirectoryAtPath:old withIntermediateDirectories:YES attributes:nil error:NULL];

    OK(CSArtworkCacheDirectory() == nil, @"a process with no bundle identifier has no cache of its own");
    CSArtworkCacheSetDirectory(dir);
    __block int draws = 0;
    CGImageRef (^draw)(void) = ^{ draws++; return CSCreateKeyImage(CSKeyPlay, NO, 2); };

    CGImageRef first = CSArtworkCopy(@"key", 2, draw);
    CSArtworkCacheFlush();
    NSString *file = [dir stringByAppendingPathComponent:@"key@2x.pixels"];
    OK(draws == 1 && first != NULL, @"a miss draws the image");
    OK([fm fileExistsAtPath:file], @"and keeps it");
    OK(![fm fileExistsAtPath:old], @"the folder another build left behind is deleted");

    CGImageRef second = CSArtworkCopy(@"key", 2, draw);
    OK(draws == 1, @"a hit does not draw");
    OK(SamePixels(first, second), @"and gives back exactly the pixels that were drawn");
    CGImageRef other = CSArtworkCopy(@"key", 1, draw);
    OK(draws == 2, @"each scale is its own entry");
    CGImageRelease(other);

    // A file cut short, as a full disk might leave one, is not read.
    NSData *whole = [NSData dataWithContentsOfFile:file];
    [[whole subdataWithRange:NSMakeRange(0, [whole length] / 2)] writeToFile:file atomically:YES];
    CGImageRef third = CSArtworkCopy(@"key", 2, draw);
    CSArtworkCacheFlush();
    OK(draws == 3 && SamePixels(first, third), @"a truncated file is drawn again");
    OK([[NSData dataWithContentsOfFile:file] length] == [whole length], @"and replaced");
    [@"not pixels at all" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    CGImageRef fourth = CSArtworkCopy(@"key", 2, draw);
    OK(draws == 4 && SamePixels(first, fourth), @"so is one that is not in the format");

    CSArtworkCacheSetDirectory(nil);
    CGImageRef uncached = CSArtworkCopy(@"key", 2, draw);
    OK(draws == 5 && SamePixels(first, uncached), @"with the cache off, everything is drawn");
    CGImageRelease(first);
    CGImageRelease(second);
    CGImageRelease(third);
    CGImageRelease(fourth);
    CGImageRelease(uncached);
    CSArtworkCacheFlush();
    [fm removeItemAtPath:root error:NULL];
}

#pragma mark - audio

// A mono 16-bit file whose every sample is different from its neighbours, so
// that any gap, repeat or offset at a loop point shows up as a mismatch.
static SInt16 FixtureSample(SInt64 i)
{
    return (SInt16)(((i * 7919) % 20011) - 10005);
}

static NSURL *WriteFixture(NSString *dir, NSString *name, double rate, SInt64 frames, BOOL sine, AudioFileTypeID type,
                           AudioFormatID format)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];

    AudioStreamBasicDescription pcm;
    memset(&pcm, 0, sizeof(pcm));
    pcm.mSampleRate = rate;
    pcm.mFormatID = kAudioFormatLinearPCM;
    pcm.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    pcm.mBitsPerChannel = 16;
    pcm.mChannelsPerFrame = 1;
    pcm.mFramesPerPacket = 1;
    pcm.mBytesPerFrame = 2;
    pcm.mBytesPerPacket = 2;

    AudioStreamBasicDescription fileFormat = pcm;
    if (format != kAudioFormatLinearPCM) {
        memset(&fileFormat, 0, sizeof(fileFormat));
        fileFormat.mSampleRate = rate;
        fileFormat.mFormatID = format;
        fileFormat.mChannelsPerFrame = 1;
    }

    ExtAudioFileRef ext = NULL;
    OSStatus st = ExtAudioFileCreateWithURL((CFURLRef)url, type, &fileFormat, NULL,
                                            kAudioFileFlags_EraseFile, &ext);
    if (st != noErr) return nil;
    ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, sizeof(pcm), &pcm);
    SInt16 *buf = (SInt16 *)malloc((size_t)frames * sizeof(SInt16));
    SInt64 i;
    for (i = 0; i < frames; i++)
        buf[i] = sine ? (SInt16)(12000.0 * sin(2 * M_PI * 480.0 * (double)i / rate)) : FixtureSample(i);
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 1;
    list.mBuffers[0].mDataByteSize = (UInt32)(frames * 2);
    list.mBuffers[0].mData = buf;
    st = ExtAudioFileWrite(ext, (UInt32)frames, &list);
    ExtAudioFileDispose(ext);
    free(buf);
    return st == noErr ? url : nil;
}

// Renders `total` frames offline, paced a few times faster than real time so
// the player's disk reader keeps up as it would with a real device.
static float *RenderOffline(CSAudioEngine *engine, SInt64 total, float **rightOut, int topUpEvery)
{
    float *left = (float *)calloc((size_t)total, sizeof(float));
    float *right = (float *)calloc((size_t)total, sizeof(float));
    SInt64 done = 0;
    int slices = 0;
    while (done < total) {
        UInt32 n = (UInt32)MIN((SInt64)512, total - done);
        [engine renderOffline:left + done right:right + done frames:n];
        done += n;
        if (topUpEvery && ++slices % topUpEvery == 0) [engine topUpSchedule];
        usleep(1500);
    }
    *rightOut = right;
    return left;
}

static int RunAudio(NSString *dir)
{
    Section("fixtures");
    const double rate = 48000;
    const SInt64 pass = 4800;   // 0.1 s
    NSURL *wav = WriteFixture(dir, @"pattern.wav", rate, pass, NO, kAudioFileWAVEType, kAudioFormatLinearPCM);
    OK(wav != nil, @"wrote the WAV fixture");
    NSURL *m4a = WriteFixture(dir, @"tone.m4a", 44100, 44100, YES, kAudioFileM4AType, kAudioFormatMPEG4AAC);
    OK(m4a != nil, @"wrote the AAC fixture");
    NSURL *junk = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"not-audio.wav"]];
    [@"this is not a sound" writeToURL:junk atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (!wav) return Finish("audio");

    Section("loading");
    // Three passes per region, so eight regions go by in the test below.
    [CSAudioEngine setMaximumRegionFramesForTesting:3 * pass];
    CSAudioEngine *engine = [[CSAudioEngine alloc] initForOfflineRendering];
    NSError *error = nil;
    OK([engine loadURL:wav error:&error], @"loads the WAV fixture (%@)", error);
    OK([engine hasTape] && ![engine isPlaying], @"a new tape is in, stopped");
    OK([engine framesPerPass] == pass, @"%lld frames per pass", (long long)[engine framesPerPass]);
    OK(Near([engine duration], 0.1, 1e-9), @"duration is 0.1 s");
    OK([engine passesPerRegion] == 3, @"three passes per region under the test cap");
    OK([engine elapsed] == 0, @"a rewound tape has played nothing");

    Section("looping");
    SInt64 total = pass * 24;
    float *right = NULL;
    float *left = RenderOffline(engine, total, &right, 8);
    SInt64 i, wrong = 0, firstWrong = -1, asymmetric = 0;
    for (i = 0; i < total; i++) {
        float want = (float)FixtureSample(i % pass) / 32768.0f;
        if (fabsf(left[i] - want) > 1e-5f) { wrong++; if (firstWrong < 0) firstWrong = i; }
        if (left[i] != right[i]) asymmetric++;
    }
    OK(wrong == 0, @"24 passes across 8 regions are sample-exact (%lld wrong, first at frame %lld: got %f want %f)",
       (long long)wrong, (long long)firstWrong,
       firstWrong >= 0 ? left[firstWrong] : 0, firstWrong >= 0 ? FixtureSample(firstWrong % pass) / 32768.0f : 0);
    OK(asymmetric == 0, @"a mono file plays identically in both channels (%lld differ)", (long long)asymmetric);
    // Elapsed is counted from the frames the player has rendered, so after an
    // offline render it is exactly what was asked for.
    double lag = (double)total / rate - [engine elapsed];
    OK(Near(lag, 0, 1e-9), @"elapsed is the frames rendered (%.1f frames out)", lag * rate);
    free(left); free(right);

    Section("pause resumes from the same sample");
    OK([engine play] && [engine isPlaying], @"play");
    SInt64 before = pass + 2300;   // mid-pass, so the queue restarts with a partial pass
    left = RenderOffline(engine, before, &right, 0);
    free(left); free(right);
    [engine pause];
    OK(![engine isPlaying], @"paused");
    double at = [engine elapsed] * rate;
    OK(at > 0 && fmod(at, (double)pass) != 0, @"paused part-way through a pass, at frame %.0f", at);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    OK(Near([engine elapsed] * rate, at, 0.5), @"a paused tape does not move");
    OK([engine play], @"resume");
    SInt64 after = pass * 10;      // across the partial pass and three region boundaries
    left = RenderOffline(engine, after, &right, 4);
    wrong = 0; firstWrong = -1;
    for (i = 0; i < after; i++) {
        float want = (float)FixtureSample(((SInt64)at + i) % pass) / 32768.0f;
        if (fabsf(left[i] - want) > 1e-5f) { wrong++; if (firstWrong < 0) firstWrong = i; }
    }
    OK(wrong == 0, @"playback continues from frame %.0f, sample-exact for ten passes (%lld wrong, first at %lld)",
       at, (long long)wrong, (long long)firstWrong);
    free(left); free(right);

    Section("stop rewinds");
    [engine stop];
    OK([engine elapsed] == 0, @"stop puts the play head back to zero");
    left = RenderOffline(engine, 2048, &right, 0);
    OK(fabsf(left[0] - FixtureSample(0) / 32768.0f) < 1e-5f && fabsf(left[2047] - FixtureSample(2047) / 32768.0f) < 1e-5f,
       @"and playback restarts at the first sample");
    free(left); free(right);

    Section("a bad file changes nothing");
    error = nil;
    OK(![engine loadURL:junk error:&error], @"refuses a file that is not audio");
    OK(error != nil && [[error localizedDescription] length] > 0, @"with an explanation: %@", [error localizedDescription]);
    OK([engine hasTape] && [[engine URL] isEqual:wav], @"and the tape that was in is still in");
    OK([CSAudioEngine canProbablyReadURL:wav] && [CSAudioEngine canProbablyReadURL:m4a], @"wav and m4a are recognised");
    OK(![CSAudioEngine canProbablyReadURL:[NSURL fileURLWithPath:@"/tmp/x.pdf"]], @"pdf is not");
    OK([[CSAudioEngine readableTypes] count] > 3, @"the Open panel is offered %lu types", (unsigned long)[[CSAudioEngine readableTypes] count]);
    [engine eject];
    OK(![engine hasTape] && [engine elapsed] == 0, @"eject empties the deck");
    [engine release];
    [CSAudioEngine setMaximumRegionFramesForTesting:0];

    if (m4a) {
        Section("AAC loops without a gap");
        CSAudioEngine *aac = [[CSAudioEngine alloc] initForOfflineRendering];
        OK([aac loadURL:m4a error:&error], @"loads the AAC fixture (%@)", error);
        printf("   AAC pass: %lld frames (%.4f s); encoded from 44100\n", (long long)[aac framesPerPass], [aac duration]);
        OK(llabs([aac framesPerPass] - 44100) <= 1, @"encoder priming and padding are excluded from the pass");
        SInt64 n = [aac framesPerPass] * 3;
        left = RenderOffline(aac, n, &right, 0);
        // The tone is exactly periodic over the file, so a seamless loop has no
        // quiet stretch anywhere. A gap -- priming played as silence -- would.
        double quietest = 1e9;
        SInt64 w, win = 256;
        for (w = 0; w + win <= n; w += 64) {
            double e = 0;
            for (i = w; i < w + win; i++) e += (double)left[i] * left[i];
            e = sqrt(e / win);
            if (e < quietest) quietest = e;
        }
        OK(quietest > 0.15, @"no silent stretch across two loop points (quietest window RMS %.3f)", quietest);
        free(left); free(right);
        [aac release];
    }

    Section("through the real output device");
    CSAudioEngine *live = [[CSAudioEngine alloc] init];
    if (![live loadURL:wav error:&error]) {
        printf("   SKIP: no output device (%s)\n", [[error localizedDescription] UTF8String]);
    } else {
        [live setVolume:0];
        OK([live play] && [live isPlaying], @"starts the output");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
        double played = [live elapsed];
        OK(played > 0.3 && played < 1.5, @"the sample clock advances in real time (%.3f s in 0.6 s)", played);
        [live pause];
        double held = [live elapsed];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        OK(Near([live elapsed], held, 0.01) && ![live isPlaying], @"pause holds the position");
        OK([live play], @"resumes");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        OK([live elapsed] > held + 0.1, @"from where it paused");

        // An output that refuses to start -- a device not ready after a wake --
        // is reported, keeps the tape's place, and does not leave the next
        // attempt starting over a queue it never finished building.
        [live pause];
        double kept = [live elapsed];
        [CSAudioEngine setOutputStartFailsForTesting:YES];
        OK(![live play] && ![live isPlaying], @"an output that will not start is reported, not assumed");
        [CSAudioEngine setOutputStartFailsForTesting:NO];
        OK(Near([live elapsed], kept, 1e-9), @"and the tape keeps its place (%.3f s)", kept);
        OK([live play], @"the next attempt starts");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        OK([live elapsed] > kept + 0.1, @"from that place");

        // A tape playing when the machine goes to sleep is paused, says so, and
        // is still paused, in the same place, when the machine wakes.
        __block int pausedForSleep = 0;
        id observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:CSAudioEngineDidPauseForSleepNotification object:live
                         queue:nil usingBlock:^(NSNotification *note) { pausedForSleep++; }];
        NSNotificationCenter *workspace = [[NSWorkspace sharedWorkspace] notificationCenter];
        [workspace postNotificationName:NSWorkspaceWillSleepNotification object:nil];
        double asleep = [live elapsed];
        OK(![live isPlaying] && pausedForSleep == 1, @"going to sleep pauses the tape, and says so");
        [workspace postNotificationName:NSWorkspaceDidWakeNotification object:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        OK(![live isPlaying] && Near([live elapsed], asleep, 0.01),
           @"waking does not start it again, and it keeps its place (%.3f s)", asleep);
        [workspace postNotificationName:NSWorkspaceWillSleepNotification object:nil];
        OK(pausedForSleep == 1, @"a tape already paused is left alone by the next sleep");
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        OK([live play], @"PLAY carries on after a sleep");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        OK([live elapsed] > asleep + 0.1, @"from where it was");
        [live stop];
        OK([live elapsed] == 0 && ![live isPlaying], @"stop rewinds");
    }
    [live release];
    return Finish("audio");
}

#pragma mark - deck

// Private to the controller, declared rather than added: the public spelling
// reports a refusal with an alert, which a test with no window on screen would
// put up as a modal and wait on forever.
@interface CSPlayerController (CSTestHooks)
- (BOOL)insertURL:(NSURL *)url error:(NSError **)error animated:(BOOL)animated;
@end

// The delegate's handlers for Syllabus's block cue, called here the way the
// distributed notification calls them.
@interface CSAppDelegate (CSTestHooks)
- (void)blockStarted:(NSNotification *)note;
- (void)blockEnded:(NSNotification *)note;
@end

// Counts what an observer registered the ordinary way hears, to show that
// delivery really was suspended when the cue got through.
@interface CSCueWitness : NSObject
@property (nonatomic) int heard;
- (void)hear:(NSNotification *)note;
@end

@implementation CSCueWitness
@synthesize heard = _heard;
- (void)hear:(NSNotification *)note { _heard++; }
@end

static BOOL PumpUntil(double seconds, BOOL (^done)(void))
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && [until timeIntervalSinceNow] > 0) Pump(0.05);
    return done();
}

static int Latched(CSPlayerController *player)
{
    return [[player valueForKey:@"_latched"] intValue];
}

// Syllabus posts com.syllabus.block.started as a block starts and
// com.syllabus.block.ended as it ends. The deck plays on the one and pauses on
// the other, the way its keys would, and otherwise does nothing.
static void TestBlockCue(NSURL *junk)
{
    Section("the block cue");
    NSDictionary *started = [NSDictionary dictionaryWithObject:@"Course 101" forKey:@"course"];
    NSDictionary *ended = [NSDictionary dictionaryWithObjectsAndKeys:
                           @"Course 101", @"course", @"answered", @"how", nil];
    NSNotification *start = [NSNotification notificationWithName:@"com.syllabus.block.started"
                                                          object:nil userInfo:started];
    NSNotification *end = [NSNotification notificationWithName:@"com.syllabus.block.ended"
                                                        object:nil userInfo:ended];

    // Launched as the app is, so the deck restores the remembered tape and the
    // observers are registered where the app registers them.
    CSAppDelegate *app = [[CSAppDelegate alloc] init];
    [app applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    [app applicationDidFinishLaunching:
        [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
    CSPlayerController *cued = [app player];
    CSDeckView *deck = [cued deck];
    OK([cued hasTape] && ![cued isPlaying], @"the remembered tape is back in, stopped");

    [app blockStarted:start];
    OK([cued isPlaying], @"a block starting plays it, reading a restored tape on the spot");
    OK(Latched(cued) == CSKeyPlay && [cued reelsSpinning], @"with PLAY held down and the reels turning");
    Pump(0.4);
    double at = [[cued engine] elapsed];
    [app blockStarted:start];
    Pump(0.2);
    OK([cued isPlaying] && [[cued engine] elapsed] > at,
       @"a start while it plays changes nothing (%.2f s, then %.2f s)", at, [[cued engine] elapsed]);

    [app blockEnded:end];
    at = [[cued engine] elapsed];
    OK(![cued isPlaying] && Latched(cued) == CSKeyPause && ![cued reelsSpinning],
       @"a block ending pauses it, with PAUSE held down");
    [app blockEnded:end];
    Pump(0.2);
    OK(![cued isPlaying] && Latched(cued) == CSKeyPause,
       @"an end on a paused deck leaves it paused (pressing PAUSE there would play)");
    [app blockStarted:start];
    Pump(0.2);
    OK([cued isPlaying] && [[cued engine] elapsed] >= at - 0.01,
       @"the next start carries on from the same place (%.2f s, paused at %.2f s)",
       [[cued engine] elapsed], at);

    // A tape that sleep paused: an end leaves it paused, a start once the Mac
    // is awake plays it, and a start on the way down to sleep is ignored.
    NSNotificationCenter *workspace = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspace postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    OK(![cued isPlaying] && Latched(cued) == CSKeyPause, @"sleep pauses it as before");
    [app blockStarted:start];
    OK(![cued isPlaying] && Latched(cued) == CSKeyPause,
       @"a start while the Mac goes to sleep is ignored, so the tape can't run through the sleep");
    [workspace postNotificationName:NSWorkspaceDidWakeNotification object:nil];
    Pump(0.2);
    OK(![cued isPlaying], @"the wake stays silent");
    [app blockEnded:end];
    OK(![cued isPlaying] && Latched(cued) == CSKeyPause, @"an end after the wake leaves the sleep's pause alone");
    [app blockStarted:start];
    OK([cued isPlaying] && Latched(cued) == CSKeyPlay, @"a block starting after the wake plays it");

    [cued stop];
    [app blockStarted:start];
    OK([cued isPlaying] && [[cued engine] elapsed] < 0.5, @"a stopped tape plays from the top");
    [app blockEnded:end];

    // Through the real distributed centre, with delivery suspended as Cocoa
    // suspends it for an app in the background. Skipped while a real Cassette
    // runs on this Mac, since it would hear the cue too.
    if ([[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.cassette.Cassette"] count]) {
        printf("   SKIP: Cassette is running here, and would play on the suite's cue\n");
    } else {
        NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
        NSString *control = @"com.cassette.suite.control";
        CSCueWitness *witness = [[CSCueWitness alloc] init];
        [dnc addObserver:witness selector:@selector(hear:) name:control object:nil];
        BOOL wasSuspended = [dnc suspended];
        [dnc setSuspended:YES];
        // First something nobody asked to have at once, to show the hold is
        // real. (The server lets it through later, with the next one that is
        // asked for at once.)
        [dnc postNotificationName:control object:nil userInfo:nil];
        Pump(0.6);
        OK([witness heard] == 0 && [dnc suspended],
           @"with delivery suspended, an ordinary distributed notification is held back");
        [dnc postNotificationName:@"com.syllabus.block.started" object:nil userInfo:started];
        BOOL played = PumpUntil(3.0, ^{ return [cued isPlaying]; });
        OK(played && Latched(cued) == CSKeyPlay, @"while a posted start reaches the deck and plays it");
        [dnc postNotificationName:@"com.syllabus.block.ended" object:nil userInfo:ended];
        BOOL paused = PumpUntil(3.0, ^{ return (BOOL)![cued isPlaying]; });
        OK(paused && Latched(cued) == CSKeyPause, @"and a posted end pauses it");
        [dnc removeObserver:witness];
        [dnc setSuspended:wasSuspended];
        [witness release];
    }

    [cued eject];
    Pump(0.2);
    [app blockStarted:start];
    Pump(1.5);
    OK(![cued hasTape] && ![cued isPlaying] && [[cued window] attachedSheet] == nil && ![deck tapeLoaded],
       @"on an empty deck a start does nothing, and doesn't ask for a tape");
    [app blockEnded:end];
    OK(![cued hasTape] && ![cued isPlaying], @"nor does an end");

    [[cued window] orderOut:nil];
    [app release];

    // A remembered tape that turns out not to play, read for the first time by
    // the cue: the deck ends up empty, quietly, and nothing asks for a tape.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSData *mark = [junk bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil
                                   relativeToURL:nil error:NULL];
    OK(mark != nil, @"a remembered tape that is not audio");
    [defaults setObject:mark forKey:@"CSLastTapeBookmark"];
    [defaults setObject:@"Not audio" forKey:@"CSLastTapeTitle"];
    app = [[CSAppDelegate alloc] init];
    [app applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    [app applicationDidFinishLaunching:
        [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
    cued = [app player];
    [app blockStarted:start];
    Pump(1.5);
    OK(![cued hasTape] && ![cued isPlaying] && [[cued window] attachedSheet] == nil &&
       ![[cued deck] tapeLoaded], @"read by a start, it leaves the deck empty without asking for a tape");
    [[cued window] orderOut:nil];
    [app release];
}

static int RunDeck(void)
{
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];

    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"cassette-deck-test"];
    NSURL *song = WriteFixture(dir, @"deck.wav", 44100, 44100 * 2, YES, kAudioFileWAVEType, kAudioFormatLinearPCM);
    OK(song != nil, @"wrote a fixture");

    // Whoever was in front before the test, to be put back afterwards.
    NSRunningApplication *previous = [[[NSWorkspace sharedWorkspace] frontmostApplication] retain];

    // Isolate from the user's own settings.
    [[NSUserDefaults standardUserDefaults] setFloat:0 forKey:@"CSVolumePosition"];
    CSPlayerController *player = [[CSPlayerController alloc] init];
    CSDeckView *deck = [player deck];
    [player showDeck];
    Pump(0.3);

    Section("the window");
    NSWindow *window = [player window];
    OK([window isKindOfClass:[CSDeckWindow class]] && [(CSDeckWindow *)window handleView] != nil,
       @"the deck has the leather handle for a title bar");
    NSSize size = [window frame].size;
    OK(size.width == CS_DECK_WIDTH && size.height == CS_DECK_HEIGHT + CS_HANDLE_HEIGHT,
       @"sized to the handle and the deck (%.0f x %.0f)", size.width, size.height);
    NSRect before = [window frame];
    NSRect saved = NSMakeRect(before.origin.x, before.origin.y, 800, 464);
    [window setFrame:saved display:NO];
    OK(NSEqualSizes([window frame].size, size) && NSMaxY([window frame]) == NSMaxY(saved),
       @"a frame saved at another size keeps its top edge and takes the deck's");
    [window setFrame:before display:NO];
    OK([window canBecomeKeyWindow] && [window canBecomeMainWindow], @"it can be key and main");

    Section("loading");
    OK([player loadURL:song play:NO], @"a tape goes in");
    OK([player hasTape] && ![player isPlaying], @"stopped");
    OK([deck tapeLoaded] && [[window title] length] > 0 && ![[window title] isEqualToString:@"Cassette"],
       @"the label is written and the handle shows it (%@)", [window title]);
    OK(![player reelsSpinning] && ![deck hubHasSpinAnimation:0], @"a stopped deck has no animation attached");

    Section("battery");
    CSSetPowerSourceOverride(CSPowerBattery, YES);
    [player play];
    Pump(0.3);
    OK([player isPlaying], @"playing");
    BOOL active = [NSApp isActive];
    if (!active) {
        [NSApp activateIgnoringOtherApps:YES];
        Pump(0.5);
        active = [NSApp isActive];
    }
    if (active) {
        [player reevaluate];
        OK([player reelsSpinning] && [deck hubHasSpinAnimation:0] && [deck hubHasSpinAnimation:1],
           @"battery, frontmost and visible: reels turn");
        // Something else has to take the focus for this one to lose it.
        NSArray *finder = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"];
        if ([finder count]) [[finder objectAtIndex:0] activateWithOptions:0];
        else [NSApp deactivate];
        Pump(0.8);
        if (![NSApp isActive]) {
            OK(![player reelsSpinning] && ![deck hubHasSpinAnimation:0] && ![deck hubHasSpinAnimation:1],
               @"battery, in the background: reels stop and the animations are removed");
            OK([player isPlaying], @"while the music plays on");
        } else {
            printf("   SKIP: could not put the test in the background\n");
        }
    } else {
        printf("   SKIP: could not bring the test to the front\n");
    }
    [[player window] miniaturize:nil];
    Pump(0.8);
    OK([[player window] isMiniaturized], @"a borderless window still minimises");
    [player reevaluate];
    OK(![player reelsSpinning] && ![deck hubHasSpinAnimation:0], @"battery, minimised: reels still");

    Section("AC");
    CSSetPowerSourceOverride(CSPowerAC, YES);
    [player reevaluate];
    OK([player reelsSpinning] && [deck hubHasSpinAnimation:0] && [deck hubHasSpinAnimation:1],
       @"AC, minimised and in the background: reels turn");
    double pl = [deck hubSpinPeriod:0], pr = [deck hubSpinPeriod:1];
    OK(pl > pr && Near(pl / pr, CS_FULL_RADIUS_MM / CS_HUB_RADIUS_MM, 0.05),
       @"the full left reel turns slower than the empty right one (%.2f s vs %.2f s per turn)", pl, pr);
    [[player window] deminiaturize:nil];
    Pump(0.8);
    [player reevaluate];
    OK([player reelsSpinning], @"AC, restored: reels turn");

    Section("transport");
    [player pause];
    OK(![player isPlaying] && ![player reelsSpinning] && ![deck hubHasSpinAnimation:0],
       @"pause stops the reels even on AC");
    [player pause];
    OK([player isPlaying] && [player reelsSpinning], @"pressing Pause again releases it");
    [player stop];
    OK(![player isPlaying] && ![player reelsSpinning], @"stop");

    Section("the counter");
    // The fixture is two seconds long. The counter used to show the position
    // within the file, so it could never have got past 001.
    [player play];
    Pump(3.4);
    OK([deck counter] >= 2 && [deck counter] <= 4,
       @"after 3.4 s of a 2 s loop the counter reads %03lu", (unsigned long)[deck counter]);
    [player stop];
    OK([deck counter] == 0, @"stop puts it back to 000");

    Section("closing the window");
    [player play];
    [[player window] performClose:nil];
    Pump(0.3);
    OK([player isPlaying] && ![player reelsSpinning], @"closed: the music plays, nothing animates");
    [player showDeck];
    OK([player reelsSpinning], @"reopened on AC: reels turn again");
    [player stop];

    Section("sleep pauses the tape");
    // A tape playing when the machine goes to sleep comes back paused: a wake
    // nobody meant -- a mouse nudged in the night -- must not start the music
    // again and hold the machine awake. And the deck has to show it, not go on
    // with PLAY held down and the reels turning over silence.
    [player play];
    Pump(0.3);
    NSNotificationCenter *workspace = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspace postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    double slept = [[player engine] elapsed];
    [workspace postNotificationName:NSWorkspaceDidWakeNotification object:nil];
    Pump(0.3);
    OK(![player isPlaying], @"a tape playing at sleep is still paused after the wake");
    OK(![player reelsSpinning] && ![deck hubHasSpinAnimation:0],
       @"and the reels stop with it, on AC as well");
    OK([[player valueForKey:@"_latched"] intValue] == CSKeyPause,
       @"the deck shows PAUSE held rather than PLAY");
    OK(Near([[player engine] elapsed], slept, 0.01),
       @"and the tape keeps its place (%.3f s, went to sleep at %.3f s)",
       [[player engine] elapsed], slept);
    [player pause];
    Pump(0.3);
    OK([player isPlaying] && [player reelsSpinning], @"pressing PAUSE again carries on");
    OK([[player engine] elapsed] > slept + 0.1, @"from where it was");
    [player stop];
    int stoppedKey = [[player valueForKey:@"_latched"] intValue];
    [workspace postNotificationName:NSWorkspaceWillSleepNotification object:nil];
    [workspace postNotificationName:NSWorkspaceDidWakeNotification object:nil];
    Pump(0.1);
    OK(![player isPlaying] && [[player valueForKey:@"_latched"] intValue] == stoppedKey,
       @"a stopped deck is left alone by a sleep");

    Section("eject");
    [player play];
    [player eject];
    Pump(0.4);
    OK(![player hasTape] && ![player isPlaying] && ![player reelsSpinning], @"the tape comes out and the music stops");
    OK(![deck tapeLoaded] && [[window title] isEqualToString:@"Cassette"], @"the deck shows an empty compartment");
    OK([[NSUserDefaults standardUserDefaults] objectForKey:@"CSLastTapeBookmark"] == nil,
       @"and an ejected tape is not put back in at the next launch");
    [player eject];
    Pump(1.5);
    NSWindow *sheet = [window attachedSheet];
    OK(sheet != nil, @"EJECT on an empty deck asks for a tape");
    if ([sheet isKindOfClass:[NSSavePanel class]]) {
        [(NSSavePanel *)sheet cancel:nil];
        Pump(0.8);
    }

    Section("restoring at launch");
    OK([player loadURL:song play:NO], @"a tape goes back in");
    CSPlayerController *next = [[CSPlayerController alloc] init];
    [next restoreLastTape];
    OK([next hasTape] && [[next deck] tapeLoaded], @"the next launch shows the tape at once");
    OK(![[next engine] hasTape], @"before its sound has been read");
    OK([[[next window] title] isEqualToString:[window title]], @"with the same label (%@)", [[next window] title]);
    Pump(0.3);
    OK([[next engine] hasTape] && ![next isPlaying], @"which follows a moment later, stopped");
    [next release];
    next = [[CSPlayerController alloc] init];
    [next restoreLastTape];
    [next play];
    OK([next isPlaying], @"Play straight away reads it on the spot and plays");
    [next stop];
    [[next window] orderOut:nil];
    [next release];

    // A file that cannot be played is refused, and whatever tape was in stays
    // in -- including one that is still being restored. It used to be dropped
    // before the new file was even tried, leaving a label on the deck for a
    // tape that was no longer there.
    NSURL *junk = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"not-audio.wav"]];
    [@"this is not a sound" writeToURL:junk atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    next = [[CSPlayerController alloc] init];
    [next restoreLastTape];
    OK(![next insertURL:junk error:NULL animated:NO], @"a file that is not audio is refused");
    OK([next hasTape] && [[next deck] tapeLoaded],
       @"and the tape being restored is still in the deck");
    Pump(0.3);
    // Compared as files rather than as spellings: the restored URL comes back
    // through bookmark resolution, which names /var as /private/var.
    NSString *readPath = [[[[next engine] URL] URLByResolvingSymlinksInPath] path];
    NSString *songPath = [[song URLByResolvingSymlinksInPath] path];
    OK([[next engine] hasTape] && [readPath isEqualToString:songPath],
       @"and is read a moment later, as it would have been (%@)", readPath);
    [[next window] orderOut:nil];
    [next release];

    TestBlockCue(junk);

    CSSetPowerSourceOverride(CSPowerUnknown, NO);
    if (previous && ![previous isEqual:[NSRunningApplication currentApplication]])
        [previous activateWithOptions:0];
    [previous release];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"CSVolumePosition"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"CSLastTapeBookmark"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"CSLastTapeTitle"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"CSLastTapeArtist"];
    return Finish("deck");
}

#pragma mark - snapshot

static BOOL WritePNG(CGImageRef image, NSString *path)
{
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease];
    NSData *png = [rep representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
    return [png writeToFile:path atomically:YES];
}

// The whole window as it stands: the handle with its title and buttons, over
// the deck. The window is never shown, so it draws as an inactive one does.
static CGImageRef CreateWindowImage(CSDeckWindow *window, CSDeckView *deck, CGFloat scale)
{
    NSView *handle = [window handleView];
    NSRect hb = [handle bounds];
    NSBitmapImageRep *rep = [handle bitmapImageRepForCachingDisplayInRect:hb];
    [handle cacheDisplayInRect:hb toBitmapImageRep:rep];
    CGImageRef deckImage = [deck createSnapshotImage];
    size_t w = (size_t)ceil(CS_DECK_WIDTH * scale);
    size_t h = (size_t)ceil((CS_DECK_HEIGHT + CS_HANDLE_HEIGHT) * scale);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    CGContextScaleCTM(c, scale, scale);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, CS_DECK_WIDTH, CS_DECK_HEIGHT), deckImage);
    CGContextDrawImage(c, CGRectMake(0, CS_DECK_HEIGHT, CS_DECK_WIDTH, CS_HANDLE_HEIGHT), [rep CGImage]);
    CGImageRelease(deckImage);
    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return image;
}

static int RunSnapshot(NSString *dir)
{
    [NSApplication sharedApplication];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    CGFloat scales[2] = { 1, 2 };
    int s;
    for (s = 0; s < 2; s++) {
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        CSDeckView *deck = [[CSDeckView alloc] initWithFrame:NSZeroRect];
        [deck setRenderScale:scales[s]];
        double built = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
        printf("   @%gx: all artwork drawn in %.0f ms\n", scales[s], built);
        CSDeckWindow *window = [[CSDeckWindow alloc] initWithDeckView:deck];
        [window setReleasedWhenClosed:NO];
        [deck setRenderScale:scales[s]];

        [deck setPowerSource:CSPowerAC];
        CGImageRef img = [deck createSnapshotImage];
        OK(WritePNG(img, [dir stringByAppendingFormat:@"/empty@%gx.png", scales[s]]), @"empty deck");
        CGImageRelease(img);
        img = CreateWindowImage(window, deck, scales[s]);
        OK(WritePNG(img, [dir stringByAppendingFormat:@"/window-empty@%gx.png", scales[s]]), @"empty window");
        CGImageRelease(img);

        [deck setTapeLoaded:YES title:@"Summer Nights ’79" artist:@"The Mixtape"];
        CSTapeState t = CSTapeStateAt(42, 180);
        [deck setLeftRadius:t.leftRadius rightRadius:t.rightRadius leftOmega:t.leftOmega rightOmega:t.rightOmega];
        [deck setCounter:42];
        [deck setDirection:t.direction lit:YES];
        [deck setLatchedKey:CSKeyPlay];
        [deck setVolumePosition:0.7f];
        img = [deck createSnapshotImage];
        OK(WritePNG(img, [dir stringByAppendingFormat:@"/playing@%gx.png", scales[s]]), @"playing");
        CGImageRelease(img);
        [window setTitle:@"The Mixtape — Summer Nights ’79"];
        img = CreateWindowImage(window, deck, scales[s]);
        OK(WritePNG(img, [dir stringByAppendingFormat:@"/window-playing@%gx.png", scales[s]]), @"playing window");
        CGImageRelease(img);

        t = CSTapeStateAt(1800 + 1350, 180);
        [deck setLeftRadius:t.leftRadius rightRadius:t.rightRadius leftOmega:t.leftOmega rightOmega:t.rightOmega];
        [deck setDirection:t.direction lit:YES];
        [deck setCounter:t.counter];
        [deck setLatchedKey:CSKeyPause];
        [deck setPowerSource:CSPowerBattery];
        [deck setTapeLoaded:YES title:@"a very long title for a field recording of rain on a tin roof, Tuesday"
                     artist:nil];
        [deck setVolumePosition:0.25f];
        img = [deck createSnapshotImage];
        OK(WritePNG(img, [dir stringByAppendingFormat:@"/reverse-paused@%gx.png", scales[s]]), @"reverse, paused, on battery");
        CGImageRelease(img);
        [window close];
        [window release];
        [deck release];
    }
    printf("   written to %s\n", [dir fileSystemRepresentation]);
    return Finish("snapshot");
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *cmd = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        NSString *arg = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;
        if ([cmd isEqualToString:@"unit"]) {
            TestPowerStrings();
            TestPolicy();
            TestTape();
            TestGeometry();
            TestArtworkCache();
            return Finish("unit");
        }
        if ([cmd isEqualToString:@"audio"])    return RunAudio(arg ? arg : @"build/fixtures");
        if ([cmd isEqualToString:@"deck"])     return RunDeck();
        if ([cmd isEqualToString:@"snapshot"]) return RunSnapshot(arg ? arg : @"build/shots");
        fprintf(stderr, "usage: cssuite unit | audio <dir> | deck | snapshot <dir>\n");
        return 2;
    }
}
