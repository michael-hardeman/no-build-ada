--  foreach.adb -- demonstrate No_Build.For_Each_File

with No_Build;

procedure Foreach is
   use No_Build;

   procedure Print (Name : String) is
   begin
      Info ("    " & Name);
   end Print;

   procedure Print_All is new For_Each_File (Print);

begin
   Info ("For_Each_File ("".""):");
   Print_All (".");
end Foreach;
