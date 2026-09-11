# Masterful — build, bundle, sign, install.
#
# There is no .xcodeproj on purpose. SwiftPM builds the code, and this file
# assembles the .app around it: every step is visible, reviewable in a diff, and
# reproducible from a clean checkout. `open Package.swift` still gives Xcode and
# SwiftUI previews for the library targets.

APP_NAME    := Masterful
BUNDLE_ID   := com.tlotliso.masterful
CONFIG      ?= release
BUILD_DIR   := .build/$(CONFIG)
DIST_DIR    := build
APP_BUNDLE  := $(DIST_DIR)/$(APP_NAME).app
CONTENTS    := $(APP_BUNDLE)/Contents

# First Apple Development identity in the keychain. Override with:
#   make app SIGN_ID="Developer ID Application: ..."
SIGN_ID ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $$2; exit}')

.PHONY: all build app sign install run stop test clean reset-permissions icon shots voice preview probe probe-mouse eval record eval-asr eval-asr-list

all: app

build:
	swift build -c $(CONFIG)

## Show what your keyboard and mouse actually emit, and what is bindable.
probe-mouse:
	@swift Tools/mouse-probe.swift $(SECONDS_ARG)

## Measure clean-up quality and latency across every mode.
eval:
	@swift run -c release masterful-eval

## Read the reference passages aloud, once. Run this in your own terminal:
## a CLI inherits microphone permission from whatever launched it.
record:
	@swift run -c release masterful-asr-eval record $(PASSAGE)

## Replay that recording through every installed model and rank them by word
## error rate. Add LOCALES="en_GB,en_US" to name them explicitly.
eval-asr:
	@swift run -c release masterful-asr-eval run $(if $(LOCALES),--locales $(LOCALES),)

## What has been recorded so far.
eval-asr-list:
	@swift run -c release masterful-asr-eval list

## Diagnose why text is not appearing in a particular app. Focus the field
## under test, then run this; it reports what each insertion strategy does.
probe:
	@swift Tools/insertion-probe.swift

## Regenerate the app icon. Drawn in code so it stays reviewable in a diff.
icon:
	swift Tools/make-icon.swift

## Render the island's documented states out of HUDView itself, plus the state
## strip and the coalescence as GIFs in docs/island. Same reasoning as `icon`:
## an image generated from the real view cannot drift away from what ships —
## and unlike a screen recording it can show the notch, which is in the panel
## rather than the framebuffer and so appears in no capture. Needs ImageMagick.
shots:
	@swift run HUDShots $(DIST_DIR)/shots
	@command -v magick >/dev/null || { echo "   (skipping GIF — ImageMagick not installed)"; exit 0; }; \
	mkdir -p docs/island && cd $(DIST_DIR)/shots && magick -loop 0 \
		-delay 90  00-rest.png \
		-delay 110 01-listening.png -delay 120 02-latched.png \
		-delay 70  03-transcribing.png -delay 130 04-delivered.png \
		-delay 190 05-delivered-clipboard.png -delay 190 06-blocked.png \
		-delay 170 07-failed.png -delay 190 08-failed-permission.png \
		-resize 700x -dither None -colors 200 -layers OptimizeTransparency \
		../../docs/island/states.gif && \
	echo "   docs/island/states.gif" && \
	magick -loop 0 -delay 3.33 motion/frame-*.png \
		-crop 200x76+700+0 +repage \
		-resize 400% -dither None -colors 64 -layers OptimizeTransparency \
		../../docs/island/morph-closeup.gif && \
	echo "   docs/island/morph-closeup.gif" 

## Render what a VoiceOver user hears into docs/audio, through the same system
## speech engine VoiceOver itself speaks with. The text comes from HUDAnnouncer,
## not from a script typed here, so a recording cannot drift from the app.
## Override the voice with VOICE="Samantha".
VOICE ?= Daniel
voice: shots
	@mkdir -p docs/audio
	@while IFS=$$'\t' read -r name text; do \
		say -v "$(VOICE)" -o "docs/audio/$$name.m4a" --data-format=aac "$$text" && \
		echo "   docs/audio/$$name.m4a  —  $$text"; \
	done < $(DIST_DIR)/shots/announcements.tsv

## Cycle the HUD through every state with the microphone and hotkeys inactive.
## Turn VoiceOver on first (Cmd-F5) to hear the announcements as well as see
## them — they are posted only when VoiceOver is actually running, since nothing
## else consumes them. ANCHOR=notch|topCenter|bottomCenter previews one position.
preview:
	@MASTERFUL_HUD_PREVIEW=1 $(if $(ANCHOR),MASTERFUL_HUD_ANCHOR=$(ANCHOR),) swift run Masterful

## Assemble and sign the .app bundle.
app: build Resources/AppIcon.icns
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@# SwiftPM emits resource bundles next to the binary; carry any across.
	@for bundle in $(BUILD_DIR)/*.bundle; do \
		[ -e "$$bundle" ] && cp -R "$$bundle" "$(CONTENTS)/Resources/" || true; \
	done
	@$(MAKE) --no-print-directory sign
	@echo "Built $(APP_BUNDLE)"

## Sign with hardened runtime. A stable signing identity matters beyond
## distribution: macOS keys TCC grants (microphone, Accessibility) to it, so an
## unsigned or ad-hoc-signed build asks for permission again on every rebuild.
sign:
ifeq ($(strip $(SIGN_ID)),)
	@echo "No codesigning identity found — signing ad hoc."
	@echo "   Permissions will need re-granting after each rebuild."
	@codesign --force --options runtime \
		--entitlements Resources/Masterful.entitlements \
		--sign - "$(APP_BUNDLE)"
else
	@echo "Signing as: $(SIGN_ID)"
	@codesign --force --options runtime \
		--entitlements Resources/Masterful.entitlements \
		--sign "$(SIGN_ID)" "$(APP_BUNDLE)"
endif
	@codesign --verify --verbose=2 "$(APP_BUNDLE)" 2>&1 | sed 's/^/   /'

## Install into /Applications. Quits any running copy first, because a running
## binary cannot be replaced in place.
install: app
	@$(MAKE) --no-print-directory stop
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" /Applications/
	@echo "Installed /Applications/$(APP_NAME).app"

run: app
	@$(MAKE) --no-print-directory stop
	@open "$(APP_BUNDLE)"

stop:
	@pkill -x "$(APP_NAME)" 2>/dev/null || true

test:
	swift test

## Forget this app's microphone and Accessibility grants, to re-test onboarding.
reset-permissions:
	@tccutil reset Microphone $(BUNDLE_ID) || true
	@tccutil reset Accessibility $(BUNDLE_ID) || true
	@tccutil reset SpeechRecognition $(BUNDLE_ID) || true

clean:
	swift package clean
	@rm -rf "$(DIST_DIR)"

Resources/AppIcon.icns: Tools/make-icon.swift
	@swift Tools/make-icon.swift
