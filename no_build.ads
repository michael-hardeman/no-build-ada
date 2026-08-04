--  no_build.ads -- Ada 83 port of https://github.com/tsoding/nob.h.
--  Targets the Ada83 compiler (MIL-STD-1815A plus the documented
--  Extension_Command_Line vendor package).  See README.md for usage.
--
--  Differences from the Ada 95+ edition of this library:
--    * For_Each_File and Walk_Dir are generics (Ada 83 has no
--      access-to-subprogram types).
--    * Argument_List is a plain private type: no controlled finalization,
--      so storage is reclaimed by Clear or at process exit.
--    * Build_Error carries no message text (Ada 83 exceptions cannot);
--      Panic and every raiser log through Erro first.
--    * Set_Log_Handler is gone; Set_Log_Level remains.
--    * Compiler probe/resolver hooks are enumerations rather than
--      function pointers.
--    * Platform is a function, not a constant (a spec constant cannot
--      call its own body's function during elaboration in Ada 83).

with System;

package No_Build is

   Version : constant String := "0.1.0-ada83";
   --  Library version.  Bump together with CHANGELOG.md on every change
   --  to the public spec or to observable behavior.

   Build_Error : exception;
   --  Raised when any build step fails (non-zero exit code or OS error).

   --------------------------------------------------------------------------
   --  Platform
   --------------------------------------------------------------------------

   type Platform_Kind is (Linux, MacOS, Windows);

   function Platform return Platform_Kind;
   --  Detected once on first call, then cached.  WINDIR is Windows-only;
   --  /usr/bin/sw_vers ships on macOS only.

   --------------------------------------------------------------------------
   --  Str -- heap string used in Ada_Compiler record literals.  "+" is the
   --  allocator shorthand; storage lives until process exit.
   --------------------------------------------------------------------------

   type Str is access String;

   function "+" (S : String) return Str;

   function Value (S : Str) return String;
   --  Null maps to "".

   --------------------------------------------------------------------------
   --  Argument_List -- a growable list of strings.  Build instances with
   --  the Args(...) constructors for the common case, or Append / & when
   --  growing dynamically.  Assignment shares storage; use Copy for a
   --  deep copy and Clear to release one explicitly.
   --------------------------------------------------------------------------

   type Argument_List is private;

   No_Args : constant Argument_List;
   --  Empty list.  Default for procedures that take an Argument_List.

   function Args (A : String)                      return Argument_List;
   function Args (A, B : String)                   return Argument_List;
   function Args (A, B, C : String)                return Argument_List;
   function Args (A, B, C, D : String)             return Argument_List;
   function Args (A, B, C, D, E : String)          return Argument_List;
   function Args (A, B, C, D, E, F : String)       return Argument_List;
   function Args (A, B, C, D, E, F, G : String)    return Argument_List;
   function Args (A, B, C, D, E, F, G, H : String) return Argument_List;
   --  Convenience constructors for 1..8 elements.  Beyond eight, chain
   --  with & or use Append.

   procedure Append (List : in out Argument_List; Item  : String);
   procedure Append (List : in out Argument_List; Items : Argument_List);

   function "&" (Left, Right : Argument_List) return Argument_List;
   function "&" (Left : Argument_List; Right : String) return Argument_List;
   function "&" (Left : String; Right : Argument_List) return Argument_List;

   function Length  (List : Argument_List) return Natural;
   function Element (List : Argument_List; Index : Positive) return String;

   function Copy  (List : Argument_List) return Argument_List;
   procedure Clear (List : in out Argument_List);
   --  Clear frees the list's storage and leaves it empty.  Other lists
   --  sharing the same storage (through assignment) must not be used
   --  afterwards.

   --------------------------------------------------------------------------
   --  Command execution
   --------------------------------------------------------------------------

   type Redirect is private;
   --  Captures optional stdout/stderr file paths.  Default state is
   --  "inherit both"; build other states with To_File.

   No_Redirect : constant Redirect;

   function To_File (Stdout : String := ""; Stderr : String := "")
     return Redirect;
   --  Empty path means "inherit"; non-empty means "redirect to that file".

   procedure Cmd
     (Program : String;
      Args     : Argument_List := No_Args;
      Redir    : Redirect      := No_Redirect);
   --  Locate Program on PATH, run it with Args, and wait for it to
   --  finish.  Prints "[CMD] program args..." to stderr before executing.
   --  Optionally redirects stdout/stderr to files via Redir.
   --  Raises Build_Error if the program is not found or exits non-zero.

   procedure Sh (Command : String);
   --  Run Command via the platform shell (/bin/sh on POSIX, cmd.exe on
   --  Windows).
   --
   --  WARNING: shell syntax is NOT portable.  The two shells disagree
   --  about almost everything (pipes, sequencing, variables, quoting,
   --  globbing, PATH separators, slashes).  For portable command
   --  execution prefer Cmd, which spawns directly with no shell in the
   --  loop.  If you need pipes or redirection, branch on Platform and
   --  emit two Sh calls -- see examples/pipe.adb.

   function Capture
     (Program  : String;
      Args     : Argument_List := No_Args) return String;
   --  Run Program with Args, capture stdout, and return it trimmed of
   --  leading/trailing whitespace.  Stderr is inherited.  Raises
   --  Build_Error on non-zero exit or if the program cannot be located.

   --------------------------------------------------------------------------
   --  Parallel process execution
   --------------------------------------------------------------------------

   type Proc is private;
   --  Handle to a running process returned by Cmd_Async.

   Invalid_Proc : constant Proc;
   --  Sentinel value returned when a process could not be spawned.

   type Proc_List is private;
   --  Growable list of Proc handles for batch waiting.

   function Cmd_Async
     (Program  : String;
      Args     : Argument_List := No_Args;
      Redir    : Redirect      := No_Redirect) return Proc;
   --  Spawn Program without waiting.  Returns a Proc handle.
   --  Raises Build_Error if the program is not found.

   procedure Wait (P : Proc);
   --  Block until P exits.  Raises Build_Error on non-zero exit.

   procedure Append   (List : in out Proc_List; P : Proc);
   --  Add a Proc handle to List.

   procedure Wait_All (List : in out Proc_List);
   --  Wait for every process in List, then clear it.
   --  Raises Build_Error if any process exits non-zero.

   function N_Procs return Positive;
   --  Return the number of logical CPU cores.  Useful for throttling
   --  parallel jobs: spawn at most N_Procs commands before Wait_All.

   --------------------------------------------------------------------------
   --  Ada compilation.  Compile_Program, Compile, and Build_*_Lib drive an
   --  Ada toolchain described by an Ada_Compiler record (default
   --  Gnatmake_Compiler).  Call Set_Compiler to retarget.
   --------------------------------------------------------------------------

   type Runtime_Probe_Kind is (No_Probe, Gnat_Runtime_Probe);
   --  Strategy Build_Shared_Lib uses to find a runtime token appended
   --  verbatim to the shared-link command line.  Gnat_Runtime_Probe
   --  derives the adalib/libgnat path from `gcc -print-libgcc-file-name`.

   function Find_Gnat_Runtime return String;
   --  The Gnat_Runtime_Probe implementation, callable directly.

   type Source_Resolver_Kind is (No_Resolver, Gnat_Spec_To_Body);
   --  Per-compiler rewrite applied by Build_Static_Lib / Build_Shared_Lib
   --  before invoking the compile.  Gnat_Spec_To_Body swaps a .ads for a
   --  sibling .adb when one exists, because gnatmake -c won't compile a
   --  bare spec next to a body.  No_Resolver uses Source as given.

   type Ada_Compiler is record
      Executable            : Str;            --  e.g. "gnatmake"
      Compile_Flags         : Argument_List;  --  always passed
      PIC_Flags             : Argument_List;  --  added for shared libs
      Obj_Flag              : Str;            --  selects obj dir
      Out_Flag              : Str;            --  selects output binary
      Compile_Only_Flag     : Str;            --  suppresses link
      Shared_Linker         : Str;            --  shared-lib driver
      Shared_Flags          : Argument_List;  --  before Shared_Out_Flag
      Shared_Out_Flag       : Str;            --  shared-lib output flag
      Shared_Runtime_Probe  : Runtime_Probe_Kind := No_Probe;
      Static_Archiver       : Str;            --  static-lib archiver
      Static_Archiver_Flags : Argument_List;

      --  File-extension conventions used by Build_*_Lib (collecting
      --  produced objects, resolving spec/body siblings).  Defaults
      --  match the de-facto GNAT convention; override for toolchains
      --  that emit .obj or use a different source-naming scheme.
      Source_Spec_Ext       : Str;
      Source_Body_Ext       : Str;
      Object_Ext            : Str;

      Resolve_Source        : Source_Resolver_Kind := No_Resolver;
   end record;

   function Gnatmake_Compiler  return Ada_Compiler;
   --  GNAT in Ada 83 mode (-gnat83); host-correct toolchain switches
   --  via Platform.  Override any field to retarget another toolchain.

   function Ada83_Compiler     return Ada_Compiler;
   --  The Ada83 single-file LLVM compiler this port targets.

   procedure Set_Compiler (C : Ada_Compiler);
   --  Replace the active compiler descriptor.

   procedure Compile_Program
     (Source  : String;
      Output  : String        := "";
      Obj_Dir : String        := "";
      Extra   : Argument_List := No_Args);
   --  Compile and link Source using the active compiler.  Empty Output
   --  lets the compiler pick the binary name; empty Obj_Dir puts objects
   --  in CWD.

   procedure Compile
     (Source  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := No_Args);
   --  Compile-only: passes Compile_Only_Flag (no link).

   procedure Build_Static_Lib
     (Source  : String;
      Output  : String;
      Obj_Dir : String;
      Extra   : Argument_List := No_Args);
   --  Compile Source (a root unit) and its with-closure into a dedicated
   --  "<stem>_static" subdirectory of Obj_Dir, then archive every object
   --  file found there into Output via the active Static_Archiver
   --  (default "ar rcs").  See the Ada 95 edition's spec for the full
   --  contract; behavior is unchanged.

   procedure Build_Shared_Lib
     (Source  : String;
      Output  : String;
      Obj_Dir : String;
      Extra   : Argument_List := No_Args);
   --  As Build_Static_Lib, but compiles with PIC_Flags into "<stem>_pic"
   --  and links the collected objects into Output via the active
   --  Shared_Linker.  When Shared_Runtime_Probe is not No_Probe its
   --  result is appended so the Ada runtime is embedded.

   --------------------------------------------------------------------------
   --  Path utilities
   --------------------------------------------------------------------------

   function "/" (Left, Right : String) return String;
   --  Join two path components ("a" / "b" => "a/b" or "a\b" on Windows).

   function No_Ext    (Path : String) return String;
   --  Strip the trailing ".ext"; returns Path unchanged if no extension.

   function Ends_With (S, Suffix : String) return Boolean;
   function Base_Name (Path : String) return String;
   --  Final path component (after the last '/' or '\').

   --------------------------------------------------------------------------
   --  Filesystem predicates
   --------------------------------------------------------------------------

   function Path_Exists (Path : String) return Boolean;
   function Is_Dir      (Path : String) return Boolean;

   --------------------------------------------------------------------------
   --  Filesystem mutations
   --------------------------------------------------------------------------

   procedure Make_Dir  (Path : String);  --  warns if Path already exists
   procedure Make_Dirs (Path : String);  --  also creates parents

   procedure Rename_Path (Old_Path, New_Path : String);
   procedure Remove_Path (Path : String);   --  recursive for directories

   procedure Copy_File (Src, Dst : String);  --  overwrites Dst
   procedure Copy_Dir  (Src, Dst : String);  --  recursive

   function  Read_File  (Path : String) return String;
   procedure Write_File (Path : String; Contents : String);
   --  Raise Build_Error on I/O failure.

   function  Get_Current_Dir return String;
   procedure Set_Current_Dir (Path : String);  --  raises Build_Error

   --------------------------------------------------------------------------
   --  Dependency checking
   --------------------------------------------------------------------------

   function Is_Newer (Path1, Path2 : String) return Boolean;
   --  Return True when Path1's mtime is strictly after Path2's mtime.
   --  Returns True  when Path2 does not exist (always needs rebuild).
   --  Returns False when Path1 does not exist.

   function Needs_Rebuild (Output : String; Inputs : Argument_List)
     return Boolean;
   --  Return True when Output is missing or is older than any file in
   --  Inputs.

   --------------------------------------------------------------------------
   --  Directory iteration.  Both are generics: instantiate with the
   --  subprogram to run, then call the instance.
   --
   --     procedure Show (File_Name : String);
   --     procedure Show_All is new No_Build.For_Each_File (Show);
   --     ...
   --     Show_All ("src", ".adb");
   --------------------------------------------------------------------------

   generic
      with procedure Process (File_Name : String);
   procedure For_Each_File (Dir : String; Suffix : String := "");
   --  Call Process(simple_name) for each entry in Dir whose name ends
   --  with Suffix.  Suffix => "" visits every entry (excluding "." and
   --  "..").

   type Walk_Action is (Walk_Continue, Walk_Skip, Walk_Stop);
   --  Walk_Skip skips a directory's subtree; Walk_Stop aborts the walk.

   type File_Kind is (Regular_File, Directory, Symlink, Other);
   --  Symlink is reserved; this implementation never returns it.

   type Walk_Entry (Path_Len, Name_Len : Natural) is record
      Path  : String (1 .. Path_Len);   --  full path relative to root
      Name  : String (1 .. Name_Len);   --  simple name
      Kind  : File_Kind;
      Depth : Natural;                  --  0 = entries directly inside root
   end record;

   generic
      with function Func (E : Walk_Entry) return Walk_Action;
   procedure Walk_Dir (Root : String);
   --  Pre-order recursive walk of Root.

   --------------------------------------------------------------------------
   --  Logging
   --------------------------------------------------------------------------

   type Log_Level is (Verbose, Normal, Quiet, Silent);
   --  Filter applied before a message is written:
   --    Verbose -- default; every tag including [CMD], [MKDIR], [CP], ...
   --    Normal  -- [INFO], [WARN], [ERRO] only
   --    Quiet   -- [WARN], [ERRO] only
   --    Silent  -- nothing.

   procedure Set_Log_Level (Level : Log_Level);
   --  Default is Verbose.  Use Normal (or lower) to silence the
   --  per-command [CMD] echo.

   procedure Info  (Msg : String);  --  [INFO] to stderr
   procedure Warn  (Msg : String);  --  [WARN] to stderr
   procedure Erro  (Msg : String);  --  [ERRO] to stderr
   procedure Panic (Msg : String);  --  [ERRO] then raises Build_Error

   --------------------------------------------------------------------------
   --  Go_Rebuild_Urself(TM): call as the first statement in your build
   --  procedure.  If Source_Path is newer than Binary_Path, recompiles
   --  and re-execs, forwarding the original argv (via
   --  Extension_Command_Line).
   --------------------------------------------------------------------------

   procedure Go_Rebuild_Urself
     (Binary_Path : String;
      Source_Path : String;
      Obj_Dir     : String        := "";
      Extra       : Argument_List := No_Args);

private

   type Str_Array is array (Positive range <>) of Str;
   type Str_Array_Access is access Str_Array;

   type Argument_List is record
      Items : Str_Array_Access;   --  null when Count = 0
      Count : Natural := 0;
   end record;

   No_Args : constant Argument_List := (Items => null, Count => 0);

   type Redirect is record
      Stdout : Str;   --  null = inherit
      Stderr : Str;
   end record;

   No_Redirect : constant Redirect := (Stdout => null, Stderr => null);

   type Proc is record
      Pid : Integer := -1;
   end record;

   Invalid_Proc : constant Proc := (Pid => -1);

   type Proc_Array is array (Positive range <>) of Proc;
   type Proc_Array_Access is access Proc_Array;

   type Proc_List is record
      Items : Proc_Array_Access;
      Count : Natural := 0;
   end record;

end No_Build;
