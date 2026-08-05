@ECHO OFF
REM One-time bootstrap of the examples build script.  From then on run
REM examples\build_all.exe -- it rebuilds itself when its source changes.
REM
REM Nothing here names a platform; one body of the library serves every
REM target.

ada83.exe --ir -I. no_build.adb -o no_build.ll || exit /b 1
ada83.exe -I. examples\build_all.adb no_build.ll -o examples\build_all.exe
