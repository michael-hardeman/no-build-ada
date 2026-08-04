--  posix/platform_support.adb -- Linux and macOS.
--
--  Both are POSIX, so the entry points are the same; what differs is
--  arithmetic.  The two systems disagree about the layout of struct stat
--  and struct dirent, about the value of O_CREAT and O_TRUNC, and about
--  the sysconf selector for the processor count.  Every such difference
--  is answered by Host below, in one place each, rather than by a second
--  copy of the code.
--
--  Known limitation: on x86_64 macOS the C library exports stat as
--  stat$INODE64, and the plain name binds to a variant that predates
--  64-bit inodes.  This body imports "stat", which is correct on arm64
--  macOS and on Linux.

with System;
with Unchecked_Conversion;

package body Platform_Support is

   --  struct stat and struct dirent read as words and as bytes; the
   --  offsets below index these.
   type Word_Array is array (1 .. 32) of Long;
   type Byte_Array is array (1 .. 1200) of Character;
   type Byte_Array_Ptr is access Byte_Array;

   Dirent_Words : Word_Array;

   Host_Known : Boolean   := False;
   Host_Value : Host_Kind := Linux;

   Dirent_Type_Unknown   : constant Integer := 0;
   Dirent_Type_Directory : constant Integer := 4;
   Dirent_Type_Regular   : constant Integer := 8;

   --------------------------------------------------------------------------
   --  C
   --------------------------------------------------------------------------

   function C_Access (Path : System.Address; Mode : Integer) return Integer;
   pragma Import (C, C_Access, "access");

   function C_Fputs (S : System.Address; Stream : System.Address)
     return Integer;
   pragma Import (C, C_Fputs, "fputs");

   function C_Stderr return System.Address;
   pragma Import (C, C_Stderr, "__ada_stderr");

   function C_Fork return Integer;
   pragma Import (C, C_Fork, "fork");

   function C_Execvp (File : System.Address; Argv : System.Address)
     return Integer;
   pragma Import (C, C_Execvp, "execvp");

   function C_Waitpid (Pid : Integer; Status : System.Address;
                       Options : Integer) return Integer;
   pragma Import (C, C_Waitpid, "waitpid");

   procedure C_Exit (Status : Integer);
   pragma Import (C, C_Exit, "_exit");

   function C_Open (Path : System.Address; Flags : Integer; Mode : Integer)
     return Integer;
   pragma Import (C, C_Open, "open");

   function C_Close (Fd : Integer) return Integer;
   pragma Import (C, C_Close, "close");

   function C_Dup2 (Old_Fd, New_Fd : Integer) return Integer;
   pragma Import (C, C_Dup2, "dup2");

   function C_Getpid return Integer;
   pragma Import (C, C_Getpid, "getpid");

   function C_Sysconf (Name : Integer) return Long;
   pragma Import (C, C_Sysconf, "sysconf");

   function C_Stat (Path : System.Address; Buf : System.Address)
     return Integer;
   pragma Import (C, C_Stat, "stat");

   function C_Mkdir (Path : System.Address; Mode : Integer) return Integer;
   pragma Import (C, C_Mkdir, "mkdir");

   function C_Rmdir (Path : System.Address) return Integer;
   pragma Import (C, C_Rmdir, "rmdir");

   function C_Unlink (Path : System.Address) return Integer;
   pragma Import (C, C_Unlink, "unlink");

   function C_Rename (Old_Path, New_Path : System.Address) return Integer;
   pragma Import (C, C_Rename, "rename");

   function C_Chdir (Path : System.Address) return Integer;
   pragma Import (C, C_Chdir, "chdir");

   function C_Getcwd (Buffer : System.Address; Size : Long)
     return System.Address;
   pragma Import (C, C_Getcwd, "getcwd");

   function C_Opendir (Path : System.Address) return System.Address;
   pragma Import (C, C_Opendir, "opendir");

   function C_Readdir_R (Dir : System.Address; Entry_Buf : System.Address;
                         Result : System.Address) return Integer;
   pragma Import (C, C_Readdir_R, "readdir_r");

   function C_Closedir (Dir : System.Address) return Integer;
   pragma Import (C, C_Closedir, "closedir");

   function To_Long is new Unchecked_Conversion (System.Address, Long);
   function To_Bytes is
     new Unchecked_Conversion (System.Address, Byte_Array_Ptr);

   procedure Ignore (X : Integer) is
      pragma Unreferenced (X);
   begin
      null;
   end Ignore;

   function Is_Null (A : System.Address) return Boolean is
   begin
      return To_Long (A) = 0;
   end Is_Null;

   --------------------------------------------------------------------------
   --  Host
   --------------------------------------------------------------------------

   function Host return Host_Kind is
   begin
      if not Host_Known then
         --  sw_vers ships on macOS and nowhere else.
         declare
            Probe : constant String := "/usr/bin/sw_vers" & ASCII.NUL;
         begin
            if C_Access (Probe'Address, 0) = 0 then
               Host_Value := MacOS;
            else
               Host_Value := Linux;
            end if;
         end;
         Host_Known := True;
      end if;
      return Host_Value;
   end Host;

   function Path_Separator return Character is
   begin
      return '/';
   end Path_Separator;

   function Shell_Program return String is
   begin
      return "/bin/sh";
   end Shell_Program;

   function Shell_Flag return String is
   begin
      return "-c";
   end Shell_Flag;

   --------------------------------------------------------------------------
   --  Per-system numbers
   --------------------------------------------------------------------------

   --  O_WRONLY or O_CREAT or O_TRUNC.  O_CREAT is 0100 on Linux and
   --  0x200 on macOS; O_TRUNC is 01000 and 0x400.
   function Open_Write_Create_Truncate return Integer is
   begin
      if Host = MacOS then
         return 1537;
      end if;
      return 577;
   end Open_Write_Create_Truncate;

   --  _SC_NPROCESSORS_ONLN
   function Sysconf_Cpus return Integer is
   begin
      if Host = MacOS then
         return 58;
      end if;
      return 84;
   end Sysconf_Cpus;

   --  Word holding st_mode, and the width of the field within it.
   --  Linux: a 32-bit st_mode at byte 24.  macOS: a 16-bit st_mode at
   --  byte 4, so the low word carries st_dev beneath it.
   function Stat_Mode (Words : Word_Array) return Integer is
   begin
      if Host = MacOS then
         return Integer ((Words (1) / 4294967296) mod 65536);
      end if;
      return Integer ((Words (4) mod 4294967296) mod 65536);
   end Stat_Mode;

   --  st_mtim(e).tv_sec: byte 88 on Linux, byte 48 on macOS.
   function Stat_Mtime_Word return Integer is
   begin
      if Host = MacOS then
         return 7;
      end if;
      return 12;
   end Stat_Mtime_Word;

   --  d_type, then the first byte of d_name, one-based.  macOS carries an
   --  eight-byte d_seekoff that Linux does not.
   function Dirent_Type_Index return Integer is
   begin
      if Host = MacOS then
         return 21;
      end if;
      return 19;
   end Dirent_Type_Index;

   --------------------------------------------------------------------------
   --  Diagnostics
   --------------------------------------------------------------------------

   procedure Write_Error (Line : String) is
      Buffer : constant String := Line & ASCII.LF & ASCII.NUL;
   begin
      Ignore (C_Fputs (Buffer'Address, C_Stderr));
   end Write_Error;

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
      Ignore (C_Dup2 (File_Fd, Fd));
      Ignore (C_Close (File_Fd));
   end Redirect_Child;

   function Spawn
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
         Ignore (C_Execvp (Vector (1), Vector'Address));
         C_Exit (127);
      elsif Pid < 0 then
         return Spawn_Failed;
      end if;
      return Pid;
   end Spawn;

   function Wait_For (Handle : Integer) return Integer is
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
   end Wait_For;

   procedure Exit_Process (Status : Integer) is
   begin
      C_Exit (Status);
   end Exit_Process;

   function Process_Id return Integer is
   begin
      return C_Getpid;
   end Process_Id;

   function Cpu_Count return Positive is
      Count : constant Long := C_Sysconf (Sysconf_Cpus);
   begin
      if Count < 1 then
         return 1;
      end if;
      return Positive (Count);
   end Cpu_Count;

   --------------------------------------------------------------------------
   --  Files and directories
   --------------------------------------------------------------------------

   procedure File_Status
     (Path         : String;
      Found        : out Boolean;
      Is_Directory : out Boolean;
      Mtime_Sec    : out Long;
      Mtime_Nsec   : out Long) is
      C_Path : constant String := Path & ASCII.NUL;
      Words  : Word_Array;
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
   end File_Status;

   function Exists (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Access (C_Path'Address, 0) = 0;
   end Exists;

   function Make_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Mkdir (C_Path'Address, 493) = 0;   --  0755
   end Make_Directory;

   function Remove_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Rmdir (C_Path'Address) = 0;
   end Remove_Directory;

   function Remove_File (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Unlink (C_Path'Address) = 0;
   end Remove_File;

   function Change_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Chdir (C_Path'Address) = 0;
   end Change_Directory;

   function Rename_Path (Old_Path, New_Path : String) return Boolean is
      C_Old : constant String := Old_Path & ASCII.NUL;
      C_New : constant String := New_Path & ASCII.NUL;
   begin
      return C_Rename (C_Old'Address, C_New'Address) = 0;
   end Rename_Path;

   function Working_Directory return String is
      Buffer : String (1 .. 4096);
   begin
      if Is_Null (C_Getcwd (Buffer'Address, Long (Buffer'Length))) then
         return "";
      end if;
      for I in Buffer'Range loop
         if Buffer (I) = ASCII.NUL then
            return Buffer (1 .. I - 1);
         end if;
      end loop;
      return "";
   end Working_Directory;

   --------------------------------------------------------------------------
   --  Directory listing
   --------------------------------------------------------------------------

   function Open_Dir (Path : String) return System.Address is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Opendir (C_Path'Address);
   end Open_Dir;

   procedure Read_Dir
     (Handle       : System.Address;
      Name         : out String;
      Last         : out Natural;
      Is_Directory : out Boolean;
      Is_File      : out Boolean) is
      Result     : System.Address;
      Bytes      : Byte_Array_Ptr;
      Type_Index : constant Integer := Dirent_Type_Index;
      Kind       : Integer;
      Name_First : Integer;
   begin
      Last         := 0;
      Is_Directory := False;
      Is_File      := False;
      if Is_Null (Handle) then
         return;
      end if;
      if C_Readdir_R (Handle, Dirent_Words'Address, Result'Address) /= 0
        or else Is_Null (Result)
      then
         return;
      end if;

      Bytes      := To_Bytes (Dirent_Words'Address);
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
      --  caller settles it with File_Status: only the caller knows the
      --  directory this name sits in.
      if Kind = Dirent_Type_Directory then
         Is_Directory := True;
      elsif Kind = Dirent_Type_Regular then
         Is_File := True;
      end if;
   end Read_Dir;

   procedure Close_Dir (Handle : System.Address) is
   begin
      if not Is_Null (Handle) then
         Ignore (C_Closedir (Handle));
      end if;
   end Close_Dir;

end Platform_Support;
