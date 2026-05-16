--  no_build.adb -- Implementation of the No_Build package.

with Ada.Text_IO;
with Ada.Calendar;
with Ada.Directories;
with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
with System.Multiprocessors;
with GNAT.OS_Lib;

package body No_Build is

   use Ada.Text_IO;

   --  Bring in equality/relational operators for GNAT.OS_Lib private types
   --  without pulling every name from GNAT.OS_Lib into scope.
   use type GNAT.OS_Lib.String_Access;
   use type GNAT.OS_Lib.Process_Id;
   use type GNAT.OS_Lib.File_Descriptor;

   --------------------------------------------------------------------------
   --  Internal bridge: convert our types to GNAT.OS_Lib types.
   --  Removed in Phase 3 when GNAT.OS_Lib is fully eliminated.
   --
   --  Both String_Access and GNAT.OS_Lib.String_Access are "access String";
   --  they share identical representations (a single pointer word), so the
   --  unchecked conversion is safe on all supported targets.
   --------------------------------------------------------------------------

   function To_GNAT_SA is new Ada.Unchecked_Conversion
     (String_Access, GNAT.OS_Lib.String_Access);

   function To_GNAT_Args
     (Args : Argument_List) return GNAT.OS_Lib.Argument_List
   is
      Result : GNAT.OS_Lib.Argument_List (Args'First .. Args'Last);
   begin
      for I in Args'Range loop
         Result (I) := To_GNAT_SA (Args (I));
      end loop;
      return Result;
   end To_GNAT_Args;

   --------------------------------------------------------------------------
   --  Platform detection
   --------------------------------------------------------------------------

   function Detect_Platform return Platform_Kind is
   begin
      --  WINDIR is a Windows system environment variable that is always
      --  present on any Windows installation and never set on POSIX systems.
      if Ada.Environment_Variables.Exists ("WINDIR") then
         return Windows;
      --  /usr/bin/sw_vers is a macOS system utility present on every macOS
      --  installation since 10.3 and absent on Linux.
      elsif Ada.Directories.Exists ("/usr/bin/sw_vers") then
         return MacOS;
      else
         return Linux;
      end if;
   end Detect_Platform;

   --------------------------------------------------------------------------
   --  Logging
   --------------------------------------------------------------------------

   procedure Default_Log_Handler (Tag, Msg : String) is
   begin
      Put_Line (Standard_Error, "[" & Tag & "] " & Msg);
   end Default_Log_Handler;

   Active_Handler : Log_Handler := Default_Log_Handler'Access;

   procedure Log (Tag, Msg : String) is
   begin
      if Active_Handler /= null then
         Active_Handler (Tag, Msg);
      end if;
   end Log;

   procedure Set_Log_Handler (Handler : Log_Handler) is
   begin
      if Handler = null then
         Active_Handler := Default_Log_Handler'Access;
      else
         Active_Handler := Handler;
      end if;
   end Set_Log_Handler;

   --------------------------------------------------------------------------
   --  String_Access helper
   --------------------------------------------------------------------------

   function S (Str : String) return String_Access is
   begin
      return new String'(Str);
   end S;

   --------------------------------------------------------------------------
   --  Command execution
   --------------------------------------------------------------------------

   procedure Cmd (Program : String; Args : Argument_List) is
   begin
      Cmd (Program, Args, No_Redirect);
   end Cmd;

   procedure Cmd (Program : String) is
      Empty : constant Argument_List (1 .. 0) := (others => null);
   begin
      Cmd (Program, Empty, No_Redirect);
   end Cmd;

   procedure Sh (Command : String) is
   begin
      case Platform is
         when Linux | MacOS =>
            Cmd ("/bin/sh", Argument_List'(S ("-c"), S (Command)));
         when Windows =>
            Cmd ("cmd.exe", Argument_List'(S ("/c"), S (Command)));
      end case;
   end Sh;

   --------------------------------------------------------------------------
   --  Internal helpers
   --------------------------------------------------------------------------

   --  Locate Program on PATH, log the command line, raise on not-found.
   --  Returns the resolved absolute path as a String.
   function Resolve_Program
     (Program : String;
      Display : String) return String
   is
      Prog_Path : GNAT.OS_Lib.String_Access;
   begin
      Log ("CMD", Display);
      Prog_Path := GNAT.OS_Lib.Locate_Exec_On_Path (Program);
      if Prog_Path = null then
         Log ("ERRO", "program not found on PATH: " & Program);
         raise Build_Error with "program not found: " & Program;
      end if;
      declare
         Result : constant String := Prog_Path.all;
      begin
         GNAT.OS_Lib.Free (Prog_Path);
         return Result;
      end;
   end Resolve_Program;

   --  Build a display string "program arg1 arg2 ..." for logging.
   function Display_Of
     (Program : String; Args : Argument_List) return String
   is
      use Ada.Strings.Unbounded;
      D : Unbounded_String := To_Unbounded_String (Program);
   begin
      for A of Args loop
         if A /= null then
            Append (D, " " & A.all);
         end if;
      end loop;
      return To_String (D);
   end Display_Of;

   procedure Cmd
     (Program : String;
      Args    : Argument_List;
      Redir   : Redirect)
   is
      Display   : constant String                      := Display_Of (Program, Args);
      Prog_Path : constant String                      := Resolve_Program (Program, Display);
      GNAT_Args : constant GNAT.OS_Lib.Argument_List   := To_GNAT_Args (Args);
      Pid       : GNAT.OS_Lib.Process_Id;
      Success   : Boolean;
   begin
      if Redir.Stdout = null and then Redir.Stderr = null then
         declare
            Exit_Code : constant Integer :=
              GNAT.OS_Lib.Spawn (Prog_Path, GNAT_Args);
         begin
            if Exit_Code /= 0 then
               Log ("ERRO", "command exited with status" & Exit_Code'Image);
               raise Build_Error with "command failed: " & Program;
            end if;
         end;
      elsif Redir.Stdout /= null and then Redir.Stderr /= null then
         Pid := GNAT.OS_Lib.Non_Blocking_Spawn
           (Prog_Path, GNAT_Args, Redir.Stdout.all, Redir.Stderr.all);
         if Pid = GNAT.OS_Lib.Invalid_Pid then
            raise Build_Error with "could not spawn: " & Program;
         end if;
         GNAT.OS_Lib.Wait_Process (Pid, Success);
         if not Success then
            Log ("ERRO", "command failed: " & Program);
            raise Build_Error with "command failed: " & Program;
         end if;
      elsif Redir.Stdout /= null then
         Pid := GNAT.OS_Lib.Non_Blocking_Spawn
           (Prog_Path, GNAT_Args, Redir.Stdout.all, Err_To_Out => False);
         if Pid = GNAT.OS_Lib.Invalid_Pid then
            raise Build_Error with "could not spawn: " & Program;
         end if;
         GNAT.OS_Lib.Wait_Process (Pid, Success);
         if not Success then
            Log ("ERRO", "command failed: " & Program);
            raise Build_Error with "command failed: " & Program;
         end if;
      else
         --  Stderr only: route both streams into the stderr file.
         Pid := GNAT.OS_Lib.Non_Blocking_Spawn
           (Prog_Path, GNAT_Args, Redir.Stderr.all, Err_To_Out => True);
         if Pid = GNAT.OS_Lib.Invalid_Pid then
            raise Build_Error with "could not spawn: " & Program;
         end if;
         GNAT.OS_Lib.Wait_Process (Pid, Success);
         if not Success then
            Log ("ERRO", "command failed: " & Program);
            raise Build_Error with "command failed: " & Program;
         end if;
      end if;
   end Cmd;

   function Cmd_Async
     (Program : String;
      Args    : Argument_List;
      Redir   : Redirect := No_Redirect) return Proc
   is
      Display   : constant String                    := Display_Of (Program, Args);
      Prog_Path : constant String                    := Resolve_Program (Program, Display);
      GNAT_Args : constant GNAT.OS_Lib.Argument_List := To_GNAT_Args (Args);
      Pid       : GNAT.OS_Lib.Process_Id;
   begin
      if Redir.Stdout /= null and then Redir.Stderr /= null then
         Pid := GNAT.OS_Lib.Non_Blocking_Spawn
           (Prog_Path, GNAT_Args, Redir.Stdout.all, Redir.Stderr.all);
      elsif Redir.Stdout /= null then
         Pid := GNAT.OS_Lib.Non_Blocking_Spawn
           (Prog_Path, GNAT_Args, Redir.Stdout.all, Err_To_Out => False);
      elsif Redir.Stderr /= null then
         Pid := GNAT.OS_Lib.Non_Blocking_Spawn
           (Prog_Path, GNAT_Args, Redir.Stderr.all, Err_To_Out => True);
      else
         Pid := GNAT.OS_Lib.Non_Blocking_Spawn (Prog_Path, GNAT_Args);
      end if;

      if Pid = GNAT.OS_Lib.Invalid_Pid then
         raise Build_Error with "could not spawn: " & Program;
      end if;
      return (Pid => Pid);
   end Cmd_Async;

   function Cmd_Async (Program : String) return Proc is
      Empty : constant Argument_List (1 .. 0) := (others => null);
   begin
      return Cmd_Async (Program, Empty);
   end Cmd_Async;

   procedure Wait (P : Proc) is
      Done    : GNAT.OS_Lib.Process_Id;
      Success : Boolean;
   begin
      loop
         GNAT.OS_Lib.Wait_Process (Done, Success);
         exit when Done = P.Pid or else Done = GNAT.OS_Lib.Invalid_Pid;
      end loop;
      if not Success then
         raise Build_Error with "process exited with non-zero status";
      end if;
   end Wait;

   procedure Append (List : in out Proc_List; P : Proc) is
   begin
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
         declare
            Done    : GNAT.OS_Lib.Process_Id;
            Success : Boolean;
         begin
            loop
               GNAT.OS_Lib.Wait_Process (Done, Success);
               for J in 1 .. List.Count loop
                  if List.Items (J).Pid = Done then
                     List.Items (J) := Invalid_Proc;
                     exit;
                  end if;
               end loop;
               exit when Done = List.Items (I).Pid
                 or else List.Items (I).Pid = GNAT.OS_Lib.Invalid_Pid
                 or else Done = GNAT.OS_Lib.Invalid_Pid;
            end loop;
            if not Success then
               Any_Failed := True;
            end if;
         end;
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
   --  Compile (compile-only, no link)
   --------------------------------------------------------------------------

   procedure Compile
     (Source  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null))
   is
   begin
      Gnatmake (Source, Obj_Dir => Obj_Dir,
                Extra => Argument_List'(1 => S ("-c")) & Extra);
   end Compile;

   --------------------------------------------------------------------------
   --  Build_Lib_Objects: compile each .adb in Src_Dir, collect .o paths.
   --------------------------------------------------------------------------

   procedure Build_Lib_Objects
     (Src_Dir : String;
      Obj_Dir : String;
      PIC     : Boolean;
      Extra   : Argument_List;
      Objects : out Argument_List;
      N_Obj   : out Natural)
   is
      use Ada.Directories;
      Eff_Obj  : constant String := (if Obj_Dir /= "" then Obj_Dir else ".");
      Search   : Search_Type;
      Dir_Ent  : Directory_Entry_Type;
      --  -fPIC is needed on POSIX; not meaningful on Windows.
      PIC_Flag : constant Argument_List :=
        (if PIC and then Platform /= Windows
         then Argument_List'(1 => S ("-fPIC"))
         else Argument_List'(1 .. 0 => null));
      Flags    : constant Argument_List :=
        (if PIC then PIC_Flag & Extra else Extra);
   begin
      N_Obj := 0;
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
               N_Obj := N_Obj + 1;
               Objects (N_Obj) := S (Eff_Obj / No_Ext (Name) & ".o");
            end if;
         end;
      end loop;
      End_Search (Search);
   end Build_Lib_Objects;

   procedure Build_Static_Lib
     (Src_Dir : String;
      Output  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null))
   is
      Objects : Argument_List (1 .. 256) := (others => null);
      N_Obj   : Natural;
   begin
      Build_Lib_Objects (Src_Dir, Obj_Dir, PIC => False,
                         Extra => Extra, Objects => Objects, N_Obj => N_Obj);
      if N_Obj > 0 then
         Cmd ("ar", Argument_List'(S ("rcs"), S (Output)) & Objects (1 .. N_Obj));
      end if;
   end Build_Static_Lib;

   procedure Build_Shared_Lib
     (Src_Dir : String;
      Output  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null))
   is
      Objects : Argument_List (1 .. 256) := (others => null);
      N_Obj   : Natural;
   begin
      Build_Lib_Objects (Src_Dir, Obj_Dir, PIC => True,
                         Extra => Extra, Objects => Objects, N_Obj => N_Obj);
      if N_Obj > 0 then
         case Platform is
            when Linux =>
               Cmd ("gcc",
                    Argument_List'(S ("-shared"), S ("-o"), S (Output)) &
                    Objects (1 .. N_Obj));
            when MacOS =>
               Cmd ("gcc",
                    Argument_List'(S ("-dynamiclib"), S ("-o"), S (Output)) &
                    Objects (1 .. N_Obj));
            when Windows =>
               Cmd ("gcc",
                    Argument_List'(S ("-shared"), S ("-o"), S (Output)) &
                    Objects (1 .. N_Obj));
         end case;
      end if;
   end Build_Shared_Lib;

   --------------------------------------------------------------------------
   --  Gnatmake
   --------------------------------------------------------------------------

   procedure Gnatmake
     (Source  : String;
      Output  : String        := "";
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null))
   is
   begin
      if Obj_Dir /= "" then
         Make_Dirs (Obj_Dir);
      end if;

      if Output = "" and then Obj_Dir = "" then
         Cmd ("gnatmake", Argument_List'(1 => S (Source)) & Extra);
      elsif Output = "" then
         Cmd ("gnatmake",
              Argument_List'(S (Source), S ("-D"), S (Obj_Dir)) & Extra);
      elsif Obj_Dir = "" then
         Cmd ("gnatmake",
              Argument_List'(S (Source), S ("-o"), S (Output)) & Extra);
      else
         Cmd ("gnatmake",
              Argument_List'(S (Source), S ("-D"), S (Obj_Dir),
                             S ("-o"), S (Output)) & Extra);
      end if;
   end Gnatmake;

   --------------------------------------------------------------------------
   --  Path utilities
   --------------------------------------------------------------------------

   function "/" (Left, Right : String) return String is
   begin
      if Left = "" then
         return Right;
      elsif Left (Left'Last) = '/' then
         return Left & Right;
      else
         return Left & "/" & Right;
      end if;
   end "/";

   function No_Ext (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '.' then
            return Path (Path'First .. I - 1);
         elsif Path (I) = '/' then
            exit;
         end if;
      end loop;
      return Path;
   end No_Ext;

   function Ends_With (Str, Suffix : String) return Boolean is
   begin
      if Suffix'Length > Str'Length then
         return False;
      end if;
      return Str (Str'Last - Suffix'Length + 1 .. Str'Last) = Suffix;
   end Ends_With;

   function Base_Name (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (I + 1 .. Path'Last);
         end if;
      end loop;
      return Path;
   end Base_Name;

   --------------------------------------------------------------------------
   --  Filesystem predicates
   --------------------------------------------------------------------------

   function Path_Exists (Path : String) return Boolean is
   begin
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

   procedure Make_Dir (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Log ("WARN", "directory already exists: " & Path);
      else
         Log ("MKDIR", Path);
         Ada.Directories.Create_Directory (Path);
      end if;
   end Make_Dir;

   procedure Make_Dirs (Path : String) is
   begin
      Log ("MKDIRS", Path);
      for I in Path'Range loop
         if Path (I) = '/' and then I > Path'First then
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
      Success : Boolean;
   begin
      Log ("RENAME", Old_Path & " -> " & New_Path);
      GNAT.OS_Lib.Rename_File (Old_Path, New_Path, Success);
      if not Success then
         Log ("ERRO", "could not rename " & Old_Path & " to " & New_Path);
         raise Build_Error with "rename failed: " & Old_Path;
      end if;
   end Rename_Path;

   procedure Remove_Path (Path : String) is
   begin
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
         if I /= null and then Is_Newer (I.all, Output) then
            return True;
         end if;
      end loop;
      return False;
   end Needs_Rebuild;

   --------------------------------------------------------------------------
   --  Directory iteration
   --------------------------------------------------------------------------

   procedure For_Each_File
     (Dir     : String;
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

   function Walk_Dir_Rec
     (Dir   : String;
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
                     when Ada.Directories.Special_File  =>
                        if GNAT.OS_Lib.Is_Symbolic_Link (Full) then
                           Kind := Symlink;
                        else
                           Kind := Other;
                        end if;
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

   procedure Walk_Dir (Root : String; Func : Walk_Func) is
      Dummy : Boolean;
   begin
      Dummy := Walk_Dir_Rec (Root, Func, 0);
   end Walk_Dir;

   --------------------------------------------------------------------------
   --  Copy_File / Copy_Dir
   --------------------------------------------------------------------------

   procedure Copy_File (Src, Dst : String) is
   begin
      Log ("CP", Src & " -> " & Dst);
      Ada.Directories.Copy_File
        (Source_Name => Src, Target_Name => Dst,
         Form        => "");
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
                        when Ada.Directories.Directory =>
                           Recurse (Src_Path, Dst_Path);
                        when Ada.Directories.Ordinary_File =>
                           No_Build.Copy_File (Src_Path, Dst_Path);
                        when Ada.Directories.Special_File => null;
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
      FD     : constant GNAT.OS_Lib.File_Descriptor :=
        GNAT.OS_Lib.Open_Read (Path, GNAT.OS_Lib.Binary);
      Len    : constant Integer :=
        Integer (GNAT.OS_Lib.File_Length (FD));
      Buffer : String (1 .. Len);
      N_Read : Integer;
   begin
      if FD = GNAT.OS_Lib.Invalid_FD then
         raise Build_Error with "cannot open file: " & Path;
      end if;
      N_Read := GNAT.OS_Lib.Read (FD, Buffer'Address, Len);
      GNAT.OS_Lib.Close (FD);
      return Buffer (1 .. N_Read);
   end Read_File;

   procedure Write_File (Path : String; Contents : String) is
      FD        : constant GNAT.OS_Lib.File_Descriptor :=
        GNAT.OS_Lib.Create_File (Path, GNAT.OS_Lib.Binary);
      N_Written : Integer;
   begin
      if FD = GNAT.OS_Lib.Invalid_FD then
         raise Build_Error with "cannot create file: " & Path;
      end if;
      N_Written := GNAT.OS_Lib.Write (FD, Contents'Address, Contents'Length);
      GNAT.OS_Lib.Close (FD);
      if N_Written /= Contents'Length then
         raise Build_Error with "incomplete write to: " & Path;
      end if;
   end Write_File;

   function Get_Current_Dir return String is
   begin
      return Ada.Directories.Current_Directory;
   end Get_Current_Dir;

   procedure Set_Current_Dir (Path : String) is
   begin
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

   procedure Panic (Msg : String) is
   begin
      Log ("ERRO", Msg);
      raise Build_Error with Msg;
   end Panic;

   --------------------------------------------------------------------------
   --  Go Rebuild Urself(TM)
   --------------------------------------------------------------------------

   procedure Go_Rebuild_Urself
     (Binary_Path : String;
      Source_Path : String;
      Obj_Dir     : String        := "";
      Extra       : Argument_List := (1 .. 0 => null))
   is
      Old_Binary : constant String := Binary_Path & ".old";
   begin
      if not Path_Exists (Source_Path) then
         return;
      end if;

      if Is_Newer (Source_Path, Binary_Path) then
         Info ("build script changed, rebuilding: " & Source_Path);

         if Path_Exists (Binary_Path) then
            Rename_Path (Binary_Path, Old_Binary);
         end if;

         begin
            Gnatmake (Source_Path, Output => Binary_Path,
                      Obj_Dir => Obj_Dir, Extra => Extra);
         exception
            when others =>
               if Path_Exists (Old_Binary) then
                  Rename_Path (Old_Binary, Binary_Path);
               end if;
               raise;
         end;

         if Path_Exists (Old_Binary) then
            Remove_Path (Old_Binary);
         end if;

         declare
            Args      : Argument_List (1 .. Ada.Command_Line.Argument_Count);
            GNAT_Args : GNAT.OS_Lib.Argument_List
                          (1 .. Ada.Command_Line.Argument_Count);
            Exit_Code : Integer;
         begin
            for I in Args'Range loop
               Args (I) := new String'(Ada.Command_Line.Argument (I));
            end loop;
            GNAT_Args := To_GNAT_Args (Args);
            Info ("re-executing: " & Binary_Path);
            Exit_Code := GNAT.OS_Lib.Spawn (Binary_Path, GNAT_Args);
            GNAT.OS_Lib.OS_Exit (Exit_Code);
         end;
      end if;
   end Go_Rebuild_Urself;

end No_Build;
