--  hex.adb -- hex dump of stdin: 16 bytes per line, hex + printable ASCII

with GNAT.OS_Lib; use GNAT.OS_Lib;
with Ada.Text_IO; use Ada.Text_IO;

procedure Hex is

   Columns    : constant := 16;
   Padding    : constant := 6;
   Hex_Digits : constant String := "0123456789ABCDEF";

   Buffer : String (1 .. Columns);
   N      : Integer;

   function Hex_Byte (C : Character) return String is
      V : constant Natural := Character'Pos (C);
   begin
      return Hex_Digits (V / 16 + 1 .. V / 16 + 1)
           & Hex_Digits (V mod 16 + 1 .. V mod 16 + 1);
   end Hex_Byte;

   function Printable (C : Character) return Character is
   begin
      if C in ' ' .. '~' then return C; else return '.'; end if;
   end Printable;

begin
   loop
      N := Read (Standin, Buffer'Address, Columns);
      exit when N <= 0;

      for I in 1 .. N loop
         Put (Hex_Byte (Buffer (I)) & " ");
      end loop;

      --  Pad to align the ASCII column
      Put ((1 .. Padding + (Columns - N) * 3 => ' '));

      for I in 1 .. N loop
         Put (Printable (Buffer (I)));
      end loop;

      New_Line;
   end loop;
end Hex;
