#import <Cocoa/Cocoa.h>
#import "CSArtwork.h"
#import "CSPower.h"

@class CSDeckView;

@protocol CSDeckViewDelegate <NSObject>
- (void)deckView:(CSDeckView *)deck pressedKey:(CSKey)key;
// The knob moved. `finished` is YES when the gesture ends (mouse up, a scroll
// step), which is when the setting is worth saving.
- (void)deckView:(CSDeckView *)deck movedVolumeKnobTo:(float)position finished:(BOOL)finished;
- (BOOL)deckView:(CSDeckView *)deck canAcceptDroppedURL:(NSURL *)url;
- (void)deckView:(CSDeckView *)deck droppedURL:(NSURL *)url;
// A click in the empty compartment: asking for a tape, the way pushing one
// into the door would.
- (void)deckViewClickedEmptyCompartment:(CSDeckView *)deck;
// The mouse went down on the cabinet itself -- wood, faceplate, printing --
// rather than on a control, so the window may be dragged by it.
- (void)deckView:(CSDeckView *)deck mouseDownOnCabinet:(NSEvent *)event;
@end

// The deck, as a tree of Core Animation layers hosted by one view.
//
// Nothing is drawn in -drawRect:. Every part is a finished bitmap from
// CSArtwork set as a layer's contents, and every change of state is a change
// of which bitmap a layer shows, or of its transform. The reels turn by a
// repeating rotation animation that the window server's compositor runs
// without waking this process; stopping them removes the animation outright,
// so a still deck costs exactly nothing per frame.
@interface CSDeckView : NSView

@property (nonatomic, assign) id<CSDeckViewDelegate> delegate;

// An empty compartment, or a cassette with this writing on its label.
// Animated, the cassette settles into the well as it goes in and rises out of
// it when ejected; the animation runs once and is then gone.
- (void)setTapeLoaded:(BOOL)loaded title:(NSString *)title artist:(NSString *)artist;
- (void)setTapeLoaded:(BOOL)loaded title:(NSString *)title artist:(NSString *)artist
             animated:(BOOL)animated;
@property (nonatomic, readonly) BOOL tapeLoaded;

// The key held down by its latch (Play while playing, Pause while paused), or
// CSKeyCount for none.
- (void)setLatchedKey:(CSKey)key;

@property (nonatomic) float volumePosition;          // the knob, 0 to 1

- (void)setCounter:(NSUInteger)value;               // shows value mod 1000
@property (nonatomic, readonly) NSUInteger counter;
- (void)setDirection:(int)direction lit:(BOOL)lit;  // the auto-reverse lamps
- (void)setPowerSource:(CSPowerSource)source;       // the AC / BATT lamps

// Pack radii in millimetres and reel speeds in radians per second (positive is
// counter-clockwise). Cheap to call often: a pack is redrawn only when its
// edge has moved by half a pixel, and a spinning reel is only re-timed when
// its speed has changed by more than 1.5%.
- (void)setLeftRadius:(double)left rightRadius:(double)right
            leftOmega:(double)leftOmega rightOmega:(double)rightOmega;

@property (nonatomic, readonly) BOOL reelsSpinning;
- (void)setReelsSpinning:(BOOL)spinning;

// For drawing off screen, where there is no window to say what resolution the
// display is. In a window, the window's backing scale is used automatically.
- (void)setRenderScale:(CGFloat)scale;

// The deck as it stands, as a +1 image. Reels are drawn at their resting
// angles; a running animation is not captured.
- (CGImageRef)createSnapshotImage CF_RETURNS_RETAINED;

// Test seams.
- (BOOL)hubHasSpinAnimation:(int)side;
- (double)hubSpinPeriod:(int)side;   // seconds per revolution of the running animation, 0 if none

@end
