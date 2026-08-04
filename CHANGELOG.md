# Changelog

All notable changes to no-build-ada are recorded here. Versions follow
semver-ish discipline: while the project is pre-1.0 the minor version
bumps on any breaking change to the public surface of `no_build.ads`,
the patch bumps on behavior-preserving fixes.

The library version is also surfaced as the `No_Build.Version` constant
in `no_build.ads`.

## Unreleased

### Fixed

- Child-side stdout/stderr redirection now calls `creat(2)` instead of
  `open(2)`.  `open` is variadic, and on arm64 Darwin variadic arguments
  are passed on the stack, so calling it through a fixed-arity access
  type handed the kernel a garbage creation mode: redirect targets (and
  therefore `Capture`'s temp file) could be created unreadable, making
  `Capture` fail with `cannot read file:` on Apple Silicon.  `creat` is
  non-variadic and means exactly `O_WRONLY | O_CREAT | O_TRUNC`, so the
  per-platform flag literals are gone as well.

## 0.1.0 — 2026-05-19

First tagged release.

### Added

- `No_Build.Version` constant in `no_build.ads`.
- `Log_Level` enum (`Verbose | Normal | Quiet | Silent`) and
  `Set_Log_Level` procedure so callers can mute per-command
  `[CMD]` / `[MKDIR]` / ... noise without writing a custom
  `Log_Handler`.  Default level remains `Verbose`.
- `Ada_Compiler` gained `Source_Spec_Ext`, `Source_Body_Ext`,
  `Object_Ext`, and a `Resolve_Source` access function so toolchain
  conventions (file extensions, source-path quirks) live on the
  descriptor instead of being hardcoded.  The default
  `Gnatmake_Compiler` wires `Resolve_Source` to a body-local helper
  that swaps a `.ads` for a sibling `.adb` -- working around
  `gnatmake -c`'s refusal to compile a bare spec next to a body.

### Changed

- `Build_Static_Lib` and `Build_Shared_Lib` now take a single `Source`
  (path to a root `.ads` or `.adb`) instead of a `Src_Dir`, mirroring
  `Compile_Program`.  The compiler compiles Source plus its
  `with`-closure; spec-only packages are no longer silently skipped,
  and hierarchical packages are included only when reachable from the
  root unit's `with`-closure.
- `Obj_Dir` is now the *parent* directory; each Build_*_Lib call
  carves its own subdir (`<stem>_static` or `<stem>_pic`, derived
  from `Output`'s basename) so executable and library builds can
  share an `Obj_Dir` without cross-contamination.  The library
  archives or links every object file (extension from
  `Active_Compiler.Object_Ext`) found in that subdir.
- `Wait` (on a `Proc` returned by `Cmd_Async`) now embeds the exit
  status in the `Build_Error` message, matching `Cmd` / `Check_Exit`.
- `Capture` writes its temporary stdout file under `$TMPDIR` (POSIX) /
  `%TEMP%` / `%TMP%` (Windows) when those are set, falling back to the
  previous CWD-local path otherwise. Builds in a read-only working
  directory no longer fail at `Capture`.
- `Find_Gnat_Runtime` raises a diagnostic `Build_Error` that includes
  the underlying `Capture` failure message instead of swallowing it,
  so "gcc missing" and "gcc exited non-zero" don't look identical.
- The default `Gnatmake_Compiler` descriptor sets
  `Shared_Runtime_Probe` to null on macOS, since the macOS shared
  link uses `-undefined dynamic_lookup` and resolves the GNAT
  runtime at load time -- no need to embed libgnat into the .dylib,
  and the Alire toolchain on macOS doesn't reliably ship a `gcc`
  symlink suitable for `-print-libgcc-file-name`.
- `waitpid` loops in `Posix_Spawn` / `Posix_Wait` now tolerate signal
  interruption: a `-1` return retries up to a bounded number of times
  rather than treating EINTR as a hard failure.
- Magic POSIX literals and conditionals (`Pid < 0`, `Pid = 0`,
  `FD < 0`, raw `mod 128` / `/ 256` exit-status bit twiddling,
  `RTLD_LAZY = 1`, `O_WRONLY` / `O_CREAT` / `O_TRUNC` literals,
  stdout/stderr fd numbers, child exec-failure exit codes) have been
  replaced with named constants (`POSIX_STDOUT_FD`,
  `POSIX_DEFAULT_FILE_MODE`, `Child_Exit_Exec_Failed`, ...) and
  predicates (`Fork_Failed`, `In_Child_Process`, `Syscall_Failed`) so
  the call sites read like prose.

### Documentation

- `Build_Static_Lib` doc now states that the archive contains object
  files only (no Ada binder artifact) and is intended for re-link by
  a downstream Ada toolchain, not direct consumption by a non-Ada
  linker.
- `tests/build_tests` reports assertion-level pass/fail totals in
  addition to the program-level tally.
- README typos fixed and the Windows-support paragraph rewritten;
  GNAT minimum and per-platform CI toolchains stated explicitly.
