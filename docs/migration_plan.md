# Migration Plan: Remove GNAT.OS_Lib Dependency

## Goals

- Remove all `GNAT.OS_Lib` uses so the package compiles with any Ada 2012+
  compiler (GNAT, ObjectAda, Janus, future open-source compilers, etc.).
- Add macOS as a first-class supported platform alongside Linux and Windows.
- Rename `Gnatmake` → `Compile_Program` and introduce a generic compiler
  abstraction so users are not tied to gnatmake.
- Keep the single source-pair distribution model (`no_build.ads` + `no_build.adb`).
- No C companion file.
- Introduce zero new link-time dependencies beyond the default Ada RTS link set.

## Non-Goals

- Reimplementing Ada.Directories or Ada.Text_IO — those are standard and fine.
- Supporting non-POSIX UNIX variants (AIX, HP-UX, etc.) in this pass.
- Removing Ada.Command_Line or System — those are standard Ada.

---

## What GNAT.OS_Lib Currently Provides

| Usage site | GNAT.OS_Lib symbol | Replacement |
|---|---|---|
| Platform detection | `Directory_Separator` | Pure Ada — see below |
| Arg list types | `Argument_List`, `String_Access`, `Free` | Own type definitions |
| PATH search | `Locate_Exec_On_Path` | Walk `PATH` env var manually |
| Sync spawn + wait | `Spawn` | `dlopen`/`dlsym` → `fork`+`exec`+`waitpid` / `CreateProcessA` |
| Async spawn | `Non_Blocking_Spawn` | Same |
| Wait for child | `Wait_Process` | Same |
| Process handle | `Process_Id`, `Invalid_Pid` | Own `Proc` record |
| Re-execute self | `OS_Exit` | `dlopen`/`dlsym` → `_exit` / `ExitProcess` |
| Low-level file I/O | `Open_Read`, `Create_File`, `Read`, `Write`, `Close`, `File_Descriptor`, `Invalid_FD`, `File_Length` | `pragma Import` of POSIX/Win32 directly |
| File timestamps | `File_Time_Stamp` | `Ada.Directories.Modification_Time` |
| Rename file | `Rename_File` | `pragma Import` of `rename` / `MoveFileExA` |
| Symlink check | `Is_Symbolic_Link` | Dropped — see below |
| CPU count | *(System.Multiprocessors)* `Number_Of_CPUs` | Keep as-is — it IS standard Ada |

---

## Replacement Strategy

### 1. Own type definitions (replacing GNAT.OS_Lib types)

Remove the `subtype` aliases that forwarded to GNAT.OS_Lib and define our own:

```ada
type String_Access is access String;
type Argument_List is array (Positive range <>) of String_Access;
procedure Free is new Ada.Unchecked_Deallocation (String, String_Access);
```

Semantics are identical. Existing user code that builds `Argument_List` literals
with `S("foo") & S("bar")` continues to work unchanged.

### 2. CPU count — keep System.Multiprocessors

`System.Multiprocessors.Number_Of_CPUs` is defined in the Ada Reference Manual
(ARM D.16, Systems Programming Annex).  It is not GNAT-specific.  The GNAT
source even notes: *"This specification is derived from the Ada Reference
Manual."*  Keep the existing `N_Procs` implementation; remove from the problem
list.

### 3. File timestamps — Ada.Directories.Modification_Time

`Ada.Directories.Modification_Time (Path)` returns `Ada.Calendar.Time`.
Two `Ada.Calendar.Time` values compare with the standard `>` operator.
This is pure standard Ada (2005+) and completely replaces `File_Time_Stamp`
and all `stat()` struct layout concerns:

```ada
function Is_Newer (Path1, Path2 : String) return Boolean is
   use Ada.Directories, Ada.Calendar;
begin
   if not Exists (Path1) then return False; end if;
   if not Exists (Path2) then return True;  end if;
   return Modification_Time (Path1) > Modification_Time (Path2);
end Is_Newer;
```

No `pragma Import`, no struct offsets, no platform variation.

### 4. Platform detection — pure Ada, no imports

Detect the platform at elaboration time using only `Ada.Environment_Variables`
and `Ada.Directories.Exists`:

