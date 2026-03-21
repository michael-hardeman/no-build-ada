--  no_build.ads -- Ada port of the nobuild build-system library
--  https://github.com/tsoding/nobuild
--
--  Usage
--  -----
--  1. Place no_build.ads and no_build.adb next to your build script.
--  2. Write a build.adb that withs No_Build and contains a main procedure.
--  3. Bootstrap once:  gnatmake build.adb -o build && ./build
--  4. From then on just run ./build -- it will recompile itself if build.adb
--     has been modified (Go_Rebuild_Urself technology).

with GNAT.OS_Lib;

package No_Build is

   Build_Error : exception;

   --------------------------------------------------------------------------
   --  Platform
   --------------------------------------------------------------------------

   type Platform_Kind is (Linux, Windows);

   function Detect_Platform return Platform_Kind is
     (if GNAT.OS_Lib.Directory_Separator = '/' then Linux else Windows);
   --  Detect the current platform; evaluated at elaboration time.

   Platform : constant Platform_Kind := Detect_Platform;
   --  Package-wide constant; use this instead of runtime OS checks.
   --  Raised when any build step fails (non-zero exit code or OS error).

   --------------------------------------------------------------------------
   --  Argument-list helpers
   --
   --  GNAT.OS_Lib.Argument_List is array (Positive range <>) of String_Access.
   --  Use S("text") to heap-allocate individual strings, then build lists
   --  with Ada array aggregates and the built-in & concatenation, e.g.:
   --
   --    Cmd ("gnatmake", (S ("main.adb"), S ("-O2")));
   --    Cmd ("gnatmake", S ("main.adb") & Extra_Flags);
   --------------------------------------------------------------------------

   subtype Argument_List is GNAT.OS_Lib.Argument_List;
   subtype String_Access is GNAT.OS_Lib.String_Access;

   function S (Str : String) return String_Access;
   --  Heap-allocate Str; convenience for building Argument_List literals.

   --------------------------------------------------------------------------
   --  Command execution
   --------------------------------------------------------------------------

   procedure Cmd (Program : String; Args : Argument_List);
   --  Locate Program on PATH, run it with Args, and wait for it to finish.
   --  Prints "[CMD] program args..." to stderr before executing.
   --  Raises Build_Error if the program is not found or exits non-zero.

   procedure Cmd (Program : String);
   --  Run Program with no arguments.

   procedure Sh (Command : String);
   --  Run Command via /bin/sh -c "Command".

   --------------------------------------------------------------------------
   --  I/O redirection
   --------------------------------------------------------------------------

   type Redirect is record
      Stdout : String_Access := null;  --  file to receive stdout (null = inherit)
      Stderr : String_Access := null;  --  file to receive stderr (null = inherit)
   end record;

   No_Redirect : constant Redirect := (Stdout => null, Stderr => null);

   procedure Cmd
     (Program : String;
      Args    : Argument_List;
      Redir   : Redirect);
   --  Like Cmd, but stdout and/or stderr are redirected to files.

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

   function  Cmd_Async
     (Program : String;
      Args    : Argument_List;
      Redir   : Redirect := No_Redirect) return Proc;
   --  Spawn Program without waiting.  Returns a Proc handle.
   --  Raises Build_Error if the program is not found.

   function  Cmd_Async (Program : String) return Proc;
   --  Spawn Program with no arguments.

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
   --  Ada-specific: compile with gnatmake
   --------------------------------------------------------------------------

   procedure Compile
     (Source  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null));
   --  Compile Source and its dependencies without linking (-c).
   --  Produces .o and .ali files only.

   procedure Build_Static_Lib
     (Src_Dir : String;
      Output  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null));
   --  Compile every .adb in Src_Dir with -c, then archive the objects into
   --  a static library at Output (e.g. "lib/libfoo.a") using ar(1).

   procedure Build_Shared_Lib
     (Src_Dir : String;
      Output  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null));
   --  Compile every .adb in Src_Dir with -c -fPIC, then link the objects
   --  into a shared library at Output (e.g. "lib/libfoo.so") using gcc -shared.

   procedure Gnatmake
     (Source  : String;
      Output  : String        := "";
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null));
   --  Compile the Ada main source file Source using gnatmake.
   --  If Output  is non-empty, passes "-o Output".
   --  If Obj_Dir is non-empty, passes "-D Obj_Dir" (all .o/.ali files go
   --  there) and creates the directory if it does not already exist.
   --  Extra args are appended to the gnatmake invocation.

   --------------------------------------------------------------------------
   --  Path utilities
   --------------------------------------------------------------------------

   function "/" (Left, Right : String) return String;
   --  Join two path components: "a" / "b" => "a/b".

   function No_Ext (Path : String) return String;
   --  Strip the file extension (last "." and everything after it).
   --  Returns Path unchanged if there is no extension.

   function Ends_With (Str, Suffix : String) return Boolean;
   --  Return True when Str ends with Suffix.

   function Base_Name (Path : String) return String;
   --  Return the final component of Path (after the last '/').

   --------------------------------------------------------------------------
   --  Filesystem predicates
   --------------------------------------------------------------------------

   function Path_Exists (Path : String) return Boolean;
   function Is_Dir      (Path : String) return Boolean;

   --------------------------------------------------------------------------
   --  Filesystem mutations
   --------------------------------------------------------------------------

   procedure Make_Dir  (Path : String);
   --  Create directory Path.  Warns (does not raise) if it already exists.

   procedure Make_Dirs (Path : String);
   --  Create Path and all missing intermediate directories.

   procedure Rename_Path (Old_Path, New_Path : String);
   --  Rename/move a file or directory.

   procedure Remove_Path (Path : String);
   --  Recursively remove Path (file or directory tree).

   procedure Copy_File (Src, Dst : String);
   --  Copy the file at Src to Dst, overwriting Dst if it already exists.

   procedure Copy_Dir (Src, Dst : String);
   --  Recursively copy directory Src into Dst, creating Dst if needed.

   function  Read_File  (Path : String) return String;
   --  Read the entire contents of Path and return them as a String.
   --  Raises Build_Error if the file cannot be opened.

   procedure Write_File (Path : String; Contents : String);
   --  Write Contents to Path, creating or overwriting the file.
   --  Raises Build_Error if the file cannot be written.

   function  Get_Current_Dir return String;
   --  Return the current working directory.

   procedure Set_Current_Dir (Path : String);
   --  Change the current working directory to Path.
   --  Raises Build_Error if the directory does not exist.

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
   --  Equivalent to calling Is_Newer (Input, Output) for each input.

   --------------------------------------------------------------------------
   --  Directory iteration
   --------------------------------------------------------------------------

   procedure For_Each_File
     (Dir     : String;
      Process : not null access procedure (File_Name : String);
      Suffix  : String := "");
   --  Call Process(simple_name) for every entry in Dir whose name ends with
   --  Suffix.  Pass Suffix => "" to visit every entry (excluding "." / "..").

   type Walk_Action is (Walk_Continue, Walk_Skip, Walk_Stop);
   --  Walk_Continue -- keep going
   --  Walk_Skip     -- skip this directory's subtree (ignored for files)
   --  Walk_Stop     -- abort the entire walk immediately

   type File_Kind is (Regular_File, Directory, Symlink, Other);

   type Walk_Entry is record
      Path  : String_Access;  --  full path relative to the walk root
      Name  : String_Access;  --  simple name (final component)
      Kind  : File_Kind;
      Depth : Natural;        --  0 = entries directly inside root
   end record;

   type Walk_Func is
     not null access function (E : Walk_Entry) return Walk_Action;

   procedure Walk_Dir (Root : String; Func : Walk_Func);
   --  Recursively walk Root in pre-order, calling Func for each entry.
   --  Returning Walk_Skip from Func on a Directory prevents descending into it.
   --  Returning Walk_Stop aborts the entire walk immediately.

   --------------------------------------------------------------------------
   --  Logging
   --------------------------------------------------------------------------

   type Log_Handler is access procedure (Tag, Msg : String);
   --  Signature for a custom log handler.  Tag is the bracketed label
   --  (e.g. "INFO", "ERRO"); Msg is the message text.

   procedure Set_Log_Handler (Handler : Log_Handler);
   --  Replace the active log handler.  Pass null to restore the default
   --  handler, which writes "[TAG] msg" to stderr.

   procedure Info  (Msg : String);  --  [INFO] to stderr
   procedure Warn  (Msg : String);  --  [WARN] to stderr
   procedure Erro  (Msg : String);  --  [ERRO] to stderr
   procedure Panic (Msg : String);  --  [ERRO] to stderr, then raises Build_Error

   --------------------------------------------------------------------------
   --  Go Rebuild Urself(TM)
   --
   --  Call this as the very first statement in your build procedure.
   --  If Source_Path is newer than Binary_Path the build script is
   --  recompiled with gnatmake and then re-executed (via execv), passing
   --  through the original command-line arguments.  Only needs bootstrapping
   --  once; after that ./build is self-maintaining.
   --------------------------------------------------------------------------

   procedure Go_Rebuild_Urself
     (Binary_Path : String;
      Source_Path : String;
      Obj_Dir     : String        := "";
      Extra       : Argument_List := (1 .. 0 => null));
   --  Extra args (e.g. "-Ilinux/") are forwarded to the internal gnatmake
   --  call that recompiles the build script.

private

   type Proc is record
      Pid : GNAT.OS_Lib.Process_Id := GNAT.OS_Lib.Invalid_Pid;
   end record;

   Invalid_Proc : constant Proc := (Pid => GNAT.OS_Lib.Invalid_Pid);

   type Proc_Array is array (1 .. Max_Procs) of Proc;

   type Proc_List is record
      Items : Proc_Array := (others => Invalid_Proc);
      Count : Natural    := 0;
   end record;

end No_Build;
