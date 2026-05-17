--  pipe.adb -- demonstrate shell pipes via No_Build.Sh
--
--  Sh is a thin wrapper over the platform shell, so command syntax is
--  not portable -- see the gotcha list on No_Build.Sh.  Here we branch
--  on Platform: a POSIX pipeline on Linux/macOS and a cmd.exe pipeline
--  on Windows.  Both pipe a short greeting through rot13 then hex; we
--  then cat the file via No_Build.Cmd and clean up.

with No_Build; use No_Build;

procedure Pipe is
begin
   case Platform is
      when Linux | MacOS =>
         Sh ("echo 'Hello, World!' | examples/tools/rot13"
             & " | examples/tools/hex > output.txt");
      when Windows =>
         Sh ("echo Hello, World | examples\tools\rot13"
             & " | examples\tools\hex > output.txt");
   end case;
   Cmd ("examples/tools/cat", Argument_List'(1 => S ("output.txt")));
   Remove_Path ("output.txt");
end Pipe;
