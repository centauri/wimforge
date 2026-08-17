# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
.SYNOPSIS
    Creates the Hyper-V reference VM the POS base image is built in.

.DESCRIPTION
    Run this on the Hyper-V host, elevated. It creates a Generation 2 VM
    configured the way an imaging reference build wants to be configured, which
    is not the way Hyper-V configures one by default.

    What differs from the defaults, and why:

    * Automatic checkpoints OFF. Windows 10/11 Hyper-V turns these on for new
      VMs. They fire on every start, and one taken mid-sysprep is a corrupt
      reference build you will not notice until capture.

    * Standard checkpoints, not Production. Production checkpoints use VSS
      inside the guest to get an application-consistent state -- which is exactly
      wrong here, because the state you want to snapshot is a machine sitting in
      audit mode that has never completed OOBE.

    * Fixed memory, no dynamic memory. Sysprep and DISM against a ballooning
      guest is a source of intermittent, unreproducible failures.

    * No integration components to install. Hyper-V's synthetic drivers are
      in-box in Windows 10, so a Gen 2 VM contributes nothing third-party to the
      driver store. That is the whole point of building in a VM: the captured
      image has no physical model's drivers ranked ahead of the ones you inject.

.PARAMETER Name
    VM name. Also used for the folder and disk name.

.PARAMETER IsoPath
    The Windows 10 IoT Enterprise LTSC 2021 installation media.

.PARAMETER Path
    Where the VM and its disk are created.

.PARAMETER SwitchName
    Virtual switch to attach. Omit for no network -- see the note below.

.PARAMETER MemoryGB
    Fixed startup memory. 4 GB is plenty for an LTSC reference build.

.PARAMETER VhdSizeGB
    Virtual disk size. Dynamically expanding, so this is a ceiling not an
    allocation. 80 GB leaves room for the app stack and the component store
    before cleanup.

.EXAMPLE
    .\New-ReferenceVM.ps1 -IsoPath D:\ISO\LTSC2021.iso -Path E:\VMs -SwitchName 'Default Switch'

.NOTES
    Network: attaching a switch is convenient for installing the app stack from
    a share, but it also lets Windows Update pull drivers and feature updates
    into the reference build non-deterministically. Prepare-ReferenceBuild.ps1
    -Stage Start turns the driver side of that off inside the guest. Apply the
    cumulative update offline afterwards with the toolkit instead, so the image
    is reproducible.
#>
[CmdletBinding()]
param(
    [string] $Name       = 'LTSC2021-POS-Reference',
    [Parameter(Mandatory)] [string] $IsoPath,
    [string] $Path,
    [string] $SwitchName,
    [int]    $MemoryGB   = 4,
    [int]    $VhdSizeGB  = 80,
    [int]    $CpuCount   = 2
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------- guards --
$id        = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this elevated -- Hyper-V management requires it.'
}

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'The Hyper-V PowerShell module is not present. Enable the Hyper-V Management Tools feature.'
}

if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath" }

if (-not $Path) {
    $Path = (Get-VMHost).VirtualMachinePath
}
if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    throw "A VM named '$Name' already exists. Remove it first, or pass a different -Name."
}

$vhdPath = Join-Path $Path ("$Name.vhdx")
if (Test-Path -LiteralPath $vhdPath) {
    throw "Disk already exists: $vhdPath"
}

function Write-Step { param([string] $Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

# -------------------------------------------------------------------- build --
Write-Step "Creating VM '$Name'"

$newVmArgs = @{
    Name               = $Name
    Generation         = 2
    MemoryStartupBytes = ($MemoryGB * 1GB)
    NewVHDPath         = $vhdPath
    NewVHDSizeBytes    = ($VhdSizeGB * 1GB)
    Path               = $Path
}
if ($SwitchName) { $newVmArgs['SwitchName'] = $SwitchName }

$vm = New-VM @newVmArgs
Write-Host "    $vhdPath ($VhdSizeGB GB, dynamically expanding)"

Write-Step 'Applying imaging-appropriate settings'

# Fixed memory. A ballooning guest during sysprep or DISM produces failures that
# do not reproduce, which is the worst kind to chase.
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB * 1GB)
Write-Host "    memory      : $MemoryGB GB fixed"

Set-VMProcessor -VMName $Name -Count $CpuCount
Write-Host "    processors  : $CpuCount"

# The two checkpoint settings that matter. Automatic checkpoints fire on every
# start; one taken mid-sysprep gives you a reference build that is quietly wrong.
Set-VM -Name $Name -AutomaticCheckpointsEnabled $false -CheckpointType Standard
Write-Host '    checkpoints : automatic OFF, type Standard'

# Nothing should start this VM except you.
Set-VM -Name $Name -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
Write-Host '    autostart   : off'

Write-Step 'Attaching the installation media'
Add-VMDvdDrive -VMName $Name -Path $IsoPath
$dvd = Get-VMDvdDrive -VMName $Name
Write-Host "    $IsoPath"

Write-Step 'Setting the boot order'
# Boot the DVD first for the install; the disk takes over once Windows is on it.
Set-VMFirmware -VMName $Name -FirstBootDevice $dvd

# Secure Boot on with the Microsoft Windows template matches how the POS
# hardware is configured, so anything that would trip over Secure Boot trips
# over it here rather than in a store.
Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
Write-Host '    secure boot : on (MicrosoftWindows template)'

if (-not $SwitchName) {
    Write-Host ''
    Write-Host '    No virtual switch attached. Add one when you need to reach a share:' -ForegroundColor Yellow
    Write-Host "      Connect-VMNetworkAdapter -VMName '$Name' -SwitchName 'Default Switch'" -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ summary --
Write-Host ''
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
Write-Host "   VM ready: $Name" -ForegroundColor Green
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '   Next:' -ForegroundColor Cyan
Write-Host "     1. Start-VM -Name '$Name'  and connect with vmconnect"
Write-Host '     2. Install Windows 10 IoT Enterprise LTSC 2021 as normal'
Write-Host '     3. At the FIRST OOBE screen press Ctrl+Shift+F3'
Write-Host '        -- this reboots into audit mode as the built-in Administrator,'
Write-Host '           with no user profile created. Do not click through OOBE.'
Write-Host '     4. Inside the VM, run Prepare-ReferenceBuild.ps1 -Stage Start'
Write-Host '     5. Install the app stack, certificates and policy'
Write-Host "     6. Checkpoint-VM -Name '$Name' -SnapshotName 'audit-mode pre-sysprep'"
Write-Host '        -- that snapshot is your real master; keep it'
Write-Host '     7. Prepare-ReferenceBuild.ps1 -Stage PreSeal -Sysprep'
Write-Host '     8. On the host, capture with the toolkit:'
Write-Host "        New-WfCapture -VhdxPath '$vhdPath' -Notes 'initial build'"
Write-Host ''
Write-Host '   Full procedure: Reference-Build-Checklist.md' -ForegroundColor DarkGray
Write-Host ''

return [pscustomobject]@{
    Name    = $Name
    VhdPath = $vhdPath
    Path    = $Path
    MemoryGB = $MemoryGB
    Switch  = $SwitchName
}
