#!/bin/sh
#
# One-time bootstrap of the test runner.  From then on run
# ./tests/build_tests -- it rebuilds itself whenever its source changes.
#
# Platform_Support has one body per family; pick the one for this system.

set -e

case "$(uname -s)" in
    Darwin|Linux) PLATFORM=posix   ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
    *)            PLATFORM=posix   ;;
esac

ada83 --ir -I. "$PLATFORM/platform_support.adb" -o platform_support.ll
ada83 --ir -I. no_build.adb -o no_build.ll
ada83 -I. tests/build_tests.adb no_build.ll platform_support.ll \
      -o tests/build_tests
