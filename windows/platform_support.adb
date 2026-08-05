--  windows/platform_support.adb -- Win32.
--
--  Windows has no fork, no execvp and no opendir, so this body is not a
--  translation of the POSIX one: processes come from CreateProcessA, and
--  directories from the FindFirstFileA / FindNextFileA pair, which hands
--  back the first entry when the search opens.  That entry is held in the
--  search block below and returned by the next Read_Dir.
--
--  The Win32 structures are addressed as arrays of 64-bit words rather
--  than declared as records, so no representation clause has to agree
--  with the C compiler that built the DLLs.  Offsets are for x86-64,
--  where a word holds either one pointer or two DWORDs; a comment gives
--  the byte offset of every field read or written.
--

with System;
with Unchecked_Conversion;

package body Platform_Support is

   type Byte_Array is array (1 .. 1024) of Character;
   type Byte_Array_Ptr is access Byte_Array;

   type Word_Array is array (1 .. 100) of Long;
   type Word_Array_Ptr is access Word_Array;

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
   pragma Import (Stdcall, W_CreateProcessA, "CreateProcessA");

   function W_WaitForSingleObject (Object : Win_Handle; Millis : Integer)
     return Integer;
   pragma Import (Stdcall, W_WaitForSingleObject, "WaitForSingleObject");

   function W_GetExitCodeProcess (Process : Win_Handle; Code : System.Address)
     return Integer;
   pragma Import (Stdcall, W_GetExitCodeProcess, "GetExitCodeProcess");

   function W_CloseHandle (Object : Win_Handle) return Integer;
   pragma Import (Stdcall, W_CloseHandle, "CloseHandle");

   function W_CreateFileA
     (Name        : System.Address;
      Access_Mask : Integer;
      Share       : Integer;
      Security    : System.Address;
      Disposition : Integer;
      Flags       : Integer;
      Template    : Win_Handle) return Win_Handle;
   pragma Import (Stdcall, W_CreateFileA, "CreateFileA");

   function W_GetStdHandle (Which : Integer) return Win_Handle;
   pragma Import (Stdcall, W_GetStdHandle, "GetStdHandle");

   function W_WriteFile
     (File     : Win_Handle;
      Buffer   : System.Address;
      To_Write : Integer;
      Written  : System.Address;
      Overlap  : System.Address) return Integer;
   pragma Import (Stdcall, W_WriteFile, "WriteFile");

   procedure W_ExitProcess (Status : Integer);
   pragma Import (Stdcall, W_ExitProcess, "ExitProcess");

   function W_GetCurrentProcessId return Integer;
   pragma Import (Stdcall, W_GetCurrentProcessId, "GetCurrentProcessId");

   procedure W_GetSystemInfo (Info : System.Address);
   pragma Import (Stdcall, W_GetSystemInfo, "GetSystemInfo");

   function W_GetFileAttributesA (Name : System.Address) return Integer;
   pragma Import (Stdcall, W_GetFileAttributesA, "GetFileAttributesA");

   function W_GetFileAttributesExA
     (Name : System.Address; Level : Integer; Data : System.Address)
     return Integer;
   pragma Import (Stdcall, W_GetFileAttributesExA, "GetFileAttributesExA");

   function W_CreateDirectoryA
     (Path : System.Address; Security : System.Address) return Integer;
   pragma Import (Stdcall, W_CreateDirectoryA, "CreateDirectoryA");

   function W_RemoveDirectoryA (Path : System.Address) return Integer;
   pragma Import (Stdcall, W_RemoveDirectoryA, "RemoveDirectoryA");

   function W_DeleteFileA (Path : System.Address) return Integer;
   pragma Import (Stdcall, W_DeleteFileA, "DeleteFileA");

   function W_MoveFileExA
     (Old_Path, New_Path : System.Address; Flags : Integer) return Integer;
   pragma Import (Stdcall, W_MoveFileExA, "MoveFileExA");

   function W_SetCurrentDirectoryA (Path : System.Address) return Integer;
   pragma Import (Stdcall, W_SetCurrentDirectoryA, "SetCurrentDirectoryA");

   function W_GetCurrentDirectoryA (Size : Integer; Buffer : System.Address)
     return Integer;
   pragma Import (Stdcall, W_GetCurrentDirectoryA, "GetCurrentDirectoryA");

   function W_FindFirstFileA (Pattern : System.Address; Data : System.Address)
     return Win_Handle;
   pragma Import (Stdcall, W_FindFirstFileA, "FindFirstFileA");

   function W_FindNextFileA (Search : Win_Handle; Data : System.Address)
     return Integer;
   pragma Import (Stdcall, W_FindNextFileA, "FindNextFileA");

   function W_FindClose (Search : Win_Handle) return Integer;
   pragma Import (Stdcall, W_FindClose, "FindClose");

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

   function To_Bytes is
     new Unchecked_Conversion (System.Address, Byte_Array_Ptr);
   function To_Words is
     new Unchecked_Conversion (System.Address, Word_Array_Ptr);
   function To_Long is new Unchecked_Conversion (System.Address, Long);
   function To_Address is new Unchecked_Conversion (Long, System.Address);

   procedure Ignore (X : Integer) is
      pragma Unreferenced (X);
   begin
      null;
   end Ignore;

   function Is_Null (A : System.Address) return Boolean is
   begin
      return To_Long (A) = 0;
   end Is_Null;

   function Low_Half  (Word : Long) return Long is
   begin
      return Word mod Four_GB;
   end Low_Half;

   function High_Half (Word : Long) return Long is
   begin
      return Word / Four_GB;
   end High_Half;

   --------------------------------------------------------------------------
   --  Host
   --------------------------------------------------------------------------

   function Host return Host_Kind is
   begin
      return Windows;
   end Host;

   function Body_Dir return String is
   begin
      return "windows";
   end Body_Dir;

   function Path_Separator return Character is
   begin
      return '\';
   end Path_Separator;

   function Shell_Program return String is
   begin
      return "cmd.exe";
   end Shell_Program;

   function Shell_Flag return String is
   begin
      return "/c";
   end Shell_Flag;

   --------------------------------------------------------------------------
   --  Diagnostics
   --------------------------------------------------------------------------

   procedure Write_Error (Line : String) is
      Buffer  : constant String := Line & ASCII.CR & ASCII.LF;
      Written : Integer := 0;
   begin
      Ignore (W_WriteFile (W_GetStdHandle (Std_Error_Handle),
                           Buffer'Address, Buffer'Length,
                           Written'Address, System.Null_Address));
   end Write_Error;

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
      Bytes : constant Byte_Array_Ptr := To_Bytes (A);
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
      Security : Word_Array;
   begin
      Security (1) := 24;
      Security (2) := 0;
      Security (3) := 1;
      return W_CreateFileA (C_Path'Address, Generic_Write, File_Share_Read,
                            Security'Address, Create_Always,
                            File_Attribute_Normal, 0);
   end Redirect_Handle;

   function Spawn
     (Argv     : Argv_Array;
      Out_Path : String;
      Err_Path : String) return Integer is

      --  STARTUPINFOA, 104 bytes: cb at 0, dwFlags at 60, hStdInput at 80,
      --  hStdOutput at 88, hStdError at 96.  As words: cb is the low half
      --  of word 1, dwFlags the high half of word 8, and the handles are
      --  words 11, 12 and 13.
      Startup      : Word_Array;
      Process_Info : Word_Array;
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
               Ignore (W_CloseHandle (Out_Handle));
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
      if Is_Null (Block) then
         return Spawn_Failed;
      end if;
      declare
         Bytes : constant Byte_Array_Ptr := To_Bytes (Block);
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
         Ignore (W_CloseHandle (Out_Handle));
      end if;
      if Err_Path /= "" then
         Ignore (W_CloseHandle (Err_Handle));
      end if;
      if Ok = 0 then
         return Spawn_Failed;
      end if;

      --  PROCESS_INFORMATION: hProcess at 0, hThread at 8, the ids after.
      Ignore (W_CloseHandle (Process_Info (2)));
      return Integer (Process_Info (1) mod 2147483647);
   end Spawn;

   function Wait_For (Handle : Integer) return Integer is
      Process : constant Win_Handle := Long (Handle);
      Code    : Integer := 0;
      Status  : Integer;
   begin
      if Handle <= 0 then
         return Wait_Failed;
      end if;
      Ignore (W_WaitForSingleObject (Process, Infinite));
      Status := W_GetExitCodeProcess (Process, Code'Address);
      Ignore (W_CloseHandle (Process));
      if Status = 0 then
         return Wait_Failed;
      end if;
      return Code;
   end Wait_For;

   procedure Exit_Process (Status : Integer) is
   begin
      W_ExitProcess (Status);
   end Exit_Process;

   function Process_Id return Integer is
   begin
      return W_GetCurrentProcessId;
   end Process_Id;

   function Cpu_Count return Positive is
      --  SYSTEM_INFO, 48 bytes: dwNumberOfProcessors at byte 32, the low
      --  half of word 5.
      Info : Word_Array;
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
   end Cpu_Count;

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

   procedure File_Status
     (Path         : String;
      Found        : out Boolean;
      Is_Directory : out Boolean;
      Mtime_Sec    : out Long;
      Mtime_Nsec   : out Long) is
      C_Path : constant String := Path & ASCII.NUL;
      --  WIN32_FILE_ATTRIBUTE_DATA, 36 bytes: dwFileAttributes at 0, then
      --  three FILETIMEs at 4, 12 and 20, then the two size halves.
      --  ftLastWriteTime therefore straddles words 3 and 4.
      Data  : Word_Array;
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
   end File_Status;

   function Exists (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_GetFileAttributesA (C_Path'Address) /= Invalid_File_Attrs;
   end Exists;

   function Make_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_CreateDirectoryA (C_Path'Address, System.Null_Address) /= 0;
   end Make_Directory;

   function Remove_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_RemoveDirectoryA (C_Path'Address) /= 0;
   end Remove_Directory;

   function Remove_File (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_DeleteFileA (C_Path'Address) /= 0;
   end Remove_File;

   function Change_Directory (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return W_SetCurrentDirectoryA (C_Path'Address) /= 0;
   end Change_Directory;

   function Rename_Path (Old_Path, New_Path : String) return Boolean is
      C_Old : constant String := Old_Path & ASCII.NUL;
      C_New : constant String := New_Path & ASCII.NUL;
   begin
      --  Windows refuses to delete a running executable but will rename
      --  one, which is what Go_Rebuild_Urself depends on.
      return W_MoveFileExA (C_Old'Address, C_New'Address,
                            Move_Replace_Existing + Move_Copy_Allowed) /= 0;
   end Rename_Path;

   function Working_Directory return String is
      Buffer : String (1 .. 4096);
      Length : constant Integer :=
        W_GetCurrentDirectoryA (Buffer'Length, Buffer'Address);
   begin
      if Length <= 0 or else Length > Buffer'Length then
         return "";
      end if;
      return Buffer (1 .. Length);
   end Working_Directory;

   --------------------------------------------------------------------------
   --  Directory listing
   --
   --  The search block holds the Win32 handle, a flag saying the buffered
   --  entry has yet to be handed out, and the WIN32_FIND_DATAA itself:
   --
   --     word 1    FindFirstFileA handle
   --     word 2    1 while the buffered entry is pending
   --     word 3..  WIN32_FIND_DATAA, 320 bytes, cFileName at its byte 44
   --------------------------------------------------------------------------

   Find_Data_Word   : constant := 3;
   Find_Data_Offset : constant Long := 8 * (Find_Data_Word - 1);
   Find_Name_Offset : constant Long := Find_Data_Offset + 44;

   function Open_Dir (Path : String) return System.Address is
      Pattern : constant String := Path & "\*" & ASCII.NUL;
      Block   : constant System.Address := C_Malloc (400);
      Search  : Win_Handle;
   begin
      if Is_Null (Block) then
         return Null_Dir;
      end if;
      Search := W_FindFirstFileA
        (Pattern'Address, To_Address (To_Long (Block) + Find_Data_Offset));
      if Search = Invalid_Win_Handle then
         C_Free (Block);
         return Null_Dir;
      end if;
      To_Words (Block) (1) := Search;
      To_Words (Block) (2) := 1;
      return Block;
   end Open_Dir;

   procedure Read_Dir
     (Handle       : System.Address;
      Name         : out String;
      Last         : out Natural;
      Is_Directory : out Boolean;
      Is_File      : out Boolean) is
      Words      : Word_Array_Ptr;
      Name_Bytes : Byte_Array_Ptr;
      Attributes : Long;
   begin
      Last         := 0;
      Is_Directory := False;
      Is_File      := False;
      if Is_Null (Handle) then
         return;
      end if;

      Words := To_Words (Handle);
      if Words (2) = 1 then
         Words (2) := 0;          --  hand out the entry FindFirstFileA read
      elsif W_FindNextFileA
              (Words (1),
               To_Address (To_Long (Handle) + Find_Data_Offset)) = 0
      then
         return;
      end if;

      Name_Bytes := To_Bytes (To_Address (To_Long (Handle) +
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
      Is_Directory := (Attributes / File_Attribute_Dir) mod 2 = 1;
      Is_File      := not Is_Directory;
   end Read_Dir;

   procedure Close_Dir (Handle : System.Address) is
   begin
      if Is_Null (Handle) then
         return;
      end if;
      Ignore (W_FindClose (To_Words (Handle) (1)));
      C_Free (Handle);
   end Close_Dir;

end Platform_Support;
