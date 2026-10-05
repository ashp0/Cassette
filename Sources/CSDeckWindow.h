#import <Cocoa/Cocoa.h>

// The deck's window: a black leather carrying handle where the title bar would
// be, and the cabinet below it.
//
// Mavericks has no public way to restyle a title bar. The ways it was done at
// the time -- adding views to the window's private frame view, or swizzling its
// drawing -- depend on AppKit internals that change between releases. So this
// window has no system title bar at all (it is borderless), draws the handle
// itself, and puts the real close, minimise and zoom buttons on it. It then
// supplies, with public API, the few things the system frame used to:
//
//   * it can become the key and main window,
//   * Close and Minimize work from the buttons, the menus, ⌘W and ⌘M,
//   * dragging the handle moves the window, and never above the menu bar,
//   * double-clicking the handle minimises it, if the user has asked for that
//     in System Preferences,
//   * the handle's title dims when the window is not active.
//
// The top corners are rounded and transparent, the bottom ones square, as on
// every standard Mavericks window, and the system draws the shadow from what is
// opaque, so the outline and shadow match one.
@interface CSDeckWindow : NSWindow

// `deck` fills the window below the handle; the window is sized to fit both,
// and stays that size.
- (id)initWithDeckView:(NSView *)deck;

// Moves the window with the mouse until the button comes up, the way dragging
// a title bar does. The handle uses it, and the deck does for a click on the
// cabinet rather than on one of its controls.
- (void)trackMoveFromEvent:(NSEvent *)event;

// The handle, for tests.
@property (nonatomic, readonly) NSView *handleView;

@end
