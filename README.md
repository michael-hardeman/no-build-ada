# no-build

An Ada port of [nob.h](https://github.com/tsoding/nob.h) — a build system
that lives entirely in your source tree with no Makefiles, no `.gpr` project
files, and no external tools beyond `gnatmake`.

## Concept

Write your build logic as a normal Ada program (`build.adb`).  Bootstrap it
once with `gnatmake`, and from then on `./build` recompiles itself whenever
`build.adb` changes before doing anything else (*Go Rebuild Urself* pattern).

```
gnatmake build.adb -o build   # one-time bootstrap (Linux, macOS, Windows-MinGW)
./build                        # use forever after
```

On macOS this is identical — `gnatmake` resolves `dlopen` / `dlsym` against
libSystem automatically.  On Windows you also need a small `windows_dl.adb`
shim (see [Windows support](#windows-support) below) and your `build.adb`
must `with` it before bootstrapping.

## Installation

Copy two files into your project root alongside `build.adb`:

| File            | Purpose                          |
|-----------------|----------------------------------|
| `no_build.ads`  | Package spec (API)               |
| `no_build.adb`  | Package body (implementation)    |

That's it.  `gnatmake` follows `with` clauses automatically, so both files are
compiled as part of the normal bootstrap.

## Windows support

`no_build.adb` imports `dlopen` and `dlsym` to load OS functions at runtime.
On Linux (glibc ≥ 2.34) and macOS these resolve against libc / libSystem
automatically.  If you are on Windows and you aren't using Msys or Cygwin or some
other Posix implmementation (as GNAT does) you will not have a standard C 
library that provides them. You must add a small shim to your project that 
exports these symbols on top of `LoadLibraryA` / `GetProcAddress`.

Create `windows_dl.ads` and `windows_dl.adb` alongside `build.adb`:

```ada
-- windows_dl.ads
package Windows_DL is
   --  Exporting dlopen / dlsym from this unit satisfies the link-time
   --  references in no_build.adb.  Add `with Windows_DL;` to build.adb
   --  when compiling on windows to force the unit into the link;
   --  nothing else needs to call it.

   function DL_Open
     (Path : System.Address; Mode : Integer) return System.Address;
   pragma Export (C, DL_Open, "dlopen");

   function DL_Sym
     (Handle : System.Address; Symbol : System.Address) return System.Address;
   pragma Export (C, DL_Sym, "dlsym");

end Windows_DL;
```

```ada
-- windows_dl.adb
with System;
package body Windows_DL is

   function LoadLibraryA (Name : System.Address) return System.Address;
   pragma Import (Stdcall, LoadLibraryA, "LoadLibraryA");

   function GetModuleHandleA (Name : System.Address) return System.Address;
   pragma Import (Stdcall, GetModuleHandleA, "GetModuleHandleA");

   function GetProcAddress
     (Handle : System.Address; Name : System.Address) return System.Address;
   pragma Import (Stdcall, GetProcAddress, "GetProcAddress");

   function DL_Open
     (Path : System.Address; Mode : Integer) return System.Address
   is
      pragma Unreferenced (Mode);
      use type System.Address;
   begin
      if Path = System.Null_Address then
         --  dlopen(NULL): hand back a handle to the current process.
         return GetModuleHandleA (System.Null_Address);
      else
         return LoadLibraryA (Path);
      end if;
   end DL_Open;

   function DL_Sym
     (Handle : System.Address; Symbol : System.Address) return System.Address
   is
   begin
      return GetProcAddress (Handle, Symbol);
   end DL_Sym;

end Windows_DL;
```

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

1. **Use the shim above.**  Compiler-agnostic — same `build.adb` keeps
   working if you ever switch to ObjectAda, Janus, or another toolchain.
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
      Extra       => Argument_List'(S ("-largs"), S ("-ldl")));
   ```

The shim is recommended if you care about toolchain portability; `-ldl` is
shorter if you intend to stay on GNAT.

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

## API reference

### Platform

```ada
type Platform_Kind is (Linux, MacOS, Windows);

function Detect_Platform return Platform_Kind;
Platform : constant Platform_Kind := Detect_Platform;
```

`Platform` is a package-level constant evaluated at elaboration time.  Use it
anywhere you need to branch on the current OS.

### Command execution

```ada
procedure Cmd (Program : String; Args : Argument_List);
procedure Cmd (Program : String);
```
Locate `Program` on `PATH`, run it with `Args`, and wait for it to finish.
Prints `[CMD] program args...` to stderr.  Raises `Build_Error` on non-zero
exit or if the program is not found.

```ada
procedure Sh (Command : String);
```
Run `Command` through the platform shell (`/bin/sh -c` on Linux/macOS,
`cmd.exe /c` on Windows).

### Argument list helpers

`Argument_List` is an array of heap-allocated strings (`String_Access`), both
defined in `No_Build` itself — no `GNAT.OS_Lib` dependency.  Use `S` to
allocate individual strings and `&` to concatenate lists:

```ada
Cmd ("gnatmake", (S ("main.adb"), S ("-O2")));
Cmd ("gnatmake", Argument_List'(S ("main.adb")) & Extra_Flags);
```

```ada
function S (Str : String) return String_Access;
```

### Ada compilation

`No_Build` drives any Ada compiler through an `Ada_Compiler` descriptor.  The
default descriptor is `Gnatmake_Compiler` (matching the GNAT toolchain); call
`Set_Compiler` once to swap in a descriptor for ObjectAda, Janus, or any
other compiler that takes a source file plus output, object-directory, and
compile-only flags.

```ada
type Ada_Compiler is record
   Executable        : String_Access;  --  e.g. "gnatmake"
   Obj_Flag          : String_Access;  --  flag selecting the object dir
   Out_Flag          : String_Access;  --  flag selecting the output binary
   Compile_Only_Flag : String_Access;  --  flag suppressing the link step
end record;

Gnatmake_Compiler : constant Ada_Compiler;
procedure Set_Compiler (C : Ada_Compiler);
```

```ada
procedure Compile_Program
  (Source  : String;
   Output  : String        := "";
   Obj_Dir : String        := "";
   Extra   : Argument_List := (1 .. 0 => null));
```
Compile and link `Source` using the active compiler.  Passes the descriptor's
`Out_Flag` + `Output` and/or `Obj_Flag` + `Obj_Dir` when non-empty.  Creates
`Obj_Dir` if it does not exist.

```ada
procedure Compile
  (Source  : String;
   Obj_Dir : String        := "";
   Extra   : Argument_List := (1 .. 0 => null));
```
Compile-only: passes the active compiler's `Compile_Only_Flag` (e.g. `-c` on
GNAT) so that only `.o` (and `.ali`) files are produced.

### Library builds

```ada
procedure Build_Static_Lib
  (Src_Dir : String;
   Output  : String;
   Obj_Dir : String        := "";
   Extra   : Argument_List := (1 .. 0 => null));
```
Compile every `.adb` in `Src_Dir` with `-c`, then archive the objects into a
static library at `Output` (e.g. `"lib/libfoo.a"`) using `ar rcs`.

```ada
procedure Build_Shared_Lib
  (Src_Dir : String;
   Output  : String;
   Obj_Dir : String        := "";
   Extra   : Argument_List := (1 .. 0 => null));
```
Compile every `.adb` in `Src_Dir` with `-fPIC` (Linux/macOS; skipped on
Windows) using the active compiler's compile-only flag, then link the objects
into a shared library at `Output` (e.g. `"lib/libfoo.so"` /
`"lib/libfoo.dylib"`) using `gcc -shared` on Linux/Windows or
`gcc -dynamiclib` on macOS.

Use separate `Obj_Dir` values for static and shared builds to avoid mixing
PIC and non-PIC objects:

```ada
Build_Static_Lib ("lib", Output => "lib/libfoo.a",   Obj_Dir => "obj");
Build_Shared_Lib ("lib", Output => "lib/libfoo.so",  Obj_Dir => "obj/pic");
```

### Self-rebuilding build script

```ada
procedure Go_Rebuild_Urself
  (Binary_Path : String;
   Source_Path : String;
   Obj_Dir     : String        := "";
   Extra       : Argument_List := (1 .. 0 => null));
```
If `Source_Path` is newer than `Binary_Path`, recompile the build script with
the active compiler (`Compile_Program`) and re-execute it, forwarding all
original command-line arguments.  Call this as the **first statement** in
your build procedure.

If compilation fails the previous binary is restored so you are never left
without a working `./build`.

### Path utilities

```ada
function "/"  (Left, Right : String) return String;  -- join: "a" / "b" => "a/b"
function No_Ext    (Path   : String) return String;   -- strip extension
function Base_Name (Path   : String) return String;   -- final component
function Ends_With (Str, Suffix : String) return Boolean;
```

### Filesystem

```ada
function  Path_Exists (Path : String) return Boolean;
function  Is_Dir      (Path : String) return Boolean;
function  Is_Newer    (Path1, Path2 : String) return Boolean;

procedure Make_Dir    (Path : String);          -- create one directory
procedure Make_Dirs   (Path : String);          -- create with parents
procedure Rename_Path (Old_Path, New_Path : String);
procedure Remove_Path (Path : String);          -- recursive delete
```

`Is_Newer (A, B)` returns `True` when `A`'s mtime is after `B`'s, or when `B`
does not exist (always rebuild).  Returns `False` when `A` does not exist.

### Directory iteration

```ada
procedure For_Each_File
  (Dir     : String;
   Process : not null access procedure (File_Name : String);
   Suffix  : String := "");
```
Call `Process (simple_name)` for every entry in `Dir` whose name ends with
`Suffix`.  Pass `Suffix => ""` to visit every entry (excluding `.` and `..`).

```ada
For_Each_File ("src", Compile_One'Access, Suffix => ".adb");
```

### Logging

```ada
procedure Info  (Msg : String);  -- [INFO] to stderr
procedure Warn  (Msg : String);  -- [WARN] to stderr
procedure Erro  (Msg : String);  -- [ERRO] to stderr
procedure Panic (Msg : String);  -- [ERRO] to stderr, then raises Build_Error
```

All build failures raise `Build_Error`.

## Worked example

The `build.adb` in this repository builds static and shared libraries from
`lib/`, a set of standalone tools in `tools/`, and example programs in
`examples/`:

```ada
with No_Build; use No_Build;

procedure Build is
   Obj : constant String := "obj";

   procedure Build_Tool (Tool : String) is
   begin
      Compile_Program ("tools" / Tool, Output => "tools" / No_Ext (Tool),
                       Obj_Dir => Obj);
   end Build_Tool;

   procedure Build_And_Run_Example (Example : String) is
      Bin : constant String := "examples" / No_Ext (Example);
   begin
      Compile_Program ("examples" / Example, Output => Bin,
                       Obj_Dir => Obj,
                       Extra   => Argument_List'(S ("-I."), S ("-Ilib")));
      Cmd (Bin);
   end Build_And_Run_Example;

begin
   Go_Rebuild_Urself (Binary_Path => "./build",
                      Source_Path => "build.adb",
                      Obj_Dir     => Obj);

   Info ("building static library...");
   Build_Static_Lib ("lib", Output => "lib/libgreet.a", Obj_Dir => Obj);

   Info ("building shared library...");
   Build_Shared_Lib ("lib", Output => "lib/libgreet.so",
                     Obj_Dir => Obj / "pic");

   Info ("building tools...");
   For_Each_File ("tools",    Build_Tool'Access,            Suffix => ".adb");

   Info ("building and running examples...");
   For_Each_File ("examples", Build_And_Run_Example'Access, Suffix => ".adb");

   Info ("Done.");
end Build;
```

## Requirements

- Any Ada 2012+ compiler (tested with GNAT 15).  The package has no
  `with GNAT.OS_Lib`, so other toolchains (ObjectAda, Janus, …) should
  build it given an `Ada_Compiler` descriptor.
- `ar` for static libraries
- `gcc` for shared libraries
- On Windows: the `windows_dl.adb` shim described above

## Inspiration

Inspired by [nob.h](https://github.com/tsoding/nob.h) by Tsoding.
