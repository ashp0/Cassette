#import "CSPlayerController.h"
#import "CSAudioEngine.h"
#import "CSDeckWindow.h"
#import "CSPower.h"
#import "CSTape.h"

static NSString *const CSVolumeKey     = @"CSVolumePosition";
static NSString *const CSLastTapeKey   = @"CSLastTapeBookmark";
static NSString *const CSLastTitleKey  = @"CSLastTapeTitle";
static NSString *const CSLastArtistKey = @"CSLastTapeArtist";
static NSString *const CSFrameName     = @"CassetteDeck";

#define CS_DEFAULT_VOLUME_POSITION  0.7f

// The knob is marked 0 to 10 in even steps, but hearing is logarithmic: a
// linear gain crowds all the useful range into the bottom third of the dial.
// Squaring it spreads it out, the way an audio-taper potentiometer does.
static float CSGainForPosition(float position)
{
    return position * position;
}

@implementation CSPlayerController
{
    CSAudioEngine *_engine;
    CSDeckView    *_deck;
    NSTimer       *_tick;
    CSKey          _latched;
    BOOL           _windowOpen;
    BOOL           _spinning;
    BOOL           _panelOpen;
    int            _powerToken;
    NSURL         *_pendingTape;     // shown in the deck at launch, sound not read yet
    BOOL           _pendingStale;    // and its bookmark wants renewing once it is
}

@synthesize engine = _engine, deck = _deck, reelsSpinning = _spinning;

// Whether a restored frame put the window where it can be seen and grabbed:
// the display it was saved on may have gone since.
static BOOL CSFrameIsOnScreen(NSRect frame)
{
    NSRect handle = NSMakeRect(frame.origin.x, NSMaxY(frame) - CS_HANDLE_HEIGHT,
                               frame.size.width, CS_HANDLE_HEIGHT);
    for (NSScreen *screen in [NSScreen screens]) {
        NSRect overlap = NSIntersectionRect(handle, [screen visibleFrame]);
        if (overlap.size.width >= 80 && overlap.size.height >= CS_HANDLE_HEIGHT / 2) return YES;
    }
    return NO;
}

- (id)init
{
    CSDeckView *deck = [[CSDeckView alloc] initWithFrame:NSMakeRect(0, 0, CS_DECK_WIDTH, CS_DECK_HEIGHT)];
    CSDeckWindow *window = [[CSDeckWindow alloc] initWithDeckView:deck];
    self = [super initWithWindow:window];
    [window release];
    if (!self) {
        [deck release];
        return nil;
    }
    _deck = deck;
    [_deck setDelegate:self];

    [window setReleasedWhenClosed:NO];
    [window setRestorable:NO];
    [window setTitle:@"Cassette"];
    [window setDelegate:self];
    if (![window setFrameUsingName:CSFrameName] || !CSFrameIsOnScreen([window frame]))
        [window center];
    [window setFrameAutosaveName:CSFrameName];

    _engine = [[CSAudioEngine alloc] init];
    _latched = CSKeyCount;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    float position = [defaults objectForKey:CSVolumeKey]
        ? [defaults floatForKey:CSVolumeKey] : CS_DEFAULT_VOLUME_POSITION;
    [_deck setVolumePosition:position];
    [_engine setVolume:CSGainForPosition([_deck volumePosition])];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSString *appEvents[] = {
        NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification,
        NSApplicationDidHideNotification, NSApplicationDidUnhideNotification };
    unsigned i;
    for (i = 0; i < sizeof(appEvents) / sizeof(appEvents[0]); i++)
        [nc addObserver:self selector:@selector(somethingChanged:) name:appEvents[i] object:NSApp];

    // The engine stopping by itself -- the output would not come back after a
    // wake -- is a change of play state nobody pressed a key for.
    [nc addObserver:self selector:@selector(engineStoppedUnexpectedly:)
               name:CSAudioEngineDidStopUnexpectedlyNotification object:_engine];

    // Waking can change the power source without the charger being touched
    // while the machine was awake to hear about it.
    NSNotificationCenter *ws = [[NSWorkspace sharedWorkspace] notificationCenter];
    [ws addObserver:self selector:@selector(somethingChanged:)
               name:NSWorkspaceDidWakeNotification object:nil];
    [ws addObserver:self selector:@selector(somethingChanged:)
               name:NSWorkspaceScreensDidWakeNotification object:nil];

    // The block retains this controller, which lives as long as the process.
    _powerToken = CSObservePowerSource(^{ [self reevaluate]; });

    [self refreshTape];
    [self reevaluate];
    return self;
}

