CONFIG ?= debug

.PHONY: build test check spike bundle run install dev-cert format clean

## Compile every target (works with the Command Line Tools alone).
build:
	swift build -c $(CONFIG)

## Run the unit tests (needs Xcode for the Swift Testing module).
test:
	swift test

## Verify the pure modules without Xcode: builds and runs the check runner.
check:
	swift run -c $(CONFIG) cutscene-check

## Run a spike; the first argument picks it: make spike ARGS="writer".
spike:
	swift run -c $(CONFIG) cutscene-spike $(ARGS)

## Build and assemble a signed dist/Cutscene.app.
bundle:
	scripts/bundle.sh $(CONFIG)

## Build, bundle and launch the app. Quits a running instance first; otherwise
## `open` would just bring the old build to the front.
run: bundle
	@pkill -x Cutscene 2>/dev/null; for i in $$(seq 1 30); do pgrep -x Cutscene >/dev/null || break; sleep 0.1; done; true
	open dist/Cutscene.app

## Build, sign and copy the app into /Applications, then launch it from there.
install: bundle
	@pkill -x Cutscene 2>/dev/null; for i in $$(seq 1 30); do pgrep -x Cutscene >/dev/null || break; sleep 0.1; done; true
	rm -rf /Applications/Cutscene.app && cp -R dist/Cutscene.app /Applications/Cutscene.app
	open /Applications/Cutscene.app

## Create a local signing identity once, so permission grants survive rebuilds.
dev-cert:
	bash scripts/dev-cert.sh

## Format sources with swift-format using .swift-format.
format:
	swift format --in-place --recursive Sources Tests Package.swift

clean:
	rm -rf .build dist
