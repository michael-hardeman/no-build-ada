#!/bin/sh
#
# One-time bootstrap of the examples build script.  From then on run
# ./examples/build_all -- it rebuilds itself whenever its source changes.
#
# Nothing here names a platform.  One body of the library serves every
# target: which system calls exist is settled by the compiler, from
# System.TARGET_OS.

set -e

ada83 --ir -I. no_build.adb -o no_build.ll
ada83 -I. examples/build_all.adb no_build.ll -o examples/build_all
