#import "CSArtwork.h"
#include <math.h>
#include <stdlib.h>

#pragma mark - Geometry

CGRect CSDoorRect(void) { return CGRectMake(66, 124, 364, 284); }
CGRect CSWellRect(void) { return CGRectMake(78, 136, 340, 260); }

CGRect CSCassetteRect(void)
{
    CGFloat w = CS_SHELL_W_MM * CS_PT_PER_MM, h = CS_SHELL_H_MM * CS_PT_PER_MM;
    CGRect well = CSWellRect();
    return CGRectMake(well.origin.x + (well.size.width - w) / 2, 166, w, h);
}

CGPoint CSHubCentreInCassette(int side)
{
    CGFloat x = CS_SHELL_W_MM / 2 + (side ? 0.5 : -0.5) * CS_HUB_SPACING_MM;
    return CGPointMake(x * CS_PT_PER_MM, CS_HUB_Y_MM * CS_PT_PER_MM);
}

CGPoint CSHubCentre(int side)
{
    CGRect c = CSCassetteRect();
    CGPoint p = CSHubCentreInCassette(side);
    return CGPointMake(c.origin.x + p.x, c.origin.y + p.y);
}

CGRect  CSKeyHitRect(CSKey k)   { return CGRectMake(66 + 93 * (CGFloat)k, 46, 85, 58); }
CGRect  CSKeyRect(CSKey k)      { return CGRectInset(CSKeyHitRect(k), -4, -4); }
CGPoint CSKnobCentre(void)      { return CGPointMake(593, 168); }
CGFloat CSKnobRadius(void)      { return 56; }
CGFloat CSKnobPointerRadius(void) { return 47; }
CGRect  CSCounterDigitRect(int i) { return CGRectMake(477 + 22 * i, 291, 20, 30); }

static CGRect CSLampLensRect(CSLamp lamp)
{
    switch (lamp) {
        case CSLampReverse: return CGRectMake(602, 300, 20, 14);
        case CSLampForward: return CGRectMake(628, 300, 20, 14);
        case CSLampAC:      return CGRectMake(677, 301, 12, 12);
        default:            return CGRectMake(705, 301, 12, 12);
    }
}

CGRect CSLampRect(CSLamp lamp) { return CGRectInset(CSLampLensRect(lamp), -8, -8); }

#pragma mark - Drawing infrastructure

static CGColorSpaceRef CSColorSpace(void)
{
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    return space;
}

