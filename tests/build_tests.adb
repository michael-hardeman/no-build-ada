--  build_tests.adb -- build and run every test_*.adb in tests/.
--
--  One program per feature of the library, named for it.  Adding a
--  suite means dropping a test_*.adb in this directory; nothing here
--  lists them.
--
--  Bootstrap (one time only):
--    sh bootstrap_tests.sh
--    ./tests/build_tests
--
--  From then on just run ./tests/build_tests; Go_Rebuild_Urself
--  recompiles it whenever this source changes.
--
--  Each test program prints PASSED, or one FAILED line per broken check,
--  and exits non-zero only if it dies outright -- so a run is judged on
--  what the program printed, not just on its status.

with Text_IO;
with No_Build;

procedure Build_Tests is
   use No_Build;

   Root : constant String := "tests";

   --  The library and the system it sits on, both compiled to modules by
   --  the bootstrap and linked into every test.
   Lib             : constant String := "no_build.ll";

   --  Several suites exercise failure paths on purpose, so a passing run
   --  still writes [ERRO] lines and compiler diagnostics.  Both streams
   --  are captured and shown only when a test actually fails.
   Out_File : constant String := "tests" / "last_run.out";
   Err_File : constant String := "tests" / "last_run.err";

   Passed : Natural := 0;
   Failed : Natural := 0;

   procedure Run_One (Test : String) is
      Bin : constant String := Root / No_Ext (Test);
   begin
      if Test = "build_tests.adb" then
         return;
      end if;

      declare
         Modules : Argument_List;
      begin
         Append (Modules, Lib);
         Compile_Program (Root / Test, Bin, Modules, Args ("-I."));
         Clear (Modules);
      end;

      begin
         Cmd (Bin, No_Args, To_File (Out_File, Err_File));
      exception
         when Build_Error =>
            null;   --  the report below decides; a crash shows up there
      end;

      declare
         Report : constant String := Read_File (Out_File);
         Ok     : Boolean := False;
      begin
         --  A test that neither passed nor reported anything crashed.
         for I in Report'First .. Report'Last - 5 loop
            if Report (I .. I + 5) = "PASSED" then
               Ok := True;
            end if;
         end loop;
         if Ok then
            Passed := Passed + 1;
            Text_IO.Put_Line ("  ok   " & No_Ext (Test));
         else
            Failed := Failed + 1;
            Text_IO.Put_Line ("  FAIL " & No_Ext (Test));
            if Report'Length > 0 then
               Text_IO.Put (Report);
            end if;
            declare
               Errors : constant String := Read_File (Err_File);
            begin
               if Errors'Length > 0 then
                  Text_IO.Put (Errors);
               end if;
            end;
         end if;
      end;
   end Run_One;

   procedure Run_All is new For_Each_File (Run_One);

begin
   Go_Rebuild_Urself ("./tests/build_tests", "tests/build_tests.adb",
                      Args ("-I."));

   Set_Log_Level (Normal);

   Info ("building the library...");
   Compile_Module ("no_build.adb", Lib, Args ("-I."));

   Info ("running the test suite...");
   Run_All (Root, ".adb");

   if Path_Exists (Out_File) then
      Remove_Path (Out_File);
   end if;
   if Path_Exists (Err_File) then
      Remove_Path (Err_File);
   end if;

   Text_IO.Put_Line ("");
   Text_IO.Put_Line ("  " & Natural'Image (Passed + Failed) &
                     " test programs:" & Natural'Image (Passed) &
                     " passed," & Natural'Image (Failed) & " failed");

   if Failed > 0 then
      Panic ("test failures");
   end if;
end Build_Tests;
