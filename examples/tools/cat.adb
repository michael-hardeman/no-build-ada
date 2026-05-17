--  cat.adb -- concatenate files to stdout

with GNAT.OS_Lib; use GNAT.OS_Lib;
with Ada.Text_IO;
with Ada.Command_Line;

procedure Cat is

   Buffer : String (1 .. 4096);

   procedure Cat_File (Path : String) is
      FD : constant File_Descriptor := Open_Read (Path, Binary);
      N  : Integer;
   begin
      if FD = Invalid_FD then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, "ERROR: could not open file: " & Path);
         OS_Exit (1);
      end if;
      loop
         N := Read (FD, Buffer'Address, Buffer'Length);
         exit when N <= 0;
         if Write (Standout, Buffer'Address, N) /= N then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error, "ERROR: write failed");
            OS_Exit (1);
         end if;
      end loop;
      Close (FD);
   end Cat_File;

begin
   if Ada.Command_Line.Argument_Count < 1 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "USAGE: cat <file...>");
      OS_Exit (1);
   end if;

   for I in 1 .. Ada.Command_Line.Argument_Count loop
      Cat_File (Ada.Command_Line.Argument (I));
   end loop;
end Cat;