static CGContextRef CSBitmap(size_t w, size_t h)
{
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    return CGBitmapContextCreate(NULL, w, h, 8, 0, CSColorSpace(),
                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
}

static size_t CSPixelsFor(CGFloat points, CGFloat scale)
{
    double px = ceil(points * scale - 0.001);
    return px < 1 ? 1 : (size_t)px;
}

// A context `wPt` x `hPt` points, drawn in points, origin bottom-left.
static CGContextRef CSBegin(CGFloat wPt, CGFloat hPt, CGFloat scale)
{
    CGContextRef c = CSBitmap(CSPixelsFor(wPt, scale), CSPixelsFor(hPt, scale));
    CGContextScaleCTM(c, scale, scale);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    // These images are composited over other layers; subpixel text would fringe.
    CGContextSetShouldSmoothFonts(c, false);
    return c;
}

static CGImageRef CSEnd(CGContextRef c)
{
    CGImageRef image = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return image;
}

static void CSFillRGBA(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    CGFloat comps[4] = { r, g, b, a };
    CGColorRef col = CGColorCreate(CSColorSpace(), comps);
    CGContextSetFillColorWithColor(c, col);
    CGColorRelease(col);
}

static void CSStrokeRGBA(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    CGFloat comps[4] = { r, g, b, a };
    CGColorRef col = CGColorCreate(CSColorSpace(), comps);
    CGContextSetStrokeColorWithColor(c, col);
    CGColorRelease(col);
}

// Shadows are specified in device pixels and ignore the CTM, so every offset
// and blur here is given in the current drawing units and converted.
static CGFloat CSDeviceScale(CGContextRef c)
{
    CGAffineTransform m = CGContextGetCTM(c);
    return sqrt(m.a * m.a + m.b * m.b);
}

static void CSShadow(CGContextRef c, CGFloat dx, CGFloat dy, CGFloat blur,
                     CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    CGFloat k = CSDeviceScale(c);
    CGFloat comps[4] = { r, g, b, a };
    CGColorRef col = CGColorCreate(CSColorSpace(), comps);
    CGContextSetShadowWithColor(c, CGSizeMake(dx * k, dy * k), blur * k, col);
    CGColorRelease(col);
}

// A gradient through `n` RGBA stops.
static CGGradientRef CSGradient(size_t n, const CGFloat *rgba, const CGFloat *locs)
{
    return CGGradientCreateWithColorComponents(CSColorSpace(), rgba, locs, n);
}

static void CSLinear(CGContextRef c, CGPoint from, CGPoint to, size_t n,
                     const CGFloat *rgba, const CGFloat *locs)
{
    CGGradientRef g = CSGradient(n, rgba, locs);
    CGContextDrawLinearGradient(c, g, from, to,
        kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
}

static void CSRadial(CGContextRef c, CGPoint c0, CGFloat r0, CGPoint c1, CGFloat r1,
                     size_t n, const CGFloat *rgba, const CGFloat *locs, BOOL extend)
{
    CGGradientRef g = CSGradient(n, rgba, locs);
    CGContextDrawRadialGradient(c, g, c0, r0, c1, r1,
                                extend ? kCGGradientDrawsAfterEndLocation : 0);
    CGGradientRelease(g);
}

// Top-to-bottom gradient between two colours over `r`.
static void CSVertical(CGContextRef c, CGRect r, const CGFloat top[4], const CGFloat bottom[4])
{
    CGFloat comps[8] = { top[0], top[1], top[2], top[3],
                         bottom[0], bottom[1], bottom[2], bottom[3] };
    CGFloat locs[2] = { 0, 1 };
    CSLinear(c, CGPointMake(CGRectGetMidX(r), CGRectGetMaxY(r)),
                CGPointMake(CGRectGetMidX(r), CGRectGetMinY(r)), 2, comps, locs);
}

static CGPathRef CSRoundRect(CGRect r, CGFloat radius)
{
    CGFloat limit = MIN(r.size.width, r.size.height) / 2;
    if (radius > limit) radius = limit;
    if (radius < 0) radius = 0;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddRoundedRect(p, NULL, r, radius, radius);
    return p;
}

static CGPathRef CSCircle(CGPoint centre, CGFloat r)
{
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddEllipseInRect(p, NULL, CGRectMake(centre.x - r, centre.y - r, 2 * r, 2 * r));
    return p;
}

static void CSFillPath(CGContextRef c, CGPathRef p)
{
    CGContextAddPath(c, p);
    CGContextFillPath(c);
}

static void CSClipPath(CGContextRef c, CGPathRef p)
{
    CGContextAddPath(c, p);
    CGContextClip(c);
}

// A shadow cast INTO a shape by its own edge: the recess look.
static void CSInnerShadow(CGContextRef c, CGPathRef path, CGFloat dx, CGFloat dy, CGFloat blur,
                          CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    CGContextSaveGState(c);
    CSClipPath(c, path);
    CGFloat pad = blur * 3 + fabs(dx) + fabs(dy) + 4;
    CGMutablePathRef ring = CGPathCreateMutable();
    CGPathAddRect(ring, NULL, CGRectInset(CGPathGetBoundingBox(path), -pad, -pad));
    CGPathAddPath(ring, NULL, path);
    CSShadow(c, dx, dy, blur, r, g, b, a);
    CSFillRGBA(c, r, g, b, 1);
    CGContextAddPath(c, ring);
    CGContextEOFillPath(c);
    CGPathRelease(ring);
    CGContextRestoreGState(c);
}

#pragma mark - Text

static NSFont *CSFont(NSString *names, CGFloat size)
{
    for (NSString *name in [names componentsSeparatedByString:@","]) {
        NSFont *f = [NSFont fontWithName:name size:size];
        if (f) return f;
    }
    return [NSFont systemFontOfSize:size];
}

#define CS_FONT_PRINT   @"HelveticaNeue-Medium,Helvetica-Bold"
#define CS_FONT_BOLD    @"HelveticaNeue-Bold,Helvetica-Bold"
#define CS_FONT_BRAND   @"Futura-Medium,AvenirNext-Medium,HelveticaNeue"
#define CS_FONT_HAND    @"Noteworthy-Bold,MarkerFelt-Wide,MarkerFelt-Thin,ChalkboardSE-Regular,Chalkboard"
#define CS_FONT_DIGITS  @"HelveticaNeue-Medium,Helvetica"

typedef enum { CSAlignLeft, CSAlignCentre, CSAlignRight } CSAlign;

static NSAttributedString *CSString(NSString *s, NSFont *font, CGFloat kern,
                                    CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    NSColor *colour = [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
    NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
        font, NSFontAttributeName,
        colour, NSForegroundColorAttributeName,
        [NSNumber numberWithDouble:kern], NSKernAttributeName, nil];
    return [[[NSAttributedString alloc] initWithString:s attributes:attrs] autorelease];
}

// Width of a string as it will be drawn, without the tracking after its last
// character, which would otherwise pull centred text to the left.
static CGFloat CSTextWidth(NSString *s, NSFont *font, CGFloat kern)
{
    return [CSString(s, font, kern, 0, 0, 0, 1) size].width - ([s length] ? kern : 0);
}

// Draws with its baseline at `p.y`.
static void CSText(CGContextRef c, NSString *s, NSFont *font, CGFloat kern,
                   CGFloat r, CGFloat g, CGFloat b, CGFloat a, CGPoint p, CSAlign align)
{
    NSAttributedString *as = CSString(s, font, kern, r, g, b, a);
    CGFloat w = [as size].width - ([s length] ? kern : 0);
    CGFloat x = p.x;
    if (align == CSAlignCentre) x -= w / 2;
    if (align == CSAlignRight)  x -= w;

    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithGraphicsPort:c flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:gc];
    // Without NSStringDrawingUsesLineFragmentOrigin the rectangle's origin is
    // the baseline of the (single) line, which is what every caller wants.
    [as drawWithRect:NSMakeRect(x, p.y, w + 4 * [font pointSize], 0) options:0];
    [NSGraphicsContext restoreGraphicsState];
}

// Silkscreen on metal: dark paint with a faint highlight under it, the way
// light catches the lower edge of printing that sits proud of a brushed plate.
static void CSPrinted(CGContextRef c, NSString *s, NSFont *font, CGFloat kern,
                      CGFloat v, CGPoint p, CSAlign align)
{
    CSText(c, s, font, kern, 1, 1, 1, 0.38, CGPointMake(p.x, p.y - 0.6), align);
    CSText(c, s, font, kern, v, v, v * 1.02, 0.92, p, align);
}

#pragma mark - Per-pixel textures

typedef struct {
    CGContextRef ctx;
    uint32_t    *data;
    size_t       w, h, stride;
} CSPixels;

static CSPixels CSPixelsCreate(size_t w, size_t h)
{
    CSPixels p;
    p.ctx    = CSBitmap(w, h);
    p.data   = (uint32_t *)CGBitmapContextGetData(p.ctx);
    p.w      = CGBitmapContextGetWidth(p.ctx);
    p.h      = CGBitmapContextGetHeight(p.ctx);
    p.stride = CGBitmapContextGetBytesPerRow(p.ctx) / 4;
    return p;
}

static CGImageRef CSPixelsFinish(CSPixels p) { return CSEnd(p.ctx); }

// Row `y` counted from the bottom, to match every other coordinate here.
static inline uint32_t *CSRow(const CSPixels *p, size_t y)
{
    return p->data + (p->h - 1 - y) * p->stride;
}

// Runs `body` over every row of an image `rows` high, in bands of eight, spread
// across all the machine's cores. Every texture here computes a pixel from its
// coordinates alone, so rows can be done in any order and at the same time.
// This is what makes the first launch -- the only one that draws, since the
// results are then cached -- several times quicker on a multi-core Mac.
// dispatch_apply returns when every band is done.
static void CSEachBand(size_t rows, void (^body)(size_t y0, size_t y1))
{
    const size_t band = 8;
    size_t bands = (rows + band - 1) / band;
    dispatch_apply(bands, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(size_t i) {
        size_t end = (i + 1) * band;
        body(i * band, end < rows ? end : rows);
    });
}

static inline float CSClamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

// Straight colour in, premultiplied native-endian ARGB out.
static inline uint32_t CSPx(float r, float g, float b, float a)
{
    a = CSClamp01(a);
    r = CSClamp01(r) * a; g = CSClamp01(g) * a; b = CSClamp01(b) * a;
    return ((uint32_t)(a * 255.0f + 0.5f) << 24) | ((uint32_t)(r * 255.0f + 0.5f) << 16) |
           ((uint32_t)(g * 255.0f + 0.5f) << 8)  |  (uint32_t)(b * 255.0f + 0.5f);
}

static inline uint32_t CSHash(uint32_t x)
{
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

// Repeatable white noise in [0, 1).
static inline float CSRand(int x, int y, uint32_t seed)
{
    uint32_t h = CSHash((uint32_t)x * 0x9E3779B1U ^ CSHash((uint32_t)y * 0x85EBCA77U + seed * 0xC2B2AE3DU));
    return (float)(h >> 8) * (1.0f / 16777216.0f);
}

static inline float CSSmooth(float t) { return t * t * (3.0f - 2.0f * t); }

// Value noise: smooth, repeatable, [0, 1].
static float CSNoise(float x, float y, uint32_t seed)
{
    float fx = floorf(x), fy = floorf(y);
    int ix = (int)fx, iy = (int)fy;
    float tx = CSSmooth(x - fx), ty = CSSmooth(y - fy);
    float a = CSRand(ix, iy, seed),     b = CSRand(ix + 1, iy, seed);
    float c = CSRand(ix, iy + 1, seed), d = CSRand(ix + 1, iy + 1, seed);
    float top = a + (b - a) * tx, bottom = c + (d - c) * tx;
    return top + (bottom - top) * ty;
}

static float CSFbm(float x, float y, int octaves, uint32_t seed)
{
    float sum = 0, amp = 0.5f, norm = 0;
    int i;
    for (i = 0; i < octaves; i++) {
        sum  += amp * CSNoise(x, y, seed + (uint32_t)i * 131U);
        norm += amp;
        x *= 2.03f; y *= 2.03f; amp *= 0.5f;
    }
    return sum / norm;
}

// Brushed aluminium, grain running horizontally.
//
// Each row is white noise smeared along the row by a running box filter, which
// is what a brush does to a surface: long, fine, parallel scratches. A per-row
// tone on top gives the few deeper lines that catch the eye. The smear is
// normalised to its own length, so the texture reads the same at any scale.
static CGImageRef CSCreateBrushedImage(CGFloat wPt, CGFloat hPt, CGFloat scale, uint32_t seed,
                                       float base, float contrast, float tr, float tg, float tb)
{
    CSPixels p = CSPixelsCreate(CSPixelsFor(wPt, scale), CSPixelsFor(hPt, scale));
    int R = (int)(16 * scale);
    if (R < 3) R = 3;
    int span = 2 * R + 1;
    float norm = 1.0f / (sqrtf((float)span) * 0.2887f);
    CSEachBand(p.h, ^(size_t y0, size_t y1) {
        float *noise = (float *)calloc(p.w + (size_t)span + 1, sizeof(float));
        if (!noise) return;
        size_t x, y;
        for (y = y0; y < y1; y++) {
            uint32_t *row = CSRow(&p, y);
            float v = (float)y / (float)scale;
            float rowTone = (CSRand(3, (int)y, seed) - 0.5f) * 0.045f
                          + (CSFbm(0.5f, v * 0.09f, 2, seed + 9) - 0.5f) * 0.06f;
            size_t i, n = p.w + (size_t)span;
            for (i = 0; i < n; i++) noise[i] = CSRand((int)i, (int)y, seed + 1) - 0.5f;
            float sum = 0;
            for (i = 0; i < (size_t)span; i++) sum += noise[i];
            for (x = 0; x < p.w; x++) {
                float streak = sum / (float)span * norm * 0.028f;
                float fine = noise[x + (size_t)R] * 0.035f;
                float t = base + (rowTone + streak + fine) * contrast;
                row[x] = CSPx(t * tr, t * tg, t * tb, 1);
                sum += noise[x + (size_t)span] - noise[x];
            }
        }
        free(noise);
    });
    return CSPixelsFinish(p);
}

// Walnut, grain running vertically, as it would on a side cheek cut from a
// board. Growth rings are a sawtooth across the width, bent by two scales of
// noise into the long flowing figure walnut is known for; latewood darkens
// towards each ring's end, and open pores show as short dark flecks along the
// grain.
static CGImageRef CSCreateWoodImage(CGFloat wPt, CGFloat hPt, CGFloat scale, uint32_t seed)
{
    CSPixels p = CSPixelsCreate(CSPixelsFor(wPt, scale), CSPixelsFor(hPt, scale));
    CSEachBand(p.h, ^(size_t y0, size_t y1) {
        size_t x, y;
        for (y = y0; y < y1; y++) {
            uint32_t *row = CSRow(&p, y);
            float v = ((float)y + 0.5f) / (float)scale;
            for (x = 0; x < p.w; x++) {
                float u = ((float)x + 0.5f) / (float)scale;
                float warp = 24.0f * CSFbm(u * 0.016f, v * 0.0028f, 4, seed)
                           + 3.0f * CSFbm(u * 0.11f, v * 0.009f, 3, seed + 17);
                float g = (u + warp) * 0.115f;
                float ring = g - floorf(g);
                // Latewood: a gradual darkening across each ring and a crisp dark
                // line at its end, which is what makes walnut grain legible.
                float late = powf(ring, 2.2f) + 0.7f * CSClamp01((ring - 0.88f) * 8.0f);
                float figure = CSFbm(u * 0.035f, v * 0.0045f, 3, seed + 5);
                float streak = CSFbm(u * 0.6f, v * 0.008f, 2, seed + 41);   // mineral streaks
                float pore = CSRand((int)(u * 3.0f), (int)(v * 0.30f), seed + 29);
                pore = pore > 0.95f ? (pore - 0.95f) * 9.0f : 0;
                float t = CSClamp01(0.25f + 0.52f * late + 1.15f * (figure - 0.5f)
                                    + 0.30f * CSClamp01((streak - 0.6f) * 4.0f) + 0.35f * pore);
                // Fibre: fine noise drawn out along the grain, not speckle.
                float fine = (CSRand((int)x, (int)((float)y / (20.0f * (float)scale)), seed + 77) - 0.5f) * 0.022f;
                // Oiled American black walnut: honey-brown heartwood through to
                // near-black chocolate in the latewood.
                float r = 0.58f + (0.13f - 0.58f) * t + fine;
                float gg = 0.37f + (0.07f - 0.37f) * t + fine * 0.75f;
                float b = 0.21f + (0.035f - 0.21f) * t + fine * 0.5f;
                row[x] = CSPx(r, gg, b, 1);
            }
        }
    });
    return CSPixelsFinish(p);
}

// A translucent speckle to lay over a flat colour: matte plastic, paper.
static CGImageRef CSCreateGrainImage(CGFloat wPt, CGFloat hPt, CGFloat scale, uint32_t seed,
                                     float amount, float cell)
{
    CSPixels p = CSPixelsCreate(CSPixelsFor(wPt, scale), CSPixelsFor(hPt, scale));
    CSEachBand(p.h, ^(size_t y0, size_t y1) {
        size_t x, y;
        for (y = y0; y < y1; y++) {
            uint32_t *row = CSRow(&p, y);
            for (x = 0; x < p.w; x++) {
                float n = CSRand((int)(x / cell), (int)(y / cell), seed) - 0.5f;
                n += (CSNoise((float)x * 0.08f, (float)y * 0.08f, seed + 3) - 0.5f) * 0.6f;
                float a = fabsf(n) * amount;
                row[x] = n > 0 ? CSPx(1, 1, 1, a) : CSPx(0, 0, 0, a);
            }
        }
    });
    return CSPixelsFinish(p);
}

// Spun aluminium: machined in concentric rings, so light off it forms the
// radial "bowtie" that points at the lamp. Lighting is baked in; this disc
// never turns, only the pointer drawn over it does.
static CGImageRef CSCreateSpunImage(CGFloat radiusPt, CGFloat scale, uint32_t seed, float base)
{
    size_t side = CSPixelsFor(2 * radiusPt, scale);
    CSPixels p = CSPixelsCreate(side, side);
    float c = (float)side / 2.0f, R = (float)(radiusPt * scale);
    float light = (float)(135.0 * M_PI / 180.0);
    CSEachBand(p.h, ^(size_t y0, size_t y1) {
        size_t x, y;
        for (y = y0; y < y1; y++) {
            uint32_t *row = CSRow(&p, y);
            for (x = 0; x < p.w; x++) {
                float dx = (float)x + 0.5f - c, dy = (float)y + 0.5f - c;
                float r = sqrtf(dx * dx + dy * dy);
                float cover = CSClamp01(R - r + 0.5f);
                if (cover <= 0) { row[x] = 0; continue; }
                float phi = atan2f(dy, dx);
                float k = fabsf(cosf(phi - light));
                float v = base + 0.28f * powf(k, 14.0f) + 0.10f * k * k
                        + (CSRand((int)(r * 0.9f), 1, seed) - 0.5f) * 0.07f
                        - 0.05f * (r / R);
                row[x] = CSPx(v * 0.99f, v, v * 1.01f, cover);
            }
        }
    });
    return CSPixelsFinish(p);
}

#pragma mark - Small parts

static void CSDrawScrew(CGContextRef c, CGPoint p, CGFloat r, CGFloat angle, BOOL dark)
{
    CGPathRef head = CSCircle(p, r);

    CGContextSaveGState(c);
    CSShadow(c, 0.25 * r, -0.35 * r, 0.5 * r, 0, 0, 0, 0.6);
    CSFillRGBA(c, 0.3, 0.3, 0.3, 1);
    CSFillPath(c, head);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    CSClipPath(c, head);
    CGFloat hi = dark ? 0.55 : 0.97, lo = dark ? 0.12 : 0.42;
    CGFloat comps[12] = { hi, hi, hi, 1,  (hi + lo) / 2, (hi + lo) / 2, (hi + lo) / 2 + 0.01, 1,  lo, lo, lo + 0.01, 1 };
    CGFloat locs[3] = { 0, 0.45, 1 };
    CSRadial(c, CGPointMake(p.x - 0.4 * r, p.y + 0.45 * r), 0,
                CGPointMake(p.x - 0.4 * r, p.y + 0.45 * r), 1.7 * r, 3, comps, locs, YES);

    // The cross, with its lower edges lit and upper edges in shadow.
    CGContextTranslateCTM(c, p.x, p.y);
    CGContextRotateCTM(c, angle);
    CGFloat len = r * 0.72, wid = r * 0.16;
    int i;
    for (i = 0; i < 2; i++) {
        CGRect slot = i ? CGRectMake(-wid, -len, 2 * wid, 2 * len) : CGRectMake(-len, -wid, 2 * len, 2 * wid);
        CSFillRGBA(c, 1, 1, 1, dark ? 0.12 : 0.35);
        CGContextFillRect(c, CGRectOffset(slot, 0, -0.08 * r));
    }
    for (i = 0; i < 2; i++) {
        CGRect slot = i ? CGRectMake(-wid, -len, 2 * wid, 2 * len) : CGRectMake(-len, -wid, 2 * len, 2 * wid);
        CSFillRGBA(c, 0.06, 0.06, 0.06, 0.9);
        CGContextFillRect(c, slot);
    }
    CGContextRestoreGState(c);

    CSStrokeRGBA(c, 0, 0, 0, 0.45);
    CGContextSetLineWidth(c, MAX(0.2, r * 0.08));
    CGContextAddPath(c, head);
    CGContextStrokePath(c);
    CGPathRelease(head);
}

// The deck's reel spindle: a black moulding with three drive tabs around a
// chrome shaft. `k` is points per millimetre. Drawn in the empty deck, and
// again inside each hub bitmap, where it turns with the hub it drives.
static void CSDrawSpindle(CGContextRef c, CGPoint centre, CGFloat k)
{
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, centre.x, centre.y);
    CGContextScaleCTM(c, k, k);

    CGPathRef disc = CSCircle(CGPointZero, 4.5);
    CGContextSaveGState(c);
    CSShadow(c, 0.25, -0.35, 0.8, 0, 0, 0, 0.8);
    CSFillRGBA(c, 0.13, 0.13, 0.14, 1);
    CSFillPath(c, disc);
    int i;
    for (i = 0; i < 3; i++) {
        CGContextSaveGState(c);
        CGContextRotateCTM(c, (CGFloat)(M_PI / 6 + i * 2 * M_PI / 3));
        CGPathRef tab = CSRoundRect(CGRectMake(3.0, -0.72, 3.9, 1.44), 0.5);
        CSFillPath(c, tab);
        CGPathRelease(tab);
        CGContextRestoreGState(c);
    }
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    CSClipPath(c, disc);
    CGFloat comps[8] = { 0.30, 0.30, 0.32, 1,  0.08, 0.08, 0.09, 1 };
    CGFloat locs[2] = { 0, 1 };
    CSRadial(c, CGPointMake(-1.2, 1.5), 0, CGPointMake(-1.2, 1.5), 6.0, 2, comps, locs, YES);
    CGContextRestoreGState(c);
    CGPathRelease(disc);

    CGPathRef shaft = CSCircle(CGPointZero, 1.9);
    CGContextSaveGState(c);
    CSClipPath(c, shaft);
    CGFloat chrome[12] = { 0.98, 0.98, 0.98, 1,  0.62, 0.63, 0.65, 1,  0.30, 0.30, 0.32, 1 };
    CGFloat clocs[3] = { 0, 0.5, 1 };
    CSRadial(c, CGPointMake(-0.6, 0.7), 0, CGPointMake(-0.6, 0.7), 2.8, 3, chrome, clocs, YES);
    CGContextRestoreGState(c);
    CSStrokeRGBA(c, 0, 0, 0, 0.5);
    CGContextSetLineWidth(c, 0.15);
    CGContextAddPath(c, shaft);
    CGContextStrokePath(c);
    CGPathRelease(shaft);
    CGContextRestoreGState(c);
}

#pragma mark - The deck

static void CSDrawCheek(CGContextRef c, CGRect r, BOOL right, CGFloat scale)
{
    CGImageRef wood = CSCreateWoodImage(r.size.width, r.size.height, scale, right ? 91 : 37);
    CGContextDrawImage(c, r, wood);
    CGImageRelease(wood);

    CGContextSaveGState(c);
    CGContextClipToRect(c, r);
    // A rounded profile: dark where the board turns away at its outer edge, a
    // broad lacquer sheen across the crown, and shadow down into the joint
    // with the faceplate.
    CGFloat comps[24] = {
        0, 0, 0, 0.62,
        0, 0, 0, 0.18,
        1, 0.93, 0.84, 0.13,
        1, 0.93, 0.84, 0.03,
        0, 0, 0, 0.10,
        0, 0, 0, 0.55 };
    CGFloat locs[6] = { 0, 0.10, 0.40, 0.62, 0.86, 1 };
    CGPoint outer = CGPointMake(right ? CGRectGetMaxX(r) : CGRectGetMinX(r), 0);
    CGPoint inner = CGPointMake(right ? CGRectGetMinX(r) : CGRectGetMaxX(r), 0);
    CSLinear(c, outer, inner, 6, comps, locs);

    // Top-lit: the board is brighter where it faces the ceiling.
    CGFloat vcomps[12] = { 1, 0.95, 0.88, 0.10,  0, 0, 0, 0,  0, 0, 0, 0.30 };
    CGFloat vlocs[3] = { 0, 0.35, 1 };
    CSLinear(c, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 3, vcomps, vlocs);

    // Lacquer: a narrow gloss running the length of the board, where its
    // rounded face turns towards the light, brightest near the top.
    CGFloat inset = r.size.width * 0.30;
    CGFloat glossX = right ? CGRectGetMaxX(r) - inset : CGRectGetMinX(r) + inset;
    CGContextSaveGState(c);
    CGContextClipToRect(c, CGRectMake(glossX - 4, r.origin.y, 8, r.size.height));
    // In a layer of its own, so that fading it takes nothing from the wood.
    CGContextBeginTransparencyLayer(c, NULL);
    CGFloat gloss[12] = { 1, 0.96, 0.9, 0,  1, 0.96, 0.9, 0.16,  1, 0.96, 0.9, 0 };
    CGFloat glocs[3] = { 0, 0.5, 1 };
    CSLinear(c, CGPointMake(glossX - 4, 0), CGPointMake(glossX + 4, 0), 3, gloss, glocs);
    CGFloat fade[8] = { 0, 0, 0, 0,  0, 0, 0, 0.6 };
    CGFloat flocs[2] = { 0.15, 1 };
    CGContextSetBlendMode(c, kCGBlendModeDestinationOut);
    CSLinear(c, CGPointMake(0, CGRectGetMaxY(r)), CGPointMake(0, CGRectGetMinY(r)), 2, fade, flocs);
    CGContextEndTransparencyLayer(c);
    CGContextRestoreGState(c);

    // Catch-light along the arris nearest the faceplate.
    CGFloat edgeX = right ? CGRectGetMinX(r) + 2.0 : CGRectGetMaxX(r) - 2.0;
    CSFillRGBA(c, 1, 0.9, 0.78, 0.16);
    CGContextFillRect(c, CGRectMake(edgeX - 0.5, r.origin.y, 1.0, r.size.height));
    CSFillRGBA(c, 0, 0, 0, 0.55);
    CGContextFillRect(c, CGRectMake(right ? CGRectGetMinX(r) : CGRectGetMaxX(r) - 1.0,
                                    r.origin.y, 1.0, r.size.height));
    CGContextRestoreGState(c);
}

static void CSDrawCompartment(CGContextRef c, CGFloat scale)
{
    CGRect door = CSDoorRect();
    CGPathRef bezel = CSRoundRect(door, 9);

    CGContextSaveGState(c);
    CSShadow(c, 0, -3, 8, 0, 0, 0, 0.55);
    CSFillRGBA(c, 0.1, 0.1, 0.1, 1);
    CSFillPath(c, bezel);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    CSClipPath(c, bezel);
    CGFloat top[4] = { 0.22, 0.22, 0.23, 1 }, bottom[4] = { 0.07, 0.07, 0.075, 1 };
    CSVertical(c, door, top, bottom);
    CGImageRef grain = CSCreateGrainImage(door.size.width, door.size.height, scale, 5, 0.10f, 1);
    CGContextDrawImage(c, door, grain);
    CGImageRelease(grain);
    CGContextRestoreGState(c);
    CSInnerShadow(c, bezel, 0, -1.2, 0.8, 1, 1, 1, 0.20);
    CGPathRelease(bezel);

    // The well.
    CGRect well = CSWellRect();
    CGPathRef wp = CSRoundRect(well, 5);
    CGContextSaveGState(c);
    CSClipPath(c, wp);
    CGFloat wtop[4] = { 0.09, 0.09, 0.10, 1 }, wbottom[4] = { 0.15, 0.15, 0.16, 1 };
    CSVertical(c, well, wtop, wbottom);
    CGImageRef wgrain = CSCreateGrainImage(well.size.width, well.size.height, scale, 8, 0.08f, 1);
    CGContextDrawImage(c, well, wgrain);
    CGImageRelease(wgrain);

    // Moulded ribs on the back wall.
    int i;
    for (i = 0; i < 2; i++) {
        CGFloat y = well.origin.y + 58 + i * 150;
        CSFillRGBA(c, 1, 1, 1, 0.035);
        CGContextFillRect(c, CGRectMake(well.origin.x + 8, y, well.size.width - 16, 1));
        CSFillRGBA(c, 0, 0, 0, 0.25);
        CGContextFillRect(c, CGRectMake(well.origin.x + 8, y + 1, well.size.width - 16, 1));
    }

    // What an empty deck shows: spindles, heads, pinch roller, instructions.
    CSDrawSpindle(c, CSHubCentre(0), CS_PT_PER_MM);
    CSDrawSpindle(c, CSHubCentre(1), CS_PT_PER_MM);

    CGFloat mid = CGRectGetMidX(well);
    CSPrinted(c, @"INSERT TAPE", CSFont(CS_FONT_BOLD, 9), 2.2, 0.62,
              CGPointMake(mid, 226), CSAlignCentre);
    CSText(c, @"click to choose a sound file, or drop one here", CSFont(CS_FONT_PRINT, 8), 0.4,
           0.55, 0.55, 0.57, 0.8, CGPointMake(mid, 211), CSAlignCentre);

    // Head block, flanked by the erase head and the capstan with its roller.
    CGFloat baseY = well.origin.y + 5;
    CGRect head = CGRectMake(mid - 22, baseY, 44, 20);
    CGPathRef hp = CSRoundRect(head, 4);
    CGContextSaveGState(c);
    CSShadow(c, 0, -1.5, 3, 0, 0, 0, 0.7);
    CSFillRGBA(c, 0.5, 0.5, 0.5, 1);
    CSFillPath(c, hp);
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    CSClipPath(c, hp);
    CGFloat hcomps[12] = { 0.93, 0.93, 0.94, 1,  0.60, 0.61, 0.63, 1,  0.36, 0.36, 0.38, 1 };
    CGFloat hlocs[3] = { 0, 0.45, 1 };
    CSLinear(c, CGPointMake(0, CGRectGetMaxY(head)), CGPointMake(0, head.origin.y), 3, hcomps, hlocs);
    CSFillRGBA(c, 0.1, 0.1, 0.1, 0.8);
    CGContextFillRect(c, CGRectMake(mid - 0.4, head.origin.y, 0.8, head.size.height));
    CGContextRestoreGState(c);
    CGPathRelease(hp);

    CGRect erase = CGRectMake(mid - 62, baseY + 2, 18, 15);
    CGPathRef ep = CSRoundRect(erase, 3);
    CGContextSaveGState(c);
    CSShadow(c, 0, -1, 2, 0, 0, 0, 0.6);
    CSFillRGBA(c, 0.46, 0.46, 0.48, 1);
    CSFillPath(c, ep);
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    CSClipPath(c, ep);
    CSLinear(c, CGPointMake(0, CGRectGetMaxY(erase)), CGPointMake(0, erase.origin.y), 3, hcomps, hlocs);
    CGContextRestoreGState(c);
    CGPathRelease(ep);

    CGRect roller = CGRectMake(mid + 44, baseY, 22, 21);
    CGPathRef rp = CSRoundRect(roller, 6);
    CGContextSaveGState(c);
    CSShadow(c, 0, -1.5, 3, 0, 0, 0, 0.7);
    CSFillRGBA(c, 0.06, 0.06, 0.06, 1);
    CSFillPath(c, rp);
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    CSClipPath(c, rp);
    CGFloat rcomps[12] = { 0.03, 0.03, 0.03, 1,  0.20, 0.20, 0.21, 1,  0.03, 0.03, 0.03, 1 };
    CGFloat rlocs[3] = { 0, 0.35, 1 };
    CSLinear(c, CGPointMake(roller.origin.x, 0), CGPointMake(CGRectGetMaxX(roller), 0), 3, rcomps, rlocs);
    CGContextRestoreGState(c);
    CGPathRelease(rp);
    CGRect capstan = CGRectMake(mid + 37, baseY + 1, 3.5, 19);
    CGContextSaveGState(c);
    CGContextClipToRect(c, capstan);
    CGFloat ccomps[12] = { 0.45, 0.45, 0.47, 1,  0.97, 0.97, 0.98, 1,  0.35, 0.35, 0.37, 1 };
    CSLinear(c, CGPointMake(capstan.origin.x, 0), CGPointMake(CGRectGetMaxX(capstan), 0), 3, ccomps, hlocs);
    CGContextRestoreGState(c);

    CGContextRestoreGState(c);   // well clip

    CSInnerShadow(c, wp, 0, -4, 11, 0, 0, 0, 0.9);
    CSInnerShadow(c, wp, 0, 1.2, 1, 1, 1, 1, 0.10);
    CSStrokeRGBA(c, 0.02, 0.02, 0.02, 1);
    CGContextSetLineWidth(c, 1.5);
    CGContextAddPath(c, wp);
    CGContextStrokePath(c);
    CGPathRelease(wp);

    CSText(c, @"◀  PUSH EJECT", CSFont(CS_FONT_PRINT, 6.5), 1.6, 0.55, 0.55, 0.57, 0.9,
           CGPointMake(CGRectGetMaxX(door) - 14, door.origin.y + 3.5), CSAlignRight);
    CSText(c, @"CrO₂ · FeCr · NORMAL", CSFont(CS_FONT_PRINT, 6.5), 1.6, 0.55, 0.55, 0.57, 0.9,
           CGPointMake(door.origin.x + 14, door.origin.y + 3.5), CSAlignLeft);
}

static void CSDrawKeySlots(CGContextRef c)
{
    int k;
    for (k = 0; k < CSKeyCount; k++) {
        CGRect slot = CGRectInset(CSKeyHitRect((CSKey)k), -2.5, -2.5);
        CGPathRef sp = CSRoundRect(slot, 5);
        CSFillRGBA(c, 0.035, 0.035, 0.04, 1);
        CSFillPath(c, sp);
        CSInnerShadow(c, sp, 0, -3, 6, 0, 0, 0, 0.95);
        // The faceplate's lip catches light below the slot.
        CSInnerShadow(c, sp, 0, 1, 0.6, 1, 1, 1, 0.12);
        CGPathRelease(sp);
    }
    CSPrinted(c, @"∞  ENDLESS LOOP", CSFont(CS_FONT_BOLD, 7), 2.4, 0.26,
              CGPointMake(CSKeyHitRect(CSKeyEject).origin.x, 28), CSAlignLeft);
    CSPrinted(c, @"TRANSPORT", CSFont(CS_FONT_BOLD, 7), 2.4, 0.26,
              CGPointMake(CGRectGetMaxX(CSKeyHitRect(CSKeyStop)), 28), CSAlignRight);
}

static void CSDrawBrand(CGContextRef c, CGFloat scale)
{
    CGRect plate = CGRectMake(462, 362, 262, 42);
    CGPathRef pp = CSRoundRect(plate, 5);
    CGContextSaveGState(c);
    CSShadow(c, 0, -1.5, 3, 0, 0, 0, 0.5);
    CSFillRGBA(c, 0.08, 0.08, 0.08, 1);
    CSFillPath(c, pp);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    CSClipPath(c, pp);
    CGImageRef brushed = CSCreateBrushedImage(plate.size.width, plate.size.height, scale, 21,
                                              0.10f, 0.6f, 1.0f, 1.0f, 1.04f);
    CGContextDrawImage(c, plate, brushed);
    CGImageRelease(brushed);
    CGFloat sheen[12] = { 1, 1, 1, 0.10,  1, 1, 1, 0.0,  0, 0, 0, 0.35 };
    CGFloat slocs[3] = { 0, 0.5, 1 };
    CSLinear(c, CGPointMake(0, CGRectGetMaxY(plate)), CGPointMake(0, plate.origin.y), 3, sheen, slocs);
    // Glass over the plate: the glossy upper half, crisp where it ends.
    CGRect glassRect = CGRectMake(plate.origin.x + 2, CGRectGetMidY(plate) + 1,
                                  plate.size.width - 4, plate.size.height / 2 - 3);
    CGPathRef glass = CSRoundRect(glassRect, 3.5);
    CSClipPath(c, glass);
    CGFloat gloss[8] = { 1, 1, 1, 0.16,  1, 1, 1, 0.03 };
    CGFloat glocs[2] = { 0, 1 };
    CSLinear(c, CGPointMake(0, CGRectGetMaxY(glassRect)), CGPointMake(0, glassRect.origin.y), 2, gloss, glocs);
    CGPathRelease(glass);
    CGContextRestoreGState(c);
    CSInnerShadow(c, pp, 0, -1, 0.6, 1, 1, 1, 0.22);
    CGPathRelease(pp);

    CGFloat mid = CGRectGetMidX(plate);
    NSFont *brand = CSFont(CS_FONT_BRAND, 20);
    CSText(c, @"CASSETTE", brand, 7.5, 0, 0, 0, 0.6, CGPointMake(mid, 380.4), CSAlignCentre);
    CSText(c, @"CASSETTE", brand, 7.5, 0.90, 0.89, 0.86, 1, CGPointMake(mid, 381), CSAlignCentre);
    NSString *model = @"STEREO CASSETTE DECK  ·  CS-1090";
    NSFont *small = CSFont(CS_FONT_PRINT, 6.2);
    CSText(c, model, small, 2.0, 0.66, 0.66, 0.66, 1, CGPointMake(mid, 368), CSAlignCentre);
    // Amber rules either side of the model line, stopping short of it.
    CGFloat half = CSTextWidth(model, small, 2.0) / 2 + 8;
    CSFillRGBA(c, 0.93, 0.55, 0.14, 0.9);
    CGContextFillRect(c, CGRectMake(plate.origin.x + 16, 370, mid - half - plate.origin.x - 16, 1.2));
    CGContextFillRect(c, CGRectMake(mid + half, 370, CGRectGetMaxX(plate) - 16 - mid - half, 1.2));
}

static void CSDrawCounterAndLamps(CGContextRef c)
{
    CGRect bezel = CGRectMake(468, 284, 84, 44);
    CGPathRef bp = CSRoundRect(bezel, 4);
    CGContextSaveGState(c);
    CSShadow(c, 0, -1.5, 3, 0, 0, 0, 0.55);
    CSFillRGBA(c, 0.07, 0.07, 0.07, 1);
    CSFillPath(c, bp);
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    CSClipPath(c, bp);
    CGFloat top[4] = { 0.20, 0.20, 0.21, 1 }, bottom[4] = { 0.06, 0.06, 0.06, 1 };
    CSVertical(c, bezel, top, bottom);
    CGContextRestoreGState(c);
    CSInnerShadow(c, bp, 0, -1, 0.6, 1, 1, 1, 0.2);
    CGPathRelease(bp);
    int i;
    for (i = 0; i < 3; i++) {
        CGPathRef win = CSRoundRect(CGRectInset(CSCounterDigitRect(i), -1.5, -1.5), 2);
        CSFillRGBA(c, 0, 0, 0, 1);
        CSFillPath(c, win);
        CGPathRelease(win);
    }
    NSFont *label = CSFont(CS_FONT_BOLD, 6.5);
    CSPrinted(c, @"TAPE COUNTER", label, 1.8, 0.2, CGPointMake(CGRectGetMidX(bezel), 339), CSAlignCentre);

    CGRect rev = CSLampLensRect(CSLampReverse), fwd = CSLampLensRect(CSLampForward);
    CGRect ac = CSLampLensRect(CSLampAC), batt = CSLampLensRect(CSLampBattery);
    CGRect groups[2] = { CGRectUnion(rev, fwd), CGRectUnion(ac, batt) };
    for (i = 0; i < 2; i++) {
        CGRect g = CGRectInset(groups[i], -7, -6);
        CGPathRef gp = CSRoundRect(g, 4);
        CGContextSaveGState(c);
        CSShadow(c, 0, -1, 2, 0, 0, 0, 0.45);
        CSFillRGBA(c, 0.08, 0.08, 0.08, 1);
        CSFillPath(c, gp);
        CGContextRestoreGState(c);
        CSInnerShadow(c, gp, 0, -1, 0.6, 1, 1, 1, 0.18);
        CGPathRelease(gp);
    }
    CSPrinted(c, @"AUTO REVERSE", label, 1.8, 0.2, CGPointMake(CGRectGetMidX(groups[0]), 339), CSAlignCentre);
    CSPrinted(c, @"POWER", label, 1.8, 0.2, CGPointMake(CGRectGetMidX(groups[1]), 339), CSAlignCentre);

    NSFont *legend = CSFont(CS_FONT_BOLD, 5.5);
    CSPrinted(c, @"REV", legend, 1.2, 0.24, CGPointMake(CGRectGetMidX(rev), 279), CSAlignCentre);
    CSPrinted(c, @"FWD", legend, 1.2, 0.24, CGPointMake(CGRectGetMidX(fwd), 279), CSAlignCentre);
    CSPrinted(c, @"AC", legend, 1.2, 0.24, CGPointMake(CGRectGetMidX(ac), 279), CSAlignCentre);
    CSPrinted(c, @"BATT", legend, 1.2, 0.24, CGPointMake(CGRectGetMidX(batt), 279), CSAlignCentre);
}

// Angle of the knob's pointer for a volume, radians, counter-clockwise from
// the positive x axis: 0 at seven o'clock, 1 at five o'clock.
static CGFloat CSVolumeAngle(CGFloat v)
{
    return (CGFloat)((225.0 - 270.0 * v) * M_PI / 180.0);
}

static void CSDrawKnobBody(CGContextRef c, CGFloat scale)
{
    CGPoint o = CSKnobCentre();
    CGFloat R = CSKnobRadius(), face = CSKnobPointerRadius();

    // The printed scale.
    int i;
    for (i = 0; i <= 20; i++) {
        BOOL major = (i % 2) == 0;
        CGFloat a = CSVolumeAngle(i / 20.0);
        CGFloat r0 = R + 7, r1 = R + (major ? 17 : 12);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextSetLineWidth(c, major ? 1.5 : 0.9);
        CSStrokeRGBA(c, 1, 1, 1, 0.4);
        CGContextMoveToPoint(c, o.x + r0 * cos(a), o.y + r0 * sin(a) - 0.6);
        CGContextAddLineToPoint(c, o.x + r1 * cos(a), o.y + r1 * sin(a) - 0.6);
        CGContextStrokePath(c);
        CSStrokeRGBA(c, 0.18, 0.18, 0.19, 0.95);
        CGContextMoveToPoint(c, o.x + r0 * cos(a), o.y + r0 * sin(a));
        CGContextAddLineToPoint(c, o.x + r1 * cos(a), o.y + r1 * sin(a));
        CGContextStrokePath(c);
        if (major) {
            NSFont *f = CSFont(CS_FONT_PRINT, 7.5);
            CGFloat rn = R + 27;
            CSPrinted(c, [NSString stringWithFormat:@"%d", i / 2], f, 0, 0.2,
                      CGPointMake(o.x + rn * cos(a), o.y + rn * sin(a) - 2.7), CSAlignCentre);
        }
    }
    CSPrinted(c, @"VOLUME", CSFont(CS_FONT_BOLD, 7), 2.4, 0.2, CGPointMake(o.x, o.y - R - 20), CSAlignCentre);

    // Shadow on the faceplate: a soft one thrown by the knob's height, and a
    // tight dark one where it meets the plate.
    CGPathRef outer = CSCircle(o, R);
    CGContextSaveGState(c);
    CSShadow(c, 2, -9, 16, 0, 0, 0, 0.55);
    CSFillRGBA(c, 0.2, 0.2, 0.2, 1);
    CSFillPath(c, outer);
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    CSShadow(c, 0.5, -2, 3, 0, 0, 0, 0.6);
    CSFillRGBA(c, 0.2, 0.2, 0.2, 1);
    CSFillPath(c, outer);
    CGContextRestoreGState(c);

    // Knurled skirt: fine ridges round the rim, then the room's light over them.
    CGContextSaveGState(c);
    CSClipPath(c, outer);
    CSFillRGBA(c, 0.45, 0.45, 0.46, 1);
    CGContextFillRect(c, CGRectMake(o.x - R, o.y - R, 2 * R, 2 * R));
    int ridges = 150;
    for (i = 0; i < ridges; i++) {
        CGFloat a0 = 2 * M_PI * i / ridges, a1 = 2 * M_PI * (i + 0.5) / ridges;
        CGContextMoveToPoint(c, o.x, o.y);
        CGContextAddLineToPoint(c, o.x + (R + 2) * cos(a0), o.y + (R + 2) * sin(a0));
        CGContextAddLineToPoint(c, o.x + (R + 2) * cos(a1), o.y + (R + 2) * sin(a1));
        CGContextClosePath(c);
    }
    CSFillRGBA(c, 0.80, 0.80, 0.81, 1);
    CGContextFillPath(c);
    CGFloat light[12] = { 1, 1, 1, 0.35,  0.5, 0.5, 0.5, 0.0,  0, 0, 0, 0.55 };
    CGFloat llocs[3] = { 0, 0.45, 1 };
    CSLinear(c, CGPointMake(o.x - R * 0.7, o.y + R * 0.7), CGPointMake(o.x + R * 0.7, o.y - R * 0.7),
             3, light, llocs);
    CGContextRestoreGState(c);
    CSStrokeRGBA(c, 0, 0, 0, 0.5);
    CGContextSetLineWidth(c, 0.8);
    CGContextAddPath(c, outer);
    CGContextStrokePath(c);
    CGPathRelease(outer);

    // Chamfer between skirt and face.
    CGPathRef chamfer = CSCircle(o, face + 2.5);
    CGContextSaveGState(c);
    CSClipPath(c, chamfer);
    CGFloat ch[8] = { 0.98, 0.98, 0.99, 1,  0.30, 0.30, 0.32, 1 };
    CGFloat clocs[2] = { 0, 1 };
    CSLinear(c, CGPointMake(o.x - face, o.y + face), CGPointMake(o.x + face, o.y - face), 2, ch, clocs);
    CGContextRestoreGState(c);
    CGPathRelease(chamfer);

    // Spun face, very slightly domed: lighter towards the lamp, and a broad
    // soft gloss on the upper left.
    CGImageRef spun = CSCreateSpunImage(face, scale, 44, 0.60f);
    CGContextDrawImage(c, CGRectMake(o.x - face, o.y - face, 2 * face, 2 * face), spun);
    CGImageRelease(spun);
    CGPathRef fp = CSCircle(o, face);
    CGContextSaveGState(c);
    CSClipPath(c, fp);
    CGFloat dome[8] = { 1, 1, 1, 0.20,  1, 1, 1, 0 };
    CGFloat dlocs[2] = { 0, 1 };
    CGPoint lamp = CGPointMake(o.x - face * 0.38, o.y + face * 0.42);
    CSRadial(c, lamp, 0, lamp, face * 1.05, 2, dome, dlocs, NO);
    CGFloat away[8] = { 0, 0, 0, 0,  0, 0, 0, 0.16 };
    CGFloat alocs[2] = { 0.55, 1 };
    CSRadial(c, lamp, 0, lamp, face * 1.9, 2, away, alocs, YES);
    CGContextRestoreGState(c);
    // A bright rim where the face turns down into the chamfer, facing the lamp.
    CGContextSaveGState(c);
    CGContextSetLineCap(c, kCGLineCapRound);
    CSStrokeRGBA(c, 1, 1, 1, 0.75);
    CGContextSetLineWidth(c, 0.9);
    CGContextAddArc(c, o.x, o.y, face + 1.2, (CGFloat)(105 * M_PI / 180), (CGFloat)(165 * M_PI / 180), 0);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    CSStrokeRGBA(c, 0, 0, 0, 0.35);
    CGContextSetLineWidth(c, 0.6);
    CGContextAddPath(c, fp);
    CGContextStrokePath(c);
    CGPathRelease(fp);
}

static void CSDrawFaceplate(CGContextRef c, CGRect plate, CGFloat scale)
{
    CGImageRef metal = CSCreateBrushedImage(plate.size.width, plate.size.height, scale, 7,
                                            0.735f, 1.0f, 0.985f, 0.99f, 1.0f);
    CGContextDrawImage(c, plate, metal);
    CGImageRelease(metal);

    CGContextSaveGState(c);
    CGContextClipToRect(c, plate);
    // Lit from above: brighter at the top, falling off towards the floor.
    CGFloat light[12] = { 1, 1, 1, 0.14,  1, 1, 1, 0.0,  0, 0, 0, 0.18 };
    CGFloat locs[3] = { 0, 0.45, 1 };
    CSLinear(c, CGPointMake(0, CGRectGetMaxY(plate)), CGPointMake(0, plate.origin.y), 3, light, locs);
    // The broad, soft reflection of a window in brushed metal, up to the left.
    CGPoint bloom = CGPointMake(plate.origin.x + plate.size.width * 0.28, CGRectGetMaxY(plate) + 30);
    CGFloat soft[8] = { 1, 1, 1, 0.12,  1, 1, 1, 0 };
    CGFloat softLocs[2] = { 0, 1 };
    CSRadial(c, bloom, 0, bloom, plate.size.width * 0.62, 2, soft, softLocs, NO);

    // The cheeks stand proud of the plate and shade it at both ends.
    CGFloat side[8] = { 0, 0, 0, 0.42,  0, 0, 0, 0 };
    CGFloat slocs[2] = { 0, 1 };
    CSLinear(c, CGPointMake(plate.origin.x, 0), CGPointMake(plate.origin.x + 12, 0), 2, side, slocs);
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    CGContextClipToRect(c, plate);
    CGGradientRef g = CSGradient(2, side, slocs);
    CGContextDrawLinearGradient(c, g, CGPointMake(CGRectGetMaxX(plate), 0),
                                CGPointMake(CGRectGetMaxX(plate) - 12, 0), 0);
    CGGradientRelease(g);

    CSFillRGBA(c, 0, 0, 0, 0.45);
    CGContextFillRect(c, CGRectMake(plate.origin.x, plate.origin.y, plate.size.width, 1));
    CGContextRestoreGState(c);

    CSDrawScrew(c, CGPointMake(plate.origin.x + 12, plate.origin.y + 12), 4.2, 0.3, NO);
    CSDrawScrew(c, CGPointMake(plate.origin.x + 12, CGRectGetMaxY(plate) - 12), 4.2, 1.1, NO);
    CSDrawScrew(c, CGPointMake(CGRectGetMaxX(plate) - 12, plate.origin.y + 12), 4.2, 0.8, NO);
    CSDrawScrew(c, CGPointMake(CGRectGetMaxX(plate) - 12, CGRectGetMaxY(plate) - 12), 4.2, 0.1, NO);
}

CGImageRef CSCreateDeckImage(CGFloat scale)
{
    CGContextRef c = CSBegin(CS_DECK_WIDTH, CS_DECK_HEIGHT, scale);
    CGFloat cheek = CS_CHEEK_WIDTH;
    CGRect plate = CGRectMake(cheek, 0, CS_DECK_WIDTH - 2 * cheek, CS_DECK_HEIGHT);

    CSDrawFaceplate(c, plate, scale);
    CSDrawCheek(c, CGRectMake(0, 0, cheek, CS_DECK_HEIGHT), NO, scale);
    CSDrawCheek(c, CGRectMake(CS_DECK_WIDTH - cheek, 0, cheek, CS_DECK_HEIGHT), YES, scale);
    CSDrawCompartment(c, scale);
    CSDrawKeySlots(c);
    CSDrawBrand(c, scale);
    CSDrawCounterAndLamps(c);
    CSDrawKnobBody(c, scale);

    // The handle overhangs the cabinet slightly and shades its top edge: a
    // dark line tight under it, and a softer fall-off below.
    CGFloat shade[12] = { 0, 0, 0, 0.62,  0, 0, 0, 0.22,  0, 0, 0, 0 };
    CGFloat slocs[3] = { 0, 0.3, 1 };
    CSLinear(c, CGPointMake(0, CS_DECK_HEIGHT), CGPointMake(0, CS_DECK_HEIGHT - 11), 3, shade, slocs);
    return CSEnd(c);
}

#pragma mark - The handle

// Leatherette: a pebbled grain lit from above. Each pebble is a bump in a
// smooth noise field; its shading is the field's slope towards the light,
// which is what makes grain read as texture rather than as speckle.
static CGImageRef CSCreateLeatherImage(CGFloat wPt, CGFloat hPt, CGFloat scale, uint32_t seed)
{
    CSPixels p = CSPixelsCreate(CSPixelsFor(wPt, scale), CSPixelsFor(hPt, scale));
    float step = 0.35f;
    CSEachBand(p.h, ^(size_t y0, size_t y1) {
        size_t x, y;
        for (y = y0; y < y1; y++) {
            uint32_t *row = CSRow(&p, y);
            float v = ((float)y + 0.5f) / (float)scale;
            for (x = 0; x < p.w; x++) {
                float u = ((float)x + 0.5f) / (float)scale;
                float below = CSNoise(u * 0.9f, (v - step) * 0.9f, seed);
                float above = CSNoise(u * 0.9f, (v + step) * 0.9f, seed);
                float relief = (above - below) * 1.8f;
                float mottle = CSFbm(u * 0.05f, v * 0.12f, 2, seed + 3) - 0.5f;
                float fine = (CSRand((int)x, (int)y, seed + 9) - 0.5f) * 0.012f;
                float t = 0.085f + 0.045f * relief + 0.025f * mottle + fine;
                row[x] = CSPx(t, t * 0.985f, t * 0.965f, 1);
            }
        }
    });
    return CSPixelsFinish(p);
}

// A saddle stitch: short thread segments sunk into their holes.
static void CSDrawStitching(CGContextRef c, CGFloat y, CGFloat x0, CGFloat x1)
{
    CGFloat x;
    CGContextSetLineCap(c, kCGLineCapRound);
    for (x = x0; x + 2.6 <= x1; x += 4.4) {
        CSStrokeRGBA(c, 0, 0, 0, 0.75);
        CGContextSetLineWidth(c, 1.5);
        CGContextMoveToPoint(c, x - 0.3, y - 0.4);
        CGContextAddLineToPoint(c, x + 2.9, y - 0.4);
        CGContextStrokePath(c);
        CSStrokeRGBA(c, 0.42, 0.41, 0.38, 1);
        CGContextSetLineWidth(c, 0.9);
        CGContextMoveToPoint(c, x, y);
        CGContextAddLineToPoint(c, x + 2.6, y);
        CGContextStrokePath(c);
        CSStrokeRGBA(c, 1, 1, 1, 0.18);
        CGContextSetLineWidth(c, 0.35);
        CGContextMoveToPoint(c, x + 0.3, y + 0.25);
        CGContextAddLineToPoint(c, x + 2.3, y + 0.25);
        CGContextStrokePath(c);
    }
}

CGImageRef CSCreateHandleImage(CGFloat scale)
{
    CGFloat w = CS_DECK_WIDTH, h = CS_HANDLE_HEIGHT, r = CS_WINDOW_CORNER;
    CGContextRef c = CSBegin(w, h, scale);

    // Square at the bottom, where it meets the cabinet; rounded at the top.
    CGMutablePathRef band = CGPathCreateMutable();
    CGPathMoveToPoint(band, NULL, 0, 0);
    CGPathAddLineToPoint(band, NULL, 0, h - r);
    CGPathAddArcToPoint(band, NULL, 0, h, r, h, r);
    CGPathAddLineToPoint(band, NULL, w - r, h);
    CGPathAddArcToPoint(band, NULL, w, h, w, h - r, r);
    CGPathAddLineToPoint(band, NULL, w, 0);
    CGPathCloseSubpath(band);
    CSClipPath(c, band);

    CGImageRef leather = CSCreateLeatherImage(w, h, scale, 71);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), leather);
    CGImageRelease(leather);

    // Padded: the strap is rounded in section, so its crown faces the light
    // and both edges turn away from it -- the top one only just, the bottom
    // one down into shadow where it folds over the cabinet.
    CGFloat pad[20] = { 0, 0, 0, 0.30,  1, 1, 1, 0.10,  1, 1, 1, 0.03,  0, 0, 0, 0.10,  0, 0, 0, 0.62 };
    CGFloat plocs[5] = { 0, 0.16, 0.42, 0.68, 1 };
    CSLinear(c, CGPointMake(0, h), CGPointMake(0, 0), 5, pad, plocs);
    // The sheen of polished leather along the crown, strongest over the
    // middle of the handle and fading towards its ends.
    CGContextSaveGState(c);
    CGContextClipToRect(c, CGRectMake(0, h * 0.62, w, h * 0.26));
    CGFloat sheen[16] = { 1, 1, 1, 0,  1, 1, 1, 0.07,  1, 1, 1, 0.07,  1, 1, 1, 0 };
    CGFloat shlocs[4] = { 0, 0.3, 0.7, 1 };
    CSLinear(c, CGPointMake(0, 0), CGPointMake(w, 0), 4, sheen, shlocs);
    CGContextRestoreGState(c);

    CSDrawStitching(c, h - 4.2, 8, w - 8);
    CSDrawStitching(c, 4.6, 8, w - 8);

    // Catch-light along the crown, and the seam at the bottom.
    CSFillRGBA(c, 1, 1, 1, 0.20);
    CGContextFillRect(c, CGRectMake(0, h - 0.75, w, 0.75));
    CSFillRGBA(c, 0, 0, 0, 0.9);
    CGContextFillRect(c, CGRectMake(0, 0, w, 1));
    CGPathRelease(band);
    return CSEnd(c);
}

