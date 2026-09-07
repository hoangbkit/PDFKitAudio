ifneq (,$(wildcard .env))
include .env
export
endif

EXAMPLE_DIR := Examples/Demo
XCODEPROJ := $(EXAMPLE_DIR)/PDFKitAudioDemo.xcodeproj
SCHEME := PDFKitAudioDemo
DERIVED_DATA ?= $(HOME)/Developer/tmp/PDFKitAudioDemoDerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/PDFKitAudioDemo.app

.PHONY: run build open clean example-generate example-build example-build-ci example-open example-run example-clean spm-build spm-test

run: example-run
build: example-build
open: example-open
clean: example-clean

example-generate:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "XcodeGen is required. Install it with: brew install xcodegen"; \
		exit 1; \
	}
	xcodegen generate --spec "$(EXAMPLE_DIR)/project.yml"

example-build: example-generate
	xcodebuild \
		-scheme $(SCHEME) \
		-project $(XCODEPROJ) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		build

example-build-ci: example-generate
	xcodebuild \
		-scheme $(SCHEME) \
		-project $(XCODEPROJ) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO \
		build
	@test -f "$(APP)/Contents/Resources/digital-text.pdf"
	@test -f "$(APP)/Contents/Resources/outline-chapters.pdf"
	@test -f "$(APP)/Contents/Resources/blank-page.pdf"

example-open: example-generate
	open "$(XCODEPROJ)"

example-run: example-build
	@test -d "$(APP)" || { \
		echo "App not found. Run 'make example-build' first."; \
		exit 1; \
	}
	@if pgrep -x "$(SCHEME)" >/dev/null; then \
		pkill -x "$(SCHEME)"; \
		attempt=0; \
		while pgrep -x "$(SCHEME)" >/dev/null && [ $$attempt -lt 50 ]; do \
			sleep 0.1; \
			attempt=$$((attempt + 1)); \
		done; \
	fi
	open -n "$(APP)"

example-clean:
	rm -rf "$(DERIVED_DATA)" "$(XCODEPROJ)"

spm-build:
	swift build

spm-test:
	swift test
