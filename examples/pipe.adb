--  pipe.adb -- demonstrate shell pipes via No_Build.Sh
--  Pipes a short greeting through rot13 then hex, writes to a temp file,
--  cats the result, then cleans up.

with No_Build; use No_Build;

procedure Pipe is
begin
   Sh ("echo 'Hello, World!' | examples/tools/rot13 | examples/tools/hex"
       & " > output.txt");
   Cmd ("examples/tools/cat", Argument_List'(1 => S ("output.txt")));
   Remove_Path ("output.txt");
end Pipe;
