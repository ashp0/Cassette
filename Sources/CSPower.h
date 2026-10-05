#import <Foundation/Foundation.h>

// Where the machine draws its power, and what the reels do about it.

// Three states, not two. A machine that will not say is treated as running on
// battery: an unreadable answer must never switch the more expensive behaviour
// on. That is a decision, so it is written down rather than left to fall out
// of an enum that happens to start at zero.
typedef enum {
    CSPowerUnknown = 0,
    CSPowerBattery = 1,
    CSPowerAC      = 2
} CSPowerSource;

// IOKit's spellings ("AC Power", "Battery Power") and the ones a person types at
// a shell ("ac", "battery"). Anything else, including "UPS Power", is Unknown.
CSPowerSource CSPowerSourceFromString(NSString *s);

// What the machine says right now. Not cached: it is asked only when something
// has changed (focus, visibility, play state, a power notification), which is a
// handful of times a minute at the very most.
//
// `-CSPowerState battery` (or `ac`) on the command line, or CASSETTE_POWER in
// the environment, pins the answer. A Mac Pro has no battery and always reports
// AC, so this is the only way to see the battery behaviour on one:
//
//     open Cassette.app --args -CSPowerState battery
CSPowerSource CSCurrentPowerSource(void);

// Test seam: pin the answer from code, overriding the machine and the defaults.
void CSSetPowerSourceOverride(CSPowerSource source, BOOL enabled);

// Runs `handler` on the main queue each time the machine switches between wall
// power and battery. The kernel posts this only on a change of source, not as
// the battery drains, so it costs nothing while nothing happens. Returns a
// token for CSStopObservingPowerSource, or -1 if registration failed.
int  CSObservePowerSource(dispatch_block_t handler);
void CSStopObservingPowerSource(int token);

// What the deck window is doing, reduced to the facts the policy needs.
typedef struct {
    BOOL playing;         // audio is running: not paused, not stopped, not empty
    BOOL windowOpen;      // the deck window exists; it has not been closed
    BOOL windowOnScreen;  // some of it can be seen: not minimised, not hidden,
                          //   not on another Space, not completely covered
    BOOL appActive;       // Cassette is the frontmost application
} CSUIState;

// Whether the reels (and the counter that moves with them) should animate.
//
//   On AC:       whenever the tape is playing.
//   On battery:  only while the tape is playing AND Cassette is frontmost AND
//                its window can be seen. In the background the reels hold still
//                and the only work left is the audio itself.
//   Unknown:     as battery.
//
// A closed window has nothing to animate in either case. The music keeps
// playing; reopening the window (Dock icon, or Window > Cassette Deck) brings
// the reels back.
BOOL CSReelsShouldSpin(CSPowerSource power, CSUIState state);
