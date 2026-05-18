with No_Build;     use No_Build;
with Test_Support; use Test_Support;

procedure Test_Paths is
begin
   Begin_Tests ("path utilities");

   --  "/"
   Assert_Equal ("foo" / "bar",
                 (if Platform = Windows then "foo\bar" else "foo/bar"),
                 """foo"" / ""bar""");
   Assert_Equal ("" / "bar", "bar", """"" / ""bar""");
   Assert_Equal ("foo/" / "bar", "foo/bar",
                 """foo/"" / ""bar"" preserves separator");
   Assert_Equal ("foo\" / "bar", "foo\bar",
                 """foo\\"" / ""bar"" preserves separator");

   --  No_Ext
   Assert_Equal (No_Ext ("main.adb"),       "main",        "No_Ext basic");
   Assert_Equal (No_Ext ("no_ext_here"),    "no_ext_here", "No_Ext no extension");
   Assert_Equal (No_Ext ("a/b/c.txt"),      "a/b/c",       "No_Ext with path");
   Assert_Equal (No_Ext ("dir.with.dot/f"), "dir.with.dot/f",
                 "No_Ext stops at path separator");

   --  Ends_With
   Assert_Equal (Ends_With ("main.adb",  ".adb"), True,  "Ends_With matches");
   Assert_Equal (Ends_With ("main.java", ".adb"), False, "Ends_With no match");
   Assert_Equal (Ends_With ("",          ".adb"), False, "Ends_With empty str");
   Assert_Equal (Ends_With ("x", ""), True,
                 "Ends_With empty suffix always matches");
   Assert_Equal (Ends_With ("ab", "abc"), False,
                 "Ends_With suffix longer than str");

   --  Base_Name
   Assert_Equal (Base_Name ("foo/bar/baz.txt"), "baz.txt", "Base_Name posix");
   Assert_Equal (Base_Name ("baz.txt"),         "baz.txt", "Base_Name flat");
   Assert_Equal (Base_Name ("a\b\c"),           "c",       "Base_Name windows");

   End_Tests;
end Test_Paths;
