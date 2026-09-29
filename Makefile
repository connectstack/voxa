# Common tasks. `make help` lists them.

.PHONY: help project build run test lint format snapshots icon clean

help:            ## Show this help
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*##/\t/' | column -t -s "$$(printf '\t')"

project:         ## Regenerate Voxa.xcodeproj from project.yml (needs XcodeGen)
	xcodegen generate

build:           ## Debug build of Voxa.app (ad-hoc signed)
	scripts/build.sh

run:             ## Build, then launch Voxa.app
	scripts/build.sh --run

test:            ## Run the unit tests
	swift test

lint:            ## Run SwiftLint
	swiftlint lint --quiet

format:          ## Format sources with SwiftFormat
	swiftformat .

snapshots:       ## Render the HUD in every state (light and dark) to build/snapshots
	swift run voxa-dev hud-snapshots build/snapshots

icon:            ## Regenerate the app icon
	swift scripts/make-icon.swift

clean:           ## Remove build output
	rm -rf .build build
