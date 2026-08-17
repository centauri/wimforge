# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
.SYNOPSIS
    Harvests the third-party (OEM) INF drivers from a reference machine into a
    per-model folder, ready for offline injection into a WIM.

.DESCRIPTION
    Run this on one known-good, fully-driven machine per hardware model.
    Export-WindowsDriver returns exactly the third-party drivers Windows has
    actually staged in the driver store -- not the whole vendor driver pack --
    which keeps the combined image small and avoids feeding the PnP ranker
    dozens of near-miss INFs.

    Output layout:
        <Destination>\<Vendor>_<Model>\<driver folders>
        <Destination>\<Vendor>_<Model>\_manifest.csv
        <Destination>\<Vendor>_<Model>\_system.json

    Can also run against an offline mounted image with -Path.

.PARAMETER Destination
    Root of the driver library. Defaults to .\Drivers next to the script.

.PARAMETER ModelName
    Override the auto-detected folder name (Vendor_Model).

.PARAMETER Path
    Optional path to a mounted offline Windows image. Omit to harvest the
    running machine.

.PARAMETER Force
    Overwrite an existing folder for this model instead of stopping.

.EXAMPLE
    .\Export-ModelDrivers.ps1 -Destination \\srv01\Imaging$\Drivers

.EXAMPLE
    .\Export-ModelDrivers.ps1 -ModelName 'HP_EngageOne_Pro' -Force

.NOTES
    Run elevated. Windows 8.1 / Server 2012 R2 and later.
#>
[CmdletBinding()]
param(
    [string] $Destination = (Join-Path $PSScriptRoot 'Drivers'),
    [string] $ModelName,
    [string] $Path,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Assert-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session.'
    }
}

function Get-SafeName {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'Unknown' }
    $clean = $Text -replace '[^A-Za-z0-9\.\-]+', '_'
    return $clean.Trim('_')
}

Assert-Elevated

# ---------------------------------------------------------------- identify ---
# In -Path (offline image) mode the local CIM data describes the technician's
# workstation, not the image, so none of it may be recorded as provenance.
if ($Path) {
    if (-not $ModelName) {
        throw '-ModelName is required with -Path: the local machine identity does not describe an offline image.'
    }
    $cs = $bios = $os = $null
}
else {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os   = Get-CimInstance Win32_OperatingSystem

    if (-not $ModelName) {
        $ModelName = '{0}_{1}' -f (Get-SafeName $cs.Manufacturer), (Get-SafeName $cs.Model)
    }
}

$modelPath = Join-Path $Destination $ModelName

if (Test-Path $modelPath) {
    if (-not $Force) {
        throw "Folder already exists: $modelPath. Re-run with -Force to replace it."
    }
    Write-Host "Removing existing $modelPath" -ForegroundColor Yellow
    Remove-Item -LiteralPath $modelPath -Recurse -Force
}

New-Item -ItemType Directory -Path $modelPath -Force | Out-Null

Write-Host ''
Write-Host "Model      : $ModelName"          -ForegroundColor Cyan
Write-Host "Source     : $(if ($Path) { $Path } else { 'running system' })"
Write-Host "Destination: $modelPath"
Write-Host ''

# ------------------------------------------------------------------ export ---
$exportArgs = @{ Destination = $modelPath }
if ($Path) { $exportArgs['Path'] = $Path } else { $exportArgs['Online'] = $true }

$drivers = Export-WindowsDriver @exportArgs

Write-Host ("Exported {0} driver package(s)." -f ($drivers | Measure-Object).Count) -ForegroundColor Green

# ---------------------------------------------------------------- manifest ---
$manifest = $drivers | Select-Object `
    @{n = 'InfName';       e = { if ($_.OriginalFileName) { Split-Path $_.OriginalFileName -Leaf } else { $_.Driver } }},
    @{n = 'PublishedName'; e = { $_.Driver }},
    ClassName,
    ProviderName,
    Version,
    Date,
    BootCritical,
    @{n = 'SourceInf';     e = { $_.OriginalFileName }}

$manifest | Sort-Object ClassName, ProviderName |
    Export-Csv -Path (Join-Path $modelPath '_manifest.csv') -NoTypeInformation -Encoding UTF8

# Computed outside the literal: Windows PowerShell 5.1's parser is stricter than
# 7's about statements used as hashtable values.
$source = 'running system'
if ($Path) { $source = "offline image: $Path" }

$system = [ordered]@{
    ModelFolder  = $ModelName
    Source       = $source
    DriverCount  = ($drivers | Measure-Object).Count
    HarvestedUtc = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
    HarvestedBy  = "$env:USERDOMAIN\$env:USERNAME"
}

if (-not $Path) {
    # Win32_OperatingSystem.Version is already major.minor.build; the UBR (patch
    # level) only lives in the registry, and it is the part worth recording.
    $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -ErrorAction SilentlyContinue).UBR
    $system['Manufacturer'] = $cs.Manufacturer
    $system['Model']        = $cs.Model
    $system['SystemSku']    = $cs.SystemSKUNumber
    $system['BiosVersion']  = $bios.SMBIOSBIOSVersion
    $system['BiosDate']     = $bios.ReleaseDate
    $system['SerialNumber'] = $bios.SerialNumber
    $system['OsCaption']    = $os.Caption
    $system['OsBuild']      = if ($ubr) { "$($os.Version).$ubr" } else { $os.Version }
}

[pscustomobject]$system | ConvertTo-Json |
    Set-Content -Path (Join-Path $modelPath '_system.json') -Encoding UTF8

# ------------------------------------------------------------------ report ---
Write-Host ''
Write-Host 'By driver class:' -ForegroundColor Cyan
$manifest | Group-Object ClassName | Sort-Object Count -Descending |
    Format-Table @{n='Class';e={$_.Name}}, Count -AutoSize

$bootCritical = $manifest | Where-Object { $_.ClassName -in 'SCSIAdapter','HDC','System','Net','USB' }
Write-Host ("Boot/network relevant (candidates for boot.wim): {0}" -f ($bootCritical | Measure-Object).Count) -ForegroundColor Yellow

$sizeMb = [math]::Round(((Get-ChildItem $modelPath -Recurse -File |
    Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host ("Folder size: {0} MB" -f $sizeMb)

# Devices still unhealthy on the reference machine -- fix these before harvesting
# is considered complete, otherwise you are baking a gap into the image.
if (-not $Path) {
    $bad = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
           Where-Object { $_.Status -ne 'OK' -and $_.Status -ne 'Unknown' }
    if ($bad) {
        Write-Host ''
        Write-Host 'WARNING: this reference machine has devices in a non-OK state:' -ForegroundColor Red
        $bad | Format-Table FriendlyName, Class, Status, InstanceId -AutoSize
        Write-Host 'Resolve these and re-run, or the image will inherit the same gaps.' -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "Done. $modelPath" -ForegroundColor Green
