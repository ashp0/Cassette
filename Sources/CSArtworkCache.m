#import "CSArtworkCache.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

// A file is this header followed by the rows of pixels, exactly as the bitmap
// context that drew them laid them out.
#define CS_CACHE_MAGIC     0x4D425343u   // "CSBM"
#define CS_CACHE_VERSION   1u
#define CS_CACHE_LAYOUT    (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t bitmapInfo;
} CSCacheHeader;

static NSString *sDirectory;
static BOOL      sDirectoryChosen;

#pragma mark - Where

static uint32_t CSFNV1a(const char *s)
{
    uint32_t h = 2166136261u;
    for (; s && *s; s++) { h ^= (uint8_t)*s; h *= 16777619u; }
    return h;
}

// The main executable's LC_UUID, which the linker changes with every build.
static NSString *CSBuildIdentity(void)
{
    const struct mach_header *mh = _dyld_get_image_header(0);
    if (mh && mh->magic == MH_MAGIC_64) {
        const char *p = (const char *)mh + sizeof(struct mach_header_64);
        uint32_t i;
        for (i = 0; i < mh->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmd == LC_UUID) {
                const uint8_t *u = ((const struct uuid_command *)lc)->uuid;
                NSMutableString *s = [NSMutableString stringWithCapacity:32];
                int k;
                for (k = 0; k < 16; k++) [s appendFormat:@"%02X", u[k]];
                return s;
            }
            if (lc->cmdsize == 0) break;
            p += lc->cmdsize;
        }
    }
    // No UUID (a binary linked with -no_uuid): the file's size and date will do.
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:
                          [[NSBundle mainBundle] executablePath] error:NULL];
    if (!a) return nil;
    return [NSString stringWithFormat:@"%llu-%.0f", [a fileSize],
            [[a fileModificationDate] timeIntervalSinceReferenceDate]];
}

static NSString *CSDefaultDirectory(void)
{
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *build = CSBuildIdentity();
    if ([bundleID length] == 0 || [caches count] == 0 || [build length] == 0) return nil;
    NSString *os = [[NSProcessInfo processInfo] operatingSystemVersionString];
    NSString *key = [NSString stringWithFormat:@"%@-%08X", build, CSFNV1a([os UTF8String])];
    return [[[[caches objectAtIndex:0] stringByAppendingPathComponent:bundleID]
                stringByAppendingPathComponent:@"Artwork"] stringByAppendingPathComponent:key];
}

NSString *CSArtworkCacheDirectory(void)
{
    if (!sDirectoryChosen) {
        sDirectoryChosen = YES;
        sDirectory = [CSDefaultDirectory() copy];
    }
    return sDirectory;
}

void CSArtworkCacheSetDirectory(NSString *directory)
{
    CSArtworkCacheFlush();
    [sDirectory release];
    sDirectory = [directory copy];
    sDirectoryChosen = YES;
}

static NSString *CSPathFor(NSString *name, CGFloat scale)
{
    NSString *dir = CSArtworkCacheDirectory();
    if (!dir) return nil;
    return [dir stringByAppendingPathComponent:
               [NSString stringWithFormat:@"%@@%gx.pixels", name, (double)scale]];
}

#pragma mark - Reading

static void CSReleaseMappedFile(void *info, const void *data, size_t size)
{
    (void)data; (void)size;
    [(NSData *)info release];
}

static CGImageRef CSReadImage(NSString *path)
{
    NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if ([file length] < sizeof(CSCacheHeader)) return NULL;
    CSCacheHeader h;
    memcpy(&h, [file bytes], sizeof(h));
    if (h.magic != CS_CACHE_MAGIC || h.version != CS_CACHE_VERSION ||
        h.bitmapInfo != (uint32_t)CS_CACHE_LAYOUT || h.width == 0 || h.height == 0 ||
        h.width > 16384 || h.height > 16384 || h.bytesPerRow < h.width * 4)
        return NULL;
    size_t bytes = (size_t)h.bytesPerRow * h.height;
    if ([file length] != sizeof(h) + bytes) return NULL;

    // The provider owns the mapping from here, and lets it go with the image.
    CGDataProviderRef provider = CGDataProviderCreateWithData(
        [file retain], (const char *)[file bytes] + sizeof(h), bytes, CSReleaseMappedFile);
    if (!provider) { [file release]; return NULL; }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(h.width, h.height, 8, 32, h.bytesPerRow, space,
                                     (CGBitmapInfo)h.bitmapInfo, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

#pragma mark - Writing

static dispatch_queue_t CSWriteQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.cassette.artwork-cache", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

void CSArtworkCacheFlush(void)
{
    dispatch_sync(CSWriteQueue(), ^{});
}

// Makes the folder for this build, and deletes the folders of any other: they
// can never be read again, and each is a few megabytes. Once per directory,
// on the write queue.
static void CSPrepareDirectory(NSString *dir)
{
    static NSString *prepared;
    if ([prepared isEqualToString:dir]) return;
    [prepared release];
    prepared = [dir copy];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *parent = [dir stringByDeletingLastPathComponent];
    NSString *mine = [dir lastPathComponent];
    for (NSString *other in [fm contentsOfDirectoryAtPath:parent error:NULL]) {
        if ([other isEqualToString:mine] || [other hasPrefix:@"."]) continue;
        [fm removeItemAtPath:[parent stringByAppendingPathComponent:other] error:NULL];
    }
}

static void CSWriteImage(CGImageRef image, NSString *path)
{
    // Only the one layout CSReadImage accepts, which is the one every drawing
    // in CSArtwork produces.
    if (CGImageGetBitsPerComponent(image) != 8 || CGImageGetBitsPerPixel(image) != 32 ||
        CGImageGetBitmapInfo(image) != (CGBitmapInfo)CS_CACHE_LAYOUT)
        return;
    CFDataRef pixels = CGDataProviderCopyData(CGImageGetDataProvider(image));
    if (!pixels) return;
    CSCacheHeader h;
    h.magic       = CS_CACHE_MAGIC;
    h.version     = CS_CACHE_VERSION;
    h.width       = (uint32_t)CGImageGetWidth(image);
    h.height      = (uint32_t)CGImageGetHeight(image);
    h.bytesPerRow = (uint32_t)CGImageGetBytesPerRow(image);
    h.bitmapInfo  = (uint32_t)CS_CACHE_LAYOUT;
    if ((size_t)CFDataGetLength(pixels) == (size_t)h.bytesPerRow * h.height) {
        NSMutableData *file = [NSMutableData dataWithCapacity:sizeof(h) + (NSUInteger)CFDataGetLength(pixels)];
        [file appendBytes:&h length:sizeof(h)];
        [file appendData:(NSData *)pixels];
        // Atomically: a reader sees the whole file or none of it, never half.
        [file writeToFile:path atomically:YES];
    }
    CFRelease(pixels);
}

#pragma mark -

CGImageRef CSArtworkCopy(NSString *name, CGFloat scale, CGImageRef (^draw)(void))
{
    NSString *path = CSPathFor(name, scale);
    if (path) {
        CGImageRef cached = CSReadImage(path);
        if (cached) return cached;
    }
    CGImageRef image = draw();
    if (image && path) {
        NSString *dir = [[path stringByDeletingLastPathComponent] retain];
        [path retain];
        CGImageRetain(image);
        dispatch_async(CSWriteQueue(), ^{
            @autoreleasepool {
                CSPrepareDirectory(dir);
                CSWriteImage(image, path);
            }
            CGImageRelease(image);
            [path release];
            [dir release];
        });
    }
    return image;
}
