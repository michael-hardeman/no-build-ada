--  no_build.adb -- Ada 83 port.  Phase 1: platform probe, Str,
--  Argument_List, Redirect, path utilities, logging, compiler
--  descriptors.  Subprograms that need the OS layer (phases 2..5) log
--  an [ERRO] and raise Build_Error until their phase lands.

with Unchecked_Deallocation;

package body No_Build is

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

   --------------------------------------------------------------------------
   --  Internal helpers
   --------------------------------------------------------------------------

   procedure Free_String_Storage is
     new Unchecked_Deallocation (String, Str);
   procedure Free_Array_Storage is
     new Unchecked_Deallocation (Str_Array, Str_Array_Access);
   procedure Free_Proc_Storage is
     new Unchecked_Deallocation (Proc_Array, Proc_Array_Access);

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
         Compile_Flags         => No_Args,
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

   function ObjectAda_Compiler return Ada_Compiler is
      PIC    : Argument_List;
      Shared : Argument_List;
   begin
      if Platform /= Windows then
         Append (PIC, "-fpic");
      end if;
      if Platform = MacOS then
         Shared := Args ("-dynamiclib", "-undefined", "dynamic_lookup");
      else
         Append (Shared, "-shared");
      end if;
      return
        (Executable            => new String'("adabuild"),
         Compile_Flags         => No_Args,
         PIC_Flags             => PIC,
         Obj_Flag              => new String'("-D"),
         Out_Flag              => new String'("-o"),
         Compile_Only_Flag     => new String'("-c"),
         Shared_Linker         => new String'("gcc"),
         Shared_Flags          => Shared,
         Shared_Out_Flag       => new String'("-o"),
         Shared_Runtime_Probe  => Gnat_Runtime_Probe,
         Static_Archiver       => new String'("ar"),
         Static_Archiver_Flags => Args ("rcs"),
         Source_Spec_Ext       => new String'(".ads"),
         Source_Body_Ext       => new String'(".adb"),
         Object_Ext            => new String'(".o"),
         Resolve_Source        => No_Resolver);
   end ObjectAda_Compiler;

   function Janus_Compiler return Ada_Compiler is
   begin
      return
        (Executable            => new String'("janus"),
         Compile_Flags         => No_Args,
         PIC_Flags             => No_Args,
         Obj_Flag              => new String'("/OBJDIR="),
         Out_Flag              => new String'("/OUT="),
         Compile_Only_Flag     => new String'("/COMPILE"),
         Shared_Linker         => new String'("gcc"),
         Shared_Flags          => Args ("-shared"),
         Shared_Out_Flag       => new String'("-o"),
         Shared_Runtime_Probe  => No_Probe,
         Static_Archiver       => new String'("ar"),
         Static_Archiver_Flags => Args ("rcs"),
         Source_Spec_Ext       => new String'(".ads"),
         Source_Body_Ext       => new String'(".adb"),
         Object_Ext            => new String'(".obj"),
         Resolve_Source        => No_Resolver);
   end Janus_Compiler;

   procedure Set_Compiler (C : Ada_Compiler) is
   begin
      Active_Compiler     := C;
      Active_Compiler_Set := True;
   end Set_Compiler;

   --------------------------------------------------------------------------
   --  Phase 2..5 stubs
   --------------------------------------------------------------------------

   procedure Cmd
     (Program : String;
      Args     : Argument_List := No_Args;
      Redir    : Redirect      := No_Redirect) is
   begin
      Unimplemented ("Cmd");
   end Cmd;

   procedure Sh (Command : String) is
   begin
      Unimplemented ("Sh");
   end Sh;

   function Capture
     (Program  : String;
      Args     : Argument_List := No_Args) return String is
   begin
      Unimplemented ("Capture");
      return "";
   end Capture;

   function Cmd_Async
     (Program  : String;
      Args     : Argument_List := No_Args;
      Redir    : Redirect      := No_Redirect) return Proc is
   begin
      Unimplemented ("Cmd_Async");
      return Invalid_Proc;
   end Cmd_Async;

   procedure Wait (P : Proc) is
   begin
      Unimplemented ("Wait");
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
      Unimplemented ("N_Procs");
      return 1;
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
      Unimplemented ("Path_Exists");
      return False;
   end Path_Exists;

   function Is_Dir (Path : String) return Boolean is
   begin
      Unimplemented ("Is_Dir");
      return False;
   end Is_Dir;

   procedure Make_Dir (Path : String) is
   begin
      Unimplemented ("Make_Dir");
   end Make_Dir;

   procedure Make_Dirs (Path : String) is
   begin
      Unimplemented ("Make_Dirs");
   end Make_Dirs;

   procedure Rename_Path (Old_Path, New_Path : String) is
   begin
      Unimplemented ("Rename_Path");
   end Rename_Path;

   procedure Remove_Path (Path : String) is
   begin
      Unimplemented ("Remove_Path");
   end Remove_Path;

   procedure Copy_File (Src, Dst : String) is
   begin
      Unimplemented ("Copy_File");
   end Copy_File;

   procedure Copy_Dir (Src, Dst : String) is
   begin
      Unimplemented ("Copy_Dir");
   end Copy_Dir;

   function Read_File (Path : String) return String is
   begin
      Unimplemented ("Read_File");
      return "";
   end Read_File;

   procedure Write_File (Path : String; Contents : String) is
   begin
      Unimplemented ("Write_File");
   end Write_File;

   function Get_Current_Dir return String is
   begin
      Unimplemented ("Get_Current_Dir");
      return "";
   end Get_Current_Dir;

   procedure Set_Current_Dir (Path : String) is
   begin
      Unimplemented ("Set_Current_Dir");
   end Set_Current_Dir;

   function Is_Newer (Path1, Path2 : String) return Boolean is
   begin
      Unimplemented ("Is_Newer");
      return False;
   end Is_Newer;

   function Needs_Rebuild (Output : String; Inputs : Argument_List)
     return Boolean is
   begin
      Unimplemented ("Needs_Rebuild");
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
