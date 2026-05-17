--  build.adb -- example build script using No_Build
--
--  Bootstrap (one time only):
--    gnatmake build.adb -o build && ./build
--
--  From then on just run ./build -- it recompiles itself automatically.

with No_Build; use No_Build;

procedure Build is

   Obj : constant String := "obj";

   procedure Build_Tool (Tool : String) is
   begin
      Compile_Program ("tools" / Tool, Output => "tools" / No_Ext (Tool),
                       Obj_Dir => Obj);
   end Build_Tool;

   --  Pass -I lib/ so the compiler finds library specs and any out-of-date
   --  bodies.
   procedure Build_And_Run_Example (Example : String) is
      Bin : constant String := "examples" / No_Ext (Example);
   begin
      Compile_Program ("examples" / Example, Output => Bin,
                       Obj_Dir => Obj,
                       Extra   => Argument_List'(S ("-I."), S ("-Ilib")));
      Cmd (Bin);
   end Build_And_Run_Example;

begin
   Go_Rebuild_Urself (Binary_Path => "./build",
                      Source_Path => "build.adb",
                      Obj_Dir     => Obj);

   --  Compile library sources into obj/ (non-PIC) and produce a static
   --  archive.  obj/greet.ali stays there so downstream Compile_Program
   --  calls can satisfy the "with Greet" dependency without recompiling.
   Info ("building static library...");
   Build_Static_Lib ("lib", Output => "lib/libgreet.a", Obj_Dir => Obj);

   --  PIC objects live in a separate tree so they don't clobber the
   --  non-PIC objects used for linking executables.
   Info ("building shared library...");
   Build_Shared_Lib ("lib", Output => "lib/libgreet.so",
                     Obj_Dir => Obj / "pic");

   Info ("building tools...");
   For_Each_File ("tools", Build_Tool'Access, Suffix => ".adb");

   Info ("building and running examples...");
   For_Each_File ("examples", Build_And_Run_Example'Access, Suffix => ".adb");

   Info ("Done.");
end Build;
