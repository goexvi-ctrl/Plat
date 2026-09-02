# Plat -- a disk-usage treemap for macOS.

VERSION ?= $(shell cat Version)

.PHONY: all app test install release tag push-tag clean

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

# tag: create the annotated git tag v<Version> for the current commit. Fails if
# the tag already exists (bump the Version file first), and refuses a dirty
# tree: a build from uncommitted edits stamps itself "modified" and names a
# commit that does not describe it, which is exactly what a release must not do.
tag:
	@v="v$(VERSION)"; \
	if ! git diff-index --quiet HEAD -- 2>/dev/null; then \
		echo "working tree has uncommitted changes; commit them before tagging" >&2; \
		git status --short >&2; exit 1; \
	fi; \
	if git rev-parse -q --verify "refs/tags/$$v" >/dev/null; then \
		echo "tag $$v already exists; bump the Version file first" >&2; exit 1; \
	fi; \
	git tag -a "$$v" -m "Plat $(VERSION)" && echo "tagged $$v at $$(git rev-parse --short HEAD)"

# push-tag: push the v<Version> tag to origin (a plain `git push` does not).
# Fails if the tag does not exist locally yet (run `make tag` first).
push-tag:
	@v="v$(VERSION)"; \
	if ! git rev-parse -q --verify "refs/tags/$$v" >/dev/null; then \
		echo "tag $$v does not exist; run 'make tag' first" >&2; exit 1; \
	fi; \
	git push origin "$$v" && echo "pushed $$v"

clean:
	rm -rf .build build
