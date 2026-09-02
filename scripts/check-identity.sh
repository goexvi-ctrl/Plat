#!/bin/sh
# Verify a codesign identity is present and its private key reachable, before
# any work is done.  "-" (ad-hoc) always passes.
#
# Catching this up front turns a bare "errSecInternalComponent" from codesign,
# several minutes into a release build, into a message that says what to do.
set -eu

identity="${1:?usage: check-identity.sh <identity>}"
[ "$identity" = "-" ] && exit 0

available=$(security find-identity -v -p codesigning 2>/dev/null || true)
# "0 valid identities found" is not a list; treat it as nothing visible.
case "$available" in
*"0 valid identities found"*) available="" ;;
esac

if ! printf '%s' "$available" | grep -qF "$identity"; then
	echo "codesign identity not found: $identity" >&2
	echo >&2
	if [ -z "$available" ]; then
		echo "  No codesigning identities are visible to this shell at all." >&2
		echo "  That usually means the login keychain is locked or unreachable;" >&2
		echo "  see the notes below." >&2
	else
		echo "Identities available here:" >&2
		printf '%s\n' "$available" | sed 's/^/  /' >&2
		echo >&2
		echo "The name must match exactly, including the team ID in parentheses." >&2
	fi
	exit 1
fi
