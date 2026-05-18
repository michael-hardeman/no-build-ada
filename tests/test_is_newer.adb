with No_Build;     use No_Build;
with Test_Support; use Test_Support;

procedure Test_Is_Newer is
   Older_File : constant String := "tmp_newer_older";
   Newer_File : constant String := "tmp_newer_newer";

   Tmp_Older : Scratch_Path := Scratch (Older_File);
   Tmp_Newer : Scratch_Path := Scratch (Newer_File);
   pragma Unreferenced (Tmp_Older, Tmp_Newer);
begin
   Begin_Tests ("Is_Newer / Needs_Rebuild");

   --  Missing first arg => False.
   Assert_Equal (Is_Newer ("does_not_exist", "neither"), False,
                 "Is_Newer (missing, missing) = False");

   --  Create older file.
   Write_File (Older_File, "old");

   --  Missing second arg => True.
   Assert_Equal (Is_Newer (Older_File, "does_not_exist"), True,
                 "Is_Newer (exists, missing) = True");

   --  Two-second delay so mtime granularity (1s on many FSes) is exceeded.
   case Platform is
      when Linux | MacOS => Sh ("sleep 2");
      when Windows       => Sh ("ping -n 3 127.0.0.1 > NUL");
   end case;
   Write_File (Newer_File, "new");

   Assert_Equal (Is_Newer (Newer_File, Older_File), True,
                 "newer file beats older");
   Assert_Equal (Is_Newer (Older_File, Newer_File), False,
                 "older file loses to newer");

   --  Needs_Rebuild: output (Older_File) is older than newer input.
   Assert_Equal (Needs_Rebuild (Older_File, Args (Newer_File)), True,
                 "Needs_Rebuild triggers when input newer");
   Assert_Equal (Needs_Rebuild (Newer_File, Args (Older_File)), False,
                 "Needs_Rebuild False when output already newest");

   End_Tests;
end Test_Is_Newer;