void CSDrawHandleTitle(CGContextRef c, NSString *title, BOOL active, CGFloat maxWidth)
{
    if ([title length] == 0) return;
    NSFont *font = CSFont(@"Futura-Medium,AvenirNext-Medium,HelveticaNeue-Medium", 11.5);
    CGFloat kern = 0.9;
    // Long titles are shortened in the middle, keeping the start of an artist
    // and the end of a song, the way the Finder shortens file names.
    NSString *shown = title;
    while (CSTextWidth(shown, font, kern) > maxWidth && [shown length] > 6) {
        NSUInteger n = [shown length], cut = n / 2;
        NSString *head = [shown substringToIndex:cut - 1];
        NSString *tail = [shown substringFromIndex:cut + 1];
        if ([head hasSuffix:@"…"]) head = [head substringToIndex:[head length] - 1];
        if ([tail hasPrefix:@"…"]) tail = [tail substringFromIndex:1];
        shown = [NSString stringWithFormat:@"%@…%@", head, tail];
    }
    CGPoint baseline = CGPointMake(CS_DECK_WIDTH / 2, CS_HANDLE_HEIGHT / 2 - [font capHeight] / 2);
    // Debossed: pressed into the leather, so the lip above it is in shadow and
    // the one below catches the light.
    CSText(c, shown, font, kern, 0, 0, 0, 0.9, CGPointMake(baseline.x, baseline.y + 0.8), CSAlignCentre);
    CSText(c, shown, font, kern, 1, 1, 1, 0.06, CGPointMake(baseline.x, baseline.y - 0.8), CSAlignCentre);
    CSText(c, shown, font, kern, 0.76, 0.75, 0.72, active ? 0.92 : 0.42, baseline, CSAlignCentre);
}

