--  test_compiling.adb -- Compile_Module and Compile_Program.
--
--  ada83 has no object or archive stage, so a library here is an .ll
--  module that dependent programs link alongside their own source.  Both
--  halves of that are checked: writing a module, and linking one.
--
--  Needs ada83 on PATH, since that is the compiler No_Build runs.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Compiling is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_compiling";

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   procedure Write_Sources is
   begin
      Write_File (Root / "greet.ada",
        "package Greet is" & ASCII.LF &
        "   function Message return String;" & ASCII.LF &
        "end Greet;" & ASCII.LF &
        ASCII.LF &
        "package body Greet is" & ASCII.LF &
        "   function Message return String is" & ASCII.LF &
        "   begin" & ASCII.LF &
        "      return ""from a module"";" & ASCII.LF &
        "   end Message;" & ASCII.LF &
        "end Greet;" & ASCII.LF);

      Write_File (Root / "hello.ada",
        "with Text_IO;" & ASCII.LF &
        "with Greet;" & ASCII.LF &
        "procedure Hello is" & ASCII.LF &
        "begin" & ASCII.LF &
        "   Text_IO.Put_Line (Greet.Message);" & ASCII.LF &
        "end Hello;" & ASCII.LF);

      Write_File (Root / "broken.ada",
        "procedure Broken is" & ASCII.LF &
        "begin" & ASCII.LF &
        "   Undefined_Thing;" & ASCII.LF &
        "end Broken;" & ASCII.LF);
   end Write_Sources;

   procedure Check_Compile_Module is
   begin
      Compile_Module (Root / "greet.ada", Root / "greet.ll");
      Check (Path_Exists (Root / "greet.ll"), "COMPILE_MODULE WRITES IR");
   end Check_Compile_Module;

   procedure Check_Compile_Program is
   begin
      Compile_Program (Root / "hello.ada", Root / "hello",
                       Args (Root / "greet.ll"));
      Check (Path_Exists (Root / "hello"), "COMPILE_PROGRAM LINKS A MODULE");
      Check (Capture (Root / "hello") = "from a module",
             "THE COMPILED PROGRAM RUNS");
   end Check_Compile_Program;

   procedure Check_Failure_Paths is
   begin
      begin
         Compile_Program (Root / "broken.ada", Root / "broken");
         Check (False, "A COMPILE ERROR MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
      Check (not Path_Exists (Root / "broken"),
             "A FAILED COMPILE LEAVES NO BINARY");

      begin
         Compile_Module (Root / "no-such-source.ada", Root / "x.ll");
         Check (False, "A MISSING SOURCE MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
   end Check_Failure_Paths;

   procedure Check_Extra_Flags is
   begin
      --  -O0 is accepted by ada83 and changes nothing observable here;
      --  a bad flag proves Extra reaches the command line at all.
      Compile_Program (Root / "hello.ada", Root / "hello_o0",
                       Args (Root / "greet.ll"), Args ("-O0"));
      Check (Path_Exists (Root / "hello_o0"), "EXTRA FLAGS ARE ACCEPTED");

      begin
         Compile_Program (Root / "hello.ada", Root / "hello_bad",
                          Args (Root / "greet.ll"),
                          Args ("--definitely-not-a-flag"));
         Check (False, "A BAD EXTRA FLAG MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
   end Check_Extra_Flags;

begin
   Set_Log_Level (Quiet);
   Remove_Path (Root);
   Make_Dir (Root);

   Write_Sources;
   Check_Compile_Module;
   Check_Compile_Program;
   Check_Failure_Paths;
   Check_Extra_Flags;

   Remove_Path (Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Compiling;
