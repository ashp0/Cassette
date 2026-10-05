#import "CSTape.h"
#include <math.h>

static BOOL CSKnownLength(double seconds)
{
    return seconds > 0 && isfinite(seconds);
}

NSUInteger CSPassesPerSide(double passSeconds)
{
    if (!CSKnownLength(passSeconds)) return 1;
    // The epsilon keeps a file that is exactly a divisor of thirty minutes
    // from being rounded up to one pass more than it needs.
    double n = ceil(CS_SIDE_SECONDS / passSeconds - 1e-9);
    if (n < 1) n = 1;
    // A file of a few samples would otherwise ask for billions of passes. The
    // side is then a hair longer than thirty minutes, which nobody can see.
    if (n > 1e9) n = 1e9;
    return (NSUInteger)n;
}

CSTapeState CSTapeStateAt(double elapsed, double passSeconds)
{
    CSTapeState s;
    if (!(elapsed >= 0) || !isfinite(elapsed)) elapsed = 0;

    BOOL known = CSKnownLength(passSeconds);
    double side = known ? (double)CSPassesPerSide(passSeconds) * passSeconds
                        : CS_SIDE_SECONDS;

    double sides = floor(elapsed / side);
    double u = (elapsed - sides * side) / side;
    if (u < 0) u = 0;
    if (u >= 1) u = 0;   // floating-point landing exactly on a boundary

    s.sidePosition = u;
    s.direction = (fmod(sides, 2.0) < 1.0) ? 1 : -1;

    // Fraction of the tape wound onto the right-hand reel. Forward, it fills;
    // in reverse the same reel empties again, so a side boundary is continuous.
    double onRight = (s.direction > 0) ? u : 1.0 - u;

    double hub2 = CS_HUB_RADIUS_MM * CS_HUB_RADIUS_MM;
    double tape = CS_FULL_RADIUS_MM * CS_FULL_RADIUS_MM - hub2;   // area / pi
    s.leftRadius  = sqrt(hub2 + (1.0 - onRight) * tape);
    s.rightRadius = sqrt(hub2 + onRight * tape);

    // Both reels turn the same way. Seen from the front with the head at the
    // bottom, forward play draws tape down the outside of the left pack, along
    // the bottom and up the outside of the right one: counter-clockwise, both.
    s.leftOmega  = s.direction * CS_TAPE_SPEED_MM_S / s.leftRadius;
    s.rightOmega = s.direction * CS_TAPE_SPEED_MM_S / s.rightRadius;

    s.passSeconds = known ? fmod(elapsed, passSeconds) : elapsed;
    s.counter = (NSUInteger)fmod(floor(elapsed), 1000.0);
    return s;
}
