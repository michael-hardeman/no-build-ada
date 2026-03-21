--  file.adb -- demonstrate No_Build filesystem predicates and mutations

with No_Build; use No_Build;

procedure File is

   procedure Demo_Bool (Label : String; Value : Boolean) is
   begin
      Info ("    " & Label & " == " & (if Value then "1" else "0"));
   end Demo_Bool;

   procedure Print (Name : String) is
   begin
      Info ("    " & Name);
   end Print;

begin
   Demo_Bool ("Is_Dir    (""./build.adb"")",           Is_Dir ("./build.adb"));
   Demo_Bool ("Is_Dir    (""./examples"")",            Is_Dir ("./examples"));
   Demo_Bool ("Is_Dir    (""./does_not_exist"")",      Is_Dir ("./does_not_exist"));

   Demo_Bool ("Path_Exists (""./build.adb"")",         Path_Exists ("./build.adb"));
   Demo_Bool ("Path_Exists (""./examples"")",          Path_Exists ("./examples"));
   Demo_Bool ("Path_Exists (""./does_not_exist"")",    Path_Exists ("./does_not_exist"));

   Info ("Recursively listing current directory:");
   For_Each_File (".", Print'Access);

   Info ("Directory creation:");
   Make_Dirs ("foo" / "bar" / "baz");
   Make_Dirs ("foo" / "bar" / "hello" / "world");

   Info ("Directory removal:");
   Remove_Path ("foo");
   Demo_Bool ("Is_Dir (""foo"")", Is_Dir ("foo"));
end File;
