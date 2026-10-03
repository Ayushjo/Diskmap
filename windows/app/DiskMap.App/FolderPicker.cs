using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;

namespace DiskMap.App;

/// <summary>
/// Native Windows folder picker — IFileOpenDialog with FOS_PICKFOLDERS,
/// the same dialog Explorer's own pickers use. (WinForms' FolderBrowserDialog
/// is the dated tree-view picker; this is the modern one.)
/// </summary>
public static class FolderPicker
{
    private const uint FOS_PICKFOLDERS = 0x20;
    private const uint FOS_FORCEFILESYSTEM = 0x40;

    [ComImport]
    [Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] // CLSID_FileOpenDialog
    private class FileOpenDialogRCW { }

    [ComImport]
    [Guid("d57c7288-d4ad-4768-be02-9d969532d960")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog
    {
        // IModalWindow
        [PreserveSig] int Show(IntPtr parent);
        // IFileDialog
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IntPtr psi);
        void SetFolder(IntPtr psi);
        void GetFolder(out IntPtr ppsi);
        void GetCurrentSelection(out IntPtr ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName(out IntPtr pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IntPtr ppsi);
        void AddPlace(IntPtr psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        // IFileOpenDialog
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }

    [ComImport]
    [Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
    }

    private const uint SIGDN_FILESYSPATH = 0x80058000;

    /// <summary>Shows the picker; returns the chosen folder path or null.</summary>
    public static string? Pick(IntPtr ownerHwnd)
    {
        var dialog = (IFileOpenDialog)new FileOpenDialogRCW();
        try
        {
            dialog.SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
            dialog.SetTitle("Choose a folder to scan");
            if (dialog.Show(ownerHwnd) != 0) return null; // canceled
            dialog.GetResult(out IntPtr ppsi);
            if (ppsi == IntPtr.Zero) return null;
            var item = (IShellItem)Marshal.GetObjectForIUnknown(ppsi);
            Marshal.Release(ppsi);
            item.GetDisplayName(SIGDN_FILESYSPATH, out IntPtr pszPath);
            string? path = pszPath == IntPtr.Zero ? null : Marshal.PtrToStringUni(pszPath);
            if (pszPath != IntPtr.Zero) Marshal.FreeCoTaskMem(pszPath);
            Marshal.ReleaseComObject(item);
            return path;
        }
        finally
        {
            Marshal.ReleaseComObject(dialog);
        }
    }
}
