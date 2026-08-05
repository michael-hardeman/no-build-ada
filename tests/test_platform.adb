--  test_platform.adb -- the per-system body underneath everything else.
--
--  Platform_Support has one body per system, each carrying that system's
--  struct offsets, flag values and C symbol names as literals.  Get one
--  wrong and nothing raises: stat still returns 0, and the fields simply
--  come out of the wrong bytes.  Is_Dir starts answering at random, every
--  mtime becomes arbitrary, and Is_Newer, Needs_Rebuild and
--  Go_Rebuild_Urself decide on that.
--
--  So the checks here are the ones that read a field and know what must
--  be in it.  They go through Platform_Support directly where No_Build
--  does not expose the value.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;
with Platform_Support;

procedure Test_Platform is
   use No_Build;

   package OS renames Platform_Support;

   Failed : Boolean := False;
   Root   : constant String := "tmp_platform";

   --  Ada 83 has no "use type", and Platform_Support cannot be used
   --  wholesale here: its Linux, MacOS and Windows would clash with the
   --  Platform_Kind literals.  Renaming brings in just the operators the
   --  timestamp checks need.
   function ">"  (L, R : OS.Long) return Boolean renames OS.">";
   function ">=" (L, R : OS.Long) return Boolean renames OS.">=";
   function "<"  (L, R : OS.Long) return Boolean renames OS."<";

   --  Walk_Dir accounting, declared here because Ada 83 wants every
   --  basic declaration ahead of the first body.
   Saw_File   : Boolean := False;
   Saw_Dir    : Boolean := False;
   Seen_Exact : Natural := 0;

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   --  Which body was compiled in.  Nothing is probed at run time, so
   --  these must simply agree with each other.
   procedure Check_Platform_Agrees_With_Its_Directory is
      Dir : constant String := Platform_Dir;
   begin
      Check (Dir'Length > 0, "PLATFORM_DIR IS NOT EMPTY");
      Check (Platform = Platform, "PLATFORM IS STABLE");

      case Platform is
         when Linux =>
            Check (Dir = "linux", "LINUX NAMES THE LINUX BODY");
         when MacOS =>
            Check (Dir = "macos-arm64" or else Dir = "macos-x86_64",
                   "MACOS NAMES ONE OF THE MACOS BODIES");
         when Windows =>
            Check (Dir = "windows", "WINDOWS NAMES THE WINDOWS BODY");
      end case;

      --  Run from the project root, so the directory it names is there.
      Check (Path_Exists (Dir / "platform_support.adb"),
             "PLATFORM_DIR HOLDS A PLATFORM_SUPPORT BODY");
   end Check_Platform_Agrees_With_Its_Directory;

   procedure Check_System_Conventions is
   begin
      case Platform is
         when Linux | MacOS =>
            Check (OS.Path_Separator = '/', "POSIX PATH SEPARATOR");
            Check (OS.Shell_Program = "/bin/sh", "POSIX SHELL");
            Check (OS.Shell_Flag = "-c", "POSIX SHELL FLAG");
         when Windows =>
            Check (OS.Path_Separator = '\', "WINDOWS PATH SEPARATOR");
            Check (OS.Shell_Program = "cmd.exe", "WINDOWS SHELL");
            Check (OS.Shell_Flag = "/c", "WINDOWS SHELL FLAG");
      end case;
   end Check_System_Conventions;

   --  Both come from a system call whose result is read as a plain
   --  integer, so a wrong selector shows up as an absurd value rather
   --  than an error.
   procedure Check_Machine_Facts is
   begin
      Check (OS.Cpu_Count >= 1, "CPU_COUNT AT LEAST ONE");
      Check (OS.Cpu_Count <= 4096, "CPU_COUNT NOT ABSURD");
      Check (OS.Process_Id > 0, "PROCESS_ID POSITIVE");
   end Check_Machine_Facts;

   --  st_mode, read out of the words stat filled.  A body reading the
   --  wrong offset generally reports one of these two wrongly.
   procedure Check_Stat_Mode is
   begin
      Write_File (Root / "file.txt", "x");
      Make_Dir (Root / "dir");

      Check (Is_Dir (Root / "dir"), "STAT REPORTS A DIRECTORY AS ONE");
      Check (not Is_Dir (Root / "file.txt"),
             "STAT REPORTS A FILE AS NOT A DIRECTORY");
      Check (Path_Exists (Root / "file.txt") and then
             Path_Exists (Root / "dir"),
             "BOTH ARE VISIBLE TO EXISTS");
   end Check_Stat_Mode;

   --  st_mtime, likewise.  A timestamp from the wrong offset is usually
   --  either zero or enormous, and it is what every rebuild decision
   --  rests on.
   procedure Check_Stat_Mtime is
      Found      : Boolean;
      Directory  : Boolean;
      Sec, Nsec  : OS.Long;

      --  2001-09-09, comfortably before any machine running this and
      --  well clear of a zero or a garbage low word.
      Long_Ago : constant OS.Long := 1_000_000_000;
   begin
      OS.File_Status (Root / "file.txt", Found, Directory, Sec, Nsec);
      Check (Found, "FILE_STATUS FINDS THE FILE");
      Check (not Directory, "FILE_STATUS AGREES THE FILE IS NOT A DIRECTORY");
      Check (Sec > Long_Ago, "MTIME IS AFTER 2001");
      Check (Nsec >= 0 and then Nsec < 1_000_000_000,
             "MTIME NANOSECONDS IN RANGE");

      OS.File_Status (Root / "dir", Found, Directory, Sec, Nsec);
      Check (Found, "FILE_STATUS FINDS THE DIRECTORY");
      Check (Directory, "FILE_STATUS AGREES THE DIRECTORY IS ONE");
      Check (Sec > Long_Ago, "DIRECTORY MTIME IS AFTER 2001");

      OS.File_Status (Root / "absent", Found, Directory, Sec, Nsec);
      Check (not Found, "FILE_STATUS REPORTS WHAT IS NOT THERE");
   end Check_Stat_Mtime;

   --  d_type, read out of struct dirent at an offset the two POSIX
   --  systems disagree about.  Walk_Dir classifies from it, so a wrong
   --  offset either loses the recursion or invents one.
   function Classify (E : Walk_Entry) return Walk_Action is
   begin
      if E.Name = "file.txt" and then E.Kind = Regular_File then
         Saw_File := True;
      end if;
      if E.Name = "dir" and then E.Kind = Directory then
         Saw_Dir := True;
      end if;
      return Walk_Continue;
   end Classify;

   procedure Walk_Classifying is new Walk_Dir (Classify);

   procedure Check_Dirent_Kinds is
   begin
      Write_File (Root / "dir" / "nested.txt", "y");
      Walk_Classifying (Root);
      Check (Saw_File, "A DIRECTORY LISTING REPORTS A FILE AS A FILE");
      Check (Saw_Dir, "A DIRECTORY LISTING REPORTS A DIRECTORY AS ONE");

      --  Recursion only happens when the entry was classified as a
      --  directory, so reaching this file proves it was.
      Check (Path_Exists (Root / "dir" / "nested.txt"),
             "THE NESTED FILE IS THERE TO BE REACHED");
   end Check_Dirent_Kinds;

   --  Names come out of the bytes after d_type, so an offset that is
   --  wrong by any amount truncates or shifts every one of them.
   procedure Note_Name (File_Name : String) is
   begin
      if File_Name = "file.txt" or else File_Name = "dir" then
         Seen_Exact := Seen_Exact + 1;
      end if;
   end Note_Name;

   procedure Visit is new For_Each_File (Note_Name);

   procedure Check_Dirent_Names is
   begin
      Visit (Root);
      Check (Seen_Exact = 2, "DIRECTORY ENTRY NAMES COME BACK INTACT");
   end Check_Dirent_Names;

   --  O_CREAT and O_TRUNC differ between the two POSIX systems, and the
   --  redirect path is the only thing that uses them: a wrong value
   --  leaves the child unable to open its output file.
   procedure Check_Redirect_Open_Flags is
   begin
      case Platform is
         when Linux | MacOS =>
            Cmd ("/bin/echo", Args ("created"),
                 To_File (Stdout => Root / "fresh.txt"));
            Check (Read_File (Root / "fresh.txt") = "created" & ASCII.LF,
                   "REDIRECT CREATES A FILE THAT WAS NOT THERE");

            Write_File (Root / "long.txt", "aaaaaaaaaaaaaaaaaaaaaaaaaaaa");
            Cmd ("/bin/echo", Args ("hi"),
                 To_File (Stdout => Root / "long.txt"));
            Check (Read_File (Root / "long.txt") = "hi" & ASCII.LF,
                   "REDIRECT TRUNCATES AN EXISTING FILE");
         when Windows =>
            null;
      end case;
   end Check_Redirect_Open_Flags;

begin
   Set_Log_Level (Quiet);
   Remove_Path (Root);
   Make_Dir (Root);

   Check_Platform_Agrees_With_Its_Directory;
   Check_System_Conventions;
   Check_Machine_Facts;
   Check_Stat_Mode;
   Check_Stat_Mtime;
   Check_Dirent_Kinds;
   Check_Dirent_Names;
   Check_Redirect_Open_Flags;

   Remove_Path (Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Platform;
