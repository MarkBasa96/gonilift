# Creates the "Gonilift" shortcut (Desktop, and optionally Start menu) that
# opens the desktop app with its own icon. The shortcut carries the same app
# ID as the running window (JoemarkBasa.Gonilift), so pinning Gonilift to the
# taskbar pins Gonilift itself, not Python.
param(
    [string]$Root = (Resolve-Path "$PSScriptRoot\..").Path,
    [switch]$StartMenu
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class GoniliftShortcut {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class CShellLink {}

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder f, int c, IntPtr d, uint fl);
        void GetIDList(out IntPtr p); void SetIDList(IntPtr p);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder n, int c);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string n);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder d, int c);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string d);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder a, int c);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string a);
        void GetHotkey(out short h); void SetHotkey(short h);
        void GetShowCmd(out int s); void SetShowCmd(int s);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder p, int c, out int i);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string p, int i);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string p, uint r);
        void Resolve(IntPtr h, uint f);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string f);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    interface IPropertyStore {
        void GetCount(out uint c); void GetAt(uint i, out PropertyKey k);
        void GetValue(ref PropertyKey k, out PropVariant v);
        void SetValue(ref PropertyKey k, ref PropVariant v);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Explicit)]
    struct PropVariant { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }

    public static void Create(string lnk, string target, string args, string workDir, string icon, string description, string appId) {
        var link = (IShellLinkW)new CShellLink();
        link.SetPath(target);
        link.SetArguments(args);
        link.SetWorkingDirectory(workDir);
        link.SetIconLocation(icon, 0);
        link.SetDescription(description);

        // System.AppUserModel.ID
        var key = new PropertyKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
        var value = new PropVariant { vt = 31 /* VT_LPWSTR */, p = Marshal.StringToCoTaskMemUni(appId) };
        var store = (IPropertyStore)link;
        store.SetValue(ref key, ref value);
        store.Commit();
        Marshal.FreeCoTaskMem(value.p);

        ((System.Runtime.InteropServices.ComTypes.IPersistFile)link).Save(lnk, true);
    }
}
"@

$pythonw = Join-Path $Root ".venv\Scripts\pythonw.exe"
$app = Join-Path $Root "app\desktop.py"
$icon = Join-Path $Root "gonilift.ico"
foreach ($p in @($pythonw, $app, $icon)) { if (-not (Test-Path $p)) { throw "Missing: $p" } }

$places = @([Environment]::GetFolderPath("Desktop"))
if ($StartMenu) { $places += Join-Path ([Environment]::GetFolderPath("Programs")) "" }
foreach ($dir in $places) {
    $lnk = Join-Path $dir "Gonilift.lnk"
    [GoniliftShortcut]::Create($lnk, $pythonw, "`"$app`"", $Root, $icon,
        "Gonilift: split songs into vocals and backing for singing practice", "JoemarkBasa.Gonilift")
    Write-Host "Shortcut: $lnk"
}
