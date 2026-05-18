--  test_support.ads -- tiny assertion helpers for No_Build tests.
--  Each test program calls Begin_Tests at startup, asserts via the helpers,
--  and exits with non-zero status on any failure (handled by End_Tests).

with Ada.Finalization;

package Test_Support is

   procedure Begin_Tests (Suite : String);
   --  Print a header.  Should be the first call in a test program.

   procedure Assert (Condition : Boolean; What : String);
   procedure Assert_Equal (Got, Want : String;  What : String);
   procedure Assert_Equal (Got, Want : Integer; What : String);
   procedure Assert_Equal (Got, Want : Boolean; What : String);

   procedure End_Tests;
   --  Print a summary; call OS_Exit with non-zero status if any Assert
   --  failed.  Should be the last call in a test program.

   --  Scratch_Path -- an RAII guard for a filesystem path used by a test.
   --  On creation it removes any leftover at that path; on scope exit
   --  (normal completion OR exception) it removes the path again.  Use it
   --  in a declare block to make a test's cleanup automatic:
   --
   --     declare
   --        Tmp : Scratch_Path := Scratch ("tmp_dir");
   --     begin
   --        Make_Dirs (Tmp.Path);
   --        ...
   --     end;  -- "tmp_dir" is removed regardless of how this block exits
   type Scratch_Path (Path_Len : Natural) is
     new Ada.Finalization.Limited_Controlled with record
        Path : String (1 .. Path_Len);
     end record;

   overriding procedure Finalize (Self : in out Scratch_Path);

   function Scratch (Path : String) return Scratch_Path;
   --  Construct a Scratch_Path.  Pre-cleans Path (so a leftover from a
   --  previous failed run doesn't poison the test) and arranges for
   --  Finalize to clean it again on scope exit.

end Test_Support;
