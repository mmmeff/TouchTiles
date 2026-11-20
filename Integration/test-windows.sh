#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

build="$(mktemp -d "${TMPDIR:-/tmp}/touchtiles-window-test.XXXXXXXX")"
trap 'rm -rf "$build"' EXIT
fixture="$build/WindowFixture.app/Contents"
mkdir -p "$fixture/MacOS"
cp Integration/FixtureInfo.plist "$fixture/Info.plist"
xcrun swiftc Integration/WindowFixture.swift -o "$fixture/MacOS/Fixture"
filter=${TOUCHTILES_TEST_FILTER:-${DRIFTTILE_TEST_FILTER:-LiveWindowTests}}
TOUCHTILES_WINDOW_FIXTURE="$fixture/MacOS/Fixture" swift test --filter "$filter" "$@"