```ada
function Detect_Platform return Platform_Kind is
begin
   --  WINDIR is a Windows system variable, always present, never set on POSIX.
   if Ada.Environment_Variables.Exists ("WINDIR") then
      return Windows;
   --  sw_vers is a macOS system utility present on every macOS installation.
   elsif Ada.Directories.Exists ("/usr/bin/sw_vers") then
      return MacOS;
   else
      return Linux;
   end if;
end Detect_Platform;
```

`Ada.Environment_Variables` is standard Ada 2005 (A.17).
`Ada.Directories.Exists` is standard Ada 2005.
No `pragma Import`, no C preprocessor, no extra files.

`Platform_Kind` gains a third value:

```ada
type Platform_Kind is (Linux, MacOS, Windows);
```

### 5. Symlink detection — dropped

`Walk_Dir` currently calls `GNAT.OS_Lib.Is_Symbolic_Link` to distinguish
symlinks from other special files.  There is no single API available on all
three platforms without either a C helper or conditional link-time imports.

**Decision**: Remove the distinction.  All `Ada.Directories.Special_File`
entries become `Other` in the Walk callback.  The `Symlink` value is retained
in the `File_Kind` enumeration for API compatibility but is documented as never
returned by this implementation.  Any user who needs symlink discrimination on
a specific platform can wrap the Walk callback with a platform-specific check.

### 6. Process management — dlopen/dlsym

This is the hardest part.  `fork`+`execv`+`waitpid` do not exist on Windows.
`CreateProcessA`+`WaitForSingleObject` do not exist on POSIX.  A single Ada
source file cannot conditionally import one set or the other at link time
without a C preprocessor or separate platform bodies.

**Solution**: import only `dlopen` and `dlsym` via `pragma Import`; load every
other OS function through them at runtime as function-pointer-typed
`System.Address` values converted with `Ada.Unchecked_Conversion`.

The only two `pragma Import (C, ...)` declarations in the package body are:

```ada
type DL_Handle is new System.Address;

function Default_DL_Open
  (Path : System.Address; Mode : Integer) return DL_Handle;
pragma Import (C, Default_DL_Open, "dlopen");

function Default_DL_Sym
  (Handle : DL_Handle; Symbol : System.Address) return System.Address;
pragma Import (C, Default_DL_Sym, "dlsym");
```

These are resolved at link time:
- **Linux** (glibc ≥ 2.34): `dlopen` / `dlsym` are in libc itself.
- **macOS**: `dlopen` / `dlsym` are in libSystem (always linked).
- **Windows**: no standard C library provides these symbols.  The user must
  supply a shim — `windows_dl.adb` — that exports `dlopen` and `dlsym` via
  `pragma Export (C, ...)`, implemented over `LoadLibraryA` /
  `GetProcAddress`, and `with`s it from `build.adb` so the linker pulls it
  into the executable.  The stock shim is in the README's Windows section.

Older toolchains (glibc < 2.34, non-MinGW Windows compilers without their
own libdl wrapper) are not supported.  No `pragma Linker_Options` is used.

At elaboration time:

```ada
--  POSIX path (Linux + macOS)
--    dlopen(NULL, RTLD_LAZY) opens the already-loaded process image,
--    giving access to all libc symbols.
Posix_Lib : constant DL_Handle :=
   Default_DL_Open (System.Null_Address, 1);  --  RTLD_LAZY = 1
```

Each OS function is then loaded once via `Default_DL_Sym` and stored as a
procedure or function access type, obtained through
`Ada.Unchecked_Conversion`:

```ada
--  Example: fork
type Fork_Fn is access function return Interfaces.C.int;
pragma Convention (C, Fork_Fn);
function To_Fork is new Ada.Unchecked_Conversion (System.Address, Fork_Fn);

Fork : constant Fork_Fn := To_Fork (DL_Sym (Posix_Lib, New_String ("fork")));
```

Functions that are not available on the current platform have their slot
initialized to a null address.  Calling a null slot on the wrong platform
raises `Build_Error` with a clear message.

#### POSIX functions loaded at runtime

