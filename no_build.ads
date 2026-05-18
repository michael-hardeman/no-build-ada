--  no_build.ads -- Ada port of https://github.com/tsoding/nob.h.
--  See README.md for usage.

with System;
with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Finalization;
with Ada.Strings.Unbounded;

package No_Build is

   pragma Elaborate_Body;

   Build_Error : exception;
   --  Raised when any build step fails (non-zero exit code or OS error).

   --------------------------------------------------------------------------
   --  Platform
   --------------------------------------------------------------------------

   type Platform_Kind is (Linux, MacOS, Windows);

   --  Expression function (not body-side) so Platform's elaboration can
   --  call it.  WINDIR is Windows-only; /usr/bin/sw_vers ships on macOS only.
   function Detect_Platform return Platform_Kind is
     (if Ada.Environment_Variables.Exists ("WINDIR") then Windows
      elsif Ada.Directories.Exists ("/usr/bin/sw_vers") then MacOS
      else Linux);

   Platform : constant Platform_Kind := Detect_Platform;
   --  Use this instead of per-call OS checks.

   --------------------------------------------------------------------------
   --  Argument_List -- a Controlled, vector-backed container of strings.
   --  Memory is managed automatically: deep-copy on assignment, free on
   --  scope exit.  Build instances with the Args(...) constructors for the
   --  common case, or Append / & when growing dynamically.
   --------------------------------------------------------------------------

   type Argument_List is new Ada.Finalization.Controlled with private;

   function No_Args return Argument_List;
   --  Empty list.  Default for procedures that take an Argument_List.
   --  Defined as a function (not constant) so it satisfies the
   --  tag-indeterminate requirement for default parameter expressions of
   --  primitive operations on a tagged type.

   function Args (A : String)                            return Argument_List;
   function Args (A, B : String)                         return Argument_List;
   function Args (A, B, C : String)                      return Argument_List;
   function Args (A, B, C, D : String)                   return Argument_List;
   function Args (A, B, C, D, E : String)                return Argument_List;
   function Args (A, B, C, D, E, F : String)             return Argument_List;
   function Args (A, B, C, D, E, F, G : String)          return Argument_List;
   function Args (A, B, C, D, E, F, G, H : String)       return Argument_List;
   --  Convenience constructors for 1..8 elements.  Beyond eight, chain
   --  with & or use Append.

   procedure Append (List : in out Argument_List; Item  : String);
   procedure Append (List : in out Argument_List; Items : Argument_List);

   function "&" (Left, Right : Argument_List) return Argument_List;
   function "&" (Left : Argument_List; Right : String) return Argument_List;
   function "&" (Left : String; Right : Argument_List) return Argument_List;

   function Length  (List : Argument_List) return Natural;
   function Element (List : Argument_List; Index : Positive) return String;

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
      Args    : Argument_List := No_Args;
      Redir   : Redirect      := No_Redirect);
   --  Locate Program on PATH, run it with Args, and wait for it to finish.
   --  Prints "[CMD] program args..." to stderr before executing.
   --  Optionally redirects stdout/stderr to files via Redir.
   --  Raises Build_Error if the program is not found or exits non-zero.

   procedure Sh (Command : String);
   --  Run Command via the platform shell (/bin/sh on POSIX, cmd.exe on
   --  Windows).
   --
   --  WARNING: shell syntax is NOT portable.  The two shells disagree
   --  about almost everything.  Specifically:
   --
   --    * Pipes:           '|' works on both; '|&' is bash-only.
   --    * Sequencing:      '&&' and ';' on POSIX; '&&' and '&' on cmd.exe.
   --    * Variables:       $VAR / ${VAR} on POSIX vs %VAR% on cmd.exe.
   --    * Quoting:         'single' quotes are POSIX-only; cmd.exe knows
   --                       only double quotes and uses different escapes.
   --    * Globbing:        POSIX expands * before the program runs;
   --                       cmd.exe leaves * unexpanded for the program.
   --    * PATH separator:  ':' on POSIX vs ';' on Windows.
   --    * Slashes:         cmd.exe accepts both '/' and '\', but '/'
   --                       sometimes parses as a flag introducer.
   --
   --  For portable command execution prefer Cmd, which calls execv /
   --  CreateProcess directly with no shell in the loop.  If you need
   --  pipes or redirection, branch on Platform and emit two Sh calls --
   --  see examples/pipe.adb for the canonical pattern.

   function Capture
     (Program : String;
      Args    : Argument_List := No_Args) return String;
   --  Run Program with Args, capture stdout, and return it trimmed of
   --  leading/trailing whitespace.  Stderr is inherited.  Raises Build_Error
   --  on non-zero exit or if the program cannot be located.

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
     (Program : String;
      Args    : Argument_List := No_Args;
      Redir   : Redirect      := No_Redirect) return Proc;
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

   type Runtime_Probe_Func is access function return String;
   --  Returns a single token Build_Shared_Lib appends verbatim to the
   --  shared-link command line, e.g. a path to libgnat.  Null disables.

   function Find_Gnat_Runtime return String;
   --  Default Runtime_Probe_Func for GNAT: derives the adalib/libgnat path
   --  from `gcc -print-libgcc-file-name`.

   subtype US is Ada.Strings.Unbounded.Unbounded_String;
   function "+" (Str : String) return US
     renames Ada.Strings.Unbounded.To_Unbounded_String;
   --  Local shorthand for Ada.Strings.Unbounded.To_Unbounded_String, used
   --  in Ada_Compiler record literals.  Visible to users via `use No_Build;`.

   type Ada_Compiler is record
      Executable            : US;             --  e.g. "gnatmake"
      Compile_Flags         : Argument_List;  --  always passed
      PIC_Flags             : Argument_List;  --  added for shared libs
      Obj_Flag              : US;             --  selects obj dir
      Out_Flag              : US;             --  selects output binary
      Compile_Only_Flag     : US;             --  suppresses link
      Shared_Linker         : US;             --  shared-lib driver
      Shared_Flags          : Argument_List;  --  before Shared_Out_Flag
      Shared_Out_Flag       : US;             --  shared-lib output flag
      Shared_Runtime_Probe  : Runtime_Probe_Func := null;
      Static_Archiver       : US;             --  static-lib archiver
      Static_Archiver_Flags : Argument_List;
   end record;

   function Gnatmake_Compiler  return Ada_Compiler;
   --  Default GNAT descriptor; host-correct toolchain switches via Platform.
   --  Override any field to retarget another toolchain.

   function ObjectAda_Compiler return Ada_Compiler;
   --  PTC ObjectAda (formerly Aonix).  UNTESTED starting point; verify
   --  Obj_Flag / Compile_Only_Flag / driver name against your install.

   function Janus_Compiler     return Ada_Compiler;
   --  RR Software Janus/Ada.  UNTESTED.  Janus uses a separate compile/link
   --  pipeline; Executable likely needs to be a wrapper driving both steps.

   procedure Set_Compiler (C : Ada_Compiler);
   --  Replace the active compiler descriptor.

   procedure Compile_Program
     (Source  : String;
      Output  : String        := "";
      Obj_Dir : String        := "";
      Extra   : Argument_List := No_Args);
   --  Compile and link Source using the active compiler.  Empty Output lets
   --  the compiler pick the binary name; empty Obj_Dir puts objects in CWD.

   procedure Compile
     (Source  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := No_Args);
   --  Compile-only: passes Compile_Only_Flag (.o/.ali, no link).

   procedure Build_Static_Lib
     (Src_Dir : String;
      Output  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := No_Args);
   --  Compile every .adb in Src_Dir, then archive into Output via the active
   --  Static_Archiver (default "ar rcs").

   procedure Build_Shared_Lib
     (Src_Dir : String;
      Output  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := No_Args);
   --  Compile every .adb in Src_Dir with PIC_Flags, then link into Output
   --  via the active Shared_Linker.

   --------------------------------------------------------------------------
   --  Path utilities
   --------------------------------------------------------------------------

   function "/" (Left, Right : String) return String;
   --  Join two path components ("a" / "b" => "a/b" or "a\b" on Windows).

   function No_Ext    (Path : String) return String;
   --  Strip the trailing ".ext"; returns Path unchanged if no extension.

   function Ends_With (Str, Suffix : String) return Boolean;
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
   --  Return True when Output is missing or is older than any file in Inputs.

   --------------------------------------------------------------------------
   --  Directory iteration
   --------------------------------------------------------------------------

   procedure For_Each_File
     (Dir     : String;
      Process : not null access procedure (File_Name : String);
      Suffix  : String := "");
   --  Call Process(simple_name) for each entry in Dir whose name ends with
   --  Suffix.  Suffix => "" visits every entry (excluding "." / "..").

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

   procedure Walk_Dir
     (Root : String;
      Func : not null access function (E : Walk_Entry) return Walk_Action);
   --  Pre-order recursive walk of Root.  Func is an anonymous access so
   --  nested functions can be passed via 'Access without an accessibility
   --  failure (same convention as For_Each_File).

   --------------------------------------------------------------------------
   --  Logging
   --------------------------------------------------------------------------

   type Log_Handler is access procedure (Tag, Msg : String);

   procedure Set_Log_Handler (Handler : Log_Handler);
   --  Null restores the default handler ("[TAG] msg" on stderr).

   procedure Info  (Msg : String);  --  [INFO] to stderr
   procedure Warn  (Msg : String);  --  [WARN] to stderr
   procedure Erro  (Msg : String);  --  [ERRO] to stderr
   procedure Panic (Msg : String);  --  [ERRO] then raises Build_Error

   --------------------------------------------------------------------------
   --  Go_Rebuild_Urself(TM): call as the first statement in your build
   --  procedure.  If Source_Path is newer than Binary_Path, recompiles and
   --  re-execs, forwarding the original argv.
   --------------------------------------------------------------------------

   procedure Go_Rebuild_Urself
     (Binary_Path : String;
      Source_Path : String;
      Obj_Dir     : String        := "";
      Extra       : Argument_List := No_Args);

private

   package Arg_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   type Argument_List is new Ada.Finalization.Controlled with record
      Items : Arg_Vectors.Vector;
   end record;

   type Redirect is record
      Stdout : US;   --  empty = inherit
      Stderr : US;
   end record;

   No_Redirect : constant Redirect :=
     (Stdout => Ada.Strings.Unbounded.Null_Unbounded_String,
      Stderr => Ada.Strings.Unbounded.Null_Unbounded_String);

   type Proc is record
      Pid : System.Address := System.Null_Address;
   end record;

   Invalid_Proc : constant Proc := (Pid => System.Null_Address);

   package Proc_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Proc);

   type Proc_List is record
      Items : Proc_Vectors.Vector;
   end record;

end No_Build;
