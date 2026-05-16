# Phase 3 Pre-work: Audit of Phases 1 & 2

## Phase 1 Audit

| Planned task | Status | Notes |
|---|---|---|
| Define own `String_Access`, `Argument_List` | DONE | `no_build.ads:49-50` — own types, no longer subtypes of GNAT.OS_Lib |
| Define own `Free` | MISSING | Plan called for `procedure Free is new Ada.Unchecked_Deallocation(...)` — never added. Not currently used anywhere in the body so non-blocking, but should be provided for users who want to free argument strings. |
| `Is_Newer` via `Ada.Directories.Modification_Time` | DONE | `no_build.adb:579-590` — pure standard Ada, no imports |
| `Detect_Platform` via env var + filesystem probe | DONE | `no_build.adb:50-63` — uses `Ada.Environment_Variables.Exists("WINDIR")` and `Ada.Directories.Exists("/usr/bin/sw_vers")` |
| Add `MacOS` to `Platform_Kind` | DONE | `no_build.ads:29` |
| Keep `System.Multiprocessors` unchanged | DONE | `no_build.adb:11,313-317` |
| `Sh` handles MacOS | DONE | `no_build.adb:118-123` — `Linux \| MacOS => /bin/sh` |
| `Build_Shared_Lib` MacOS (`-dynamiclib`) | DONE | `no_build.adb:411-413` |
| PIC flag respects Platform | DONE | `no_build.adb:350-353` — skips `-fPIC` on Windows |
| Remove `with GNAT.OS_Lib` (or stub) | DEFERRED | Kept as `private with GNAT.OS_Lib` in spec and `with GNAT.OS_Lib` in body — transitional, expected to be removed in Phase 3 |

**Phase 1 verdict**: Complete except for the `Free` procedure (low priority).

---

## Phase 2 Audit

| Planned task | Status | Notes |
|---|---|---|
| Add `DL_Open`/`DL_Sym` imports | NOT DONE | Plan said Phase 2; deferred to Phase 3. Not needed for file I/O since Ada.Streams.Stream_IO was used instead. |
| Replace `Read_File` / `Write_File` with dlopen'd POSIX/Win32 I/O | CHANGED | `no_build.adb:746-778` — uses `Ada.Streams.Stream_IO` instead. **Better than planned**: pure standard Ada, no platform dispatch needed. |
| Replace `Rename_Path` with dlopen'd `rename()`/`MoveFileExA` | CHANGED | `no_build.adb:546-561` — uses `Ada.Directories.Copy_File` + `Delete_File` for files, `Copy_Dir` + `Delete_Tree` for dirs. **Trade-off**: not atomic like POSIX `rename()`, but pure standard Ada and works cross-platform. |
| Remove symlink branch from `Walk_Dir_Rec` | DONE | `no_build.adb:657` — `Ada.Directories.Special_File => Kind := Other` |
| Compile and run example suite | DONE | All 6 examples pass |

**Phase 2 verdict**: Complete with plan deviations that are net-positive. File I/O and rename now use standard Ada instead of dlopen, which is simpler and more portable. The dlopen/dlsym infrastructure is entirely deferred to Phase 3 where it's actually required (process management).

---

## Remaining GNAT.OS_Lib References (Phase 3 scope)

All remaining references are process management. Grouped by function:

### Spec (`no_build.ads`)

| Lines | Usage | Replacement |
|---|---|---|
| 12 | `private with GNAT.OS_Lib;` | Remove entirely |
| 307 | `Pid : GNAT.OS_Lib.Process_Id := GNAT.OS_Lib.Invalid_Pid;` | Own type: `Pid : System.Address := System.Null_Address;` |
| 310 | `Invalid_Proc : constant Proc := (Pid => GNAT.OS_Lib.Invalid_Pid);` | `(Pid => System.Null_Address)` |

### Body (`no_build.adb`)

