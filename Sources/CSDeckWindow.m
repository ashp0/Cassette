#import "CSDeckWindow.h"
#import "CSArtwork.h"
#import "CSArtworkCache.h"

#pragma mark - The backdrop

// An opaque silhouette of the deck, drawn once into the window's own backing
// store underneath it.
//
// The deck is a layer-hosting view. On 10.9, where the rest of this window is
// not layer-backed, its layers are composited as a surface of their own over
// the window, and a borderless window's shape -- what casts its shadow, which
// clicks are the window's -- is taken from the window's pixels. This puts the
// cabinet's shape into those pixels whichever way the layers are composited.
@interface CSBackdropView : NSView
{
    NSRect _solid;
}
- (id)initWithFrame:(NSRect)frame solidRect:(NSRect)solid;
@end

@implementation CSBackdropView

- (id)initWithFrame:(NSRect)frame solidRect:(NSRect)solid
{
    self = [super initWithFrame:frame];
    if (self) _solid = solid;
    return self;
}

- (BOOL)isOpaque { return NO; }

- (void)drawRect:(NSRect)dirty
{
    [[NSColor blackColor] set];
    NSRectFill(NSIntersectionRect(dirty, _solid));
    // As Apple's own shaped-window sample does: with the shape drawn, have the
    // window server work the shadow out again from it.
    [[self window] invalidateShadow];
}

@end

#pragma mark - The handle

@interface CSHandleView : NSView
- (void)windowStateChanged;
@end

@implementation CSHandleView
{
    CGImageRef      _image;
    CGFloat         _imageScale;
    NSArray        *_buttons;
    NSTrackingArea *_tracking;
    BOOL            _mouseInGroup;
}

- (void)dealloc
{
    CGImageRelease(_image);
    [_buttons release];
    [_tracking release];
    [super dealloc];
}

- (void)setButtons:(NSArray *)buttons
{
    [_buttons release];
    _buttons = [buttons copy];
    [self updateTrackingAreas];
}

// The corners are transparent.
- (BOOL)isOpaque { return NO; }
// Dragging is done by the window, by hand, so that it can be kept clear of the
// menu bar.
- (BOOL)mouseDownCanMoveWindow { return NO; }
// The first click on an inactive window's handle moves it, as a title bar does.
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)drawRect:(NSRect)dirty
{
    CGFloat scale = [[self window] backingScaleFactor];
    if (scale < 1) scale = 1;
    if (!_image || scale != _imageScale) {
        CGImageRelease(_image);
        _image = CSArtworkCopy(@"handle", scale, ^{ return CSCreateHandleImage(scale); });
        _imageScale = scale;
    }
    CGContextRef c = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
    // NULL only if the leather could not be drawn at all -- an allocation the
    // machine refused -- and then there is nothing to put under the title; the
    // next draw asks again.
    if (_image) CGContextDrawImage(c, NSRectToCGRect([self bounds]), _image);

    NSWindow *w = [self window];
    BOOL active = [w isMainWindow] || [w isKeyWindow];
    // Clear of the buttons on the left, and the same margin on the right.
    CGFloat buttonsEnd = 0;
    for (NSView *b in _buttons) buttonsEnd = MAX(buttonsEnd, NSMaxX([b frame]));
    CGFloat maxWidth = [self bounds].size.width - 2 * (buttonsEnd + 24);
    CSDrawHandleTitle(c, [w title], active, maxWidth);
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self setNeedsDisplay:YES];
}

// Active or not, the buttons change colour along with the title.
- (void)windowStateChanged
{
    [self setNeedsDisplay:YES];
    for (NSView *b in _buttons) [b setNeedsDisplay:YES];
}

#pragma mark Moving the window

// The same preference the system title bar honours: System Preferences >
// Dock > "Double-click a window's title bar to minimise". It is on unless
// the user has turned it off.
static BOOL CSMinimiseOnDoubleClick(void)
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleMiniaturizeOnDoubleClick"];
    return v ? [v boolValue] : YES;
}

- (void)mouseDown:(NSEvent *)event
{
    CSDeckWindow *window = (CSDeckWindow *)[self window];
    if ([event clickCount] == 2) {
        if (CSMinimiseOnDoubleClick()) [window performMiniaturize:self];
        return;
    }
    [window trackMoveFromEvent:event];
}

#pragma mark The window buttons

