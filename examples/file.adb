--  file.adb -- demonstrate No_Build filesystem predicates and mutations

with No_Build;

procedure File is
   use No_Build;

   procedure Demo_Bool (Label : String; Value : Boolean) is
   begin
      if Value then
         Info ("    " & Label & " == 1");
      else
         Info ("    " & Label & " == 0");
      end if;
   end Demo_Bool;

   procedure Print (Name : String) is
   begin
      Info ("    " & Name);
   end Print;

   procedure Print_All is new For_Each_File (Print);

begin
   Demo_Bool ("Is_Dir (""./examples/file.adb"")",
              Is_Dir ("./examples/file.adb"));
   Demo_Bool ("Is_Dir (""./examples"")",       Is_Dir ("./examples"));
   Demo_Bool ("Is_Dir (""./does_not_exist"")", Is_Dir ("./does_not_exist"));

   Demo_Bool ("Path_Exists (""./examples/file.adb"")",
              Path_Exists ("./examples/file.adb"));
   Demo_Bool ("Path_Exists (""./examples"")",  Path_Exists ("./examples"));
   Demo_Bool ("Path_Exists (""./does_not_exist"")",
              Path_Exists ("./does_not_exist"));

   Info ("Listing the current directory:");
   Print_All (".");

   Info ("Directory creation:");
   Make_Dirs ("foo" / "bar" / "baz");
   Make_Dirs ("foo" / "bar" / "hello" / "world");

   Info ("Directory removal:");
   Remove_Path ("foo");
   Demo_Bool ("Is_Dir (""foo"")", Is_Dir ("foo"));
end File;
