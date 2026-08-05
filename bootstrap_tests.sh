#!/bin/sh
#
# One-time bootstrap of the test runner.  From then on run
# ./tests/build_tests -- it rebuilds itself whenever its source changes.
#
# Platform_Support has one body per system; pick this machine's.

set -e

case "$(uname -s)" in
    Darwin)
        case "$(uname -m)" in
            arm64|aarch64) PLATFORM=macos-arm64   ;;
            *)             PLATFORM=macos-x86_64  ;;
        esac
        ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
    *)                    PLATFORM=linux   ;;
esac

ada83 --ir -I. "$PLATFORM/platform_support.adb" -o platform_support.ll
ada83 --ir -I. no_build.adb -o no_build.ll
ada83 -I. tests/build_tests.adb no_build.ll platform_support.ll \
      -o tests/build_tests
