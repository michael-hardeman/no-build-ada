#!/bin/sh

mkdir -p examples/obj
gnatmake -D examples/obj -I. examples/build_all.adb -o examples/build_all
