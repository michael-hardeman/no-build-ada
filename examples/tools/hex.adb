--  hex.adb -- hex dump of stdin: 16 bytes per line, hex then printable
--  ASCII, in the manner of hexdump -C

with Text_IO;

procedure Hex is

   Columns    : constant := 16;
   Hex_Digits : constant String := "0123456789ABCDEF";

   Line   : String (1 .. 4096);
   Last   : Natural;
   Buffer : String (1 .. Columns);
   Filled : Natural := 0;

   procedure Put_Byte (C : Character) is
      Code : constant Natural := Character'Pos (C);
   begin
      Text_IO.Put (Hex_Digits (Code / 16 + 1));
      Text_IO.Put (Hex_Digits (Code mod 16 + 1));
      Text_IO.Put (" ");
   end Put_Byte;

   procedure Flush_Row is
   begin
      if Filled = 0 then
         return;
      end if;
      for I in 1 .. Filled loop
         Put_Byte (Buffer (I));
      end loop;
      for I in Filled + 1 .. Columns loop
         Text_IO.Put ("   ");
      end loop;
      Text_IO.Put (" |");
      for I in 1 .. Filled loop
         if Buffer (I) >= ' ' and then Buffer (I) <= '~' then
            Text_IO.Put (Buffer (I));
         else
            Text_IO.Put ('.');
         end if;
      end loop;
      Text_IO.Put_Line ("|");
      Filled := 0;
   end Flush_Row;

   procedure Feed (C : Character) is
   begin
      Filled := Filled + 1;
      Buffer (Filled) := C;
      if Filled = Columns then
         Flush_Row;
      end if;
   end Feed;

begin
   while not Text_IO.End_Of_File loop
      Text_IO.Get_Line (Line, Last);
      for I in 1 .. Last loop
         Feed (Line (I));
      end loop;
      Feed (ASCII.LF);
   end loop;
   Flush_Row;
end Hex;
