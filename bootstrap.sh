#!/bin/sh
#
# One-time bootstrap of the examples build script.  From then on run
# ./examples/build_all -- it rebuilds itself whenever its source changes.
#
# Platform_Support has one body per system; pick this machine's.  Nothing
# after this asks again: the built program reports the directory back
# through No_Build.Platform_Dir.

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
ada83 -I. examples/build_all.adb no_build.ll platform_support.ll \
      -o examples/build_all
