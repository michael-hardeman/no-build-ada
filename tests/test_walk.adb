with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with No_Build;     use No_Build;
with Test_Support; use Test_Support;

procedure Test_Walk is

   Root : constant String := "tmp_walk";

   --  Test state shared with the walker callback.
   Visited_Count : Natural := 0;
   Stop_After    : Natural := Natural'Last;
   Skip_Dir      : Unbounded_String := Null_Unbounded_String;

   function Counting_Walker (E : Walk_Entry) return Walk_Action is
   begin
      Visited_Count := Visited_Count + 1;
      if Visited_Count >= Stop_After then
         return Walk_Stop;
      end if;
      if To_String (Skip_Dir) /= ""
        and then E.Kind = Directory
        and then E.Name = To_String (Skip_Dir)
      then
         return Walk_Skip;
      end if;
      return Walk_Continue;
   end Counting_Walker;

   Tmp : Scratch_Path := Scratch (Root);
   pragma Unreferenced (Tmp);
begin
   Begin_Tests ("Walk_Dir");

   Make_Dirs (Root / "a" / "b");
   Make_Dirs (Root / "c");
   Write_File (Root / "top.txt",           "t");
   Write_File (Root / "a" / "mid.txt",     "m");
   Write_File (Root / "a" / "b" / "x.txt", "x");
   Write_File (Root / "c" / "y.txt",       "y");

   --  Full walk: should hit every entry.
   Visited_Count := 0;
   Stop_After    := Natural'Last;
   Skip_Dir      := Null_Unbounded_String;
   Walk_Dir (Root, Counting_Walker'Access);
   Assert (Visited_Count >= 5, "Walk_Dir visited every entry");

   --  Walk_Stop terminates the walk early.
   Visited_Count := 0;
   Stop_After    := 2;
   Skip_Dir      := Null_Unbounded_String;
   Walk_Dir (Root, Counting_Walker'Access);
   Assert_Equal (Visited_Count, 2, "Walk_Stop stops after 2 entries");

   --  Walk_Skip skips a subtree.
   declare
      Full_Count    : Natural;
      Skipped_Count : Natural;
   begin
      Visited_Count := 0;
      Stop_After    := Natural'Last;
      Skip_Dir      := Null_Unbounded_String;
      Walk_Dir (Root, Counting_Walker'Access);
      Full_Count := Visited_Count;

      Visited_Count := 0;
      Skip_Dir      := To_Unbounded_String ("a");
      Walk_Dir (Root, Counting_Walker'Access);
      Skipped_Count := Visited_Count;

      Assert (Skipped_Count < Full_Count,
              "Walk_Skip on 'a' reduces visit count");
   end;

   End_Tests;
end Test_Walk;
