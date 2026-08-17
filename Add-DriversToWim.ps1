# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
.SYNOPSIS
    Offline-services a WIM: injects a multi-model driver library, optionally
    applies updates, cleans the component store and exports a compressed image.

.DESCRIPTION
    Works for both an OS image (install.wim / your captured golden image) and a
    WinPE boot image (boot.wim). For a boot image, pass -BootImage: only the
    driver classes WinPE actually needs are injected (network, storage, chipset,
    USB controllers), which keeps the PE small and fast.

    The mount is always cleaned up: on any failure the image is dismounted with
    -Discard so you never leave a stale mount behind.

    IMPORTANT: this script commits changes to the WIM you point it at. Work on a
    copy of your master, or pass -WorkingCopy to have the script make one.

.PARAMETER WimPath
    The .wim to service.

.PARAMETER Index
    Image index inside the WIM. Default 1. (On untouched Microsoft install media,
    boot.wim index 2 is the Setup/PE image; a custom PE wim is usually index 1.)

.PARAMETER DriverRoot
    Root of the driver library produced by Export-ModelDrivers.ps1 -- a folder of
    per-model subfolders. Injected with recursion.

.PARAMETER Models
    Optional subset of model subfolder names. Omit to inject everything.

.PARAMETER BootImage
    Treat the target as WinPE: filter injected drivers to -BootDriverClasses.

.PARAMETER BootDriverClasses
    INF classes considered relevant to WinPE.

.PARAMETER ForceUnsigned
    Allow unsigned / non-WHQL drivers. Needed for some POS OEM packages.

.PARAMETER UpdatePath
    Optional folder of .msu/.cab updates, applied in filename order. Since
    February 2021 the Windows 10 SSU and LCU ship as one combined .msu, so a
    single file is the normal case. If you ever do need a specific order, name
    the files 01-..., 02-... or pass them one run at a time.

.PARAMETER Cleanup
    Run component store cleanup with /ResetBase before dismounting. Big size win.
    Note: after ResetBase the applied updates can no longer be uninstalled from
    the deployed OS. That is normally what you want in an image.

.PARAMETER ExportPath
    After committing, export to a new maximally-compressed WIM at this path.
    This is what you publish to WDS.

.PARAMETER WorkingCopy
    Copy WimPath next to itself as *.working.wim and service the copy instead,
    leaving the original untouched.

.PARAMETER MountPath
    Scratch mount folder. Default C:\WimMount.

.EXAMPLE
    # OS image: every model's drivers, latest CU, cleanup, publish
    .\Add-DriversToWim.ps1 -WimPath D:\Images\LTSC2021-Base.wim `
        -DriverRoot D:\Drivers -UpdatePath D:\Updates -Cleanup `
        -ExportPath D:\Images\LTSC2021-POS-2026-08.wim -WorkingCopy

