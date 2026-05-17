--  rot13.adb -- apply ROT-13 cipher to stdin, write to stdout

with GNAT.OS_Lib; use GNAT.OS_Lib;
with Ada.Text_IO;

procedure Rot13 is

   Buffer : String (1 .. 4096);
   N      : Integer;

   function Rotate (C : Character) return Character is
      Pos : Integer;
   begin
      if C in 'a' .. 'z' then
         Pos := Character'Pos (C) - Character'Pos ('a');
         return Character'Val ((Pos + 13) mod 26 + Character'Pos ('a'));
      elsif C in 'A' .. 'Z' then
         Pos := Character'Pos (C) - Character'Pos ('A');
         return Character'Val ((Pos + 13) mod 26 + Character'Pos ('A'));
      else
         return C;
      end if;
   end Rotate;

begin
   loop
      N := Read (Standin, Buffer'Address, Buffer'Length);
      exit when N <= 0;
      for I in 1 .. N loop
         Buffer (I) := Rotate (Buffer (I));
      end loop;
      if Write (Standout, Buffer'Address, N) /= N then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, "ERROR: write failed");
         OS_Exit (1);
      end if;
   end loop;
end Rot13;
