with No_Build;     use No_Build;
with Test_Support; use Test_Support;

procedure Test_File_IO is
   Path : constant String := "tmp_io.txt";
   Tmp  : Scratch_Path := Scratch (Path);
   pragma Unreferenced (Tmp);
begin
   Begin_Tests ("Read_File / Write_File");

   Write_File (Path, "hello world");
   Assert (Path_Exists (Path), "Write_File created file");
   Assert_Equal (Read_File (Path), "hello world",
                 "Read_File round-trips Write_File");

   --  Empty content.
   Write_File (Path, "");
   Assert_Equal (Read_File (Path), "", "empty content round-trip");

   --  Multi-line content.
   Write_File (Path, "line1" & ASCII.LF & "line2");
   Assert_Equal (Read_File (Path), "line1" & ASCII.LF & "line2",
                 "multi-line round-trip");

   Remove_Path (Path);
   Assert (not Path_Exists (Path), "Remove_Path deleted file");

   End_Tests;
end Test_File_IO;