| Ada name | libc symbol | Notes |
|---|---|---|
| `Fork` | `fork` | Create child process |
| `Execv` | `execv` | Replace child image |
| `Waitpid` | `waitpid` | Wait for child, get exit code |
| `C_Exit` | `_exit` | Exit without flushing stdio |
| `Dup2` | `dup2` | Redirect fd before exec |
| `Open_FD` | `open` | Open file for redirection |
| `Close_FD` | `close` | Close file descriptor |
| `Read_FD` | `read` | Read from fd (for Read_File) |
| `Write_FD` | `write` | Write to fd (for Write_File) |
| `Rename_C` | `rename` | Atomic file rename |

#### Windows functions loaded at runtime (via MinGW dlopen → LoadLibraryA)

| Ada name | kernel32 symbol | Notes |
|---|---|---|
| `Create_Process` | `CreateProcessA` | Spawn a process |
| `Wait_Single` | `WaitForSingleObject` | Wait for handle |
| `Get_Exit_Code` | `GetExitCodeProcess` | Get exit code from handle |
| `Close_Handle` | `CloseHandle` | Close process/file handle |
| `Create_File_W` | `CreateFileA` | Open/create file |
| `Read_File_W` | `ReadFile` | Read from HANDLE |
| `Write_File_W` | `WriteFile` | Write to HANDLE |
| `Move_File` | `MoveFileExA` | Rename/move file |
| `Exit_Process` | `ExitProcess` | Exit process |

#### PATH search (replacing Locate_Exec_On_Path)

Walk `Ada.Environment_Variables.Value ("PATH")` splitting on `:` (POSIX) or
`;` (Windows), and for each directory check `Ada.Directories.Exists (Dir / Program)`.
On Windows also probe `Program & ".exe"` if the name has no extension.
Pure standard Ada — no `pragma Import` required.

#### I/O redirection

POSIX: `dup2` + `open` before `execv` in the child.
Windows: populate `STARTUPINFO.hStdOutput/hStdError` in `CreateProcessA`.

#### Shared library flags

`Build_Shared_Lib` passes `-shared` (Linux) or `-dynamiclib` (macOS) and uses
`.so` / `.dylib` output extensions respectively, selected at runtime via
`Platform`.

### 7. File I/O (replacing GNAT File_Descriptor)

`Read_File` and `Write_File` use the POSIX/Win32 fd functions already loaded
via `dlopen`/`dlsym` (see table above).  No additional imports are needed.

### 8. Rename (replacing GNAT.OS_Lib.Rename_File)

POSIX `rename()` and Windows `MoveFileExA()` are both loaded via
`dlopen`/`dlsym` at elaboration time.  `Rename_Path` dispatches on `Platform`.

---

## Compiler Abstraction: Compile_Program

`Gnatmake` is replaced by a generic compiler descriptor + `Compile_Program`.

### Ada_Compiler type

```ada
type Ada_Compiler is record
   Executable        : String_Access;  -- e.g. "gnatmake"
   Obj_Flag          : String_Access;  -- e.g. "-D"
   Out_Flag          : String_Access;  -- e.g. "-o"
   Compile_Only_Flag : String_Access;  -- e.g. "-c"
end record;

Gnatmake_Compiler : constant Ada_Compiler :=
  (Executable        => S ("gnatmake"),
   Obj_Flag          => S ("-D"),
   Out_Flag          => S ("-o"),
   Compile_Only_Flag => S ("-c"));
```

### New public API

```ada
procedure Set_Compiler    (C : Ada_Compiler);
procedure Compile_Program
  (Source  : String;
   Output  : String        := "";
   Obj_Dir : String        := "";
   Extra   : Argument_List := (1 .. 0 => null));
```

`Gnatmake` is kept as a deprecated alias that calls `Compile_Program` using a
hardcoded `Gnatmake_Compiler` descriptor — existing `build.adb` scripts
continue to compile unchanged.

`Compile`, `Build_Static_Lib`, `Build_Shared_Lib`, and `Go_Rebuild_Urself`
are updated to use `Compile_Program` via `Active_Compiler`.

---

## Migration Phases

### Phase 1 — Types, CPU count, timestamps, platform detection
- Define own `String_Access`, `Argument_List`, `Free`.
- Update `Is_Newer` to use `Ada.Directories.Modification_Time`.
- Implement `Detect_Platform` via env var + filesystem probe.
- Add `MacOS` to `Platform_Kind`.
- Keep `System.Multiprocessors` unchanged.
- Remove `with GNAT.OS_Lib` temporarily replaced by a stub; confirm package
  still compiles.

