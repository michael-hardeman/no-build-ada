--  no_build.ads -- Ada port of https://github.com/tsoding/nob.h.  
--  See README.md for usage.

with System;
with Ada.Directories;
with Ada.Environment_Variables;

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
   --  Argument-list helpers.  Build lists with aggregates / &, allocating
   --  each string with S, e.g. Cmd ("gnatmake", (S ("main.adb"), S ("-O2"))).
   --------------------------------------------------------------------------

   type String_Access is access String;
   type Argument_List is
     array (Positive range <>) of not null String_Access;
   type Argument_List_Access is access Argument_List;

   function S (Str : String) return not null String_Access;

   --  Empty argument list.
   No_Args : constant Argument_List := (1 .. 0 => new String'(""));

   --------------------------------------------------------------------------
   --  Command execution
   --------------------------------------------------------------------------

   type Redirect is record
      Stdout : String_Access := null;  --  file to receive stdout (null = inherit)
      Stderr : String_Access := null;  --  file to receive stderr (null = inherit)
   end record;

   No_Redirect : constant Redirect := (Stdout => null, Stderr => null);

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
   --  Windows).  Shell syntax is not portable; for portable command
   --  execution prefer Cmd, which avoids the shell entirely.

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

   Max_Procs : constant := 256;

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
   --  Add a Proc handle to List.  Raises Build_Error if List is full.

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

   type Ada_Compiler is record
      Executable            : not null String_Access;         --  e.g. "gnatmake"
      Compile_Flags         : not null Argument_List_Access;  --  always passed
      PIC_Flags             : not null Argument_List_Access;  --  added for shared libs
      Obj_Flag              : not null String_Access;         --  selects obj dir
      Out_Flag              : not null String_Access;         --  selects output binary
      Compile_Only_Flag     : not null String_Access;         --  suppresses link
      Shared_Linker         : not null String_Access;         --  shared-lib driver
      Shared_Flags          : not null Argument_List_Access;  --  before Shared_Out_Flag
      Shared_Out_Flag       : not null String_Access;         --  shared-lib output flag
      Shared_Runtime_Probe  : Runtime_Probe_Func;             --  null = no probe
      Static_Archiver       : not null String_Access;         --  static-lib archiver
      Static_Archiver_Flags : not null Argument_List_Access;
   end record;

   Gnatmake_Compiler : constant Ada_Compiler :=
     (Executable            => new String'("gnatmake"),
      Compile_Flags         => new Argument_List'(No_Args),
      PIC_Flags             =>
        (case Platform is
           when Linux | MacOS =>
             new Argument_List'(1 => new String'("-fPIC")),
           when Windows =>
             new Argument_List'(No_Args)),
      Obj_Flag              => new String'("-D"),
      Out_Flag              => new String'("-o"),
      Compile_Only_Flag     => new String'("-c"),
      Shared_Linker         => new String'("gcc"),
      Shared_Flags          =>
        (case Platform is
           when MacOS =>
             new Argument_List'(new String'("-dynamiclib"),
                                new String'("-undefined"),
                                new String'("dynamic_lookup")),
           when Linux | Windows =>
             new Argument_List'(1 => new String'("-shared"))),
      Shared_Out_Flag       => new String'("-o"),
      Shared_Runtime_Probe  => Find_Gnat_Runtime'Access,
      Static_Archiver       => new String'("ar"),
      Static_Archiver_Flags => new Argument_List'(1 => new String'("rcs")));
   --  Default descriptor; host-correct toolchain switches via Platform.
   --  Override any field to retarget another toolchain.

   --  PTC ObjectAda (formerly Aonix).  UNTESTED starting point; verify
   --  Obj_Flag / Compile_Only_Flag / driver name against your install.
   ObjectAda_Compiler : constant Ada_Compiler :=
     (Executable            => new String'("adabuild"),
      Compile_Flags         => new Argument_List'(No_Args),
      PIC_Flags             =>
        (case Platform is
           when Linux | MacOS =>
             new Argument_List'(1 => new String'("-fpic")),
           when Windows =>
             new Argument_List'(No_Args)),
      Obj_Flag              => new String'("-D"),
      Out_Flag              => new String'("-o"),
      Compile_Only_Flag     => new String'("-c"),
      Shared_Linker         => new String'("gcc"),
      Shared_Flags          =>
        (case Platform is
           when MacOS =>
             new Argument_List'(new String'("-dynamiclib"),
                                new String'("-undefined"),
                                new String'("dynamic_lookup")),
           when Linux | Windows =>
             new Argument_List'(1 => new String'("-shared"))),
      Shared_Out_Flag       => new String'("-o"),
      Shared_Runtime_Probe  => Find_Gnat_Runtime'Access,
      Static_Archiver       => new String'("ar"),
      Static_Archiver_Flags => new Argument_List'(1 => new String'("rcs")));

   --  RR Software Janus/Ada.  UNTESTED.  Janus uses a separate compile/link
   --  pipeline; Executable likely needs to be a wrapper driving both steps.
   Janus_Compiler : constant Ada_Compiler :=
     (Executable            => new String'("janus"),
      Compile_Flags         => new Argument_List'(No_Args),
      PIC_Flags             => new Argument_List'(No_Args),
      Obj_Flag              => new String'("/OBJDIR="),
      Out_Flag              => new String'("/OUT="),
      Compile_Only_Flag     => new String'("/COMPILE"),
      Shared_Linker         => new String'("gcc"),
      Shared_Flags          => new Argument_List'(1 => new String'("-shared")),
      Shared_Out_Flag       => new String'("-o"),
      Shared_Runtime_Probe  => null,
      Static_Archiver       => new String'("ar"),
      Static_Archiver_Flags => new Argument_List'(1 => new String'("rcs")));

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

   type Walk_Entry is record
      Path  : String_Access;  --  full path relative to root
      Name  : String_Access;  --  simple name
      Kind  : File_Kind;
      Depth : Natural;        --  0 = entries directly inside root
   end record;

   type Walk_Func is
     not null access function (E : Walk_Entry) return Walk_Action;

   procedure Walk_Dir (Root : String; Func : Walk_Func);
   --  Pre-order recursive walk of Root.

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

   type Proc is record
      Pid : System.Address := System.Null_Address;
   end record;

   Invalid_Proc : constant Proc := (Pid => System.Null_Address);

   type Proc_Array is array (1 .. Max_Procs) of Proc;

   type Proc_List is record
      Items : Proc_Array := (others => Invalid_Proc);
      Count : Natural    := 0;
   end record;

end No_Build;
