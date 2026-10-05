#import <Cocoa/Cocoa.h>
#import "CSDeckView.h"

@class CSAudioEngine;

// The deck window and everything behind it: the audio engine, the transport
// logic, and the policy that decides when the reels may move.
//
// That policy (CSReelsShouldSpin) is re-decided only when one of its inputs
// changes -- play state, focus, visibility, power source -- each of which
// arrives as a notification. Nothing polls. While the reels are still, the
// only timers in the process are the audio engine's hourly bookkeeping one;
// while they turn, there is one more, which moves the counter and the tape
// packs once a second.
@interface CSPlayerController : NSWindowController <NSWindowDelegate, CSDeckViewDelegate>

@property (nonatomic, readonly) CSAudioEngine *engine;
@property (nonatomic, readonly) CSDeckView *deck;
@property (nonatomic, readonly) BOOL reelsSpinning;

- (void)showDeck;
- (void)chooseTape;                          // the Open panel, as a sheet
- (BOOL)loadURL:(NSURL *)url play:(BOOL)play; // reports failure to the user itself
- (void)restoreLastTape;                     // quietly; stays stopped; see the .m
- (void)finishRestoringTape;                 // reads a restored tape's sound now

- (void)play;
- (void)pause;             // the Pause key: engages, or releases if engaged
- (void)togglePlayPause;   // Space
- (void)stop;              // and rewind
- (void)eject;             // the tape comes out; with none in, asks for one
- (void)nudgeVolume:(float)delta;

- (BOOL)hasTape;
- (BOOL)isPlaying;

- (void)saveState;

// Re-decides whether the reels turn. Public so tests can drive it.
- (void)reevaluate;

@end
