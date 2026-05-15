.PHONY: setup generate build run clean release

setup:
	@which xcodegen > /dev/null 2>&1 || brew install xcodegen
	$(MAKE) generate
	@echo "✓ Run 'open ClawdBar.xcodeproj' to build in Xcode, or 'make build' for CLI."

generate:
	xcodegen generate

build: generate
	xcodebuild -project ClawdBar.xcodeproj \
		-scheme ClawdBar \
		-configuration Debug \
		-derivedDataPath .build \
		build | xcpretty || xcodebuild -project ClawdBar.xcodeproj \
		-scheme ClawdBar \
		-configuration Debug \
		-derivedDataPath .build \
		build

run: build
	open .build/Build/Products/Debug/ClawdBar.app

clean:
	rm -rf .build ClawdBar.xcodeproj

release: generate
	xcodebuild -project ClawdBar.xcodeproj \
		-scheme ClawdBar \
		-configuration Release \
		-archivePath .build/ClawdBar.xcarchive \
		archive \
		CODE_SIGN_IDENTITY="Developer ID Application"
	xcodebuild -exportArchive \
		-archivePath .build/ClawdBar.xcarchive \
		-exportPath .build/export \
		-exportOptionsPlist ExportOptions.plist
	@echo "✓ App exported to .build/export/ClawdBar.app"
	@echo "  Next: create DMG, tag release, update Homebrew cask"
