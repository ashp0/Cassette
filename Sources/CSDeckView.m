#import "CSDeckView.h"
#import "CSArtworkCache.h"
#import "CSTape.h"
#import <QuartzCore/QuartzCore.h>

#define CS_SPIN_KEY    @"spin"
#define CS_INSERT_KEY  @"insert"

// Every implicit animation off. State changes on this deck are mechanical --
// a key drops, a lamp lights -- and should happen on the frame they are made,
// not cross-fade over a quarter of a second at sixty frames a second.
static NSDictionary *CSNoActions(void)
{
    static NSDictionary *actions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // kCFNull is the NSNull singleton. Named through CoreFoundation, where
        // it has been since 10.2, rather than by the NSNull class, which has
        // moved between frameworks over the years and would bind to wherever
        // the build machine's SDK says it lives today.
        id none = (id)kCFNull;
        actions = [[NSDictionary alloc] initWithObjectsAndKeys:
            none, @"contents", none, @"bounds", none, @"position", none, @"hidden",
            none, @"transform", none, @"frame", none, @"sublayers", none, @"opacity",
            none, @"onOrderIn", none, @"onOrderOut", none, @"borderColor", nil];
    });
    return actions;
}

static CGFloat CSKnobRotation(float position)
{
    // The pointer is drawn pointing straight up; 0 is at seven o'clock and
    // full volume at five, clockwise.
    return (CGFloat)((135.0 - 270.0 * position) * M_PI / 180.0);
}

@implementation CSDeckView
{
    CALayer *_root;
    CALayer *_cassetteShadow;
    CALayer *_cassette;
    CALayer *_interior;
    CALayer *_pack[2];
    CALayer *_hub[2];
    CALayer *_shine[2];
    CALayer *_face;
    CALayer *_glass;
    CALayer *_key[CSKeyCount];
    CALayer *_pointer;
    CALayer *_digit[3];
    CALayer *_lamp[CSLampCount];
    CALayer *_dropGlow;

    CGImageRef _keyImage[CSKeyCount][2];
    CGImageRef _lampImage[CSLampCount][2];
    CGImageRef _digitImage[10];
    CGImageRef _blankFace;     // the label with nothing written on it

    CGFloat   _scale;
    BOOL      _loaded;
    NSString *_title;
    NSString *_artist;

    CSKey     _latched;
    CSKey     _pressed;
    BOOL      _pressedInside;
    BOOL      _pressedCompartment;
    BOOL      _trackingKnob;
    NSPoint   _knobStart;
    float     _knobStartPosition;
    float     _volume;

    NSUInteger    _counter;
    int           _direction;
    BOOL          _directionLit;
    CSPowerSource _power;

    double    _radius[2];      // mm
    CGFloat   _packPixels[2];  // radius the current pack bitmap was drawn at
    double    _omega[2];       // rad/s wanted
    double    _running[2];     // rad/s of the animation actually attached; 0 if none
    double    _angle[2];       // resting angle, radians
    BOOL      _spinning;
}

@synthesize delegate = _delegate, reelsSpinning = _spinning, tapeLoaded = _loaded, counter = _counter;

#pragma mark - Construction

- (CALayer *)addLayer:(CGRect)frame to:(CALayer *)parent
{
    CALayer *l = [CALayer layer];
    l.actions = CSNoActions();
    l.frame = frame;
    l.contentsScale = _scale;
    [parent addSublayer:l];
    return l;
}

