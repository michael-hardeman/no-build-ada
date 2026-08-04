--  build_all.adb -- example build script using No_Build
--
--  Bootstrap (one time only):
--    sh bootstrap.sh
--    ./examples/build_all
--
--  From then on just run ./examples/build_all -- it recompiles itself
--  whenever this source changes.

with No_Build;

procedure Build_All is
   use No_Build;

   Examples : constant String := "examples";
   Tools    : constant String := "examples/tools";
   Lib      : constant String := "examples/lib";
   Library  : constant String := "no_build.ll";
   Greet_LL : constant String := "examples/lib/greet.ll";

   procedure Build_Tool (Tool : String) is
   begin
      Compile_Program (Tools / Tool, Tools / No_Ext (Tool));
   end Build_Tool;

   --  Every example links the library module, and lib_demo also links
   --  Greet.  Skip build_all itself; Go_Rebuild_Urself handles it.
   procedure Build_And_Run_Example (Example : String) is
      Bin     : constant String := Examples / No_Ext (Example);
      Modules : Argument_List;
   begin
      if Example = "build_all.adb" then
         return;
      end if;
      Append (Modules, Library);
      if Example = "lib_demo.adb" then
         Append (Modules, Greet_LL);
      end if;
      Compile_Program (Examples / Example, Bin, Modules,
                       Args ("-I.", "-I" & Lib));
      Clear (Modules);
      Cmd (Bin);
   end Build_And_Run_Example;

   procedure Build_Tools    is new For_Each_File (Build_Tool);
   procedure Build_Examples is new For_Each_File (Build_And_Run_Example);

begin
   Go_Rebuild_Urself ("./examples/build_all", "examples/build_all.adb",
                      Args ("-I."));

   Info ("building the library...");
   Compile_Module ("no_build.adb", Library);

   --  ada83 has no archive stage, so a "library" here is an .ll module
   --  that the programs needing it link alongside their own source.
   Info ("building the greet module...");
   Compile_Module (Lib / "greet.adb", Greet_LL);

   Info ("building tools...");
   Build_Tools (Tools, ".adb");

   Info ("building and running examples...");
   Build_Examples (Examples, ".adb");

   Info ("Done.");
end Build_All;
