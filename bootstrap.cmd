@ECHO OFF

if not exist examples\obj mkdir examples\obj
gnatmake.exe -D examples\obj -I. -Iwindows examples\build_all.adb -o examples\build_all.exe