- (CALayer *)addLayerCentred:(CGPoint)centre halfSide:(CGFloat)half to:(CALayer *)parent
{
    return [self addLayer:CGRectMake(centre.x - half, centre.y - half, 2 * half, 2 * half) to:parent];
}

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:NSMakeRect(frame.origin.x, frame.origin.y, CS_DECK_WIDTH, CS_DECK_HEIGHT)];
    if (!self) return nil;

    _scale = [[NSScreen mainScreen] backingScaleFactor];
    if (_scale < 1) _scale = 1;
    _latched = CSKeyCount;
    _pressed = CSKeyCount;
    _volume = 0.7f;
    _direction = 1;
    _radius[0] = CS_FULL_RADIUS_MM;
    _radius[1] = CS_HUB_RADIUS_MM;

    // Layer-hosting: the layer tree is ours, and AppKit never asks the view to
    // draw. The root is opaque, so nothing behind it is ever composited.
    _root = [[CALayer alloc] init];
    _root.actions = CSNoActions();
    _root.frame = CGRectMake(0, 0, CS_DECK_WIDTH, CS_DECK_HEIGHT);
    _root.opaque = YES;
    _root.contentsScale = _scale;
    [self setLayer:_root];
    [self setWantsLayer:YES];

    CGRect cr = CSCassetteRect();
    _cassetteShadow = [self addLayer:CSCassetteShadowRect() to:_root];
    _cassetteShadow.hidden = YES;
    _cassette = [self addLayer:cr to:_root];
    _cassette.hidden = YES;
    _interior = [self addLayer:CGRectMake(0, 0, cr.size.width, cr.size.height) to:_cassette];
    CGFloat hubHalf = CS_HUB_IMAGE_R_MM * CS_PT_PER_MM;
    int i;
    for (i = 0; i < 2; i++)
        _pack[i] = [self addLayerCentred:CSHubCentreInCassette(i) halfSide:1 to:_cassette];
    for (i = 0; i < 2; i++)
        _hub[i] = [self addLayerCentred:CSHubCentreInCassette(i) halfSide:hubHalf to:_cassette];
    for (i = 0; i < 2; i++)
        _shine[i] = [self addLayerCentred:CSHubCentreInCassette(i) halfSide:hubHalf to:_cassette];
    _face = [self addLayer:CGRectMake(0, 0, cr.size.width, cr.size.height) to:_cassette];

    _glass = [self addLayer:CSWellRect() to:_root];

    for (i = 0; i < CSKeyCount; i++) _key[i] = [self addLayer:CSKeyRect((CSKey)i) to:_root];
    _pointer = [self addLayerCentred:CSKnobCentre() halfSide:CSKnobPointerRadius() to:_root];
    for (i = 0; i < 3; i++) _digit[i] = [self addLayer:CSCounterDigitRect(i) to:_root];
    for (i = 0; i < CSLampCount; i++) _lamp[i] = [self addLayer:CSLampRect((CSLamp)i) to:_root];

    _dropGlow = [self addLayer:CGRectInset(CSDoorRect(), -3, -3) to:_root];
    _dropGlow.cornerRadius = 12;
    _dropGlow.borderWidth = 3;
    CGColorRef amber = CGColorCreateGenericRGB(1.0, 0.64, 0.18, 0.85);
    _dropGlow.borderColor = amber;
    CGColorRelease(amber);
    _dropGlow.hidden = YES;

    [self renderAll];
    [self registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
    return self;
}

- (void)releaseImages
{
    int i, j;
    for (i = 0; i < CSKeyCount; i++)
        for (j = 0; j < 2; j++) { CGImageRelease(_keyImage[i][j]); _keyImage[i][j] = NULL; }
    for (i = 0; i < CSLampCount; i++)
        for (j = 0; j < 2; j++) { CGImageRelease(_lampImage[i][j]); _lampImage[i][j] = NULL; }
    for (i = 0; i < 10; i++) { CGImageRelease(_digitImage[i]); _digitImage[i] = NULL; }
    CGImageRelease(_blankFace);
    _blankFace = NULL;
}

- (void)dealloc
{
    [self unregisterDraggedTypes];
    [self releaseImages];
    [_title release];
    [_artist release];
    [_root release];
    [super dealloc];
}

static void CSSetContents(CALayer *layer, CGImageRef image, CGFloat scale)
{
    layer.contentsScale = scale;
    layer.contents = (id)image;
}

