--  build_tests.adb -- build and run every test_*.adb in tests/.
--
--  Bootstrap (one-time):
--    gnatmake -D tests/obj -I. tests/build_tests.adb -o tests/build_tests
--    ./tests/build_tests
--
--  Subsequent runs use Go_Rebuild_Urself.

with No_Build; use No_Build;

procedure Build_Tests is

   Obj   : constant String := "tests/obj";
   Root  : constant String := "tests";

   Pass_Count, Fail_Count : Natural := 0;

   procedure Build_And_Run (Test : String) is
      Bin : constant String := Root / No_Ext (Test);
   begin
      --  Skip the runner itself and the shared support unit (Test_Support
      --  is pulled in transitively via each test's `with` clause).
      if Test = "build_tests.adb" or else Test = "test_support.adb" then
         return;
      end if;

      Compile_Program (Root / Test,
                       Output  => Bin,
                       Obj_Dir => Obj,
                       Extra   => Args ("-I.", "-I" & Root));
      begin
         Cmd (Bin);
         Pass_Count := Pass_Count + 1;
      exception
         when Build_Error =>
            Fail_Count := Fail_Count + 1;
      end;
   end Build_And_Run;

begin
   Go_Rebuild_Urself (Binary_Path => "./tests/build_tests",
                      Source_Path => "tests/build_tests.adb",
                      Obj_Dir     => Obj,
                      Extra       => Args ("-I."));

   Info ("running test suite...");
   For_Each_File (Root, Build_And_Run'Access, Suffix => ".adb");

   Info ("Tests:" & Pass_Count'Image & " test programs passed,"
         & Fail_Count'Image & " failed");

   if Fail_Count > 0 then
      Panic ("test failures");
   end if;
end Build_Tests;
