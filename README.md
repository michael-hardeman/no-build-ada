# no-build

[![Linux](https://github.com/michael-hardeman/no-build-ada/actions/workflows/ci.yml/badge.svg?branch=main&job=linux)](https://github.com/michael-hardeman/no-build-ada/actions/workflows/ci.yml)
[![macOS](https://github.com/michael-hardeman/no-build-ada/actions/workflows/ci.yml/badge.svg?branch=main&job=macos)](https://github.com/michael-hardeman/no-build-ada/actions/workflows/ci.yml)
[![Windows](https://github.com/michael-hardeman/no-build-ada/actions/workflows/ci.yml/badge.svg?branch=main&job=windows)](https://github.com/michael-hardeman/no-build-ada/actions/workflows/ci.yml)

An Ada port of [nob.h](https://github.com/tsoding/nob.h) — a build system
that lives entirely in your source tree with no Makefiles, no `.gpr` project
files, and no external tools beyond your Ada compiler.

I have taken steps to try and make this compiler independent. I rely only on
Ada Standard Library packages and implement platform specific stuff myself.
I also tried to make a generic compiler interface using the Ada_Compiler
type. I only ever use GNAT since it's free and open source but if you have
access to other Ada compilers I'd appreciate it if you tested my code and
gave me feedback/pull requests.

## Concept

Write your build logic as a normal Ada program (`build.adb`).  Bootstrap it
once with your Ada compiler, and from then on `./build` recompiles itself 
whenever `build.adb` changes before doing anything else 
(*Go Rebuild Urself* pattern).

```sh
gnatmake build.adb -o build   # one-time bootstrap (Linux, macOS, Windows-MinGW)
./build                       # use forever after
```

On macOS this is identical — `gnatmake` resolves `dlopen` / `dlsym` against
libSystem automatically.  On Windows you also need a small `windows_dl.adb`
shim (see [Windows support](#windows-support) below) and your `build.adb`
must `with` it before bootstrapping.

## Usage

Copy two files into your project root alongside `build.adb`:

| File            | Purpose                          |
|-----------------|----------------------------------|
| `no_build.ads`  | Package spec (API)               |
| `no_build.adb`  | Package body (implementation)    |

Then write a `build.adb` program. Bootstrap it by building it once with your
compiler of choice. On GNAT you `gnatmake build.adb -o build`. That's it.
From then on you just `./build` to build your program.

## Quick start

```ada
-- build.adb
with No_Build; use No_Build;

procedure Build is
   Obj : constant String := "obj";
begin
   Go_Rebuild_Urself (Binary_Path => "./build",
                      Source_Path => "build.adb",
                      Obj_Dir     => Obj);

   Compile_Program ("src/main.adb", Output => "bin/main", Obj_Dir => Obj);
end Build;
```

## Argument lists

`Argument_List` is a Controlled, vector-backed container of strings.  It owns
its strings: deep-copy on assignment, free on scope exit -- no manual
deallocation, no leak.

```ada
--  One-shot constructor (1..8 elements).
Cmd ("gnatmake", Args ("main.adb", "-O2"));

--  Concatenate with & ; mix strings and Argument_Lists freely.
Cmd ("gnatmake", Args ("main.adb") & "-O2" & Args ("-gnatwa", "-gnata"));

--  Grow dynamically with Append.
declare
   Flags : Argument_List;
begin
   for Path of Include_Dirs loop
      Flags.Append ("-I" & Path);
   end loop;
   Cmd ("gnatmake", Flags);
end;
```

## Windows support

In order to try and avoid linking errors or separate package we don't
directly link with OS libraries. `no_build.adb` imports the smallest
surface area we can that allows us to dynamically load OS libraries
at runtime: `dlopen` and `dlsym`. On Linux (glibc ≥ 2.34) and macOS these 
resolve against libc / libSystem automatically. If you are on Windows you 
will not have a standard C library that provides them. You must add a 
small shim to your project that exports these symbols on top 
of `LoadLibraryA` / `GetProcAddress`.

Copy `windows/windows_dl.ads` and `windows/windows_dl.adb` next to your `build.adb`:

Then `with` the shim from your `build.adb`:

```ada
with Windows_DL;   --  link-time only; brings exported dlopen/dlsym in
with No_Build; use No_Build;

procedure Build is
begin
   ...
end Build;
```

The `with` clause forces the shim's object file into the link, which is all
the linker needs to resolve `no_build.adb`'s references to `dlopen` and
`dlsym`.  If your compiler emits an "unused with" warning, silence it with
`pragma Warnings (Off, Windows_DL);` (GNAT) or the equivalent in your
toolchain.

### Windows + GNAT (MinGW) — two options

GNAT/MinGW on Windows ships a `libdl.a` wrapper around `LoadLibraryA` /
`GetProcAddress`, so you have a choice:

1. **Use the shim above.** (Reccomended) - Compiler-agnostic — 
   same workflow in all compilers
   same `build.adb` keeps working if you ever switch to another toolchain.
2. **Skip the shim and link MinGW's libdl wrapper.**  Pass `-largs -ldl`
   on the one-time bootstrap:

   ```
   gnatmake build.adb -largs -ldl -o build
   ```

   For self-rebuilds to keep the same link flags, pass them in `Extra`
   when calling `Go_Rebuild_Urself`:

   ```ada
   Go_Rebuild_Urself
     (Binary_Path => "./build",
      Source_Path => "build.adb",
      Obj_Dir     => Obj,
      Extra       => Args ("-largs", "-ldl"));
   ```

The shim is recommended if you care about toolchain portability; `-ldl` is
shorter if you intend to stay on GNAT and care about that sort of thing.

## API reference

see [no_build.ads](no_build.ads)

## Worked example

This repository keeps the library (`no_build.ads` / `no_build.adb`) at the
root and groups everything else under `examples/`:

```
examples/
├── build_all.adb     # master build script (compiles everything below)
├── *.adb             # example programs (file, foreach, lib_demo, ...)
├── lib/              # demo library (libgreet)
└── tools/            # standalone tool programs (cat, hex, rot13)
```

Bootstrap it with the wrapper script (`bootstrap.cmd` on Windows):

```
./bootstrap.sh
./examples/build_all
```

The script just runs `gnatmake`; the full command is:

```
gnatmake -D examples/obj -I. examples/build_all.adb -o examples/build_all
```

### Why the bootstrap is different here than in your own project

In a normal project (see [Quick start](#quick-start)) you keep `build.adb`
next to `no_build.ads`/`no_build.adb` at the repo root, and the bootstrap
is the short form shown there:

```
gnatmake build.adb -o build   # source and library both at .
./build
```

This repo deliberately keeps the root limited to the two files you would
actually copy into your own project, so the example build script lives
one level down at `examples/build_all.adb`.  That changes three things:

- **`-I.`** — gnatmake searches the source's own directory for `with`-ed
  units by default.  Since `build_all.adb` is in `examples/` but
  `no_build.adb` is at the root, we have to point gnatmake back up with
  `-I.`.  The same flag is passed to `Go_Rebuild_Urself` (via `Extra`) so
  the self-rebuild keeps working.
- **`-D examples/obj`** — keeps `.o` / `.ali` files out of the repo root.
  A normal project usually wants the same thing, but the *default*
  `gnatmake build.adb` drops them next to the source, which is fine when
  the source already lives at the root.
- **`./examples/build_all`** instead of `./build` — the output binary
  lives next to its source.

If you copy `no_build.ads`/`no_build.adb` into your own project, ignore
all of the above and follow [Quick start](#quick-start) — the one-line
bootstrap is the normal path.

`examples/build_all.adb` builds static and shared libraries from
`examples/lib/`, the standalone tools in `examples/tools/`, then compiles
and runs every other `.adb` in `examples/` (skipping itself):

```ada
with No_Build; use No_Build;

procedure Build_All is
   Obj      : constant String := "examples/obj";
   Tools    : constant String := "examples/tools";
   Examples : constant String := "examples";
   Lib      : constant String := "examples/lib";

   procedure Build_Tool (Tool : String) is
   begin
      Compile_Program (Tools / Tool, Output => Tools / No_Ext (Tool),
                       Obj_Dir => Obj);
   end Build_Tool;

   procedure Build_And_Run_Example (Example : String) is
      Bin : constant String := Examples / No_Ext (Example);
   begin
      if Example = "build_all.adb" then
         return;  --  Go_Rebuild_Urself handles this one
      end if;
      Compile_Program (Examples / Example, Output => Bin,
                       Obj_Dir => Obj,
                       Extra   => Args ("-I.", "-I" & Lib));
      Cmd (Bin);
   end Build_And_Run_Example;

begin
   Go_Rebuild_Urself (Binary_Path => "./examples/build_all",
                      Source_Path => "examples/build_all.adb",
                      Obj_Dir     => Obj,
                      Extra       => Args ("-I."));

   Info ("building static library...");
   Build_Static_Lib (Lib, Output => Lib / "libgreet.a", Obj_Dir => Obj);

   Info ("building shared library...");
   Build_Shared_Lib (Lib, Output => Lib / "libgreet.so",
                     Obj_Dir => Obj / "pic");

   Info ("building tools...");
   For_Each_File (Tools,    Build_Tool'Access,            Suffix => ".adb");

   Info ("building and running examples...");
   For_Each_File (Examples, Build_And_Run_Example'Access, Suffix => ".adb");

   Info ("Done.");
end Build_All;
```

## Tests

The library has a small test suite under `tests/` that exercises path
utilities, `Argument_List`, `Make_Dirs`, `Is_Newer`/`Needs_Rebuild`,
`Capture`, `Walk_Dir`, and `Read_File`/`Write_File`.  Each test is its own
program; `tests/build_tests.adb` is a `No_Build`-based runner that compiles
and executes every `test_*.adb` and accumulates pass/fail counts.

```sh
./bootstrap_tests.sh    # Linux/macOS -- one-time gnatmake
./bootstrap_tests.cmd   # Windows
./tests/build_tests     # build + run all tests
```

CI runs the same flow on Linux, macOS, and Windows -- see
`.github/workflows/ci.yml`.

## Requirements

- Any Ada 2012+ compiler (tested with GNAT 15).  The package has no
  `with GNAT.OS_Lib`, so other toolchains (ObjectAda, Janus, …) should
  build it given an `Ada_Compiler` descriptor.
- `ar` for static libraries
- `gcc` for shared libraries
- On Windows: the `windows_dl.adb` shim described above

## Inspiration

Inspired by [nob.h](https://github.com/tsoding/nob.h) by Tsoding.
