--  foreach.adb -- demonstrate No_Build.For_Each_File

with No_Build; use No_Build;

procedure Foreach is

   procedure Print (Name : String) is
   begin
      Info ("    " & Name);
   end Print;

begin
   Info ("For_Each_File ("".""):");
   For_Each_File (".", Print'Access);
end Foreach;
