# Cassette -- one audio file on an endless loop, for OS X 10.9 Mavericks.
#
# Built with a current Xcode toolchain but targeted at 10.9, the way Postview
# is: -mmacosx-version-min=10.9 makes the linker emit the load commands
# Mavericks' dyld understands, and -Werror=unguarded-availability turns any use
# of an API newer than 10.9 into a compile error.
#
# Nothing here reaches the network. There are no packages, no downloads and no
# third-party code: the build needs clang and the macOS SDK, and the app needs
# only frameworks that ship with 10.9.
#
#   make              build Cassette.app
#   make run          build and launch it
#   make run-battery  launch it as if on battery (to see that policy on a desktop)
#   make test         unit, audio and policy checks (Tests/cssuite.m)
#   make snapshot     render the deck to PNGs in build/shots, for looking at
#   make verify       check the binary really is Mavericks-compatible
#   make analyze      clang static analyser; any finding fails
#   make dist         all of the above, then Cassette.zip
#   make icon         regenerate Resources/Cassette.icns from the artwork code
#   make clean

APP      := Cassette
BUNDLE   := $(APP).app
BUILD    := build
CONTENTS := $(BUNDLE)/Contents
MACOS    := $(CONTENTS)/MacOS
RES      := $(CONTENTS)/Resources
ICON     := Resources/$(APP).icns

CC       := $(shell xcrun -f clang)
SDK      ?= $(shell xcrun --show-sdk-path)
HOST_SDK := $(shell xcrun --show-sdk-path)
MIN      := 10.9

# Armed where the compiler knows the warning group, skipped where it does not
# (an Xcode 5/6-era clang on the Mavericks machine itself), exactly as Postview
# does it -- an unknown -Werror= group is itself an error on old compilers.
AVAILABILITY_CFLAGS := $(shell \
	printf '' | $(CC) -x objective-c -fsyntax-only -Werror \
	  -Wunguarded-availability -Wunguarded-availability-new - \
	  >/dev/null 2>&1 && \
	printf '%s' '-Werror=unguarded-availability -Werror=unguarded-availability-new')

# -march=core2: Mavericks runs on Macs back to 2007; the Mac Pro would take
# more, but nothing here is compute-bound enough to be worth excluding them.
# Manual retain/release, because ARC at a 10.9 deployment target needs
# libarclite, which current toolchains no longer ship.
CFLAGS := -arch x86_64 -march=core2 -mmacosx-version-min=$(MIN) -isysroot $(SDK) \
          -fno-objc-arc -fobjc-exceptions -Os -fno-common -fvisibility=hidden \
          -Wall -Wextra -Wno-unused-parameter $(AVAILABILITY_CFLAGS) \
          -Wno-deprecated-declarations -Wno-objc-missing-property-synthesis

# Every framework is one that exists at this path on 10.9; `make verify`
# re-checks the list after each build.
#
# AudioUnit is named explicitly, and BEFORE AudioToolbox, and both matter. On
# current systems the audio-unit functions (AudioComponent*, AudioUnit*,
# AudioOutputUnit*) live in AudioToolbox, and AudioUnit merely re-exports them;
# on 10.9 they live in AudioUnit and AudioToolbox does not have them. The linker
# records the first framework on the line that provides a symbol, so with
# AudioToolbox first every one of them was bound to it -- a binary that would
# die at launch on Mavericks with "symbol not found". `make verify` checks that
# each landed where Mavericks keeps it.
FRAMEWORKS := -framework Cocoa -framework QuartzCore -framework CoreGraphics \
              -framework AudioUnit -framework AudioToolbox -framework IOKit
LDFLAGS := -arch x86_64 -mmacosx-version-min=$(MIN) -isysroot $(SDK) \
           $(FRAMEWORKS) -Wl,-dead_strip

