--  test_phase3.adb -- exercises the directory layer of the Ada 83 port:
--  the For_Each_File and Walk_Dir generics, Copy_Dir, and Remove_Path.
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Phase3 is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_phase3";

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
   begin
      Seen_Total := Seen_Total + 1;
   end Count_Any;

   procedure Count_Adb (File_Name : String) is
   begin
      Seen_Adb := Seen_Adb + 1;
      if not Ends_With (File_Name, ".adb") then
         Failed := True;
         Text_IO.Put_Line ("FAILED: SUFFIX FILTER LET THROUGH " &
                           File_Name);
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
         Check (E.Path = Root & "/outer/inner/deep.txt",
                "WALK ENTRY PATH");
         Check (E.Depth = 2, "WALK ENTRY DEPTH");
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
         Text_IO.Put_Line ("FAILED: WALK_SKIP DID NOT PRUNE");
      end if;
      return Walk_Continue;
   end Skip_Inner;

   function Stop_Early (E : Walk_Entry) return Walk_Action is
   begin
      Stop_Count := Stop_Count + 1;
      return Walk_Stop;
   end Stop_Early;

   procedure Walk_Note is new Walk_Dir (Note);
   procedure Walk_Skip_Inner is new Walk_Dir (Skip_Inner);
   procedure Walk_Stop_Early is new Walk_Dir (Stop_Early);

begin
   Set_Log_Level (Quiet);
   Sh ("rm -rf " & Root);
   Make_Dirs (Root & "/outer/inner");
   Write_File (Root & "/one.adb", "1");
   Write_File (Root & "/two.adb", "2");
   Write_File (Root & "/three.txt", "3");
   Write_File (Root & "/outer/four.txt", "4");
   Write_File (Root & "/outer/inner/deep.txt", "5");

   Visit_All (Root);
   Check (Seen_Total = 4, "FOR_EACH_FILE VISITS ALL ENTRIES");

   Visit_Adb (Root, ".adb");
   Check (Seen_Adb = 2, "FOR_EACH_FILE SUFFIX FILTER");

   begin
      Visit_All (Root & "/no-such-dir");
      Check (False, "FOR_EACH_FILE MISSING DIR MUST RAISE");
   exception
      when Build_Error =>
         null;
   end;

   Walk_Note (Root);
   Check (Walk_Files = 5, "WALK FILE COUNT");
   Check (Walk_Dirs = 2, "WALK DIR COUNT");
   Check (Max_Depth = 2, "WALK MAX DEPTH");
   Check (Deep_Visited, "WALK REACHES DEEP FILE");

   Walk_Skip_Inner (Root);

   Walk_Stop_Early (Root);
   Check (Stop_Count = 1, "WALK_STOP HALTS IMMEDIATELY");

   Copy_Dir (Root & "/outer", Root & "/outer_copy");
   Check (Read_File (Root & "/outer_copy/inner/deep.txt") = "5",
          "COPY_DIR DEEP FILE");
   Check (Read_File (Root & "/outer_copy/four.txt") = "4",
          "COPY_DIR TOP FILE");

   Remove_Path (Root & "/outer_copy");
   Check (not Path_Exists (Root & "/outer_copy"), "REMOVE_PATH TREE");

   Remove_Path (Root & "/three.txt");
   Check (not Path_Exists (Root & "/three.txt"), "REMOVE_PATH FILE");

   Remove_Path (Root & "/absent");

   Remove_Path (Root);
   Check (not Path_Exists (Root), "REMOVE_PATH ROOT");

   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Phase3;
