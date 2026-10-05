#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Finished artwork, kept on disk between launches.
//
// Every bitmap on the deck is generated from noise and gradients (CSArtwork),
// and drawing them all was most of the time between clicking the Dock icon and
// seeing the deck: a few hundred milliseconds, more on a Retina display. None
// of it changes from one launch to the next, so the first launch keeps what it
// drew, as raw pixels, under ~/Library/Caches/<bundle id>/Artwork, and later
// launches map those files straight back in instead of drawing again. Mapped,
// not read: a file's pages come off the disk when the compositor first uses
// them, and the kernel can drop them again, because they are clean.
//
// The cache is keyed by the build (the executable's UUID) and by the OS
// version, whose fonts are drawn into the pictures. A new copy of the app or a
// system update draws afresh, and the folders any other build left behind are
// deleted. A file that is missing, truncated or not in the expected layout is
// simply treated as absent. Writing happens on a background queue, so it
// never delays the launch that does the drawing.

// +1: the image called `name` at `scale` pixels per point, from the cache if it
// is there, otherwise from `draw` (which returns +1), which is then kept.
CGImageRef CSArtworkCopy(NSString *name, CGFloat scale, CGImageRef (^draw)(void)) CF_RETURNS_RETAINED;

// ---- Test seams --------------------------------------------------------

// Where the cache lives. The app's own is chosen automatically; a process
// with no bundle identifier (the test suite, the icon tool) has none, so it
// always draws, unless given a directory here. nil turns the cache off.
void      CSArtworkCacheSetDirectory(NSString *directory);
NSString *CSArtworkCacheDirectory(void);

// Blocks until every pending write has reached the disk.
void      CSArtworkCacheFlush(void);
