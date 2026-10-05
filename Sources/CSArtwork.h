#import <Cocoa/Cocoa.h>

// Everything the deck looks like, drawn procedurally with Core Graphics.
//
// There are no image files. Wood, brushed and spun aluminium, paper and plastic
// are generated per pixel from noise, then lit with gradients and shadows, at
// the exact resolution of the display, so the deck is as sharp on a Retina
// screen as on the Mac Pro's and nothing ships that has to be scaled.
//
// All of it is drawn ONCE, on the first launch; CSArtworkCache keeps the
// results for every launch after that. The deck view turns each drawing into
// the contents of a Core Animation layer and never draws again unless the
// tape or the display resolution changes. Spinning a reel is a rotation of a
// finished bitmap, composited by the GPU; no code of ours runs per frame.
//
// Coordinates are points, origin bottom-left, in the deck view's space. The
// cassette itself is drawn in millimetres to the IEC compact cassette
// dimensions and scaled by CS_PT_PER_MM.

#define CS_DECK_WIDTH        800.0
#define CS_CHEEK_WIDTH       44.0     // the walnut side panels
#define CS_DECK_HEIGHT       432.0
#define CS_HANDLE_HEIGHT     28.0     // the black leather panel that is the title bar
#define CS_HANDLE_BUTTONS_X  11.0     // where the close button starts on it
#define CS_WINDOW_CORNER     6.0
#define CS_PT_PER_MM         3.2

#define CS_SHELL_W_MM        100.4
#define CS_SHELL_H_MM        63.8
#define CS_HUB_SPACING_MM    42.5     // between the two hub centres
#define CS_HUB_Y_MM          34.0     // hub centres, above the shell's bottom edge
#define CS_WINDOW_R_MM       13.0     // the window's round ends, concentric with the hubs
#define CS_HUB_IMAGE_R_MM    11.6     // half the side of the hub bitmaps

typedef enum { CSKeyEject = 0, CSKeyPlay, CSKeyPause, CSKeyStop, CSKeyCount } CSKey;
typedef enum { CSLampReverse = 0, CSLampForward, CSLampAC, CSLampBattery, CSLampCount } CSLamp;

// ---- Geometry -----------------------------------------------------------
CGRect  CSDoorRect(void);              // outer edge of the compartment bezel
CGRect  CSWellRect(void);              // the recess, and the smoked door over it
CGRect  CSCassetteRect(void);
CGPoint CSHubCentre(int side);         // 0 = left (supply), 1 = right (take-up); deck space
CGPoint CSHubCentreInCassette(int side);
CGRect  CSKeyRect(CSKey key);          // the key's bitmap, which includes its shadow
CGRect  CSKeyHitRect(CSKey key);       // where a click presses it
CGPoint CSKnobCentre(void);
CGFloat CSKnobRadius(void);            // what can be grabbed
CGFloat CSKnobPointerRadius(void);     // half the side of the pointer bitmap
CGRect  CSCounterDigitRect(int index); // 0 = hundreds
CGRect  CSLampRect(CSLamp lamp);       // the lamp's bitmap, including its glow

// ---- Drawings -----------------------------------------------------------
// Each returns a +1 CGImageRef at `scale` pixels per point.

// The fixed deck: walnut cheeks, brushed faceplate, compartment and well (with
// the empty-deck spindles), key slots, counter bezel, lamp sockets, printing,
// and the volume knob's body and scale.
CGImageRef CSCreateDeckImage(CGFloat scale);

// The soft shadow the cassette casts on the well behind it.
CGRect     CSCassetteShadowRect(void);
CGImageRef CSCreateCassetteShadowImage(CGFloat scale);

// The inside of the cassette, seen past the reels through the window.
CGImageRef CSCreateCassetteInteriorImage(CGFloat scale);

// The shell and label, with the window cut out. `title` and `artist` are
// handwritten on the label; either may be nil.
CGImageRef CSCreateCassetteFaceImage(CGFloat scale, NSString *title, NSString *artist);

// The same in two steps: everything but the writing, which is the same for
// every tape and so can be kept, and then the writing added to a copy of it.
CGImageRef CSCreateBlankCassetteFaceImage(CGFloat scale);
CGImageRef CSCreateWrittenCassetteFaceImage(CGImageRef blank, CGFloat scale,
                                            NSString *title, NSString *artist);

// A tape pack of the given radius, lit from the upper left. Rotationally
// symmetric in shape, with the lighting fixed to the room: it never rotates.
CGImageRef CSCreatePackImage(CGFloat radiusPt, CGFloat scale);

// The hub and the deck spindle turning it: the only bitmap that rotates. It is
// deliberately lit flat; the fixed highlights are in the shine overlay above.
CGImageRef CSCreateHubImage(CGFloat scale);
CGImageRef CSCreateHubShineImage(CGFloat scale);

CGImageRef CSCreateDoorGlassImage(CGFloat scale);
CGImageRef CSCreateKeyImage(CSKey key, BOOL down, CGFloat scale);
CGImageRef CSCreateKnobPointerImage(CGFloat scale);
CGImageRef CSCreateCounterDigitImage(int digit, CGFloat scale);
CGImageRef CSCreateLampImage(CSLamp lamp, BOOL lit, CGFloat scale);

// The carrying handle across the top of the window, CS_DECK_WIDTH by
// CS_HANDLE_HEIGHT: black padded leatherette, stitched along both edges.
CGImageRef CSCreateHandleImage(CGFloat scale);

// The window's title, debossed into the handle and centred on it. Drawn in
// the handle's own coordinates; dimmer when the window is not active.
void CSDrawHandleTitle(CGContextRef c, NSString *title, BOOL active, CGFloat maxWidth);
