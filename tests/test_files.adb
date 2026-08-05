--  test_files.adb -- files, directories and the working directory:
--  Path_Exists, Is_Dir, Make_Dir(s), Read_File, Write_File, Copy_File,
--  Rename_Path, Get_Current_Dir and Set_Current_Dir.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Files is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_files";

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   procedure Check_Predicates is
   begin
      Write_File (Root / "probe.txt", "x");
      Make_Dir (Root / "probe_dir");

      Check (Path_Exists (Root / "probe.txt"), "PATH_EXISTS ON A FILE");
      Check (Path_Exists (Root / "probe_dir"), "PATH_EXISTS ON A DIRECTORY");
      Check (not Path_Exists (Root / "absent"), "PATH_EXISTS FALSE");

      Check (Is_Dir (Root / "probe_dir"), "IS_DIR ON A DIRECTORY");
      Check (not Is_Dir (Root / "probe.txt"), "IS_DIR ON A FILE");
      Check (not Is_Dir (Root / "absent"), "IS_DIR ON NOTHING");
   end Check_Predicates;

   procedure Check_Making_Directories is
   begin
      Make_Dir (Root / "sub");
      Check (Is_Dir (Root / "sub"), "MAKE_DIR");

      Make_Dirs (Root / "a" / "b" / "c");
      Check (Is_Dir (Root / "a" / "b" / "c"), "MAKE_DIRS CREATES PARENTS");
      Check (Is_Dir (Root / "a" / "b"), "MAKE_DIRS LEAVES PARENTS BEHIND");

      --  Already there is not an error, only a warning.
      Make_Dirs (Root / "a" / "b" / "c");
      Check (Is_Dir (Root / "a" / "b" / "c"), "MAKE_DIRS IS IDEMPOTENT");
   end Check_Making_Directories;

   procedure Check_Reading_And_Writing is
      Two_Lines : constant String := "line one" & ASCII.LF & "two";
   begin
      Write_File (Root / "data.txt", Two_Lines);
      Check (Read_File (Root / "data.txt") = Two_Lines,
             "WRITE THEN READ ROUND TRIP");

      Write_File (Root / "empty.txt", "");
      Check (Read_File (Root / "empty.txt") = "", "EMPTY FILE ROUND TRIP");

      --  Writing again replaces rather than appends.
      Write_File (Root / "data.txt", "short");
      Check (Read_File (Root / "data.txt") = "short", "WRITE_FILE REPLACES");

      declare
         Nul_Byte : constant String := "a" & ASCII.NUL & "b";
      begin
         Write_File (Root / "binary.bin", Nul_Byte);
         Check (Read_File (Root / "binary.bin") = Nul_Byte,
                "WRITE/READ KEEPS A NUL BYTE");
      end;

      begin
         declare
            Ignored : constant String := Read_File (Root / "absent");
         begin
            Check (False, "READ_FILE MISSING MUST RAISE, GOT " & Ignored);
         end;
      exception
         when Build_Error =>
            null;
      end;
   end Check_Reading_And_Writing;

   procedure Check_Copy_And_Rename is
   begin
      Write_File (Root / "source.txt", "contents");

      Copy_File (Root / "source.txt", Root / "copy.txt");
      Check (Read_File (Root / "copy.txt") = "contents", "COPY_FILE");
      Check (Path_Exists (Root / "source.txt"), "COPY_FILE KEEPS THE SOURCE");

      Write_File (Root / "target.txt", "to be replaced");
      Copy_File (Root / "source.txt", Root / "target.txt");
      Check (Read_File (Root / "target.txt") = "contents",
             "COPY_FILE OVERWRITES");

      Rename_Path (Root / "copy.txt", Root / "renamed.txt");
      Check (Read_File (Root / "renamed.txt") = "contents", "RENAME_PATH");
      Check (not Path_Exists (Root / "copy.txt"),
             "RENAME_PATH LEAVES NOTHING BEHIND");
   end Check_Copy_And_Rename;

   procedure Check_Working_Directory is
      Before : constant String := Get_Current_Dir;
   begin
      Check (Before'Length > 0, "GET_CURRENT_DIR IS NOT EMPTY");

      Set_Current_Dir (Root);
      Check (Ends_With (Get_Current_Dir, Root), "SET_CURRENT_DIR");

      Set_Current_Dir (Before);
      Check (Get_Current_Dir = Before, "WORKING DIRECTORY RESTORED");

      begin
         Set_Current_Dir (Root / "absent");
         Check (False, "SET_CURRENT_DIR MISSING MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
      Check (Get_Current_Dir = Before,
             "A FAILED SET_CURRENT_DIR MOVES NOTHING");
   end Check_Working_Directory;

begin
   Set_Log_Level (Quiet);
   Remove_Path (Root);
   Make_Dir (Root);

   Check_Predicates;
   Check_Making_Directories;
   Check_Reading_And_Writing;
   Check_Copy_And_Rename;
   Check_Working_Directory;

   Remove_Path (Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Files;
