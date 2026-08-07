#!/usr/bin/env bats
# Shared helpers for SwiftWebSetup bats tests.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source_script() {
	local name="$1"
	local script="$REPO_ROOT/$name"
	[[ -f "$script" ]] || {
		echo "missing: $script" >&2
		return 1
	}
	# shellcheck disable=SC1090
	source "$script"
}

fail() {
	echo "FAILED: $*" >&2
	return 1
}

cd "$REPO_ROOT" || exit 1
