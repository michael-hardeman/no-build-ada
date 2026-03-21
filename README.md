# no-build

An Ada port of [nob.h](https://github.com/tsoding/nob.h) — a build system
that lives entirely in your source tree with no Makefiles, no `.gpr` project
files, and no external tools beyond `gnatmake`.

## Concept

Write your build logic as a normal Ada program (`build.adb`).  Bootstrap it
once with `gnatmake`, and from then on `./build` recompiles itself whenever
`build.adb` changes before doing anything else (*Go Rebuild Urself* pattern).

```
gnatmake build.adb -o build   # one-time bootstrap
./build                        # use forever after
```

## Installation

Copy two files into your project root alongside `build.adb`:

| File            | Purpose                          |
|-----------------|----------------------------------|
| `no_build.ads`  | Package spec (API)               |
| `no_build.adb`  | Package body (implementation)    |

That's it.  `gnatmake` follows `with` clauses automatically, so both files are
compiled as part of the normal bootstrap.

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

   Gnatmake ("src/main.adb", Output => "bin/main", Obj_Dir => Obj);
end Build;
```

## API reference

### Platform

```ada
type Platform_Kind is (Linux, Windows);

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

`Argument_List` is a subtype of `GNAT.OS_Lib.Argument_List` (an array of
heap-allocated strings).  Use `S` to allocate individual strings and `&` to
concatenate lists:

```ada
Cmd ("gnatmake", (S ("main.adb"), S ("-O2")));
Cmd ("gnatmake", Argument_List'(S ("main.adb")) & Extra_Flags);
```

```ada
function S (Str : String) return String_Access;
```

### Ada compilation

```ada
procedure Gnatmake
  (Source  : String;
   Output  : String        := "";
   Obj_Dir : String        := "";
   Extra   : Argument_List := (1 .. 0 => null));
```
Compile and link `Source` with `gnatmake`.  Passes `-o Output` and/or
`-D Obj_Dir` when non-empty.  Creates `Obj_Dir` if it does not exist.

```ada
procedure Compile
  (Source  : String;
   Obj_Dir : String        := "";
   Extra   : Argument_List := (1 .. 0 => null));
```
Compile-only (`-c`): produces `.o` and `.ali` without linking.

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
Compile every `.adb` in `Src_Dir` with `-c -fPIC` (Linux) or `-c` (Windows),
then link the objects into a shared library at `Output`
(e.g. `"lib/libfoo.so"`) using `gcc -shared`.

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
`gnatmake` and re-execute it, forwarding all original command-line arguments.
Call this as the **first statement** in your build procedure.

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
      Gnatmake ("tools" / Tool, Output => "tools" / No_Ext (Tool),
                Obj_Dir => Obj);
   end Build_Tool;

   procedure Build_And_Run_Example (Example : String) is
      Bin : constant String := "examples" / No_Ext (Example);
   begin
      Gnatmake ("examples" / Example, Output => Bin,
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

- GNAT (any recent version — tested with GNAT 15)
- `ar` for static libraries
- `gcc` for shared libraries

## Inspiration

Inspired by [nob.h](https://github.com/tsoding/nob.h) by Tsoding.
