--  test_paths.adb -- the path utilities: "/", Base_Name, No_Ext and
--  Ends_With.
--
--  These are pure string operations: they never touch the filesystem and
--  never ask what system they are on, so a path built here is the same
--  text everywhere.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Paths is
   use No_Build;

   Failed : Boolean := False;

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   procedure Check_Join is
   begin
      Check ("a" / "b" = "a/b", "PATH JOIN");
      Check ("" / "b" = "b", "JOIN EMPTY LEFT");
      Check ("a" / "" = "a", "JOIN EMPTY RIGHT");
      Check ("" / "" = "", "JOIN BOTH EMPTY");
      Check ("a" / "b" / "c" = "a/b/c", "JOIN CHAINS");

      --  A separator the left operand already ends with is kept, not
      --  doubled, and whichever separator that is survives.
      Check ("foo/" / "bar" = "foo/bar", "JOIN KEEPS EXISTING SEPARATOR");
      Check ("foo\" / "bar" = "foo\bar", "JOIN KEEPS BACKSLASH");
   end Check_Join;

   procedure Check_Suffixes is
   begin
      Check (Ends_With ("hello.adb", ".adb"), "ENDS_WITH TRUE");
      Check (not Ends_With ("hello.ads", ".adb"), "ENDS_WITH FALSE");
      Check (not Ends_With ("b", ".adb"), "ENDS_WITH SHORTER THAN SUFFIX");
      Check (Ends_With ("x", ""), "ENDS_WITH EMPTY SUFFIX");
      Check (not Ends_With ("", ".adb"), "ENDS_WITH EMPTY STRING");
      Check (Ends_With (".adb", ".adb"), "ENDS_WITH WHOLE STRING");
   end Check_Suffixes;

   procedure Check_Splitting is
   begin
      Check (No_Ext ("dir/file.adb") = "dir/file", "NO_EXT");
      Check (No_Ext ("plain") = "plain", "NO_EXT NO EXTENSION");
      Check (No_Ext ("dir.d/file") = "dir.d/file",
             "NO_EXT IGNORES A DOT IN A DIRECTORY");

      Check (Base_Name ("a/b/c.adb") = "c.adb", "BASE_NAME");
      Check (Base_Name ("plain") = "plain", "BASE_NAME NO DIRECTORY");
      Check (Base_Name ("a/b/") = "", "BASE_NAME TRAILING SEPARATOR");
   end Check_Splitting;

begin
   Check_Join;
   Check_Suffixes;
   Check_Splitting;

   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Paths;
