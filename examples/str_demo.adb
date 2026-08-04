--  str_demo.adb -- demonstrate No_Build string/path utilities

with No_Build;

procedure Str_Demo is
   use No_Build;

   procedure S (Label, Value : String) is
   begin
      Info ("    " & Label & " == """ & Value & """");
   end S;

   procedure B (Label : String; Value : Boolean) is
   begin
      if Value then
         Info ("    " & Label & " == 1");
      else
         Info ("    " & Label & " == 0");
      end if;
   end B;

begin
   S ("""foo"" / ""bar"" / ""baz""",           "foo" / "bar" / "baz");
   S ("No_Ext (""main.adb"")",                 No_Ext ("main.adb"));
   S ("Base_Name (""foo/bar/baz.txt"")",       Base_Name ("foo/bar/baz.txt"));
   B ("Ends_With (""main.adb"",  "".adb"")",   Ends_With ("main.adb",  ".adb"));
   B ("Ends_With (""main.java"", "".adb"")",   Ends_With ("main.java", ".adb"));
   B ("Ends_With ("""",          "".adb"")",   Ends_With ("",          ".adb"));
end Str_Demo;
