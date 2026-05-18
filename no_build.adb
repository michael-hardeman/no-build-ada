--  no_build.adb -- Implementation of the No_Build package.
with Ada.Text_IO;
with Ada.Calendar;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
with Interfaces.C;
with Interfaces.C.Strings;
with System;
with System.Multiprocessors;
with System.Storage_Elements;

package body No_Build is

   use Ada.Text_IO;
   use type System.Address;

   --  dlopen / dlsym are the only pragma Import in this package; every
   --  other OS call is resolved through them at elaboration time.  Windows
   --  callers must supply a shim — see the README.

   type DL_Handle is new System.Address;

   function Default_DL_Open (Path : System.Address; Mode : Integer) return DL_Handle;
   pragma Import (C, Default_DL_Open, "dlopen");

   function Default_DL_Sym (Handle : DL_Handle; Symbol : System.Address) return System.Address;
   pragma Import (C, Default_DL_Sym, "dlsym");

   function To_Address is new Ada.Unchecked_Conversion (Interfaces.C.Strings.chars_ptr, System.Address);

   function Sym (Handle : DL_Handle; Name : String) return System.Address is
      C_Name : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Name);
      Result : System.Address;
   begin
      Result := Default_DL_Sym (Handle, To_Address (C_Name));
      Interfaces.C.Strings.Free (C_Name);
      return Result;
   end Sym;

   --------------------------------------------------------------------------
   --  POSIX process function pointer types (loaded via dlsym at elaboration)
   --------------------------------------------------------------------------

   type Fork_Func is access function
      return Interfaces.C.int with Convention => C;

   type Execv_Func is access function (
      Path : System.Address;
      Argv : System.Address)
      return Interfaces.C.int with Convention => C;

   type Waitpid_Func is access function (
      Pid     : Interfaces.C.int;
      Status  : access Interfaces.C.int;
      Options : Interfaces.C.int) 
      return Interfaces.C.int with Convention => C;

   type Exit_Func is access procedure (Status : Interfaces.C.int);
   pragma Convention (C, Exit_Func);

   type Dup2_Func is access function (
      Old_FD, New_FD : Interfaces.C.int)
      return Interfaces.C.int with Convention => C;

   type Open_Func is access function (
      Path  : System.Address;
      Flags : Interfaces.C.int;
      Mode  : Interfaces.C.int)
      return Interfaces.C.int with Convention => C;

   type Close_Func is access function (
      FD : Interfaces.C.int)
      return Interfaces.C.int with Convention => C;

   type Rename_Func is access function (
      Old_Path, New_Path : System.Address)
      return Interfaces.C.int with Convention => C;

   function Is_Ok (X : Interfaces.C.int) return Boolean is (Interfaces.C."=" (X, 0));

   function To_Fork    is new Ada.Unchecked_Conversion (System.Address, Fork_Func);
   function To_Execv   is new Ada.Unchecked_Conversion (System.Address, Execv_Func);
   function To_Waitpid is new Ada.Unchecked_Conversion (System.Address, Waitpid_Func);
   function To_Exit    is new Ada.Unchecked_Conversion (System.Address, Exit_Func);
   function To_Dup2    is new Ada.Unchecked_Conversion (System.Address, Dup2_Func);
   function To_Open    is new Ada.Unchecked_Conversion (System.Address, Open_Func);
   function To_Close   is new Ada.Unchecked_Conversion (System.Address, Close_Func);
   function To_Rename  is new Ada.Unchecked_Conversion (System.Address, Rename_Func);

   --  Initialized by Load_Posix_Symbols at elaboration.
   C_Fork    : Fork_Func    := null;
   C_Execv   : Execv_Func   := null;
   C_Waitpid : Waitpid_Func := null;
   C_Exit    : Exit_Func    := null;
   C_Dup2    : Dup2_Func    := null;
   C_Open    : Open_Func    := null;
   C_Close   : Close_Func   := null;
   C_Rename  : Rename_Func  := null;

   --  POSIX open(2) constants.  O_CREAT/O_TRUNC differ between Linux and macOS.
   O_WRONLY : constant := 1;
   O_CREAT  : constant := 64;
   O_TRUNC  : constant := 512;

   function Open_Flags return Interfaces.C.int is begin
      if Platform = MacOS then
         return Interfaces.C.int (O_WRONLY + 16#200# + 16#400#);
      else
         return Interfaces.C.int (O_WRONLY + O_CREAT + O_TRUNC);
      end if;
   end Open_Flags;

   procedure Load_Posix_Symbols is
      Lib : DL_Handle;
   begin
      --  dlopen(NULL, RTLD_LAZY): main image, picking up libc.
      Lib := Default_DL_Open (System.Null_Address, 1);

      C_Fork    := To_Fork    (Sym (Lib, "fork"));
      C_Execv   := To_Execv   (Sym (Lib, "execv"));
      C_Waitpid := To_Waitpid (Sym (Lib, "waitpid"));
      C_Exit    := To_Exit    (Sym (Lib, "_exit"));
      C_Dup2    := To_Dup2    (Sym (Lib, "dup2"));
      C_Open    := To_Open    (Sym (Lib, "open"));
      C_Close   := To_Close   (Sym (Lib, "close"));
      C_Rename  := To_Rename  (Sym (Lib, "rename"));

      if C_Fork = null or else C_Execv = null or else C_Waitpid = null
        or else C_Exit = null or else C_Dup2 = null or else C_Open = null
        or else C_Close = null or else C_Rename = null
      then
         raise Build_Error with "failed to resolve libc symbols via dlsym";
      end if;
   end Load_Posix_Symbols;

   --  Win32 equivalents loaded from kernel32.dll on Windows; fork/execv
   --  don't exist there.

   subtype Win_DWORD is Interfaces.C.unsigned;
   subtype Win_WORD  is Interfaces.C.unsigned_short;
   subtype Win_BOOL  is Interfaces.C.int;

   Win_FALSE                 : constant Win_BOOL  := 0;
   Win_TRUE                  : constant Win_BOOL  := 1;
   Win_STARTF_USESTDHANDLES  : constant Win_DWORD := 16#0000_0100#;
   Win_INFINITE              : constant Win_DWORD := 16#FFFF_FFFF#;
   --  GetStdHandle IDs: -10/-11/-12 as unsigned.
   Win_STD_INPUT_HANDLE      : constant Win_DWORD := 16#FFFF_FFF6#;
   Win_STD_OUTPUT_HANDLE     : constant Win_DWORD := 16#FFFF_FFF5#;
   Win_STD_ERROR_HANDLE      : constant Win_DWORD := 16#FFFF_FFF4#;
   Win_GENERIC_WRITE         : constant Win_DWORD := 16#4000_0000#;
   Win_FILE_SHARE_READ       : constant Win_DWORD := 16#0000_0001#;
   Win_FILE_SHARE_WRITE      : constant Win_DWORD := 16#0000_0002#;
   Win_CREATE_ALWAYS         : constant Win_DWORD := 2;
   Win_FILE_ATTRIBUTE_NORMAL : constant Win_DWORD := 16#0000_0080#;
   --  MoveFileExA: REPLACE_EXISTING overwrites, COPY_ALLOWED crosses volumes.
   Win_MOVEFILE_REPLACE_EXISTING : constant Win_DWORD := 16#0000_0001#;
   Win_MOVEFILE_COPY_ALLOWED     : constant Win_DWORD := 16#0000_0002#;

   function Win_Is_Error (Result : Win_BOOL) return Boolean is (Interfaces.C."=" (Result, Win_FALSE));
   function Win_Is_Ok    (Result : Win_BOOL) return Boolean is (Interfaces.C."=" (Result, Win_TRUE));

   type Win_Startup_Info is record
      Cb              : Win_DWORD      := 0;
      Reserved        : System.Address := System.Null_Address;
      Desktop         : System.Address := System.Null_Address;
      Title           : System.Address := System.Null_Address;
      X               : Win_DWORD      := 0;
      Y               : Win_DWORD      := 0;
      X_Size          : Win_DWORD      := 0;
      Y_Size          : Win_DWORD      := 0;
      X_Count_Chars   : Win_DWORD      := 0;
      Y_Count_Chars   : Win_DWORD      := 0;
      Fill_Attribute  : Win_DWORD      := 0;
      Flags           : Win_DWORD      := 0;
      Show_Window     : Win_WORD       := 0;
      Cb_Reserved2    : Win_WORD       := 0;
      Reserved2       : System.Address := System.Null_Address;
      H_Std_Input     : System.Address := System.Null_Address;
      H_Std_Output    : System.Address := System.Null_Address;
      H_Std_Error     : System.Address := System.Null_Address;
   end record with Convention => C;

   type Win_Process_Info is record
      H_Process  : System.Address := System.Null_Address;
      H_Thread   : System.Address := System.Null_Address;
      Process_Id : Win_DWORD      := 0;
      Thread_Id  : Win_DWORD      := 0;
   end record with Convention => C;

   type Win_Security_Attrs is record
      Length     : Win_DWORD      := 0;
      Descriptor : System.Address := System.Null_Address;
      Inherit    : Win_BOOL       := 0;
   end record with Convention => C;

   type CreateProcess_Func is access function (
      App_Name        : System.Address;
      Cmd_Line        : System.Address;
      Proc_Attrs      : System.Address;
      Thread_Attrs    : System.Address;
      Inherit_Handles : Win_BOOL;
      Creation_Flags  : Win_DWORD;
      Environment     : System.Address;
      Current_Dir     : System.Address;
      Startup_Info    : System.Address;
      Process_Info    : System.Address)
      return Win_BOOL with Convention => Stdcall;

   type WaitForSingleObject_Func is access function (
      Handle       : System.Address;
      Milliseconds : Win_DWORD)
      return Win_DWORD with Convention => Stdcall;

   type GetExitCodeProcess_Func is access function (
      Process   : System.Address;
      Exit_Code : access Win_DWORD)
      return Win_BOOL with Convention => Stdcall;

   type CloseHandle_Func is access function (
      Handle : System.Address)
      return Win_BOOL with Convention => Stdcall;

   type CreateFile_Func is access function (
      File_Name      : System.Address;
      Desired_Access : Win_DWORD;
      Share_Mode     : Win_DWORD;
      Security_Attrs : System.Address;
      Creation_Disp  : Win_DWORD;
      Flags_Attrs    : Win_DWORD;
      Template_File  : System.Address)
      return System.Address with Convention => Stdcall;

   type GetStdHandle_Func is access function (
      Std_Handle : Win_DWORD)
      return System.Address with Convention => Stdcall;

   type ExitProcess_Func is access procedure (
      Exit_Code : Win_DWORD) with Convention => Stdcall;

   type MoveFileEx_Func is access function (
      Existing : System.Address;
      New_Name : System.Address;
      Flags    : Win_DWORD)
      return Win_BOOL with Convention => Stdcall;

   function To_CreateProcess       is new Ada.Unchecked_Conversion (System.Address, CreateProcess_Func);
   function To_WaitForSingleObject is new Ada.Unchecked_Conversion (System.Address, WaitForSingleObject_Func);
   function To_GetExitCodeProcess  is new Ada.Unchecked_Conversion (System.Address, GetExitCodeProcess_Func);
   function To_CloseHandle         is new Ada.Unchecked_Conversion (System.Address, CloseHandle_Func);
   function To_CreateFile          is new Ada.Unchecked_Conversion (System.Address, CreateFile_Func);
   function To_GetStdHandle        is new Ada.Unchecked_Conversion (System.Address, GetStdHandle_Func);
   function To_ExitProcess         is new Ada.Unchecked_Conversion (System.Address, ExitProcess_Func);
   function To_MoveFileEx          is new Ada.Unchecked_Conversion (System.Address, MoveFileEx_Func);

   W_CreateProcess       : CreateProcess_Func       := null;
   W_WaitForSingleObject : WaitForSingleObject_Func := null;
   W_GetExitCodeProcess  : GetExitCodeProcess_Func  := null;
   W_CloseHandle         : CloseHandle_Func         := null;
   W_CreateFile          : CreateFile_Func          := null;
   W_GetStdHandle        : GetStdHandle_Func        := null;
   W_ExitProcess         : ExitProcess_Func         := null;
   W_MoveFileEx          : MoveFileEx_Func          := null;

   procedure Load_Win32_Symbols is
      use Interfaces.C.Strings;
      Name : chars_ptr := New_String ("kernel32.dll");
      Lib  : DL_Handle;
   begin
      Lib := Default_DL_Open (To_Address (Name), 0);
      Free (Name);
      if System.Address (Lib) = System.Null_Address then
         raise Build_Error with "failed to load kernel32.dll";
      end if;

      W_CreateProcess       := To_CreateProcess       (Sym (Lib, "CreateProcessA"));
      W_WaitForSingleObject := To_WaitForSingleObject (Sym (Lib, "WaitForSingleObject"));
      W_GetExitCodeProcess  := To_GetExitCodeProcess  (Sym (Lib, "GetExitCodeProcess"));
      W_CloseHandle         := To_CloseHandle         (Sym (Lib, "CloseHandle"));
      W_CreateFile          := To_CreateFile          (Sym (Lib, "CreateFileA"));
      W_GetStdHandle        := To_GetStdHandle        (Sym (Lib, "GetStdHandle"));
      W_ExitProcess         := To_ExitProcess         (Sym (Lib, "ExitProcess"));
      W_MoveFileEx          := To_MoveFileEx          (Sym (Lib, "MoveFileExA"));

      if W_CreateProcess = null
        or else W_WaitForSingleObject = null
        or else W_GetExitCodeProcess = null
        or else W_CloseHandle = null
        or else W_CreateFile = null
        or else W_GetStdHandle = null
        or else W_ExitProcess = null
        or else W_MoveFileEx = null
      then
         raise Build_Error
           with "failed to resolve kernel32.dll symbols";
      end if;
   end Load_Win32_Symbols;

   --------------------------------------------------------------------------
   --  Ignore
   --------------------------------------------------------------------------

   procedure Ignore (X : System.Address)        is null;
   procedure Ignore (X : Interfaces.C.int)      is null;
   procedure Ignore (X : Interfaces.C.unsigned) is null;
   procedure Ignore (X : Boolean)               is null;

   --------------------------------------------------------------------------
   --  Logging
   --------------------------------------------------------------------------

   procedure Default_Log_Handler (Tag, Msg : String) is begin
      Put_Line (Standard_Error, "[" & Tag & "] " & Msg);
   end Default_Log_Handler;

   Active_Handler : Log_Handler := Default_Log_Handler'Access;

   procedure Log (Tag, Msg : String) is begin
      if Active_Handler /= null then
         Active_Handler (Tag, Msg);
      end if;
   end Log;

   procedure Set_Log_Handler (Handler : Log_Handler) is begin
      if Handler = null then
         Active_Handler := Default_Log_Handler'Access;
      else
         Active_Handler := Handler;
      end if;
   end Set_Log_Handler;

   --------------------------------------------------------------------------
   --  String_Access helper
   --------------------------------------------------------------------------

   function S (Str : String) return not null String_Access is begin
      return new String'(Str);
   end S;

   --------------------------------------------------------------------------
   --  Command execution
   --------------------------------------------------------------------------

   procedure Sh (Command : String) is begin
      case Platform is
         when Linux | MacOS =>
            Cmd ("/bin/sh", Argument_List'(S ("-c"), S (Command)));
         when Windows =>
            Cmd ("cmd.exe", Argument_List'(S ("/c"), S (Command)));
      end case;
   end Sh;

   --------------------------------------------------------------------------
   --  Internal helpers: PATH search (replaces GNAT.OS_Lib.Locate_Exec_On_Path)
   --------------------------------------------------------------------------

   function Resolve_Program
     (Program : String;
      Display : String) return String
   is
      function Has_Slash return Boolean is
        (for some C of Program => C = '/' or else C = '\');

      --  Return a usable path: Path itself if it points to a regular file,
      --  Path & ".exe" on Windows if that exists, else "".
      function Probe_With_Exe (Path : String) return String is
         use Ada.Directories;
      begin
         if Exists (Path) and then Kind (Path) = Ordinary_File then
            return Path;
         end if;
         if Platform = Windows and then not Ends_With (Path, ".exe") then
            declare
               Exe : constant String := Path & ".exe";
            begin
               if Exists (Exe) and then Kind (Exe) = Ordinary_File then
                  return Exe;
               end if;
            end;
         end if;
         return "";
      end Probe_With_Exe;

      Separator : constant Character :=
        (if Platform = Windows then ';' else ':');
   begin
      Log ("CMD", Display);

      if Has_Slash then
         declare
            Hit : constant String := Probe_With_Exe (Program);
         begin
            if Hit /= "" then
               return Hit;
            end if;
            Log ("ERRO", "program not found: " & Program);
            raise Build_Error with "program not found: " & Program;
         end;
      end if;

      if Ada.Environment_Variables.Exists ("PATH") then
         declare
            PATH  : constant String :=
              Ada.Environment_Variables.Value ("PATH");
            Start : Positive := PATH'First;

            function Try (Dir : String) return String is
              (if Dir = "" then "" else Probe_With_Exe (Dir / Program));
         begin
            for I in PATH'Range loop
               if PATH (I) = Separator then
                  declare
                     Hit : constant String :=
                       Try (PATH (Start .. I - 1));
                  begin
                     if Hit /= "" then return Hit; end if;
                  end;
                  Start := I + 1;
               end if;
            end loop;
            if Start <= PATH'Last then
               declare
                  Hit : constant String :=
                    Try (PATH (Start .. PATH'Last));
               begin
                  if Hit /= "" then return Hit; end if;
               end;
            end if;
         end;
      end if;

      Log ("ERRO", "program not found on PATH: " & Program);
      raise Build_Error with "program not found: " & Program;
   end Resolve_Program;

   --  Build a display string "program arg1 arg2 ..." for logging.
   function Display_Of
     (Program : String; Args : Argument_List) return String
   is
      use Ada.Strings.Unbounded;
      D : Unbounded_String := To_Unbounded_String (Program);
   begin
      for A of Args loop
         Append (D, " " & A.all);
      end loop;
      return To_String (D);
   end Display_Of;

   --------------------------------------------------------------------------
   --  Internal helpers: POSIX process spawn via dlsym'd fork/execv/waitpid
   --------------------------------------------------------------------------

   --  C argv: NULL-terminated array of NUL-terminated strings, suitable for
   --  passing to execv.
   type C_Str_Array is array (Natural range <>) of
     Interfaces.C.Strings.chars_ptr;
   type C_Str_Array_Access is access C_Str_Array;

   function Build_Argv
     (Prog_Path : String;
      Args      : Argument_List) return C_Str_Array_Access
   is
      use Interfaces.C.Strings;
      Argv : constant C_Str_Array_Access :=
        new C_Str_Array (0 .. Args'Length + 1);
   begin
      Argv (0) := New_String (Prog_Path);
      for I in Args'Range loop
         Argv (I - Args'First + 1) := New_String (Args (I).all);
      end loop;
      Argv (Args'Length + 1) := Null_Ptr;  --  NULL terminator
      return Argv;
   end Build_Argv;

   --  Frees the chars_ptrs; the small C_Str_Array block itself leaks
   --  (one short-lived allocation per Cmd / Cmd_Async).
   procedure Free_Argv (Argv : in out C_Str_Array_Access) is
   begin
      if Argv /= null then
         for I in Argv'Range loop
            Interfaces.C.Strings.Free (Argv (I));
         end loop;
         Argv := null;
      end if;
   end Free_Argv;

   --  Child-side fd redirection (open + dup2 + close).
   procedure Redirect_FD (File_Path : String; Target_FD : Interfaces.C.int) is
      use Interfaces.C;
      use Interfaces.C.Strings;
      C_Path : chars_ptr := New_String (File_Path);
      FD     : int;
   begin
      FD := C_Open (To_Address (C_Path), Open_Flags, 8#644#);
      Free (C_Path);
      if FD < 0 then
         C_Exit (1);
      end if;
      if C_Dup2 (FD, Target_FD) < 0 then
         C_Exit (1);
      end if;
      if FD /= Target_FD then
         Ignore (C_Close (FD));
      end if;
   end Redirect_FD;

   --  WIFEXITED + WEXITSTATUS on a raw waitpid status word; -1 on signal.
   function Exit_Status_Of (Status : Interfaces.C.int) return Integer is
      S : constant Integer := Integer (Status);
   begin
      if (S mod 128) = 0 then
         return (S / 256) mod 256;
      else
         return -1;
      end if;
   end Exit_Status_Of;

   procedure Check_Exit (Code : Integer) is
   begin
      if Code /= 0 then
         Log ("ERRO", "command exited with status" & Code'Image);
         raise Build_Error with "command failed (exit" & Code'Image & ")";
      end if;
   end Check_Exit;

   --  fork+execv child.  Wait_For_Exit => True waits and raises on non-zero;
   --  False returns the child PID packed into a System.Address.
   function Posix_Spawn (Prog_Path      : String;
                         Args           : Argument_List;
                         Stdout_File    : String_Access;
                         Stderr_File    : String_Access;
                         Wait_For_Exit  : Boolean) return System.Address
   is
      use Interfaces.C;
      use type System.Address;
      Argv    : C_Str_Array_Access := Build_Argv (Prog_Path, Args);
      Pid     : int;
      Status  : aliased int;
      Waited  : int;
      C_Path  : Interfaces.C.Strings.chars_ptr;
   begin
      Pid := C_Fork.all;

      if Pid < 0 then
         Free_Argv (Argv);
         raise Build_Error with "fork failed";
      end if;

      if Pid = 0 then
         --  Child process: set up redirections and exec.
         if Stdout_File /= null then
            Redirect_FD (Stdout_File.all, 1);
         end if;
         if Stderr_File /= null then
            Redirect_FD (Stderr_File.all, 2);
         end if;

         C_Path := Interfaces.C.Strings.New_String (Prog_Path);
         Ignore (C_Execv (To_Address (C_Path), Argv (0)'Address));
         --  If execv returns, it failed.
         C_Exit (127);
      end if;

      --  Parent process.
      Free_Argv (Argv);

      if not Wait_For_Exit then
         --  Pack the int PID into a pointer-sized address.
         return System.Storage_Elements.To_Address
                  (System.Storage_Elements.Integer_Address (Pid));
      end if;

      --  Synchronous: wait for child.
      loop
         Waited := C_Waitpid (Pid, Status'Access, 0);
         exit when Waited = Pid or else Waited < 0;
      end loop;

      Check_Exit (Exit_Status_Of (Status));
      return System.Null_Address;
   end Posix_Spawn;

   function Posix_Wait (Pid_Addr : System.Address) return Integer is
      use Interfaces.C;
      Pid    : constant int := int (System.Storage_Elements.To_Integer (Pid_Addr));
      Status : aliased int;
      Waited : int;
   begin
      loop
         Waited := C_Waitpid (Pid, Status'Access, 0);
         exit when Waited = Pid or else Waited < 0;
      end loop;
      return Exit_Status_Of (Status);
   end Posix_Wait;

   --------------------------------------------------------------------------
   --  Win32 process spawn via CreateProcessA
   --------------------------------------------------------------------------

   --  Quote one argument per CommandLineToArgvW's reverse rules: 2n '\'s + '"'
   --  end a quoted run, 2n+1 quote a literal '"', trailing '\'s inside quotes
   --  are doubled.
   procedure Win32_Append_Arg (B : in out Ada.Strings.Unbounded.Unbounded_String; Arg : String) is
      use Ada.Strings.Unbounded;
      Needs_Quote : Boolean := Arg'Length = 0;
   begin
      for C of Arg loop
         if C = ' ' or else C = ASCII.HT or else C = '"' then
            Needs_Quote := True;
            exit;
         end if;
      end loop;

      if not Needs_Quote then
         Append (B, Arg);
         return;
      end if;

      Append (B, '"');
      declare
         I        : Positive := Arg'First;
         BS_Count : Natural;
      begin
         while I <= Arg'Last loop
            BS_Count := 0;
            while I <= Arg'Last and then Arg (I) = '\' loop
               BS_Count := BS_Count + 1;
               I        := I + 1;
            end loop;

            if I > Arg'Last then
               for K in 1 .. 2 * BS_Count loop
                  Append (B, '\');
               end loop;
            elsif Arg (I) = '"' then
               for K in 1 .. 2 * BS_Count + 1 loop
                  Append (B, '\');
               end loop;
               Append (B, '"');
               I := I + 1;
            else
               for K in 1 .. BS_Count loop
                  Append (B, '\');
               end loop;
               Append (B, Arg (I));
               I := I + 1;
            end if;
         end loop;
      end;
      Append (B, '"');
   end Win32_Append_Arg;

   function Build_Command_Line (Prog_Path : String; Args : Argument_List) return String is
      use Ada.Strings.Unbounded;
      B : Unbounded_String;
   begin
      Win32_Append_Arg (B, Prog_Path);
      for A of Args loop
         Append (B, ' ');
         Win32_Append_Arg (B, A.all);
      end loop;
      return To_String (B);
   end Build_Command_Line;

   --  Open a file as an inheritable handle for STARTUPINFO redirection.
   function Win32_Open_For_Redirect (Path : String) return System.Address is
      use Interfaces.C.Strings;
      use System.Storage_Elements;
      use type Interfaces.C.unsigned;
      C_Path : chars_ptr := New_String (Path);
      Security_Attrs : aliased Win_Security_Attrs := (
         Length     => Win_DWORD (Win_Security_Attrs'Object_Size / System.Storage_Unit),
         Descriptor => System.Null_Address,
         Inherit    => Win_TRUE);
      --  INVALID_HANDLE_VALUE == (HANDLE)(-1); 'Last is the all-ones value
      --  at the host word size.
      Invalid : constant System.Address := To_Address (Integer_Address'Last);
      Handle  : System.Address;
   begin
      Handle := W_CreateFile (To_Address (C_Path),
                              Win_GENERIC_WRITE,
                              Win_FILE_SHARE_READ + Win_FILE_SHARE_WRITE,
                              Security_Attrs'Address,
                              Win_CREATE_ALWAYS,
                              Win_FILE_ATTRIBUTE_NORMAL,
                              System.Null_Address);
      Free (C_Path);
      if Handle = Invalid then
         raise Build_Error with "CreateFile failed for: " & Path;
      end if;
      return Handle;
   end Win32_Open_For_Redirect;

   --  CreateProcessA counterpart of Posix_Spawn; same return contract.
   function Win32_Spawn (Prog_Path     : String;
                         Args          : Argument_List;
                         Stdout_File   : String_Access;
                         Stderr_File   : String_Access;
                         Wait_For_Exit : Boolean) return System.Address
   is
      use Interfaces.C.Strings;
      use type Interfaces.C.int;
      use type Interfaces.C.unsigned;
      Cmd_Line     : constant String := Build_Command_Line (Prog_Path, Args);
      C_Prog       : chars_ptr := New_String (Prog_Path);
      C_Cmd        : chars_ptr := New_String (Cmd_Line);
      Startup_Info : aliased Win_Startup_Info;
      Process_Info : aliased Win_Process_Info;
      Result       : Win_BOOL;
      Exit_Code    : aliased Win_DWORD := 0;
      Owned_Out    : Boolean := False;
      Owned_Err    : Boolean := False;
   begin
      Startup_Info.Cb          := Win_DWORD (Win_Startup_Info'Object_Size / System.Storage_Unit);
      Startup_Info.Flags       := Win_STARTF_USESTDHANDLES;
      Startup_Info.H_Std_Input := W_GetStdHandle (Win_STD_INPUT_HANDLE);

      if Stdout_File /= null then
         Startup_Info.H_Std_Output := Win32_Open_For_Redirect (Stdout_File.all);
         Owned_Out := True;
      else
         Startup_Info.H_Std_Output := W_GetStdHandle (Win_STD_OUTPUT_HANDLE);
      end if;

      if Stderr_File /= null then
         Startup_Info.H_Std_Error := Win32_Open_For_Redirect (Stderr_File.all);
         Owned_Err := True;
      else
         Startup_Info.H_Std_Error := W_GetStdHandle (Win_STD_ERROR_HANDLE);
      end if;

      Result := W_CreateProcess (App_Name        => To_Address (C_Prog),
                                 Cmd_Line        => To_Address (C_Cmd),
                                 Proc_Attrs      => System.Null_Address,
                                 Thread_Attrs    => System.Null_Address,
                                 Inherit_Handles => Win_TRUE,
                                 Creation_Flags  => 0,
                                 Environment     => System.Null_Address,
                                 Current_Dir     => System.Null_Address,
                                 Startup_Info    => Startup_Info'Address,
                                 Process_Info    => Process_Info'Address);

      --  Child has its own copies of the redirection handles after CreateProcess.
      if Owned_Out then
         Ignore (W_CloseHandle (Startup_Info.H_Std_Output));
      end if;
      if Owned_Err then
         Ignore (W_CloseHandle (Startup_Info.H_Std_Error));
      end if;

      Free (C_Prog);
      Free (C_Cmd);

      if Win_Is_Error (Result) then
         Log ("ERRO", "CreateProcess failed for: " & Prog_Path);
         raise Build_Error with "CreateProcess failed for: " & Prog_Path;
      end if;

      --  We don't need the main thread handle.
      Ignore (W_CloseHandle (Process_Info.H_Thread));

      if not Wait_For_Exit then
         return Process_Info.H_Process;
      end if;

      Ignore (W_WaitForSingleObject (Process_Info.H_Process, Win_INFINITE));
      Ignore (W_GetExitCodeProcess (Process_Info.H_Process, Exit_Code'Access));
      Ignore (W_CloseHandle (Process_Info.H_Process));

      Check_Exit (Integer (Exit_Code));
      return System.Null_Address;
   end Win32_Spawn;

   --  Wait for a previously-spawned Win32 process handle and return its
   --  exit code.  Closes the handle.
   function Win32_Wait (Pid_Addr : System.Address) return Integer is
      Exit_Code : aliased Win_DWORD := 0;
   begin
      Ignore (W_WaitForSingleObject (Pid_Addr, Win_INFINITE));
      Ignore (W_GetExitCodeProcess (Pid_Addr, Exit_Code'Access));
      Ignore (W_CloseHandle (Pid_Addr));
      return Integer (Exit_Code);
   end Win32_Wait;

   --------------------------------------------------------------------------
   --  Command execution (public API)
   --------------------------------------------------------------------------

   --  Platform-dispatching spawn used by Cmd, Cmd_Async, and Go_Rebuild_Urself(TM).
   function Spawn (Prog_Path     : String;
                   Args          : Argument_List;
                   Redir         : Redirect;
                   Wait_For_Exit : Boolean) return System.Address is
   begin
      case Platform is
         when Linux | MacOS =>
            return Posix_Spawn
              (Prog_Path, Args, Redir.Stdout, Redir.Stderr, Wait_For_Exit);
         when Windows =>
            return Win32_Spawn
              (Prog_Path, Args, Redir.Stdout, Redir.Stderr, Wait_For_Exit);
      end case;
   end Spawn;

   procedure Cmd (Program : String;
                  Args    : Argument_List := No_Args;
                  Redir   : Redirect      := No_Redirect)
   is
      Display   : constant String := Display_Of (Program, Args);
      Prog_Path : constant String := Resolve_Program (Program, Display);
   begin
      Ignore (Spawn (Prog_Path, Args, Redir, Wait_For_Exit => True));
   end Cmd;

   function Capture (Program : String; Args : Argument_List := No_Args) return String is
      Tmp_Path : constant String := ".no_build_capture";
      Redir    : constant Redirect := (Stdout => new String'(Tmp_Path), Stderr => null);

      function Trim (S : String) return String is
         function Is_WS (C : Character) return Boolean is (C = ' ' or else C = ASCII.HT
                                                                   or else C = ASCII.LF
                                                                   or else C = ASCII.CR);
         First : Natural := S'First;
         Last  : Natural := S'Last;
      begin
         while First <= Last and then Is_WS (S (First)) loop
            First := First + 1;
         end loop;
         while Last >= First and then Is_WS (S (Last)) loop
            Last := Last - 1;
         end loop;
         return S (First .. Last);
      end Trim;
   begin
      Cmd (Program, Args, Redir);
      declare
         Content : constant String := Read_File (Tmp_Path);
      begin
         Remove_Path (Tmp_Path);
         return Trim (Content);
      end;
   exception
      when others =>
         if Path_Exists (Tmp_Path) then
            Remove_Path (Tmp_Path);
         end if;
         raise;
   end Capture;

   function Cmd_Async
     (Program : String;
      Args    : Argument_List := No_Args;
      Redir   : Redirect      := No_Redirect) return Proc
   is
      Display   : constant String := Display_Of (Program, Args);
      Prog_Path : constant String := Resolve_Program (Program, Display);
   begin
      return (Pid => Spawn (Prog_Path, Args, Redir, Wait_For_Exit => False));
   end Cmd_Async;

   function Wait_For (Pid : System.Address) return Integer is
   begin
      case Platform is
         when Linux | MacOS => return Posix_Wait (Pid);
         when Windows       => return Win32_Wait (Pid);
      end case;
   end Wait_For;

   procedure Wait (P : Proc) is
      Code : constant Integer := Wait_For (P.Pid);
   begin
      if Code /= 0 then
         raise Build_Error with "process exited with non-zero status";
      end if;
   end Wait;

   procedure Append (List : in out Proc_List; P : Proc) is begin
      if List.Count >= Max_Procs then
         raise Build_Error with "Proc_List is full (max" & Max_Procs'Image & ")";
      end if;
      List.Count := List.Count + 1;
      List.Items (List.Count) := P;
   end Append;

   procedure Wait_All (List : in out Proc_List) is
      Any_Failed : Boolean := False;
   begin
      for I in 1 .. List.Count loop
         if List.Items (I).Pid /= System.Null_Address then
            declare
               Code : constant Integer := Wait_For (List.Items (I).Pid);
            begin
               if Code /= 0 then
                  Any_Failed := True;
               end if;
            end;
         end if;
      end loop;
      List := (Items => (others => Invalid_Proc), Count => 0);
      if Any_Failed then
         raise Build_Error with "one or more parallel commands failed";
      end if;
   end Wait_All;

   function N_Procs return Positive is
      use System.Multiprocessors;
   begin
      return Positive (Number_Of_CPUs);
   end N_Procs;

   --------------------------------------------------------------------------
   --  Compiler abstraction
   --------------------------------------------------------------------------

   Active_Compiler : Ada_Compiler := Gnatmake_Compiler;

   procedure Set_Compiler (C : Ada_Compiler) is begin
      Active_Compiler := C;
   end Set_Compiler;

   procedure Compile_Program (Source  : String;
                              Output  : String        := "";
                              Obj_Dir : String        := "";
                              Extra   : Argument_List := No_Args)
   is
      C    : Ada_Compiler renames Active_Compiler;
      Args : Argument_List_Access := new Argument_List'(1 => S (Source));

      procedure Append_Pair (Flag, Value : String_Access) is
         New_Args : constant Argument_List_Access := new Argument_List'(Args.all & Flag & Value);
      begin
         Args := New_Args;
      end Append_Pair;
   begin
      if Obj_Dir /= "" then
         Make_Dirs (Obj_Dir);
         Append_Pair (C.Obj_Flag, S (Obj_Dir));
      end if;
      if Output /= "" then
         Append_Pair (C.Out_Flag, S (Output));
      end if;

      Cmd (C.Executable.all, Args.all & C.Compile_Flags.all & Extra);
   end Compile_Program;

   procedure Compile (Source  : String;
                      Obj_Dir : String        := "";
                      Extra   : Argument_List := No_Args)
   is begin
      Compile_Program (Source, Obj_Dir => Obj_Dir,
         Extra => Argument_List'(1 => Active_Compiler.Compile_Only_Flag) & Extra);
   end Compile;

   --  Compile each .adb in Src_Dir; return the resulting .o paths.
   function Build_Lib_Objects (Src_Dir : String;
                               Obj_Dir : String;
                               PIC     : Boolean;
                               Extra   : Argument_List) return Argument_List
   is
      use Ada.Directories;
      Eff_Obj : constant String := (if Obj_Dir /= "" then Obj_Dir else ".");
      Flags   : constant Argument_List := (if PIC then Active_Compiler.PIC_Flags.all & Extra else Extra);
      Search  : Search_Type;
      Dir_Ent : Directory_Entry_Type;
      Acc     : Argument_List_Access := new Argument_List'(No_Args);
   begin
      if Obj_Dir /= "" then
         Make_Dirs (Obj_Dir);
      end if;
      Start_Search (Search, Src_Dir, "*",
                    Filter => (Ordinary_File => True, others => False));
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Dir_Ent);
         declare
            Name : constant String := Simple_Name (Dir_Ent);
         begin
            if Ends_With (Name, ".adb") then
               Compile (Src_Dir / Name, Obj_Dir => Obj_Dir, Extra => Flags);
               Acc := new Argument_List'
                        (Acc.all & S (Eff_Obj / No_Ext (Name) & ".o"));
            end if;
         end;
      end loop;
      End_Search (Search);
      return Acc.all;
   end Build_Lib_Objects;

   procedure Build_Static_Lib (Src_Dir : String;
                               Output  : String;
                               Obj_Dir : String        := "";
                               Extra   : Argument_List := No_Args)
   is
      C       : Ada_Compiler renames Active_Compiler;
      Objects : constant Argument_List := Build_Lib_Objects (Src_Dir, Obj_Dir, PIC => False, Extra => Extra);
   begin
      if Objects'Length > 0 then
         Cmd (C.Static_Archiver.all,
              C.Static_Archiver_Flags.all
              & Argument_List'(1 => S (Output))
              & Objects);
      end if;
   end Build_Static_Lib;

   procedure Build_Shared_Lib (Src_Dir : String;
                               Output  : String;
                               Obj_Dir : String        := "";
                               Extra   : Argument_List := No_Args)
   is
      C       : Ada_Compiler renames Active_Compiler;
      Objects : constant Argument_List := Build_Lib_Objects (Src_Dir, Obj_Dir, PIC => True, Extra => Extra);

      --  Shared_Runtime_Probe's return value as a single positional arg.
      function Probe_Args return Argument_List is begin
         if C.Shared_Runtime_Probe = null then
            return No_Args;
         end if;
         return (1 => S (C.Shared_Runtime_Probe.all));
      end Probe_Args;
   begin
      if Objects'Length > 0 then
         Cmd (C.Shared_Linker.all,
              C.Shared_Flags.all
              & Argument_List'(C.Shared_Out_Flag, S (Output))
              & Objects
              & Probe_Args);
      end if;
   end Build_Shared_Lib;

   function Find_Gnat_Runtime return String is
      Libgcc : constant String := Capture ("gcc", Argument_List'(1 => S ("-print-libgcc-file-name")));
      Slash  : Natural := 0;
   begin
      for I in reverse Libgcc'Range loop
         if Libgcc (I) = '/' or else Libgcc (I) = '\' then
            Slash := I;
            exit;
         end if;
      end loop;
      if Slash = 0 then
         return Libgcc;
      end if;
      declare
         Adalib : constant String := Libgcc (Libgcc'First .. Slash) & "adalib/";
         Pic    : constant String := Adalib & "libgnat_pic.a";
      begin
         --  Linux GNAT ships a PIC variant; Windows MinGW and macOS link
         --  the plain libgnat.a into a shared object fine.
         if Path_Exists (Pic) then
            return Pic;
         end if;
         return Adalib & "libgnat.a";
      end;
   end Find_Gnat_Runtime;

   --------------------------------------------------------------------------
   --  Path utilities
   --------------------------------------------------------------------------

   function "/" (Left, Right : String) return String is
      --  Native separator (Windows tools tolerate '/', but mixing styles in
      --  a single path can trip some Win32 lookups).
      Sep : constant Character := (if Platform = Windows then '\' else '/');
   begin
      if Left = "" then
         return Right;
      elsif Left (Left'Last) = '/' or else Left (Left'Last) = '\' then
         return Left & Right;
      else
         return Left & Sep & Right;
      end if;
   end "/";

   function No_Ext (Path : String) return String is begin
      for I in reverse Path'Range loop
         if Path (I) = '.' then
            return Path (Path'First .. I - 1);
         elsif Path (I) = '/' or else Path (I) = '\' then
            exit;
         end if;
      end loop;
      return Path;
   end No_Ext;

   function Ends_With (Str, Suffix : String) return Boolean is begin
      if Suffix'Length > Str'Length then
         return False;
      end if;
      return Str (Str'Last - Suffix'Length + 1 .. Str'Last) = Suffix;
   end Ends_With;

   function Base_Name (Path : String) return String is begin
      for I in reverse Path'Range loop
         if Path (I) = '/' or else Path (I) = '\' then
            return Path (I + 1 .. Path'Last);
         end if;
      end loop;
      return Path;
   end Base_Name;

   --------------------------------------------------------------------------
   --  Filesystem predicates
   --------------------------------------------------------------------------

   function Path_Exists (Path : String) return Boolean is begin
      return Ada.Directories.Exists (Path);
   end Path_Exists;

   function Is_Dir (Path : String) return Boolean is
      use Ada.Directories;
   begin
      return Exists (Path) and then Kind (Path) = Directory;
   end Is_Dir;

   --------------------------------------------------------------------------
   --  Filesystem mutations
   --------------------------------------------------------------------------

   procedure Make_Dir (Path : String) is begin
      if Ada.Directories.Exists (Path) then
         Log ("WARN", "directory already exists: " & Path);
      else
         Log ("MKDIR", Path);
         Ada.Directories.Create_Directory (Path);
      end if;
   end Make_Dir;

   procedure Make_Dirs (Path : String) is begin
      Log ("MKDIRS", Path);
      for I in Path'Range loop
         if (Path (I) = '/' or else Path (I) = '\')
           and then I > Path'First
         then
            declare
               Part : constant String := Path (Path'First .. I - 1);
            begin
               if Part /= "" and then not Ada.Directories.Exists (Part) then
                  Ada.Directories.Create_Directory (Part);
               end if;
            end;
         end if;
      end loop;
      if not Ada.Directories.Exists (Path) then
         Ada.Directories.Create_Directory (Path);
      end if;
   end Make_Dirs;

   procedure Rename_Path (Old_Path, New_Path : String) is
      use Interfaces.C.Strings;
      use type Interfaces.C.unsigned;

      --  Native rename can move a running .exe (Windows blocks delete, not
      --  rename) — needed by Go_Rebuild_Urself(TM).  Copy+delete fallback below
      --  handles cross-filesystem renames (POSIX EXDEV).
      function Native_Rename return Boolean is
         Old_C : chars_ptr := New_String (Old_Path);
         New_C : chars_ptr := New_String (New_Path);
         Ok    : Boolean   := False;
      begin
         case Platform is
            when Linux | MacOS =>
               Ok := Is_Ok (C_Rename (To_Address (Old_C),
                                      To_Address (New_C)));
            when Windows =>
               Ok := Win_Is_Ok (W_MoveFileEx (To_Address (Old_C),
                                              To_Address (New_C),
                                              Win_MOVEFILE_REPLACE_EXISTING or Win_MOVEFILE_COPY_ALLOWED));
         end case;
         Free (Old_C);
         Free (New_C);
         return Ok;
      end Native_Rename;
   begin
      Log ("RENAME", Old_Path & " -> " & New_Path);
      if Native_Rename then
         return;
      end if;

      --  Fallback: copy + delete.  Form => preserve=all_attributes is a
      --  GNAT extension that keeps the executable bit; harmless elsewhere.
      if Is_Dir (Old_Path) then
         Copy_Dir (Old_Path, New_Path);
         Ada.Directories.Delete_Tree (Old_Path);
      else
         Ada.Directories.Copy_File
           (Old_Path, New_Path, Form => "preserve=all_attributes");
         Ada.Directories.Delete_File (Old_Path);
      end if;
   exception
      when Build_Error => raise;
      when others =>
         Log ("ERRO", "could not rename " & Old_Path & " to " & New_Path);
         raise Build_Error with "rename failed: " & Old_Path;
   end Rename_Path;

   procedure Remove_Path (Path : String) is begin
      Log ("RM", Path);
      if Is_Dir (Path) then
         Ada.Directories.Delete_Tree (Path);
      elsif Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      else
         Log ("WARN", "path does not exist: " & Path);
      end if;
   end Remove_Path;

   --------------------------------------------------------------------------
   --  Dependency checking
   --------------------------------------------------------------------------

   function Is_Newer (Path1, Path2 : String) return Boolean is
      use Ada.Directories;
      use Ada.Calendar;
   begin
      if not Exists (Path1) then
         return False;
      end if;
      if not Exists (Path2) then
         return True;
      end if;
      return Modification_Time (Path1) > Modification_Time (Path2);
   end Is_Newer;

   function Needs_Rebuild (Output : String; Inputs : Argument_List)
     return Boolean is
   begin
      for I of Inputs loop
         if Is_Newer (I.all, Output) then
            return True;
         end if;
      end loop;
      return False;
   end Needs_Rebuild;

   --------------------------------------------------------------------------
   --  Directory iteration
   --------------------------------------------------------------------------

   procedure For_Each_File (Dir     : String;
                            Process : not null access procedure (File_Name : String);
                            Suffix  : String := "")
   is
      use Ada.Directories;
      Search  : Search_Type;
      Dir_Ent : Directory_Entry_Type;
   begin
      Start_Search (Search, Dir, "*", Filter => (others => True));
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Dir_Ent);
         declare
            Name : constant String := Simple_Name (Dir_Ent);
         begin
            if Name /= "." and then Name /= ".." then
               if Suffix = "" or else Ends_With (Name, Suffix) then
                  Process (Name);
               end if;
            end if;
         end;
      end loop;
      End_Search (Search);
   end For_Each_File;

   function Walk_Dir_Rec (Dir   : String;
                          Func  : Walk_Func;
                          Depth : Natural) return Boolean
   is
      use Ada.Directories;
      Search  : Search_Type;
      Dir_Ent : Directory_Entry_Type;
   begin
      Start_Search (Search, Dir, "*", Filter => (others => True));
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Dir_Ent);
         declare
            Name : constant String := Simple_Name (Dir_Ent);
         begin
            if Name /= "." and then Name /= ".." then
               declare
                  Full     : constant String := Dir / Name;
                  Kind     : File_Kind;
                  Ada_Kind : constant Ada.Directories.File_Kind :=
                    Ada.Directories.Kind (Dir_Ent);
               begin
                  case Ada_Kind is
                     when Ada.Directories.Ordinary_File => Kind := Regular_File;
                     when Ada.Directories.Directory     => Kind := Directory;
                     when Ada.Directories.Special_File  => Kind := Other;
                  end case;

                  declare
                     Action : constant Walk_Action :=
                       Func ((Path  => new String'(Full),
                              Name  => new String'(Name),
                              Kind  => Kind,
                              Depth => Depth));
                  begin
                     case Action is
                        when Walk_Stop =>
                           End_Search (Search);
                           return False;
                        when Walk_Skip => null;
                        when Walk_Continue =>
                           if Kind = Directory then
                              if not Walk_Dir_Rec (Full, Func, Depth + 1) then
                                 End_Search (Search);
                                 return False;
                              end if;
                           end if;
                     end case;
                  end;
               end;
            end if;
         end;
      end loop;
      End_Search (Search);
      return True;
   end Walk_Dir_Rec;

   procedure Walk_Dir (Root : String; Func : Walk_Func) is begin
      Ignore (Walk_Dir_Rec (Root, Func, 0));
   end Walk_Dir;

   --------------------------------------------------------------------------
   --  Copy_File / Copy_Dir
   --------------------------------------------------------------------------

   procedure Copy_File (Src, Dst : String) is begin
      Log ("CP", Src & " -> " & Dst);
      Ada.Directories.Copy_File (Source_Name => Src,
                                 Target_Name => Dst,
                                 Form        => "preserve=all_attributes");
   end Copy_File;

   procedure Copy_Dir (Src, Dst : String) is
      procedure Recurse (From, To : String) is
         use Ada.Directories;
         Search  : Search_Type;
         Dir_Ent : Directory_Entry_Type;
      begin
         Make_Dirs (To);
         Start_Search (Search, From, "*", Filter => (others => True));
         while More_Entries (Search) loop
            Get_Next_Entry (Search, Dir_Ent);
            declare
               Name : constant String := Simple_Name (Dir_Ent);
            begin
               if Name /= "." and then Name /= ".." then
                  declare
                     Src_Path : constant String := From / Name;
                     Dst_Path : constant String := To   / Name;
                  begin
                     case Ada.Directories.Kind (Dir_Ent) is
                        when Ada.Directories.Directory     => Recurse (Src_Path, Dst_Path);
                        when Ada.Directories.Ordinary_File => No_Build.Copy_File (Src_Path, Dst_Path);
                        when Ada.Directories.Special_File  => null;
                     end case;
                  end;
               end if;
            end;
         end loop;
         End_Search (Search);
      end Recurse;
   begin
      Recurse (Src, Dst);
   end Copy_Dir;

   --------------------------------------------------------------------------
   --  File I/O
   --------------------------------------------------------------------------

   function Read_File (Path : String) return String is
      package SIO renames Ada.Streams.Stream_IO;
      File   : SIO.File_Type;
      Size   : constant Natural := Natural (Ada.Directories.Size (Path));
      Result : String (1 .. Size);
   begin
      if Size = 0 then
         return "";
      end if;
      SIO.Open (File, SIO.In_File, Path);
      String'Read (SIO.Stream (File), Result);
      SIO.Close (File);
      return Result;
   exception
      when Build_Error => raise;
      when others =>
         if SIO.Is_Open (File) then SIO.Close (File); end if;
         raise Build_Error with "cannot read file: " & Path;
   end Read_File;

   procedure Write_File (Path : String; Contents : String) is
      package SIO renames Ada.Streams.Stream_IO;
      File : SIO.File_Type;
   begin
      SIO.Create (File, SIO.Out_File, Path);
      String'Write (SIO.Stream (File), Contents);
      SIO.Close (File);
   exception
      when Build_Error => raise;
      when others =>
         if SIO.Is_Open (File) then SIO.Close (File); end if;
         raise Build_Error with "cannot write file: " & Path;
   end Write_File;

   function Get_Current_Dir return String is begin
      return Ada.Directories.Current_Directory;
   end Get_Current_Dir;

   procedure Set_Current_Dir (Path : String) is begin
      Log ("CD", Path);
      Ada.Directories.Set_Directory (Path);
   exception
      when others =>
         raise Build_Error with "cannot change directory to: " & Path;
   end Set_Current_Dir;

   --------------------------------------------------------------------------
   --  Logging
   --------------------------------------------------------------------------

   procedure Info  (Msg : String) is begin Log ("INFO", Msg); end Info;
   procedure Warn  (Msg : String) is begin Log ("WARN", Msg); end Warn;
   procedure Erro  (Msg : String) is begin Log ("ERRO", Msg); end Erro;
   procedure Panic (Msg : String) is begin Log ("ERRO", Msg); raise Build_Error with Msg; end Panic;

   --------------------------------------------------------------------------
   --  Go Rebuild Urself(TM)
   --------------------------------------------------------------------------

   procedure Go_Rebuild_Urself (Binary_Path : String;
                                Source_Path : String;
                                Obj_Dir     : String        := "";
                                Extra       : Argument_List := No_Args)
   is
      --  On Windows gnatmake adds .exe; Compile_Program still gets the raw
      --  Binary_Path, but the timestamp / backup / re-exec need the suffix.
      Bin : constant String :=
        (if Platform = Windows and then not Ends_With (Binary_Path, ".exe")
         then Binary_Path & ".exe"
         else Binary_Path);
      Old_Binary : constant String := Bin & ".old";
   begin
      if not Path_Exists (Source_Path) then
         return;
      end if;

      --  Sweep up any .old from a previous run: on Windows the running exe
      --  owns its file until exec, so the previous rebuild couldn't delete it.
      if Path_Exists (Old_Binary) then
         begin
            Remove_Path (Old_Binary);
         exception
            when others => null;
         end;
      end if;

      if Is_Newer (Source_Path, Bin) then
         Info ("build script changed, rebuilding: " & Source_Path);

         if Path_Exists (Bin) then
            Rename_Path (Bin, Old_Binary);
         end if;

         begin
            Compile_Program (Source_Path, Output => Binary_Path,
                             Obj_Dir => Obj_Dir, Extra => Extra);
         exception
            when others =>
               if Path_Exists (Old_Binary) then
                  Rename_Path (Old_Binary, Bin);
               end if;
               raise;
         end;

         --  Best-effort: Windows blocks delete of the running exe; the
         --  next-run sweep above catches it.
         if Path_Exists (Old_Binary) then
            begin
               Remove_Path (Old_Binary);
            exception
               when others => null;
            end;
         end if;

         declare
            Args : Argument_List_Access := new Argument_List'(No_Args);
         begin
            for I in 1 .. Ada.Command_Line.Argument_Count loop
               Args := new Argument_List' (Args.all & S (Ada.Command_Line.Argument (I)));
            end loop;
            Info ("re-executing: " & Bin);
            Ignore (Spawn (Bin, Args.all, No_Redirect, Wait_For_Exit => True));
            --  Exit this (old) process; the re-execed build ran.
            case Platform is
               when Linux | MacOS => C_Exit (0);
               when Windows       => W_ExitProcess (0);
            end case;
         end;
      end if;
   end Go_Rebuild_Urself;

begin
   --  Elaboration runs after Platform is set in the spec.
   case Platform is
      when Linux | MacOS => Load_Posix_Symbols;
      when Windows       => Load_Win32_Symbols;
   end case;
end No_Build;
