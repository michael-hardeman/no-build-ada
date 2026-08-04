--  no_build.adb -- Ada 83 port.
--
--  Every system call goes through Platform_Support, whose body is chosen
--  at bootstrap: posix/ for Linux and macOS, windows/ for Windows.  No
--  struct layout, syscall name or errno-style constant appears here.

with Command_Line;
with Platform_Support;
with System;
with Unchecked_Deallocation;

package body No_Build is

   package OS renames Platform_Support;

   --  No_Build's own 64-bit integer, so its operators are directly
   --  visible here; values crossing the OS boundary are converted.
   type Long is range -(2 ** 63) .. 2 ** 63 - 1;

   Active_Level : Log_Level := Verbose;

   Platform_Known : Boolean       := False;
   Platform_Value : Platform_Kind := Linux;

   Compiler : constant String := "ada83";

   --------------------------------------------------------------------------
   --  The C library's file streams.  These are the same everywhere the C
   --  standard reaches, so they are not part of Platform_Support.
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
   --  Internal helpers
   --------------------------------------------------------------------------

   procedure Free_String_Storage is
     new Unchecked_Deallocation (String, Str);
   procedure Free_Array_Storage is
     new Unchecked_Deallocation (Str_Array, Str_Array_Access);
   procedure Free_Proc_Storage is
     new Unchecked_Deallocation (Proc_Array, Proc_Array_Access);

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
      OS.Write_Error (Line);
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
   --  Platform
   --------------------------------------------------------------------------

   function Platform return Platform_Kind is
   begin
      if not Platform_Known then
         case OS.Host is
            when OS.Linux   => Platform_Value := Linux;
            when OS.MacOS   => Platform_Value := MacOS;
            when OS.Windows => Platform_Value := Windows;
         end case;
         Platform_Known := True;
      end if;
      return Platform_Value;
   end Platform;

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
      return OS.Path_Separator;
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
      Argv    : OS.Argv_Array (1 .. Argc + 1);
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

      Pid := OS.Spawn (Argv, Value (Redir.Stdout), Value (Redir.Stderr));

      for I in Holders'Range loop
         Free_String_Storage (Holders (I));
      end loop;

      if Pid = OS.Spawn_Failed then
         Panic ("cannot start " & Program);
      end if;
      return Pid;
   end Spawn;

   procedure Check_Exit_Code (Code : Integer; Label : String) is
   begin
      if Code = OS.Wait_Failed then
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
      Check_Exit_Code (OS.Wait_For (Pid), Program);
   end Cmd;

   procedure Sh (Command : String) is
   begin
      Cmd (OS.Shell_Program, Args (OS.Shell_Flag, Command));
   end Sh;

   function Capture
     (Program  : String;
      Args     : Argument_List := No_Args) return String is
      Pid_Image : constant String := Integer'Image (OS.Process_Id);
      Temp_Path : constant String :=
        "no_build_capture_" & Pid_Image (2 .. Pid_Image'Last) & ".txt";
   begin
      begin
         Cmd (Program, Args, To_File (Stdout => Temp_Path));
      exception
         when Build_Error =>
            Ignore (OS.Remove_File (Temp_Path));
            raise;
      end;
      declare
         Raw : constant String := Read_File (Temp_Path);
      begin
         Ignore (OS.Remove_File (Temp_Path));
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
      Check_Exit_Code (OS.Wait_For (P.Pid),
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
      return OS.Cpu_Count;
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
      return OS.Exists (Path);
   end Path_Exists;

   function Is_Dir (Path : String) return Boolean is
      Found     : Boolean;
      Directory : Boolean;
      Sec, Nsec : OS.Long;
   begin
      OS.File_Status (Path, Found, Directory, Sec, Nsec);
      return Found and then Directory;
   end Is_Dir;

   procedure Close_Dir (Handle : System.Address) is
   begin
      OS.Close_Dir (Handle);
   end Close_Dir;

   function Open_Dir_Or_Panic (Path : String) return System.Address is
      Handle : constant System.Address := OS.Open_Dir (Path);
   begin
      if OS.Is_Null (Handle) then
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
      OS.Read_Dir (Dir, Name_Buf, Name_Last, Is_Directory, Is_File);
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
      Sec, Nsec       : OS.Long;
   begin
      if Entry_Type = 1 then
         return Directory;
      end if;
      if Entry_Type = 2 then
         return Regular_File;
      end if;
      OS.File_Status (Full_Path, Found, Directory_Entry, Sec, Nsec);
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
      if not OS.Make_Directory (Path) then
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
                  Ignore (OS.Make_Directory (Prefix));
               end if;
            end;
         end if;
      end loop;
      if not Path_Exists (Path) and then not OS.Make_Directory (Path) then
         Panic ("mkdir failed: " & Path);
      end if;
   end Make_Dirs;

   procedure Rename_Path (Old_Path, New_Path : String) is
   begin
      Log ("RENAME", Old_Path & " -> " & New_Path);
      if not OS.Rename_Path (Old_Path, New_Path) then
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
                     Ignore (OS.Remove_File (Full));
                  end if;
               end;
            end if;
         end;
      end loop;
      Close_Dir (Handle);
      if not OS.Remove_Directory (Path) then
         Panic ("cannot remove directory: " & Path);
      end if;
   end Remove_Tree;

   procedure Remove_Path (Path : String) is
   begin
      Log ("RM", Path);
      if Is_Dir (Path) then
         Remove_Tree (Path);
      elsif Path_Exists (Path) then
         if not OS.Remove_File (Path) then
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
      if OS.Is_Null (Source) then
         Panic ("Copy_File: cannot open " & Src);
      end if;
      Target := C_Fopen (C_Dst'Address, Write_Mode'Address);
      if OS.Is_Null (Target) then
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
      if OS.Is_Null (Stream) then
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
      if OS.Is_Null (Stream) then
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
      Here : constant String := OS.Working_Directory;
   begin
      if Here'Length = 0 then
         Panic ("cannot read the working directory");
      end if;
      return Here;
   end Get_Current_Dir;

   procedure Set_Current_Dir (Path : String) is
   begin
      Log ("CD", Path);
      if not OS.Change_Directory (Path) then
         Panic ("chdir failed: " & Path);
      end if;
   end Set_Current_Dir;

   function Is_Newer (Path1, Path2 : String) return Boolean is
      Found1, Found2 : Boolean;
      Dir1, Dir2     : Boolean;
      Sec1, Nsec1    : OS.Long;
      Sec2, Nsec2    : OS.Long;
   begin
      OS.File_Status (Path1, Found1, Dir1, Sec1, Nsec1);
      if not Found1 then
         return False;
      end if;
      OS.File_Status (Path2, Found2, Dir2, Sec2, Nsec2);
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

      begin
         Compile_Program (Source_Path, Binary_Path, No_Args, Extra);
      exception
         when others =>
            if Path_Exists (Old_Binary) then
               Rename_Path (Old_Binary, Bin);
            end if;
            raise;
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
         Ignore (OS.Wait_For (Pid));
         Clear (Forwarded);
      end;

      --  Leave this, the superseded process; the rebuilt one has run.
      OS.Exit_Process (0);
   end Rebuild_And_Reexec;

   procedure Go_Rebuild_Urself
     (Binary_Path : String;
      Source_Path : String;
      Extra       : Argument_List := No_Args) is
   begin
      if not Path_Exists (Source_Path) then
         return;
      end if;
      if Platform = Windows and then not Ends_With (Binary_Path, ".exe") then
         Rebuild_And_Reexec (Binary_Path & ".exe", Binary_Path,
                             Source_Path, Extra);
      else
         Rebuild_And_Reexec (Binary_Path, Binary_Path, Source_Path, Extra);
      end if;
   end Go_Rebuild_Urself;

end No_Build;
