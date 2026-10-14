# Plainchain: SwiftUI app bundled into build/Plainchain.app
APP     := Plainchain
BUILD   := build
BUNDLE  := $(BUILD)/$(APP).app
BIN     := app/.build/release/$(APP)
# A real signing identity keeps the microphone permission across rebuilds; ad-hoc ("-") does not.
# Hardened runtime, with entitlements that let third-party plugins load in-process.
SIGN    := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1)
SIGN    := $(if $(SIGN),$(SIGN),-)

.PHONY: all app bundle run install smoke clean

all: bundle

app:
	swift build -c release --package-path app

bundle: app
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS"
	cp "$(BIN)" "$(BUNDLE)/Contents/MacOS/$(APP)"
	cp app/Info.plist "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign $(SIGN) --options runtime --timestamp --entitlements app/Plainchain.entitlements "$(BUNDLE)"

run: bundle
	open "$(BUNDLE)"

# Replace /Applications/Plainchain.app with a fresh build (quits a running copy first).
install: bundle
	-osascript -e 'tell application "$(APP)" to quit' 2>/dev/null
	rm -rf "/Applications/$(APP).app"
	cp -R "$(BUNDLE)" "/Applications/$(APP).app"

# Headless engine check: default in -> chain -> default out for 2 s, then a session round trip.
# PC_IN / PC_OUT select devices by name substring; PLUGINS lists plugin names.
smoke: bundle
	"$(BUNDLE)/Contents/MacOS/$(APP)" --smoke $(PLUGINS)

clean:
	rm -rf app/.build "$(BUILD)"
