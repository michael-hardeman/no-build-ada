--  test_phase4.adb -- exercises the compile layer of the Ada 83 port:
--  Compile_Module, Compile_Program and Go_Rebuild_Urself.  Prints PASSED,
--  or one FAILED line per broken check.
--
--  Needs ada83 on PATH, since that is the compiler No_Build runs.

with Text_IO;
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

   --  The rebuild itself cannot be run in this process: it re-execs and
   --  never returns.  Build a second No_Build program that calls it, make
   --  its source newer than its binary, and let it rebuild and re-exec
   --  itself.  The marker the re-executed program writes is the one only
   --  the second source spells, so reading it back proves the rebuild
   --  linked -- which it can only do if Go_Rebuild_Urself carried the
   --  library module and this host's Platform_Support body forward.
   procedure Write_Self_Builder (Marker : String) is
   begin
      Write_File (Root & "/selfbuild.ada",
        "with No_Build;" & ASCII.LF &
        "procedure Selfbuild is" & ASCII.LF &
        "   use No_Build;" & ASCII.LF &
        "begin" & ASCII.LF &
        "   Set_Log_Level (Silent);" & ASCII.LF &
        "   Go_Rebuild_Urself (""" & Root & "/selfbuild"", """ &
                               Root & "/selfbuild.ada"");" & ASCII.LF &
        "   Write_File (""" & Root & "/marker"", """ & Marker & """);" &
                               ASCII.LF &
        "end Selfbuild;" & ASCII.LF);
   end Write_Self_Builder;

   procedure Check_Rebuild_Carries_The_Host is
      Modules : Argument_List;
   begin
      Append (Modules, "no_build.ll");
      if Path_Exists ("platform_support.ll") then
         Append (Modules, "platform_support.ll");
      end if;

      Write_Self_Builder ("first");
      Compile_Program (Root & "/selfbuild.ada", Root & "/selfbuild",
                       Modules, Args ("-I."));
      Clear (Modules);

      --  Now the source is newer than the binary just built from it.
      Write_Self_Builder ("second");
      Check (Is_Newer (Root & "/selfbuild.ada", Root & "/selfbuild"),
             "SELFBUILD SOURCE IS NEWER THAN ITS BINARY");

      Cmd (Root & "/selfbuild");
      Check (Path_Exists (Root & "/marker"),
             "GO_REBUILD_URSELF RE-EXECS THE REBUILT PROGRAM");
      if Path_Exists (Root & "/marker") then
         Check (Read_File (Root & "/marker") = "second",
                "GO_REBUILD_URSELF REBUILDS FROM THE CURRENT SOURCE");
      end if;
   end Check_Rebuild_Carries_The_Host;

begin
   Set_Log_Level (Quiet);
   Sh ("rm -rf " & Root);
   Make_Dir (Root);

   Write_Sources;
   Check_Compilation;
   Check_Failure_Paths;
   Check_Extra_Flags;
   Check_Go_Rebuild_Urself;
   Check_Rebuild_Carries_The_Host;

   Sh ("rm -rf " & Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Phase4;
