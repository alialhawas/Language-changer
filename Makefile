APP_NAME := Dodoma
BUNDLE_ID := com.ali.dodoma
APP_BUNDLE := build/$(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
SIGN_IDENTITY := Dodoma Dev

.PHONY: build bundle sign install run test logs ngrams clean

build:
	swift build -c release

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" $(CONTENTS)/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	@find Resources -mindepth 1 -maxdepth 1 ! -name Info.plist -exec cp -R {} $(CONTENTS)/Resources/ \;
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
		echo "Dodoma after every build."; \
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

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --style compact

ngrams:
	@echo "see Tools/build-ngrams.py (Task 4)"

clean:
	rm -rf .build build
