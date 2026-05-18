-- windows_dl.adb
package body Windows_DL is

   function LoadLibraryA (Name : System.Address) return System.Address;
   pragma Import (Stdcall, LoadLibraryA, "LoadLibraryA");

   function GetModuleHandleA (Name : System.Address) return System.Address;
   pragma Import (Stdcall, GetModuleHandleA, "GetModuleHandleA");

   function GetProcAddress
     (Handle : System.Address; Name : System.Address) return System.Address;
   pragma Import (Stdcall, GetProcAddress, "GetProcAddress");

   function DL_Open
     (Path : System.Address; Mode : Integer) return System.Address
   is
      pragma Unreferenced (Mode);
      use type System.Address;
   begin
      if Path = System.Null_Address then
         --  dlopen(NULL): hand back a handle to the current process.
         return GetModuleHandleA (System.Null_Address);
      else
         return LoadLibraryA (Path);
      end if;
   end DL_Open;

   function DL_Sym
     (Handle : System.Address; Symbol : System.Address) return System.Address
   is begin
      return GetProcAddress (Handle, Symbol);
   end DL_Sym;

end Windows_DL;