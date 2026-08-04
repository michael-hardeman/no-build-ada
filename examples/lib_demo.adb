--  lib_demo.adb -- demonstrate building against a library package

with Greet;
with No_Build;

procedure Lib_Demo is
   use No_Build;
begin
   Info ("--- library demo ---");
   Greet.Hello    ("Ada");
   Greet.Hello    ("Ada 83");
   Greet.Farewell ("C");
end Lib_Demo;