// Every bitmap at the current scale, from the artwork cache when it has them
// (every launch but the first) and drawn when it does not. Runs at start-up
// and when the window moves to a display of a different resolution; never
// otherwise.
- (void)renderAll
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self releaseImages];

    CGFloat s = _scale;
    CGImageRef img;
    _root.contentsScale = s;
    img = CSArtworkCopy(@"deck", s, ^{ return CSCreateDeckImage(s); });
    CSSetContents(_root, img, s);
    CGImageRelease(img);
    img = CSArtworkCopy(@"interior", s, ^{ return CSCreateCassetteInteriorImage(s); });
    CSSetContents(_interior, img, s);
    CGImageRelease(img);
    img = CSArtworkCopy(@"cassette-shadow", s, ^{ return CSCreateCassetteShadowImage(s); });
    CSSetContents(_cassetteShadow, img, s);
    CGImageRelease(img);
    img = CSArtworkCopy(@"glass", s, ^{ return CSCreateDoorGlassImage(s); });
    CSSetContents(_glass, img, s);
    CGImageRelease(img);
    img = CSArtworkCopy(@"pointer", s, ^{ return CSCreateKnobPointerImage(s); });
    CSSetContents(_pointer, img, s);
    CGImageRelease(img);
    img = CSArtworkCopy(@"hub", s, ^{ return CSCreateHubImage(s); });
    CSSetContents(_hub[0], img, s);
    CSSetContents(_hub[1], img, s);
    CGImageRelease(img);
    img = CSArtworkCopy(@"hub-shine", s, ^{ return CSCreateHubShineImage(s); });
    CSSetContents(_shine[0], img, s);
    CSSetContents(_shine[1], img, s);
    CGImageRelease(img);
    _blankFace = CSArtworkCopy(@"face", s, ^{ return CSCreateBlankCassetteFaceImage(s); });
    _cassette.contentsScale = s;
    _dropGlow.contentsScale = s;

    int i;
    for (i = 0; i < CSKeyCount; i++) {
        CSKey k = (CSKey)i;
        _keyImage[i][0] = CSArtworkCopy([NSString stringWithFormat:@"key%d-up", i], s,
                                        ^{ return CSCreateKeyImage(k, NO, s); });
        _keyImage[i][1] = CSArtworkCopy([NSString stringWithFormat:@"key%d-down", i], s,
                                        ^{ return CSCreateKeyImage(k, YES, s); });
        _key[i].contentsScale = s;
    }
    for (i = 0; i < CSLampCount; i++) {
        CSLamp l = (CSLamp)i;
        _lampImage[i][0] = CSArtworkCopy([NSString stringWithFormat:@"lamp%d-off", i], s,
                                         ^{ return CSCreateLampImage(l, NO, s); });
        _lampImage[i][1] = CSArtworkCopy([NSString stringWithFormat:@"lamp%d-on", i], s,
                                         ^{ return CSCreateLampImage(l, YES, s); });
        _lamp[i].contentsScale = s;
    }
    for (i = 0; i < 10; i++) {
        int d = i;
        _digitImage[i] = CSArtworkCopy([NSString stringWithFormat:@"digit%d", i], s,
                                       ^{ return CSCreateCounterDigitImage(d, s); });
    }
    for (i = 0; i < 3; i++) _digit[i].contentsScale = s;

    _packPixels[0] = _packPixels[1] = -1;
    [self renderFace];
    [self updatePacks];
    [self refreshKeys];
    [self refreshLamps];
    [self refreshCounter];
    [self refreshPointer];
    [CATransaction commit];
}

// The writing is the only part of the cassette that differs from tape to
// tape, so it goes onto a copy of the blank label kept from start-up.
- (void)renderFace
{
    CGImageRef img = CSCreateWrittenCassetteFaceImage(_blankFace, _scale, _title, _artist);
    CSSetContents(_face, img, _scale);
    CGImageRelease(img);
}

#pragma mark - Resolution

