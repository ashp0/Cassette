#import "CSAppDelegate.h"

// NSApplication does not retain its delegate, and -run never returns, so the
// delegate is held here for the life of the process.
static CSAppDelegate *sDelegate;

int main(int argc, const char *argv[])
{
    (void)argc; (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        sDelegate = [[CSAppDelegate alloc] init];
        [NSApp setDelegate:sDelegate];
        [NSApp run];
    }
    return 0;
}
