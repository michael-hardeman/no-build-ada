--  greet.adb -- greeting library body

with Ada.Text_IO; use Ada.Text_IO;

package body Greet is

   procedure Hello (Name : String) is
   begin
      Put_Line ("Hello, " & Name & "!");
   end Hello;

   procedure Farewell (Name : String) is
   begin
      Put_Line ("Goodbye, " & Name & "!");
   end Farewell;

end Greet;