- (void)adoptWindowScale
{
    CGFloat s = [[self window] backingScaleFactor];
    if (s >= 1 && s != _scale) {
        _scale = s;
        [self renderAll];
    }
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self adoptWindowScale];
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self adoptWindowScale];
}

- (void)setRenderScale:(CGFloat)scale
{
    if (scale >= 1 && scale != _scale) {
        _scale = scale;
        [self renderAll];
    }
}

#pragma mark - State

static BOOL CSSameString(NSString *a, NSString *b)
{
    return a == b || [a isEqualToString:b];
}

- (void)setTapeLoaded:(BOOL)loaded title:(NSString *)title artist:(NSString *)artist
{
    [self setTapeLoaded:loaded title:title artist:artist animated:NO];
}

- (void)setTapeLoaded:(BOOL)loaded title:(NSString *)title artist:(NSString *)artist
             animated:(BOOL)animated
{
    BOOL wasLoaded = _loaded;
    BOOL sameLabel = CSSameString(title, _title) && CSSameString(artist, _artist) && _face.contents;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _loaded = loaded;
    if (title != _title) { [_title release]; _title = [title copy]; }
    if (artist != _artist) { [_artist release]; _artist = [artist copy]; }
    if (loaded && !sameLabel) [self renderFace];
    if (!loaded) [self setReelsSpinning:NO];
    // Only where it can be seen: an animation nobody is watching is work for
    // nothing, and a hidden window's may never report that it has finished.
    NSWindow *w = [self window];
    if (animated && loaded != wasLoaded && [w isVisible] &&
        ([w occlusionState] & NSWindowOcclusionStateVisible)) {
        [self moveCassette:loaded];
    } else {
        [_cassette removeAnimationForKey:CS_INSERT_KEY];
        [_cassetteShadow removeAnimationForKey:CS_INSERT_KEY];
        _cassette.hidden = !loaded;
        _cassetteShadow.hidden = !loaded;
        _cassette.opacity = 1;
        _cassetteShadow.opacity = 1;
    }
    [self refreshLamps];
    [CATransaction commit];
    [[self window] invalidateCursorRectsForView:self];
}

// Ejected, the cassette comes up and out towards you and is gone; inserted,
// it drops back into the well. A fifth of a second, once, and afterwards
// there is nothing left animating. The shadow only fades: it stays on the
// back of the well while the cassette moves off it.
- (void)moveCassette:(BOOL)entering
{
    // Before the animations: the block waits for those added after it.
    if (!entering) {
        [CATransaction setCompletionBlock:^{
            // Unless a tape went back in while this one was on its way out.
            if (_loaded) return;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            _cassette.hidden = YES;
            _cassetteShadow.hidden = YES;
            _cassette.opacity = 1;
            _cassetteShadow.opacity = 1;
            [CATransaction commit];
        }];
    }
    CALayer *layers[2] = { _cassette, _cassetteShadow };
    int i;
    for (i = 0; i < 2; i++) {
        CALayer *l = layers[i];
        [l removeAnimationForKey:CS_INSERT_KEY];
        NSMutableArray *parts = [NSMutableArray array];
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = [NSNumber numberWithFloat:entering ? 0.0f : 1.0f];
        fade.toValue   = [NSNumber numberWithFloat:entering ? 1.0f : 0.0f];
        [parts addObject:fade];
        if (l == _cassette) {
            CATransform3D rest = CATransform3DIdentity;
            CATransform3D out = CATransform3DScale(CATransform3DMakeTranslation(0, 12, 0), 1.035, 1.035, 1);
            CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"transform"];
            move.fromValue = [NSValue valueWithCATransform3D:entering ? out : rest];
            move.toValue   = [NSValue valueWithCATransform3D:entering ? rest : out];
            [parts addObject:move];
        }
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = parts;
        group.duration = 0.2;
        group.timingFunction = [CAMediaTimingFunction functionWithName:
            entering ? kCAMediaTimingFunctionEaseOut : kCAMediaTimingFunctionEaseIn];
        [l addAnimation:group forKey:CS_INSERT_KEY];
        l.hidden = NO;
        // Where it ends up, so that nothing jumps when the animation is removed.
        l.opacity = entering ? 1 : 0;
    }
}

