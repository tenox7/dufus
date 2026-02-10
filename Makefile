BUILD     = build
APP       = $(BUILD)/Dufus.app
DMG       = $(BUILD)/Dufus.dmg
BIN_PATH  = $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

.PHONY: all app dmg icon binary sign clean

all: dmg

icon: $(BUILD)/AppIcon.icns

$(BUILD)/AppIcon.icns: scripts/gen_icon.swift
	@mkdir -p $(BUILD)
	swift scripts/gen_icon.swift $(BUILD)

binary:
	swift build -c release --arch arm64 --arch x86_64

app: icon binary
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/
	cp $(BUILD)/AppIcon.icns $(APP)/Contents/Resources/
	cp $(BIN_PATH)/Dufus $(APP)/Contents/MacOS/
	codesign --force --deep --sign - $(APP)

dmg: app
	@rm -rf $(BUILD)/dmg_staging $(DMG)
	@mkdir -p $(BUILD)/dmg_staging
	cp -R $(APP) $(BUILD)/dmg_staging/
	ln -s /Applications $(BUILD)/dmg_staging/Applications
	hdiutil create -volname Dufus -srcfolder $(BUILD)/dmg_staging -ov -format UDZO $(DMG)
	@rm -rf $(BUILD)/dmg_staging

clean:
	rm -rf $(BUILD)
	swift package clean