- (void)dealloc
{
    [_pendingTape release];
    CSStopObservingPowerSource(_powerToken);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self disarmTick];
    [[self window] setDelegate:nil];
    [_deck setDelegate:nil];
    [_deck release];
    [_engine release];
    [super dealloc];
}

- (BOOL)hasTape   { return _pendingTape != nil || [_engine hasTape]; }
- (BOOL)isPlaying { return [_engine isPlaying]; }

#pragma mark - The window

- (void)showDeck
{
    _windowOpen = YES;
    [[self window] makeKeyAndOrderFront:nil];
    [self reevaluate];
}

- (void)windowWillClose:(NSNotification *)note
{
    _windowOpen = NO;
    [self reevaluate];
}

// The deck follows the engine. It kept its place, the way a pause does, so the
// key that comes up is PLAY and the one that goes down is PAUSE -- pressing
// either carries on from there -- and the reels stop with the sound.
- (void)engineStoppedUnexpectedly:(NSNotification *)note
{
    if ([_engine hasTape] && ![_engine isPlaying] && _latched == CSKeyPlay)
        [self latch:CSKeyPause];
    [self reevaluate];
}

- (void)windowDidMiniaturize:(NSNotification *)note             { [self reevaluate]; }
- (void)windowDidDeminiaturize:(NSNotification *)note           { [self reevaluate]; }
- (void)windowDidChangeOcclusionState:(NSNotification *)note    { [self reevaluate]; }
- (void)somethingChanged:(NSNotification *)note                 { [self reevaluate]; }

// Whether any of the deck could be seen right now. Occlusion (new in 10.9)
// covers being buried under other windows, sitting on another Space, and the
// display being asleep or locked; the other tests are for the cases it is
// documented to report only eventually.
- (BOOL)windowOnScreen
{
    NSWindow *w = [self window];
    if (!_windowOpen || ![w isVisible] || [w isMiniaturized] || [NSApp isHidden]) return NO;
    return ([w occlusionState] & NSWindowOcclusionStateVisible) != 0;
}

#pragma mark - The policy

- (void)reevaluate
{
    CSPowerSource power = CSCurrentPowerSource();
    [_deck setPowerSource:power];

    CSUIState state;
    state.playing        = [_engine isPlaying];
    state.windowOpen     = _windowOpen;
    state.windowOnScreen = [self windowOnScreen];
    state.appActive      = [NSApp isActive];
    BOOL spin = CSReelsShouldSpin(power, state);
    if (spin == _spinning) return;
    _spinning = spin;

    if (spin) {
        // Catch the counter and packs up with however long the tape played
        // unwatched, then let the reels go.
        [self refreshTape];
        [_deck setReelsSpinning:YES];
        [self armTick];
    } else {
        [_deck setReelsSpinning:NO];
        [self disarmTick];
        [self refreshTape];
    }
}

- (void)refreshTape
{
    if (![_engine hasTape]) {
        // A tape still being restored is rewound, like any other at launch.
        [_deck setCounter:0];
        [_deck setDirection:1 lit:_pendingTape != nil];
        return;
    }
    CSTapeState t = CSTapeStateAt([_engine elapsed], [_engine duration]);
    [_deck setCounter:t.counter];
    [_deck setDirection:t.direction lit:YES];
    [_deck setLeftRadius:t.leftRadius rightRadius:t.rightRadius
               leftOmega:t.leftOmega rightOmega:t.rightOmega];
}

- (void)tick:(NSTimer *)timer
{
    (void)timer;
    [self refreshTape];
}

- (void)armTick
{
    if (_tick) return;
    _tick = [[NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick:)
                                   userInfo:nil repeats:YES] retain];
    // A counter that ticks a quarter-second late is indistinguishable from one
    // that does not; the slack lets the system coalesce this with other
    // wakeups instead of making its own.
    [_tick setTolerance:0.25];
    [[NSRunLoop mainRunLoop] addTimer:_tick forMode:NSRunLoopCommonModes];
}

- (void)disarmTick
{
    [_tick invalidate];
    [_tick release];
    _tick = nil;
}

#pragma mark - Transport

- (void)latch:(CSKey)key
{
    _latched = key;
    [_deck setLatchedKey:key];
}

- (void)play
{
    [self finishRestoringTape];
    if (![_engine hasTape]) {
        [self chooseTape];
        return;
    }
    if (![_engine play]) {
        [self presentAlert:@"Cassette couldn’t start the sound output."
                    detail:@"Check that an output device is selected in System Preferences > Sound."];
        return;
    }
    [self latch:CSKeyPlay];
    [self reevaluate];
}

- (void)pause
{
    [self finishRestoringTape];
    if (![_engine hasTape]) return;
    if ([_engine isPlaying]) {
        [_engine pause];
        [self latch:CSKeyPause];
        [self reevaluate];
    } else if (_latched == CSKeyPause) {
        [self play];
    }
}

