APP_NAME := Harf
BUNDLE_ID := com.ali.dodoma
APP_BUNDLE := build/$(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
SIGN_IDENTITY := Dodoma Dev

FIXTURES := Tests/DodomaCoreTests/Fixtures/layout-tables.json
CORPUS := Tests/DodomaCoreTests/Fixtures/corpus.tsv
# SwiftPM resource bundle for the DodomaCore target: <package>_<target>.bundle
RESOURCE_BUNDLE := Harf_DodomaCore.bundle

.PHONY: dmg build bundle sign install run test fixtures logs ngrams eval clean

build:
	swift build -c release

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" $(CONTENTS)/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	@find Resources -mindepth 1 -maxdepth 1 ! -name Info.plist -exec cp -R {} $(CONTENTS)/Resources/ \;
	@# SPM emits DodomaCore's word lists and bigram tables as a separate bundle.
	@# CoreResources.swift searches Contents/Resources for it at runtime, so it
	@# has to be copied in or the app cannot score anything.
	@BIN="$$(swift build -c release --show-bin-path)"; \
	if [ ! -d "$$BIN/$(RESOURCE_BUNDLE)" ]; then \
		echo "error: $(RESOURCE_BUNDLE) not found in $$BIN"; exit 1; \
	fi; \
	cp -R "$$BIN/$(RESOURCE_BUNDLE)" $(CONTENTS)/Resources/
	@echo "Bundled $(APP_BUNDLE)"

sign: bundle
	@if security find-identity -v -p codesigning | grep -q "$(SIGN_IDENTITY)"; then \
		echo "Signing with identity '$(SIGN_IDENTITY)'"; \
		codesign --force --deep --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE); \
	else \
		echo "############################################################"; \
		echo "WARNING: code-signing identity '$(SIGN_IDENTITY)' not found."; \
		echo "Falling back to ad-hoc signing."; \
		echo "Ad-hoc signatures change on every rebuild, so macOS treats"; \
		echo "each build as a different app and DROPS the Accessibility"; \
		echo "and Input Monitoring grants. You will have to re-approve"; \
		echo "Harf after every build."; \
		echo "Fix this once by running: scripts/make-cert.sh"; \
		echo "############################################################"; \
		codesign --force --deep --sign - $(APP_BUNDLE); \
	fi
	codesign -dr - $(APP_BUNDLE)

install: build bundle sign
	pkill -x $(APP_NAME) || true
	rm -rf /Applications/$(APP_NAME).app
	ditto $(APP_BUNDLE) /Applications/$(APP_NAME).app
	open /Applications/$(APP_NAME).app

run: build bundle sign
	open $(APP_BUNDLE)

test:
	swift test

# Snapshots this machine's ABC and Arabic uchr tables so renderer tests stay
# deterministic regardless of which input sources are enabled where they run.
fixtures:
	swift run Dodoma --dump-layout-fixtures $(FIXTURES)

eval:
	swift run Dodoma --eval $(CORPUS)

# --debug --info: the decision and pipeline categories log at those levels, and
# `log stream` shows neither by default.
logs:
	log stream --debug --info --predicate 'subsystem == "$(BUNDLE_ID)"' --style compact

# Regenerates the committed language models. The only network access in the
# project, and it only happens on a dev machine when Tools/data/ is cold.
ngrams:
	uv run Tools/build-ngrams.py

clean:
	rm -rf .build build

dmg: build bundle sign ## Build a distributable disk image
	./scripts/make-dmg.sh
