# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
.SYNOPSIS
    Prepares a reference build inside the VM. Run in audit mode, elevated.

.DESCRIPTION
    Two stages, run at two different moments.

    -Stage Start  : run once, as soon as you land in audit mode and before you
                    install anything. Applies the settings that keep the build
                    deterministic and keep junk out of the driver store.

    -Stage PreSeal: run last, immediately before sysprep. Cleans out everything
                    that should not travel in an image, then optionally seals.

    The Start stage is the one people skip and regret. Without it, Windows Update
    quietly installs its own idea of a driver for the virtual hardware, hibernation
    reserves several GB of file that gets captured, and reserved storage eats
    another 7 GB -- all of which end up inside the WIM.

.PARAMETER Stage
    Start or PreSeal.

.PARAMETER Sysprep
    PreSeal only. Runs sysprep /generalize /oobe /shutdown at the end. Asks first.

.PARAMETER UnattendPath
    Answer file for sysprep. Defaults to unattend.xml next to this script.

.PARAMETER SkipComponentCleanup
    PreSeal only. Skips the online /ResetBase, which is the slowest step.

.EXAMPLE
    .\Prepare-ReferenceBuild.ps1 -Stage Start

.EXAMPLE
    .\Prepare-ReferenceBuild.ps1 -Stage PreSeal -Sysprep
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Start','PreSeal')] [string] $Stage,
    [switch] $Sysprep,
    [string] $UnattendPath,
    [switch] $SkipComponentCleanup
)

$ErrorActionPreference = 'Stop'

$id        = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this elevated.'
}

