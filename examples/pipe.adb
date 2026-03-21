--  pipe.adb -- demonstrate shell pipes via No_Build.Sh
--  Pipes this source file through rot13 then hex, outputs to a temp file,
--  cats the result, then cleans up.

with No_Build; use No_Build;

procedure Pipe is
begin
   Sh ("tools/rot13 < examples/pipe.adb | tools/hex > output.txt");
   Cmd ("tools/cat", Argument_List'(1 => S ("output.txt")));
   Remove_Path ("output.txt");
end Pipe;