#pragma mark - The cassette

// The label's window: a slot with round ends centred on the hubs.
static CGPathRef CSWindowPathMM(CGFloat grow)
{
    CGPoint l = CGPointMake(CS_SHELL_W_MM / 2 - CS_HUB_SPACING_MM / 2, CS_HUB_Y_MM);
    CGPoint r = CGPointMake(CS_SHELL_W_MM / 2 + CS_HUB_SPACING_MM / 2, CS_HUB_Y_MM);
    CGFloat rad = CS_WINDOW_R_MM + grow;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, l.x, l.y + rad);
    CGPathAddLineToPoint(p, NULL, r.x, r.y + rad);
    CGPathAddArc(p, NULL, r.x, r.y, rad, (CGFloat)M_PI_2, (CGFloat)-M_PI_2, true);
    CGPathAddLineToPoint(p, NULL, l.x, l.y - rad);
    CGPathAddArc(p, NULL, l.x, l.y, rad, (CGFloat)-M_PI_2, (CGFloat)M_PI_2, true);
    CGPathCloseSubpath(p);
    return p;
}

CGImageRef CSCreateCassetteInteriorImage(CGFloat scale)
{
    CGRect r = CSCassetteRect();
    CGContextRef c = CSBegin(r.size.width, r.size.height, scale);
    CGRect all = CGRectMake(0, 0, r.size.width, r.size.height);
    // Behind the reels: the far half of the shell and the translucent liner
    // sheet, lit a little through the far window.
    CGFloat top[4] = { 0.40, 0.40, 0.41, 1 }, bottom[4] = { 0.20, 0.20, 0.21, 1 };
    CSVertical(c, all, top, bottom);
    CGImageRef grain = CSCreateGrainImage(r.size.width, r.size.height, scale, 12, 0.10f, 1);
    CGContextDrawImage(c, all, grain);
    CGImageRelease(grain);
    CGContextScaleCTM(c, CS_PT_PER_MM, CS_PT_PER_MM);
    // The liner's embossed diagonal pattern, barely there.
    CGContextSaveGState(c);
    CGPathRef w = CSWindowPathMM(0);
    CSClipPath(c, w);
    CGPathRelease(w);
    CSStrokeRGBA(c, 1, 1, 1, 0.06);
    CGContextSetLineWidth(c, 0.35);
    CGFloat x;
    for (x = -40; x < 140; x += 1.6) {
        CGContextMoveToPoint(c, x, 0);
        CGContextAddLineToPoint(c, x + 40, 64);
    }
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    return CSEnd(c);
}

