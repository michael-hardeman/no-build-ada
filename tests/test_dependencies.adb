--  test_dependencies.adb -- Is_Newer and Needs_Rebuild.
--
--  These two decide whether anything gets built at all, and both rest on
--  file timestamps, which the platform body reads out of a struct at
--  hardcoded offsets.  A body that reads the wrong offsets makes every
--  answer here arbitrary, so this suite is also what catches that.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Dependencies is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_dependencies";

   Older  : constant String := Root / "older.txt";
   Newer  : constant String := Root / "newer.txt";
   Absent : constant String := Root / "absent";

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   --  Two files a measurable moment apart.  The sleep is what makes the
   --  order real rather than a coin toss on a coarse clock.
   procedure Write_Two_Files_In_Order is
   begin
      Write_File (Older, "1");
      Sh ("sleep 0.05");
      Write_File (Newer, "2");
   end Write_Two_Files_In_Order;

   procedure Check_Is_Newer is
   begin
      Check (Is_Newer (Newer, Older), "IS_NEWER TRUE");
      Check (not Is_Newer (Older, Newer), "IS_NEWER FALSE");
      Check (not Is_Newer (Older, Older), "IS_NEWER AGAINST ITSELF");
   end Check_Is_Newer;

   --  A missing file is not an error here: a missing target always needs
   --  building, and a missing source can never be newer than anything.
   procedure Check_Is_Newer_With_Missing_Files is
   begin
      Check (Is_Newer (Newer, Absent), "IS_NEWER WITH NO TARGET");
      Check (not Is_Newer (Absent, Newer), "IS_NEWER WITH NO SOURCE");
      Check (not Is_Newer (Absent, Absent), "IS_NEWER WITH NEITHER");
   end Check_Is_Newer_With_Missing_Files;

   procedure Check_Needs_Rebuild is
   begin
      Check (Needs_Rebuild (Absent, Args (Older)),
             "NEEDS_REBUILD WITH NO OUTPUT");
      Check (Needs_Rebuild (Older, Args (Newer)),
             "NEEDS_REBUILD WITH A STALE OUTPUT");
      Check (not Needs_Rebuild (Newer, Args (Older)),
             "NEEDS_REBUILD WITH A FRESH OUTPUT");
   end Check_Needs_Rebuild;

   --  One stale input out of several is enough, wherever it sits in the
   --  list, and an empty input list never asks for a rebuild.
   procedure Check_Needs_Rebuild_Over_Several_Inputs is
   begin
      Check (not Needs_Rebuild (Newer, Args (Older, Older)),
             "NEEDS_REBUILD WITH ALL INPUTS OLDER");
      Check (Needs_Rebuild (Older, Args (Older, Newer)),
             "NEEDS_REBUILD WITH THE LAST INPUT NEWER");
      Check (Needs_Rebuild (Older, Args (Newer, Older)),
             "NEEDS_REBUILD WITH THE FIRST INPUT NEWER");
      Check (not Needs_Rebuild (Newer, No_Args),
             "NEEDS_REBUILD WITH NO INPUTS");
   end Check_Needs_Rebuild_Over_Several_Inputs;

   --  Rewriting the older file reverses the order.  Timestamps that come
   --  from the wrong offset tend to be constant, so a pair that never
   --  changes relative order is the tell.
   procedure Check_Rewriting_Reverses_The_Order is
   begin
      Sh ("sleep 0.05");
      Write_File (Older, "rewritten");
      Check (Is_Newer (Older, Newer), "REWRITING A FILE MAKES IT NEWER");
      Check (not Is_Newer (Newer, Older),
             "THE FILE IT PASSED IS NOW THE OLDER ONE");
   end Check_Rewriting_Reverses_The_Order;

begin
   Set_Log_Level (Quiet);
   Remove_Path (Root);
   Make_Dir (Root);

   Write_Two_Files_In_Order;
   Check_Is_Newer;
   Check_Is_Newer_With_Missing_Files;
   Check_Needs_Rebuild;
   Check_Needs_Rebuild_Over_Several_Inputs;
   Check_Rewriting_Reverses_The_Order;

   Remove_Path (Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Dependencies;
