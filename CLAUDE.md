# Cassette — notes for Claude

A tape deck for OS X 10.9 Mavericks that plays one audio file on an endless, gapless
loop, drawn as a 1970s front-loader. Objective-C, no third-party code. `README.md` is
the spec.

This repo is **public**. Keep personal paths and names out of it.

## Building

Build with `make dist` on a modern Mac with Xcode. Pass
`SDK="$HOME/Developer/SDKs/MacOSX10.9.sdk"` to link against the real 10.9.5 SDK. After
a change, rebuild `Cassette.zip` and commit it. A 10.9 machine can't build this tree;
on one, the job is to install, run and report.

## Behaviour to keep

- Cassette pauses at sleep (b72e401), so it no longer holds the Mac awake after a wake.
  Nightlatch depends on that.
- The block cue: `CSAppDelegate` plays on the distributed notification
  `com.syllabus.block.started` and pauses on `com.syllabus.block.ended`, which Syllabus
  posts. The names are shared with Syllabus; change both repos or neither. A cue never
  asks for a tape, an end never presses PAUSE on a paused deck (that would play), and a
  start between `NSWorkspaceWillSleepNotification` and the wake is ignored, so the sleep
  pause holds.

## 10.9 traps (verified)

- A current SDK binds many Foundation classes to CoreFoundation. A name that 10.9's CF
  doesn't export stops loading with "Symbol not found". The 10.9.5 SDK's CF stub is the
  ground truth. To check: `nm -um <binary> | grep 'from CoreFoundation'`.
- Icons (`Tools/mkicon.m`): check at 128 and 32 px on #EDEDED. CG shadows are in device
  pixels, so scale them.

## Still untested on the real Mac Pro

- Everything under "Not verified" in the README: the handle's window buttons and shadow.
- The block cue between the two apps on 10.9: a start posted by Syllabus in front
  reaching Cassette in the background and playing the tape, and the end pausing it.
