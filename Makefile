# Plainchain: SwiftUI app bundled into build/Plainchain.app
APP     := Plainchain
BUILD   := build
BUNDLE  := $(BUILD)/$(APP).app
BIN     := app/.build/release/$(APP)
ICON    := $(BUILD)/AppIcon.icns
ICONSRC := app/Assets/icon-1024.png
# A real signing identity keeps the microphone permission across rebuilds; ad-hoc ("-") does not.
# Hardened runtime, with entitlements that let third-party plugins load in-process.
SIGN    := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1)
SIGN    := $(if $(SIGN),$(SIGN),-)

.PHONY: all app bundle run install smoke clean icon notarize dist

all: bundle

app:
	swift build -c release --package-path app

# The .icns is derived from the 1024 px master in app/Assets.
icon: $(ICON)
$(ICON): $(ICONSRC)
	rm -rf "$(BUILD)/AppIcon.iconset"
	mkdir -p "$(BUILD)/AppIcon.iconset"
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s "$(ICONSRC)" --out "$(BUILD)/AppIcon.iconset/icon_$${s}x$${s}.png" >/dev/null; \
	  sips -z $$((s*2)) $$((s*2)) "$(ICONSRC)" --out "$(BUILD)/AppIcon.iconset/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done
	iconutil -c icns "$(BUILD)/AppIcon.iconset" -o "$(ICON)"

bundle: app $(ICON)
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp "$(BIN)" "$(BUNDLE)/Contents/MacOS/$(APP)"
	cp "$(ICON)" "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	cp app/Info.plist "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign $(SIGN) --options runtime --timestamp --entitlements app/Plainchain.entitlements "$(BUNDLE)"

run: bundle
	open "$(BUNDLE)"

# Replace /Applications/Plainchain.app with a fresh build (quits a running copy first).
install: bundle
	-osascript -e 'tell application "$(APP)" to quit' 2>/dev/null
	rm -rf "/Applications/$(APP).app"
	cp -R "$(BUNDLE)" "/Applications/$(APP).app"
	touch "/Applications/$(APP).app"   # nudge Finder and the Dock to pick up the icon

# Notarize the bundle so copies run anywhere without a Gatekeeper override.
# One-time setup: xcrun notarytool store-credentials plainchain --apple-id ... --team-id 6RMZ7JM472
ZIP := $(BUILD)/$(APP).zip
notarize: bundle
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(BUNDLE)" "$(ZIP)"
	xcrun notarytool submit "$(ZIP)" --keychain-profile plainchain --wait
	xcrun stapler staple "$(BUNDLE)"
	spctl --assess --type execute --verbose=2 "$(BUNDLE)"

# A notarized, stapled zip ready to send: build/Plainchain.zip
dist: notarize
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(BUNDLE)" "$(ZIP)"
	@echo "ready: $(ZIP)"

# Headless engine check: default in -> chain -> default out for 2 s, then a session round trip.
# PC_IN / PC_OUT select devices by name substring; PLUGINS lists plugin names.
smoke: bundle
	"$(BUNDLE)/Contents/MacOS/$(APP)" --smoke $(PLUGINS)

clean:
	rm -rf app/.build "$(BUILD)"
