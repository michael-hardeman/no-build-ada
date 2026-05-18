with System;
package Windows_DL is
   --  Exporting dlopen / dlsym from this unit satisfies the link-time
   --  references in no_build.adb.
   --  Copy this packages .ads and .adb files next to build.adb
   --  and add `with Windows_DL;` to build.adb when compiling on
   --  windows to force the unit into the link and fix linker errors.

   function DL_Open
     (Path : System.Address; Mode : Integer) return System.Address;
   pragma Export (C, DL_Open, "dlopen");

   function DL_Sym
     (Handle : System.Address; Symbol : System.Address) return System.Address;
   pragma Export (C, DL_Sym, "dlsym");

end Windows_DL;