function Write-Step { param([string] $Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}
function Write-Ok   { param([string] $Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn { param([string] $Text) Write-Host "    $Text" -ForegroundColor Yellow }

function Set-WfRegValue {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Value,
        [string] $Type = 'DWord'
    )
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Ok "$Path\$Name = $Value"
}

# ===========================================================================
if ($Stage -eq 'Start') {

    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '   Reference build -- start of audit mode' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan

    # --- keep Windows Update out of the driver store ------------------------
    # This is the important one for a multi-model image. Left alone, Windows
    # Update installs drivers for whatever it thinks is present -- in a VM that
    # means generic virtual hardware drivers get staged and ranked, and they then
    # compete with the real vendor drivers you inject later.
    Write-Step 'Excluding drivers from Windows Update'
    Set-WfRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' `
                    -Name 'ExcludeWUDriversInQualityUpdate' -Value 1
    Set-WfRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' `
                    -Name 'SearchOrderConfig' -Value 0
    Set-WfRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' `
                    -Name 'DontSearchWindowsUpdate' -Value 1
    Set-WfRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata' `
                    -Name 'PreventDeviceMetadataFromNetwork' -Value 1

    # Apply the cumulative update offline with the toolkit instead. Same result,
    # but reproducible -- the image contains the CU you chose, not whatever was
    # current the afternoon someone built it.
    Write-Warn 'Apply the cumulative update offline afterwards (Servicing > Run servicing).'

    # --- hibernation ---------------------------------------------------------
    # hiberfil.sys is sized from RAM and gets captured into the WIM. Fast startup
    # also causes trouble on a target machine that is expected to actually shut down.
    Write-Step 'Disabling hibernation and fast startup'
    & powercfg.exe /hibernate off
    Set-WfRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                    -Name 'HiberbootEnabled' -Value 0

    # --- reserved storage ----------------------------------------------------
    # 21H2 reserves roughly 7 GB for servicing. On a target machine with a small
    # SSD that is worth reclaiming, and it inflates the captured image.
    Write-Step 'Disabling reserved storage'
    try {
        & dism.exe /Online /Set-ReservedStorageState /State:Disabled | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Reserved storage disabled' }
        else { Write-Warn "DISM returned $LASTEXITCODE -- reserved storage may not be in use on this build" }
    }
    catch { Write-Warn "Could not change reserved storage: $($_.Exception.Message)" }

    # --- power ---------------------------------------------------------------
    # A machine that sleeps mid-task is a support call.
    Write-Step 'Setting the power plan'
    try {
        & powercfg.exe /setactive SCHEME_MIN          # High performance
        & powercfg.exe /change standby-timeout-ac 0
        & powercfg.exe /change monitor-timeout-ac 0
        & powercfg.exe /change disk-timeout-ac 0
        Write-Ok 'High performance, no sleep, no disk or monitor timeout on AC'
    }
    catch { Write-Warn "powercfg: $($_.Exception.Message)" }

    # --- audit-mode housekeeping --------------------------------------------
    Write-Step 'Audit mode checks'
    $tag = 'C:\Windows\System32\Sysprep\Sysprep_succeeded.tag'
    if (Test-Path $tag) {
        Write-Warn 'A previous sysprep tag is present -- this VM has been generalized before.'
    }

    $state = (Get-ItemProperty 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' -ErrorAction SilentlyContinue).GeneralizationState
    if ($null -ne $state -and $state -ne 7) {
        Write-Warn "GeneralizationState is $state (7 = fully generalized/ready). Expected during audit mode."
    }

    Write-Host ''
    Write-Ok 'Start-stage preparation complete.'
    Write-Host ''
    Write-Host '   Now install, in this order:' -ForegroundColor Cyan
    Write-Host '     1. Runtimes and prerequisites (.NET, VC++ redistributables, WebView2)'
    Write-Host '     2. Your application stack'
    Write-Host '     3. Agents (management, monitoring), certificates, local policy baseline'
    Write-Host ''
    Write-Host '   Leave out anything model-specific, anything easier to deliver by software distribution,' -ForegroundColor DarkGray
    Write-Host '   and anything that needs a peripheral attached to install.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   Then snapshot BEFORE sealing -- that snapshot is the real master:' -ForegroundColor Yellow
    Write-Host "     Checkpoint-VM -Name '<vm>' -SnapshotName 'audit-mode pre-sysprep'" -ForegroundColor DarkGray
    Write-Host ''
}

# ===========================================================================
if ($Stage -eq 'PreSeal') {

    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '   Reference build -- pre-seal cleanup' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan

    Write-Host ''
    Write-Warn 'Have you snapshotted the VM in audit mode? Sysprep is not reversible.'
    Write-Host ''

    # --- stop Windows Update -------------------------------------------------
    # Sysprep fails outright if an update is mid-installation, and the error it
    # gives points nowhere useful.
    Write-Step 'Stopping Windows Update'
    foreach ($svc in 'wuauserv','bits','dosvc') {
        try {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Ok "$svc stopped"
        }
        catch { Write-Warn "$svc -- $($_.Exception.Message)" }
    }

    # --- component store -----------------------------------------------------
    if (-not $SkipComponentCleanup) {
        Write-Step 'Component store cleanup (/ResetBase) -- this takes a while'
        & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Component store reset' }
        else { Write-Warn "DISM returned $LASTEXITCODE" }
    }

    # --- temp and caches -----------------------------------------------------
    Write-Step 'Clearing temp folders'
    foreach ($p in @($env:TEMP, 'C:\Windows\Temp', 'C:\Windows\Prefetch')) {
        if (Test-Path -LiteralPath $p) {
            Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok $p
        }
    }

    Write-Step 'Clearing Windows Update download cache'
    try {
        $sd = 'C:\Windows\SoftwareDistribution\Download'
        if (Test-Path $sd) {
            Get-ChildItem -LiteralPath $sd -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok $sd
        }
    }
    catch { Write-Warn $_.Exception.Message }

    # --- event logs ----------------------------------------------------------
    # Otherwise every machine deploys carrying the reference machine's history,
    # which makes the first real incident harder to read.
    Write-Step 'Clearing event logs'
    $cleared = 0
    foreach ($log in (Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
                      Where-Object { $_.RecordCount -gt 0 })) {
        try {
            [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($log.LogName)
            $cleared++
        }
        catch { }
    }
    Write-Ok "$cleared log(s) cleared"

    # --- a last look at the driver store -------------------------------------
    # Anything third-party in here came from somewhere. In a clean VM build the
    # answer should be "nothing", and anything listed is worth explaining before
    # it becomes part of every machine.
    Write-Step 'Third-party drivers currently staged'
    $oem = @(Get-WindowsDriver -Online -ErrorAction SilentlyContinue | Where-Object { -not $_.Inbox })
    if ($oem.Count -eq 0) {
        Write-Ok 'None -- the driver store is clean, which is what a VM build should look like'
    }
    else {
        Write-Warn "$($oem.Count) third-party driver(s) present:"
        $oem | Select-Object Driver, ClassName, ProviderName, Version |
            Format-Table -AutoSize | Out-String | Write-Host
        Write-Warn 'Expected in a VM build: nothing. Anything here will be captured into the image.'
    }

    # --- disk usage ----------------------------------------------------------
    $free = (Get-PSDrive -Name C).Free / 1GB
    $used = (Get-PSDrive -Name C).Used / 1GB
    Write-Step 'Disk'
    Write-Host ("    C: {0:N1} GB used, {1:N1} GB free" -f $used, $free)

    # --- seal ----------------------------------------------------------------
    Write-Host ''
    if (-not $Sysprep) {
        Write-Host '   Cleanup done. To seal:' -ForegroundColor Cyan
        Write-Host '     .\Prepare-ReferenceBuild.ps1 -Stage PreSeal -Sysprep' -ForegroundColor DarkGray
        Write-Host '   or by hand:' -ForegroundColor Cyan
        Write-Host '     C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:<file>' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    if (-not $UnattendPath) { $UnattendPath = Join-Path $PSScriptRoot 'unattend.xml' }
    if (-not (Test-Path -LiteralPath $UnattendPath)) {
        throw "Answer file not found: $UnattendPath"
    }

    # Well-formedness only -- a malformed answer file makes sysprep fail in a way
    # that reads like a Windows problem rather than a typo.
    try { [xml](Get-Content -LiteralPath $UnattendPath -Raw) | Out-Null }
    catch { throw "Answer file is not valid XML: $($_.Exception.Message)" }

    if ((Get-Content -LiteralPath $UnattendPath -Raw) -match '<SkipRearm>\s*1\s*</SkipRearm>') {
        Write-Warn 'SkipRearm=1 is set in the answer file.'
        Write-Warn 'Correct while iterating on the reference VM; remove it for the final sealed build.'
    }

    Write-Host ''
    Write-Host "   About to run sysprep /generalize /oobe /shutdown" -ForegroundColor Yellow
    Write-Host "   with $UnattendPath" -ForegroundColor Yellow
    Write-Host '   The VM will shut down and MUST NOT be booted again before capture.' -ForegroundColor Yellow
    Write-Host ''
    $answer = Read-Host '   Type SEAL to continue'
    if ($answer -cne 'SEAL') {
        Write-Host '   Cancelled.' -ForegroundColor Cyan
        return
    }

    Write-Step 'Sealing'
    & C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:"$UnattendPath"
}
