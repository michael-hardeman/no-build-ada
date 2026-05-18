with No_Build;     use No_Build;
with Test_Support; use Test_Support;

procedure Test_Capture is
begin
   Begin_Tests ("Capture");

   case Platform is
      when Linux | MacOS =>
         declare
            Out_Str : constant String :=
              Capture ("/bin/sh", Args ("-c", "echo hello"));
         begin
            Assert_Equal (Out_Str, "hello", "Capture trims trailing newline");
         end;

         declare
            Out_Str : constant String :=
              Capture ("/bin/sh", Args ("-c", "echo '  spaced  '"));
         begin
            Assert_Equal (Out_Str, "spaced",
                          "Capture trims both ends of whitespace");
         end;

      when Windows =>
         declare
            Out_Str : constant String :=
              Capture ("cmd.exe", Args ("/c", "echo hello"));
         begin
            Assert_Equal (Out_Str, "hello", "Capture trims trailing CRLF");
         end;
   end case;

   End_Tests;
end Test_Capture;
