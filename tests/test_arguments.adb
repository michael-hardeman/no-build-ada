--  test_arguments.adb -- Argument_List and Str.
--
--  Argument_List is the growable string list every command is built
--  from; Str is the heap string it stores.  Neither is controlled, so
--  what is checked here is the explicit lifetime: Copy makes an
--  independent list, Clear empties one and leaves it usable.
--
--  Prints PASSED, or one FAILED line per broken check.

with Text_IO;
with No_Build;

procedure Test_Arguments is
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

   procedure Check_Constructors is
      L : constant Argument_List := Args ("a", "b", "c");
      Eight : constant Argument_List :=
        Args ("1", "2", "3", "4", "5", "6", "7", "8");
   begin
      Check (Length (L) = 3, "ARGS LENGTH");
      Check (Element (L, 1) = "a", "ELEMENT 1");
      Check (Element (L, 3) = "c", "ELEMENT 3");
      Check (Length (Eight) = 8 and then Element (Eight, 8) = "8",
             "EIGHT-ARG CONSTRUCTOR");
      Check (Length (No_Args) = 0, "NO_ARGS EMPTY");
   end Check_Constructors;

   procedure Check_Growth is
      M : Argument_List;
   begin
      for I in 1 .. 20 loop
         Append (M, "x");
      end loop;
      Check (Length (M) = 20, "GROWTH PAST INITIAL CAPACITY");
      Clear (M);
   end Check_Growth;

   procedure Check_Concatenation is
      L : Argument_List := Args ("a", "b", "c");
      M : Argument_List;
      J : Argument_List;
   begin
      Append (L, "d");
      Check (Length (L) = 4 and then Element (L, 4) = "d", "APPEND ITEM");

      for I in 1 .. 20 loop
         Append (M, "x");
      end loop;

      J := L & M;
      Check (Length (J) = 24, "LIST & LIST");
      Check (Element (J, 5) = "x", "CONCAT ORDER");

      J := Copy (Args ("solo")) & "tail";
      Check (Length (J) = 2 and then Element (J, 2) = "tail",
             "LIST & STRING");

      J := "head" & Args ("rest");
      Check (Length (J) = 2 and then Element (J, 1) = "head",
             "STRING & LIST");
   end Check_Concatenation;

   procedure Check_Bounds is
      L : constant Argument_List := Args ("a", "b");
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
   end Check_Bounds;

   procedure Check_Clear is
      L : Argument_List := Args ("a", "b", "c");
   begin
      Clear (L);
      Check (Length (L) = 0, "CLEAR EMPTIES");
      Append (L, "reuse");
      Check (Length (L) = 1 and then Element (L, 1) = "reuse",
             "REUSE AFTER CLEAR");
      Clear (L);
   end Check_Clear;

   --  Assignment shares storage, so Copy is the only way to get a list
   --  that outlives a Clear of the one it came from.
   procedure Check_Copy_Is_Independent is
      Original : Argument_List := Args ("keep", "these");
      Taken    : Argument_List := Copy (Original);
   begin
      Clear (Original);
      Check (Length (Taken) = 2 and then Element (Taken, 1) = "keep",
             "COPY SURVIVES CLEAR OF ITS SOURCE");
      Clear (Taken);
   end Check_Copy_Is_Independent;

   procedure Check_Str is
      S : constant Str := +"hello";
      Q : constant Str := +String'("qualified");
   begin
      Check (Value (S) = "hello", "STR ROUND-TRIP");
      Check (Value (Q) = "qualified", "STR FROM QUALIFIED OPERAND");
      Check (Value (null) = "", "STR NULL VALUE");
   end Check_Str;

begin
   Check_Constructors;
   Check_Growth;
   Check_Concatenation;
   Check_Bounds;
   Check_Clear;
   Check_Copy_Is_Independent;
   Check_Str;

   if not Failed then
      Text_IO.Put_Line ("PASSED");
   end if;
end Test_Arguments;
