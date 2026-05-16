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
- **Ada compilation wrappers**: `Gnatmake`, `Compile`, `Build_Static_Lib`, `Build_Shared_Lib`
- **Filesystem**: `Make_Dir(s)`, `Remove_Path`, `Copy_File`, `Copy_Dir`, `Read_File`, `Write_File`, `For_Each_File`, `Walk_Dir`
- **Path utilities**: `/` operator for joining, `No_Ext`, `Base_Name`, `Ends_With`
- **Dependency checking**: `Is_Newer`, `Needs_Rebuild`
- **Logging**: `Info`, `Warn`, `Erro`, `Panic` — customizable via `Log_Handler`
- **Self-rebuild (GRU)**: `Go_Rebuild_Urself` — recompiles `build.adb` when source changes, then re-executes the new binary
- **Platform detection**: `Platform` constant (Linux/Windows) determined at elaboration time

**`no_build.ads`** is the authoritative API reference — read it before modifying behavior.

## Key Conventions

- `Build_Static_Lib` compiles with standard flags; `Build_Shared_Lib` compiles with `-fPIC` (Linux only)
- `Walk_Dir` uses a callback with a `Continue` out-parameter for early exit
- Logging goes to stderr; `Panic` logs then raises `Program_Error`
- Requirements: GNAT (tested with GNAT 15), `ar`, `gcc`