.EXAMPLE
    # Boot image for WDS/PXE: NIC + storage only
    .\Add-DriversToWim.ps1 -WimPath D:\Images\boot.wim -Index 1 `
        -DriverRoot D:\Drivers -BootImage -ExportPath D:\Images\boot-POS.wim

.NOTES
    Run elevated, from an ADK Deployment and Imaging Tools Environment prompt so
    that the DISM in PATH is at least as new as the image you are servicing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WimPath,
    [int]      $Index = 1,
    [Parameter(Mandatory)] [string] $DriverRoot,
    [string[]] $Models,
    [switch]   $BootImage,
    [string[]] $BootDriverClasses = @('Net','SCSIAdapter','HDC','System','USB'),
    [switch]   $ForceUnsigned,
    [string]   $UpdatePath,
    [switch]   $Cleanup,
    [string]   $ExportPath,
    [switch]   $WorkingCopy,
    [string]   $MountPath = 'C:\WimMount'
)

$ErrorActionPreference = 'Stop'
$script:Mounted = $false

# ---------------------------------------------------------------- helpers ---
function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session.'
    }
}

function Write-Step { param([string] $Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Get-WorkingCopyPath {
    <#
        Where -WorkingCopy puts the copy. Same rule as the module's
        Get-WfWorkingCopyPath, kept here because this script is standalone on
        purpose -- it is the one that runs from a scheduled task on a reference
        machine, with no module to import.

        It was ChangeExtension($WimPath, 'working.wim'), which stacks: service
        something that is already a working copy and you get
        Win11IoTLTSC2024_FEC_XPOSH.working.working.wim, at exactly the moment
        anyone is trying to work out which of three similar names holds the real
        image. Stripping the suffix before adding it back would name the copy
        after the source, so a collision is renamed instead -- copying a file
        over itself is how an image ends up empty.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    # String work rather than [IO.Path], so the answer does not depend on which
    # separator the platform believes in. $dir keeps its trailing separator,
    # which is what makes the concatenation below safe for a bare file name.
    $leaf = @($Path -split '[\\/]')[-1]
    $dir  = $Path.Substring(0, $Path.Length - $leaf.Length)
    $stem = ($leaf -replace '\.[^.]+$', '') -replace '(?i)\.working(-\d+)?$', ''

    $copy = $dir + $stem + '.working.wim'
    if ($copy -eq $Path) { $copy = $dir + $stem + '.working-2.wim' }
    return $copy
}

function Get-InfClass {
    <# Reads the Class= line from an INF. Handles ANSI and Unicode INFs. #>
    param([string] $InfPath)
    try {
        $text = Get-Content -LiteralPath $InfPath -Raw -ErrorAction Stop
    } catch {
        return $null
    }
    $m = [regex]::Match($text, '(?im)^\s*Class\s*=\s*([A-Za-z0-9_]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Invoke-Dism {
    param([string[]] $Arguments)
    Write-Host "    dism.exe $($Arguments -join ' ')" -ForegroundColor DarkGray
    & dism.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dism.exe failed with exit code $LASTEXITCODE"
    }
}

# ------------------------------------------------------------ preparation ---
Assert-Elevated

if (-not (Test-Path -LiteralPath $WimPath))    { throw "WIM not found: $WimPath" }
if (-not (Test-Path -LiteralPath $DriverRoot)) { throw "Driver root not found: $DriverRoot" }
if ($UpdatePath -and -not (Test-Path -LiteralPath $UpdatePath)) {
    throw "Update path not found: $UpdatePath"
}

$WimPath = (Resolve-Path -LiteralPath $WimPath).Path

if ($WorkingCopy) {
    $copy = Get-WorkingCopyPath -Path $WimPath
    Write-Step "Copying master to working copy: $copy"
    Copy-Item -LiteralPath $WimPath -Destination $copy -Force
    # Copy-Item preserves the ReadOnly attribute; masters are often stored
    # read-only, which is exactly when -WorkingCopy is wanted.
    Set-ItemProperty -LiteralPath $copy -Name IsReadOnly -Value $false
    $WimPath = $copy
}
elseif ((Get-Item -LiteralPath $WimPath).IsReadOnly) {
    # Refuse to run against a read-only master by accident.
    throw "WIM is read-only: $WimPath. Clear the attribute, or re-run with -WorkingCopy."
}

# Boot images are where the wrong index silently costs you a hardware model:
# on Microsoft media, index 1 is the base WinPE and index 2 is Windows Setup --
# and index 2 is the one that actually boots. Show what is in the file first.
if ($BootImage) {
    Write-Step 'Boot image contents -- confirm you are targeting the right index'
    Get-WindowsImage -ImagePath $WimPath |
        Format-Table ImageIndex, ImageName, ImageSize -AutoSize | Out-String | Write-Host
    Write-Host "    Servicing index $Index." -ForegroundColor Yellow
}

if (-not (Test-Path $MountPath)) { New-Item -ItemType Directory -Path $MountPath -Force | Out-Null }
if ((Get-ChildItem -LiteralPath $MountPath -Force | Measure-Object).Count -gt 0) {
    throw "Mount folder is not empty: $MountPath. Run 'dism /Cleanup-Mountpoints' and clear it first."
}

# ------------------------------------------------------- select the drivers ---
Write-Step 'Building driver set'

$modelDirs = Get-ChildItem -LiteralPath $DriverRoot -Directory
if ($Models) {
    $modelDirs = $modelDirs | Where-Object { $_.Name -in $Models }
    $missing = $Models | Where-Object { $_ -notin $modelDirs.Name }
    if ($missing) { throw "Model folder(s) not found under ${DriverRoot}: $($missing -join ', ')" }
}
if (-not $modelDirs) { throw "No model subfolders found under $DriverRoot" }

Write-Host ("    Models: {0}" -f (($modelDirs.Name) -join ', '))

$infs = foreach ($dir in $modelDirs) {
    Get-ChildItem -LiteralPath $dir.FullName -Filter '*.inf' -Recurse -File |
        ForEach-Object {
            [pscustomobject]@{
                Model = $dir.Name
                Path  = $_.FullName
                Class = Get-InfClass $_.FullName
            }
        }
}

Write-Host ("    INF files found: {0}" -f ($infs | Measure-Object).Count)

$selected = $infs
if ($BootImage) {
    $selected = $infs | Where-Object { $_.Class -in $BootDriverClasses }
    Write-Host ("    Boot image mode -- keeping classes: {0}" -f ($BootDriverClasses -join ', ')) -ForegroundColor Yellow
    Write-Host ("    INF files selected: {0}" -f ($selected | Measure-Object).Count)
}

if (-not $selected) { throw 'No drivers selected -- nothing to do.' }

# ------------------------------------------------------------------- mount ---
try {
    Write-Step "Mounting index $Index of $WimPath"
    Mount-WindowsImage -ImagePath $WimPath -Index $Index -Path $MountPath | Out-Null
    $script:Mounted = $true

    $info = Get-WindowsImage -ImagePath $WimPath -Index $Index
    Write-Host ("    {0}  ({1})  build {2}" -f $info.ImageName, $info.Architecture, $info.Version)

    # --------------------------------------------------------------- updates ---
    if ($UpdatePath) {
        Write-Step 'Applying updates'
        $pkgs = Get-ChildItem -LiteralPath $UpdatePath -Include '*.msu','*.cab' -File -Recurse |
                Sort-Object Name
        if (-not $pkgs) { Write-Host '    No .msu/.cab found -- skipping.' -ForegroundColor Yellow }
        foreach ($p in $pkgs) {
            Write-Host "    + $($p.Name)"
            Add-WindowsPackage -Path $MountPath -PackagePath $p.FullName -ErrorAction Stop | Out-Null
        }
    }

    # --------------------------------------------------------------- drivers ---
    Write-Step ("Injecting {0} driver package(s)" -f ($selected | Measure-Object).Count)

    $added = 0; $failed = @()
    foreach ($inf in $selected) {
        $addArgs = @{ Path = $MountPath; Driver = $inf.Path }
        if ($ForceUnsigned) { $addArgs['ForceUnsigned'] = $true }
        try {
            Add-WindowsDriver @addArgs -ErrorAction Stop | Out-Null
            $added++
        } catch {
            $failed += [pscustomobject]@{
                Model = $inf.Model
                Inf   = Split-Path $inf.Path -Leaf
                Class = $inf.Class
                Error = $_.Exception.Message.Trim()
            }
        }
    }

    Write-Host ("    Added: {0}" -f $added) -ForegroundColor Green
    if ($failed) {
        Write-Host ("    Failed: {0}" -f $failed.Count) -ForegroundColor Red
        $failed | Format-Table -AutoSize | Out-String | Write-Host
        Write-Host '    Unsigned drivers need -ForceUnsigned. Architecture mismatches cannot be fixed.' -ForegroundColor Yellow
    }

    # --------------------------------------------------------------- cleanup ---
    if ($Cleanup) {
        Write-Step 'Component store cleanup (/ResetBase)'
        Invoke-Dism @('/Image:' + $MountPath, '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
    }

    # ---------------------------------------------------------------- commit ---
    Write-Step 'Dismounting and committing'
    Dismount-WindowsImage -Path $MountPath -Save | Out-Null
    $script:Mounted = $false
}
catch {
    if ($script:Mounted) {
        Write-Host ''
        Write-Host 'ERROR -- discarding the mount so nothing is left half-serviced.' -ForegroundColor Red
        try { Dismount-WindowsImage -Path $MountPath -Discard | Out-Null } catch {
            Write-Host "    Discard failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    Run: dism /Cleanup-Mountpoints" -ForegroundColor Yellow
        }
    }
    throw
}

# ------------------------------------------------------------------ export ---
if ($ExportPath) {
    Write-Step "Exporting compressed image to $ExportPath"
    if (Test-Path -LiteralPath $ExportPath) { Remove-Item -LiteralPath $ExportPath -Force }
    Export-WindowsImage -SourceImagePath $WimPath -SourceIndex $Index `
        -DestinationImagePath $ExportPath -CompressionType Max | Out-Null
    $final = $ExportPath
} else {
    $final = $WimPath
}

$sizeGb = [math]::Round((Get-Item -LiteralPath $final).Length / 1GB, 2)
Write-Host ''
Write-Host "Done. $final ($sizeGb GB)" -ForegroundColor Green
Write-Host "Verify with: Get-WindowsImage -ImagePath '$final' -Index $Index" -ForegroundColor DarkGray
