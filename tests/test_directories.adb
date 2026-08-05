--  test_directories.adb -- walking a tree: the For_Each_File and
--  Walk_Dir generics, Copy_Dir and Remove_Path.
--
--  Ada 83 has no access-to-subprogram types, so both iterators are
--  generics taking a formal subprogram.  What is checked is the shape of
--  the traversal -- what is visited, in what nesting, and what the two
--  pruning actions do.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Directories is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_directories";

   --  For_Each_File accounting
   Seen_Total : Natural := 0;
   Seen_Adb   : Natural := 0;

   --  Walk_Dir accounting
   Walk_Files   : Natural := 0;
   Walk_Dirs    : Natural := 0;
   Max_Depth    : Natural := 0;
   Deep_Visited : Boolean := False;
   Stop_Count   : Natural := 0;

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   procedure Count_Any (File_Name : String) is
      pragma Unreferenced (File_Name);
   begin
      Seen_Total := Seen_Total + 1;
   end Count_Any;

   procedure Count_Adb (File_Name : String) is
   begin
      Seen_Adb := Seen_Adb + 1;
      if not Ends_With (File_Name, ".adb") then
         Failed := True;
         Text_IO.Put_Line ("FAILED: SUFFIX FILTER LET THROUGH " & File_Name);
      end if;
   end Count_Adb;

   procedure Visit_All is new For_Each_File (Count_Any);
   procedure Visit_Adb is new For_Each_File (Count_Adb);

   function Note (E : Walk_Entry) return Walk_Action is
   begin
      if E.Kind = Regular_File then
         Walk_Files := Walk_Files + 1;
      elsif E.Kind = Directory then
         Walk_Dirs := Walk_Dirs + 1;
      end if;
      if E.Depth > Max_Depth then
         Max_Depth := E.Depth;
      end if;
      if E.Name = "deep.txt" then
         Deep_Visited := True;
         Check (E.Path = Root / "outer" / "inner" / "deep.txt",
                "WALK ENTRY CARRIES THE FULL PATH");
         Check (E.Depth = 2, "WALK ENTRY CARRIES THE DEPTH");
         Check (E.Kind = Regular_File, "WALK ENTRY CARRIES THE KIND");
      end if;
      return Walk_Continue;
   end Note;

   function Skip_Inner (E : Walk_Entry) return Walk_Action is
   begin
      if E.Name = "inner" then
         return Walk_Skip;
      end if;
      if E.Name = "deep.txt" then
         Failed := True;
         Text_IO.Put_Line ("FAILED: WALK_SKIP DID NOT PRUNE THE SUBTREE");
      end if;
      return Walk_Continue;
   end Skip_Inner;

   function Stop_Early (E : Walk_Entry) return Walk_Action is
      pragma Unreferenced (E);
   begin
      Stop_Count := Stop_Count + 1;
      return Walk_Stop;
   end Stop_Early;

   procedure Walk_Note is new Walk_Dir (Note);
   procedure Walk_Skip_Inner is new Walk_Dir (Skip_Inner);
   procedure Walk_Stop_Early is new Walk_Dir (Stop_Early);

   procedure Build_Tree is
   begin
      Make_Dirs (Root / "outer" / "inner");
      Write_File (Root / "one.adb", "1");
      Write_File (Root / "two.adb", "2");
      Write_File (Root / "three.txt", "3");
      Write_File (Root / "outer" / "four.txt", "4");
      Write_File (Root / "outer" / "inner" / "deep.txt", "5");
   end Build_Tree;

   --  For_Each_File is one level deep: the three files directly under
   --  Root, plus the directory outer, and nothing below it.
   procedure Check_For_Each_File is
   begin
      Visit_All (Root);
      Check (Seen_Total = 4, "FOR_EACH_FILE VISITS ONE LEVEL");

      Visit_Adb (Root, ".adb");
      Check (Seen_Adb = 2, "FOR_EACH_FILE SUFFIX FILTER");

      begin
         Visit_All (Root / "no-such-dir");
         Check (False, "FOR_EACH_FILE MISSING DIRECTORY MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
   end Check_For_Each_File;

   procedure Check_Walk_Dir is
   begin
      Walk_Note (Root);
      Check (Walk_Files = 5, "WALK VISITS EVERY FILE");
      Check (Walk_Dirs = 2, "WALK VISITS EVERY DIRECTORY");
      Check (Max_Depth = 2, "WALK REPORTS THE DEEPEST LEVEL");
      Check (Deep_Visited, "WALK REACHES THE DEEPEST FILE");

      Walk_Skip_Inner (Root);

      Walk_Stop_Early (Root);
      Check (Stop_Count = 1, "WALK_STOP HALTS ON THE FIRST ENTRY");
   end Check_Walk_Dir;

   procedure Check_Copy_Dir is
   begin
      Copy_Dir (Root / "outer", Root / "outer_copy");
      Check (Read_File (Root / "outer_copy" / "four.txt") = "4",
             "COPY_DIR COPIES THE TOP LEVEL");
      Check (Read_File (Root / "outer_copy" / "inner" / "deep.txt") = "5",
             "COPY_DIR RECURSES");
   end Check_Copy_Dir;

   procedure Check_Remove_Path is
   begin
      Remove_Path (Root / "outer_copy");
      Check (not Path_Exists (Root / "outer_copy"),
             "REMOVE_PATH DELETES A TREE");

      Remove_Path (Root / "three.txt");
      Check (not Path_Exists (Root / "three.txt"),
             "REMOVE_PATH DELETES A FILE");

      --  Removing what is not there is a no-op, not an error.
      Remove_Path (Root / "absent");
      Check (True, "REMOVE_PATH ON NOTHING IS A NO-OP");

      Remove_Path (Root);
      Check (not Path_Exists (Root), "REMOVE_PATH DELETES THE ROOT");
   end Check_Remove_Path;

begin
   Set_Log_Level (Quiet);
   Remove_Path (Root);
   Build_Tree;

   Check_For_Each_File;
   Check_Walk_Dir;
   Check_Copy_Dir;
   Check_Remove_Path;

   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Directories;
