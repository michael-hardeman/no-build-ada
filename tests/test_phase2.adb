--  test_phase2.adb -- exercises the POSIX OS layer of the Ada 83 port:
--  Cmd, Sh, Capture, Cmd_Async/Wait/Wait_All, N_Procs, file IO,
--  filesystem predicates and mutations, cwd, and dependency checks.
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Phase2 is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_phase2";

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   procedure Check_Processes is
      P1, P2 : Proc;
      Batch  : Proc_List;
   begin
      Cmd ("/bin/true");
      begin
         Cmd ("/bin/false");
         Check (False, "CMD NONZERO MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
      begin
         Cmd ("definitely-not-a-real-program-42");
         Check (False, "CMD MISSING PROGRAM MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;

      Check (Capture ("/bin/echo", Args ("captured")) = "captured",
             "CAPTURE ECHO");
      Check (Capture ("/bin/echo", Args ("  padded  ")) = "padded",
             "CAPTURE TRIMS");

      Sh ("exit 0");
      begin
         Sh ("exit 3");
         Check (False, "SH NONZERO MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;

      P1 := Cmd_Async ("/bin/sleep", Args ("0.2"));
      P2 := Cmd_Async ("/bin/sleep", Args ("0.2"));
      Wait (P1);
      Wait (P2);

      Append (Batch, Cmd_Async ("/bin/true"));
      Append (Batch, Cmd_Async ("/bin/true"));
      Wait_All (Batch);

      Append (Batch, Cmd_Async ("/bin/false"));
      begin
         Wait_All (Batch);
         Check (False, "WAIT_ALL FAILURE MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;

      Check (N_Procs >= 1, "N_PROCS POSITIVE");
   end Check_Processes;

   procedure Check_Redirect is
   begin
      Cmd ("/bin/echo", Args ("into-file"),
           To_File (Stdout => Root & "/redir.txt"));
      Check (Read_File (Root & "/redir.txt") = "into-file" & ASCII.LF,
             "REDIRECT STDOUT TO FILE");
   end Check_Redirect;

   procedure Check_Filesystem is
   begin
      Check (Path_Exists ("/bin/echo"), "PATH_EXISTS TRUE");
      Check (not Path_Exists (Root & "/absent"), "PATH_EXISTS FALSE");
      Check (Is_Dir ("/tmp"), "IS_DIR TRUE");
      Check (not Is_Dir ("/bin/echo"), "IS_DIR ON FILE");

      Make_Dir (Root & "/sub");
      Check (Is_Dir (Root & "/sub"), "MAKE_DIR");

      Make_Dirs (Root & "/a/b/c");
      Check (Is_Dir (Root & "/a/b/c"), "MAKE_DIRS");

      Write_File (Root & "/data.txt", "line one" & ASCII.LF & "two");
      Check (Read_File (Root & "/data.txt") =
               "line one" & ASCII.LF & "two",
             "WRITE/READ ROUND TRIP");

      Write_File (Root & "/empty.txt", "");
      Check (Read_File (Root & "/empty.txt") = "", "EMPTY FILE");

      Copy_File (Root & "/data.txt", Root & "/data2.txt");
      Check (Read_File (Root & "/data2.txt") =
               Read_File (Root & "/data.txt"),
             "COPY_FILE");

      Rename_Path (Root & "/data2.txt", Root & "/renamed.txt");
      Check (Path_Exists (Root & "/renamed.txt") and then
             not Path_Exists (Root & "/data2.txt"),
             "RENAME_PATH");
   end Check_Filesystem;

   procedure Check_Cwd is
      Before : constant String := Get_Current_Dir;
   begin
      Check (Before'Length > 0, "GET_CURRENT_DIR NONEMPTY");
      Set_Current_Dir (Root);
      Check (Ends_With (Get_Current_Dir, Root), "SET_CURRENT_DIR");
      Set_Current_Dir (Before);
      Check (Get_Current_Dir = Before, "CWD RESTORED");
   end Check_Cwd;

   procedure Check_Dependencies is
   begin
      Write_File (Root & "/older.txt", "1");
      Sh ("sleep 0.05");
      Write_File (Root & "/newer.txt", "2");

      Check (Is_Newer (Root & "/newer.txt", Root & "/older.txt"),
             "IS_NEWER TRUE");
      Check (not Is_Newer (Root & "/older.txt", Root & "/newer.txt"),
             "IS_NEWER FALSE");
      Check (Is_Newer (Root & "/newer.txt", Root & "/absent"),
             "IS_NEWER MISSING TARGET");
      Check (not Is_Newer (Root & "/absent", Root & "/newer.txt"),
             "IS_NEWER MISSING SOURCE");

      Check (Needs_Rebuild (Root & "/absent",
                            Args (Root & "/older.txt")),
             "NEEDS_REBUILD MISSING OUTPUT");
      Check (Needs_Rebuild (Root & "/older.txt",
                            Args (Root & "/newer.txt")),
             "NEEDS_REBUILD STALE OUTPUT");
      Check (not Needs_Rebuild (Root & "/newer.txt",
                                Args (Root & "/older.txt")),
             "NEEDS_REBUILD FRESH OUTPUT");
   end Check_Dependencies;

begin
   Set_Log_Level (Quiet);
   Sh ("rm -rf " & Root);
   Make_Dir (Root);

   Check_Processes;
   Check_Redirect;
   Check_Filesystem;
   Check_Cwd;
   Check_Dependencies;

   Sh ("rm -rf " & Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Phase2;
