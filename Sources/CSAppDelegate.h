#import <Cocoa/Cocoa.h>

@class CSPlayerController;

@interface CSAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, readonly) CSPlayerController *player;
@end
