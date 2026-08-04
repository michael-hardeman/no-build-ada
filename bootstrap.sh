#!/bin/sh
#
# One-time bootstrap of the examples build script.  From then on run
# ./examples/build_all -- it rebuilds itself whenever its source changes.

set -e

ada83 --ir no_build.adb -o no_build.ll
ada83 -I. examples/build_all.adb no_build.ll -o examples/build_all
