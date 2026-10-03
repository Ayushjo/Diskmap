#!/bin/bash
# Run the DiskMap test suite. Use this instead of bare `swift test`.
#
# Why this exists: Command Line Tools 26.6 (Swift 6.3.3) ships Swift Testing
# as Testing.framework under CommandLineTools/Library/Developer/Frameworks,
# but SwiftPM passes that directory with -I/-L rather than -F, so every test
# file fails with "no such module 'Testing'". The binary also needs rpaths
# for Testing.framework and lib_TestingInterop.dylib. Full Xcode is
# unaffected. The flags are only added when that CLT layout is present, so
# this script is harmless everywhere else.
#
# All arguments are passed through, e.g.:
#   scripts/test.sh
#   scripts/test.sh --filter ScanIdentityTests
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p 2>/dev/null || true)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

EXTRA=()
if [[ -d "$FW/Testing.framework" ]]; then
    EXTRA+=(-Xswiftc -F -Xswiftc "$FW" -Xlinker -rpath -Xlinker "$FW")
    [[ -d "$LIB" ]] && EXTRA+=(-Xlinker -rpath -Xlinker "$LIB")
fi

exec swift test ${EXTRA[@]+"${EXTRA[@]}"} "$@"