static void CSDrawHandwriting(CGContextRef c, NSString *text, CGFloat left, CGFloat right,
                              CGFloat baseline, CGFloat size, CGFloat tilt)
{
    if ([text length] == 0) return;
    CGFloat avail = right - left;
    NSFont *font = CSFont(CS_FONT_HAND, size);
    CGFloat w = CSTextWidth(text, font, 0.05);
    // Shrink to fit, down to a point; past that, cut it short the way you
    // would when the label runs out.
    if (w > avail) {
        CGFloat s = MAX(size * 0.7, size * avail / w);
        font = CSFont(CS_FONT_HAND, s);
        w = CSTextWidth(text, font, 0.05);
        while (w > avail && [text length] > 2) {
            text = [[text substringToIndex:[text length] - 2] stringByAppendingString:@"…"];
            text = [text stringByReplacingOccurrencesOfString:@" …" withString:@"…"];
            w = CSTextWidth(text, font, 0.05);
        }
    }
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, left + 0.6, baseline);
    CGContextRotateCTM(c, tilt);
    // Felt-tip ink bleeds very slightly into paper.
    CSShadow(c, 0, 0, 0.25, 0.10, 0.14, 0.40, 0.6);
    CSText(c, text, font, 0.05, 0.11, 0.15, 0.42, 0.95, CGPointZero, CSAlignLeft);
    CGContextRestoreGState(c);
}