| Lines | Symbol | Used in | Replacement |
|---|---|---|---|
| 12 | `with GNAT.OS_Lib` | package-level | Remove |
| 20-21 | `use type GNAT.OS_Lib.String_Access`, `Process_Id` | package-level | Remove |
| 32-44 | `To_GNAT_SA`, `To_GNAT_Args` bridge functions | Cmd, Cmd_Async, GRU | Remove entirely |
| 136-147 | `Locate_Exec_On_Path`, `Free` | `Resolve_Program` | Pure Ada PATH walk |
| 174-181 | `Spawn` (synchronous) | `Cmd` (no redirect) | dlsym'd `fork`+`execv`+`waitpid` |
| 189-221 | `Non_Blocking_Spawn`, `Wait_Process`, `Invalid_Pid` | `Cmd` (with redirect) | dlsym'd process functions + `dup2`+`open`+`close` |
| 232-251 | `Non_Blocking_Spawn`, `Invalid_Pid` | `Cmd_Async` | dlsym'd `fork`+`execv` |
| 261-266 | `Wait_Process`, `Invalid_Pid` | `Wait` | dlsym'd `waitpid` |
| 287-300 | `Wait_Process`, `Invalid_Pid` | `Wait_All` | dlsym'd `waitpid` |
| 848-858 | `Spawn`, `OS_Exit` | `Go_Rebuild_Urself` | dlsym'd `fork`+`execv`+`waitpid`+`_exit` |

### Other files (not in Phase 3 scope but noted)

| File | Usage | Notes |
|---|---|---|
| `tools/rot13.adb:3` | `with GNAT.OS_Lib; use GNAT.OS_Lib;` | Standalone tool, not part of no_build package |
| `tools/cat.adb:3` | `with GNAT.OS_Lib; use GNAT.OS_Lib;` | Standalone tool |
| `tools/hex.adb:3` | `with GNAT.OS_Lib; use GNAT.OS_Lib;` | Standalone tool |
| `README.md:79,261` | Documentation references | Update in Phase 5 |
| `CLAUDE.md:45` | "Requirements: GNAT" | Update in Phase 5 |

---

## Phase 3 Implementation Plan

### Step 1: Spec changes (`no_build.ads`)

1. Remove `private with GNAT.OS_Lib`
2. Add `with System;` (needed for `System.Address` in Proc and DL types)
3. Add DL binding types to public API:
   - `DL_Handle`, `DL_Open_Func`, `DL_Sym_Func`, `DL_Binding`, `Set_DL_Binding`
4. Change private section:
   - `Proc.Pid` becomes `System.Address` (was `GNAT.OS_Lib.Process_Id`)
   - `Invalid_Proc` uses `System.Null_Address`

### Step 2: Body infrastructure (`no_build.adb`)

1. Remove `with GNAT.OS_Lib` and all `use type` clauses for it
2. Remove bridge functions (`To_GNAT_SA`, `To_GNAT_Args`)
3. Add `with Interfaces.C; with Interfaces.C.Strings; with System;`
4. Add `pragma Import` for `dlopen` and `dlsym` (the only two C imports)
5. Add `pragma Linker_Options ("-ldl")` for older glibc systems
6. Declare C function pointer types for POSIX process functions:
   - `fork`, `execv`, `waitpid`, `_exit`, `dup2`, `open`, `close`
7. Load function pointers at elaboration via `dlsym(dlopen(NULL, RTLD_LAZY), ...)`
8. Implement `Set_DL_Binding`

### Step 3: Replace `Resolve_Program`

Replace `GNAT.OS_Lib.Locate_Exec_On_Path` with pure Ada PATH walking:
- Read `Ada.Environment_Variables.Value("PATH")`
- Split on `:` (POSIX) or `;` (Windows)
- For each dir, check `Ada.Directories.Exists(Dir / Program)`
- On Windows, also check `Program & ".exe"` if no extension
- If Program contains `/`, treat as absolute/relative (skip PATH search)

### Step 4: Replace process management

Implement POSIX process spawn using loaded function pointers:
- `Spawn_Process`: `fork()` in parent, `execv()` in child; returns pid
- `Spawn_Process_Redirected`: same but with `dup2()`+`open()`+`close()` before `execv()`
- `Wait_For_Process`: `waitpid()` wrapper, extracts exit status

Replace all `Cmd`, `Cmd_Async`, `Wait`, `Wait_All` internals.

### Step 5: Replace `Go_Rebuild_Urself`

- Replace `GNAT.OS_Lib.Spawn` + `OS_Exit` with the new spawn+wait+`_exit()` calls

### Step 6: Verify

- `rm -rf obj/ build && gnatmake build.adb -o build && ./build`
- Confirm zero GNAT.OS_Lib references in no_build.ads and no_build.adb
