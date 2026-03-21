--  str_demo.adb -- demonstrate No_Build string/path utilities
--  (equivalent of the original string.c example)

with No_Build; use No_Build;

procedure Str_Demo is

   procedure S (Label, Value : String) is
   begin
      Info ("    " & Label & " == """ & Value & """");
   end S;

   procedure B (Label : String; Value : Boolean) is
   begin
      Info ("    " & Label & " == " & (if Value then "1" else "0"));
   end B;

begin
   S ("""foo"" / ""bar"" / ""baz""",           "foo" / "bar" / "baz");
   S ("No_Ext (""main.adb"")",                 No_Ext ("main.adb"));
   S ("Base_Name (""foo/bar/baz.txt"")",        Base_Name ("foo/bar/baz.txt"));
   B ("Ends_With (""main.adb"",  "".adb"")",   Ends_With ("main.adb",  ".adb"));
   B ("Ends_With (""main.java"", "".adb"")",   Ends_With ("main.java", ".adb"));
   B ("Ends_With ("""",          "".adb"")",   Ends_With ("",          ".adb"));
end Str_Demo;
