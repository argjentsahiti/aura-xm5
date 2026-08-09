APP       = Aura
BIN       = SonyXM5
BUILD     = .build/release
# Staged inside .build so the repo never holds a second visible copy of the app.
BUNDLE    = .build/$(APP).app
INSTALLED = /Applications/$(APP).app

VERSION  = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP      = dist/$(APP)-$(VERSION).zip

.PHONY: all build icon app install run uninstall dist sign notarize release clean

all: install

build:
	swift build -c release

icon: Resources/$(APP).icns

Resources/$(APP).icns: Tools/makeicon.swift
	swiftc -O -o /tmp/aura-makeicon Tools/makeicon.swift -framework AppKit -framework Foundation
	/tmp/aura-makeicon Resources
	iconutil -c icns Resources/$(APP).iconset -o Resources/$(APP).icns

app: build icon
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(BIN) $(BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(BUNDLE)/Contents/
	cp Resources/$(APP).icns $(BUNDLE)/Contents/Resources/
	codesign --force --sign - $(BUNDLE)

# Replaces any existing install rather than leaving a second copy behind.
install: app
	-@pkill -f "$(APP).app/Contents/MacOS/$(BIN)" 2>/dev/null || true
	@sleep 0.3
	rm -rf $(INSTALLED)
	cp -R $(BUNDLE) /Applications/
	@echo "Installed $(INSTALLED)"

run: install
	open $(INSTALLED)

uninstall:
	-@pkill -f "$(APP).app/Contents/MacOS/$(BIN)" 2>/dev/null || true
	rm -rf $(INSTALLED)
	rm -rf $(APP).app
	@echo "Removed $(INSTALLED)"

# --- Signing & notarization -------------------------------------------------
# Optional. Without a Developer ID the app is ad-hoc signed, which works fine
# locally but makes Gatekeeper block it on anyone else's Mac unless the
# quarantine flag is cleared (the Homebrew cask does that automatically).
#
# With a Developer ID Application certificate in the keychain, `make release`
# produces a signed, notarized, stapled build that opens on double-click
# anywhere, with no workarounds.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate and install it
#        Keychain Access -> Certificate Assistant -> Request a Certificate…
#        then developer.apple.com -> Certificates -> + -> Developer ID Application
#   2. Store notarization credentials (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials aura-notary \
#          --apple-id "you@example.com" --team-id "TEAMID" --password "abcd-efgh-ijkl-mnop"
IDENTITY = $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
PROFILE  = aura-notary

sign: app
ifeq ($(strip $(IDENTITY)),)
	@echo "No Developer ID Application certificate found — leaving the ad-hoc signature in place."
	@echo "See the setup notes in this Makefile to enable signed builds."
else
	@echo "Signing as: $(IDENTITY)"
	codesign --force --deep --options runtime --timestamp --sign "$(IDENTITY)" $(BUNDLE)
	codesign --verify --strict --verbose=2 $(BUNDLE)
endif

notarize: sign
ifeq ($(strip $(IDENTITY)),)
	@echo "Skipping notarization — no Developer ID certificate."
else
	rm -rf dist && mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) dist/notarize.zip
	xcrun notarytool submit dist/notarize.zip --keychain-profile $(PROFILE) --wait
	xcrun stapler staple $(BUNDLE)
	rm -f dist/notarize.zip
	@echo "Notarized and stapled."
endif

# Signed + notarized release artifact. Falls back to an ad-hoc zip if no cert.
release: notarize
	mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) $(ZIP)
	@shasum -a 256 $(ZIP) | tee dist/SHA256.txt
	@spctl -a -vv $(BUNDLE) 2>&1 | head -2 || true
	@echo "Built $(ZIP)"

# Zip for release downloads. ditto preserves the bundle's signature and resource
# forks — plain `zip` corrupts a signed .app.
dist: app
	rm -rf dist && mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) $(ZIP)
	@shasum -a 256 $(ZIP) | tee dist/SHA256.txt
	@echo "Built $(ZIP)"

clean:
	rm -rf .build dist $(APP).app
