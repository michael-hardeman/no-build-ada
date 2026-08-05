#!/bin/sh
#
# One-time bootstrap of the test runner.  From then on run
# ./tests/build_tests -- it rebuilds itself whenever its source changes.
#
# Nothing here names a platform.  One body of the library serves every
# target: which system calls exist is settled by the compiler, from
# System.TARGET_OS.

set -e

ada83 --ir -I. no_build.adb -o no_build.ll
ada83 -I. tests/build_tests.adb no_build.ll -o tests/build_tests
