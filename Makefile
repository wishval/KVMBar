APP      = KVMBar
DIST     = dist/$(APP).app
BIN_PATH = $(shell swift build -c release --show-bin-path)

.PHONY: build install run clean

build:
	swift build -c release
	@rm -rf dist
	@mkdir -p $(DIST)/Contents/MacOS $(DIST)/Contents/Resources
	cp "$(BIN_PATH)/$(APP)" $(DIST)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(DIST)/Contents/Info.plist
	cp Resources/AppIcon.icns $(DIST)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(DIST)
	@echo "==> $(DIST)"

install: build
	@rm -rf /Applications/$(APP).app
	cp -R $(DIST) /Applications/
	@echo "==> /Applications/$(APP).app  (enable Launch at Login from the menu)"
	@echo "    CLI: /Applications/$(APP).app/Contents/MacOS/$(APP) --status"

run: build
	open $(DIST)

clean:
	swift package clean
	rm -rf dist
