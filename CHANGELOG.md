# Changelog

All notable changes to no-build-ada are recorded here. Versions follow
semver-ish discipline: while the project is pre-1.0 the minor version
bumps on any breaking change to the public surface of `no_build.ads`,
the patch bumps on behavior-preserving fixes.

The library version is also surfaced as the `No_Build.Version` constant
in `no_build.ads`.

## 0.1.0 — 2026-05-19

First tagged release.

### Added

- `No_Build.Version` constant in `no_build.ads`.
- `Log_Level` enum (`Verbose | Normal | Quiet | Silent`) and
  `Set_Log_Level` procedure so callers can mute per-command
  `[CMD]` / `[MKDIR]` / ... noise without writing a custom
  `Log_Handler`. Default level remains `Verbose`.

### Changed

- `Build_Static_Lib` and `Build_Shared_Lib` now take a single `Source`
  (path to a root `.ads` or `.adb`) instead of a `Src_Dir`, mirroring
  `Compile_Program`. gnatmake compiles Source plus its `with`-closure
  into the (now required) `Obj_Dir`, and the library is archived (or
  linked) from every `.o` left there. Spec-only packages (`.ads`
  without a body) are no longer silently skipped; hierarchical
  packages are included only when reachable from the root unit's
  `with`-closure. `Obj_Dir` must be dedicated to the library --
  shared dirs would pull unrelated objects into the archive.
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

- `Build_Static_Lib` doc now states that the `.a` contains object
  files only (no Ada binder) and is intended for re-link by a
  downstream `gnatmake`, not direct consumption by a non-Ada linker.
- `tests/build_tests` reports assertion-level pass/fail totals in
  addition to the program-level tally.
- README typos fixed and the Windows-support paragraph rewritten;
  GNAT minimum stated explicitly.
