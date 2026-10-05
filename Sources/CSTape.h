#import <Foundation/Foundation.h>

// The tape the deck pretends to be playing.
//
// The audio file loops by itself; nothing here affects what is heard. This is
// the arithmetic that decides what the reels LOOK like, and it is kept pure so
// that it can be asserted on without a window, a sound card or a clock.
//
// The model is a real C60 in an auto-reverse deck. Tape runs at 1 7/8 inches a
// second, a side holds thirty minutes, and it is wound on hubs 22 mm across.
// Two consequences a viewer can see:
//
//   * The packs trade size as the side plays, conserving the area of tape
//     between them, so the supply reel empties and the take-up reel fills.
//   * Each reel turns at tape speed divided by its own radius. The empty hub
//     turns more than twice as fast as the full one, as it does on a real deck.
//
// A side is a whole number of passes through the file, at least thirty minutes
// long. At the end of a side the deck reverses, exactly on a loop boundary, so
// the tape never has to jump back to the start: the packs only ever move
// smoothly, however short or long the file is.

#define CS_TAPE_SPEED_MM_S    47.625   // 1 7/8 in/s
#define CS_HUB_RADIUS_MM      11.0     // where the tape winds on
#define CS_FULL_RADIUS_MM     24.2     // one C60 side, all on one hub
#define CS_SIDE_SECONDS       1800.0   // thirty minutes

typedef struct {
    NSUInteger counter;    // what the three-digit counter shows; see below
    double passSeconds;    // seconds into the current play-through of the file
    double sidePosition;   // 0 at the start of a side, approaching 1 at its end
    int    direction;      // +1 forward (left reel to right), -1 reverse
    double leftRadius;     // tape pack radii, millimetres
    double rightRadius;
    double leftOmega;      // reel speeds, radians per second; positive is
    double rightOmega;     //   counter-clockwise as seen from the front
} CSTapeState;

// How many play-throughs of a file of this length make up one side.
NSUInteger CSPassesPerSide(double passSeconds);

// Everything above, for a tape that has played `elapsedSeconds` in total since
// it was last rewound, holding a file `passSeconds` long. A length that is not
// positive and finite is treated as unknown, and a side is then thirty minutes.
//
// The counter is whole seconds of tape played since the last rewind, modulo
// 1000. It carries on across loops, the way a mechanical counter geared to the
// reels knows nothing about where a song starts. It used to be the position
// within the current pass, which never left 000 for a file shorter than a
// second and reset every few seconds for a short loop -- a counter that looked
// broken exactly when a loop player is most likely to be used.
//
// It counts up in both directions of an auto-reverse deck. A real counter
// would run backwards on the reverse side, and read as a fault if it did.
CSTapeState CSTapeStateAt(double elapsedSeconds, double passSeconds);
