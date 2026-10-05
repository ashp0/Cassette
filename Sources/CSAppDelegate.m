#import "CSAppDelegate.h"
#import "CSPlayerController.h"

@implementation CSAppDelegate
{
    CSPlayerController *_player;
    BOOL _openedFileAtLaunch;
}

@synthesize player = _player;

#pragma mark - Menus

static NSMenuItem *CSAdd(NSMenu *menu, NSString *title, SEL action,
                         NSString *key, NSUInteger mask)
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                   action:action
                                            keyEquivalent:key ? key : @""] autorelease];
    if (key) [item setKeyEquivalentModifierMask:mask];
    [menu addItem:item];
    return item;
}

static NSMenu *CSSubmenu(NSMenu *bar, NSString *title)
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""] autorelease];
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:title] autorelease];
    [item setSubmenu:menu];
    [bar addItem:item];
    return menu;
}

static NSString *CSFnKey(unichar c)
{
    return [NSString stringWithCharacters:&c length:1];
}

- (void)buildMenuBar
{
    NSMenu *bar = [[[NSMenu alloc] initWithTitle:@""] autorelease];

    NSMenu *app = CSSubmenu(bar, @"Cassette");
    CSAdd(app, @"About Cassette", @selector(orderFrontStandardAboutPanel:), nil, 0);
    [app addItem:[NSMenuItem separatorItem]];
    CSAdd(app, @"Hide Cassette", @selector(hide:), @"h", NSCommandKeyMask);
    CSAdd(app, @"Hide Others", @selector(hideOtherApplications:), @"h",
          NSCommandKeyMask | NSAlternateKeyMask);
    CSAdd(app, @"Show All", @selector(unhideAllApplications:), nil, 0);
    [app addItem:[NSMenuItem separatorItem]];
    CSAdd(app, @"Quit Cassette", @selector(terminate:), @"q", NSCommandKeyMask);

    NSMenu *file = CSSubmenu(bar, @"File");
    CSAdd(file, @"Load Tape…", @selector(chooseTape:), @"o", NSCommandKeyMask);
    [file addItem:[NSMenuItem separatorItem]];
    CSAdd(file, @"Close", @selector(performClose:), @"w", NSCommandKeyMask);

    // For the Open panel's search field; the deck itself takes no text.
    NSMenu *edit = CSSubmenu(bar, @"Edit");
    CSAdd(edit, @"Cut", @selector(cut:), @"x", NSCommandKeyMask);
    CSAdd(edit, @"Copy", @selector(copy:), @"c", NSCommandKeyMask);
    CSAdd(edit, @"Paste", @selector(paste:), @"v", NSCommandKeyMask);
    CSAdd(edit, @"Select All", @selector(selectAll:), @"a", NSCommandKeyMask);

    NSMenu *controls = CSSubmenu(bar, @"Controls");
    CSAdd(controls, @"Play", @selector(togglePlayPause:), @" ", 0);
    CSAdd(controls, @"Stop", @selector(stopTape:), @".", NSCommandKeyMask);
    CSAdd(controls, @"Eject", @selector(ejectTape:), @"e", NSCommandKeyMask);
    [controls addItem:[NSMenuItem separatorItem]];
    CSAdd(controls, @"Volume Up", @selector(volumeUp:), CSFnKey(NSUpArrowFunctionKey), NSCommandKeyMask);
    CSAdd(controls, @"Volume Down", @selector(volumeDown:), CSFnKey(NSDownArrowFunctionKey), NSCommandKeyMask);

    NSMenu *window = CSSubmenu(bar, @"Window");
    CSAdd(window, @"Minimize", @selector(performMiniaturize:), @"m", NSCommandKeyMask);
    [window addItem:[NSMenuItem separatorItem]];
    CSAdd(window, @"Cassette Deck", @selector(showDeck:), @"1", NSCommandKeyMask);
    [window addItem:[NSMenuItem separatorItem]];
    CSAdd(window, @"Bring All to Front", @selector(arrangeInFront:), nil, 0);

    [NSApp setMainMenu:bar];
    [NSApp setWindowsMenu:window];
}

#pragma mark - Actions

- (IBAction)chooseTape:(id)sender      { [_player chooseTape]; }
- (IBAction)togglePlayPause:(id)sender { [_player togglePlayPause]; }
- (IBAction)stopTape:(id)sender        { [_player stop]; }
- (IBAction)ejectTape:(id)sender       { [_player eject]; }
- (IBAction)volumeUp:(id)sender        { [_player nudgeVolume:0.05f]; }
- (IBAction)volumeDown:(id)sender      { [_player nudgeVolume:-0.05f]; }
- (IBAction)showDeck:(id)sender        { [_player showDeck]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL action = [item action];
    if (action == @selector(togglePlayPause:)) {
        [item setTitle:[_player isPlaying] ? @"Pause" : @"Play"];
        return YES;
    }
    if (action == @selector(stopTape:) || action == @selector(ejectTape:)) return [_player hasTape];
    return YES;
}

// Transport from the Dock, so the tape can be stopped without bringing the
// deck forward.
- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    NSMenuItem *play = CSAdd(menu, [_player isPlaying] ? @"Pause" : @"Play",
                             @selector(togglePlayPause:), nil, 0);
    [play setTarget:self];
    if ([_player hasTape]) {
        [CSAdd(menu, @"Stop", @selector(stopTape:), nil, 0) setTarget:self];
        [CSAdd(menu, @"Eject", @selector(ejectTape:), nil, 0) setTarget:self];
    }
    return menu;
}

#pragma mark - Lifecycle

- (void)applicationWillFinishLaunching:(NSNotification *)note
{
    [self buildMenuBar];
    _player = [[CSPlayerController alloc] init];
}

// Finder's Open With, or a file dropped on the Dock icon. One tape: the first
// file that loads is the one that stays in.
- (void)application:(NSApplication *)app openFiles:(NSArray *)paths
{
    BOOL loaded = NO;
    for (NSString *path in paths) {
        if ([_player loadURL:[NSURL fileURLWithPath:path] play:YES]) {
            loaded = YES;
            break;
        }
    }
    _openedFileAtLaunch = YES;
    [_player showDeck];
    [app replyToOpenOrPrint:loaded ? NSApplicationDelegateReplySuccess
                                   : NSApplicationDelegateReplyFailure];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    if (!_openedFileAtLaunch) [_player restoreLastTape];
    [_player showDeck];
}

// Closing the window does not stop the music; clicking the Dock icon brings
// the deck back.
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return NO; }

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible
{
    [_player showDeck];
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    [_player saveState];
}

@end