### Phase 2 — File I/O, rename, symlink
- Add `DL_Open` / `DL_Sym` imports.
- Load POSIX `open`/`read`/`write`/`close` or Win32 `CreateFileA`/`ReadFile`/
  `WriteFile` at elaboration; update `Read_File` / `Write_File`.
- Load POSIX `rename` or Win32 `MoveFileExA`; update `Rename_Path`.
- Remove symlink branch from `Walk_Dir_Rec`; return `Other` for special files.
- Compile and run example suite.

### Phase 3 — Process management
- Implement `PATH_Search` in pure Ada.
- Load `fork`/`execv`/`waitpid`/`_exit`/`dup2` (POSIX) or
  `CreateProcessA`/`WaitForSingleObject`/`GetExitCodeProcess`/
  `ExitProcess` (Windows) via `dlopen`/`dlsym`.
- Replace `Cmd`, `Cmd_Async`, `Wait`, `Wait_All`, `Go_Rebuild_Urself`.
- Full build + self-rebuild test on Linux, macOS, and Windows.

### Phase 4 — Compiler abstraction
- Add `Ada_Compiler`, `Set_Compiler`, `Compile_Program` to spec.
- Keep `Gnatmake` as deprecated alias.
- Update `Compile`, `Build_Static_Lib`, `Build_Shared_Lib`,
  `Go_Rebuild_Urself` to call `Compile_Program`.

### Phase 5 — Cleanup and verification
- Remove `with GNAT.OS_Lib` from both files — confirm clean compile with
  GNAT using `-gnatX0` to surface any residual GNAT-isms.
- Verify on macOS arm64 and x86-64.
- Update CLAUDE.md and README (add macOS bootstrap section, document
  Windows shim).

---

## API Surface Changes Summary

| Old | New | Notes |
|---|---|---|
| `subtype String_Access is GNAT.OS_Lib.String_Access` | `type String_Access is access String` | Same semantics |
| `subtype Argument_List is GNAT.OS_Lib.Argument_List` | `type Argument_List is array (Positive range <>) of String_Access` | Same layout |
| `type Platform_Kind is (Linux, Windows)` | `type Platform_Kind is (Linux, MacOS, Windows)` | Additive |
| `procedure Gnatmake (...)` | `procedure Compile_Program (...)` | `Gnatmake` kept as alias |
| *(new)* | `type Ada_Compiler is record ... end record` | Compiler descriptor |
| *(new)* | `procedure Set_Compiler (C : Ada_Compiler)` | Switch active compiler |
| *(new)* | `Gnatmake_Compiler : constant Ada_Compiler` | Pre-built descriptor |
| `Walk_Entry.Kind = Symlink` | never returned | Documented limitation |

No other public API symbols are removed or renamed.

---

## Open Questions

1. **`dlopen(NULL, ...)` on macOS**: `RTLD_DEFAULT` on macOS is
   `((void *)-2)`, not `NULL`.  Using `NULL` opens the main bundle only, which
   may not expose all libc symbols.  Verify at Phase 3 whether
   `dlopen(NULL, RTLD_LAZY)` suffices or whether we must pass
   `dlopen("libSystem.dylib", RTLD_LAZY)` on macOS specifically.

2. **`Compile_Program` and `Go_Rebuild_Urself`**: When the build script
   recompiles itself, `Go_Rebuild_Urself` uses `Active_Compiler`.  If the
   user changed the active compiler before calling `Go_Rebuild_Urself`, the
   self-rebuild uses that compiler — which may or may not be intentional.
   Consider a dedicated `Bootstrap_Compiler` parameter.

3. **Thread safety of `Active_Compiler`**: Package-level variable.  Add a
   protected object if concurrent calls to `Set_Compiler` ever become a
   concern.

4. **Windows console inheritance**: `CreateProcessA` with
   `bInheritHandles = TRUE` and no `STARTUPINFO` flag override will inherit
   the parent's console.  Verify that stdout/stderr pass through correctly
   in the default (non-redirected) case.
