ifneq (,$(wildcard .env))
include .env
export
endif

XCODEPROJ := Demo/PDFDemoApp/PDFDemoApp.xcodeproj
SCHEME := PDFDemoApp
DERIVED_DATA ?= $(HOME)/Developer/tmp/PDFDemoDerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/PDFDemoApp.app

.PHONY: build open clean run spm-build spm-test

run: build open

build:
	xcodebuild \
		-scheme $(SCHEME) \
		-project $(XCODEPROJ) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		build

open:
	@test -d "$(APP)" || { \
		echo "App not found. Run 'make build' first."; \
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

clean:
	rm -rf "$(DERIVED_DATA)"

spm-build:
	swift build

spm-test:
	swift test
