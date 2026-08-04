# no-build (Ada 83)

An Ada port of [nob.h](https://github.com/tsoding/nob.h) — a build system
that lives entirely in your source tree with no Makefiles, no `.gpr` project
files, and no external tools beyond your Ada compiler.

This branch targets [Ada83](https://github.com/AdaDoom3/Ada83), a single-file
Ada 83 compiler with an LLVM back end. It is MIL-STD-1815A only: no
`Ada.Strings.Unbounded`, no `Ada.Containers`, no `Ada.Directories`, no
access-to-subprogram types, no controlled types. Everything the build system
needs from the operating system is bound directly with `pragma Import`,
behind one package with a body per platform.

## Concept

Write your build logic as a normal Ada program (`build.ada`). Bootstrap it
once, and from then on `./build` recompiles itself whenever `build.ada`
changes, before doing anything else (*Go Rebuild Urself* pattern).

```sh
ada83 --ir -I. posix/platform_support.adb -o platform_support.ll  # one-time
ada83 --ir -I. no_build.adb -o no_build.ll
ada83 -I. build.ada no_build.ll platform_support.ll -o build
./build                                                          # forever after
```

## Usage

Copy these into your project root alongside your build program:

| File | Purpose |
|---|---|
| `no_build.ads` | Package spec (API) |
| `no_build.adb` | Package body (implementation) |
| `platform_support.ads` | The operating system, as No_Build needs it |
| `posix/` or `windows/` | One body for that spec; see [Platforms](#platforms) |

## Quick start

```ada
--  build.ada
with No_Build;

procedure Build is
   use No_Build;
begin
   Go_Rebuild_Urself ("./build", "build.ada");
   Compile_Program ("src/main.ada", "bin/main");
end Build;
```

## Compiling

The compiler is `ada83`, taken from PATH. It builds an executable from one
Ada source plus any number of `.ll` modules compiled earlier, and has no
object-file or archive stage — so a "library" here is an `.ll` module that
the programs needing it link alongside their own source.

```ada
Compile_Module ("lib/greet.adb", "lib/greet.ll");
Compile_Program ("app.ada", "app", Args ("lib/greet.ll"), Args ("-I lib"));
```

## Argument lists

`Argument_List` is a growable list of strings. Ada 83 has no controlled
types, so assignment shares storage rather than deep-copying: use `Copy`
for an independent list and `Clear` to release one. Build scripts are
short-lived processes, so leaving a list unfreed is harmless.

```ada
--  One-shot constructor (1..8 elements).
Cmd ("ada83", Args ("main.ada", "-O2"));

--  Concatenate with & ; mix strings and Argument_Lists freely.
Cmd ("ada83", Args ("main.ada") & "-O2" & Args ("-w"));

--  Grow dynamically with Append.
declare
   Flags : Argument_List;
begin
   Append (Flags, "-I" & Include_Dir);
   Cmd ("ada83", Flags);
   Clear (Flags);
end;
```

## Directory iteration

Ada 83 has no access-to-subprogram types, so the two callback APIs are
generics. Instantiate with the subprogram to run, then call the instance:

```ada
procedure Show (File_Name : String) is
begin
   Info (File_Name);
end Show;

procedure Show_All is new For_Each_File (Show);

...
Show_All ("src", ".adb");
```

`Walk_Dir` is the same shape, taking a function that returns a
`Walk_Action` (`Walk_Continue`, `Walk_Skip`, `Walk_Stop`).

## Differences from the Ada 95 edition

| Ada 95 edition | here |
|---|---|
| `For_Each_File`/`Walk_Dir` take access-to-subprogram | generics |
| `Argument_List` is controlled | plain private type, with `Copy` and `Clear` |
| `Build_Error` carries a message | Ada 83 exceptions carry none; every raiser logs through `Erro` first |
| `Set_Log_Handler` | gone; `Set_Log_Level` remains |
| `Ada_Compiler` descriptor, `Build_Static_Lib`, `Build_Shared_Lib` | gone; ada83 is the only compiler and has no archive stage |
| `Platform` is a constant | a function |

## API reference

See [no_build.ads](no_build.ads).

## Worked example

This repository keeps the library (`no_build.ads` / `no_build.adb`) at the
root and groups everything else under `examples/`:

```
examples/
├── build_all.adb     # master build script (compiles everything below)
├── *.adb             # example programs (file, foreach, lib_demo, ...)
├── lib/              # demo library module (greet)
└── tools/            # standalone tool programs (cat, hex, rot13)
```

Bootstrap it once, then run it:

```sh
sh bootstrap.sh          # or bootstrap.cmd on Windows
./examples/build_all
```

## Tests

`tests/` holds one program per phase of the port, each self-reporting
`PASSED` or one `FAILED` line per broken check:

| Program | Covers |
|---|---|
| `test_phase1` | `Argument_List`, path utilities, `Str`, logging, the platform probe |
| `test_phase2` | processes, redirection, filesystem, cwd, `Is_Newer`/`Needs_Rebuild` |
| `test_phase3` | `For_Each_File`, `Walk_Dir`, `Copy_Dir`, `Remove_Path` |
| `test_phase4` | `Compile_Module`, `Compile_Program`, `Go_Rebuild_Urself` |

`tests/build_tests.adb` is the runner, itself a No_Build program:

```sh
sh bootstrap_tests.sh    # one-time
./tests/build_tests      # build + run every test
```

## Requirements

- [Ada83](https://github.com/AdaDoom3/Ada83) on PATH as `ada83`, including
  its `Command_Line` vendor package, which `Go_Rebuild_Urself` uses to
  forward the original argv.
- A POSIX C library on Linux and macOS, or Win32 on Windows. Which one
  is reached is decided by the `Platform_Support` body the bootstrap
  compiles; see below.

## Platforms

Every system call goes through `Platform_Support`, whose spec is one file
and whose body is one per family:

| Body | Covers |
|---|---|
| `posix/platform_support.adb` | Linux and macOS |
| `windows/platform_support.adb` | Windows |

Nothing above that package names a syscall, a struct offset or an
errno-style constant, so porting to another system means writing one more
body and changing nothing else. The bootstrap scripts pick a body from
`uname`; point them elsewhere to cross-compile.

Being POSIX is not enough to share a body blindly: Linux and macOS
disagree about the layout of `struct stat` and `struct dirent`, about the
values of `O_CREAT` and `O_TRUNC`, and about the `sysconf` selector for
the processor count. The POSIX body answers each of those from `Host`, in
one place each.

**Tested on Linux only.** The macOS constants and offsets are taken from
the documented ABIs, and the Windows body is written against the Win32
ABI and has never been run. Both should be treated as unverified until
they have been.

One known gap: on x86_64 macOS the C library exports `stat` as
`stat$INODE64`, and the POSIX body imports the plain name, which is
correct on arm64 macOS and on Linux.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). The library version is exposed as
`No_Build.Version` in `no_build.ads`, currently `0.1.0-ada83`.

## Inspiration

Inspired by [nob.h](https://github.com/tsoding/nob.h) by Tsoding.
