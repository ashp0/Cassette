#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

// One audio file, played in an endless loop.
//
// Built on the system's audio-file-player unit feeding the default output
// device, which is the least work OS X can be asked to do to play a file:
//
//   * The file is streamed from disk by the player's own reader thread and
//     decoded as it goes. Nothing is loaded whole, so a three-hour recording
//     costs the same memory as a three-second one.
//   * Looping is done by the player itself, sample-accurately. There is no
//     gap, no click, and no code of ours running at the loop point.
//   * The device is asked for a 4096-frame I/O buffer, about 93 ms, so the
//     audio thread wakes roughly eleven times a second instead of eighty-six.
//     Nothing here needs low latency, and every wakeup costs battery.
//   * The main thread is not involved in playback at all, apart from one
//     bookkeeping timer that fires about once an hour (see -topUpSchedule).
//
// All methods are for the main thread.

// Posted on the default centre, with the engine as the object, when the engine
// pauses without having been asked to: the machine is going to sleep. A tape
// playing at sleep comes back paused, so a wake nobody meant -- a mouse nudged
// in the night -- neither starts the music again nor, with it, holds the
// machine awake behind a dark screen. The position is kept, as by -pause.
extern NSString *const CSAudioEngineDidPauseForSleepNotification;

@interface CSAudioEngine : NSObject

// Uniform type identifiers the system can decode, for an Open panel.
+ (NSArray *)readableTypes;

// A quick check by file extension, for deciding whether to accept a drag.
// The real test is -loadURL:error:.
+ (BOOL)canProbablyReadURL:(NSURL *)url;

- (id)init;                         // plays through the default output device
- (id)initForOfflineRendering;      // test seam: no device; see below

// Puts a tape in the deck, rewound and stopped. If the file cannot be played,
// returns NO with a presentable error and leaves the current tape untouched.
- (BOOL)loadURL:(NSURL *)url error:(NSError **)error;

- (BOOL)play;       // NO if the output device refused to start
- (void)pause;      // keeps the position
- (void)stop;       // pauses and rewinds to the start of the file
- (void)eject;      // empties the deck

@property (nonatomic, readonly) BOOL hasTape;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) NSURL *URL;
@property (nonatomic, readonly) NSString *title;     // from the file's tags, else its name
@property (nonatomic, readonly) NSString *artist;    // from the file's tags, or nil
@property (nonatomic, readonly) double duration;     // seconds in one pass through the file

// Seconds played since the tape was last rewound, counting every pass. Counted
// from the frames the player has actually rendered, so it cannot drift from
// what is heard.
- (double)elapsed;

// Linear output gain, 0 to 1.
@property (nonatomic) float volume;

// ---- Test seams --------------------------------------------------------

// Caps the number of frames scheduled as one region, so a test can cross
// several region boundaries in a fraction of a second. 0 restores the default.
+ (void)setMaximumRegionFramesForTesting:(SInt64)frames;

// Makes the output refuse to start, as a device that is not ready after a wake
// can, so the recovery from that can be driven without one.
+ (void)setOutputStartFailsForTesting:(BOOL)fails;

// Offline instances only: pulls the next `frames` frames from the player, as
// the output device would. Rendering is what advances the player's clock.
- (OSStatus)renderOffline:(float *)left right:(float *)right frames:(UInt32)frames;

// Keeps more than one region of audio scheduled ahead of the play head. Runs
// by itself on a timer while playing; exposed so a test can drive it.
- (void)topUpSchedule;

- (UInt32)passesPerRegion;
- (SInt64)framesPerPass;
- (double)sampleRate;

@end
