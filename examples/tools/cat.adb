--  cat.adb -- concatenate the named files to stdout

with Text_IO;
with Command_Line;

procedure Cat is

   procedure Cat_File (Path : String) is
      File : Text_IO.File_Type;
      Line : String (1 .. 4096);
      Last : Natural;
   begin
      Text_IO.Open (File, Text_IO.In_File, Path);
      while not Text_IO.End_Of_File (File) loop
         Text_IO.Get_Line (File, Line, Last);
         Text_IO.Put_Line (Line (1 .. Last));
      end loop;
      Text_IO.Close (File);
   exception
      when Text_IO.Name_Error =>
         Text_IO.Put_Line ("ERROR: could not open file: " & Path);
   end Cat_File;

begin
   for I in 1 .. Command_Line.Argument_Count loop
      Cat_File (Command_Line.Argument (I));
   end loop;
end Cat;
