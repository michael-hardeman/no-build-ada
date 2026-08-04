# Changelog

All notable changes to no-build-ada are recorded here. Versions follow
semver-ish discipline: while the project is pre-1.0 the minor version
bumps on any breaking change to the public surface of `no_build.ads`,
the patch bumps on behavior-preserving fixes.

The library version is also surfaced as the `No_Build.Version` constant
in `no_build.ads`.

## 0.1.0-ada83 — 2026-08-04

A rewrite of the library for [Ada83](https://github.com/AdaDoom3/Ada83),
a single-file Ada 83 compiler with an LLVM back end. The target is
MIL-STD-1815A alone, so nothing from Ada 95 or later is available: no
`Ada.Strings.Unbounded`, no `Ada.Containers`, no `Ada.Directories`, no
`Ada.Command_Line`, no access-to-subprogram types, no controlled types,
no child units. Everything the build system needs from the operating
system is bound directly with `pragma Import`.

This is not source-compatible with the 0.1.0 line. A build script
written against that version needs the changes listed under *Changed*
and *Removed* below.

### Changed

- `For_Each_File` and `Walk_Dir` are generics taking a formal
  subprogram, since Ada 83 has no access-to-subprogram types.
  Instantiate, then call the instance:

  ```ada
  procedure Show_All is new For_Each_File (Show);
  ...
  Show_All ("src", ".adb");
  ```

- `Argument_List` is a plain private type over a growable array of
  string accesses. Without controlled types there is no deep copy on
  assignment and no free on scope exit: assignment shares storage, `Copy`
  makes an independent list, and `Clear` releases one. Build scripts are
  short-lived processes, so leaving a list unfreed is harmless.

- `Build_Error` carries no message. Ada 83 exceptions have no associated
  string, so every raiser logs through `Erro` first and the text lands on
  stderr rather than in the exception.

- `Platform` is a function rather than a constant. A constant in the spec
  cannot call the body's detection function during elaboration; the
  result is computed on first call and cached. The probe no longer uses
  `Ada.Environment_Variables` — it looks for `C:\Windows` and
  `/usr/bin/sw_vers` through `access(2)`.

- `Compile_Program` takes a `Modules` list instead of an `Obj_Dir`, and
  speaks ada83's command line directly: one Ada source plus any number of
  `.ll` modules compiled earlier, and `-o` for the output.

- `Go_Rebuild_Urself` loses its `Obj_Dir` parameter, which no longer
  means anything, and forwards the original argv through ada83's
  `Command_Line` vendor package.

- `Str`, an access-to-String with `+` as its allocator, replaces the `US`
  subtype and its `Ada.Strings.Unbounded` renaming.

- The default log handler writes `[TAG] msg` to stderr through `fputs`,
  since Ada 83 `Text_IO` has no `Standard_Error`.

### Added

- `Compile_Module`, which compiles one source to textual LLVM IR
  (`ada83 --ir`) — the form `Compile_Program` links through `Modules`.

- `Copy` and `Clear` on `Argument_List`, to do explicitly what
  finalization used to do implicitly.

- `Value (S : Str) return String`, mapping null to `""`.

### Removed

- The `Ada_Compiler` descriptor and everything shaped around it:
  `Gnatmake_Compiler`, `ObjectAda_Compiler`, `Janus_Compiler`,
  `Set_Compiler`, `Runtime_Probe_Kind`, `Source_Resolver_Kind` and
  `Find_Gnat_Runtime`. There is one compiler, `ada83`, taken from PATH.

- `Build_Static_Lib` and `Build_Shared_Lib`. ada83 emits executables and
  `.ll` modules and has no object-file or archive stage, so there is
  nothing for `ar` or `gcc -shared` to work on. A library here is an
  `.ll` module that dependent programs link alongside their own source.

- `Set_Log_Handler` and the `Log_Handler` access type. `Set_Log_Level`
  remains.

- The `windows/` directory. Its `dlopen`/`dlsym` shim existed so the
  Ada 95 edition could resolve syscalls through function pointers, which
  Ada 83 cannot express. See *Known limitations*.

### Fixed

- `"/"` no longer doubles a separator the left operand already ends with:
  `"foo/" / "bar"` gives `"foo/bar"`, not `"foo//bar"`.

### Platforms

- Every system call goes through a new `Platform_Support` package, whose
  body is chosen at bootstrap: `posix/` for Linux and macOS, `windows/`
  for Windows. Nothing above it names a syscall, a struct offset or an
  errno-style constant.

- Being POSIX is not enough to share a body blindly. Linux and macOS
  disagree about the layout of `struct stat` and `struct dirent`, about
  the values of `O_CREAT` and `O_TRUNC`, and about the `sysconf`
  selector for the processor count; the POSIX body answers each from
  `Host`.

### Known limitations

- Tested on Linux only. The macOS numbers come from the documented ABIs
  and the Windows body has never been run; treat both as unverified.

- On x86_64 macOS the C library exports `stat` as `stat$INODE64`. The
  POSIX body imports the plain name, correct on arm64 macOS and Linux.

### Compiler bugs found and fixed upstream

Porting the library surfaced five defects in ada83, each fixed in that
repository with ACATS holding at 3561/3561:

- A generic instantiated in another compilation unit emitted calls to
  package-body-local subprograms — and to `pragma Import` subprograms —
  without declaring them, so the IR did not parse. This blocks any
  generic whose body uses a private helper, which the directory iterators
  do.

- A slice took its extent from the prefix's type rather than its own
  range, so `Buf (1 .. Last)` of a `String (1 .. 32)` yielded 32
  characters when used to initialise an object or as an attribute prefix.
  Silent: the object held the right first character and a tail of
  whatever followed it in the array.

- A file whose first unit was a library subprogram body sharing the
  file's name compiled that subprogram twice when a later unit in the
  same file withed it, leaving one definition referring to locals it
  never declared.

- A name written without an actual parameter part resolved to whichever
  overload the package exported first, so the parameterless
  `Text_IO.End_Of_File` was rejected for want of a `File` argument.

- A user-defined unary operator was never offered an operand whose type
  comes from context, so `+"literal"` was rejected where
  `+String'("literal")` compiled. Binary operators already allowed for
  it; the unary case did not.

Two further departures from bare MIL-STD-1815A were added to ada83 for
this port: library subprograms carry a GNAT-style `_ada_` symbol prefix,
so a `procedure Main` cannot collide with the C entry point, and a
`Command_Line` vendor package exposes `argc`/`argv`.

### Testing

`tests/` holds one self-reporting program per phase of the port —
`test_phase1` through `test_phase4` — covering the core types and path
utilities, the process and filesystem layer, directory iteration, and the
compile layer. `tests/build_tests.adb` runs them, judging each on whether
it printed `PASSED` rather than on exit status alone. The examples under
`examples/` are built and run by `examples/build_all.adb`; both harnesses
are themselves No_Build programs, bootstrapped by `bootstrap_tests.sh`
and `bootstrap.sh`.

---

The releases below predate this port and describe the Ada 95 line, whose
history is preserved in git.

## 0.1.0 — 2026-05-19

First tagged release, targeting Ada 2012 and GNAT.
