--  lib_demo.adb -- demonstrate building and using a library package

with Greet;
with No_Build; use No_Build;

procedure Lib_Demo is
begin
   Info ("--- library demo ---");
   Greet.Hello    ("Ada");
   Greet.Hello    ("GNAT");
   Greet.Farewell ("C");
end Lib_Demo;
