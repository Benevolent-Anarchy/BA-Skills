# Resolves Windows filesystem redirection to a path other processes can open.
#requires -Version 7.2
Set-StrictMode -Version Latest
function Resolve-ReleaseWindowsPath([string]$Path) {
    if (-not ('BARelease.NativePath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace BARelease {
 public static class NativePath {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder buffer, uint size, uint flags);
  public static string Resolve(string path) {
   using (var handle=CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
    if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
    var buffer=new StringBuilder(32768);
    uint size=GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
    if (size==0 || size>=buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
    string value=buffer.ToString();
    if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\"+value.Substring(8);
    return value.StartsWith(@"\\?\", StringComparison.Ordinal) ? value.Substring(4) : value;
   }
  }
 }
}
'@
    }
    $full=[IO.Path]::GetFullPath($Path);$ancestor=$full
    while (-not (Test-Path -LiteralPath $ancestor)) {
        $parent=Split-Path $ancestor -Parent
        if (-not $parent -or $parent -eq $ancestor) {throw 'Windows release path has no accessible ancestor.'}
        $ancestor=$parent
    }
    $physical=[BARelease.NativePath]::Resolve($ancestor)
    if ($ancestor -ceq $full) {return [IO.Path]::GetFullPath($physical)}
    return [IO.Path]::GetFullPath((Join-Path $physical ([IO.Path]::GetRelativePath($ancestor,$full))))
}
Export-ModuleMember -Function Resolve-ReleaseWindowsPath
