@ECHO OFF

if not exist tests\obj mkdir tests\obj
gnatmake.exe -D tests\obj -I. -Iwindows -Itests tests\build_tests.adb -o tests\build_tests.exe
