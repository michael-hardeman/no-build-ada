--  test_phase1.adb -- exercises the pure-Ada core of the Ada 83 port:
--  Argument_List, path utilities, Str, logging levels and the platform
--  probe.  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Phase1 is
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

   procedure Check_Args is
      L : Argument_List := Args ("a", "b", "c");
      M : Argument_List;
      J : Argument_List;
   begin
      Check (Length (L) = 3, "ARGS LENGTH");
      Check (Element (L, 1) = "a", "ELEMENT 1");
      Check (Element (L, 3) = "c", "ELEMENT 3");

      Append (L, "d");
      Check (Length (L) = 4 and then Element (L, 4) = "d", "APPEND ITEM");

      for I in 1 .. 20 loop
         Append (M, "x");
      end loop;
      Check (Length (M) = 20, "GROWTH PAST INITIAL CAPACITY");

      J := L & M;
      Check (Length (J) = 24, "LIST & LIST");
      Check (Element (J, 5) = "x", "CONCAT ORDER");

      J := Copy (Args ("solo")) & "tail";
      Check (Length (J) = 2 and then Element (J, 2) = "tail",
             "LIST & STRING");

      J := "head" & Args ("rest");
      Check (Length (J) = 2 and then Element (J, 1) = "head",
             "STRING & LIST");

      Check (Length (No_Args) = 0, "NO_ARGS EMPTY");

      begin
         declare
            S : constant String := Element (L, 99);
         begin
            Failed := True;
            Text_IO.Put_Line ("FAILED: ELEMENT RANGE CHECK, GOT " & S);
         end;
      exception
         when Constraint_Error =>
            null;
      end;

      Clear (L);
      Check (Length (L) = 0, "CLEAR EMPTIES");
      Append (L, "reuse");
      Check (Length (L) = 1 and then Element (L, 1) = "reuse",
             "REUSE AFTER CLEAR");

      declare
         Eight : constant Argument_List :=
           Args ("1", "2", "3", "4", "5", "6", "7", "8");
      begin
         Check (Length (Eight) = 8 and then Element (Eight, 8) = "8",
                "EIGHT-ARG CONSTRUCTOR");
      end;
   end Check_Args;

   procedure Check_Paths is
   begin
      Check ("a" / "b" = "a/b", "PATH JOIN");
      Check ("" / "b" = "b", "JOIN EMPTY LEFT");
      Check ("a" / "" = "a", "JOIN EMPTY RIGHT");
      Check ("foo/" / "bar" = "foo/bar", "JOIN KEEPS EXISTING SEPARATOR");
      Check ("foo\" / "bar" = "foo\bar", "JOIN KEEPS BACKSLASH");
      Check (Ends_With ("x", ""), "ENDS_WITH EMPTY SUFFIX");
      Check (not Ends_With ("", ".adb"), "ENDS_WITH EMPTY STRING");
      Check (No_Ext ("dir/file.adb") = "dir/file", "NO_EXT");
      Check (No_Ext ("dir.d/file") = "dir.d/file", "NO_EXT DOTTED DIR");
      Check (No_Ext ("plain") = "plain", "NO_EXT PLAIN");
      Check (Ends_With ("hello.adb", ".adb"), "ENDS_WITH TRUE");
      Check (not Ends_With ("hello.ads", ".adb"), "ENDS_WITH FALSE");
      Check (not Ends_With ("b", ".adb"), "ENDS_WITH SHORT");
      Check (Base_Name ("a/b/c.adb") = "c.adb", "BASE_NAME");
      Check (Base_Name ("plain") = "plain", "BASE_NAME PLAIN");
   end Check_Paths;

   procedure Check_Str is
      S : constant Str := +"hello";
      Q : constant Str := +String'("qualified");
   begin
      Check (Value (S) = "hello", "STR ROUND-TRIP");
      Check (Value (Q) = "qualified", "STR FROM QUALIFIED OPERAND");
      Check (Value (null) = "", "STR NULL VALUE");
   end Check_Str;

   procedure Check_Platform_And_Logging is
      P : constant Platform_Kind := Platform;
   begin
      Check (P = Platform, "PLATFORM STABLE");
      Set_Log_Level (Silent);
      Info ("this line must not appear");
      Set_Log_Level (Verbose);
      begin
         Panic ("expected [ERRO]: exercising Panic");
         Failed := True;
         Text_IO.Put_Line ("FAILED: PANIC DID NOT RAISE");
      exception
         when Build_Error =>
            null;
      end;
   end Check_Platform_And_Logging;

begin
   Check_Args;
   Check_Paths;
   Check_Str;
   Check_Platform_And_Logging;
   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Phase1;
