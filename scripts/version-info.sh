#!/bin/sh
# Emit build metadata for embedding in the app's Info.plist.
#
# The release version comes from the Version file; the rest is derived from git,
# so a build always says exactly which commit it came from and whether the tree
# had local edits at the time.  Output is shell-eval-able:
#
#   eval "$(scripts/version-info.sh)"
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

version=$(cat Version)
commitDate=$(git log -1 --format=%cs 2>/dev/null || echo unknown)
hash=$(git rev-parse --short HEAD 2>/dev/null || echo "")
state=""
buildTime=""

# Tracked edits only; untracked files do not mark the build modified.
# diff-index exits 1 when dirty, 0 when clean, 128+ on error (treat as clean).
rc=0
if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
	git diff-index --quiet HEAD -- 2>/dev/null || rc=$?
fi
if [ "$rc" -eq 1 ]; then
	state=modified
	buildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

printf 'PLAT_VERSION=%s\n'     "$version"
printf 'PLAT_COMMIT_DATE=%s\n' "$commitDate"
printf 'PLAT_COMMIT_HASH=%s\n' "$hash"
printf 'PLAT_TREE_STATE=%s\n'  "$state"
printf 'PLAT_BUILD_TIME=%s\n'  "$buildTime"
