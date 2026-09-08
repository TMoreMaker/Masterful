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

.PHONY: all build app sign install run stop test clean reset-permissions icon probe probe-mouse eval record eval-asr eval-asr-list

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
