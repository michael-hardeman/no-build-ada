--  test_processes.adb -- Cmd_Async, Wait, Proc_List, Wait_All and
--  N_Procs.
--
--  This is the parallel half of the command layer: spawn without
--  waiting, then collect.  A batch reports failure once, at the end, so
--  one failing child in a batch of good ones still raises.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Processes is
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

   procedure Check_Async_Pair_Runs_Together is
      P1, P2 : Proc;
   begin
      P1 := Cmd_Async ("/bin/sleep", Args ("0.2"));
      P2 := Cmd_Async ("/bin/sleep", Args ("0.2"));
      Wait (P1);
      Wait (P2);
      Check (True, "TWO ASYNC CHILDREN BOTH COMPLETE");
   end Check_Async_Pair_Runs_Together;

   procedure Check_Wait_Reports_Failure is
      P : Proc;
   begin
      P := Cmd_Async ("/bin/false");
      begin
         Wait (P);
         Check (False, "WAIT ON A FAILING CHILD MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;
   end Check_Wait_Reports_Failure;

   procedure Check_Batch is
      Batch : Proc_List;
   begin
      Append (Batch, Cmd_Async ("/bin/true"));
      Append (Batch, Cmd_Async ("/bin/true"));
      Wait_All (Batch);
      Check (True, "WAIT_ALL ON A GOOD BATCH RETURNS");

      --  Wait_All empties the list, so the same one is reusable.
      Append (Batch, Cmd_Async ("/bin/true"));
      Append (Batch, Cmd_Async ("/bin/false"));
      Append (Batch, Cmd_Async ("/bin/true"));
      begin
         Wait_All (Batch);
         Check (False, "WAIT_ALL WITH ONE FAILURE MUST RAISE");
      exception
         when Build_Error =>
            null;
      end;

      --  and after raising it is empty again, not still holding the
      --  batch that failed.
      Append (Batch, Cmd_Async ("/bin/true"));
      Wait_All (Batch);
      Check (True, "WAIT_ALL REUSABLE AFTER A FAILING BATCH");
   end Check_Batch;

   procedure Check_Missing_Program is
   begin
      declare
         P : constant Proc := Cmd_Async ("definitely-not-a-real-program-42");
      begin
         Wait (P);
         Check (False, "ASYNC MISSING PROGRAM MUST RAISE");
      end;
   exception
      when Build_Error =>
         null;
   end Check_Missing_Program;

   procedure Check_N_Procs is
   begin
      Check (N_Procs >= 1, "N_PROCS AT LEAST ONE");
      Check (N_Procs = N_Procs, "N_PROCS STABLE");
   end Check_N_Procs;

begin
   Set_Log_Level (Quiet);

   Check_Async_Pair_Runs_Together;
   Check_Wait_Reports_Failure;
   Check_Batch;
   Check_Missing_Program;
   Check_N_Procs;

   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Processes;
