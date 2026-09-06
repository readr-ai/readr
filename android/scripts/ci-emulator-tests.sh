#!/usr/bin/env bash
# Runs on a booted x86_64 emulator (CI): the kit's XCTest suite pushed as a
# native binary, then the app's instrumented tests. One script because the
# emulator-runner action executes each `script:` line in its own shell.
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:?}"
BUNDLE="$HOME/.config/swiftpm/swift-sdks/swift-${SWIFT_VERSION}-RELEASE_android.artifactbundle/swift-android"
LIBS="$BUNDLE/swift-resources/usr/lib/swift-x86_64/android"
TEST_BIN=".build/x86_64-unknown-linux-android28/debug/ReadrKitPackageTests.xctest"

test -f "$TEST_BIN"
adb shell 'rm -rf /data/local/tmp/readr; mkdir -p /data/local/tmp/readr/lib /data/local/tmp/readr/tmp'
adb push "$TEST_BIN" /data/local/tmp/readr/ >/dev/null
for f in "$LIBS"/*.so; do adb push "$f" /data/local/tmp/readr/lib/ >/dev/null; done
adb push "$BUNDLE/ndk-sysroot/usr/lib/x86_64-linux-android/libc++_shared.so" /data/local/tmp/readr/lib/ >/dev/null

# adb shell does not propagate the remote exit code, and XCTest prints a
# "with 0 failures" line per suite — gate on the echoed status and on the
# whole-run summary, and refuse any non-zero failure count anywhere.
adb shell 'cd /data/local/tmp/readr && TMPDIR=/data/local/tmp/readr/tmp HOME=/data/local/tmp/readr LD_LIBRARY_PATH=/data/local/tmp/readr/lib ./ReadrKitPackageTests.xctest; echo XCTEST_EXIT=$?' | tee kit-tests.log
grep -q '^XCTEST_EXIT=0' kit-tests.log
grep -q "Test Suite 'All tests' passed" kit-tests.log
! grep -qE 'with [1-9][0-9]* failures' kit-tests.log

cd android && ./gradlew :app:connectedDebugAndroidTest
