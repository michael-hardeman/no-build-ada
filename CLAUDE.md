# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`no-build` is an Ada port of [nob.h](https://github.com/tsoding/nob.h) — a single-package, zero-external-dependency build system. The user copies `no_build.ads` and `no_build.adb` into their project and writes a `build.adb` that uses the API.

## Build Commands

Bootstrap (first time only):
```bash
gnatmake build.adb -o build && ./build
```

Subsequent builds:
```bash
./build
```

There is no Makefile, test runner, or linter. The build script itself (`build.adb`) is the canonical example of the API in use.

## Architecture

Everything lives in a single Ada package `No_Build` (spec: `no_build.ads`, body: `no_build.adb`). There is no build framework — the library IS the build framework.

**Core subsystems in `no_build.adb`:**

- **Command execution**: `Cmd`/`Sh` (synchronous), `Cmd_Async`/`Wait`/`Wait_All` (async process management)
- **Ada compilation wrappers**: `Compile_Program` (compiler-agnostic, driven by an `Ada_Compiler` descriptor — swap with `Set_Compiler`), `Compile`, `Build_Static_Lib`, `Build_Shared_Lib`; `Gnatmake` is kept as a deprecated alias for `Compile_Program` over the bundled `Gnatmake_Compiler` descriptor.
- **Filesystem**: `Make_Dir(s)`, `Remove_Path`, `Copy_File`, `Copy_Dir`, `Read_File`, `Write_File`, `For_Each_File`, `Walk_Dir`
- **Path utilities**: `/` operator for joining, `No_Ext`, `Base_Name`, `Ends_With`
- **Dependency checking**: `Is_Newer`, `Needs_Rebuild`
- **Logging**: `Info`, `Warn`, `Erro`, `Panic` — customizable via `Log_Handler`
- **Self-rebuild (GRU)**: `Go_Rebuild_Urself` — recompiles `build.adb` when source changes, then re-executes the new binary
- **Platform detection**: `Platform` constant (Linux/MacOS/Windows) determined at elaboration time
- **Process spawn**: POSIX `fork`/`execv`/`waitpid` (loaded at elaboration via `dlopen`/`dlsym`); Windows users must supply a shim that exports `dlopen`/`dlsym` (see README).

**`no_build.ads`** is the authoritative API reference — read it before modifying behavior.

## Key Conventions

- `Build_Static_Lib` compiles with standard flags; `Build_Shared_Lib` adds `-fPIC` on Linux/macOS (skipped on Windows) and links with `gcc -shared` (Linux/Windows) or `gcc -dynamiclib` (macOS).
- `Walk_Dir` uses a callback returning a `Walk_Action` value (`Walk_Continue` / `Walk_Skip` / `Walk_Stop`) for early exit.
- Logging goes to stderr; `Panic` logs then raises `Build_Error`.
- The package has no `with GNAT.OS_Lib`; it should compile with any Ada 2012+ compiler (tested with GNAT 15). `ar` is required for static libraries; `gcc` for shared libraries.
