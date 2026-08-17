# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Device lockdown and the first-boot seam.
#
# The invariant that matters most here is an ordering one: UWF must be enabled
# LAST in the generated script. Once the write filter is on and the machine
# reboots, everything written after that point is gone -- so enabling it before
# the keyboard and shell configuration would silently discard them, and it would
# look exactly like the settings never applied.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Public\Lockdown.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

$mount = Join-Path ([IO.Path]::GetTempPath()) ('wf-mount-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path (Join-Path $mount 'Windows\Setup') -Force | Out-Null

function Get-WfConfig      { @{ MountPath = $script:MountPath } }
function Write-WfLog       { param([string]$Message, [string]$Level) $script:Logged += @("$Level|$Message") }
function Assert-WfElevated { }
function Write-WfHistory   { param($Action, $ImagePath, $Detail, $Notes) }
function Join-WfPath       { param([string]$Path, [string]$ChildPath) return (Join-Path $Path $ChildPath) }
function New-WfDirectory   { param([string]$Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null; return $Path }
function Assert-WfPath     { param([string]$Path, [string]$Label) if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }; return $Path }

$script:MountPath = $mount
$script:Logged    = @()

# ------------------------------------------------------- the first-boot script
Write-Host 'SetupComplete.cmd' -ForegroundColor Cyan
$r = Set-WfFirstBootScript -MountPath $mount -Command 'net localgroup Administrators /add DOMAIN\POSAdmins' -Confirm:$false
$cmd = Get-Content -LiteralPath $r.Path -Raw
$lines = @(Get-Content -LiteralPath $r.Path)

# Separator-agnostic: these tests run under pwsh on Linux too, where Join-Path
# builds forward slashes. The path SHAPE is what matters, not the slashes.
Test-Case 'written where Windows looks for it' $true `
    ([bool](($r.Path -replace '/', '\') -like '*Windows\Setup\Scripts\SetupComplete.cmd'))
Test-Case 'starts silent'      '@echo off' $lines[0]
Test-Case 'the command is in it' $true ([bool]($cmd -match 'net localgroup Administrators'))
Test-Case 'output is captured'   $true ([bool]($cmd -match '>> "%WF_LOG%" 2>&1'))
# Windows deletes the script after it runs, so a log inside Setup\Scripts would
# go with it.
Test-Case 'logs outside the Scripts folder' $true ([bool]($cmd -match 'set WF_LOG=C:\\Windows\\Temp\\'))
Test-Case 'exits zero'         $true ([bool]($cmd -match 'exit /b 0'))

# ASCII, no BOM: the command processor reads this before any locale is set, and
# a BOM on line 1 stops @echo off working.
$bytes = [IO.File]::ReadAllBytes($r.Path)
Test-Case 'no byte order mark' $true (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))

Test-Case 'ErrorHandler.cmd too' $true (Test-Path -LiteralPath (Join-Path $mount 'Windows\Setup\Scripts\ErrorHandler.cmd'))

Write-Host 'A .ps1 is copied in and run non-interactively' -ForegroundColor Cyan
$payload = Join-Path ([IO.Path]::GetTempPath()) 'wf-provision.ps1'
Set-Content -LiteralPath $payload -Value '"hello"' -Force
$r2 = Set-WfFirstBootScript -MountPath $mount -ScriptFile $payload -Confirm:$false
$cmd2 = Get-Content -LiteralPath $r2.Path -Raw
Test-Case 'copied into the image' $true (Test-Path -LiteralPath (Join-Path $mount 'Windows\Setup\Scripts\wf-provision.ps1'))
# Without -NonInteractive a stray Read-Host waits forever on a machine with no
# desktop to type into.
Test-Case 'non-interactive'      $true ([bool]($cmd2 -match '-NonInteractive'))
Test-Case 'bypasses policy'      $true ([bool]($cmd2 -match '-ExecutionPolicy Bypass'))

Write-Host 'Appending keeps what was already there' -ForegroundColor Cyan
$before = @(Get-Content -LiteralPath $r2.Path).Count
$r3 = Set-WfFirstBootScript -MountPath $mount -Command 'echo second' -Append -Confirm:$false
$cmd3 = Get-Content -LiteralPath $r3.Path -Raw
Test-Case 'kept the first command' $true ([bool]($cmd3 -match 'wf-provision.ps1'))
Test-Case 'added the second'       $true ([bool]($cmd3 -match 'echo second'))
Test-Case 'reported as appended'   $true $r3.Appended
# One header only: a second "> %WF_LOG%" would truncate the log the first half
# had already written to.
Test-Case 'log opened once'        1 ([regex]::Matches($cmd3, '(?<!>)> "%WF_LOG%"').Count)

Write-Host 'Refuses to write nothing' -ForegroundColor Cyan
$threw = $false
try { Set-WfFirstBootScript -MountPath $mount -Confirm:$false } catch { $threw = $true }
Test-Case 'threw' $true $threw

# --------------------------------------------------------- the lockdown script
Write-Host 'Lockdown script: UWF goes last' -ForegroundColor Cyan
Remove-Item -LiteralPath (Join-Path $mount 'Windows\Setup\Scripts\SetupComplete.cmd') -Force
$r4 = New-WfLockdownFirstBoot -MountPath $mount -Confirm:$false `
        -ProtectVolume 'C:' -Exclusion 'C:\POS\Logs','C:\POS\Data' `
        -BlockKey 'Ctrl+Alt+Del','Alt+Tab','Windows' -ShellLauncherShell 'C:\POS\Till.exe'

$script = Get-Content -LiteralPath $r4.ScriptPath -Raw

$posKeyboard = $script.IndexOf('WEKF_PredefinedKey')
$posShell    = $script.IndexOf('WESL_UserSetting')
$posExclude  = $script.IndexOf('add-exclusion')
$posProtect  = $script.IndexOf('volume protect')
$posEnable   = $script.IndexOf('filter enable')

Test-Case 'keyboard filter is configured' $true ($posKeyboard -gt 0)
Test-Case 'shell launcher is configured'  $true ($posShell    -gt 0)
Test-Case 'exclusions are configured'     $true ($posExclude  -gt 0)

# The whole point. Anything after "filter enable" is discarded at the next
# reboot, so it has to be the final act.
Test-Case 'keyboard filter before the filter is enabled' $true ($posKeyboard -lt $posEnable)
Test-Case 'shell launcher before it too'                 $true ($posShell    -lt $posEnable)
Test-Case 'exclusions before it'                         $true ($posExclude  -lt $posEnable)
Test-Case 'volume protected before it'                   $true ($posProtect  -lt $posEnable)
Test-Case 'nothing after but a log line' $true ([bool]($script.Substring($posEnable) -notmatch 'uwfmgr.exe (volume|file) '))

Write-Host 'What it was asked for is what it configures' -ForegroundColor Cyan
Test-Case 'both exclusions'  2 ([regex]::Matches($script, 'add-exclusion').Count)
Test-Case 'all three keys'   $true ([bool](($script -match 'Ctrl\+Alt\+Del') -and ($script -match 'Alt\+Tab') -and ($script -match "'Windows'")))
Test-Case 'the shell'        $true ([bool]($script -match [regex]::Escape('C:\POS\Till.exe')))
Test-Case 'wired into SetupComplete.cmd' $true ([bool]((Get-Content -LiteralPath $r4.SetupComplete -Raw) -match 'WimForge-Lockdown.ps1'))

Write-Host 'Warns when a write filter has no exclusions' -ForegroundColor Cyan
# A till that discards its own transaction log every night is worse than no
# write filter at all.
Remove-Item -LiteralPath (Join-Path $mount 'Windows\Setup\Scripts\SetupComplete.cmd') -Force
$script:Logged = @()
$null = New-WfLockdownFirstBoot -MountPath $mount -ProtectVolume 'C:' -Confirm:$false
Test-Case 'said so' $true ([bool]($script:Logged -match 'Every write to the protected volume will be discarded'))

Write-Host 'Refuses to generate an empty script' -ForegroundColor Cyan
$threw2 = $false
try { New-WfLockdownFirstBoot -MountPath $mount -Confirm:$false } catch { $threw2 = $true }
Test-Case 'threw' $true $threw2

Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
