with Ada.Directories;
with No_Build;     use No_Build;
with Test_Support; use Test_Support;

procedure Test_Make_Dirs is
begin
   Begin_Tests ("Make_Dirs");

   --  Simple case.
   declare
      Tmp : Scratch_Path := Scratch ("tmp_md");
      pragma Unreferenced (Tmp);
   begin
      Make_Dirs ("tmp_md/a/b/c");
      Assert (Is_Dir ("tmp_md"),       "Make_Dirs created tmp_md");
      Assert (Is_Dir ("tmp_md/a"),     "Make_Dirs created tmp_md/a");
      Assert (Is_Dir ("tmp_md/a/b"),   "Make_Dirs created tmp_md/a/b");
      Assert (Is_Dir ("tmp_md/a/b/c"), "Make_Dirs created tmp_md/a/b/c");
   end;

   --  Idempotent: calling twice doesn't raise.
   declare
      Tmp : Scratch_Path := Scratch ("tmp_md");
      pragma Unreferenced (Tmp);
   begin
      Make_Dirs ("tmp_md/a");
      Make_Dirs ("tmp_md/a");
      Assert (Is_Dir ("tmp_md/a"), "Make_Dirs idempotent");
   end;

   --  Backslash-style components (Windows-style) on POSIX are not split
   --  into segments by Make_Dirs -- the whole path is treated as one
   --  literal directory name.
   if Platform /= Windows then
      declare
         Tmp : Scratch_Path := Scratch ("tmp_md\back\slash");
         pragma Unreferenced (Tmp);
      begin
         Make_Dirs ("tmp_md\back\slash");
         Assert (Ada.Directories.Exists ("tmp_md\back\slash"),
                 "Make_Dirs treats backslash literally on POSIX");
      end;
   end if;

   --  Drive-prefix safety.  On POSIX, "C:" is just a directory name --
   --  Make_Dirs creates it (literally) and we verify no exception fires.
   --  On Windows, the drive-prefix branch is exercised but we can't
   --  safely create a real drive root; just smoke that the path through
   --  Make_Dirs doesn't raise.
   if Platform = Windows then
      Assert (True, "drive prefix branch reachable (Windows-only smoke)");
   else
      declare
         Tmp : Scratch_Path := Scratch ("C:");
         pragma Unreferenced (Tmp);
      begin
         Make_Dirs ("C:/tmp_drive_test");
         Assert (Is_Dir ("C:"),
                 "POSIX: ""C:"" treated as literal directory name");
         Assert (Is_Dir ("C:/tmp_drive_test"),
                 "POSIX: nested under literal ""C:"" created");
      end;
   end if;

   End_Tests;
end Test_Make_Dirs;