- (void)togglePlayPause
{
    [self finishRestoringTape];
    if ([_engine isPlaying]) [self pause];
    else [self play];
}

- (void)stop
{
    [self finishRestoringTape];
    if (![_engine hasTape]) return;
    [_engine stop];
    [self latch:CSKeyCount];
    [self reevaluate];
    [self refreshTape];
}

#pragma mark - Tapes

// The writing on the cassette, and the same on the handle.
- (void)showLabel:(NSString *)title artist:(NSString *)artist animated:(BOOL)animated
{
    [_deck setTapeLoaded:YES title:title artist:artist animated:animated];
    NSString *name = title;
    if (artist) name = [NSString stringWithFormat:@"%@ — %@", artist, title];
    [[self window] setTitle:[name length] ? name : @"Cassette"];
}

- (BOOL)insertURL:(NSURL *)url error:(NSError **)error animated:(BOOL)animated
{
    if (![_engine loadURL:url error:error]) {
        // "A file that can't be played is refused, and whatever tape was in
        // stays in" -- which includes a tape still being restored. It used to
        // be dropped before the new file was even tried, so a refusal left the
        // deck showing a cassette that was no longer in it: Play then asked
        // for a file instead of playing it.
        //
        // The engine keeps its own tape when the FILE is at fault. When the
        // file was fine and the sound output was not, it has already let the
        // old tape go, and the deck has to say so rather than go on showing it
        // -- with PLAY held down and, on mains power, the reels turning over
        // silence.
        if (![self hasTape]) {
            [self latch:CSKeyCount];
            [_deck setTapeLoaded:NO title:nil artist:nil animated:animated];
            [[self window] setTitle:@"Cassette"];
            [self refreshTape];
            [self reevaluate];
        }
        return NO;
    }
    // A new tape replaces one still being restored without it ever being read.
    [_pendingTape release];
    _pendingTape = nil;
    [self latch:CSKeyCount];
    [self showLabel:[_engine title] artist:[_engine artist] animated:animated];
    [self refreshTape];
    [self reevaluate];
    return YES;
}

- (BOOL)loadURL:(NSURL *)url play:(BOOL)play
{
    NSError *error = nil;
    if (![self insertURL:url error:&error animated:YES]) {
        [self presentAlert:[error localizedDescription]
                    detail:[error localizedRecoverySuggestion]];
        return NO;
    }
    [self rememberTape:url];
    if (play) [self play];
    return YES;
}

- (void)chooseTape
{
    if (_panelOpen) return;
    [self finishRestoringTape];
    [self showDeck];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowedFileTypes:[CSAudioEngine readableTypes]];
    [panel setAllowsMultipleSelection:NO];
    [panel setCanChooseDirectories:NO];
    [panel setMessage:@"Choose a sound file to put in the deck. It plays on a loop until you stop it."];
    [panel setPrompt:@"Insert"];
    NSURL *current = [_engine URL];
    if (current) [panel setDirectoryURL:[current URLByDeletingLastPathComponent]];

    _panelOpen = YES;
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSInteger result) {
        _panelOpen = NO;
        if (result != NSFileHandlingPanelOKButton || [[panel URLs] count] == 0) return;
        NSURL *url = [[[panel URLs] objectAtIndex:0] retain];
        // After the sheet has gone, so that an error can use the same window.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self loadURL:url play:YES];
            [url release];
        });
    }];
}

// Takes the tape out: the music stops, and the deck is empty, as it would be
// at launch next time too. With no tape in, EJECT is the way to put one in.
- (void)eject
{
    if (![self hasTape]) {
        [self chooseTape];
        return;
    }
    [_pendingTape release];
    _pendingTape = nil;
    [_engine eject];
    [self latch:CSKeyCount];
    [_deck setTapeLoaded:NO title:nil artist:nil animated:YES];
    [[self window] setTitle:@"Cassette"];
    [self forgetTape];
    [self refreshTape];
    [self reevaluate];
}

// The tape, and what is written on it, so that the next launch can put the
// label up before the sound has been read.
- (void)rememberTape:(NSURL *)url
{
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil
                                      relativeToURL:nil error:NULL];
    if (!bookmark) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:bookmark forKey:CSLastTapeKey];
    [defaults setObject:[_engine title] ? [_engine title] : @"" forKey:CSLastTitleKey];
    if ([_engine artist]) [defaults setObject:[_engine artist] forKey:CSLastArtistKey];
    else [defaults removeObjectForKey:CSLastArtistKey];
}

- (void)forgetTape
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:CSLastTapeKey];
    [defaults removeObjectForKey:CSLastTitleKey];
    [defaults removeObjectForKey:CSLastArtistKey];
}