SOURCES := $(wildcard Sources/*.m)
OBJECTS := $(patsubst Sources/%.m,$(BUILD)/%.o,$(SOURCES))
DEPS    := $(OBJECTS:.o=.d)

.PHONY: all run run-battery test snapshot verify analyze dist icon clean

all: $(BUNDLE)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: Sources/%.m Makefile | $(BUILD)
	@echo "  compile  $<"
	@$(CC) $(CFLAGS) -MMD -MP -MF $(@:.o=.d) -c $< -o $@

-include $(DEPS)

$(BUNDLE): $(OBJECTS) Resources/Info.plist $(ICON)
	@echo "  link     $(MACOS)/$(APP)"
	@mkdir -p $(MACOS) $(RES)
	@$(CC) $(LDFLAGS) $(OBJECTS) -o $(MACOS)/$(APP)
	@strip -x $(MACOS)/$(APP)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@cp $(ICON) $(RES)/$(APP).icns
	@touch $(BUNDLE)
	@echo "  built    $(BUNDLE)"

run: $(BUNDLE)
	@open $(BUNDLE)

run-battery: $(BUNDLE)
	@open -n $(BUNDLE) --args -CSPowerState battery

# ---- Tests ---------------------------------------------------------------
#
# One program, built for the shipping target like everything else. On an Apple
# silicon host it runs under Rosetta, which is also the nearest thing to the
# Mac Pro's Intel CPU that this machine has.
SUITE     := $(BUILD)/cssuite
SUITEOBJS := $(filter-out $(BUILD)/main.o,$(OBJECTS))

$(SUITE): Tests/cssuite.m $(SUITEOBJS) | $(BUILD)
	@echo "  compile  Tests/cssuite.m"
	@$(CC) $(CFLAGS) -ISources -c Tests/cssuite.m -o $(BUILD)/cssuite.o
	@$(CC) $(LDFLAGS) $(SUITEOBJS) $(BUILD)/cssuite.o -o $(SUITE)

test: $(SUITE)
	@$(SUITE) unit
	@$(SUITE) audio $(BUILD)/fixtures
	@$(SUITE) deck

snapshot: $(SUITE)
	@$(SUITE) snapshot $(BUILD)/shots

# ---- Mavericks compatibility ---------------------------------------------
#
# What `make verify` can prove without a Mavericks machine: one x86_64 slice,
# minimum OS 10.9 in the old-style load command, none of the newer load
# commands 10.9's dyld rejects, only frameworks that exist on 10.9, and every
# Core Audio symbol bound to the framework that exports it there.
#
# What it cannot prove is that nothing was compiled against a newer header's
# idea of a struct. For that, build against the real 10.9 SDK:
#   make clean all verify SDK=/path/to/MacOSX10.9.sdk REQUIRE_SDK=10.9
REQUIRE_SDK ?= any

verify: $(BUNDLE)
	@echo "== Mach-O compatibility check =="
	@plutil -lint $(CONTENTS)/Info.plist >/dev/null || { echo "FAIL: Info.plist"; exit 1; }
	@test -f $(RES)/$(APP).icns || { echo "FAIL: icon missing from bundle"; exit 1; }
	@m=$(MACOS)/$(APP); \
	archs="$$(lipo -archs $$m)"; \
	[ "$$archs" = "x86_64" ] || { echo "FAIL: architectures: $$archs"; exit 1; }; \
	min="$$(otool -l $$m | awk '/LC_VERSION_MIN_MACOSX/{getline; getline; print $$2; exit}')"; \
	[ "$$min" = "10.9" ] || { echo "FAIL: minimum OS is '$$min'"; exit 1; }; \
	sdk="$$(otool -l $$m | awk '/LC_VERSION_MIN_MACOSX/{getline; getline; getline; print $$2; exit}')"; \
	if [ "$(REQUIRE_SDK)" != "any" ] && [ "$$sdk" != "$(REQUIRE_SDK)" ]; then \
	  echo "FAIL: built against SDK $$sdk, not $(REQUIRE_SDK)"; exit 1; fi; \
	echo "   x86_64, minimum OS $$min, built against SDK $$sdk"; \
	if otool -l $$m | grep -q LC_BUILD_VERSION; then echo "FAIL: LC_BUILD_VERSION present"; exit 1; fi; \
	if otool -l $$m | grep -q LC_DYLD_CHAINED_FIXUPS; then echo "FAIL: chained fixups"; exit 1; fi; \
	if otool -l $$m | grep -q LC_RPATH; then echo "FAIL: LC_RPATH present"; exit 1; fi; \
	otool -L $$m | tail -n +2 | sed 's/^/   /'; \
	otool -L $$m | tail -n +2 | awk '{print $$1}' | \
	  grep -vE '^/System/Library/Frameworks/(Cocoa|AppKit|Foundation|CoreFoundation|CoreGraphics|QuartzCore|AudioToolbox|AudioUnit|IOKit)\.framework/Versions/[A-Z]/[A-Za-z]+$$' | \
	  grep -vE '^/usr/lib/(libSystem\.B|libobjc\.A)\.dylib$$' | \
	  (! grep .) || { echo "FAIL: unexpected dylib above"; exit 1; }; \
	nm -m $$m > $(BUILD)/symbols.txt; \
	bad="$$(grep -E 'external _Audio(Component|Unit|OutputUnit)[A-Za-z]*' $(BUILD)/symbols.txt | grep -v '(from AudioUnit)')"; \
	[ -z "$$bad" ] || { echo "FAIL: audio-unit symbols not bound to AudioUnit (absent from 10.9's AudioToolbox):"; echo "$$bad"; exit 1; }; \
	bad="$$(grep -E 'external _(AudioFile|ExtAudioFile)[A-Za-z]*' $(BUILD)/symbols.txt | grep -v '(from AudioToolbox)')"; \
	[ -z "$$bad" ] || { echo "FAIL: audio-file symbols not bound to AudioToolbox:"; echo "$$bad"; exit 1; }; \
	n="$$(grep -cE 'external _Audio(Component|Unit|OutputUnit)' $(BUILD)/symbols.txt)"; \
	echo "   $$n audio-unit symbols bound to AudioUnit, audio-file symbols to AudioToolbox"
	@echo "OK"

analyze: | $(BUILD)
	@echo "== Clang static analysis =="
	@log=$(BUILD)/analyze.log; : > $$log; status=0; \
	for f in $(SOURCES); do \
	  $(CC) $(CFLAGS) --analyze -Xanalyzer -analyzer-output=text $$f -o /dev/null >> $$log 2>&1 || status=1; \
	done; \
	if grep -qE '(warning|error):' $$log; then cat $$log; echo "FAIL: analyser findings"; exit 1; fi; \
	[ $$status -eq 0 ] || { cat $$log; echo "FAIL: analyser did not run"; exit 1; }
	@echo "OK"

# ---- Distribution ----------------------------------------------------------

dist: all verify analyze test
	@rm -rf $(BUILD)/dist $(APP).zip
	@mkdir -p $(BUILD)/dist
	@ditto $(BUNDLE) $(BUILD)/dist/$(BUNDLE)
	@cp README.md $(BUILD)/dist/README.md
	@xattr -cr $(BUILD)/dist 2>/dev/null || true
	@cd $(BUILD)/dist && ditto -c -k --norsrc --noextattr --noqtn --noacl . ../../$(APP).zip
	@echo "  packaged $(APP).zip ($$(du -h $(APP).zip | cut -f1))"

# ---- Icon ------------------------------------------------------------------
#
# The icon is the deck's own cassette artwork, drawn at every size by a host
# tool that links CSArtwork.m. The .icns is kept in Resources so a build never
# depends on the host's iconutil; this regenerates it on demand, or if missing.
MKICON := $(BUILD)/mkicon

$(MKICON): Tools/mkicon.m Sources/CSArtwork.m Sources/CSArtwork.h | $(BUILD)
	@echo "  compile  Tools/mkicon.m (host)"
	@$(CC) -isysroot $(HOST_SDK) -fno-objc-arc -O2 -Wno-deprecated-declarations -ISources -framework Cocoa \
	   Tools/mkicon.m Sources/CSArtwork.m -o $@

$(ICON):
	@$(MAKE) --no-print-directory icon

icon: $(MKICON)
	@rm -rf $(BUILD)/$(APP).iconset
	@$(MKICON) $(BUILD)/$(APP).iconset
	@iconutil -c icns $(BUILD)/$(APP).iconset -o $(ICON)
	@echo "  wrote    $(ICON)"

clean:
	@rm -rf $(BUILD) $(BUNDLE)
