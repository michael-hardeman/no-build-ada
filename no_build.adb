--  no_build.adb -- Ada 83 port.  Phase 1: platform probe, Str,
--  Argument_List, Redirect, path utilities, logging, compiler
--  descriptors.  Subprograms that need the OS layer (phases 2..5) log
--  an [ERRO] and raise Build_Error until their phase lands.

with Unchecked_Conversion;
with Unchecked_Deallocation;

package body No_Build is

   type Long is range -(2 ** 63) .. 2 ** 63 - 1;

   type Address_Array is array (Positive range <>) of System.Address;

   type Stat_Words is array (1 .. 18) of Long;

   Open_Write_Create_Truncate : constant Integer := 577;
   Mode_755                   : constant Integer := 493;
   Mode_644                   : constant Integer := 420;
   Seek_Set                   : constant Integer := 0;
   Seek_End                   : constant Integer := 2;
   Sysconf_Nprocessors_Onln   : constant Integer := 84;

   Active_Level : Log_Level := Verbose;

   Platform_Known : Boolean       := False;
   Platform_Value : Platform_Kind := Linux;

   Active_Compiler_Set : Boolean := False;
   Active_Compiler     : Ada_Compiler;

   --------------------------------------------------------------------------
   --  C bindings (phase 1 needs only these three)
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

   procedure C_Exit_Process (Status : Integer);
   pragma Import (C, C_Exit_Process, "_exit");

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

   function C_Unlink (Path : System.Address) return Integer;
   pragma Import (C, C_Unlink, "unlink");

   function C_Rename (Old_Path, New_Path : System.Address) return Integer;
   pragma Import (C, C_Rename, "rename");

   function C_Chdir (Path : System.Address) return Integer;
   pragma Import (C, C_Chdir, "chdir");

   function C_Getcwd (Buffer : System.Address; Size : Long)
     return System.Address;
   pragma Import (C, C_Getcwd, "getcwd");

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

   --------------------------------------------------------------------------
   --  Internal helpers
   --------------------------------------------------------------------------

   procedure Free_String_Storage is
     new Unchecked_Deallocation (String, Str);
   procedure Free_Array_Storage is
     new Unchecked_Deallocation (Str_Array, Str_Array_Access);
   procedure Free_Proc_Storage is
     new Unchecked_Deallocation (Proc_Array, Proc_Array_Access);

   function To_Address_Value is
     new Unchecked_Conversion (Long, System.Address);
   function To_Long_Value is
     new Unchecked_Conversion (System.Address, Long);

   function Null_Addr return System.Address is
   begin
      return To_Address_Value (0);
   end Null_Addr;

   function Is_Null (A : System.Address) return Boolean is
   begin
      return To_Long_Value (A) = 0;
   end Is_Null;

   function C_Str (S : String) return Str is
   begin
      return new String'(S & ASCII.NUL);
   end C_Str;

   function Data_Address (S : Str) return System.Address is
   begin
      return S.all (S.all'First)'Address;
   end Data_Address;

   function File_Reachable (Path : String) return Boolean is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      return C_Access (C_Path'Address, 0) = 0;
   end File_Reachable;

   procedure Put_Stderr (Line : String) is
      Buffer  : constant String := Line & ASCII.LF & ASCII.NUL;
      Ignored : Integer;
   begin
      Ignored := C_Fputs (Buffer'Address, C_Stderr);
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
         if File_Reachable ("C:\Windows") then
            Platform_Value := Windows;
         elsif File_Reachable ("/usr/bin/sw_vers") then
            Platform_Value := MacOS;
         else
            Platform_Value := Linux;
         end if;
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
      if Platform = Windows then
         return '\';
      end if;
      return '/';
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
   --  Compiler descriptors
   --------------------------------------------------------------------------

   function Gnatmake_Compiler return Ada_Compiler is
      PIC    : Argument_List;
      Shared : Argument_List;
      Probe  : Runtime_Probe_Kind := Gnat_Runtime_Probe;
   begin
      if Platform /= Windows then
         Append (PIC, "-fPIC");
      end if;
      if Platform = MacOS then
         --  "-undefined dynamic_lookup" defers runtime resolution to load
         --  time, so libgnat need not be embedded (and the probe's
         --  gcc -print-libgcc-file-name is unreliable on Alire toolchains).
         Shared := Args ("-dynamiclib", "-undefined", "dynamic_lookup");
         Probe  := No_Probe;
      else
         Append (Shared, "-shared");
      end if;
      return
        (Executable            => new String'("gnatmake"),
         Compile_Flags         => Args ("-gnat83"),
         PIC_Flags             => PIC,
         Obj_Flag              => new String'("-D"),
         Out_Flag              => new String'("-o"),
         Compile_Only_Flag     => new String'("-c"),
         Shared_Linker         => new String'("gcc"),
         Shared_Flags          => Shared,
         Shared_Out_Flag       => new String'("-o"),
         Shared_Runtime_Probe  => Probe,
         Static_Archiver       => new String'("ar"),
         Static_Archiver_Flags => Args ("rcs"),
         Source_Spec_Ext       => new String'(".ads"),
         Source_Body_Ext       => new String'(".adb"),
         Object_Ext            => new String'(".o"),
         Resolve_Source        => Gnat_Spec_To_Body);
   end Gnatmake_Compiler;

   function Ada83_Compiler return Ada_Compiler is
   begin
      --  ada83 emits one .ll per source with --ir and links .ll modules
      --  with the main source in one step; there is no separate object
      --  directory notion, so Obj_Flag is null and Build_*_Lib collects
      --  .ll files.
      return
        (Executable            => new String'("ada83"),
         Compile_Flags         => No_Args,
         PIC_Flags             => No_Args,
         Obj_Flag              => null,
         Out_Flag              => new String'("-o"),
         Compile_Only_Flag     => new String'("--ir"),
         Shared_Linker         => new String'("cc"),
         Shared_Flags          => Args ("-shared"),
         Shared_Out_Flag       => new String'("-o"),
         Shared_Runtime_Probe  => No_Probe,
         Static_Archiver       => new String'("ar"),
         Static_Archiver_Flags => Args ("rcs"),
         Source_Spec_Ext       => new String'(".ads"),
         Source_Body_Ext       => new String'(".adb"),
         Object_Ext            => new String'(".ll"),
         Resolve_Source        => No_Resolver);
   end Ada83_Compiler;

   procedure Set_Compiler (C : Ada_Compiler) is
   begin
      Active_Compiler     := C;
      Active_Compiler_Set := True;
   end Set_Compiler;

   --------------------------------------------------------------------------
   --  Process execution (POSIX)
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

   procedure Redirect_Child_Fd (Path : String; Fd : Integer) is
      C_Path  : constant String := Path & ASCII.NUL;
      File_Fd : Integer;
      Ignored : Integer;
   begin
      File_Fd := C_Open (C_Path'Address, Open_Write_Create_Truncate,
                         Mode_644);
      if File_Fd < 0 then
         C_Exit_Process (126);
      end if;
      Ignored := C_Dup2 (File_Fd, Fd);
      Ignored := C_Close (File_Fd);
   end Redirect_Child_Fd;

   function Spawn
     (Program : String;
      List    : Argument_List;
      Redir   : Redirect) return Integer is
      Argc    : constant Natural := Length (List);
      Argv    : Address_Array (1 .. Argc + 2);
      Holders : Str_Array (1 .. Argc + 1);
      Pid     : Integer;
      Ignored : Integer;
   begin
      Holders (1) := C_Str (Program);
      Argv (1)    := Data_Address (Holders (1));
      for I in 1 .. Argc loop
         Holders (I + 1) := C_Str (Element (List, I));
         Argv (I + 1)    := Data_Address (Holders (I + 1));
      end loop;
      Argv (Argc + 2) := Null_Addr;

      Pid := C_Fork;
      if Pid = 0 then
         if Redir.Stdout /= null then
            Redirect_Child_Fd (Redir.Stdout.all, 1);
         end if;
         if Redir.Stderr /= null then
            Redirect_Child_Fd (Redir.Stderr.all, 2);
         end if;
         Ignored := C_Execvp (Argv (1), Argv'Address);
         C_Exit_Process (127);
      elsif Pid < 0 then
         Panic ("fork failed for " & Program);
      end if;

      for I in Holders'Range loop
         Free_String_Storage (Holders (I));
      end loop;
      return Pid;
   end Spawn;

   procedure Check_Child_Status (Status : Integer; Label : String) is
      Signal_Bits : constant Integer := Status mod 128;
      Exit_Code   : constant Integer := (Status / 256) mod 256;
   begin
      if Signal_Bits /= 0 then
         Panic (Label & ": terminated by signal" &
                Integer'Image (Signal_Bits));
      elsif Exit_Code /= 0 then
         Panic (Label & ": exit code" & Integer'Image (Exit_Code));
      end if;
   end Check_Child_Status;

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
      Pid     : Integer;
      Status  : Integer := 0;
      Ignored : Integer;
   begin
      if Length (Args) = 0 then
         Log ("CMD", Program);
      else
         Log ("CMD", Program & " " & Join_From (Args, 1));
      end if;
      Pid     := Spawn (Program, Args, Redir);
      Ignored := C_Waitpid (Pid, Status'Address, 0);
      Check_Child_Status (Status, Program);
   end Cmd;

   procedure Sh (Command : String) is
   begin
      if Platform = Windows then
         Unimplemented ("Sh on Windows");
      end if;
      Cmd ("/bin/sh", Args ("-c", Command));
   end Sh;

   function Capture
     (Program  : String;
      Args     : Argument_List := No_Args) return String is
      Pid_Image : constant String := Integer'Image (C_Getpid);
      Temp_Path : constant String :=
        "/tmp/no_build_capture_" & Pid_Image (2 .. Pid_Image'Last) & ".txt";
      C_Temp    : constant String := Temp_Path & ASCII.NUL;
      Ignored   : Integer;
   begin
      begin
         Cmd (Program, Args, To_File (Stdout => Temp_Path));
      exception
         when Build_Error =>
            Ignored := C_Unlink (C_Temp'Address);
            raise;
      end;
      declare
         Raw : constant String := Read_File (Temp_Path);
      begin
         Ignored := C_Unlink (C_Temp'Address);
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
      Status  : Integer := 0;
      Ignored : Integer;
   begin
      if P.Pid <= 0 then
         Panic ("Wait: invalid process handle");
      end if;
      Ignored := C_Waitpid (P.Pid, Status'Address, 0);
      Check_Child_Status (Status, "pid" & Integer'Image (P.Pid));
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
      Count : constant Long := C_Sysconf (Sysconf_Nprocessors_Onln);
   begin
      if Count < 1 then
         return 1;
      end if;
      return Positive (Count);
   end N_Procs;

   function Find_Gnat_Runtime return String is
   begin
      Unimplemented ("Find_Gnat_Runtime");
      return "";
   end Find_Gnat_Runtime;

   procedure Compile_Program
     (Source  : String;
      Output  : String        := "";
      Obj_Dir : String        := "";
      Extra   : Argument_List := No_Args) is
   begin
      Unimplemented ("Compile_Program");
   end Compile_Program;

   procedure Compile
     (Source  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := No_Args) is
   begin
      Unimplemented ("Compile");
   end Compile;

   procedure Build_Static_Lib
     (Source  : String;
      Output  : String;
      Obj_Dir : String;
      Extra   : Argument_List := No_Args) is
   begin
      Unimplemented ("Build_Static_Lib");
   end Build_Static_Lib;

   procedure Build_Shared_Lib
     (Source  : String;
      Output  : String;
      Obj_Dir : String;
      Extra   : Argument_List := No_Args) is
   begin
      Unimplemented ("Build_Shared_Lib");
   end Build_Shared_Lib;

   function Path_Exists (Path : String) return Boolean is
   begin
      return File_Reachable (Path);
   end Path_Exists;

   procedure Stat_Path
     (Path  : String;
      Words : out Stat_Words;
      RC    : out Integer) is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      RC := C_Stat (C_Path'Address, Words'Address);
   end Stat_Path;

   function Is_Dir (Path : String) return Boolean is
      Words : Stat_Words;
      RC    : Integer;
      Mode  : Integer;
   begin
      Stat_Path (Path, Words, RC);
      if RC /= 0 then
         return False;
      end if;
      Mode := Integer ((Words (4) mod 4294967296) mod 65536);
      return (Mode / 4096) mod 16 = 4;
   end Is_Dir;

   procedure Make_Dir (Path : String) is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      Log ("MKDIR", Path);
      if Path_Exists (Path) then
         Warn ("Make_Dir: " & Path & " already exists");
         return;
      end if;
      if C_Mkdir (C_Path'Address, Mode_755) /= 0 then
         Panic ("mkdir failed: " & Path);
      end if;
   end Make_Dir;

   procedure Make_Dirs (Path : String) is
      Ignored : Integer;
   begin
      Log ("MKDIRS", Path);
      for I in Path'Range loop
         if Is_Separator (Path (I)) and then I > Path'First then
            declare
               Prefix   : constant String := Path (Path'First .. I - 1);
               C_Prefix : constant String := Prefix & ASCII.NUL;
            begin
               if not Path_Exists (Prefix) then
                  Ignored := C_Mkdir (C_Prefix'Address, Mode_755);
               end if;
            end;
         end if;
      end loop;
      if not Path_Exists (Path) then
         declare
            C_Path : constant String := Path & ASCII.NUL;
         begin
            if C_Mkdir (C_Path'Address, Mode_755) /= 0 then
               Panic ("mkdir failed: " & Path);
            end if;
         end;
      end if;
   end Make_Dirs;

   procedure Rename_Path (Old_Path, New_Path : String) is
      C_Old : constant String := Old_Path & ASCII.NUL;
      C_New : constant String := New_Path & ASCII.NUL;
   begin
      Log ("RENAME", Old_Path & " -> " & New_Path);
      if C_Rename (C_Old'Address, C_New'Address) /= 0 then
         Panic ("rename failed: " & Old_Path & " -> " & New_Path);
      end if;
   end Rename_Path;

   procedure Remove_Path (Path : String) is
   begin
      Unimplemented ("Remove_Path");
   end Remove_Path;

   procedure Copy_File (Src, Dst : String) is
      C_Src      : constant String := Src & ASCII.NUL;
      C_Dst      : constant String := Dst & ASCII.NUL;
      Read_Mode  : constant String := "rb" & ASCII.NUL;
      Write_Mode : constant String := "wb" & ASCII.NUL;
      Source     : System.Address;
      Target     : System.Address;
      Ignored    : Integer;
   begin
      Log ("CP", Src & " -> " & Dst);
      Source := C_Fopen (C_Src'Address, Read_Mode'Address);
      if Is_Null (Source) then
         Panic ("Copy_File: cannot open " & Src);
      end if;
      Target := C_Fopen (C_Dst'Address, Write_Mode'Address);
      if Is_Null (Target) then
         Ignored := C_Fclose (Source);
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
               Ignored := C_Fclose (Source);
               Ignored := C_Fclose (Target);
               Panic ("Copy_File: short write to " & Dst);
            end if;
         end loop;
      end;
      Ignored := C_Fclose (Source);
      if C_Fclose (Target) /= 0 then
         Panic ("Copy_File: close failed for " & Dst);
      end if;
   end Copy_File;

   procedure Copy_Dir (Src, Dst : String) is
   begin
      Unimplemented ("Copy_Dir");
   end Copy_Dir;

   function Read_File (Path : String) return String is
      C_Path    : constant String := Path & ASCII.NUL;
      Read_Mode : constant String := "rb" & ASCII.NUL;
      Stream    : System.Address;
      Size      : Long;
      Ignored   : Integer;
   begin
      Stream := C_Fopen (C_Path'Address, Read_Mode'Address);
      if Is_Null (Stream) then
         Panic ("Read_File: cannot open " & Path);
      end if;
      Ignored := C_Fseek (Stream, 0, Seek_End);
      Size    := C_Ftell (Stream);
      Ignored := C_Fseek (Stream, 0, Seek_Set);
      declare
         Result : String (1 .. Integer (Size));
         Got    : Long;
      begin
         Got := C_Fread (Result'Address, 1, Size, Stream);
         Ignored := C_Fclose (Stream);
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
      if Is_Null (Stream) then
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
      Buffer : String (1 .. 4096);
   begin
      if Is_Null (C_Getcwd (Buffer'Address, Long (Buffer'Length))) then
         Panic ("getcwd failed");
      end if;
      for I in Buffer'Range loop
         if Buffer (I) = ASCII.NUL then
            return Buffer (1 .. I - 1);
         end if;
      end loop;
      Panic ("getcwd returned an unterminated path");
      return "";
   end Get_Current_Dir;

   procedure Set_Current_Dir (Path : String) is
      C_Path : constant String := Path & ASCII.NUL;
   begin
      Log ("CD", Path);
      if C_Chdir (C_Path'Address) /= 0 then
         Panic ("chdir failed: " & Path);
      end if;
   end Set_Current_Dir;

   function Is_Newer (Path1, Path2 : String) return Boolean is
      Words1, Words2 : Stat_Words;
      RC1, RC2       : Integer;
   begin
      Stat_Path (Path1, Words1, RC1);
      if RC1 /= 0 then
         return False;
      end if;
      Stat_Path (Path2, Words2, RC2);
      if RC2 /= 0 then
         return True;
      end if;
      if Words1 (12) /= Words2 (12) then
         return Words1 (12) > Words2 (12);
      end if;
      return Words1 (13) > Words2 (13);
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
   begin
      Unimplemented ("For_Each_File");
   end For_Each_File;

   procedure Walk_Dir (Root : String) is
   begin
      Unimplemented ("Walk_Dir");
   end Walk_Dir;

   procedure Go_Rebuild_Urself
     (Binary_Path : String;
      Source_Path : String;
      Obj_Dir     : String        := "";
      Extra       : Argument_List := No_Args) is
   begin
      Unimplemented ("Go_Rebuild_Urself");
   end Go_Rebuild_Urself;

end No_Build;