CGImageRef CSCreateBlankCassetteFaceImage(CGFloat scale)
{
    CGRect cr = CSCassetteRect();
    CGContextRef c = CSBegin(cr.size.width, cr.size.height, scale);
    CGRect shellPt = CGRectMake(0, 0, cr.size.width, cr.size.height);

    // Matte plastic grain, generated at pixel resolution before switching to mm.
    CGImageRef grain = CSCreateGrainImage(cr.size.width, cr.size.height, scale, 31, 0.07f, 1);
    CGImageRef paper = CSCreateGrainImage(cr.size.width, cr.size.height, scale, 57, 0.05f, 1);

    CGContextScaleCTM(c, CS_PT_PER_MM, CS_PT_PER_MM);
    CGRect shell = CGRectMake(0, 0, CS_SHELL_W_MM, CS_SHELL_H_MM);
    CGPathRef sp = CSRoundRect(shell, 2.6);

    CGContextSaveGState(c);
    CSClipPath(c, sp);
    CGFloat stop[4] = { 0.19, 0.19, 0.20, 1 }, sbottom[4] = { 0.10, 0.10, 0.11, 1 };
    CSVertical(c, shell, stop, sbottom);
    CGContextDrawImage(c, CGRectMake(0, 0, shellPt.size.width / CS_PT_PER_MM,
                                     shellPt.size.height / CS_PT_PER_MM), grain);
    CGContextRestoreGState(c);
    CSInnerShadow(c, sp, 0.15, -0.25, 0.35, 1, 1, 1, 0.22);
    CSInnerShadow(c, sp, -0.2, 0.3, 0.5, 0, 0, 0, 0.6);

    // The raised section along the bottom, where the tape runs past the head.
    CGMutablePathRef trap = CGPathCreateMutable();
    CGPathMoveToPoint(trap, NULL, 12.6, 0.4);
    CGPathAddLineToPoint(trap, NULL, 87.8, 0.4);
    CGPathAddLineToPoint(trap, NULL, 81.0, 12.3);
    CGPathAddLineToPoint(trap, NULL, 19.4, 12.3);
    CGPathCloseSubpath(trap);
    CGContextSaveGState(c);
    CSShadow(c, 0, -0.25, 0.5, 0, 0, 0, 0.7);
    CSFillRGBA(c, 0.17, 0.17, 0.18, 1);
    CSFillPath(c, trap);
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    CSClipPath(c, trap);
    CGFloat tt[4] = { 0.23, 0.23, 0.24, 1 }, tb[4] = { 0.12, 0.12, 0.13, 1 };
    CSVertical(c, CGRectMake(12, 0, 76, 12.3), tt, tb);
    CGContextRestoreGState(c);
    CSInnerShadow(c, trap, 0, -0.2, 0.2, 1, 1, 1, 0.25);
    CGPathRelease(trap);

    // The tape itself, glimpsed through the openings along the bottom edge.
    CSFillRGBA(c, 0.24, 0.14, 0.08, 1);
    CGContextFillRect(c, CGRectMake(21, 0.35, 58.4, 0.55));

    // Guide holes and pad openings.
    CGFloat hx[2] = { 27.2, 73.2 };
    int i;
    for (i = 0; i < 2; i++) {
        CGPathRef h = CSCircle(CGPointMake(hx[i], 5.6), 1.75);
        CSFillRGBA(c, 0.02, 0.02, 0.02, 1);
        CSFillPath(c, h);
        CSInnerShadow(c, h, 0, -0.3, 0.4, 0, 0, 0, 1);
        CGPathRelease(h);
        CGPathRef sq = CSRoundRect(CGRectMake(i ? 57.6 : 39.8, 2.4, 3.0, 2.2), 0.3);
        CSFillRGBA(c, 0.02, 0.02, 0.02, 1);
        CSFillPath(c, sq);
        CGPathRelease(sq);
    }

    CSDrawScrew(c, CGPointMake(50.2, 7.6), 1.45, 0.5, NO);
    CSDrawScrew(c, CGPointMake(4.4, 4.4), 1.5, 0.2, NO);
    CSDrawScrew(c, CGPointMake(96.0, 4.4), 1.5, 1.0, NO);
    CSDrawScrew(c, CGPointMake(4.4, 59.4), 1.5, 0.7, NO);
    CSDrawScrew(c, CGPointMake(96.0, 59.4), 1.5, 1.3, NO);

    // The label, with its top corners clipped to clear the screws.
    CGMutablePathRef label = CGPathCreateMutable();
    CGPathMoveToPoint(label, NULL, 3.7, 14.3);
    CGPathAddLineToPoint(label, NULL, 96.7, 14.3);
    CGPathAddLineToPoint(label, NULL, 96.7, 54.8);
    CGPathAddLineToPoint(label, NULL, 91.9, 60.3);
    CGPathAddLineToPoint(label, NULL, 8.5, 60.3);
    CGPathAddLineToPoint(label, NULL, 3.7, 54.8);
    CGPathCloseSubpath(label);

    CGContextSaveGState(c);
    CSShadow(c, 0.05, -0.12, 0.25, 0, 0, 0, 0.55);
    CSFillRGBA(c, 0.94, 0.915, 0.85, 1);
    CSFillPath(c, label);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    CSClipPath(c, label);
    // Paper that has sat in a car's glovebox: warmer and darker at the edges.
    CGFloat age[8] = { 1, 1, 0.97, 0.0,  0.55, 0.42, 0.22, 0.20 };
    CGFloat alocs[2] = { 0.35, 1 };
    CSRadial(c, CGPointMake(50, 37), 0, CGPointMake(50, 37), 58, 2, age, alocs, YES);
    CGContextDrawImage(c, CGRectMake(0, 0, shellPt.size.width / CS_PT_PER_MM,
                                     shellPt.size.height / CS_PT_PER_MM), paper);

    // The printed band: three stripes in the colours of 1976.
    CGFloat bands[3][3] = { { 0.50, 0.16, 0.07 }, { 0.85, 0.37, 0.09 }, { 0.95, 0.66, 0.17 } };
    for (i = 0; i < 3; i++) {
        CSFillRGBA(c, bands[i][0], bands[i][1], bands[i][2], 0.97);
        CGContextFillRect(c, CGRectMake(0, 14.3 + i * 1.75, 100.4, 1.75));
    }
    CSText(c, @"LOW NOISE", CSFont(CS_FONT_BOLD, 1.55), 0.35, 1, 0.97, 0.9, 0.95,
           CGPointMake(7.0, 16.45), CSAlignLeft);
    CSText(c, @"C60  ·  NORMAL BIAS  ·  TYPE I", CSFont(CS_FONT_BOLD, 1.55), 0.25, 1, 0.97, 0.9, 0.95,
           CGPointMake(93.4, 16.45), CSAlignRight);

    // Side mark, writing lines, cassette length.
    CGPathRef ring = CSCircle(CGPointMake(10.2, 53.4), 3.0);
    CSStrokeRGBA(c, 0.50, 0.16, 0.07, 0.95);
    CGContextSetLineWidth(c, 0.4);
    CGContextAddPath(c, ring);
    CGContextStrokePath(c);
    CGPathRelease(ring);
    CSText(c, @"A", CSFont(@"Futura-Bold,HelveticaNeue-Bold", 3.8), 0, 0.50, 0.16, 0.07, 0.95,
           CGPointMake(10.2, 52.05), CSAlignCentre);
    CSStrokeRGBA(c, 0.52, 0.47, 0.42, 0.55);
    CGContextSetLineWidth(c, 0.16);
    CGFloat lines[2] = { 49.4, 55.2 };
    for (i = 0; i < 2; i++) {
        CGContextMoveToPoint(c, 15.2, lines[i]);
        CGContextAddLineToPoint(c, 88.0, lines[i]);
    }
    CGContextStrokePath(c);
    CSText(c, @"60", CSFont(@"Futura-Bold,HelveticaNeue-Bold", 2.6), 0.1, 0.50, 0.16, 0.07, 0.95,
           CGPointMake(92.4, 51.0), CSAlignCentre);
    CSText(c, @"MIN", CSFont(CS_FONT_BOLD, 1.2), 0.2, 0.50, 0.16, 0.07, 0.9,
           CGPointMake(92.4, 49.3), CSAlignCentre);

    // Printed frame around the window.
    CGPathRef frame = CSWindowPathMM(0.9);
    CSStrokeRGBA(c, 0.42, 0.24, 0.13, 0.85);
    CGContextSetLineWidth(c, 0.3);
    CGContextAddPath(c, frame);
    CGContextStrokePath(c);
    CGPathRelease(frame);
    CGContextRestoreGState(c);   // label clip

    CGPathRelease(label);

    // Cut the window out of shell and label alike, then put the plastic back.
    CGPathRef win = CSWindowPathMM(0);
    CGContextSaveGState(c);
    CGContextSetBlendMode(c, kCGBlendModeClear);
    CSFillPath(c, win);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    CSClipPath(c, win);
    CSFillRGBA(c, 0.85, 0.9, 1.0, 0.04);
    CGContextFillRect(c, shell);
    // Glare off the upper half, and a crisp line where the moulding bends.
    CGFloat glare[12] = { 1, 1, 1, 0.20,  1, 1, 1, 0.05,  1, 1, 1, 0 };
    CGFloat glocs[3] = { 0, 0.35, 1 };
    CSLinear(c, CGPointMake(0, CS_HUB_Y_MM + CS_WINDOW_R_MM), CGPointMake(0, CS_HUB_Y_MM - 2),
             3, glare, glocs);
    CSFillRGBA(c, 1, 1, 1, 0.08);
    CGMutablePathRef streak = CGPathCreateMutable();
    CGPathMoveToPoint(streak, NULL, 58, 64);
    CGPathAddLineToPoint(streak, NULL, 66, 64);
    CGPathAddLineToPoint(streak, NULL, 52, 0);
    CGPathAddLineToPoint(streak, NULL, 44, 0);
    CGPathCloseSubpath(streak);
    CSFillPath(c, streak);
    CGPathRelease(streak);
    // The scale moulded into the window, between the hubs.
    CSStrokeRGBA(c, 1, 1, 1, 0.5);
    CGContextSetLineWidth(c, 0.18);
    for (i = 0; i <= 10; i++) {
        CGFloat x = 41.2 + i * 1.8;
        CGFloat len = (i % 5 == 0) ? 1.6 : 0.9;
        CGContextMoveToPoint(c, x, CS_HUB_Y_MM + CS_WINDOW_R_MM - 1.4);
        CGContextAddLineToPoint(c, x, CS_HUB_Y_MM + CS_WINDOW_R_MM - 1.4 - len);
    }
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    // The thickness of the shell at the cut edge.
    CSInnerShadow(c, win, 0, -0.45, 0.55, 0, 0, 0, 0.85);
    CGContextSaveGState(c);
    CSClipPath(c, win);
    CSStrokeRGBA(c, 0, 0, 0, 0.55);
    CGContextSetLineWidth(c, 0.8);
    CGContextAddPath(c, win);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    CGPathRelease(win);

    CGPathRelease(sp);
    CGImageRelease(grain);
    CGImageRelease(paper);
    return CSEnd(c);
}

CGImageRef CSCreateWrittenCassetteFaceImage(CGImageRef blank, CGFloat scale,
                                            NSString *title, NSString *artist)
{
    CGRect cr = CSCassetteRect();
    CGContextRef c = CSBegin(cr.size.width, cr.size.height, scale);
    // Pixel for pixel: the blank was drawn into a context of this very size.
    CGContextDrawImage(c, CGRectMake(0, 0, CGImageGetWidth(blank) / scale,
                                     CGImageGetHeight(blank) / scale), blank);
    CGContextScaleCTM(c, CS_PT_PER_MM, CS_PT_PER_MM);
    // Title on the upper line, artist below it. The writing stays on the label,
    // clear of the window, so it can go on after the window has been cut.
    NSString *upper = title, *lower = artist;
    if ([upper length] == 0) { upper = lower; lower = nil; }
    CSDrawHandwriting(c, upper, 15.4, 87.6, 55.7, 4.4, (CGFloat)(0.9 * M_PI / 180));
    CSDrawHandwriting(c, lower, 16.4, 87.6, 49.9, 3.6, (CGFloat)(-0.5 * M_PI / 180));
    return CSEnd(c);
}

