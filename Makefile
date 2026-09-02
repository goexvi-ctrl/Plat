# Plat -- a disk-usage treemap for macOS.

VERSION ?= $(shell cat Version)

.PHONY: all app test install release clean

all: app

# app: build Plat.app into build/. Ad-hoc signed unless CODESIGN_IDENTITY is set.
app:
	./make-app.sh

test:
	swift test

install:
	./make-app.sh --install

# release: build a signed macOS .dmg for upload to a GitHub release.
#
# Default builds are ad-hoc signed: runnable locally, but a download is
# quarantined and must be de-quarantined by hand. Pass a Developer ID to get a
# hardened-runtime, notarized, stapled image that opens with no user fiddling:
#
#   make release \
#     CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#     NOTARY_PROFILE=plat-notary
#
# NOTARY_PROFILE names a stored `xcrun notarytool store-credentials` profile.
RELEASE_ARCH      := $(shell uname -m)
RELEASE_DMG       := build/Plat-$(VERSION)-macos-$(RELEASE_ARCH).dmg
CODESIGN_IDENTITY ?= -
NOTARY_PROFILE    ?= plat-notary

release:
	CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" ./make-app.sh
	APP=build/Plat.app DMG=$(RELEASE_DMG) \
	VOLNAME="Plat $(VERSION)" IDENTITY="$(CODESIGN_IDENTITY)" \
	NOTARY_PROFILE="$(NOTARY_PROFILE)" ./scripts/macos-release.sh

clean:
	rm -rf .build build
