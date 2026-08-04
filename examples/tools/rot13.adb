--  rot13.adb -- apply the ROT-13 cipher to stdin, write to stdout

with Text_IO;

procedure Rot13 is

   Line : String (1 .. 4096);
   Last : Natural;

   function Rotate (C : Character) return Character is
      Pos : Integer;
   begin
      if C >= 'a' and then C <= 'z' then
         Pos := Character'Pos (C) - Character'Pos ('a');
         return Character'Val ((Pos + 13) mod 26 + Character'Pos ('a'));
      elsif C >= 'A' and then C <= 'Z' then
         Pos := Character'Pos (C) - Character'Pos ('A');
         return Character'Val ((Pos + 13) mod 26 + Character'Pos ('A'));
      end if;
      return C;
   end Rotate;

begin
   while not Text_IO.End_Of_File loop
      Text_IO.Get_Line (Line, Last);
      for I in 1 .. Last loop
         Line (I) := Rotate (Line (I));
      end loop;
      Text_IO.Put_Line (Line (1 .. Last));
   end loop;
end Rot13;
