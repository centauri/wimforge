# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    NativeWim.ps1 -- pull a single file out of a WIM without mounting it.

    Mounting an image to read four registry values is a minute or two of work to
    answer a question that takes seconds. A DISM mount builds a full filesystem
    projection of every file in the image; all we ever wanted was one hive.

    wimgapi.dll is the library DISM and WDS themselves sit on, and it ships in
    System32 on every Windows that can service an image. WIMExtractImagePath
    pulls one path out of an image directly. No mount, no mount folder, no stale
    mount to clean up if something goes wrong halfway.

    Nothing here is load-bearing: every caller falls back to mounting if the
    extraction does not work, so an unexpected wimgapi on some future Windows
    costs speed rather than function.
#>

function Initialize-WfNativeWim {
    <#
        Compiles the P/Invoke surface once per session. Add-Type is slow enough
        (it runs the C# compiler) that doing it per call would give back a
        useful part of what the extraction saves.
    #>
    if ('WimForge.NativeWim' -as [type]) { return $true }

    $source = @'
using System;
using System.Runtime.InteropServices;

namespace WimForge
{
    public static class NativeWim
    {
        // wimgapi exports plain names -- there is no WIMCreateFileW to probe
        // for -- so every import is ExactSpelling. Strings are still Unicode:
        // the API is PCWSTR throughout.

        public const uint WIM_GENERIC_READ   = 0x80000000;
        public const uint WIM_OPEN_EXISTING  = 3;
        public const uint WIM_COMPRESS_NONE  = 0;

        [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        public static extern IntPtr WIMCreateFile(
            string pszWimPath, uint dwDesiredAccess, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, uint dwCompressionType, out uint pdwCreationResult);

        [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WIMSetTemporaryPath(IntPtr hWim, string pszPath);

        [DllImport("wimgapi.dll", ExactSpelling = true, SetLastError = true)]
        public static extern IntPtr WIMLoadImage(IntPtr hWim, uint dwImageIndex);

        [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WIMExtractImagePath(
            IntPtr hImage, string pszImagePath, string pszDestinationPath, uint dwExtractFlags);

        [DllImport("wimgapi.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WIMCloseHandle(IntPtr hObject);

        [DllImport("wimgapi.dll", ExactSpelling = true, SetLastError = true)]
        public static extern uint WIMGetImageCount(IntPtr hWim);

        /// <summary>
        /// Extracts one path from one image. Returns null on success, or a
        /// message naming the call that failed and its Win32 error.
        /// </summary>
        public static string ExtractPath(string wimPath, uint index, string sourcePath,
                                         string destinationPath, string tempPath)
        {
            IntPtr hWim   = IntPtr.Zero;
            IntPtr hImage = IntPtr.Zero;
            try
            {
                uint created;
                hWim = WIMCreateFile(wimPath, WIM_GENERIC_READ, WIM_OPEN_EXISTING,
                                     0, WIM_COMPRESS_NONE, out created);
                if (hWim == IntPtr.Zero)
                    return "WIMCreateFile failed (" + Marshal.GetLastWin32Error() + ")";

                // Required before anything reads image content: the library
                // needs somewhere to put its own scratch data.
                if (!WIMSetTemporaryPath(hWim, tempPath))
                    return "WIMSetTemporaryPath failed (" + Marshal.GetLastWin32Error() + ")";

                uint count = WIMGetImageCount(hWim);
                if (count == 0)
                    return "The file contains no images";
                if (index < 1 || index > count)
                    return "Index " + index + " is outside 1.." + count;

                hImage = WIMLoadImage(hWim, index);
                if (hImage == IntPtr.Zero)
                    return "WIMLoadImage failed (" + Marshal.GetLastWin32Error() + ")";

                if (!WIMExtractImagePath(hImage, sourcePath, destinationPath, 0))
                    return "WIMExtractImagePath failed (" + Marshal.GetLastWin32Error() + ")";

                return null;
            }
            finally
            {
                if (hImage != IntPtr.Zero) WIMCloseHandle(hImage);
                if (hWim   != IntPtr.Zero) WIMCloseHandle(hWim);
            }
        }
    }
}
'@

    try {
        Add-Type -TypeDefinition $source -ErrorAction Stop
        return $true
    }
    catch {
        Write-WfLog "The native WIM reader could not be compiled, so image reads will mount instead: $($_.Exception.Message)" -Level WARN
        return $false
    }
}

function Export-WfImageFile {
<#
.SYNOPSIS
    Extracts one file from a WIM without mounting it.
.DESCRIPTION
    Returns the destination path on success, or $null -- never throws. A caller
    that gets $null should fall back to mounting, which is the whole reason this
    reports failure instead of raising it.
.PARAMETER SourcePath
    Path inside the image, from its root: '\Windows\System32\config\SOFTWARE'.
.PARAMETER Destination
    Where to write it. The folder must already exist.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [int] $Index = 1,
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $Destination
    )

    if (-not (Test-Path -LiteralPath $ImagePath)) {
        Write-WfLog "Image not found: $ImagePath" -Level WARN
        return $null
    }
    if (-not (Initialize-WfNativeWim)) { return $null }

    # wimgapi wants a leading backslash on the in-image path.
    if ($SourcePath -notmatch '^[\\/]') { $SourcePath = '\' + $SourcePath }

    # Everything below is inside the try, including creating the scratch folder.
    # This function's contract is that it returns $null rather than throwing --
    # its callers fall back to mounting on $null and would die on an exception --
    # and setup work outside the try is exactly how that contract gets broken.
    $scratch = $null
    try {
        $tempRoot = $env:TEMP
        if (-not $tempRoot) { $tempRoot = [IO.Path]::GetTempPath() }

        $scratch = Join-WfPath $tempRoot ('WfWim-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $scratch -Force -ErrorAction Stop | Out-Null

        $problem = [WimForge.NativeWim]::ExtractPath($ImagePath, [uint32]$Index, $SourcePath, $Destination, $scratch)

        if ($problem) {
            Write-WfLog "Could not read $SourcePath out of $(Split-Path $ImagePath -Leaf) directly: $problem" -Level WARN
            return $null
        }
        if (-not (Test-Path -LiteralPath $Destination)) {
            Write-WfLog "The extraction reported success but produced no file at $Destination" -Level WARN
            return $null
        }

        return $Destination
    }
    catch {
        # An access violation in a P/Invoke would take the process down rather
        # than land here, so this is for the ordinary failures: a locked file, a
        # path that is too long, a disk that filled up.
        Write-WfLog "Direct read from $(Split-Path $ImagePath -Leaf) failed: $($_.Exception.Message)" -Level WARN
        return $null
    }
    finally {
        if ($scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