// The standard buttons show their ×, – and + when the pointer is over any of
// the three, not just the one it is on. They find out by asking the view they
// sit in; the system title bar answers, and this view answers in its place.
// Defining the method is all it takes; nothing private is called.
- (BOOL)_mouseInGroup:(NSButton *)button
{
    (void)button;
    return _mouseInGroup;
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    [_tracking release];
    _tracking = nil;
    NSRect group = NSZeroRect;
    for (NSView *b in _buttons) group = NSUnionRect(group, [b frame]);
    if (NSIsEmptyRect(group)) return;
    _tracking = [[NSTrackingArea alloc] initWithRect:group
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
        owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)setMouseInGroup:(BOOL)inside
{
    _mouseInGroup = inside;
    for (NSButton *b in _buttons) [b setNeedsDisplay:YES];
}

- (void)mouseEntered:(NSEvent *)event { [self setMouseInGroup:YES]; }
- (void)mouseExited:(NSEvent *)event  { [self setMouseInGroup:NO]; }

@end

#pragma mark - The window

@implementation CSDeckWindow
{
    CSHandleView *_handle;
    NSSize        _size;
}

- (NSView *)handleView { return _handle; }

- (id)initWithDeckView:(NSView *)deck
{
    NSSize deckSize = [deck frame].size;
    NSRect content = NSMakeRect(0, 0, deckSize.width, deckSize.height + CS_HANDLE_HEIGHT);
    // Borderless, but still closable and miniaturisable: those two bits are
    // what let -close and -miniaturize: work on a window with no title bar.
    self = [super initWithContentRect:content
                            styleMask:NSBorderlessWindowMask | NSClosableWindowMask |
                                      NSMiniaturizableWindowMask
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (!self) return nil;
    _size = content.size;

    [self setOpaque:NO];
    [self setBackgroundColor:[NSColor clearColor]];
    [self setHasShadow:YES];

    NSRect deckFrame = NSMakeRect(0, 0, deckSize.width, deckSize.height);
    NSView *root = [[[CSBackdropView alloc] initWithFrame:content solidRect:deckFrame] autorelease];
    [deck setFrame:deckFrame];
    [root addSubview:deck];

    _handle = [[[CSHandleView alloc] initWithFrame:
        NSMakeRect(0, deckSize.height, deckSize.width, CS_HANDLE_HEIGHT)] autorelease];
    [root addSubview:_handle];

    // The real buttons, as a titled window would have them, set into the
    // leather at the left, the same distance apart as on a title bar.
    NSUInteger mask = NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask;
    NSWindowButton kinds[3] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton };
    NSMutableArray *buttons = [NSMutableArray array];
    CGFloat x = CS_HANDLE_BUTTONS_X;
    int i;
    for (i = 0; i < 3; i++) {
        NSButton *b = [NSWindow standardWindowButton:kinds[i] forStyleMask:mask];
        if (!b) continue;
        NSRect f = [b frame];
        f.origin = NSMakePoint(x, floor((CS_HANDLE_HEIGHT - f.size.height) / 2));
        [b setFrame:f];
        // The deck is a fixed size, so there is nothing to zoom to: greyed,
        // as on any window that cannot be resized.
        if (kinds[i] == NSWindowZoomButton) [b setEnabled:NO];
        [_handle addSubview:b];
        [buttons addObject:b];
        x += f.size.width + 6;
    }
    [_handle setButtons:buttons];

    [self setContentView:root];
    return self;
}

// A borderless window declines both by default.
- (BOOL)canBecomeKeyWindow  { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }

// The system versions of these check for a title bar button and beep when
// there is none; these do what the buttons would have done.
- (void)performClose:(id)sender
{
    id delegate = [self delegate];
    if ([delegate respondsToSelector:@selector(windowShouldClose:)] &&
        ![delegate windowShouldClose:self])
        return;
    [self close];
}

- (void)performMiniaturize:(id)sender
{
    [self miniaturize:sender];
}

- (void)performZoom:(id)sender
{
    (void)sender;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL action = [item action];
    if (action == @selector(performClose:) || action == @selector(performMiniaturize:)) return YES;
    if (action == @selector(performZoom:)) return NO;
    return [super validateMenuItem:item];
}

#pragma mark Size and place

// The deck is one size. A frame saved by an earlier version, whose title bar
// was a different height, keeps its top-left corner and takes this size.
- (void)setFrame:(NSRect)frame display:(BOOL)flag
{
    if (_size.width > 0 && !NSEqualSizes(frame.size, _size)) {
        frame.origin.y = NSMaxY(frame) - _size.height;
        frame.size = _size;
    }
    [super setFrame:frame display:flag];
}

// Titled windows are kept with their title bar below the menu bar; borderless
// ones are not, so the handle could be dragged up behind it and lost. The top
// is held inside the visible area of whichever screen the window is on.
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen
{
    if (!screen) screen = [self screen];
    if (!screen) screen = [NSScreen mainScreen];
    NSRect visible = [screen visibleFrame];
    if (NSMaxY(frame) > NSMaxY(visible)) frame.origin.y = NSMaxY(visible) - frame.size.height;
    return frame;
}

- (void)trackMoveFromEvent:(NSEvent *)event
{
    (void)event;
    NSPoint start = [NSEvent mouseLocation];
    NSPoint origin = [self frame].origin;
    for (;;) {
        NSEvent *next = [self nextEventMatchingMask:NSLeftMouseDraggedMask | NSLeftMouseUpMask];
        if ([next type] == NSLeftMouseUp) break;
        NSPoint now = [NSEvent mouseLocation];
        NSRect frame = [self frame];
        frame.origin = NSMakePoint(origin.x + now.x - start.x, origin.y + now.y - start.y);
        [self setFrameOrigin:[self constrainFrameRect:frame toScreen:[self screen]].origin];
    }
}

#pragma mark Title and state

- (void)setTitle:(NSString *)title
{
    [super setTitle:title];
    [_handle setNeedsDisplay:YES];
}

- (void)becomeKeyWindow  { [super becomeKeyWindow];  [_handle windowStateChanged]; }
- (void)resignKeyWindow  { [super resignKeyWindow];  [_handle windowStateChanged]; }
- (void)becomeMainWindow { [super becomeMainWindow]; [_handle windowStateChanged]; }
- (void)resignMainWindow { [super resignMainWindow]; [_handle windowStateChanged]; }

@end
