--  test_platform.adb -- the system calls underneath everything else.
--
--  No_Build holds every system in one body, each with that system's
--  struct offsets, flag values and C symbol names written out, selected
--  by static conditions on System.TARGET_OS.  Get one wrong and nothing
--  raises: stat still returns 0, and the fields simply come out of the
--  wrong bytes.  Is_Dir starts answering at random, every mtime becomes
--  arbitrary, and Is_Newer, Needs_Rebuild and Go_Rebuild_Urself decide
--  on that.
--
--  So the checks here are the ones that read a field and know what must
--  be in it.  Everything is reached through No_Build: the library has no
--  other surface, and a test needing more than it exposes would be
--  testing the wrong thing.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with System;
with No_Build;

procedure Test_Platform is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_platform";

   On_Posix : constant Boolean := System.Target_OS /= System.Windows;

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

   --  Sh reaches the shell through this system's program and flag; a
   --  wrong one fails to spawn rather than reporting a status.
   procedure Check_The_Shell_Runs is
   begin
      if On_Posix then
         Sh ("exit 0");
         begin
            Sh ("exit 3");
            Check (False, "SH MUST REPORT A NONZERO STATUS");
         exception
            when Build_Error =>
               null;
         end;
      else
         Sh ("exit /b 0");
      end if;
      Check (True, "THE SHELL SPAWNS AND ITS STATUS COMES BACK");
   end Check_The_Shell_Runs;

   --  From sysconf on one system and GetSystemInfo on the other; a wrong
   --  selector reads as an absurd value rather than an error.
   procedure Check_Cpu_Count is
   begin
      Check (N_Procs >= 1, "N_PROCS AT LEAST ONE");
      Check (N_Procs <= 4096, "N_PROCS NOT ABSURD");
   end Check_Cpu_Count;

   --  st_mode, dug out of the words stat filled.  A body reading the
   --  wrong offset generally reports one of these two wrongly.
   procedure Check_File_Mode is
   begin
      Write_File (Root / "file.txt", "x");
      Make_Dir (Root / "dir");

      Check (Is_Dir (Root / "dir"), "A DIRECTORY REPORTS AS A DIRECTORY");
      Check (not Is_Dir (Root / "file.txt"),
             "A FILE REPORTS AS NOT A DIRECTORY");
      Check (Path_Exists (Root / "file.txt") and then
             Path_Exists (Root / "dir"),
             "BOTH ARE VISIBLE TO PATH_EXISTS");
      Check (not Is_Dir (Root / "absent"), "NOTHING IS NOT A DIRECTORY");
   end Check_File_Mode;

   --  st_mtime, likewise, and what every rebuild decision rests on.  A
   --  timestamp read from the wrong offset is usually zero or enormous,
   --  so anchoring against a file stamped in 2001 catches both: a zero
   --  loses to it, and an enormous one beats a file written now.
   procedure Check_File_Times is
   begin
      if not On_Posix then
         return;
      end if;

      Sh ("touch -t 200101010000 " & Root & "/ancient.txt");
      Write_File (Root / "recent.txt", "now");

      Check (Is_Newer (Root / "recent.txt", Root / "ancient.txt"),
             "A FILE WRITTEN NOW IS NEWER THAN ONE STAMPED IN 2001");
      Check (not Is_Newer (Root / "ancient.txt", Root / "recent.txt"),
             "THE FILE STAMPED IN 2001 IS NOT THE NEWER OF THE TWO");

      Check (Needs_Rebuild (Root / "ancient.txt",
                            Args (Root / "recent.txt")),
             "A STALE OUTPUT NEEDS REBUILDING");
      Check (not Needs_Rebuild (Root / "recent.txt",
                                Args (Root / "ancient.txt")),
             "A FRESH OUTPUT DOES NOT");
   end Check_File_Times;

   --  d_type, read out of struct dirent at an offset the two POSIX
   --  systems disagree about, or the attribute word of a Win32 find
   --  block.  Walk_Dir classifies from it, so a wrong offset either
   --  loses the recursion or invents one.
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

   procedure Check_Directory_Kinds is
   begin
      Write_File (Root / "dir" / "nested.txt", "y");
      Walk_Classifying (Root);
      Check (Saw_File, "A LISTING REPORTS A FILE AS A FILE");
      Check (Saw_Dir, "A LISTING REPORTS A DIRECTORY AS A DIRECTORY");
      Check (Path_Exists (Root / "dir" / "nested.txt"),
             "THE NESTED FILE IS THERE TO BE REACHED");
   end Check_Directory_Kinds;

   --  Names come out of the bytes after that field, so an offset wrong
   --  by any amount truncates or shifts every one of them.
   procedure Note_Name (File_Name : String) is
   begin
      if File_Name = "file.txt" or else File_Name = "dir" then
         Seen_Exact := Seen_Exact + 1;
      end if;
   end Note_Name;

   procedure Visit is new For_Each_File (Note_Name);

   procedure Check_Directory_Names is
   begin
      Visit (Root);
      Check (Seen_Exact = 2, "DIRECTORY ENTRY NAMES COME BACK INTACT");
   end Check_Directory_Names;

   --  O_CREAT and O_TRUNC differ between the two POSIX systems, and
   --  redirection is the only thing that uses them: a wrong value leaves
   --  the child unable to open its output file.
   procedure Check_Redirect_Open_Flags is
   begin
      if not On_Posix then
         return;
      end if;

      Cmd ("/bin/echo", Args ("created"),
           To_File (Stdout => Root / "fresh.txt"));
      Check (Read_File (Root / "fresh.txt") = "created" & ASCII.LF,
             "REDIRECT CREATES A FILE THAT WAS NOT THERE");

      Write_File (Root / "long.txt", "aaaaaaaaaaaaaaaaaaaaaaaaaaaa");
      Cmd ("/bin/echo", Args ("hi"),
           To_File (Stdout => Root / "long.txt"));
      Check (Read_File (Root / "long.txt") = "hi" & ASCII.LF,
             "REDIRECT TRUNCATES AN EXISTING FILE");
   end Check_Redirect_Open_Flags;

begin
   Set_Log_Level (Quiet);
   Remove_Path (Root);
   Make_Dir (Root);

   Check_The_Shell_Runs;
   Check_Cpu_Count;
   Check_File_Mode;
   Check_File_Times;
   Check_Directory_Kinds;
   Check_Directory_Names;
   Check_Redirect_Open_Flags;

   Remove_Path (Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Platform;