- (void)refreshKeys
{
    int i;
    for (i = 0; i < CSKeyCount; i++) {
        BOOL down = (i == (int)_latched) || (i == (int)_pressed && _pressedInside);
        _key[i].contents = (id)_keyImage[i][down ? 1 : 0];
    }
}

- (void)setLatchedKey:(CSKey)key
{
    _latched = key;
    [self refreshKeys];
}

- (float)volumePosition { return _volume; }

- (void)setVolumePosition:(float)position
{
    if (!(position >= 0)) position = 0;
    if (position > 1) position = 1;
    _volume = position;
    [self refreshPointer];
}

- (void)refreshPointer
{
    _pointer.transform = CATransform3DMakeRotation(CSKnobRotation(_volume), 0, 0, 1);
}

- (void)setCounter:(NSUInteger)value
{
    value %= 1000;
    if (value == _counter && _digit[0].contents) return;
    _counter = value;
    [self refreshCounter];
}

- (void)refreshCounter
{
    NSUInteger v = _counter;
    _digit[0].contents = (id)_digitImage[(v / 100) % 10];
    _digit[1].contents = (id)_digitImage[(v / 10) % 10];
    _digit[2].contents = (id)_digitImage[v % 10];
}

- (void)setDirection:(int)direction lit:(BOOL)lit
{
    if (direction == _direction && lit == _directionLit) return;
    _direction = direction < 0 ? -1 : 1;
    _directionLit = lit;
    [self refreshLamps];
}

- (void)setPowerSource:(CSPowerSource)source
{
    if (source == _power) return;
    _power = source;
    [self refreshLamps];
}

- (void)refreshLamps
{
    BOOL on[CSLampCount];
    on[CSLampReverse] = _loaded && _directionLit && _direction < 0;
    on[CSLampForward] = _loaded && _directionLit && _direction > 0;
    on[CSLampAC]      = _power == CSPowerAC;
    // Unknown lights neither: the deck behaves as if on battery, but it would
    // be wrong to claim that it knows.
    on[CSLampBattery] = _power == CSPowerBattery;
    int i;
    for (i = 0; i < CSLampCount; i++) _lamp[i].contents = (id)_lampImage[i][on[i] ? 1 : 0];
}

#pragma mark - Reels

- (void)updatePacks
{
    int i;
    for (i = 0; i < 2; i++) {
        CGFloat r = (CGFloat)(_radius[i] * CS_PT_PER_MM);
        CGFloat px = r * _scale;
        if (_packPixels[i] >= 0 && fabs(px - _packPixels[i]) < 0.5) continue;
        _packPixels[i] = px;
        CGImageRef img = CSCreatePackImage(r, _scale);
        CGPoint c = CSHubCentreInCassette(i);
        _pack[i].bounds = CGRectMake(0, 0, 2 * (r + 1), 2 * (r + 1));
        _pack[i].position = c;
        CSSetContents(_pack[i], img, _scale);
        CGImageRelease(img);
    }
}

- (double)currentAngle:(int)i
{
    if (![_hub[i] animationForKey:CS_SPIN_KEY]) return _angle[i];
    CALayer *shown = [_hub[i] presentationLayer];
    NSNumber *z = [shown valueForKeyPath:@"transform.rotation.z"];
    return z ? [z doubleValue] : _angle[i];
}

// Takes the reel's angle from what is on screen, fixes it there, and removes
// the animation, so nothing is left for the compositor to do.
- (void)freezeReel:(int)i
{
    _angle[i] = fmod([self currentAngle:i], 2 * M_PI);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _hub[i].transform = CATransform3DMakeRotation((CGFloat)_angle[i], 0, 0, 1);
    [_hub[i] removeAnimationForKey:CS_SPIN_KEY];
    [CATransaction commit];
    _running[i] = 0;
}

