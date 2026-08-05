--  platform_support.ads -- the operating system, as No_Build needs it.
--
--  One spec, one body per system:
--
--     linux/platform_support.adb          Linux, any architecture
--     macos-arm64/platform_support.adb    macOS on Apple silicon
--     macos-x86_64/platform_support.adb   macOS on Intel
--     windows/platform_support.adb        Windows
--
--  Pick one at bootstrap by compiling that directory's file; see
--  bootstrap.sh and bootstrap.cmd.  Nothing above this package knows a
--  struct layout, an errno-style constant or a syscall name, so porting
--  to another system means writing one more body and nothing else.
--
--  The bodies do not share a POSIX layer: Linux and macOS agree on most
--  of the text but disagree on enough of the arithmetic -- and, on Intel
--  macOS, on the symbol names -- that each states its own answers.
--
--  Operations that can fail report it in their result rather than
--  raising: No_Build owns the diagnostics and the Build_Error.

with System;

package Platform_Support is

   type Long is range -(2 ** 63) .. 2 ** 63 - 1;
   --  A 64-bit integer, for the values C hands back in one.

   type Host_Kind is (Linux, MacOS, Windows);

   function Host return Host_Kind;
   --  Settled when the body was chosen, not probed at run time.

   function Body_Dir return String;
   --  The directory this package's body was compiled from, relative to
   --  the project root: "linux", "macos-arm64", "macos-x86_64" or
   --  "windows".
   --
   --  This is the whole of what the bootstrap had to decide, carried in
   --  the program built from it: a build script recompiles this package
   --  without being told a system again.

   function Path_Separator return Character;
   function Shell_Program  return String;   --  "/bin/sh" or "cmd.exe"
   function Shell_Flag     return String;   --  "-c" or "/c"

   --------------------------------------------------------------------------
   --  Diagnostics
   --------------------------------------------------------------------------

   procedure Write_Error (Line : String);
   --  Write Line and a newline to standard error.  Ada 83 Text_IO has no
   --  Standard_Error, so this is the only way to reach it.

   --------------------------------------------------------------------------
   --  Processes
   --------------------------------------------------------------------------

   type Argv_Array is array (Positive range <>) of System.Address;
   --  Addresses of NUL-terminated strings.  Argv (1) names the program;
   --  the caller keeps the storage alive across the Spawn call.

   Spawn_Failed : constant Integer := -1;

   function Spawn
     (Argv     : Argv_Array;
      Out_Path : String;
      Err_Path : String) return Integer;
   --  Start a program and return a handle for Wait_For, or Spawn_Failed.
   --  An empty Out_Path or Err_Path inherits this process's stream;
   --  otherwise the child's stream is truncated onto that file.

   Wait_Failed : constant Integer := -1;

   function Wait_For (Handle : Integer) return Integer;
   --  Block until the process exits and return its exit status, or
   --  Wait_Failed if it was killed by a signal or could not be waited for.

   procedure Exit_Process (Status : Integer);

   function Process_Id return Integer;

   function Cpu_Count return Positive;

   --------------------------------------------------------------------------
   --  Files and directories
   --------------------------------------------------------------------------

   procedure File_Status
     (Path         : String;
      Found        : out Boolean;
      Is_Directory : out Boolean;
      Mtime_Sec    : out Long;
      Mtime_Nsec   : out Long);
   --  Mtime_Sec and Mtime_Nsec are meaningful only when Found; together
   --  they order two files in time, and nothing above reads them alone.

   function Exists (Path : String) return Boolean;

   function Make_Directory   (Path : String) return Boolean;
   function Remove_Directory (Path : String) return Boolean;
   function Remove_File      (Path : String) return Boolean;
   function Change_Directory (Path : String) return Boolean;
   function Rename_Path      (Old_Path, New_Path : String) return Boolean;

   function Working_Directory return String;
   --  "" if it cannot be determined.

   --------------------------------------------------------------------------
   --  Directory listing
   --------------------------------------------------------------------------

   Null_Dir : constant System.Address := System.Null_Address;

   function Is_Null (A : System.Address) return Boolean;
   --  True for Null_Dir and for any other address that denotes nothing.

   function Open_Dir (Path : String) return System.Address;
   --  Null_Dir when Path cannot be listed.

   procedure Read_Dir
     (Handle       : System.Address;
      Name         : out String;
      Last         : out Natural;
      Is_Directory : out Boolean;
      Is_File      : out Boolean);
   --  Last = 0 marks the end of the directory.  "." and ".." are
   --  reported like any other entry; callers skip them.

   procedure Close_Dir (Handle : System.Address);

end Platform_Support;