CGImageRef CSCreateCassetteFaceImage(CGFloat scale, NSString *title, NSString *artist)
{
    CGImageRef blank = CSCreateBlankCassetteFaceImage(scale);
    CGImageRef face = CSCreateWrittenCassetteFaceImage(blank, scale, title, artist);
    CGImageRelease(blank);
    return face;
}

CGRect CSCassetteShadowRect(void)
{
    return CGRectInset(CSCassetteRect(), -14, -14);
}

CGImageRef CSCreateCassetteShadowImage(CGFloat scale)
{
    CGRect frame = CSCassetteShadowRect(), cr = CSCassetteRect();
    CGContextRef c = CSBegin(frame.size.width, frame.size.height, scale);
    CGRect shell = CGRectOffset(cr, -frame.origin.x, -frame.origin.y);
    CGPathRef p = CSRoundRect(shell, 2.6 * CS_PT_PER_MM);
    CSShadow(c, 1.5, -3.5, 7, 0, 0, 0, 0.75);
    CSFillRGBA(c, 0, 0, 0, 1);
    CSFillPath(c, p);
    CGPathRelease(p);
    return CSEnd(c);
}

CGImageRef CSCreatePackImage(CGFloat radiusPt, CGFloat scale)
{
    CGFloat half = radiusPt + 1;
    size_t side = CSPixelsFor(2 * half, scale);
    CSPixels p = CSPixelsCreate(side, side);
    float c = (float)side / 2.0f;
    float R = (float)(radiusPt * scale);
    float pxPerMM = (float)(CS_PT_PER_MM * scale);
    float light = (float)(135.0 * M_PI / 180.0);
    CSEachBand(p.h, ^(size_t y0, size_t y1) {
        size_t x, y;
        for (y = y0; y < y1; y++) {
            uint32_t *row = CSRow(&p, y);
            for (x = 0; x < p.w; x++) {
                float dx = (float)x + 0.5f - c, dy = (float)y + 0.5f - c;
                float r = sqrtf(dx * dx + dy * dy);
                float cover = CSClamp01(R - r + 0.5f);
                if (cover <= 0) { row[x] = 0; continue; }
                float mm = r / pxPerMM;
                float phi = atan2f(dy, dx);
                float k = fabsf(cosf(phi - light));
                // Satin sheen of wound tape edges, a fine ring for every few
                // turns, and slower bands where the winding tension changed.
                float v = 0.14f + 0.20f * powf(k, 9.0f) + 0.04f * k
                        + (CSRand((int)(mm * 22.0f), 7, 5) - 0.5f) * 0.035f
                        + (CSNoise(mm * 1.3f, 0.5f, 11) - 0.5f) * 0.05f;
                // The cut edge of the outermost turns catches the light.
                float edge = CSClamp01(1.0f - (R - r) / (0.35f * pxPerMM));
                v += edge * 0.10f * (0.4f + 0.6f * k);
                row[x] = CSPx(v * 1.65f, v * 1.08f, v * 0.70f, cover);
            }
        }
    });
    return CSPixelsFinish(p);
}

CGImageRef CSCreateHubImage(CGFloat scale)
{
    CGFloat half = CS_HUB_IMAGE_R_MM * CS_PT_PER_MM;
    CGContextRef c = CSBegin(2 * half, 2 * half, scale);
    CGContextTranslateCTM(c, half, half);
    CGContextScaleCTM(c, CS_PT_PER_MM, CS_PT_PER_MM);

    // Behind the hub: the hole through the cassette, and the spindle in it.
    CGPathRef outer = CSCircle(CGPointZero, 11.0);
    CGPathRef hole = CSCircle(CGPointZero, 7.8);
    CSFillRGBA(c, 0.035, 0.035, 0.04, 1);
    CSFillPath(c, hole);
    CGPathRelease(hole);
    CSDrawSpindle(c, CGPointZero, 1.0);

    // The ring, with the hole cut out of it.
    CGMutablePathRef ring = CGPathCreateMutable();
    CGPathAddEllipseInRect(ring, NULL, CGRectMake(-11, -11, 22, 22));
    CGPathAddEllipseInRect(ring, NULL, CGRectMake(-7.7, -7.7, 15.4, 15.4));
    CGContextSaveGState(c);
    CGContextAddPath(c, ring);
    CGContextEOClip(c);
    CGFloat ivory[8] = { 0.95, 0.935, 0.89, 1,  0.86, 0.84, 0.79, 1 };
    CGFloat ilocs[2] = { 0, 1 };
    CSRadial(c, CGPointZero, 7.7, CGPointZero, 11.0, 2, ivory, ilocs, YES);
    CGContextRestoreGState(c);

    // Six drive teeth, moulded in one piece with the ring.
    int i;
    for (i = 0; i < 6; i++) {
        CGContextSaveGState(c);
        CGContextRotateCTM(c, (CGFloat)(i * M_PI / 3));
        CGPathRef tooth = CSRoundRect(CGRectMake(5.7, -0.78, 2.4, 1.56), 0.45);
        CSShadow(c, 0.1, -0.1, 0.25, 0, 0, 0, 0.6);
        CSFillRGBA(c, 0.90, 0.885, 0.84, 1);
        CSFillPath(c, tooth);
        CGPathRelease(tooth);
        CGContextRestoreGState(c);
    }

    // A moulded groove, three ejector-pin marks, and the leader clamp: the
    // details that make it visible that the hub is turning.
    CSStrokeRGBA(c, 0.70, 0.67, 0.61, 0.9);
    CGContextSetLineWidth(c, 0.22);
    CGPathRef groove = CSCircle(CGPointZero, 9.35);
    CGContextAddPath(c, groove);
    CGContextStrokePath(c);
    CGPathRelease(groove);
    for (i = 0; i < 3; i++) {
        CGFloat a = (CGFloat)(M_PI / 6 + i * 2 * M_PI / 3 + M_PI / 3);
        CGPathRef pin = CSCircle(CGPointMake(8.5 * cos(a), 8.5 * sin(a)), 0.42);
        CSFillRGBA(c, 0.80, 0.78, 0.73, 1);
        CSFillPath(c, pin);
        CGPathRelease(pin);
    }
    CGContextSaveGState(c);
    CGContextRotateCTM(c, (CGFloat)M_PI_2);
    CGPathRef clamp = CSRoundRect(CGRectMake(8.9, -1.35, 2.3, 2.7), 0.25);
    CSFillRGBA(c, 0.82, 0.80, 0.75, 1);
    CSFillPath(c, clamp);
    CSStrokeRGBA(c, 0.45, 0.42, 0.38, 0.9);
    CGContextSetLineWidth(c, 0.16);
    CGContextAddPath(c, clamp);
    CGContextStrokePath(c);
    CGPathRelease(clamp);
    CGContextRestoreGState(c);

    CSStrokeRGBA(c, 0.52, 0.49, 0.44, 0.9);
    CGContextSetLineWidth(c, 0.22);
    CGContextAddPath(c, outer);
    CGContextStrokePath(c);
    CGPathRelease(outer);
    CGPathRelease(ring);
    return CSEnd(c);
}

CGImageRef CSCreateHubShineImage(CGFloat scale)
{
    CGFloat half = CS_HUB_IMAGE_R_MM * CS_PT_PER_MM;
    CGContextRef c = CSBegin(2 * half, 2 * half, scale);
    CGContextTranslateCTM(c, half, half);
    CGContextScaleCTM(c, CS_PT_PER_MM, CS_PT_PER_MM);

    // Occlusion inside the hole: the rim shades the spindle below it.
    CGPathRef hole = CSCircle(CGPointZero, 7.7);
    CGContextSaveGState(c);
    CSClipPath(c, hole);
    CGFloat ao[8] = { 0, 0, 0, 0.0,  0, 0, 0, 0.65 };
    CGFloat aolocs[2] = { 0.72, 1 };
    CSRadial(c, CGPointMake(0.4, -0.5), 0, CGPointZero, 7.7, 2, ao, aolocs, NO);
    CGContextRestoreGState(c);
    CGPathRelease(hole);

    // The ring's lighting, which stays put while the ring turns under it.
    CGMutablePathRef ring = CGPathCreateMutable();
    CGPathAddEllipseInRect(ring, NULL, CGRectMake(-11, -11, 22, 22));
    CGPathAddEllipseInRect(ring, NULL, CGRectMake(-7.7, -7.7, 15.4, 15.4));
    CGContextSaveGState(c);
    CGContextAddPath(c, ring);
    CGContextEOClip(c);
    CGFloat hi[8] = { 1, 1, 1, 0.42,  1, 1, 1, 0 };
    CGFloat hilocs[2] = { 0, 1 };
    CSRadial(c, CGPointMake(-4.2, 5.2), 0, CGPointMake(-4.2, 5.2), 8.5, 2, hi, hilocs, NO);
    CGFloat lo[8] = { 0, 0, 0, 0.22,  0, 0, 0, 0 };
    CSRadial(c, CGPointMake(5.0, -5.5), 0, CGPointMake(5.0, -5.5), 9.0, 2, lo, hilocs, NO);
    CGContextRestoreGState(c);
    CGPathRelease(ring);
    return CSEnd(c);
}

#pragma mark - Door, keys, knob, counter, lamps

CGImageRef CSCreateDoorGlassImage(CGFloat scale)
{
    CGRect well = CSWellRect();
    CGContextRef c = CSBegin(well.size.width, well.size.height, scale);
    CGRect r = CGRectMake(0, 0, well.size.width, well.size.height);
    CGPathRef glass = CSRoundRect(r, 5);
    CSClipPath(c, glass);

    // Smoked acrylic.
    CSFillRGBA(c, 0.02, 0.025, 0.035, 0.26);
    CGContextFillRect(c, r);

    // Darker towards the edges, where you look through it at an angle.
    CGFloat vig[8] = { 0, 0, 0, 0,  0, 0, 0, 0.30 };
    CGFloat vlocs[2] = { 0.55, 1 };
    CGContextSaveGState(c);
    CGContextScaleCTM(c, 1, r.size.height / r.size.width);
    CGPoint mid = CGPointMake(r.size.width / 2, r.size.width / 2);
    CSRadial(c, mid, 0, mid, r.size.width * 0.72, 2, vig, vlocs, YES);
    CGContextRestoreGState(c);

    // The room's window reflected in it: a broad soft glare from the top left
    // and two hard-edged diagonal bands.
    CGFloat glare[12] = { 1, 1, 1, 0.17,  1, 1, 1, 0.04,  1, 1, 1, 0 };
    CGFloat glocs[3] = { 0, 0.4, 1 };
    CSLinear(c, CGPointMake(0, r.size.height), CGPointMake(r.size.width * 0.55, r.size.height * 0.35),
             3, glare, glocs);
    CGMutablePathRef band = CGPathCreateMutable();
    CGPathMoveToPoint(band, NULL, 196, r.size.height);
    CGPathAddLineToPoint(band, NULL, 250, r.size.height);
    CGPathAddLineToPoint(band, NULL, 118, 0);
    CGPathAddLineToPoint(band, NULL, 64, 0);
    CGPathCloseSubpath(band);
    CSFillRGBA(c, 1, 1, 1, 0.045);
    CSFillPath(c, band);
    CGPathRelease(band);
    CGMutablePathRef thin = CGPathCreateMutable();
    CGPathMoveToPoint(thin, NULL, 262, r.size.height);
    CGPathAddLineToPoint(thin, NULL, 272, r.size.height);
    CGPathAddLineToPoint(thin, NULL, 140, 0);
    CGPathAddLineToPoint(thin, NULL, 130, 0);
    CGPathCloseSubpath(thin);
    CSFillRGBA(c, 1, 1, 1, 0.06);
    CSFillPath(c, thin);
    CGPathRelease(thin);

    // Polished edge.
    CSInnerShadow(c, glass, 0, -1.2, 1.2, 1, 1, 1, 0.22);
    CSInnerShadow(c, glass, 0, 1.5, 2, 0, 0, 0, 0.5);
    CGPathRelease(glass);
    return CSEnd(c);
}

// The transport icons, drawn as shapes rather than glyphs so that they look the
// same whatever fonts the machine has.
static void CSAddKeyIcon(CGContextRef c, CSKey key, CGPoint o)
{
    switch (key) {
        case CSKeyEject:
            CGContextMoveToPoint(c, o.x - 8, o.y - 1);
            CGContextAddLineToPoint(c, o.x + 8, o.y - 1);
            CGContextAddLineToPoint(c, o.x, o.y + 8);
            CGContextClosePath(c);
            CGContextAddRect(c, CGRectMake(o.x - 8, o.y - 6, 16, 2.8));
            break;
        case CSKeyPlay:
            CGContextMoveToPoint(c, o.x - 6, o.y - 7.5);
            CGContextAddLineToPoint(c, o.x + 8, o.y);
            CGContextAddLineToPoint(c, o.x - 6, o.y + 7.5);
            CGContextClosePath(c);
            break;
        case CSKeyPause:
            CGContextAddRect(c, CGRectMake(o.x - 6.5, o.y - 7, 4.6, 14));
            CGContextAddRect(c, CGRectMake(o.x + 1.9, o.y - 7, 4.6, 14));
            break;
        default:
            CGContextAddRect(c, CGRectMake(o.x - 6.5, o.y - 6.5, 13, 13));
            break;
    }
}

