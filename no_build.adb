--  no_build.adb -- Ada 83 port.
--
--  Every system call is in this file.  Both systems are compiled into
--  every build: a symbol a target does not have is left unimported by
--  the ENABLED argument of its pragma IMPORT, and every call to it sits
--  behind a static condition on System.TARGET_OS.  One body of this
--  library serves every target.

with Command_Line;
with System;
with Unchecked_Conversion;
with Unchecked_Deallocation;

package body No_Build is

   --  No_Build's own 64-bit integer, so its operators are directly
   --  visible here; values crossing the OS boundary are converted.
   type Long is range -(2 ** 63) .. 2 ** 63 - 1;

   Active_Level : Log_Level := Verbose;

   Compiler : constant String := "ada83";

   --------------------------------------------------------------------------
   --  The C library's file streams.  These are the same everywhere the C
   --  standard reaches, so they sit outside the section above.
   --------------------------------------------------------------------------

   function C_Fopen (Path : System.Address; Mode : System.Address)
     return System.Address;
   pragma Import (C, C_Fopen, "fopen");

   function C_Fclose (Stream : System.Address) return Integer;
   pragma Import (C, C_Fclose, "fclose");

   function C_Fread (Buffer : System.Address; Size, Count : Long;
                     Stream : System.Address) return Long;
   pragma Import (C, C_Fread, "fread");

   function C_Fwrite (Buffer : System.Address; Size, Count : Long;
                      Stream : System.Address) return Long;
   pragma Import (C, C_Fwrite, "fwrite");

   function C_Fseek (Stream : System.Address; Offset : Long;
                     Whence : Integer) return Integer;
   pragma Import (C, C_Fseek, "fseek");

   function C_Ftell (Stream : System.Address) return Long;
   pragma Import (C, C_Ftell, "ftell");

   Seek_Set : constant Integer := 0;
   Seek_End : constant Integer := 2;

   --------------------------------------------------------------------------
   --  Directory primitives, declared here because the compile layer reads
   --  a build's object directory with them and Ada 83 wants every basic
   --  declaration ahead of the first body.
   --------------------------------------------------------------------------

   function Open_Dir_Or_Panic (Path : String) return System.Address;

   procedure Next_Dir_Entry
     (Dir        : System.Address;
      Name_Buf   : out String;
      Name_Last  : out Natural;
      Entry_Type : out Integer);

   function Entry_Kind (Full_Path : String; Entry_Type : Integer)
     return File_Kind;

   procedure Close_Dir (Handle : System.Address);

   --------------------------------------------------------------------------
   --  The operating system.
   --
   --  Every system No_Build runs on is here at once.  Which entry points
   --  exist is decided by the ENABLED argument on each pragma IMPORT: a
   --  symbol this target does not have is left unimported, so nothing
   --  demands it of the linker, and every call to it sits behind a static
   --  condition on System.TARGET_OS that cannot be taken here.  Both are
   --  resolved and checked whatever the target, so the one that is not
   --  this target's cannot rot unnoticed.
   --
   --  Nothing outside this section names a syscall, a struct offset or an
   --  errno-style constant.  The Sys_ operations are the whole of what
   --  the rest of this body may use.
   --------------------------------------------------------------------------

   type Argv_Array is array (Positive range <>) of System.Address;
   --  Addresses of NUL-terminated strings.  Argv (1) names the program;
   --  the caller keeps the storage alive across the call.

   Spawn_Failed : constant Integer := -1;
   Wait_Failed  : constant Integer := -1;
   Null_Dir     : constant System.Address := System.Null_Address;

   function Sys_Path_Separator return Character;
   function Sys_Shell_Program return String;
   function Sys_Shell_Flag return String;
   procedure Sys_Write_Error
     (Line : String);
   function Sys_Spawn
     (Argv : Argv_Array;
      Out_Path : String;
      Err_Path : String) return Integer;
   function Sys_Wait_For
     (Handle : Integer) return Integer;
   procedure Sys_Exit_Process
     (Status : Integer);
   function Sys_Process_Id return Integer;
   function Sys_Cpu_Count return Positive;
   function Sys_Exists
     (Path : String) return Boolean;
   function Sys_Make_Directory
     (Path : String) return Boolean;
   function Sys_Remove_Directory
     (Path : String) return Boolean;
   function Sys_Remove_File
     (Path : String) return Boolean;
   function Sys_Change_Directory
     (Path : String) return Boolean;
   function Sys_Rename_Path
     (Old_Path : String;
      New_Path : String) return Boolean;
   function Sys_Working_Directory return String;
   function Sys_Is_Null
     (A : System.Address) return Boolean;
   function Sys_Open_Dir
     (Path : String) return System.Address;
   procedure Sys_Close_Dir
     (Handle : System.Address);
   procedure Sys_File_Status
     (Path         : String;
      Found        : out Boolean;
      Is_Directory : out Boolean;
      Mtime_Sec    : out Long;
      Mtime_Nsec   : out Long);

   procedure Sys_Read_Dir
     (Handle       : System.Address;
      Name         : out String;
      Last         : out Natural;
      Is_Directory : out Boolean;
      Is_File      : out Boolean);

   --------------------------------------------------------------------------
   --  Linux and macOS
   --------------------------------------------------------------------------


   --  struct stat and struct dirent read as words and as bytes; the
   --  offsets below index these.
   type Posix_Word_Array is array (1 .. 32) of Long;
   type Posix_Byte_Array is array (1 .. 1200) of Character;
   type Posix_Byte_Array_Ptr is access Posix_Byte_Array;

   Dirent_Words : Posix_Word_Array;

   Dirent_Type_Unknown   : constant Integer := 0;
   Dirent_Type_Directory : constant Integer := 4;
   Dirent_Type_Regular   : constant Integer := 8;

   --------------------------------------------------------------------------
   --  C
   --------------------------------------------------------------------------

   function C_Access (Path : System.Address; Mode : Integer) return Integer;
   pragma Import (C, C_Access, "access",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Fputs (S : System.Address; Stream : System.Address)
     return Integer;
   pragma Import (C, C_Fputs, "fputs",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Stderr return System.Address;
   pragma Import (C, C_Stderr, "__ada_stderr",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Fork return Integer;
   pragma Import (C, C_Fork, "fork",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Execvp (File : System.Address; Argv : System.Address)
     return Integer;
   pragma Import (C, C_Execvp, "execvp",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Waitpid (Pid : Integer; Status : System.Address;
                       Options : Integer) return Integer;
   pragma Import (C, C_Waitpid, "waitpid",
                  Enabled => System.Target_OS /= System.Windows);

   procedure C_Exit (Status : Integer);
   pragma Import (C, C_Exit, "_exit",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Open (Path : System.Address; Flags : Integer; Mode : Integer)
     return Integer;
   pragma Import (C, C_Open, "open",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Close (Fd : Integer) return Integer;
   pragma Import (C, C_Close, "close",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Dup2 (Old_Fd, New_Fd : Integer) return Integer;
   pragma Import (C, C_Dup2, "dup2",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Getpid return Integer;
   pragma Import (C, C_Getpid, "getpid",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Sysconf (Name : Integer) return Long;
   pragma Import (C, C_Sysconf, "sysconf",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Mkdir (Path : System.Address; Mode : Integer) return Integer;
   pragma Import (C, C_Mkdir, "mkdir",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Rmdir (Path : System.Address) return Integer;
   pragma Import (C, C_Rmdir, "rmdir",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Unlink (Path : System.Address) return Integer;
   pragma Import (C, C_Unlink, "unlink",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Rename (Old_Path, New_Path : System.Address) return Integer;
   pragma Import (C, C_Rename, "rename",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Chdir (Path : System.Address) return Integer;
   pragma Import (C, C_Chdir, "chdir",
                  Enabled => System.Target_OS /= System.Windows);

   function C_Getcwd (Buffer : System.Address; Size : Long)
     return System.Address;
   pragma Import (C, C_Getcwd, "getcwd",
                  Enabled => System.Target_OS /= System.Windows);

   --  closedir takes no struct and is exported under the plain name
   --  everywhere, so unlike opendir and readdir_r it stays here.
   function C_Closedir (Dir : System.Address) return Integer;
   pragma Import (C, C_Closedir, "closedir",
                  Enabled => System.Target_OS /= System.Windows);

   function Posix_To_Long is new Unchecked_Conversion (System.Address, Long);
   function Posix_To_Bytes is
     new Unchecked_Conversion (System.Address, Posix_Byte_Array_Ptr);

   --  x86_64 macOS keeps a pre-64-bit-inode stat, opendir and readdir_r
   --  under the plain names and the modern ones under a $INODE64 suffix;
   --  the C headers rename onto the suffixed symbols, which pragma Import
   --  does not do.  Every other target has only the plain names, where
   --  this slice is empty.
   Suffix_Text : constant String := "$INODE64";
   Suffix_Last : constant :=
     8 * Boolean'Pos (System.Target_OS  = System.MacOS and
                      System.Target_Cpu = System.X86_64);

   Inode : constant String := Suffix_Text (1 .. Suffix_Last);

   function C_Stat (Path : System.Address; Buf : System.Address)
     return Integer;
   pragma Import (C, C_Stat, "stat" & Inode,
                  Enabled => System.Target_OS /= System.Windows);

   function C_Opendir (Path : System.Address) return System.Address;
   pragma Import (C, C_Opendir, "opendir" & Inode,
                  Enabled => System.Target_OS /= System.Windows);

   function C_Readdir_R (Dir : System.Address; Entry_Buf : System.Address;
                         Result : System.Address) return Integer;
   pragma Import (C, C_Readdir_R, "readdir_r" & Inode,
                  Enabled => System.Target_OS /= System.Windows);

   --------------------------------------------------------------------------
   --  Windows
   --------------------------------------------------------------------------


   type Win_Byte_Array is array (1 .. 1024) of Character;
   type Win_Byte_Array_Ptr is access Win_Byte_Array;

   type Win_Word_Array is array (1 .. 100) of Long;
   type Word_Array_Ptr is access Win_Word_Array;

   subtype Win_Handle is Long;

   Invalid_Win_Handle : constant Win_Handle := -1;

   Four_GB : constant Long := 4294967296;

   --------------------------------------------------------------------------
   --  Win32
   --------------------------------------------------------------------------

   function W_CreateProcessA
     (Application  : System.Address;
      Command_Line : System.Address;
      Process_Attr : System.Address;
      Thread_Attr  : System.Address;
      Inherit      : Integer;
      Flags        : Integer;
      Environment  : System.Address;
      Directory    : System.Address;
      Startup_Info : System.Address;
      Process_Info : System.Address) return Integer;
   pragma Import (Stdcall, W_CreateProcessA, "CreateProcessA",
                  Enabled => System.Target_OS = System.Windows);

   function W_WaitForSingleObject (Object : Win_Handle; Millis : Integer)
     return Integer;
   pragma Import (Stdcall, W_WaitForSingleObject, "WaitForSingleObject",
                  Enabled => System.Target_OS = System.Windows);

   function W_GetExitCodeProcess (Process : Win_Handle; Code : System.Address)
     return Integer;
   pragma Import (Stdcall, W_GetExitCodeProcess, "GetExitCodeProcess",
                  Enabled => System.Target_OS = System.Windows);

   function W_CloseHandle (Object : Win_Handle) return Integer;
   pragma Import (Stdcall, W_CloseHandle, "CloseHandle",
                  Enabled => System.Target_OS = System.Windows);

   function W_CreateFileA
     (Name        : System.Address;
      Access_Mask : Integer;
      Share       : Integer;
      Security    : System.Address;
      Disposition : Integer;
      Flags       : Integer;
      Template    : Win_Handle) return Win_Handle;
   pragma Import (Stdcall, W_CreateFileA, "CreateFileA",
                  Enabled => System.Target_OS = System.Windows);

   function W_GetStdHandle (Which : Integer) return Win_Handle;
   pragma Import (Stdcall, W_GetStdHandle, "GetStdHandle",
                  Enabled => System.Target_OS = System.Windows);

   function W_WriteFile
     (File     : Win_Handle;
      Buffer   : System.Address;
      To_Write : Integer;
      Written  : System.Address;
      Overlap  : System.Address) return Integer;
   pragma Import (Stdcall, W_WriteFile, "WriteFile",
                  Enabled => System.Target_OS = System.Windows);

   procedure W_ExitProcess (Status : Integer);
   pragma Import (Stdcall, W_ExitProcess, "ExitProcess",
                  Enabled => System.Target_OS = System.Windows);

   function W_GetCurrentProcessId return Integer;
   pragma Import (Stdcall, W_GetCurrentProcessId, "GetCurrentProcessId",
                  Enabled => System.Target_OS = System.Windows);

   procedure W_GetSystemInfo (Info : System.Address);
   pragma Import (Stdcall, W_GetSystemInfo, "GetSystemInfo",
                  Enabled => System.Target_OS = System.Windows);

   function W_GetFileAttributesA (Name : System.Address) return Integer;
   pragma Import (Stdcall, W_GetFileAttributesA, "GetFileAttributesA",
                  Enabled => System.Target_OS = System.Windows);

   function W_GetFileAttributesExA
     (Name : System.Address; Level : Integer; Data : System.Address)
     return Integer;
   pragma Import (Stdcall, W_GetFileAttributesExA, "GetFileAttributesExA",
                  Enabled => System.Target_OS = System.Windows);

   function W_CreateDirectoryA
     (Path : System.Address; Security : System.Address) return Integer;
   pragma Import (Stdcall, W_CreateDirectoryA, "CreateDirectoryA",
                  Enabled => System.Target_OS = System.Windows);

   function W_RemoveDirectoryA (Path : System.Address) return Integer;
   pragma Import (Stdcall, W_RemoveDirectoryA, "RemoveDirectoryA",
                  Enabled => System.Target_OS = System.Windows);

   function W_DeleteFileA (Path : System.Address) return Integer;
   pragma Import (Stdcall, W_DeleteFileA, "DeleteFileA",
                  Enabled => System.Target_OS = System.Windows);

   function W_MoveFileExA
     (Old_Path, New_Path : System.Address; Flags : Integer) return Integer;
   pragma Import (Stdcall, W_MoveFileExA, "MoveFileExA",
                  Enabled => System.Target_OS = System.Windows);

   function W_SetCurrentDirectoryA (Path : System.Address) return Integer;
   pragma Import (Stdcall, W_SetCurrentDirectoryA, "SetCurrentDirectoryA",
                  Enabled => System.Target_OS = System.Windows);

   function W_GetCurrentDirectoryA (Size : Integer; Buffer : System.Address)
     return Integer;
   pragma Import (Stdcall, W_GetCurrentDirectoryA, "GetCurrentDirectoryA",
                  Enabled => System.Target_OS = System.Windows);

   function W_FindFirstFileA (Pattern : System.Address; Data : System.Address)
     return Win_Handle;
   pragma Import (Stdcall, W_FindFirstFileA, "FindFirstFileA",
                  Enabled => System.Target_OS = System.Windows);

   function W_FindNextFileA (Search : Win_Handle; Data : System.Address)
     return Integer;
   pragma Import (Stdcall, W_FindNextFileA, "FindNextFileA",
                  Enabled => System.Target_OS = System.Windows);

   function W_FindClose (Search : Win_Handle) return Integer;
   pragma Import (Stdcall, W_FindClose, "FindClose",
                  Enabled => System.Target_OS = System.Windows);

   function C_Malloc (Size : Long) return System.Address;
   pragma Import (C, C_Malloc, "malloc");

   procedure C_Free (Block : System.Address);
   pragma Import (C, C_Free, "free");

   --------------------------------------------------------------------------
   --  Constants
   --------------------------------------------------------------------------

   Generic_Write          : constant Integer := 16#40000000#;
   File_Share_Read        : constant Integer := 1;
   Create_Always          : constant Integer := 2;
   File_Attribute_Normal  : constant Integer := 16#80#;
   File_Attribute_Dir     : constant Long    := 16#10#;
   Invalid_File_Attrs     : constant Integer := -1;
   Std_Input_Handle       : constant Integer := -10;
   Std_Output_Handle      : constant Integer := -11;
   Std_Error_Handle       : constant Integer := -12;
   Startf_Use_Std_Handles : constant Long    := 16#100#;
   Infinite               : constant Integer := -1;
   Move_Replace_Existing  : constant Integer := 1;
   Move_Copy_Allowed      : constant Integer := 2;
   Get_File_Ex_Info_Std   : constant Integer := 0;

   function Win_To_Bytes is
     new Unchecked_Conversion (System.Address, Win_Byte_Array_Ptr);
   function To_Words is
     new Unchecked_Conversion (System.Address, Word_Array_Ptr);
   function Win_To_Long is new Unchecked_Conversion (System.Address, Long);
   function To_Address is new Unchecked_Conversion (Long, System.Address);

   --  The Win32 search block holds the handle, a flag saying the buffered
   --  entry has yet to be handed out, and the WIN32_FIND_DATAA itself:
   --
   --     word 1    FindFirstFileA handle
   --     word 2    1 while the buffered entry is pending
   --     word 3..  WIN32_FIND_DATAA, 320 bytes, cFileName at its byte 44
   Find_Data_Word   : constant := 3;
   Find_Data_Offset : constant Long := 8 * (Find_Data_Word - 1);
   Find_Name_Offset : constant Long := Find_Data_Offset + 44;

   --------------------------------------------------------------------------
   --  Internal helpers
   --------------------------------------------------------------------------

   procedure Free_String_Storage is
     new Unchecked_Deallocation (String, Str);
   procedure Free_Array_Storage is
     new Unchecked_Deallocation (Str_Array, Str_Array_Access);
   procedure Free_Proc_Storage is
     new Unchecked_Deallocation (Proc_Array, Proc_Array_Access);

   procedure Posix_Ignore (X : Integer) is
      pragma Unreferenced (X);
   begin
      null;
   end Posix_Ignore;

   function Posix_Is_Null (A : System.Address) return Boolean is
   begin
      return Posix_To_Long (A) = 0;
   end Posix_Is_Null;

   --------------------------------------------------------------------------
   --  What this system answers differently from the others
   --------------------------------------------------------------------------

   --  O_WRONLY or O_CREAT or O_TRUNC.  O_CREAT is 0100 on Linux and
   --  0x200 on macOS; O_TRUNC is 01000 and 0x400.
   function Open_Write_Create_Truncate return Integer is
   begin
      if System.Target_OS = System.MacOS then
         return 1537;
      end if;
      return 577;
   end Open_Write_Create_Truncate;

   --  The sysconf selector for _SC_NPROCESSORS_ONLN.
   function Sysconf_Cpus return Integer is
   begin
      if System.Target_OS = System.MacOS then
         return 58;
      end if;
      return 84;
   end Sysconf_Cpus;

   --  Linux keeps a 32-bit st_mode at byte 24, so the low half of word 4;
   --  macOS a 16-bit one at byte 4, so the high half of word 1, with
   --  st_dev beneath it.
   function Stat_Mode (Words : Posix_Word_Array) return Integer is
   begin
      if System.Target_OS = System.MacOS then
         return Integer ((Words (1) / 4294967296) mod 65536);
      end if;
      return Integer ((Words (4) mod 4294967296) mod 65536);
   end Stat_Mode;

   --  st_mtim(e).tv_sec: byte 88 on Linux, byte 48 on macOS.  The next
   --  word is the nanoseconds.
   function Stat_Mtime_Word return Integer is
   begin
      if System.Target_OS = System.MacOS then
         return 7;
      end if;
      return 12;
   end Stat_Mtime_Word;

   --  d_type's byte, one-based; d_name starts at the byte after it.
   --  macOS carries an eight-byte d_seekoff and a d_namlen that Linux
   --  does not.
   function Dirent_Type_Index return Integer is
   begin
      if System.Target_OS = System.MacOS then
         return 21;
      end if;
      return 19;
   end Dirent_Type_Index;

   function Posix_Path_Separator return Character is
   begin
      return '/';
   end Posix_Path_Separator;

   function Posix_Shell_Program return String is
   begin
      return "/bin/sh";
   end Posix_Shell_Program;

   function Posix_Shell_Flag return String is
   begin
      return "-c";
   end Posix_Shell_Flag;

   --------------------------------------------------------------------------
   --  Diagnostics
   --------------------------------------------------------------------------

   procedure Posix_Write_Error (Line : String) is
      Buffer : constant String := Line & ASCII.LF & ASCII.NUL;
   begin
      Posix_Ignore (C_Fputs (Buffer'Address, C_Stderr));
   end Posix_Write_Error;

   --------------------------------------------------------------------------
   --  Processes
   --------------------------------------------------------------------------

   procedure Redirect_Child (Path : String; Fd : Integer) is
      C_Path  : constant String := Path & ASCII.NUL;
      File_Fd : Integer;
   begin
      File_Fd := C_Open (C_Path'Address, Open_Write_Create_Truncate, 420);
      if File_Fd < 0 then
         C_Exit (126);
      end if;
      Posix_Ignore (C_Dup2 (File_Fd, Fd));
      Posix_Ignore (C_Close (File_Fd));
   end Redirect_Child;

   function Posix_Spawn
     (Argv     : Argv_Array;
      Out_Path : String;
      Err_Path : String) return Integer is
      --  execvp reads the vector until a null entry, which the caller's
      --  array does not carry.
      Vector : Argv_Array (1 .. Argv'Length + 1);
      Pid    : Integer;
   begin
      if Argv'Length = 0 then
         return Spawn_Failed;
      end if;
      for I in Argv'Range loop
         Vector (I - Argv'First + 1) := Argv (I);
      end loop;
      Vector (Vector'Last) := System.Null_Address;

      Pid := C_Fork;
      if Pid = 0 then
         if Out_Path /= "" then
            Redirect_Child (Out_Path, 1);
         end if;
         if Err_Path /= "" then
            Redirect_Child (Err_Path, 2);
         end if;
         Posix_Ignore (C_Execvp (Vector (1), Vector'Address));
         C_Exit (127);
      elsif Pid < 0 then
         return Spawn_Failed;
      end if;
      return Pid;
   end Posix_Spawn;

   function Posix_Wait_For (Handle : Integer) return Integer is
      Status : Integer := 0;
   begin
      if Handle <= 0 then
         return Wait_Failed;
      end if;
      if C_Waitpid (Handle, Status'Address, 0) < 0 then
         return Wait_Failed;
      end if;
      --  The low seven bits carry the terminating signal, the next eight
      --  the exit status.
      if Status mod 128 /= 0 then
         return Wait_Failed;
      end if;
      return (Status / 256) mod 256;
   end Posix_Wait_For;

   procedure Posix_Exit_Process (Status : Integer) is
   begin
      C_Exit (Status);
   end Posix_Exit_Process;

   function Posix_Process_Id return Integer is
   begin
      return C_Getpid;
   end Posix_Process_Id;

   function Posix_Cpu_Count return Positive is
      Count : constant Long := C_Sysconf (Sysconf_Cpus);
   begin
      if Count < 1 then
         return 1;
      end if;
      return Positive (Count);
   end Posix_Cpu_Count;

   --------------------------------------------------------------------------
   --  Files and directories
   --------------------------------------------------------------------------

   procedure Posix_File_Status
     (Path         : String;
      Found        : out Boolean;
      Is_Directory : out Boolean;
      Mtime_Sec    : out Long;
      Mtime_Nsec   : out Long) is
      C_Path : constant String := Path & ASCII.NUL;
      Words  : Posix_Word_Array;
      Mode   : Integer;
   begin
      Found        := False;
      Is_Directory := False;
      Mtime_Sec    := 0;
      Mtime_Nsec   := 0;
      if C_Stat (C_Path'Address, Words'Address) /= 0 then
         return;
      end if;
      Found        := True;
      Mode         := Stat_Mode (Words);
      Is_Directory := (Mode / 4096) mod 16 = 4;   --  S_IFDIR
      Mtime_Sec    := Words (Stat_Mtime_Word);
      Mtime_Nsec   := Words (Stat_Mtime_Word + 1);
   end Posix_File_Status;

   function Posix_Exists (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Access (C_Path'Address, 0) = 0;
   end Posix_Exists;

   function Posix_Make_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Mkdir (C_Path'Address, 493) = 0;   --  0755
   end Posix_Make_Directory;

   function Posix_Remove_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Rmdir (C_Path'Address) = 0;
   end Posix_Remove_Directory;

   function Posix_Remove_File (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Unlink (C_Path'Address) = 0;
   end Posix_Remove_File;

   function Posix_Change_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Chdir (C_Path'Address) = 0;
   end Posix_Change_Directory;

   function Posix_Rename_Path (Old_Path, New_Path : String) return Boolean is
      C_Old : constant String := Old_Path & ASCII.NUL;
      C_New : constant String := New_Path & ASCII.NUL;
   begin
      return C_Rename (C_Old'Address, C_New'Address) = 0;
   end Posix_Rename_Path;

   function Posix_Working_Directory return String is
      Buffer : String (1 .. 4096);
   begin
      if Posix_Is_Null (C_Getcwd (Buffer'Address, Long (Buffer'Length))) then
         return "";
      end if;
      for I in Buffer'Range loop
         if Buffer (I) = ASCII.NUL then
            return Buffer (1 .. I - 1);
         end if;
      end loop;
      return "";
   end Posix_Working_Directory;

   --------------------------------------------------------------------------
   --  Directory listing
   --------------------------------------------------------------------------

   function Posix_Open_Dir (Path : String) return System.Address is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Opendir (C_Path'Address);
   end Posix_Open_Dir;

   procedure Posix_Read_Dir
     (Handle       : System.Address;
      Name         : out String;
      Last         : out Natural;
      Is_Directory : out Boolean;
      Is_File      : out Boolean) is
      Result     : System.Address;
      Bytes      : Posix_Byte_Array_Ptr;
      Type_Index : constant Integer := Dirent_Type_Index;
      Kind       : Integer;
      Name_First : Integer;
   begin
      Last         := 0;
      Is_Directory := False;
      Is_File      := False;
      if Posix_Is_Null (Handle) then
         return;
      end if;
      if C_Readdir_R (Handle, Dirent_Words'Address, Result'Address) /= 0
        or else Posix_Is_Null (Result)
      then
         return;
      end if;

      Bytes      := Posix_To_Bytes (Dirent_Words'Address);
      Kind       := Character'Pos (Bytes (Type_Index));
      Name_First := Type_Index + 1;

      for I in Name_First .. Bytes'Last loop
         if Bytes (I) = ASCII.NUL then
            for J in Name_First .. I - 1 loop
               Name (Name'First + (J - Name_First)) := Bytes (J);
            end loop;
            Last := Name'First + (I - Name_First) - 1;
            exit;
         end if;
      end loop;

      --  Filesystems that do not fill d_type in report neither, and the
      --  caller settles it with Posix_File_Status: only the caller knows the
      --  directory this name sits in.
      if Kind = Dirent_Type_Directory then
         Is_Directory := True;
      elsif Kind = Dirent_Type_Regular then
         Is_File := True;
      end if;
   end Posix_Read_Dir;

   procedure Posix_Close_Dir (Handle : System.Address) is
   begin
      if not Posix_Is_Null (Handle) then
         Posix_Ignore (C_Closedir (Handle));
      end if;
   end Posix_Close_Dir;


   procedure Win_Ignore (X : Integer) is
      pragma Unreferenced (X);
   begin
      null;
   end Win_Ignore;

   function Win_Is_Null (A : System.Address) return Boolean is
   begin
      return Win_To_Long (A) = 0;
   end Win_Is_Null;

   function Low_Half  (Word : Long) return Long is
   begin
      return Word mod Four_GB;
   end Low_Half;

   function High_Half (Word : Long) return Long is
   begin
      return Word / Four_GB;
   end High_Half;

   function Win_Path_Separator return Character is
   begin
      return '\';
   end Win_Path_Separator;

   function Win_Shell_Program return String is
   begin
      return "cmd.exe";
   end Win_Shell_Program;

   function Win_Shell_Flag return String is
   begin
      return "/c";
   end Win_Shell_Flag;

   --------------------------------------------------------------------------
   --  Diagnostics
   --------------------------------------------------------------------------

   procedure Win_Write_Error (Line : String) is
      Buffer  : constant String := Line & ASCII.CR & ASCII.LF;
      Written : Integer := 0;
   begin
      Win_Ignore (W_WriteFile (W_GetStdHandle (Std_Error_Handle),
                           Buffer'Address, Buffer'Length,
                           Written'Address, System.Null_Address));
   end Win_Write_Error;

   --------------------------------------------------------------------------
   --  Processes
   --------------------------------------------------------------------------

   --  CreateProcessA takes one command line, not an argv, and splits it by
   --  rules of its own: a run of backslashes before a quote is doubled and
   --  the quote escaped; elsewhere backslashes are literal.
   function Quoted (Argument : String) return String is
      Needs_Quotes : Boolean := Argument'Length = 0;
   begin
      for I in Argument'Range loop
         if Argument (I) = ' ' or else Argument (I) = ASCII.HT or else
            Argument (I) = '"'
         then
            Needs_Quotes := True;
         end if;
      end loop;
      if not Needs_Quotes then
         return Argument;
      end if;

      declare
         Buffer  : String (1 .. 2 * Argument'Length + 2);
         Last    : Natural := 1;
         Slashes : Natural := 0;
      begin
         Buffer (1) := '"';
         for I in Argument'Range loop
            if Argument (I) = '\' then
               Slashes := Slashes + 1;
               Last := Last + 1;
               Buffer (Last) := '\';
            elsif Argument (I) = '"' then
               for J in 1 .. Slashes + 1 loop
                  Last := Last + 1;
                  Buffer (Last) := '\';
               end loop;
               Last := Last + 1;
               Buffer (Last) := '"';
               Slashes := 0;
            else
               Slashes := 0;
               Last := Last + 1;
               Buffer (Last) := Argument (I);
            end if;
         end loop;
         for J in 1 .. Slashes loop
            Last := Last + 1;
            Buffer (Last) := '\';
         end loop;
         Last := Last + 1;
         Buffer (Last) := '"';
         return Buffer (1 .. Last);
      end;
   end Quoted;

   function String_At (A : System.Address) return String is
      Bytes : constant Win_Byte_Array_Ptr := Win_To_Bytes (A);
   begin
      for I in Bytes'Range loop
         if Bytes (I) = ASCII.NUL then
            declare
               Result : String (1 .. I - 1);
            begin
               for J in Result'Range loop
                  Result (J) := Bytes (J);
               end loop;
               return Result;
            end;
         end if;
      end loop;
      return "";
   end String_At;

   --  A handle the child inherits needs bInheritHandle set in a
   --  SECURITY_ATTRIBUTES: {DWORD nLength, LPVOID lpDescriptor,
   --  BOOL bInheritHandle} -- 24 bytes, the flag at byte 16.
   function Redirect_Handle (Path : String) return Win_Handle is
      C_Path   : constant String := Path & ASCII.NUL;
      Security : Win_Word_Array;
   begin
      Security (1) := 24;
      Security (2) := 0;
      Security (3) := 1;
      return W_CreateFileA (C_Path'Address, Generic_Write, File_Share_Read,
                            Security'Address, Create_Always,
                            File_Attribute_Normal, 0);
   end Redirect_Handle;

   function Win_Spawn
     (Argv     : Argv_Array;
      Out_Path : String;
      Err_Path : String) return Integer is

      --  STARTUPINFOA, 104 bytes: cb at 0, dwFlags at 60, hStdInput at 80,
      --  hStdOutput at 88, hStdError at 96.  As words: cb is the low half
      --  of word 1, dwFlags the high half of word 8, and the handles are
      --  words 11, 12 and 13.
      Startup      : Win_Word_Array;
      Process_Info : Win_Word_Array;
      Out_Handle   : Win_Handle;
      Err_Handle   : Win_Handle;
      Ok           : Integer;
      Block        : System.Address;
      Line         : String (1 .. 32768);
      Last         : Natural := 0;

      procedure Add (S : String) is
      begin
         for I in S'Range loop
            Last := Last + 1;
            Line (Last) := S (I);
         end loop;
      end Add;

   begin
      if Argv'Length = 0 then
         return Spawn_Failed;
      end if;

      for I in 1 .. 13 loop
         Startup (I) := 0;
      end loop;
      for I in 1 .. 3 loop
         Process_Info (I) := 0;
      end loop;
      Startup (1) := 104;
      Startup (8) := Startf_Use_Std_Handles * Four_GB;

      if Out_Path /= "" then
         Out_Handle := Redirect_Handle (Out_Path);
         if Out_Handle = Invalid_Win_Handle then
            return Spawn_Failed;
         end if;
      else
         Out_Handle := W_GetStdHandle (Std_Output_Handle);
      end if;

      if Err_Path /= "" then
         Err_Handle := Redirect_Handle (Err_Path);
         if Err_Handle = Invalid_Win_Handle then
            if Out_Path /= "" then
               Win_Ignore (W_CloseHandle (Out_Handle));
            end if;
            return Spawn_Failed;
         end if;
      else
         Err_Handle := W_GetStdHandle (Std_Error_Handle);
      end if;

      Startup (11) := W_GetStdHandle (Std_Input_Handle);
      Startup (12) := Out_Handle;
      Startup (13) := Err_Handle;

      for I in Argv'Range loop
         if I > Argv'First then
            Add (" ");
         end if;
         Add (Quoted (String_At (Argv (I))));
      end loop;
      Last := Last + 1;
      Line (Last) := ASCII.NUL;

      --  CreateProcessA may write to the command line it is given, so it
      --  cannot be a constant of this frame.
      Block := C_Malloc (Long (Last));
      if Win_Is_Null (Block) then
         return Spawn_Failed;
      end if;
      declare
         Bytes : constant Win_Byte_Array_Ptr := Win_To_Bytes (Block);
      begin
         for I in 1 .. Last loop
            Bytes (I) := Line (I);
         end loop;
      end;

      Ok := W_CreateProcessA (System.Null_Address, Block,
                              System.Null_Address, System.Null_Address,
                              1, 0, System.Null_Address, System.Null_Address,
                              Startup'Address, Process_Info'Address);
      C_Free (Block);

      if Out_Path /= "" then
         Win_Ignore (W_CloseHandle (Out_Handle));
      end if;
      if Err_Path /= "" then
         Win_Ignore (W_CloseHandle (Err_Handle));
      end if;
      if Ok = 0 then
         return Spawn_Failed;
      end if;

      --  PROCESS_INFORMATION: hProcess at 0, hThread at 8, the ids after.
      Win_Ignore (W_CloseHandle (Process_Info (2)));
      return Integer (Process_Info (1) mod 2147483647);
   end Win_Spawn;

   function Win_Wait_For (Handle : Integer) return Integer is
      Process : constant Win_Handle := Long (Handle);
      Code    : Integer := 0;
      Status  : Integer;
   begin
      if Handle <= 0 then
         return Wait_Failed;
      end if;
      Win_Ignore (W_WaitForSingleObject (Process, Infinite));
      Status := W_GetExitCodeProcess (Process, Code'Address);
      Win_Ignore (W_CloseHandle (Process));
      if Status = 0 then
         return Wait_Failed;
      end if;
      return Code;
   end Win_Wait_For;

   procedure Win_Exit_Process (Status : Integer) is
   begin
      W_ExitProcess (Status);
   end Win_Exit_Process;

   function Win_Process_Id return Integer is
   begin
      return W_GetCurrentProcessId;
   end Win_Process_Id;

   function Win_Cpu_Count return Positive is
      --  SYSTEM_INFO, 48 bytes: dwNumberOfProcessors at byte 32, the low
      --  half of word 5.
      Info : Win_Word_Array;
   begin
      for I in 1 .. 6 loop
         Info (I) := 0;
      end loop;
      W_GetSystemInfo (Info'Address);
      declare
         Count : constant Long := Low_Half (Info (5));
      begin
         if Count < 1 then
            return 1;
         end if;
         return Positive (Count);
      end;
   end Win_Cpu_Count;

   --------------------------------------------------------------------------
   --  Files and directories
   --------------------------------------------------------------------------

   --  A FILETIME counts 100-nanosecond ticks since 1601.  Only the
   --  ordering of two of them matters here, so the epoch is left alone.
   procedure Split_Filetime (Ticks : Long; Sec : out Long; Nsec : out Long) is
   begin
      Sec  := Ticks / 10000000;
      Nsec := (Ticks mod 10000000) * 100;
   end Split_Filetime;

   procedure Win_File_Status
     (Path         : String;
      Found        : out Boolean;
      Is_Directory : out Boolean;
      Mtime_Sec    : out Long;
      Mtime_Nsec   : out Long) is
      C_Path : constant String := Path & ASCII.NUL;
      --  WIN32_FILE_ATTRIBUTE_DATA, 36 bytes: dwFileAttributes at 0, then
      --  three FILETIMEs at 4, 12 and 20, then the two size halves.
      --  ftLastWriteTime therefore straddles words 3 and 4.
      Data  : Win_Word_Array;
      Ticks : Long;
   begin
      Found        := False;
      Is_Directory := False;
      Mtime_Sec    := 0;
      Mtime_Nsec   := 0;

      for I in 1 .. 6 loop
         Data (I) := 0;
      end loop;
      if W_GetFileAttributesExA (C_Path'Address, Get_File_Ex_Info_Std,
                                 Data'Address) = 0
      then
         return;
      end if;

      Found        := True;
      Is_Directory :=
        (Low_Half (Data (1)) / File_Attribute_Dir) mod 2 = 1;
      Ticks        := High_Half (Data (3)) + Low_Half (Data (4)) * Four_GB;
      Split_Filetime (Ticks, Mtime_Sec, Mtime_Nsec);
   end Win_File_Status;

   function Win_Exists (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_GetFileAttributesA (C_Path'Address) /= Invalid_File_Attrs;
   end Win_Exists;

   function Win_Make_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_CreateDirectoryA (C_Path'Address, System.Null_Address) /= 0;
   end Win_Make_Directory;

   function Win_Remove_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_RemoveDirectoryA (C_Path'Address) /= 0;
   end Win_Remove_Directory;

   function Win_Remove_File (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_DeleteFileA (C_Path'Address) /= 0;
   end Win_Remove_File;

   function Win_Change_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_SetCurrentDirectoryA (C_Path'Address) /= 0;
   end Win_Change_Directory;

   function Win_Rename_Path (Old_Path, New_Path : String) return Boolean is
      C_Old : constant String := Old_Path & ASCII.NUL;
      C_New : constant String := New_Path & ASCII.NUL;
   begin
      --  Windows refuses to delete a running executable but will rename
      --  one, which is what Go_Rebuild_Urself depends on.
      return W_MoveFileExA (C_Old'Address, C_New'Address,
                            Move_Replace_Existing + Move_Copy_Allowed) /= 0;
   end Win_Rename_Path;

   function Win_Working_Directory return String is
      Buffer : String (1 .. 4096);
      Length : constant Integer :=
        W_GetCurrentDirectoryA (Buffer'Length, Buffer'Address);
   begin
      if Length <= 0 or else Length > Buffer'Length then
         return "";
      end if;
      return Buffer (1 .. Length);
   end Win_Working_Directory;

   --------------------------------------------------------------------------
   --  Directory listing
   --------------------------------------------------------------------------

   function Win_Open_Dir (Path : String) return System.Address is
      Pattern : constant String := Path & "\*" & ASCII.NUL;
      Block   : constant System.Address := C_Malloc (400);
      Search  : Win_Handle;
   begin
      if Win_Is_Null (Block) then
         return Null_Dir;
      end if;
      Search := W_FindFirstFileA
        (Pattern'Address, To_Address (Win_To_Long (Block) + Find_Data_Offset));
      if Search = Invalid_Win_Handle then
         C_Free (Block);
         return Null_Dir;
      end if;
      To_Words (Block) (1) := Search;
      To_Words (Block) (2) := 1;
      return Block;
   end Win_Open_Dir;

   procedure Win_Read_Dir
     (Handle       : System.Address;
      Name         : out String;
      Last         : out Natural;
      Is_Directory : out Boolean;
      Is_File      : out Boolean) is
      Words      : Word_Array_Ptr;
      Name_Bytes : Win_Byte_Array_Ptr;
      Attributes : Long;
      Directory  : Boolean;
   begin
      Last         := 0;
      Is_Directory := False;
      Is_File      := False;
      if Win_Is_Null (Handle) then
         return;
      end if;

      Words := To_Words (Handle);
      if Words (2) = 1 then
         Words (2) := 0;          --  hand out the entry FindFirstFileA read
      elsif W_FindNextFileA
              (Words (1),
               To_Address (Win_To_Long (Handle) + Find_Data_Offset)) = 0
      then
         return;
      end if;

      Name_Bytes := Win_To_Bytes (To_Address (Win_To_Long (Handle) +
                                          Find_Name_Offset));
      for I in Name_Bytes'Range loop
         if Name_Bytes (I) = ASCII.NUL then
            for J in 1 .. I - 1 loop
               Name (Name'First + J - 1) := Name_Bytes (J);
            end loop;
            Last := Name'First + I - 2;
            exit;
         end if;
      end loop;

      Attributes   := Low_Half (Words (Find_Data_Word));
      Directory    := (Attributes / File_Attribute_Dir) mod 2 = 1;
      Is_Directory := Directory;
      Is_File      := not Directory;
   end Win_Read_Dir;

   procedure Win_Close_Dir (Handle : System.Address) is
   begin
      if Win_Is_Null (Handle) then
         return;
      end if;
      Win_Ignore (W_FindClose (To_Words (Handle) (1)));
      C_Free (Handle);
   end Win_Close_Dir;


   function Sys_Path_Separator return Character is
   begin
      if System.Target_OS = System.Windows then
         return Win_Path_Separator;
      end if;
      return Posix_Path_Separator;
   end Sys_Path_Separator;

   function Sys_Shell_Program return String is
   begin
      if System.Target_OS = System.Windows then
         return Win_Shell_Program;
      end if;
      return Posix_Shell_Program;
   end Sys_Shell_Program;

   function Sys_Shell_Flag return String is
   begin
      if System.Target_OS = System.Windows then
         return Win_Shell_Flag;
      end if;
      return Posix_Shell_Flag;
   end Sys_Shell_Flag;

   procedure Sys_Write_Error
     (Line : String) is
   begin
      if System.Target_OS = System.Windows then
         Win_Write_Error(Line);
         return;
      end if;
      Posix_Write_Error(Line);
   end Sys_Write_Error;

   function Sys_Spawn
     (Argv : Argv_Array;
      Out_Path : String;
      Err_Path : String) return Integer is
   begin
      if System.Target_OS = System.Windows then
         return Win_Spawn(Argv, Out_Path, Err_Path);
      end if;
      return Posix_Spawn(Argv, Out_Path, Err_Path);
   end Sys_Spawn;

   function Sys_Wait_For
     (Handle : Integer) return Integer is
   begin
      if System.Target_OS = System.Windows then
         return Win_Wait_For(Handle);
      end if;
      return Posix_Wait_For(Handle);
   end Sys_Wait_For;

   procedure Sys_Exit_Process
     (Status : Integer) is
   begin
      if System.Target_OS = System.Windows then
         Win_Exit_Process(Status);
         return;
      end if;
      Posix_Exit_Process(Status);
   end Sys_Exit_Process;

   function Sys_Process_Id return Integer is
   begin
      if System.Target_OS = System.Windows then
         return Win_Process_Id;
      end if;
      return Posix_Process_Id;
   end Sys_Process_Id;

   function Sys_Cpu_Count return Positive is
   begin
      if System.Target_OS = System.Windows then
         return Win_Cpu_Count;
      end if;
      return Posix_Cpu_Count;
   end Sys_Cpu_Count;

   function Sys_Exists
     (Path : String) return Boolean is
   begin
      if System.Target_OS = System.Windows then
         return Win_Exists(Path);
      end if;
      return Posix_Exists(Path);
   end Sys_Exists;

   function Sys_Make_Directory
     (Path : String) return Boolean is
   begin
      if System.Target_OS = System.Windows then
         return Win_Make_Directory(Path);
      end if;
      return Posix_Make_Directory(Path);
   end Sys_Make_Directory;

   function Sys_Remove_Directory
     (Path : String) return Boolean is
   begin
      if System.Target_OS = System.Windows then
         return Win_Remove_Directory(Path);
      end if;
      return Posix_Remove_Directory(Path);
   end Sys_Remove_Directory;

   function Sys_Remove_File
     (Path : String) return Boolean is
   begin
      if System.Target_OS = System.Windows then
         return Win_Remove_File(Path);
      end if;
      return Posix_Remove_File(Path);
   end Sys_Remove_File;

   function Sys_Change_Directory
     (Path : String) return Boolean is
   begin
      if System.Target_OS = System.Windows then
         return Win_Change_Directory(Path);
      end if;
      return Posix_Change_Directory(Path);
   end Sys_Change_Directory;

   function Sys_Rename_Path
     (Old_Path : String;
      New_Path : String) return Boolean is
   begin
      if System.Target_OS = System.Windows then
         return Win_Rename_Path(Old_Path, New_Path);
      end if;
      return Posix_Rename_Path(Old_Path, New_Path);
   end Sys_Rename_Path;

   function Sys_Working_Directory return String is
   begin
      if System.Target_OS = System.Windows then
         return Win_Working_Directory;
      end if;
      return Posix_Working_Directory;
   end Sys_Working_Directory;

   function Sys_Is_Null
     (A : System.Address) return Boolean is
   begin
      if System.Target_OS = System.Windows then
         return Win_Is_Null(A);
      end if;
      return Posix_Is_Null(A);
   end Sys_Is_Null;

   function Sys_Open_Dir
     (Path : String) return System.Address is
   begin
      if System.Target_OS = System.Windows then
         return Win_Open_Dir(Path);
      end if;
      return Posix_Open_Dir(Path);
   end Sys_Open_Dir;

   procedure Sys_Close_Dir
     (Handle : System.Address) is
   begin
      if System.Target_OS = System.Windows then
         Win_Close_Dir(Handle);
         return;
      end if;
      Posix_Close_Dir(Handle);
   end Sys_Close_Dir;

   procedure Sys_File_Status
     (Path         : String;
      Found        : out Boolean;
      Is_Directory : out Boolean;
      Mtime_Sec    : out Long;
      Mtime_Nsec   : out Long) is
   begin
      if System.Target_OS = System.Windows then
         Win_File_Status (Path, Found, Is_Directory, Mtime_Sec, Mtime_Nsec);
         return;
      end if;
      Posix_File_Status (Path, Found, Is_Directory, Mtime_Sec, Mtime_Nsec);
   end Sys_File_Status;

   procedure Sys_Read_Dir
     (Handle       : System.Address;
      Name         : out String;
      Last         : out Natural;
      Is_Directory : out Boolean;
      Is_File      : out Boolean) is
   begin
      if System.Target_OS = System.Windows then
         Win_Read_Dir (Handle, Name, Last, Is_Directory, Is_File);
         return;
      end if;
      Posix_Read_Dir (Handle, Name, Last, Is_Directory, Is_File);
   end Sys_Read_Dir;

   --  Ada 83 has no way to discard a function result, and a variable that
   --  only ever receives one draws a warning.  Passing the result here is
   --  what makes "this result is deliberately unused" say so.  The one
   --  pragma sits at the definition of that idea rather than at each of
   --  its uses; a compiler that does not know the pragma ignores it.
   procedure Ignore (X : Integer) is
      pragma Unreferenced (X);
   begin
      null;
   end Ignore;

   procedure Ignore (X : Boolean) is
      pragma Unreferenced (X);
   begin
      null;
   end Ignore;

   function C_Str (S : String) return Str is
   begin
      return new String'(S & ASCII.NUL);
   end C_Str;

   function Data_Address (S : Str) return System.Address is
   begin
      return S.all (S.all'First)'Address;
   end Data_Address;

   procedure Put_Stderr (Line : String) is
   begin
      Sys_Write_Error (Line);
   end Put_Stderr;

   --------------------------------------------------------------------------
   --  Logging
   --------------------------------------------------------------------------

   function Tag_Passes (Tag : String) return Boolean is
   begin
      case Active_Level is
         when Verbose =>
            return True;
         when Normal =>
            return Tag = "INFO" or else Tag = "WARN" or else Tag = "ERRO";
         when Quiet =>
            return Tag = "WARN" or else Tag = "ERRO";
         when Silent =>
            return False;
      end case;
   end Tag_Passes;

   procedure Log (Tag, Msg : String) is
   begin
      if Tag_Passes (Tag) then
         Put_Stderr ("[" & Tag & "] " & Msg);
      end if;
   end Log;

   procedure Set_Log_Level (Level : Log_Level) is
   begin
      Active_Level := Level;
   end Set_Log_Level;

   procedure Info (Msg : String) is
   begin
      Log ("INFO", Msg);
   end Info;

   procedure Warn (Msg : String) is
   begin
      Log ("WARN", Msg);
   end Warn;

   procedure Erro (Msg : String) is
   begin
      Log ("ERRO", Msg);
   end Erro;

   procedure Panic (Msg : String) is
   begin
      Erro (Msg);
      raise Build_Error;
   end Panic;

   procedure Unimplemented (Name : String) is
   begin
      Erro (Name & ": not yet ported (arrives in a later phase)");
      raise Build_Error;
   end Unimplemented;

   --------------------------------------------------------------------------
   --  Str
   --------------------------------------------------------------------------

   function "+" (S : String) return Str is
   begin
      return new String'(S);
   end "+";

   function Value (S : Str) return String is
   begin
      if S = null then
         return "";
      end if;
      return S.all;
   end Value;

   --------------------------------------------------------------------------
   --  Argument_List
   --------------------------------------------------------------------------

   procedure Grow (List : in out Argument_List) is
   begin
      if List.Items = null then
         List.Items := new Str_Array (1 .. 8);
         for I in List.Items'Range loop
            List.Items (I) := null;
         end loop;
      elsif List.Count = List.Items'Last then
         declare
            Grown : Str_Array_Access :=
              new Str_Array (1 .. List.Items'Last * 2);
         begin
            for I in Grown'Range loop
               if I <= List.Count then
                  Grown (I) := List.Items (I);
               else
                  Grown (I) := null;
               end if;
            end loop;
            Free_Array_Storage (List.Items);
            List.Items := Grown;
         end;
      end if;
   end Grow;

   procedure Append (List : in out Argument_List; Item : String) is
   begin
      Grow (List);
      List.Count := List.Count + 1;
      List.Items (List.Count) := new String'(Item);
   end Append;

   procedure Append (List : in out Argument_List; Items : Argument_List) is
   begin
      for I in 1 .. Items.Count loop
         Append (List, Items.Items (I).all);
      end loop;
   end Append;

   function Copy (List : Argument_List) return Argument_List is
      Result : Argument_List;
   begin
      Append (Result, List);
      return Result;
   end Copy;

   procedure Clear (List : in out Argument_List) is
   begin
      if List.Items /= null then
         for I in 1 .. List.Count loop
            if List.Items (I) /= null then
               Free_String_Storage (List.Items (I));
            end if;
         end loop;
         Free_Array_Storage (List.Items);
      end if;
      List.Items := null;
      List.Count := 0;
   end Clear;

   function Length (List : Argument_List) return Natural is
   begin
      return List.Count;
   end Length;

   function Element (List : Argument_List; Index : Positive) return String is
   begin
      if Index > List.Count then
         raise Constraint_Error;
      end if;
      return List.Items (Index).all;
   end Element;

   function Args (A : String) return Argument_List is
      L : Argument_List;
   begin
      Append (L, A);
      return L;
   end Args;

   function Args (A, B : String) return Argument_List is
      L : Argument_List := Args (A);
   begin
      Append (L, B);
      return L;
   end Args;

   function Args (A, B, C : String) return Argument_List is
      L : Argument_List := Args (A, B);
   begin
      Append (L, C);
      return L;
   end Args;

   function Args (A, B, C, D : String) return Argument_List is
      L : Argument_List := Args (A, B, C);
   begin
      Append (L, D);
      return L;
   end Args;

   function Args (A, B, C, D, E : String) return Argument_List is
      L : Argument_List := Args (A, B, C, D);
   begin
      Append (L, E);
      return L;
   end Args;

   function Args (A, B, C, D, E, F : String) return Argument_List is
      L : Argument_List := Args (A, B, C, D, E);
   begin
      Append (L, F);
      return L;
   end Args;

   function Args (A, B, C, D, E, F, G : String) return Argument_List is
      L : Argument_List := Args (A, B, C, D, E, F);
   begin
      Append (L, G);
      return L;
   end Args;

   function Args (A, B, C, D, E, F, G, H : String) return Argument_List is
      L : Argument_List := Args (A, B, C, D, E, F, G);
   begin
      Append (L, H);
      return L;
   end Args;

   function "&" (Left, Right : Argument_List) return Argument_List is
      Result : Argument_List := Copy (Left);
   begin
      Append (Result, Right);
      return Result;
   end "&";

   function "&" (Left : Argument_List; Right : String)
     return Argument_List is
      Result : Argument_List := Copy (Left);
   begin
      Append (Result, Right);
      return Result;
   end "&";

   function "&" (Left : String; Right : Argument_List)
     return Argument_List is
      Result : Argument_List := Args (Left);
   begin
      Append (Result, Right);
      return Result;
   end "&";

   --------------------------------------------------------------------------
   --  Redirect
   --------------------------------------------------------------------------

   function To_File (Stdout : String := ""; Stderr : String := "")
     return Redirect is
      R : Redirect;
   begin
      if Stdout'Length > 0 then
         R.Stdout := new String'(Stdout);
      end if;
      if Stderr'Length > 0 then
         R.Stderr := new String'(Stderr);
      end if;
      return R;
   end To_File;

   --------------------------------------------------------------------------
   --  Path utilities
   --------------------------------------------------------------------------

   function Separator return Character is
   begin
      return Sys_Path_Separator;
   end Separator;

   function Is_Separator (C : Character) return Boolean is
   begin
      return C = '/' or else C = '\';
   end Is_Separator;

   function "/" (Left, Right : String) return String is
   begin
      if Left'Length = 0 then
         return Right;
      end if;
      if Right'Length = 0 then
         return Left;
      end if;
      if Is_Separator (Left (Left'Last)) then
         return Left & Right;
      end if;
      return Left & Separator & Right;
   end "/";

   function No_Ext (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '.' then
            return Path (Path'First .. I - 1);
         elsif Is_Separator (Path (I)) then
            return Path;
         end if;
      end loop;
      return Path;
   end No_Ext;

   function Ends_With (S, Suffix : String) return Boolean is
   begin
      if Suffix'Length > S'Length then
         return False;
      end if;
      return S (S'Last - Suffix'Length + 1 .. S'Last) = Suffix;
   end Ends_With;

   function Base_Name (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Is_Separator (Path (I)) then
            return Path (I + 1 .. Path'Last);
         end if;
      end loop;
      return Path;
   end Base_Name;

   --------------------------------------------------------------------------
   --  Process execution
   --------------------------------------------------------------------------

   function Join_From (List : Argument_List; From : Positive) return String is
   begin
      if From > Length (List) then
         return "";
      end if;
      if From = Length (List) then
         return Element (List, From);
      end if;
      return Element (List, From) & " " & Join_From (List, From + 1);
   end Join_From;

   function Spawn
     (Program : String;
      List    : Argument_List;
      Redir   : Redirect) return Integer is
      Argc    : constant Natural := Length (List);
      Argv    : Argv_Array (1 .. Argc + 1);
      Holders : Str_Array (1 .. Argc + 1);
      Pid     : Integer;
   begin
      --  The OS package reads through these addresses during Spawn, so the
      --  strings have to outlive the call.
      Holders (1) := C_Str (Program);
      Argv (1)    := Data_Address (Holders (1));
      for I in 1 .. Argc loop
         Holders (I + 1) := C_Str (Element (List, I));
         Argv (I + 1)    := Data_Address (Holders (I + 1));
      end loop;

      Pid := Sys_Spawn (Argv, Value (Redir.Stdout), Value (Redir.Stderr));

      for I in Holders'Range loop
         Free_String_Storage (Holders (I));
      end loop;

      if Pid = Spawn_Failed then
         Panic ("cannot start " & Program);
      end if;
      return Pid;
   end Spawn;

   procedure Check_Exit_Code (Code : Integer; Label : String) is
   begin
      if Code = Wait_Failed then
         Panic (Label & ": did not exit normally");
      elsif Code /= 0 then
         Panic (Label & ": exit code" & Integer'Image (Code));
      end if;
   end Check_Exit_Code;

   function Trim_Whitespace (S : String) return String is
      First : Integer := S'First;
      Last  : Integer := S'Last;
   begin
      while First <= Last and then
            (S (First) = ' ' or else S (First) = ASCII.HT or else
             S (First) = ASCII.LF or else S (First) = ASCII.CR) loop
         First := First + 1;
      end loop;
      while Last >= First and then
            (S (Last) = ' ' or else S (Last) = ASCII.HT or else
             S (Last) = ASCII.LF or else S (Last) = ASCII.CR) loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trim_Whitespace;

   --------------------------------------------------------------------------
   --  Phase 5..6 stubs
   --------------------------------------------------------------------------

   procedure Cmd
     (Program : String;
      Args     : Argument_List := No_Args;
      Redir    : Redirect      := No_Redirect) is
      Pid : Integer;
   begin
      if Length (Args) = 0 then
         Log ("CMD", Program);
      else
         Log ("CMD", Program & " " & Join_From (Args, 1));
      end if;
      Pid := Spawn (Program, Args, Redir);
      Check_Exit_Code (Sys_Wait_For (Pid), Program);
   end Cmd;

   procedure Sh (Command : String) is
   begin
      Cmd (Sys_Shell_Program, Args (Sys_Shell_Flag, Command));
   end Sh;

   function Capture
     (Program  : String;
      Args     : Argument_List := No_Args) return String is
      Pid_Image : constant String := Integer'Image (Sys_Process_Id);
      Temp_Path : constant String :=
        "no_build_capture_" & Pid_Image (2 .. Pid_Image'Last) & ".txt";
   begin
      begin
         Cmd (Program, Args, To_File (Stdout => Temp_Path));
      exception
         when Build_Error =>
            Ignore (Sys_Remove_File (Temp_Path));
            raise;
      end;
      declare
         Raw : constant String := Read_File (Temp_Path);
      begin
         Ignore (Sys_Remove_File (Temp_Path));
         return Trim_Whitespace (Raw);
      end;
   end Capture;

   function Cmd_Async
     (Program  : String;
      Args     : Argument_List := No_Args;
      Redir    : Redirect      := No_Redirect) return Proc is
      Result : Proc;
   begin
      if Length (Args) = 0 then
         Log ("CMD", Program & " &");
      else
         Log ("CMD", Program & " " & Join_From (Args, 1) & " &");
      end if;
      Result.Pid := Spawn (Program, Args, Redir);
      return Result;
   end Cmd_Async;

   procedure Wait (P : Proc) is
   begin
      if P.Pid <= 0 then
         Panic ("Wait: invalid process handle");
      end if;
      Check_Exit_Code (Sys_Wait_For (P.Pid),
                       "pid" & Integer'Image (P.Pid));
   end Wait;

   procedure Append (List : in out Proc_List; P : Proc) is
   begin
      if List.Items = null then
         List.Items := new Proc_Array (1 .. 8);
      elsif List.Count = List.Items'Last then
         declare
            Grown : Proc_Array_Access :=
              new Proc_Array (1 .. List.Items'Last * 2);
         begin
            for I in 1 .. List.Count loop
               Grown (I) := List.Items (I);
            end loop;
            Free_Proc_Storage (List.Items);
            List.Items := Grown;
         end;
      end if;
      List.Count := List.Count + 1;
      List.Items (List.Count) := P;
   end Append;

   procedure Wait_All (List : in out Proc_List) is
      Failures : Natural := 0;
   begin
      for I in 1 .. List.Count loop
         begin
            Wait (List.Items (I));
         exception
            when Build_Error =>
               Failures := Failures + 1;
         end;
      end loop;
      List.Count := 0;
      if Failures > 0 then
         Panic ("Wait_All: a child process failed");
      end if;
   end Wait_All;

   function N_Procs return Positive is
   begin
      return Sys_Cpu_Count;
   end N_Procs;

   procedure Compile_Program
     (Source  : String;
      Output  : String        := "";
      Modules : Argument_List := No_Args;
      Extra   : Argument_List := No_Args) is
      Line : Argument_List;
   begin
      Append (Line, Extra);
      Append (Line, Source);
      Append (Line, Modules);
      if Output /= "" then
         Append (Line, "-o");
         Append (Line, Output);
      end if;
      Cmd (Compiler, Line);
      Clear (Line);
   end Compile_Program;

   procedure Compile_Module
     (Source : String;
      Output : String        := "";
      Extra  : Argument_List := No_Args) is
      Line : Argument_List;
   begin
      Append (Line, "--ir");
      Append (Line, Extra);
      Append (Line, Source);
      if Output /= "" then
         Append (Line, "-o");
         Append (Line, Output);
      end if;
      Cmd (Compiler, Line);
      Clear (Line);
   end Compile_Module;

   function Path_Exists (Path : String) return Boolean is
   begin
      return Sys_Exists (Path);
   end Path_Exists;

   function Is_Dir (Path : String) return Boolean is
      Found     : Boolean;
      Directory : Boolean;
      Sec, Nsec : Long;
   begin
      Sys_File_Status (Path, Found, Directory, Sec, Nsec);
      return Found and then Directory;
   end Is_Dir;

   procedure Close_Dir (Handle : System.Address) is
   begin
      Sys_Close_Dir (Handle);
   end Close_Dir;

   function Open_Dir_Or_Panic (Path : String) return System.Address is
      Handle : constant System.Address := Sys_Open_Dir (Path);
   begin
      if Sys_Is_Null (Handle) then
         Panic ("cannot open directory: " & Path);
      end if;
      return Handle;
   end Open_Dir_Or_Panic;

   --  Entry_Type carries what the directory itself knew about the entry:
   --  0 unknown, 1 a directory, 2 a regular file.  Entry_Kind settles an
   --  unknown against the file, which needs the path the caller holds.
   procedure Next_Dir_Entry
     (Dir        : System.Address;
      Name_Buf   : out String;
      Name_Last  : out Natural;
      Entry_Type : out Integer) is
      Is_Directory : Boolean;
      Is_File      : Boolean;
   begin
      Entry_Type := 0;
      Sys_Read_Dir (Dir, Name_Buf, Name_Last, Is_Directory, Is_File);
      if Is_Directory then
         Entry_Type := 1;
      elsif Is_File then
         Entry_Type := 2;
      end if;
   end Next_Dir_Entry;

   function Entry_Kind (Full_Path : String; Entry_Type : Integer)
     return File_Kind is
      Found           : Boolean;
      Directory_Entry : Boolean;
      Sec, Nsec       : Long;
   begin
      if Entry_Type = 1 then
         return Directory;
      end if;
      if Entry_Type = 2 then
         return Regular_File;
      end if;
      Sys_File_Status (Full_Path, Found, Directory_Entry, Sec, Nsec);
      if not Found then
         return Other;
      end if;
      if Directory_Entry then
         return Directory;
      end if;
      return Regular_File;
   end Entry_Kind;

   procedure Make_Dir (Path : String) is
   begin
      Log ("MKDIR", Path);
      if Path_Exists (Path) then
         Warn ("Make_Dir: " & Path & " already exists");
         return;
      end if;
      if not Sys_Make_Directory (Path) then
         Panic ("mkdir failed: " & Path);
      end if;
   end Make_Dir;

   procedure Make_Dirs (Path : String) is
   begin
      Log ("MKDIRS", Path);
      for I in Path'Range loop
         if Is_Separator (Path (I)) and then I > Path'First then
            declare
               Prefix : constant String := Path (Path'First .. I - 1);
            begin
               if not Path_Exists (Prefix) then
                  Ignore (Sys_Make_Directory (Prefix));
               end if;
            end;
         end if;
      end loop;
      if not Path_Exists (Path) and then not Sys_Make_Directory (Path) then
         Panic ("mkdir failed: " & Path);
      end if;
   end Make_Dirs;

   procedure Rename_Path (Old_Path, New_Path : String) is
   begin
      Log ("RENAME", Old_Path & " -> " & New_Path);
      if not Sys_Rename_Path (Old_Path, New_Path) then
         Panic ("rename failed: " & Old_Path & " -> " & New_Path);
      end if;
   end Rename_Path;

   procedure Remove_Tree (Path : String) is
      Handle    : System.Address;
      Name_Buf  : String (1 .. 256);
      Name_Last : Natural;
      Kind_Code : Integer;
   begin
      Handle := Open_Dir_Or_Panic (Path);
      loop
         Next_Dir_Entry (Handle, Name_Buf, Name_Last, Kind_Code);
         exit when Name_Last = 0;
         declare
            Name : constant String := Name_Buf (1 .. Name_Last);
         begin
            if Name /= "." and then Name /= ".." then
               declare
                  Full : constant String := Path / Name;
               begin
                  if Entry_Kind (Full, Kind_Code) = Directory then
                     Remove_Tree (Full);
                  else
                     Ignore (Sys_Remove_File (Full));
                  end if;
               end;
            end if;
         end;
      end loop;
      Close_Dir (Handle);
      if not Sys_Remove_Directory (Path) then
         Panic ("cannot remove directory: " & Path);
      end if;
   end Remove_Tree;

   procedure Remove_Path (Path : String) is
   begin
      Log ("RM", Path);
      if Is_Dir (Path) then
         Remove_Tree (Path);
      elsif Path_Exists (Path) then
         if not Sys_Remove_File (Path) then
            Panic ("cannot remove file: " & Path);
         end if;
      else
         Warn ("path does not exist: " & Path);
      end if;
   end Remove_Path;

   procedure Copy_File (Src, Dst : String) is
      C_Src      : constant String := Src & ASCII.NUL;
      C_Dst      : constant String := Dst & ASCII.NUL;
      Read_Mode  : constant String := "rb" & ASCII.NUL;
      Write_Mode : constant String := "wb" & ASCII.NUL;
      Source     : System.Address;
      Target     : System.Address;
   begin
      Log ("CP", Src & " -> " & Dst);
      Source := C_Fopen (C_Src'Address, Read_Mode'Address);
      if Sys_Is_Null (Source) then
         Panic ("Copy_File: cannot open " & Src);
      end if;
      Target := C_Fopen (C_Dst'Address, Write_Mode'Address);
      if Sys_Is_Null (Target) then
         Ignore (C_Fclose (Source));
         Panic ("Copy_File: cannot create " & Dst);
      end if;
      declare
         Buffer : String (1 .. 65536);
         Got    : Long;
         Put    : Long;
      begin
         loop
            Got := C_Fread (Buffer'Address, 1, Long (Buffer'Length),
                            Source);
            exit when Got <= 0;
            Put := C_Fwrite (Buffer'Address, 1, Got, Target);
            if Put /= Got then
               Ignore (C_Fclose (Source));
               Ignore (C_Fclose (Target));
               Panic ("Copy_File: short write to " & Dst);
            end if;
         end loop;
      end;
      Ignore (C_Fclose (Source));
      if C_Fclose (Target) /= 0 then
         Panic ("Copy_File: close failed for " & Dst);
      end if;
   end Copy_File;

   procedure Copy_Dir (Src, Dst : String) is
      Handle    : System.Address;
      Name_Buf  : String (1 .. 256);
      Name_Last : Natural;
      Kind_Code : Integer;
   begin
      Make_Dirs (Dst);
      Handle := Open_Dir_Or_Panic (Src);
      begin
      loop
         Next_Dir_Entry (Handle, Name_Buf, Name_Last, Kind_Code);
         exit when Name_Last = 0;
         declare
            Name : constant String := Name_Buf (1 .. Name_Last);
         begin
            if Name /= "." and then Name /= ".." then
               declare
                  From : constant String := Src / Name;
                  To   : constant String := Dst / Name;
               begin
                  case Entry_Kind (From, Kind_Code) is
                     when Directory =>
                        Copy_Dir (From, To);
                     when Regular_File =>
                        Copy_File (From, To);
                     when Symlink | Other =>
                        null;
                  end case;
               end;
            end if;
         end;
      end loop;
      Close_Dir (Handle);
      exception
         when others =>
            Close_Dir (Handle);
            raise;
      end;
   end Copy_Dir;

   function Read_File (Path : String) return String is
      C_Path    : constant String := Path & ASCII.NUL;
      Read_Mode : constant String := "rb" & ASCII.NUL;
      Stream    : System.Address;
      Size      : Long;
   begin
      Stream := C_Fopen (C_Path'Address, Read_Mode'Address);
      if Sys_Is_Null (Stream) then
         Panic ("Read_File: cannot open " & Path);
      end if;
      Ignore (C_Fseek (Stream, 0, Seek_End));
      Size    := C_Ftell (Stream);
      Ignore (C_Fseek (Stream, 0, Seek_Set));
      declare
         Result : String (1 .. Integer (Size));
         Got    : Long;
      begin
         Got := C_Fread (Result'Address, 1, Size, Stream);
         Ignore (C_Fclose (Stream));
         if Got /= Size then
            Panic ("Read_File: short read from " & Path);
         end if;
         return Result;
      end;
   end Read_File;

   procedure Write_File (Path : String; Contents : String) is
      C_Path     : constant String := Path & ASCII.NUL;
      Write_Mode : constant String := "wb" & ASCII.NUL;
      Stream     : System.Address;
      Put        : Long;
   begin
      Stream := C_Fopen (C_Path'Address, Write_Mode'Address);
      if Sys_Is_Null (Stream) then
         Panic ("Write_File: cannot create " & Path);
      end if;
      if Contents'Length > 0 then
         Put := C_Fwrite (Contents'Address, 1, Long (Contents'Length),
                          Stream);
         if Put /= Long (Contents'Length) then
            Panic ("Write_File: short write to " & Path);
         end if;
      end if;
      if C_Fclose (Stream) /= 0 then
         Panic ("Write_File: close failed for " & Path);
      end if;
   end Write_File;

   function Get_Current_Dir return String is
      Here : constant String := Sys_Working_Directory;
   begin
      if Here'Length = 0 then
         Panic ("cannot read the working directory");
      end if;
      return Here;
   end Get_Current_Dir;

   procedure Set_Current_Dir (Path : String) is
   begin
      Log ("CD", Path);
      if not Sys_Change_Directory (Path) then
         Panic ("chdir failed: " & Path);
      end if;
   end Set_Current_Dir;

   function Is_Newer (Path1, Path2 : String) return Boolean is
      Found1, Found2 : Boolean;
      Dir1, Dir2     : Boolean;
      Sec1, Nsec1    : Long;
      Sec2, Nsec2    : Long;
   begin
      Sys_File_Status (Path1, Found1, Dir1, Sec1, Nsec1);
      if not Found1 then
         return False;
      end if;
      Sys_File_Status (Path2, Found2, Dir2, Sec2, Nsec2);
      if not Found2 then
         return True;
      end if;
      if Long (Sec1) /= Long (Sec2) then
         return Long (Sec1) > Long (Sec2);
      end if;
      return Long (Nsec1) > Long (Nsec2);
   end Is_Newer;

   function Needs_Rebuild (Output : String; Inputs : Argument_List)
     return Boolean is
   begin
      if not Path_Exists (Output) then
         return True;
      end if;
      for I in 1 .. Length (Inputs) loop
         if Is_Newer (Element (Inputs, I), Output) then
            return True;
         end if;
      end loop;
      return False;
   end Needs_Rebuild;

   procedure For_Each_File (Dir : String; Suffix : String := "") is
      Handle    : System.Address;
      Name_Buf  : String (1 .. 256);
      Name_Last : Natural;
      Kind_Code : Integer;
   begin
      Handle := Open_Dir_Or_Panic (Dir);
      begin
      loop
         Next_Dir_Entry (Handle, Name_Buf, Name_Last, Kind_Code);
         exit when Name_Last = 0;
         declare
            Name : constant String := Name_Buf (1 .. Name_Last);
         begin
            if Name /= "." and then Name /= ".." and then
               (Suffix'Length = 0 or else Ends_With (Name, Suffix))
            then
               Process (Name);
            end if;
         end;
      end loop;
      Close_Dir (Handle);
      exception
         when others =>
            Close_Dir (Handle);
            raise;
      end;
   end For_Each_File;

   procedure Walk_Dir (Root : String) is
      Walk_Stopped : exception;

      procedure Recurse (Dir : String; Depth : Natural) is
         Handle    : System.Address;
         Name_Buf  : String (1 .. 256);
         Name_Last : Natural;
         Kind_Code : Integer;
      begin
         Handle := Open_Dir_Or_Panic (Dir);
         begin
         loop
            Next_Dir_Entry (Handle, Name_Buf, Name_Last, Kind_Code);
            exit when Name_Last = 0;
            declare
               Name : constant String := Name_Buf (1 .. Name_Last);
            begin
               if Name /= "." and then Name /= ".." then
                  declare
                     Full : constant String := Dir / Name;
                     Kind : constant File_Kind :=
                       Entry_Kind (Full, Kind_Code);
                     Action : constant Walk_Action :=
                       Func ((Path_Len => Full'Length,
                              Name_Len => Name'Length,
                              Path     => Full,
                              Name     => Name,
                              Kind     => Kind,
                              Depth    => Depth));
                  begin
                     case Action is
                        when Walk_Stop =>
                           raise Walk_Stopped;
                        when Walk_Skip =>
                           null;
                        when Walk_Continue =>
                           if Kind = Directory then
                              Recurse (Full, Depth + 1);
                           end if;
                     end case;
                  end;
               end if;
            end;
         end loop;
         Close_Dir (Handle);
         exception
            when others =>
               Close_Dir (Handle);
               raise;
         end;
      end Recurse;
   begin
      Recurse (Root, 0);
   exception
      when Walk_Stopped =>
         null;
   end Walk_Dir;

   --  Bin is Binary_Path with the platform's executable suffix: on Windows
   --  the compiler adds .exe, so the timestamp, the backup and the re-exec
   --  all have to name the file that actually exists.
   procedure Rebuild_And_Reexec
     (Bin         : String;
      Binary_Path : String;
      Source_Path : String;
      Extra       : Argument_List) is

      Old_Binary : constant String := Bin & ".old";

      --  What bootstrap left beside the build script.  ada83 skips
      --  compiling a unit whose .ll is already on the include path, so
      --  those modules have to be named on the command line or nothing
      --  resolves them; where no .ll was left, -I reaches the source.
      Library_Module : constant String := "no_build.ll";

      procedure Discard_Old_Binary is
      begin
         if Path_Exists (Old_Binary) then
            Remove_Path (Old_Binary);
         end if;
      exception
         when others =>
            null;
      end Discard_Old_Binary;

   begin
      --  Sweep up an .old left by a previous run: on Windows the running
      --  executable owns its file until exec, so that rebuild could not
      --  delete it.
      Discard_Old_Binary;

      if not Is_Newer (Source_Path, Bin) then
         return;
      end if;

      Info ("build script changed, rebuilding: " & Source_Path);
      if Path_Exists (Bin) then
         Rename_Path (Bin, Old_Binary);
      end if;

      declare
         Modules : Argument_List;
         Flags   : Argument_List;
      begin
         if Path_Exists (Library_Module) then
            Append (Modules, Library_Module);
         end if;
         Append (Flags, Extra);

         begin
            Compile_Program (Source_Path, Binary_Path, Modules, Flags);
         exception
            when others =>
               Clear (Modules);
               Clear (Flags);
               if Path_Exists (Old_Binary) then
                  Rename_Path (Old_Binary, Bin);
               end if;
               raise;
         end;

         Clear (Modules);
         Clear (Flags);
      end;

      Discard_Old_Binary;

      declare
         Forwarded : Argument_List;
         Pid       : Integer;
      begin
         for I in 1 .. Command_Line.Argument_Count loop
            Append (Forwarded, Command_Line.Argument (I));
         end loop;
         Info ("re-executing: " & Bin);
         Pid := Spawn (Bin, Forwarded, No_Redirect);
         Ignore (Sys_Wait_For (Pid));
         Clear (Forwarded);
      end;

      --  Leave this, the superseded process; the rebuilt one has run.
      Sys_Exit_Process (0);
   end Rebuild_And_Reexec;

   procedure Go_Rebuild_Urself
     (Binary_Path : String;
      Source_Path : String;
      Extra       : Argument_List := No_Args) is
   begin
      if not Path_Exists (Source_Path) then
         return;
      end if;
      if System.Target_OS = System.Windows and then
         not Ends_With (Binary_Path, ".exe")
      then
         Rebuild_And_Reexec (Binary_Path & ".exe", Binary_Path,
                             Source_Path, Extra);
      else
         Rebuild_And_Reexec (Binary_Path, Binary_Path, Source_Path, Extra);
      end if;
   end Go_Rebuild_Urself;

end No_Build;
