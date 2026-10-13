.PHONY: setup generate build run test clean release dmg

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

# Run the unit tests.
test: generate
	xcodebuild test -project ClawdBar.xcodeproj -scheme ClawdBar \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet

clean:
	rm -rf .build ClawdBar.xcodeproj

# Ship a release: bump version, commit, tag, push -> CI builds/notarizes/publishes.
#   make release VERSION=1.2.3
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z"; exit 1; }
	@scripts/cut-release.sh $(VERSION)

# Build a local notarized test DMG (does not publish).
dmg:
	@scripts/release.sh