CGImageRef CSCreateKeyImage(CSKey key, BOOL down, CGFloat scale)
{
    CGRect frame = CSKeyRect(key), hit = CSKeyHitRect(key);
    CGContextRef c = CSBegin(frame.size.width, frame.size.height, scale);
    CGRect local = CGRectOffset(hit, -frame.origin.x, -frame.origin.y);

    // Raised, the key shows 9 pt of its lower side under the face; pressed,
    // it has travelled back into the slot and shows 2.
    CGFloat depth = down ? 2 : 9;
    CGRect face = CGRectMake(local.origin.x, local.origin.y + depth,
                             local.size.width, local.size.height - 9);
    CGRect body = CGRectMake(face.origin.x, local.origin.y, face.size.width,
                             face.size.height + depth);

    CGPathRef bp = CSRoundRect(body, 4.5);
    CGContextSaveGState(c);
    CSShadow(c, 0, down ? -0.5 : -3, down ? 1.5 : 5, 0, 0, 0, 0.85);
    CSFillRGBA(c, 0.35, 0.35, 0.36, 1);
    CSFillPath(c, bp);
    CGContextRestoreGState(c);
    // The front of the key, below its face: the rounded edge catches the light
    // at the top and the side falls away into shadow towards the slot.
    CGContextSaveGState(c);
    CSClipPath(c, bp);
    CGFloat side[12] = { 0.74, 0.74, 0.75, 1,  0.42, 0.42, 0.43, 1,  0.17, 0.17, 0.18, 1 };
    CGFloat slocs[3] = { 0, 0.3, 1 };
    CSLinear(c, CGPointMake(0, face.origin.y + 1), CGPointMake(0, body.origin.y), 3, side, slocs);
    CGContextRestoreGState(c);
    CGPathRelease(bp);

    CGPathRef fp = CSRoundRect(face, 4.5);
    CGContextSaveGState(c);
    CSClipPath(c, fp);
    CGImageRef brushed = CSCreateBrushedImage(face.size.width, face.size.height, scale,
                                              40 + (uint32_t)key, down ? 0.66f : 0.76f,
                                              0.9f, 0.985f, 0.99f, 1.0f);
    CGContextDrawImage(c, face, brushed);
    CGImageRelease(brushed);
    // Slightly crowned, so it is brighter across the top.
    CGFloat crown[12] = { 1, 1, 1, down ? 0.06 : 0.20,  1, 1, 1, 0,  0, 0, 0, down ? 0.22 : 0.14 };
    CGFloat clocs[3] = { 0, 0.5, 1 };
    CSLinear(c, CGPointMake(0, CGRectGetMaxY(face)), CGPointMake(0, face.origin.y), 3, crown, clocs);

    // Engraved icon and legend.
    CGPoint o = CGPointMake(CGRectGetMidX(face), face.origin.y + face.size.height * 0.60);
    CSFillRGBA(c, 1, 1, 1, 0.45);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, -0.7);
    CSAddKeyIcon(c, key, o);
    CGContextFillPath(c);
    CGContextRestoreGState(c);
    CSFillRGBA(c, 0.16, 0.16, 0.17, 0.92);
    CSAddKeyIcon(c, key, o);
    CGContextFillPath(c);
    static NSString *const names[CSKeyCount] = { @"EJECT", @"PLAY", @"PAUSE", @"STOP" };
    CSPrinted(c, names[key], CSFont(CS_FONT_BOLD, 6.5), 1.8, 0.2,
              CGPointMake(o.x, face.origin.y + 7), CSAlignCentre);
    CGContextRestoreGState(c);

    // Clear lacquer over the brushed face: a glossy reflection across the top
    // half with a crisp lower edge, the way light sits on an Aqua button. A
    // pressed key has sunk back under the lip of the slot, out of the light.
    CGRect glossRect = CGRectMake(face.origin.x + 2.5, face.origin.y + face.size.height * 0.53,
                                  face.size.width - 5, face.size.height * 0.47 - 1.5);
    CGPathRef gp = CSRoundRect(glossRect, 3.5);
    CGContextSaveGState(c);
    CSClipPath(c, gp);
    CGFloat gloss[8] = { 1, 1, 1, down ? 0.13 : 0.34,  1, 1, 1, down ? 0.01 : 0.05 };
    CGFloat glocs[2] = { 0, 1 };
    CSLinear(c, CGPointMake(0, CGRectGetMaxY(glossRect)), CGPointMake(0, glossRect.origin.y),
             2, gloss, glocs);
    CGContextRestoreGState(c);
    CGPathRelease(gp);

    CSInnerShadow(c, fp, 0, -1, 0.5, 1, 1, 1, down ? 0.25 : 0.6);
    CSInnerShadow(c, fp, 0, 0.8, 0.8, 0, 0, 0, 0.35);
    CGPathRelease(fp);
    return CSEnd(c);
}

CGImageRef CSCreateKnobPointerImage(CGFloat scale)
{
    CGFloat R = CSKnobPointerRadius();
    CGContextRef c = CSBegin(2 * R, 2 * R, scale);
    CGContextTranslateCTM(c, R, R);
    // An engraved groove filled with orange paint, pointing straight up.
    CGPathRef groove = CSRoundRect(CGRectMake(-1.9, 27, 3.8, 15), 1.9);
    CSFillRGBA(c, 0.12, 0.12, 0.12, 1);
    CSFillPath(c, groove);
    CGPathRelease(groove);
    CGPathRef paint = CSRoundRect(CGRectMake(-1.25, 27.8, 2.5, 13.4), 1.25);
    CSFillRGBA(c, 0.97, 0.50, 0.12, 1);
    CSFillPath(c, paint);
    CGPathRelease(paint);
    return CSEnd(c);
}

CGImageRef CSCreateCounterDigitImage(int digit, CGFloat scale)
{
    CGRect r = CSCounterDigitRect(0);
    CGFloat w = r.size.width, h = r.size.height;
    CGContextRef c = CSBegin(w, h, scale);
    CSFillRGBA(c, 0.09, 0.09, 0.09, 1);
    CGContextFillRect(c, CGRectMake(0, 0, w, h));

    NSFont *font = CSFont(CS_FONT_DIGITS, 20);
    CGFloat base = h / 2 - [font capHeight] / 2;
    digit = ((digit % 10) + 10) % 10;
    // The drum turns upward as it counts, so the next figure is coming up from
    // below and the last one is disappearing over the top.
    CSText(c, [NSString stringWithFormat:@"%d", digit], font, 0, 0.94, 0.93, 0.88, 1,
           CGPointMake(w / 2, base), CSAlignCentre);
    CSText(c, [NSString stringWithFormat:@"%d", (digit + 9) % 10], font, 0, 0.94, 0.93, 0.88, 1,
           CGPointMake(w / 2, base + 27), CSAlignCentre);
    CSText(c, [NSString stringWithFormat:@"%d", (digit + 1) % 10], font, 0, 0.94, 0.93, 0.88, 1,
           CGPointMake(w / 2, base - 27), CSAlignCentre);

    // Curvature of the drum, then the window's glass.
    CGFloat drum[20] = { 0, 0, 0, 0.92,  0, 0, 0, 0.35,  0, 0, 0, 0,  0, 0, 0, 0.35,  0, 0, 0, 0.92 };
    CGFloat dlocs[5] = { 0, 0.22, 0.5, 0.78, 1 };
    CSLinear(c, CGPointMake(0, h), CGPointMake(0, 0), 5, drum, dlocs);
    CGFloat edge[12] = { 0, 0, 0, 0.6,  0, 0, 0, 0,  0, 0, 0, 0.6 };
    CGFloat elocs[3] = { 0, 0.5, 1 };
    CSLinear(c, CGPointMake(0, 0), CGPointMake(w, 0), 3, edge, elocs);
    // The window's glass, catching the light across its upper half.
    CGContextSaveGState(c);
    CGContextClipToRect(c, CGRectMake(0, h * 0.56, w, h * 0.44));
    CGFloat glass[8] = { 1, 1, 1, 0.20,  1, 1, 1, 0.04 };
    CGFloat glocs[2] = { 0, 1 };
    CSLinear(c, CGPointMake(0, h), CGPointMake(0, h * 0.56), 2, glass, glocs);
    CGContextRestoreGState(c);
    return CSEnd(c);
}

static void CSAddLampLens(CGContextRef c, CSLamp lamp, CGRect lens)
{
    if (lamp == CSLampReverse || lamp == CSLampForward) {
        BOOL right = (lamp == CSLampForward);
        CGFloat tip = right ? CGRectGetMaxX(lens) : CGRectGetMinX(lens);
        CGFloat back = right ? CGRectGetMinX(lens) : CGRectGetMaxX(lens);
        CGContextMoveToPoint(c, back, CGRectGetMinY(lens));
        CGContextAddLineToPoint(c, tip, CGRectGetMidY(lens));
        CGContextAddLineToPoint(c, back, CGRectGetMaxY(lens));
        CGContextClosePath(c);
    } else {
        CGContextAddEllipseInRect(c, lens);
    }
}

CGImageRef CSCreateLampImage(CSLamp lamp, BOOL lit, CGFloat scale)
{
    CGRect frame = CSLampRect(lamp);
    CGContextRef c = CSBegin(frame.size.width, frame.size.height, scale);
    CGRect lens = CGRectOffset(CSLampLensRect(lamp), -frame.origin.x, -frame.origin.y);

    CGFloat on[3], off[3];
    if (lamp == CSLampAC) {
        on[0] = 0.45; on[1] = 1.0; on[2] = 0.42;   off[0] = 0.10; off[1] = 0.19; off[2] = 0.09;
    } else {
        on[0] = 1.0; on[1] = 0.62; on[2] = 0.14;   off[0] = 0.27; off[1] = 0.13; off[2] = 0.05;
    }

    if (lit) {
        CGContextSaveGState(c);
        CSShadow(c, 0, 0, 7, on[0], on[1], on[2], 0.95);
        CSFillRGBA(c, on[0], on[1], on[2], 1);
        CSAddLampLens(c, lamp, lens);
        CGContextFillPath(c);
        CGContextRestoreGState(c);
    }
    // A gel lens, as on the Aqua window buttons: light comes in through the
    // dome and gathers at the bottom of it, so the colour is deepest at the top
    // and brightest low down.
    CGContextSaveGState(c);
    CSAddLampLens(c, lamp, lens);
    CGContextClip(c);
    CGFloat top = CGRectGetMaxY(lens), bottom = CGRectGetMinY(lens);
    CGPoint m = CGPointMake(CGRectGetMidX(lens), CGRectGetMidY(lens));
    CGFloat rad = MAX(lens.size.width, lens.size.height);
    if (lit) {
        CGFloat g[12] = { on[0] * 0.62, on[1] * 0.55, on[2] * 0.5, 1,  on[0], on[1], on[2], 1,
                          on[0] + (1 - on[0]) * 0.5, on[1] + (1 - on[1]) * 0.5, on[2] + (1 - on[2]) * 0.4, 1 };
        CGFloat l[3] = { 0, 0.5, 1 };
        CSLinear(c, CGPointMake(m.x, top), CGPointMake(m.x, bottom), 3, g, l);
        CGFloat glow[8] = { 1, 1, 0.92, 0.75,  1, 1, 0.92, 0 };
        CGFloat gl[2] = { 0, 1 };
        CSRadial(c, CGPointMake(m.x, bottom + lens.size.height * 0.18), 0,
                    CGPointMake(m.x, bottom + lens.size.height * 0.18), rad * 0.55, 2, glow, gl, NO);
    } else {
        CGFloat g[8] = { off[0] * 0.5, off[1] * 0.5, off[2] * 0.5, 1,  off[0] * 1.5, off[1] * 1.5, off[2] * 1.5, 1 };
        CGFloat l[2] = { 0, 1 };
        CSLinear(c, CGPointMake(m.x, top), CGPointMake(m.x, bottom), 2, g, l);
        CGFloat glow[8] = { off[0] * 2.6, off[1] * 2.6, off[2] * 2.6, 0.55,  off[0], off[1], off[2], 0 };
        CGFloat gl[2] = { 0, 1 };
        CSRadial(c, CGPointMake(m.x, bottom + lens.size.height * 0.15), 0,
                    CGPointMake(m.x, bottom + lens.size.height * 0.15), rad * 0.5, 2, glow, gl, NO);
    }
    // The dome's reflection of the room: a bright cap over the upper half,
    // narrower than the lens and fading as it comes down.
    CGRect cap = CGRectMake(lens.origin.x + lens.size.width * 0.17, m.y - lens.size.height * 0.02,
                            lens.size.width * 0.66, lens.size.height * 0.48);
    CGContextAddEllipseInRect(c, cap);
    CGContextClip(c);
    CGFloat shine[8] = { 1, 1, 1, lit ? 0.85 : 0.5,  1, 1, 1, lit ? 0.12 : 0.04 };
    CGFloat sl[2] = { 0, 1 };
    CSLinear(c, CGPointMake(m.x, CGRectGetMaxY(cap)), CGPointMake(m.x, cap.origin.y), 2, shine, sl);
    CGContextRestoreGState(c);

    // The rim of the lens, where it sits in its socket.
    CSStrokeRGBA(c, 0, 0, 0, 0.6);
    CGContextSetLineWidth(c, 0.6);
    CSAddLampLens(c, lamp, lens);
    CGContextStrokePath(c);
    return CSEnd(c);
}
