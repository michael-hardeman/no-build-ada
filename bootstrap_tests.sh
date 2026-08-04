#!/bin/sh
#
# One-time bootstrap of the test runner.  From then on run
# ./tests/build_tests -- it rebuilds itself whenever its source changes.

set -e

ada83 --ir no_build.adb -o no_build.ll
ada83 -I. tests/build_tests.adb no_build.ll -o tests/build_tests
