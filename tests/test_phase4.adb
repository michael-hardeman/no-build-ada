--  test_phase4.adb -- exercises the compile layer of the Ada 83 port:
--  Set_Compiler/Compiler, Compile_Module, Compile_Program, and
--  Go_Rebuild_Urself.  Prints PASSED, or one FAILED line per broken check.
--
--  Needs ada83 on PATH, or ADA83 naming it; the harness passes the
--  compiler under test as the first argument.

with Text_IO;
with Command_Line;
with No_Build;

procedure Test_Phase4 is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_phase4";

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
      Write_File (Root & "/greet.ada",
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

      Write_File (Root & "/hello.ada",
        "with Text_IO;" & ASCII.LF &
        "with Greet;" & ASCII.LF &
        "procedure Hello is" & ASCII.LF &
        "begin" & ASCII.LF &
        "   Text_IO.Put_Line (Greet.Message);" & ASCII.LF &
        "end Hello;" & ASCII.LF);

      Write_File (Root & "/broken.ada",
        "procedure Broken is" & ASCII.LF &
        "begin" & ASCII.LF &
        "   Undefined_Thing;" & ASCII.LF &
        "end Broken;" & ASCII.LF);
   end Write_Sources;

   procedure Check_Compiler_Selection is
   begin
      Check (Compiler = "ada83", "DEFAULT COMPILER IS ada83");
      Set_Compiler ("/nonexistent/ada83");
      Check (Compiler = "/nonexistent/ada83", "SET_COMPILER TAKES EFFECT");
      if Command_Line.Argument_Count >= 1 then
         Set_Compiler (Command_Line.Argument (1));
      else
         Set_Compiler ("ada83");
      end if;
   end Check_Compiler_Selection;

   procedure Check_Compilation is
   begin
      Compile_Module (Root & "/greet.ada", Root & "/greet.ll");
      Check (Path_Exists (Root & "/greet.ll"), "COMPILE_MODULE WRITES IR");

      Compile_Program (Root & "/hello.ada", Root & "/hello",
                       Args (Root & "/greet.ll"));
      Check (Path_Exists (Root & "/hello"), "COMPILE_PROGRAM LINKS MODULE");
      Check (Capture (Root & "/hello") = "from a module",
             "COMPILED PROGRAM RUNS");
   end Check_Compilation;

   procedure Check_Failure_Paths is
   begin
      begin
         Compile_Program (Root & "/broken.ada", Root & "/broken");
         Check (False, "COMPILE ERROR MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;

      begin
         Compile_Module (Root & "/no-such-source.ada", Root & "/x.ll");
         Check (False, "MISSING SOURCE MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
   end Check_Failure_Paths;

   procedure Check_Extra_Flags is
   begin
      --  -O0 is accepted by ada83 and changes nothing observable here;
      --  a bad flag proves Extra reaches the command line at all.
      Compile_Program (Root & "/hello.ada", Root & "/hello_o0",
                       Args (Root & "/greet.ll"), Args ("-O0"));
      Check (Path_Exists (Root & "/hello_o0"), "EXTRA FLAGS ACCEPTED");

      begin
         Compile_Program (Root & "/hello.ada", Root & "/hello_bad",
                          Args (Root & "/greet.ll"),
                          Args ("--definitely-not-a-flag"));
         Check (False, "BAD EXTRA FLAG MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
   end Check_Extra_Flags;

   procedure Check_Go_Rebuild_Urself is
   begin
      --  The binary is newer than the source, so this must return rather
      --  than rebuild and re-exec -- if it re-execs, the test never
      --  reaches its final PASSED line.
      Go_Rebuild_Urself (Root & "/hello", Root & "/hello.ada");
      Check (True, "GO_REBUILD_URSELF RETURNS WHEN UP TO DATE");

      --  A source that does not exist is a no-op, not an error.
      Go_Rebuild_Urself (Root & "/hello", Root & "/absent.ada");
   end Check_Go_Rebuild_Urself;

begin
   Set_Log_Level (Quiet);
   Sh ("rm -rf " & Root);
   Make_Dir (Root);

   Check_Compiler_Selection;
   Write_Sources;
   Check_Compilation;
   Check_Failure_Paths;
   Check_Extra_Flags;
   Check_Go_Rebuild_Urself;

   Sh ("rm -rf " & Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Phase4;
