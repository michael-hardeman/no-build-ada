--  test_logging.adb -- Set_Log_Level, the four log procedures, and
--  Panic.
--
--  Log output goes to stderr, which this program cannot read back, so
--  what is checked is the contract around it: every level is accepted,
--  Silent suppresses without erroring, and Panic raises Build_Error
--  after logging rather than instead of it.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Logging is
   use No_Build;

   Failed : Boolean := False;

   procedure Check (Ok : Boolean; Label : String) is
   begin
      if not Ok then
         Failed := True;
         Text_IO.Put ("FAILED: ");
         Text_IO.Put_Line (Label);
      end if;
   end Check;

   --  Nothing from here should reach stderr.  A run that prints these is
   --  a failure the eye catches; the suite captures stderr and shows it
   --  only when a test fails, so they would surface there too.
   procedure Check_Silent_Suppresses is
   begin
      Set_Log_Level (Silent);
      Info ("test_logging: this line must not appear");
      Warn ("test_logging: this line must not appear");
      Erro ("test_logging: this line must not appear");
      Check (True, "SILENT ACCEPTS EVERY TAG");
   end Check_Silent_Suppresses;

   procedure Check_Every_Level_Is_Accepted is
   begin
      for Level in Log_Level loop
         Set_Log_Level (Level);
      end loop;
      Set_Log_Level (Silent);
      Check (True, "EVERY LOG LEVEL ACCEPTED");
   end Check_Every_Level_Is_Accepted;

   procedure Check_Panic_Raises is
      Raised : Boolean := False;
   begin
      Set_Log_Level (Silent);
      begin
         Panic ("test_logging: exercising Panic");
      exception
         when Build_Error =>
            Raised := True;
      end;
      Check (Raised, "PANIC RAISES BUILD_ERROR");
   end Check_Panic_Raises;

   --  A level set before a raise still applies after it: Panic must not
   --  leave the logger in some other state on its way out.
   procedure Check_Level_Survives_A_Panic is
   begin
      Set_Log_Level (Silent);
      begin
         Panic ("test_logging: exercising Panic again");
      exception
         when Build_Error =>
            null;
      end;
      Info ("test_logging: this line must not appear");
      Check (True, "LOG LEVEL SURVIVES A PANIC");
   end Check_Level_Survives_A_Panic;

begin
   Check_Silent_Suppresses;
   Check_Every_Level_Is_Accepted;
   Check_Panic_Raises;
   Check_Level_Survives_A_Panic;

   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Logging;