// The tape that was in the deck when it was last used goes back in, stopped:
// a deck remembers its cassette, but it does not start playing by itself.
//
// Reading the file and opening the sound output is a tenth of a second or
// more, and none of it is needed to draw the deck. So the label goes up now,
// from what was saved with the tape, and the sound is read just after the
// window has first been drawn: a zero-delay perform waits for the run loop to
// go round, and the window is drawn on its way round. Anything that needs the
// sound first -- Play, Stop, a new tape -- finishes the job on the spot.
- (void)restoreLastTape
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSData *bookmark = [defaults dataForKey:CSLastTapeKey];
    if (!bookmark) return;
    BOOL stale = NO;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
        options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting
        relativeToURL:nil bookmarkDataIsStale:&stale error:NULL];
    if (!url || ![url checkResourceIsReachableAndReturnError:NULL]) return;

    NSString *title = [defaults stringForKey:CSLastTitleKey];
    if (!title) {
        // Saved by a version that kept no label: read it all now.
        if ([self insertURL:url error:NULL animated:NO]) [self rememberTape:url];
        return;
    }
    [self showLabel:title artist:[defaults stringForKey:CSLastArtistKey] animated:NO];
    _pendingTape = [url retain];
    _pendingStale = stale;
    [self refreshTape];
    [self performSelector:@selector(finishRestoringTape) withObject:nil afterDelay:0];
}

- (void)finishRestoringTape
{
    if (!_pendingTape) return;
    NSURL *url = [[_pendingTape retain] autorelease];
    BOOL stale = _pendingStale;
    [_pendingTape release];
    _pendingTape = nil;
    if ([self insertURL:url error:NULL animated:NO]) {
        // Tags can change between launches; the label follows them.
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *artist = [defaults stringForKey:CSLastArtistKey];
        BOOL sameLabel = [[defaults stringForKey:CSLastTitleKey] isEqualToString:[_engine title]] &&
                         (artist == [_engine artist] || [artist isEqualToString:[_engine artist]]);
        if (stale || !sameLabel) [self rememberTape:url];
        return;
    }
    // It could not be played after all, so the deck is empty, quietly, as it
    // would have been before. The tape is still remembered: what failed may
    // have been the sound output rather than the file, and that passes.
    [_deck setTapeLoaded:NO title:nil artist:nil animated:NO];
    [[self window] setTitle:@"Cassette"];
    [self refreshTape];
}

- (void)presentAlert:(NSString *)message detail:(NSString *)detail
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:message ? message : @"Something went wrong."];
    if (detail) [alert setInformativeText:detail];
    [alert addButtonWithTitle:@"OK"];
    NSWindow *w = [self window];
    if (_windowOpen && [w isVisible] && ![w attachedSheet])
        [alert beginSheetModalForWindow:w completionHandler:nil];
    else
        [alert runModal];
}

#pragma mark - Volume

- (void)setVolumePosition:(float)position save:(BOOL)save
{
    [_deck setVolumePosition:position];
    [_engine setVolume:CSGainForPosition([_deck volumePosition])];
    if (save)
        [[NSUserDefaults standardUserDefaults] setFloat:[_deck volumePosition] forKey:CSVolumeKey];
}

- (void)nudgeVolume:(float)delta
{
    [self setVolumePosition:[_deck volumePosition] + delta save:YES];
}

- (void)saveState
{
    [[NSUserDefaults standardUserDefaults] setFloat:[_deck volumePosition] forKey:CSVolumeKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - The deck's controls

- (void)deckView:(CSDeckView *)deck pressedKey:(CSKey)key
{
    switch (key) {
        case CSKeyEject: [self eject];      break;
        case CSKeyPlay:  [self play];       break;
        case CSKeyPause: [self pause];      break;
        case CSKeyStop:  [self stop];       break;
        default: break;
    }
}

- (void)deckView:(CSDeckView *)deck movedVolumeKnobTo:(float)position finished:(BOOL)finished
{
    [self setVolumePosition:position save:finished];
}

- (BOOL)deckView:(CSDeckView *)deck canAcceptDroppedURL:(NSURL *)url
{
    return !_panelOpen && [CSAudioEngine canProbablyReadURL:url];
}

- (void)deckView:(CSDeckView *)deck droppedURL:(NSURL *)url
{
    [self loadURL:url play:YES];
}

- (void)deckViewClickedEmptyCompartment:(CSDeckView *)deck
{
    [self chooseTape];
}

- (void)deckView:(CSDeckView *)deck mouseDownOnCabinet:(NSEvent *)event
{
    [(CSDeckWindow *)[self window] trackMoveFromEvent:event];
}

@end
