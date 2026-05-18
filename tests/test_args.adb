with No_Build;     use No_Build;
with Test_Support; use Test_Support;

procedure Test_Args is
   A : Argument_List;
   B : Argument_List;
   C : Argument_List;
begin
   Begin_Tests ("Argument_List");

   --  No_Args is empty.
   Assert_Equal (Length (No_Args), 0, "No_Args has length 0");

   --  Args constructors.
   A := Args ("one");
   Assert_Equal (Length (A), 1, "Args (1) length");
   Assert_Equal (Element (A, 1), "one", "Args (1) element");

   A := Args ("a", "b", "c");
   Assert_Equal (Length (A), 3, "Args (3) length");
   Assert_Equal (Element (A, 1), "a", "Args (3) element 1");
   Assert_Equal (Element (A, 2), "b", "Args (3) element 2");
   Assert_Equal (Element (A, 3), "c", "Args (3) element 3");

   A := Args ("a", "b", "c", "d", "e", "f", "g", "h");
   Assert_Equal (Length (A), 8, "Args (8) length");
   Assert_Equal (Element (A, 8), "h", "Args (8) last element");

   --  Append (String).
   B := No_Args;
   B.Append ("x");
   B.Append ("y");
   Assert_Equal (Length (B), 2, "Append string grows length");
   Assert_Equal (Element (B, 1), "x", "Append preserves order");
   Assert_Equal (Element (B, 2), "y", "Append appends at tail");

   --  Append (Argument_List).
   C := Args ("p", "q");
   C.Append (Args ("r", "s"));
   Assert_Equal (Length (C), 4, "Append (Argument_List) length");
   Assert_Equal (Element (C, 4), "s", "Append (Argument_List) tail");

   --  & operators.
   declare
      D : constant Argument_List := Args ("1") & "2" & Args ("3");
   begin
      Assert_Equal (Length (D), 3, "& chains lengths");
      Assert_Equal (Element (D, 1), "1", "& chain element 1");
      Assert_Equal (Element (D, 2), "2", "& chain element 2 (String)");
      Assert_Equal (Element (D, 3), "3", "& chain element 3");
   end;

   declare
      D : constant Argument_List := "head" & Args ("tail");
   begin
      Assert_Equal (Length (D), 2, "String & Argument_List length");
      Assert_Equal (Element (D, 1), "head", "String & Argument_List first");
      Assert_Equal (Element (D, 2), "tail", "String & Argument_List second");
   end;

   --  Deep-copy on assignment: mutating A after copy must not touch original.
   declare
      Original : constant Argument_List := Args ("immutable");
      Copy     : Argument_List := Original;
   begin
      Copy.Append ("added");
      Assert_Equal (Length (Original), 1, "Original unchanged after copy.append");
      Assert_Equal (Length (Copy), 2,     "Copy grew independently");
   end;

   End_Tests;
end Test_Args;
