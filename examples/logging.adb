--  logging.adb -- demonstrate No_Build logging procedures

with No_Build;

procedure Logging is
   use No_Build;
begin
   Info ("    Informational Message");
   Warn ("    Warning Message");
   Erro ("    Error Message");
end Logging;
