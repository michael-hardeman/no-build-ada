with Ada.Text_IO;
with Ada.Command_Line;
with No_Build;

package body Test_Support is

   use Ada.Text_IO;

   Pass_Count : Natural := 0;
   Fail_Count : Natural := 0;
   Suite_Name : String (1 .. 64) := (others => ' ');
   Suite_Len  : Natural := 0;

   procedure Begin_Tests (Suite : String) is
      N : constant Natural := Natural'Min (Suite'Length, Suite_Name'Length);
   begin
      Suite_Name (1 .. N) := Suite (Suite'First .. Suite'First + N - 1);
      Suite_Len := N;
      Put_Line ("==> " & Suite);
   end Begin_Tests;

   procedure Record_Pass (What : String) is
   begin
      Pass_Count := Pass_Count + 1;
      Put_Line ("    PASS: " & What);
   end Record_Pass;

   procedure Record_Fail (What, Detail : String) is
   begin
      Fail_Count := Fail_Count + 1;
      Put_Line (Standard_Error, "    FAIL: " & What & " -- " & Detail);
   end Record_Fail;

   procedure Assert (Condition : Boolean; What : String) is
   begin
      if Condition then
         Record_Pass (What);
      else
         Record_Fail (What, "condition was False");
      end if;
   end Assert;

   procedure Assert_Equal (Got, Want : String; What : String) is
   begin
      if Got = Want then
         Record_Pass (What);
      else
         Record_Fail
           (What, "got """ & Got & """, want """ & Want & """");
      end if;
   end Assert_Equal;

   procedure Assert_Equal (Got, Want : Integer; What : String) is
   begin
      if Got = Want then
         Record_Pass (What);
      else
         Record_Fail
           (What, "got" & Got'Image & ", want" & Want'Image);
      end if;
   end Assert_Equal;

   procedure Assert_Equal (Got, Want : Boolean; What : String) is
   begin
      if Got = Want then
         Record_Pass (What);
      else
         Record_Fail
           (What, "got " & Got'Image & ", want " & Want'Image);
      end if;
   end Assert_Equal;

   procedure End_Tests is
   begin
      Put_Line ("    " & Suite_Name (1 .. Suite_Len) & ":"
                & Pass_Count'Image & " passed,"
                & Fail_Count'Image & " failed");
      if Fail_Count > 0 then
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end End_Tests;

   --------------------------------------------------------------------------
   --  Scratch_Path
   --------------------------------------------------------------------------

   procedure Sweep (Path : String) is
   begin
      if No_Build.Path_Exists (Path) then
         No_Build.Remove_Path (Path);
      end if;
   exception
      --  Best-effort: never let cleanup raise out of Finalize, since that
      --  would mask the underlying test failure.
      when others => null;
   end Sweep;

   procedure Finalize (Self : in out Scratch_Path) is
   begin
      Sweep (Self.Path);
   end Finalize;

   function Scratch (Path : String) return Scratch_Path is
   begin
      Sweep (Path);
      return (Ada.Finalization.Limited_Controlled with
              Path_Len => Path'Length,
              Path     => Path);
   end Scratch;

end Test_Support;
