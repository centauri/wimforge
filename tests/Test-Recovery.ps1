# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Recovery: what goes into the image, and what the generated scripts actually say.
#
# None of this can be run for real here -- reagentc, bcdedit, diskpart and a
# machine with partitions are all absent -- so what is checked is the two things
# that are checkable and that are also where the damage would be:
#
#   1. the files written into a mounted image are the right files, in the right
#      places, with the right encoding
#   2. the generated first-boot and WinPE scripts contain the safety checks they
#      are supposed to contain
#
# Point 2 is not busywork. A recovery script with the guard missing does not fail
# a syntax check and does not fail a smoke test: it works perfectly right up to
# the moment it formats the volume the image is sitting on, and then there is no
# machine left to read the log on.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

# --- the bits of the module these functions lean on -------------------------
$script:Logged  = New-Object System.Collections.Generic.List[object]
$script:History = New-Object System.Collections.Generic.List[object]

function Write-WfLog { param([string] $Message, [string] $Level = 'INFO', [switch] $NoConsole)
    $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message }) }
function Assert-WfElevated { }
function Get-WfConfig { @{ MountPath = $script:Mount } }
function Join-WfPath { param([string] $Base, [string] $Leaf) Join-Path $Base $Leaf }
function New-WfDirectory { param([AllowEmptyString()][string] $Path)
    if ($Path -and -not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    return $Path }
function Assert-WfPath { param([string] $Path, [string] $Label = 'Path')
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path }
function Format-WfSize { param([long] $Bytes) "{0:N0} B" -f $Bytes }
function Write-WfHistory { param($Action, $ImagePath, $Detail)
    $script:History.Add([pscustomobject]@{ Action = $Action; Detail = $Detail }) }

# Set-WfFirstBootScript belongs to Lockdown.ps1 and does its own thing; here it
# only needs to record that it was asked, and what with.
$script:FirstBoot = $null
function Set-WfFirstBootScript {
    param([string[]] $Command, [string] $ScriptFile, [string] $LogPath = 'C:\log.txt',
          [string] $MountPath, [switch] $Append)
    $script:FirstBoot = [pscustomobject]@{ Command = $Command; Append = [bool]$Append }
    return [pscustomobject]@{ Path = 'SetupComplete.cmd'; LogPath = $LogPath }
}

. (Join-Path $root 'WimForge\Public\Recovery.ps1')

$script:Mount = Join-Path ([IO.Path]::GetTempPath()) ('wf-rec-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $script:Mount 'Windows') -Force | Out-Null

function Reset-Fixture {
    $script:Logged.Clear(); $script:History.Clear(); $script:FirstBoot = $null
}

Write-Host 'ResetConfig.xml' -ForegroundColor Cyan
Reset-Fixture

$oemSrc = Join-Path ([IO.Path]::GetTempPath()) 'wf-rec-oem'
New-Item -ItemType Directory -Path (Join-Path $oemSrc 'Centric') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $oemSrc 'Centric\Provision.cmd') -Value '@echo off' -Force

$cfg = Set-WfResetConfig -Script @(
    @{ Phase = 'FactoryReset_AfterImageApply'; Path = 'Centric\Provision.cmd'; Duration = 5 }
) -ScriptSource $oemSrc -MountPath $script:Mount -Confirm:$false

$xmlPath = Join-Path $script:Mount 'Recovery\OEM\ResetConfig.xml'
Test-Case 'written where reset looks for it' $true (Test-Path -LiteralPath $xmlPath)
Test-Case 'and the script came with it' $true (Test-Path -LiteralPath (Join-Path $script:Mount 'Recovery\OEM\Centric\Provision.cmd'))

# The documentation is unusually direct about this: UTF-8, "do not use Unicode
# or ANSI". PowerShell 5.1's -Encoding UTF8 writes a BOM, which is exactly the
# thing being warned against, so the bytes are checked rather than the intent.
$bytes = [System.IO.File]::ReadAllBytes($xmlPath)
Test-Case 'no UTF-8 BOM' $false (($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF))
Test-Case 'not UTF-16 either' $false (($bytes[0] -eq 0xFF) -and ($bytes[1] -eq 0xFE))

$xml = [xml](Get-Content -LiteralPath $xmlPath -Raw)
Test-Case 'one Run element'   1 @($xml.Reset.Run).Count
Test-Case 'the phase is kept' 'FactoryReset_AfterImageApply' $xml.Reset.Run.Phase
Test-Case 'and the path'      'Centric\Provision.cmd'        $xml.Reset.Run.Path

Write-Host 'ResetConfig.xml refuses what reset would silently ignore' -ForegroundColor Cyan

$threw = $false
try { Set-WfResetConfig -Script @(@{ Phase = 'AfterEverything'; Path = 'x.cmd' }) `
        -MountPath $script:Mount -Confirm:$false } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Case 'an invented phase is refused' $true $threw
Test-Case 'and the four real ones are named' $true ([bool]($msg -match 'FactoryReset_AfterImageApply'))

# The one that actually costs a day: a config naming a script that was never
# copied. Reset accepts it and the miss only shows up mid-reset.
$threw = $false
try { Set-WfResetConfig -Script @(@{ Phase = 'BasicReset_AfterImageApply'; Path = 'NotThere\Missing.cmd' }) `
        -MountPath $script:Mount -Confirm:$false } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Case 'a script that is not there is refused' $true $threw
Test-Case 'and it is named'                       $true ([bool]($msg -match 'Missing\.cmd'))

$threw = $false
try { Set-WfResetConfig -Script @(@{ Phase = 'BasicReset_AfterImageApply'; Path = 'C:\Absolute.cmd' }) `
        -MountPath $script:Mount -Confirm:$false } catch { $threw = $true }
Test-Case 'an absolute path is refused' $true $threw

Write-Host 'Provisioning packages' -ForegroundColor Cyan
Reset-Fixture

$ppkgDir = Join-Path ([IO.Path]::GetTempPath()) 'wf-rec-ppkg'
New-Item -ItemType Directory -Path $ppkgDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ppkgDir 'TillApps.ppkg') -Value 'not really a ppkg' -Force
Set-Content -LiteralPath (Join-Path $ppkgDir 'Notes.txt')     -Value 'nor is this' -Force

$copied = @(Add-WfResetCustomization -Package (Join-Path $ppkgDir 'TillApps.ppkg') `
                                     -MountPath $script:Mount -Confirm:$false)
Test-Case 'copied one package' 1 $copied.Count
Test-Case 'into \Recovery\Customizations' $true `
    (Test-Path -LiteralPath (Join-Path $script:Mount 'Recovery\Customizations\TillApps.ppkg'))

$threw = $false
try { Add-WfResetCustomization -Package (Join-Path $ppkgDir 'Notes.txt') `
        -MountPath $script:Mount -Confirm:$false } catch { $threw = $true }
