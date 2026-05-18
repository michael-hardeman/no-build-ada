#!/bin/sh

mkdir -p tests/obj
gnatmake -D tests/obj -I. -Itests tests/build_tests.adb -o tests/build_tests
