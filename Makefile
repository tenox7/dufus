-include .env

BUILD     = build
APP       = $(BUILD)/Dufus.app
DMG       = $(BUILD)/Dufus.dmg
STAGING   = $(BUILD)/dmg_staging
BIN_PATH  = $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
# The app version is the git tag. A release needs all changes committed and the tag on HEAD:
# git tag 1.2.3, then make release. Other builds use the last tag, or make VERSION=1.2.3.
VERSION  ?= $(shell git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)

.PHONY: all app dmg icon binary release clean

all: dmg

icon: $(BUILD)/AppIcon.icns

$(BUILD)/AppIcon.icns: scripts/gen_icon.swift
	@mkdir -p $(BUILD)
	swift scripts/gen_icon.swift $(BUILD)

binary:
	swift build -c release --arch arm64 --arch x86_64

# $(1) = codesign options. The helper is signed first, with its own identifier.
define bundle
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(VERSION)" $(APP)/Contents/Info.plist
	cp $(BUILD)/AppIcon.icns $(APP)/Contents/Resources/
	cp $(BIN_PATH)/Dufus $(BIN_PATH)/DufusHelper $(APP)/Contents/MacOS/
	codesign --force $(1) --identifier com.github.tenox7.dufus.helper $(APP)/Contents/MacOS/DufusHelper
	codesign --force $(1) $(APP)
endef

app: icon binary
	$(call bundle,--sign -)

define build_dmg
	@rm -rf $(STAGING) $(1)
	@mkdir -p $(STAGING)
	cp -R $(APP) $(STAGING)/
	ln -s /Applications $(STAGING)/Applications
	hdiutil create -volname Dufus -srcfolder $(STAGING) -ov -format UDZO $(1)
	@rm -rf $(STAGING)
endef

dmg: app
	$(call build_dmg,$(DMG))

release: icon binary
	@git diff --quiet HEAD -- && git describe --tags --exact-match >/dev/null 2>&1 || { echo "Commit all changes, then git tag X.Y.Z: the app version comes from the tag on HEAD."; exit 1; }
	@test -n "$(DEV_ID)" || { echo "DEV_ID not set — copy .env.example to .env and fill in"; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "NOTARY_PROFILE not set — copy .env.example to .env and fill in"; exit 1; }
	$(call bundle,--options runtime --timestamp --sign "$(DEV_ID)")
	$(call build_dmg,$(DMG))
	codesign --force --timestamp --sign "$(DEV_ID)" $(DMG)
	@# hdiutil sometimes leaves a diskimages-helper with a lock on the DMG; notarytool then hangs forever
	@for p in $$(lsof -t $(DMG) 2>/dev/null); do \
		ps -o comm= -p $$p | grep -q diskimages-helper && { echo "killing stale diskimages-helper $$p"; kill -9 $$p; }; \
	done; true
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	@echo "Signed + notarized: $(DMG), version $(VERSION)"

clean:
	rm -rf $(BUILD)
	swift package clean
