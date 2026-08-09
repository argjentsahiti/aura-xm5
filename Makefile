APP       = Aura
BIN       = SonyXM5
BUILD     = .build/release
# Staged inside .build so the repo never holds a second visible copy of the app.
BUNDLE    = .build/$(APP).app
INSTALLED = /Applications/$(APP).app

VERSION  = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP      = dist/$(APP)-$(VERSION).zip

.PHONY: all build icon app install run uninstall dist clean

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

# Zip for release downloads. ditto preserves the bundle's signature and resource
# forks — plain `zip` corrupts a signed .app.
dist: app
	rm -rf dist && mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) $(ZIP)
	@shasum -a 256 $(ZIP) | tee dist/SHA256.txt
	@echo "Built $(ZIP)"

clean:
	rm -rf .build dist $(APP).app