// One revolution from wherever the reel stands, repeated for ever. The hub
// bitmap has six-fold symmetry but a clamp and pin marks that do not, so a
// turn reads as a turn.
- (void)spinReel:(int)i
{
    double w = _omega[i];
    [_hub[i] removeAnimationForKey:CS_SPIN_KEY];
    _running[i] = 0;
    if (!(fabs(w) > 1e-6)) return;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    a.fromValue = [NSNumber numberWithDouble:_angle[i]];
    a.toValue = [NSNumber numberWithDouble:_angle[i] + (w > 0 ? 2 * M_PI : -2 * M_PI)];
    a.duration = 2 * M_PI / fabs(w);
    a.repeatCount = HUGE_VALF;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [_hub[i] addAnimation:a forKey:CS_SPIN_KEY];
    _running[i] = w;
}

- (void)setReelsSpinning:(BOOL)spinning
{
    if (spinning && !_loaded) spinning = NO;
    if (spinning == _spinning) return;
    _spinning = spinning;
    int i;
    for (i = 0; i < 2; i++) {
        if (spinning) [self spinReel:i];
        else [self freezeReel:i];
    }
}

static BOOL CSNeedsRetime(double running, double wanted)
{
    if (running == 0) return wanted != 0;
    if ((running > 0) != (wanted > 0)) return YES;
    return fabs(wanted - running) / fabs(running) > 0.015;
}

- (void)setLeftRadius:(double)left rightRadius:(double)right
            leftOmega:(double)leftOmega rightOmega:(double)rightOmega
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _radius[0] = left;
    _radius[1] = right;
    [self updatePacks];
    _omega[0] = leftOmega;
    _omega[1] = rightOmega;
    if (_spinning) {
        int i;
        for (i = 0; i < 2; i++) {
            if (CSNeedsRetime(_running[i], _omega[i])) {
                [self freezeReel:i];
                [self spinReel:i];
            }
        }
    }
    [CATransaction commit];
}

- (BOOL)hubHasSpinAnimation:(int)side
{
    return [_hub[side ? 1 : 0] animationForKey:CS_SPIN_KEY] != nil;
}

- (double)hubSpinPeriod:(int)side
{
    CAAnimation *a = [_hub[side ? 1 : 0] animationForKey:CS_SPIN_KEY];
    return a ? [a duration] : 0;
}

#pragma mark - Snapshot

- (CGImageRef)createSnapshotImage
{
    size_t w = (size_t)ceil(CS_DECK_WIDTH * _scale), h = (size_t)ceil(CS_DECK_HEIGHT * _scale);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    CGContextScaleCTM(c, _scale, _scale);
    [_root renderInContext:c];
    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return image;
}

#pragma mark - Mouse and keyboard

- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
// A click on a key works even while another application is in front, the way
// a real button would.
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (BOOL)pointIsOnKnob:(NSPoint)p
{
    CGPoint o = CSKnobCentre();
    return hypot(p.x - o.x, p.y - o.y) <= CSKnobRadius();
}

// With no tape in, the compartment is a control: the pointer says so.
- (void)resetCursorRects
{
    if (!_loaded) [self addCursorRect:NSRectFromCGRect(CSDoorRect()) cursor:[NSCursor pointingHandCursor]];
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    int i;
    for (i = 0; i < CSKeyCount; i++) {
        if (NSPointInRect(p, CSKeyHitRect((CSKey)i))) {
            _pressed = (CSKey)i;
            _pressedInside = YES;
            [self refreshKeys];
            return;
        }
    }
    if ([self pointIsOnKnob:p]) {
        _trackingKnob = YES;
        _knobStart = p;
        _knobStartPosition = _volume;
        return;
    }
    if (!_loaded && NSPointInRect(p, NSRectFromCGRect(CSDoorRect()))) {
        _pressedCompartment = YES;
        return;
    }
    [_delegate deckView:self mouseDownOnCabinet:event];
}