Test-Case 'anything not a .ppkg is refused' $true $threw

Write-Host 'Set-WfRecoveryImage catches the folder-versus-file mistake' -ForegroundColor Cyan
Reset-Fixture

$threw = $false
try { Set-WfRecoveryImage -Path 'R:\Recovery\WindowsRE\winre.wim' `
        -MountPath $script:Mount -Confirm:$false } catch { $threw = $true; $msg = $_.Exception.Message }
Test-Case 'the file itself is refused' $true $threw
Test-Case 'and the right path is suggested' $true ([bool]($msg -match 'R:\\Recovery\\WindowsRE'))

Write-Host 'The first-boot script says the things it has to say' -ForegroundColor Cyan
Reset-Fixture

$fb = New-WfRecoveryFirstBoot -TargetLabel 'WFRECOVERY' -RestoreLabel 'OSDisk' `
                              -ImageFile 'Plus-POS.wim' -BootImageFile 'boot.wim' `
                              -MountPath $script:Mount -Append -Confirm:$false

$script = Get-Content -LiteralPath $fb.ScriptPath -Raw

# Compared loosely on purpose: this test runs on whatever host is to hand, and
# Join-Path uses that host's separator. What matters is the folder and the name.
Test-Case 'it went into Setup\Scripts' $true `
    (($fb.ScriptPath -match 'Setup') -and ($fb.ScriptPath -match 'Scripts') -and ($fb.ScriptPath -like '*WimForge-Recovery.ps1'))
Test-Case 'and was hooked into SetupComplete' $true ($null -ne $script:FirstBoot)
Test-Case 'appending, not replacing'          $true $script:FirstBoot.Append

# The guard that matters most. Staging the payload on the volume the restore
# formats destroys the image partway through applying it, and leaves a machine
# with no operating system and nothing to fix it with.
Test-Case 'refuses the system volume' $true ($script -match '\$root -eq \$systemRoot')
Test-Case 'and says why'              $true ($script -match 'delete the image it is applying')

# A 500MB stock recovery partition takes the copy and runs out halfway.
Test-Case 'checks free space first'   $true ($script -match 'SizeRemaining')

# An entry per re-image is its own kind of unusable.
Test-Case 'does not add a duplicate entry' $true ($script -match 'Leaving it alone')

# Never the default. A till that boots to a restore prompt when nobody presses
# anything is worse than a till with no recovery at all.
Test-Case 'the entry goes last in the menu' $true ($script -match '/displayorder.*addlast')

# A half-built entry looks fine in bcdedit and does not boot.
Test-Case 'removes the entry if a step failed' $true ($script -match 'bcdedit /delete')

# The two guesses that would produce an entry that never boots.
Test-Case 'asks the BCD how the machine boots' $true ($script -match 'bcdedit /enum "\{bootmgr\}"')
Test-Case 'and looks inside the WinPE for winload' $true ($script -match 'Mount-WindowsImage')
Test-Case 'covering both winload locations' $true `
    ($script.Contains('Windows\System32\Boot\$loader') -and $script.Contains('Windows\System32\$loader'))

# boot.sdi is the one file everybody forgets, and without it the entry is inert.
Test-Case 'checks for boot.sdi' $true ($script -match 'boot\.sdi')
Test-Case 'and says where to get one' $true ($script -match 'ADK')

# Nothing here should be able to take out a working machine on its way past.
Test-Case 'every failure path returns rather than continuing' $true `
    (@([regex]::Matches($script, '(?m)^\s*return\s*$')).Count -ge 6)

Write-Host 'The generated script is valid PowerShell' -ForegroundColor Cyan

# It is assembled by string concatenation, which means a stray quote produces a
# script that is written successfully, hooked in successfully, and then fails to
# parse on the terminal at first boot, where nobody is watching.
$t = $null; $e = $null
[System.Management.Automation.Language.Parser]::ParseFile($fb.ScriptPath, [ref]$t, [ref]$e) | Out-Null
Test-Case 'it parses' @() @($e | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" })

Write-Host 'Values with quotes in them do not break it' -ForegroundColor Cyan
Reset-Fixture

$odd = New-WfRecoveryFirstBoot -TargetLabel "IT'S RECOVERY" -RestoreLabel "the till's disk" `
                               -ImageFile "O'Brien'POS.wim" -Description "the shop's restore" `
                               -MountPath $script:Mount -Confirm:$false
$e = $null
[System.Management.Automation.Language.Parser]::ParseFile($odd.ScriptPath, [ref]$t, [ref]$e) | Out-Null
Test-Case 'still parses with apostrophes everywhere' @() @($e | ForEach-Object { $_.Message })

Write-Host 'The recovery WinPE script' -ForegroundColor Cyan

# New-WfRecoveryBootImage mounts a real WIM, which cannot happen here. What can
# be checked is the batch it would write, which is built before the mount -- so
# the checks below read the source rather than running it.
$src = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Recovery.ps1') -Raw

# In WinPE the drive letters are not the letters Windows uses. A restore script
# that assumes C: formats the wrong partition the first time it meets a machine
# with a different disk layout.
Test-Case 'finds the destination by label, not by letter' $true ($src -match 'vol %%d: 2>nul \| find /i')
Test-Case 'and refuses to guess if no label matches'      $true ($src -match 'nothing safe to restore onto')

# WinPE only has PowerShell if somebody added the optional component.
Test-Case 'the WinPE side is batch, not PowerShell' $false ($src -match 'startnet[\s\S]{0,400}powershell')

# bcdboot against the restored volume, not the one that was there before.
Test-Case 'writes boot files against the restored volume' $true ($src -match 'bcdboot %WF_DST%\\Windows')

# A failed restore must not reboot into nothing with the screen cleared.
Test-Case 'a failed restore stops and says so' $true ($src -match 'NOT bootable in this state')

Write-Host 'The honest finding is written down where it will be read' -ForegroundColor Cyan

# This is the whole reason the feature is shaped the way it is. If the note goes
# missing, the next person reads the file and reaches for /setosimage.
Test-Case 'the file says /setosimage is not used on Windows 10 or later' $true `
    ($src -match "isn't used in Windows 10 or later")
Test-Case 'and Set-WfRecoveryImage points away from it' $true `
    ($src -match 'This is NOT the command for pointing reset at a custom OS image')

Remove-Item -LiteralPath $script:Mount -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $oemSrc  -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ppkgDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
