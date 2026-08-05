--  test_rebuilding.adb -- Go_Rebuild_Urself.
--
--  The rebuild cannot be run in this process: it re-execs and never
--  returns.  So the real case is checked with a second No_Build program
--  that calls it, built here, then made stale and run.
--
--  Needs ada83 on PATH, and is run from the project root, where the
--  bootstrap left no_build.ll and platform_support.ll.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Rebuilding is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_rebuilding";

   Source : constant String := Root / "selfbuild.ada";
   Binary : constant String := Root / "selfbuild";
   Marker : constant String := Root / "marker";

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   --  Up to date, so this must return rather than rebuild and re-exec.
   --  If it re-execs, the test never reaches its final PASSED line.
   procedure Check_Returns_When_Up_To_Date is
   begin
      Write_File (Root / "fresh.ada", "procedure Fresh is begin null; end;");
      Sh ("sleep 0.05");
      Write_File (Root / "fresh", "pretend binary");

      Go_Rebuild_Urself (Root / "fresh", Root / "fresh.ada");
      Check (True, "GO_REBUILD_URSELF RETURNS WHEN UP TO DATE");
   end Check_Returns_When_Up_To_Date;

   --  A source that is not there cannot have changed.
   procedure Check_Missing_Source_Is_A_No_Op is
   begin
      Go_Rebuild_Urself (Root / "fresh", Root / "absent.ada");
      Check (True, "GO_REBUILD_URSELF WITH NO SOURCE IS A NO-OP");
   end Check_Missing_Source_Is_A_No_Op;

   procedure Write_Self_Builder (Written_Marker : String) is
   begin
      Write_File (Source,
        "with No_Build;" & ASCII.LF &
        "procedure Selfbuild is" & ASCII.LF &
        "   use No_Build;" & ASCII.LF &
        "begin" & ASCII.LF &
        "   Set_Log_Level (Silent);" & ASCII.LF &
        "   Go_Rebuild_Urself (""" & Binary & """, """ & Source & """);" &
                              ASCII.LF &
        "   Write_File (""" & Marker & """, """ & Written_Marker & """);" &
                              ASCII.LF &
        "end Selfbuild;" & ASCII.LF);
   end Write_Self_Builder;

   --  Build the program from one source, then leave a different source
   --  in its place.  The marker the program writes is spelled only by
   --  the second source, so reading it back proves the rebuild happened,
   --  linked, and re-execed -- which it can only do if Go_Rebuild_Urself
   --  carried the library and this host's platform body forward on its
   --  own.  Nothing below names a platform.
   procedure Check_Rebuilds_And_Reexecs is
      Modules : Argument_List;
   begin
      Append (Modules, "no_build.ll");
      if Path_Exists ("platform_support.ll") then
         Append (Modules, "platform_support.ll");
      end if;

      Write_Self_Builder ("first");
      Compile_Program (Source, Binary, Modules, Args ("-I."));
      Clear (Modules);

      Write_Self_Builder ("second");
      Check (Is_Newer (Source, Binary),
             "THE SELFBUILD SOURCE IS NEWER THAN ITS BINARY");

      Cmd (Binary);
      Check (Path_Exists (Marker),
             "GO_REBUILD_URSELF RE-EXECS THE REBUILT PROGRAM");
      if Path_Exists (Marker) then
         Check (Read_File (Marker) = "second",
                "GO_REBUILD_URSELF REBUILDS FROM THE CURRENT SOURCE");
      end if;

      --  Second run: nothing changed since, so it must not rebuild.
      Remove_Path (Marker);
      Cmd (Binary);
      Check (Path_Exists (Marker) and then Read_File (Marker) = "second",
             "A SECOND RUN WITH NOTHING STALE STILL RUNS");
   end Check_Rebuilds_And_Reexecs;

begin
   Set_Log_Level (Quiet);
   Remove_Path (Root);
   Make_Dir (Root);

   Check_Returns_When_Up_To_Date;
   Check_Missing_Source_Is_A_No_Op;
   Check_Rebuilds_And_Reexecs;

   Remove_Path (Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Rebuilding;