- (void)mouseDragged:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    if (_pressed != CSKeyCount) {
        BOOL inside = NSPointInRect(p, CSKeyHitRect(_pressed));
        if (inside != _pressedInside) {
            _pressedInside = inside;
            [self refreshKeys];
        }
    } else if (_trackingKnob) {
        // Up or right turns it up. 220 points of travel is the whole range.
        float delta = (float)(((p.y - _knobStart.y) + (p.x - _knobStart.x)) / 220.0);
        [self setVolumePosition:_knobStartPosition + delta];
        [_delegate deckView:self movedVolumeKnobTo:_volume finished:NO];
    }
}

- (void)mouseUp:(NSEvent *)event
{
    if (_pressedCompartment) {
        _pressedCompartment = NO;
        NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
        if (!_loaded && NSPointInRect(p, NSRectFromCGRect(CSDoorRect())))
            [_delegate deckViewClickedEmptyCompartment:self];
    } else if (_pressed != CSKeyCount) {
        CSKey key = _pressed;
        BOOL fire = _pressedInside;
        _pressed = CSKeyCount;
        _pressedInside = NO;
        [self refreshKeys];
        if (fire) [_delegate deckView:self pressedKey:key];
    } else if (_trackingKnob) {
        _trackingKnob = NO;
        [_delegate deckView:self movedVolumeKnobTo:_volume finished:YES];
    }
}

- (void)scrollWheel:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    if (![self pointIsOnKnob:p]) { [super scrollWheel:event]; return; }
    CGFloat dy = [event scrollingDeltaY];
    float step = (float)([event hasPreciseScrollingDeltas] ? dy / 400.0 : dy / 40.0);
    if (step == 0) return;
    [self setVolumePosition:_volume + step];
    [_delegate deckView:self movedVolumeKnobTo:_volume finished:YES];
}

- (void)keyDown:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars isEqualToString:@" "] &&
        !([event modifierFlags] & (NSCommandKeyMask | NSControlKeyMask | NSAlternateKeyMask))) {
        [NSApp sendAction:@selector(togglePlayPause:) to:nil from:self];
        return;
    }
    [super keyDown:event];
}

#pragma mark - Drag and drop

// One file, which the delegate agrees is audio. A drag of several is refused
// rather than guessed at: the deck holds one tape.
- (NSURL *)droppableURL:(id <NSDraggingInfo>)info
{
    NSArray *paths = [[info draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    if (![paths isKindOfClass:[NSArray class]] || [paths count] != 1) return nil;
    NSString *path = [paths objectAtIndex:0];
    if (![path isKindOfClass:[NSString class]]) return nil;
    NSURL *url = [NSURL fileURLWithPath:path];
    return [_delegate deckView:self canAcceptDroppedURL:url] ? url : nil;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)info
{
    BOOL ok = [self droppableURL:info] != nil;
    _dropGlow.hidden = !ok;
    return ok ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)info
{
    return _dropGlow.hidden ? NSDragOperationNone : NSDragOperationCopy;
}

- (void)draggingExited:(id <NSDraggingInfo>)info
{
    _dropGlow.hidden = YES;
}

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)info
{
    return [self droppableURL:info] != nil;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)info
{
    _dropGlow.hidden = YES;
    NSURL *url = [self droppableURL:info];
    if (!url) return NO;
    // After the drag session has finished, so that an error sheet raised by
    // the load does not appear while the Finder still owns the mouse.
    [self performSelector:@selector(deliverDroppedURL:) withObject:url afterDelay:0];
    return YES;
}

- (void)deliverDroppedURL:(NSURL *)url
{
    [_delegate deckView:self droppedURL:url];
}

- (void)concludeDragOperation:(id <NSDraggingInfo>)info
{
    _dropGlow.hidden = YES;
}

@end
