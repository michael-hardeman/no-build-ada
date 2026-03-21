--  logging.adb -- demonstrate No_Build logging procedures

with No_Build; use No_Build;

procedure Logging is
begin
   Info ("    Informational Message");
   Warn ("    Warning Message");
   Erro ("    Error Message");
end Logging;
