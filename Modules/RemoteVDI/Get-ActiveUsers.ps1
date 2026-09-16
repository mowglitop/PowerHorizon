
if (-not ('PowerHorizon.WtsUsers' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace PowerHorizon {
 public class DesktopUser { public string UserName; public string Domain; public int SessionId; }
 public static class WtsUsers {
  [StructLayout(LayoutKind.Sequential)]
  struct Session { public int Id; public IntPtr Station; public int State; }
  [DllImport("wtsapi32.dll", EntryPoint="WTSEnumerateSessionsW", SetLastError=true)]
  static extern bool Enumerate(IntPtr server, int reserved, int version, out IntPtr data, out int count);
  [DllImport("wtsapi32.dll", EntryPoint="WTSQuerySessionInformationW", SetLastError=true)]
  static extern bool Query(IntPtr server, int id, int info, out IntPtr data, out int bytes);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr data);
  static string Read(int id, int info) {
   IntPtr data; int bytes;
   if (!Query(IntPtr.Zero, id, info, out data, out bytes)) throw new Win32Exception();
   try { return Marshal.PtrToStringUni(data) ?? ""; } finally { WTSFreeMemory(data); }
  }
  public static DesktopUser[] Active() {
   IntPtr data; int count;
   if (!Enumerate(IntPtr.Zero, 0, 1, out data, out count)) throw new Win32Exception();
   var users = new List<DesktopUser>();
   try {
    int size = Marshal.SizeOf(typeof(Session));
    for (int i=0; i<count; i++) {
     var s = (Session)Marshal.PtrToStructure(IntPtr.Add(data, i*size), typeof(Session));
     if (s.State != 0 || s.Id == 0) continue;
     string name = Read(s.Id, 5);
     if (name.Length > 0) users.Add(new DesktopUser { UserName=name, Domain=Read(s.Id, 7), SessionId=s.Id });
    }
   } finally { WTSFreeMemory(data); }
   return users.ToArray();
  }
 }
}
"@
}
[PowerHorizon.WtsUsers]::Active()
