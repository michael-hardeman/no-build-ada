--  build_all.adb -- example build script using No_Build
--
--  Bootstrap (one time only):
--    gnatmake -D examples/obj -I. examples/build_all.adb -o examples/build_all
--    ./examples/build_all
--
--  From then on just run ./examples/build_all -- it recompiles itself
--  automatically whenever this source changes.

with No_Build; use No_Build;

procedure Build_All is

   Obj      : constant String := "examples/obj";
   Tools    : constant String := "examples/tools";
   Examples : constant String := "examples";
   Lib      : constant String := "examples/lib";

   procedure Build_Tool (Tool : String) is
   begin
      Compile_Program (Tools / Tool, Output => Tools / No_Ext (Tool),
                       Obj_Dir => Obj);
   end Build_Tool;

   --  Pass -I examples/lib so the compiler finds library specs and any
   --  out-of-date bodies.  -I. lets it find No_Build at the project root.
   --  Skip build_all.adb itself; Go_Rebuild_Urself already handles it.
   procedure Build_And_Run_Example (Example : String) is
      Bin : constant String := Examples / No_Ext (Example);
   begin
      if Example = "build_all.adb" then
         return;
      end if;
      Compile_Program (Examples / Example, Output => Bin,
                       Obj_Dir => Obj,
                       Extra   => Argument_List'(S ("-I."), S ("-I" & Lib)));
      Cmd (Bin);
   end Build_And_Run_Example;

begin
   Go_Rebuild_Urself (Binary_Path => "./examples/build_all",
                      Source_Path => "examples/build_all.adb",
                      Obj_Dir     => Obj,
                      Extra       => Argument_List'(1 => S ("-I.")));

   --  Compile library sources into obj/ (non-PIC) and produce a static
   --  archive.  obj/greet.ali stays there so downstream Compile_Program
   --  calls can satisfy the "with Greet" dependency without recompiling.
   Info ("building static library...");
   Build_Static_Lib (Lib, Output => Lib / "libgreet.a", Obj_Dir => Obj);

   --  PIC objects live in a separate tree so they don't clobber the
   --  non-PIC objects used for linking executables.
   Info ("building shared library...");
   Build_Shared_Lib (Lib, Output => Lib / "libgreet.so",
                     Obj_Dir => Obj / "pic");

   Info ("building tools...");
   For_Each_File (Tools, Build_Tool'Access, Suffix => ".adb");

   Info ("building and running examples...");
   For_Each_File (Examples, Build_And_Run_Example'Access, Suffix => ".adb");

   Info ("Done.");
end Build_All;
