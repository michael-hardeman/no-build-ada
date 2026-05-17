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

   --------------------------------------------------------------------------
   --  dlopen / dlsym — the only two pragma Import (C, ...) in this package.
   --  Everything else is loaded at runtime through these two functions.
   --
   --  On Linux (glibc >= 2.34) and macOS these resolve against libc /
   --  libSystem automatically.  On Windows the user must supply a shim that
   --  exports `dlopen` and `dlsym` on top of LoadLibraryA / GetProcAddress
   --  and `with`s it from build.adb so the linker pulls it in.  See the
   --  Windows section of the README for the stock shim.
   --------------------------------------------------------------------------

   type DL_Handle is new System.Address;

   function Default_DL_Open
     (Path : System.Address; Mode : Integer) return DL_Handle;
   pragma Import (C, Default_DL_Open, "dlopen");

   function Default_DL_Sym
     (Handle : DL_Handle; Symbol : System.Address) return System.Address;
   pragma Import (C, Default_DL_Sym, "dlsym");

   --------------------------------------------------------------------------
   --  C helper: convert an Ada String to a null-terminated C string on the
   --  stack, call dlsym, and return the raw address.
   --------------------------------------------------------------------------

   function To_Address is new Ada.Unchecked_Conversion
     (Interfaces.C.Strings.chars_ptr, System.Address);

   function Sym (Handle : DL_Handle; Name : String) return System.Address is
      C_Name : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Name);
      Result : System.Address;
   begin
      Result := Default_DL_Sym (Handle, To_Address (C_Name));
      Interfaces.C.Strings.Free (C_Name);
      return Result;
   end Sym;

   --------------------------------------------------------------------------
   --  POSIX process function pointer types (loaded via dlsym at elaboration)
   --------------------------------------------------------------------------

   type Fork_Func is access function return Interfaces.C.int;
   pragma Convention (C, Fork_Func);

   type Execv_Func is access function
     (Path : System.Address;
      Argv : System.Address) return Interfaces.C.int;
   pragma Convention (C, Execv_Func);

   type Waitpid_Func is access function
     (Pid     : Interfaces.C.int;
      Status  : access Interfaces.C.int;
      Options : Interfaces.C.int) return Interfaces.C.int;
   pragma Convention (C, Waitpid_Func);

   type Exit_Func is access procedure (Status : Interfaces.C.int);
   pragma Convention (C, Exit_Func);

   type Dup2_Func is access function
     (Old_FD, New_FD : Interfaces.C.int) return Interfaces.C.int;
   pragma Convention (C, Dup2_Func);

   type Open_Func is access function
     (Path  : System.Address;
      Flags : Interfaces.C.int;
      Mode  : Interfaces.C.int) return Interfaces.C.int;
   pragma Convention (C, Open_Func);

   type Close_Func is access function
     (FD : Interfaces.C.int) return Interfaces.C.int;
   pragma Convention (C, Close_Func);

   function To_Fork    is new Ada.Unchecked_Conversion (System.Address, Fork_Func);
   function To_Execv   is new Ada.Unchecked_Conversion (System.Address, Execv_Func);
   function To_Waitpid is new Ada.Unchecked_Conversion (System.Address, Waitpid_Func);
   function To_Exit    is new Ada.Unchecked_Conversion (System.Address, Exit_Func);
   function To_Dup2    is new Ada.Unchecked_Conversion (System.Address, Dup2_Func);
   function To_Open    is new Ada.Unchecked_Conversion (System.Address, Open_Func);
   function To_Close   is new Ada.Unchecked_Conversion (System.Address, Close_Func);

   --  Function pointers — initialized by Load_Posix_Symbols (called at
   --  elaboration after Detect_Platform).
   C_Fork    : Fork_Func    := null;
   C_Execv   : Execv_Func   := null;
   C_Waitpid : Waitpid_Func := null;
   C_Exit    : Exit_Func    := null;
   C_Dup2    : Dup2_Func    := null;
   C_Open    : Open_Func    := null;
   C_Close   : Close_Func   := null;

   --  POSIX constants for open(2)
   O_WRONLY   : constant := 1;
   O_CREAT    : constant := 64;    --  Linux; overridden for macOS below
   O_TRUNC    : constant := 512;   --  Linux; overridden for macOS below

   function Open_Flags return Interfaces.C.int is
   begin
      --  macOS uses different values for O_CREAT and O_TRUNC
      if Platform = MacOS then
         return Interfaces.C.int (O_WRONLY + 16#200# + 16#400#);
         --  O_CREAT = 0x200, O_TRUNC = 0x400 on macOS
      else
         return Interfaces.C.int (O_WRONLY + O_CREAT + O_TRUNC);
      end if;
   end Open_Flags;

   procedure Load_Posix_Symbols is
      Lib : DL_Handle;
   begin
      --  dlopen(NULL, RTLD_LAZY) opens the main process image, exposing
      --  all libc symbols that are already linked in.
      Lib := Default_DL_Open (System.Null_Address, 1);

      C_Fork    := To_Fork    (Sym (Lib, "fork"));
      C_Execv   := To_Execv   (Sym (Lib, "execv"));
      C_Waitpid := To_Waitpid (Sym (Lib, "waitpid"));
      C_Exit    := To_Exit    (Sym (Lib, "_exit"));
      C_Dup2    := To_Dup2    (Sym (Lib, "dup2"));
      C_Open    := To_Open    (Sym (Lib, "open"));
      C_Close   := To_Close   (Sym (Lib, "close"));
   end Load_Posix_Symbols;

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
   --  Internal helpers: PATH search (replaces GNAT.OS_Lib.Locate_Exec_On_Path)
   --------------------------------------------------------------------------

   function Resolve_Program
     (Program : String;
      Display : String) return String
   is
      function Has_Slash return Boolean is
      begin
         for C of Program loop
            if C = '/' or else C = '\' then
               return True;
            end if;
         end loop;
         return False;
      end Has_Slash;

      function Probe (Path : String) return Boolean is
         use Ada.Directories;
      begin
         return Exists (Path)
           and then Kind (Path) = Ordinary_File;
      end Probe;

      Separator : constant Character :=
        (if Platform = Windows then ';' else ':');
   begin
      Log ("CMD", Display);

      --  If the program contains a path separator, use it as-is.
      if Has_Slash then
         if Probe (Program) then
            return Program;
         end if;
         Log ("ERRO", "program not found: " & Program);
         raise Build_Error with "program not found: " & Program;
      end if;

      --  Walk PATH directories.
      if Ada.Environment_Variables.Exists ("PATH") then
         declare
            PATH  : constant String :=
              Ada.Environment_Variables.Value ("PATH");
            Start : Positive := PATH'First;
         begin
            for I in PATH'Range loop
               if PATH (I) = Separator then
                  if I > Start then
                     declare
                        Dir  : constant String := PATH (Start .. I - 1);
                        Full : constant String := Dir / Program;
                     begin
                        if Probe (Full) then return Full; end if;
                        if Platform = Windows
                          and then not Ends_With (Program, ".exe")
                        then
                           if Probe (Full & ".exe") then
                              return Full & ".exe";
                           end if;
                        end if;
                     end;
                  end if;
                  Start := I + 1;
               end if;
            end loop;
            --  Last segment (no trailing separator).
            if Start <= PATH'Last then
               declare
                  Dir  : constant String := PATH (Start .. PATH'Last);
                  Full : constant String := Dir / Program;
               begin
                  if Probe (Full) then return Full; end if;
                  if Platform = Windows
                    and then not Ends_With (Program, ".exe")
                  then
                     if Probe (Full & ".exe") then
                        return Full & ".exe";
                     end if;
                  end if;
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
         if A /= null then
            Append (D, " " & A.all);
         end if;
      end loop;
      return To_String (D);
   end Display_Of;

   --------------------------------------------------------------------------
   --  Internal helpers: POSIX process spawn via dlsym'd fork/execv/waitpid
   --------------------------------------------------------------------------

   --  Build a C argv array: null-terminated array of pointers to
   --  null-terminated strings.  Returns a heap-allocated block whose
   --  address can be passed to execv().
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
         if Args (I) /= null then
            Argv (I - Args'First + 1) := New_String (Args (I).all);
         else
            Argv (I - Args'First + 1) := Null_Ptr;
         end if;
      end loop;
      Argv (Args'Length + 1) := Null_Ptr;  --  NULL terminator
      return Argv;
   end Build_Argv;

   procedure Free_Argv (Argv : in out C_Str_Array_Access) is
   begin
      if Argv /= null then
         for I in Argv'Range loop
            Interfaces.C.Strings.Free (Argv (I));
         end loop;
         --  Note: we leak the C_Str_Array block itself; it is small and
         --  short-lived (one allocation per Cmd/Cmd_Async call).
         Argv := null;
      end if;
   end Free_Argv;

   --  Redirect a file descriptor: open a file, dup2 it onto Target_FD,
   --  then close the original.  Called in the child process between fork
   --  and execv.
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
         declare
            Dummy : int;
         begin
            Dummy := C_Close (FD);
         end;
      end if;
   end Redirect_FD;

   --  Extract exit status from the raw waitpid status word.
   --  WIFEXITED(s) = ((s) & 0x7f) == 0
   --  WEXITSTATUS(s) = ((s) >> 8) & 0xff
   function Exit_Status_Of (Status : Interfaces.C.int) return Integer is
      S : constant Integer := Integer (Status);
   begin
      if (S mod 128) = 0 then
         return (S / 256) mod 256;
      else
         return -1;  --  killed by signal
      end if;
   end Exit_Status_Of;

   --  Spawn a child process using fork+execv.  Optionally redirect
   --  stdout (fd 1) and/or stderr (fd 2) to files.
   --  Returns the child PID as a System.Address (for Proc.Pid).
   --  If Wait_For_Exit is True, waits and returns Null_Address; raises
   --  Build_Error on non-zero exit.
   function Posix_Spawn
     (Prog_Path      : String;
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
         declare
            Dummy : int;
         begin
            Dummy := C_Execv (To_Address (C_Path), Argv (0)'Address);
         end;
         --  If execv returns, it failed.
         C_Exit (127);
      end if;

      --  Parent process.
      Free_Argv (Argv);

      if not Wait_For_Exit then
         --  Return the child PID for async tracking.  Pack the int PID into
         --  a pointer-sized Integer_Address first so the conversion to
         --  System.Address is size-safe.
         return System.Storage_Elements.To_Address
                  (System.Storage_Elements.Integer_Address (Pid));
      end if;

      --  Synchronous: wait for child.
      loop
         Waited := C_Waitpid (Pid, Status'Access, 0);
         exit when Waited = Pid or else Waited < 0;
      end loop;

      declare
         Code : constant Integer := Exit_Status_Of (Status);
      begin
         if Code /= 0 then
            Log ("ERRO", "command exited with status" & Code'Image);
            raise Build_Error with "command failed (exit" & Code'Image & ")";
         end if;
      end;

      return System.Null_Address;
   end Posix_Spawn;

   --  Wait for a specific PID.  Returns the exit status.
   function Posix_Wait (Pid_Addr : System.Address) return Integer is
      use Interfaces.C;
      Pid    : constant int :=
        int (System.Storage_Elements.To_Integer (Pid_Addr));
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
   --  Command execution (public API)
   --------------------------------------------------------------------------

   procedure Cmd
     (Program : String;
      Args    : Argument_List;
      Redir   : Redirect)
   is
      Display   : constant String := Display_Of (Program, Args);
      Prog_Path : constant String := Resolve_Program (Program, Display);
      Dummy     : System.Address;
   begin
      Dummy := Posix_Spawn
        (Prog_Path, Args,
         Stdout_File   => Redir.Stdout,
         Stderr_File   => Redir.Stderr,
         Wait_For_Exit => True);
   end Cmd;

   function Cmd_Async
     (Program : String;
      Args    : Argument_List;
      Redir   : Redirect := No_Redirect) return Proc
   is
      Display   : constant String := Display_Of (Program, Args);
      Prog_Path : constant String := Resolve_Program (Program, Display);
      Pid_Addr  : System.Address;
   begin
      Pid_Addr := Posix_Spawn
        (Prog_Path, Args,
         Stdout_File   => Redir.Stdout,
         Stderr_File   => Redir.Stderr,
         Wait_For_Exit => False);
      return (Pid => Pid_Addr);
   end Cmd_Async;

   function Cmd_Async (Program : String) return Proc is
      Empty : constant Argument_List (1 .. 0) := (others => null);
   begin
      return Cmd_Async (Program, Empty);
   end Cmd_Async;

   procedure Wait (P : Proc) is
      Code : constant Integer := Posix_Wait (P.Pid);
   begin
      if Code /= 0 then
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
         if List.Items (I).Pid /= System.Null_Address then
            declare
               Code : constant Integer := Posix_Wait (List.Items (I).Pid);
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

   procedure Set_Compiler (C : Ada_Compiler) is
   begin
      Active_Compiler := C;
   end Set_Compiler;

   procedure Compile_Program
     (Source  : String;
      Output  : String        := "";
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null))
   is
      C        : Ada_Compiler renames Active_Compiler;
      Defaults : constant Argument_List := C.Compile_Flags.all;
   begin
      if Obj_Dir /= "" then
         Make_Dirs (Obj_Dir);
      end if;

      if Output = "" and then Obj_Dir = "" then
         Cmd (C.Executable.all,
              Argument_List'(1 => S (Source)) & Defaults & Extra);
      elsif Output = "" then
         Cmd (C.Executable.all,
              Argument_List'(S (Source), C.Obj_Flag, S (Obj_Dir))
              & Defaults & Extra);
      elsif Obj_Dir = "" then
         Cmd (C.Executable.all,
              Argument_List'(S (Source), C.Out_Flag, S (Output))
              & Defaults & Extra);
      else
         Cmd (C.Executable.all,
              Argument_List'(S (Source),
                             C.Obj_Flag, S (Obj_Dir),
                             C.Out_Flag, S (Output))
              & Defaults & Extra);
      end if;
   end Compile_Program;

   --------------------------------------------------------------------------
   --  Compile (compile-only, no link)
   --------------------------------------------------------------------------

   procedure Compile
     (Source  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null))
   is
   begin
      Compile_Program
        (Source, Obj_Dir => Obj_Dir,
         Extra => Argument_List'(1 => Active_Compiler.Compile_Only_Flag)
                  & Extra);
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
      Flags    : constant Argument_List :=
        (if PIC then Active_Compiler.PIC_Flags.all & Extra else Extra);
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
      C       : Ada_Compiler renames Active_Compiler;
      Objects : Argument_List (1 .. 256) := (others => null);
      N_Obj   : Natural;
   begin
      Build_Lib_Objects (Src_Dir, Obj_Dir, PIC => False,
                         Extra => Extra, Objects => Objects, N_Obj => N_Obj);
      if N_Obj > 0 then
         Cmd (C.Static_Archiver.all,
              C.Static_Archiver_Flags.all
              & Argument_List'(1 => S (Output))
              & Objects (1 .. N_Obj));
      end if;
   end Build_Static_Lib;

   procedure Build_Shared_Lib
     (Src_Dir : String;
      Output  : String;
      Obj_Dir : String        := "";
      Extra   : Argument_List := (1 .. 0 => null))
   is
      C       : Ada_Compiler renames Active_Compiler;
      Objects : Argument_List (1 .. 256) := (others => null);
      N_Obj   : Natural;
   begin
      Build_Lib_Objects (Src_Dir, Obj_Dir, PIC => True,
                         Extra => Extra, Objects => Objects, N_Obj => N_Obj);
      if N_Obj > 0 then
         Cmd (C.Shared_Linker.all,
              C.Shared_Flags.all
              & Argument_List'(C.Shared_Out_Flag, S (Output))
              & Objects (1 .. N_Obj));
      end if;
   end Build_Shared_Lib;

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
   begin
      Log ("RENAME", Old_Path & " -> " & New_Path);
      if Is_Dir (Old_Path) then
         Copy_Dir (Old_Path, New_Path);
         Ada.Directories.Delete_Tree (Old_Path);
      else
         Ada.Directories.Copy_File (Old_Path, New_Path);
         Ada.Directories.Delete_File (Old_Path);
      end if;
   exception
      when Build_Error => raise;
      when others =>
         Log ("ERRO", "could not rename " & Old_Path & " to " & New_Path);
         raise Build_Error with "rename failed: " & Old_Path;
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
            Compile_Program (Source_Path, Output => Binary_Path,
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
            Args : Argument_List (1 .. Ada.Command_Line.Argument_Count);
         begin
            for I in Args'Range loop
               Args (I) := new String'(Ada.Command_Line.Argument (I));
            end loop;
            Info ("re-executing: " & Binary_Path);
            declare
               Dummy : System.Address;
            begin
               Dummy := Posix_Spawn
                 (Binary_Path, Args,
                  Stdout_File   => null,
                  Stderr_File   => null,
                  Wait_For_Exit => True);
            end;
            --  If the re-executed build succeeded, exit this (old) process.
            C_Exit (0);
         end;
      end if;
   end Go_Rebuild_Urself;

begin
   --  Load POSIX process-management symbols at elaboration time.
   --  This runs after Detect_Platform (which initializes the Platform constant
   --  in the spec), so we know which platform we're on.
   if Platform /= Windows then
      Load_Posix_Symbols;
   end if;
end No_Build;
