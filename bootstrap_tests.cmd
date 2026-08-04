@ECHO OFF
REM One-time bootstrap of the test runner.  From then on run
REM tests\build_tests.exe -- it rebuilds itself when its source changes.

ada83.exe --ir -I. windows\platform_support.adb -o platform_support.ll || exit /b 1
ada83.exe --ir -I. no_build.adb -o no_build.ll || exit /b 1
ada83.exe -I. tests\build_tests.adb no_build.ll platform_support.ll -o tests\build_tests.exe
