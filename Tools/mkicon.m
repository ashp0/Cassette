// mkicon -- writes Cassette.iconset from the deck's own artwork.
//
// A host tool: it is built for and run on the development machine, never
// shipped, and links CSArtwork.m directly so the icon is the very cassette the
// app draws, at every size, rather than a picture of it.
//
//   mkicon <output.iconset>      then: iconutil -c icns <output.iconset>

#import <Cocoa/Cocoa.h>
#import "CSArtwork.h"

#define HUB_MM 11.0
#define FULL_MM 24.2

static void DrawCentred(CGContextRef c, CGImageRef image, CGPoint centre, CGFloat halfPt)
{
    CGContextDrawImage(c, CGRectMake(centre.x - halfPt, centre.y - halfPt, 2 * halfPt, 2 * halfPt), image);
}

static CGImageRef CreateIcon(size_t side)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, side, side, 8, 0, cs,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);

    CGRect cr = CSCassetteRect();
    CGFloat k = (CGFloat)side * 0.86 / cr.size.width;   // pixels per point

    CGContextTranslateCTM(c, side / 2.0, side / 2.0);
    CGContextRotateCTM(c, (CGFloat)(-7.0 * M_PI / 180.0));
    CGContextScaleCTM(c, k, k);
    CGContextTranslateCTM(c, -cr.size.width / 2, -cr.size.height / 2);

    CGFloat shadowColour[4] = { 0, 0, 0, 0.55 };
    CGColorRef shadow = CGColorCreate(CGBitmapContextGetColorSpace(c), shadowColour);
    CGContextSetShadowWithColor(c, CGSizeMake(0, -(CGFloat)side * 0.02), (CGFloat)side * 0.035, shadow);
    CGColorRelease(shadow);
    CGContextBeginTransparencyLayer(c, NULL);

    CGRect all = CGRectMake(0, 0, cr.size.width, cr.size.height);
    CGImageRef img = CSCreateCassetteInteriorImage(k);
    CGContextDrawImage(c, all, img);
    CGImageRelease(img);

    // A third of the way through side A.
    double radii[2] = { sqrt(HUB_MM * HUB_MM + 0.66 * (FULL_MM * FULL_MM - HUB_MM * HUB_MM)),
                        sqrt(HUB_MM * HUB_MM + 0.34 * (FULL_MM * FULL_MM - HUB_MM * HUB_MM)) };
    CGFloat hubHalf = CS_HUB_IMAGE_R_MM * CS_PT_PER_MM;
    CGImageRef hub = CSCreateHubImage(k), shine = CSCreateHubShineImage(k);
    int i;
    for (i = 0; i < 2; i++) {
        CGPoint p = CSHubCentreInCassette(i);
        CGFloat r = (CGFloat)(radii[i] * CS_PT_PER_MM);
        img = CSCreatePackImage(r, k);
        DrawCentred(c, img, p, r + 1);
        CGImageRelease(img);
        CGContextSaveGState(c);
        CGContextTranslateCTM(c, p.x, p.y);
        CGContextRotateCTM(c, (CGFloat)(i ? 0.4 : 1.1));
        DrawCentred(c, hub, CGPointZero, hubHalf);
        CGContextRestoreGState(c);
        DrawCentred(c, shine, p, hubHalf);
    }
    CGImageRelease(hub);
    CGImageRelease(shine);

    img = CSCreateCassetteFaceImage(k, @"Endless Loop", @"Cassette");
    CGContextDrawImage(c, all, img);
    CGImageRelease(img);

    CGContextEndTransparencyLayer(c);
    CGImageRef icon = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return icon;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: mkicon <output.iconset>\n");
            return 2;
        }
        [NSApplication sharedApplication];
        NSString *dir = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:NULL];
        int points[5] = { 16, 32, 128, 256, 512 };
        int i, x;
        for (i = 0; i < 5; i++) {
            for (x = 1; x <= 2; x++) {
                size_t px = (size_t)(points[i] * x);
                CGImageRef icon = CreateIcon(px);
                NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithCGImage:icon] autorelease];
                CGImageRelease(icon);
                NSData *png = [rep representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
                NSString *name = x == 1
                    ? [NSString stringWithFormat:@"icon_%dx%d.png", points[i], points[i]]
                    : [NSString stringWithFormat:@"icon_%dx%d@2x.png", points[i], points[i]];
                if (![png writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES]) {
                    fprintf(stderr, "mkicon: could not write %s\n", [name UTF8String]);
                    return 1;
                }
            }
        }
    }
    return 0;
}
