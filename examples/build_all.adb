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

   procedure Build_Tool (Tool : String) is begin
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
      Compile_Program (Examples / Example,
                       Output  => Bin,
                       Obj_Dir => Obj,
                       Extra   => Args ("-I.", "-I" & Lib));
      Cmd (Bin);
   end Build_And_Run_Example;

begin
   Go_Rebuild_Urself (Binary_Path => "./examples/build_all",
                      Source_Path => "examples/build_all.adb",
                      Obj_Dir     => Obj,
                      Extra       => Args ("-I."));

   --  Build_*_Lib carves its own dedicated subdir under Obj_Dir
   --  ("libgreet_static" / "libgreet_pic"), so it can be the same
   --  Obj_Dir we use for executables without cross-contamination.
   --  Source points at the .ads (the lib's "interface"); the active
   --  GNAT descriptor's Resolve_Source hook swaps to greet.adb
   --  because the body exists alongside.
   Info ("building static library...");
   Build_Static_Lib (Lib / "greet.ads",
                     Output  => Lib / "libgreet.a",
                     Obj_Dir => Obj);

   Info ("building shared library...");
   Build_Shared_Lib (Lib / "greet.ads",
                     Output  => Lib / "libgreet.so",
                     Obj_Dir => Obj);

   Info ("building tools...");
   For_Each_File (Tools, Build_Tool'Access, Suffix => ".adb");

   Info ("building and running examples...");
   For_Each_File (Examples, Build_And_Run_Example'Access, Suffix => ".adb");

   Info ("Done.");
end Build_All;
