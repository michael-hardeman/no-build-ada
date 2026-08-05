--  test_commands.adb -- Cmd, Sh, Capture and output redirection.
--
--  These are the ways a build script runs one program and waits for it.
--  Every one of them reports failure the same way, by raising
--  Build_Error, so each is checked for both outcomes.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Commands is
   use No_Build;

   Failed : Boolean := False;
   Root   : constant String := "tmp_commands";

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   procedure Check_Cmd is
   begin
      Cmd ("/bin/true");
      Check (True, "CMD ZERO EXIT RETURNS");

      begin
         Cmd ("/bin/false");
         Check (False, "CMD NONZERO MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;

      begin
         Cmd ("definitely-not-a-real-program-42");
         Check (False, "CMD MISSING PROGRAM MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
   end Check_Cmd;

   procedure Check_Arguments_Reach_The_Program is
   begin
      Check (Capture ("/bin/echo", Args ("one", "two")) = "one two",
             "ARGUMENTS ARRIVE IN ORDER");
      Check (Capture ("/bin/echo", Args ("with space")) = "with space",
             "ARGUMENT WITH A SPACE IS ONE ARGUMENT");
   end Check_Arguments_Reach_The_Program;

   procedure Check_Capture is
   begin
      Check (Capture ("/bin/echo", Args ("captured")) = "captured",
             "CAPTURE ECHO");
      Check (Capture ("/bin/echo", Args ("  padded  ")) = "padded",
             "CAPTURE TRIMS");
      Check (Capture ("/bin/true") = "", "CAPTURE NO OUTPUT");

      begin
         declare
            Ignored : constant String := Capture ("/bin/false");
         begin
            Check (False, "CAPTURE NONZERO MUST RAISE, GOT " & Ignored);
         end;
      exception
         when Build_Error =>
            null;
      end;
   end Check_Capture;

   procedure Check_Sh is
   begin
      Sh ("exit 0");
      Check (True, "SH ZERO EXIT RETURNS");

      begin
         Sh ("exit 3");
         Check (False, "SH NONZERO MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
   end Check_Sh;

   procedure Check_Redirect is
   begin
      Cmd ("/bin/echo", Args ("into-file"),
           To_File (Stdout => Root / "out.txt"));
      Check (Read_File (Root / "out.txt") = "into-file" & ASCII.LF,
             "REDIRECT STDOUT TO FILE");

      --  The file is truncated, not appended to, so a second run of a
      --  shorter command cannot leave the tail of the first behind.
      Cmd ("/bin/echo", Args ("x"), To_File (Stdout => Root / "out.txt"));
      Check (Read_File (Root / "out.txt") = "x" & ASCII.LF,
             "REDIRECT TRUNCATES");

      Sh ("echo to-stderr 1>&2");
      Cmd ("/bin/sh", Args ("-c", "echo diagnosed 1>&2"),
           To_File (Stderr => Root / "err.txt"));
      Check (Read_File (Root / "err.txt") = "diagnosed" & ASCII.LF,
             "REDIRECT STDERR TO FILE");
   end Check_Redirect;

begin
   Set_Log_Level (Quiet);
   Remove_Path (Root);
   Make_Dir (Root);

   Check_Cmd;
   Check_Arguments_Reach_The_Program;
   Check_Capture;
   Check_Sh;
   Check_Redirect;

   Remove_Path (Root);
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Commands;
