# Cassette

A tape deck for **OS X 10.9 Mavericks** that plays one audio file on an endless
loop.

Put a sound file in, and it plays until you stop it, looping with no gap or
click at the seam. The deck is drawn as a 1970s front-loader: walnut cheeks,
brushed-aluminium faceplate, a smoked door over a C60 with the song's name
handwritten on its label, and two reels that turn while it plays. In place of
the grey title bar there is a black leather carrying handle, with the window's
real close and minimise buttons set into it and the song's name stamped in the
middle.

Everything is local. There are no network calls, no packages, no downloads and
no third-party code. It uses only frameworks that ship with 10.9.

---

## Installing on the Mavericks machine

1. Copy **`Cassette.zip`** across (USB stick is fine) and unzip it.
2. Drag `Cassette.app` to `/Applications`.
3. **Right-click the app and choose "Open"**, then confirm. The app is not
   signed with a Developer ID, so a plain double-click the first time is
   refused as "from an unidentified developer". You only need to do this once.

Run it from `/Applications`, not from the USB stick. OS X reads an app's code
from its file for as long as the app is open, so ejecting the stick while it
runs kills it. (Postview's README explains this in detail.)

## Using it

| | |
|---|---|
| **EJECT** ⏏ or ⌘E | Take the tape out. The music stops and the compartment is empty. |
| EJECT on an empty deck, a click in the empty compartment, or ⌘O | Choose a sound file. It goes in and starts playing on a loop. |
| Drag a file onto the deck | Same thing. One file at a time: the deck holds one tape. |
| **PLAY** ▶ | Play, or resume. The key stays down while the tape runs. |
| **PAUSE** ❚❚ | Hold the position. Press it again, or PLAY, to carry on. |
| **STOP** ■ or ⌘. | Stop and rewind to the start of the file. |
| Space | Play / pause. |
| Volume knob | Drag up or right to turn it up; the scroll wheel works over it too. ⌘↑ / ⌘↓ from the keyboard. |
| Drag the handle | Moves the deck, as a title bar would; so does dragging the cabinet anywhere that isn't a control. Double-click the handle to minimise it, if that is set in System Preferences > Dock. |
| Close the window | The music keeps playing. Click the Dock icon, or ⌘1, to bring the deck back. |
| Dock icon menu | Play / Pause, Stop and Eject without bringing the deck forward. |
| A Syllabus block starting or ending | The tape plays when a block starts and pauses when it ends, the keys going down as if pressed. A tape that sleep paused plays at the next start; an empty deck stays empty. |

Finder's **Open With → Cassette** works too. Cassette registers as an
*alternate* handler for audio, so installing it doesn't take any file type away
from iTunes or QuickTime.

The deck remembers its last tape. It goes back in at the next launch, stopped:
a deck keeps its cassette, but it doesn't start playing by itself. A tape you
eject is gone for good: the next launch starts with an empty deck.

Sleep pauses the tape. If the Mac goes to sleep while a tape plays, it wakes
with the tape paused at the same spot and the PAUSE key down; PLAY or PAUSE
carries on. So a wake nobody meant, such as a mouse nudged in the night, stays
silent, and the Mac can go back to sleep on its own. A tape left playing still
keeps the Mac awake, as any music does.

**Formats:** anything OS X 10.9 can decode: AIFF, WAV, MP3, AAC and Apple
Lossless (`.m4a`), Core Audio (`.caf`) and a few others. FLAC and Ogg are not
among them on Mavericks. A file that can't be played is refused with an
explanation, and whatever tape was in stays in.

### The tape counter, the packs and AUTO REVERSE

The counter shows seconds of tape played since the last rewind, 000 to 999 and
round again. It counts straight on across the loops, the way a counter geared to
the reels would, so even a one-second sound shows the tape going by. Pause holds
it, Stop and Eject put it back to 000.

The reels behave like a real C60 at 1⅞ in/s. The tape pack moves from the left
reel to the right as it plays, and each reel turns at tape speed divided by its
own radius, so the empty hub spins about twice as fast as the full one. A side
is a whole number of loops of your file, at least thirty minutes long. At the
end of a side the deck **auto-reverses** (the REV lamp lights and both reels
turn the other way), exactly on a loop boundary. The tape never jumps back to
the start, however short or long the file.

None of this changes what you hear. The file loops the same either way.

## Reels, power and battery

| Power | Reels turn when… |
|---|---|
| **AC / wall** | the tape is playing. Continuously, whether or not Cassette is in front. |
| **Battery** | the tape is playing **and** Cassette is the frontmost app **and** its window can be seen. In the background, minimised, hidden or covered, the reels hold still and the only work left is the audio itself. |
| Can't tell | Treated as battery. An unreadable answer never switches the more expensive behaviour on. |

With the window closed, nothing animates in either case (the music plays on).

The **POWER** lamps on the deck show which one Cassette thinks it's on. The
switch takes effect the moment the charger is plugged in or pulled: the kernel
notifies the app, so nothing polls for it.

A Mac Pro has no battery and always reports AC. To see the battery behaviour on
it anyway:

```
open Cassette.app --args -CSPowerState battery
```

(`-CSPowerState ac` forces the other way; leaving it off asks the machine.)

## Why it is light

- **Nothing is drawn per frame.** The whole deck is drawn once, procedurally
  (wood, metal, paper and plastic generated from noise at the display's own
  resolution), into Core Animation layers. Spinning a reel is a rotation
  animation of a finished bitmap, run by the compositor. Stopping the reels
  removes the animation outright, so a still deck costs nothing.
- **Nothing is drawn twice.** The first launch keeps every finished bitmap in
  `~/Library/Caches/com.cassette.Cassette/Artwork` (about 3 MB on an ordinary
  display, 12 MB on a Retina one), and every later launch maps those files
  straight back in instead of drawing. The cache belongs to one build of the
  app and one version of OS X; a new copy of the app draws afresh and deletes
  the old one. The first launch itself spreads the texture work across all the
  Mac's cores.
- **The window comes first.** The last tape's label is saved with it, so at
  launch the deck shows the cassette at once and reads the sound file just
  after the window is on screen. Pressing Play before then simply reads it on
  the spot.
- **No polling.** Focus, visibility (10.9's window occlusion), sleep and the
  power source all arrive as notifications. While the reels are still, the only
  timer in the process fires about once an hour. While they turn, one more
  moves the counter once a second, with slack so the system can coalesce it.
- **The audio path is the system's own file player** feeding the default output:
  streamed from disk (a three-hour file costs no more memory than a
  three-second one), looped sample-accurately by the player, and run with a
  4096-frame device buffer, so the audio thread wakes about 11 times a second
  instead of 86.
- `NSSupportsAutomaticGraphicsSwitching` keeps dual-GPU MacBook Pros on the
  integrated GPU.

Measured on the development machine (Apple silicon, running the x86_64 build
under Rosetta, playing an AAC file): **0.7% CPU** with the reels turning in
front, **0.5%** on battery in the background (reels still, audio only), about
one idle wakeup a second. Launch, from `open` to the deck on screen with a
tape restored: about **0.45 s**, where the previous version took about
**0.97 s**; building the deck's layers takes about 27 ms from the cache against
about 200 ms drawing them (Retina, 2x). The Mac Pro's figures will differ. They
have not been taken there.

## Building

Needs Xcode or the Command Line Tools with a macOS SDK. No network access.

```
make            # Cassette.app
make run        # build and open it
make test       # unit, audio-engine and live-controller checks
make snapshot   # renders the deck, and the whole window, to build/shots/*.png
make verify     # Mach-O checks for Mavericks (below)
make analyze    # clang static analyser; any finding fails
make dist       # all of the above, then Cassette.zip
make icon       # regenerate Resources/Cassette.icns from the artwork code
```

It builds x86_64 with `-mmacosx-version-min=10.9`, and
`-Werror=unguarded-availability` turns any API newer than 10.9 into a compile
error, the same way Postview does. Manual retain/release, because ARC at a
10.9 target needs a runtime shim current toolchains no longer ship.

`make verify` checks the binary: one x86_64 slice, minimum OS 10.9 in the load
command Mavericks understands, none of the newer load commands its `dyld`
rejects, only frameworks that exist on 10.9, and **every Core Audio symbol bound
to the framework that exports it on 10.9**. That last check matters. On current
macOS the audio-unit functions live in AudioToolbox; on 10.9 they live in
AudioUnit. With the frameworks linked in the other order, the build succeeds and
the app dies at launch on Mavericks. `make verify` caught exactly that during
development.

### What has and hasn't been verified

Verified on the development machine, x86_64 build: 68 unit, 44 audio-engine
and 65 controller checks. Those include gapless, sample-exact looping across 24
passes and 8 scheduled regions, pause and resume continuing from the exact
sample, an output that will not start keeping the tape's place, a tape playing
at sleep coming back paused in the same place with the deck showing PAUSE
rather than PLAY, a file that
cannot be played leaving a restored tape in the deck, an AAC file looping with
no priming gap, the battery and AC reel
policy driven through real focus changes, the counter running past the end of
a two-second loop in a live window, eject, the restored tape appearing before
its sound is read, the borderless window minimising and keeping its size, and
the artwork cache giving back exactly the pixels it was given (and ignoring a
damaged file), and Syllabus's block cue: a start playing the tape and an end
pausing it, through the real distributed notification centre with delivery
suspended as it is for an app in the background; an end leaving a paused deck
paused; and a start doing nothing to an empty deck or one going to sleep. Also
verified: clean static analysis and `make verify`.

**Not verified: running on 10.9 itself.** The development machine can't run
Mavericks. The part of this version most particular to 10.9 is the handle: the
window has no system title bar, and puts the standard close, minimise and zoom
buttons on the leather itself, using only public API that 10.9 has. Check on
the Mac Pro that they show their colours, and their ×, − symbols under the
pointer, and that the window casts its shadow. Check too that a Syllabus block
starting with Syllabus in front plays the tape, and that its end pauses it.
Every class and function the binary imports has been checked against
where it lives on 10.9: the Foundation classes by comparison with Postview's
binary, which is known to run on this Mac Pro. But the first launch on the Mac
Pro is the real test. For a release, build against a real 10.9 SDK if you have
one:

```
make clean dist SDK=/path/to/MacOSX10.9.sdk REQUIRE_SDK=10.9
```

## Layout

| | |
|---|---|
| `Sources/CSAudioEngine` | File player → default output; looping, pause, sleep |
| `Sources/CSPower` | Power source, its change notification, and the reel policy (a pure function) |
| `Sources/CSTape` | The C60 model: pack radii, reel speeds, auto-reverse (pure) |
| `Sources/CSArtwork` | Every drawing, and the deck's geometry |
| `Sources/CSArtworkCache` | Finished drawings kept on disk between launches |
| `Sources/CSDeckView` | The layer tree, the reel animation, keys, knob, drag and drop |
| `Sources/CSDeckWindow` | The borderless window and its leather handle, with the real window buttons on it |
| `Sources/CSPlayerController` | Window, transport, and when the reels may move |
| `Sources/CSAppDelegate` | Menus, Open With, launch and reopen, and Syllabus's block cue |
| `Tests/cssuite.m` | Every check, one subcommand per suite |
| `Tools/mkicon.m` | Draws the icon from the deck's own cassette artwork |
