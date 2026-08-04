@ECHO OFF
REM One-time bootstrap of the examples build script.  From then on run
REM examples\build_all.exe -- it rebuilds itself when its source changes.

ada83.exe --ir -I. windows\platform_support.adb -o platform_support.ll || exit /b 1
ada83.exe --ir -I. no_build.adb -o no_build.ll || exit /b 1
ada83.exe -I. examples\build_all.adb no_build.ll platform_support.ll -o examples\build_all.exe
