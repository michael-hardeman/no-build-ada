--  build_tests.adb -- build and run every test_*.adb in tests/.
--
--  Bootstrap (one-time):
--    gnatmake -D tests/obj -I. tests/build_tests.adb -o tests/build_tests
--    ./tests/build_tests
--
--  Subsequent runs use Go_Rebuild_Urself.

with Ada.Environment_Variables;
with Ada.Text_IO;
with No_Build; use No_Build;

procedure Build_Tests is

   Obj    : constant String := "tests/obj";
   Root   : constant String := "tests";
   Report : constant String := Obj / "test_report.txt";

   Pass_Programs, Fail_Programs : Natural := 0;
   Pass_Asserts,  Fail_Asserts  : Natural := 0;

   procedure Read_Report is
      use Ada.Text_IO;
      File   : File_Type;
      Buffer : String (1 .. 32);
      Last   : Natural;
   begin
      Open (File, In_File, Report);
      Get_Line (File, Buffer, Last);
      Pass_Asserts := Pass_Asserts + Natural'Value (Buffer (1 .. Last));
      Get_Line (File, Buffer, Last);
      Fail_Asserts := Fail_Asserts + Natural'Value (Buffer (1 .. Last));
      Close (File);
   exception
      when others =>
         if Is_Open (File) then Close (File); end if;
   end Read_Report;

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

      --  Pre-clear so a missing report means "the test crashed before
      --  reporting" rather than "leftover from a prior run".
      if Path_Exists (Report) then
         Remove_Path (Report);
      end if;

      begin
         Cmd (Bin);
         Pass_Programs := Pass_Programs + 1;
      exception
         when Build_Error =>
            Fail_Programs := Fail_Programs + 1;
      end;

      if Path_Exists (Report) then
         Read_Report;
         Remove_Path (Report);
      end if;
   end Build_And_Run;

begin
   Go_Rebuild_Urself (Binary_Path => "./tests/build_tests",
                      Source_Path => "tests/build_tests.adb",
                      Obj_Dir     => Obj,
                      Extra       => Args ("-I."));

   Ada.Environment_Variables.Set ("NO_BUILD_TEST_REPORT", Report);

   Info ("running test suite...");
   For_Each_File (Root, Build_And_Run'Access, Suffix => ".adb");

   Info ("Tests:" & Pass_Programs'Image & " test programs passed,"
         & Fail_Programs'Image & " failed"
         & " (asserts:" & Pass_Asserts'Image & " passed,"
         & Fail_Asserts'Image & " failed)");

   if Fail_Programs > 0 then
      Panic ("test failures");
   end if;
end Build_Tests;
