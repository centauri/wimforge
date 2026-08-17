# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Regional settings, OEM identity, local policy, and taking things out.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Public\Regional.ps1')
. (Join-Path $root 'WimForge\Public\Slimming.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

$mount = Join-Path ([IO.Path]::GetTempPath()) ('wf-rs-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $mount -Force | Out-Null

$script:DismArgs = @()
$script:Logged   = @()
$script:RegEdits = @()
$script:Intl     = @'
Reporting offline international settings.

Default system UI language : en-US
System locale : nl-NL
Default time zone : W. Europe Standard Time
User locale for default user : nl-NL
Active keyboard(s) : 0413:00020409
Installed language(s): en-US
  Type : Fully localized language
'@

function Get-WfConfig      { @{ MountPath = $mount; ScratchPath = $mount; BootDriverClasses = @('Net','SCSIAdapter') } }
function Write-WfLog       { param([string]$Message, [string]$Level) $script:Logged += @("$Level|$Message") }
function Assert-WfElevated { }
function Join-WfPath       { param([string]$Path, [string]$ChildPath) return (Join-Path $Path $ChildPath) }
function New-WfDirectory   { param([string]$Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null; return $Path }
function Assert-WfPath     { param([string]$Path, [string]$Label) if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }; return $Path }
function Write-WfHistory   { param($Action, $ImagePath, $Detail, $Notes) }
function Format-WfSize     { param($Bytes) "$Bytes bytes" }
function Invoke-WfDism {
    param([string[]]$Arguments, [switch]$PassThruOutput)
    $script:DismArgs += ,@($Arguments)
    if ($PassThruOutput) { return ($script:Intl -split "`n") }
}
function Invoke-WfRegistryEdit {
    param([string[]]$RegFile, [scriptblock]$Action, [string]$MountPath)
    # Good enough to observe what would be written: the real one loads hives.
    $script:RegEdits += ,$Action
}

# ------------------------------------------------------------------- locale
Write-Host 'Reading the locale back' -ForegroundColor Cyan
$now = Get-WfImageLocale -MountPath $mount
Test-Case 'UI language'   'en-US' $now.UILanguage
Test-Case 'system locale' 'nl-NL' $now.SystemLocale
Test-Case 'user locale'   'nl-NL' $now.UserLocale
Test-Case 'keyboard'      '0413:00020409' $now.InputLocale

Write-Host 'Setting only what was asked for' -ForegroundColor Cyan
$script:DismArgs = @()
$null = Set-WfImageLocale -MountPath $mount -UILanguage 'en-US' -UserLocale 'nl-NL' -Confirm:$false

$flat = @($script:DismArgs | ForEach-Object { $_ -join ' ' })
Test-Case 'UI language set'   $true ([bool](@($flat) -match '/Set-UILang:en-US'))
Test-Case 'user locale set'   $true ([bool](@($flat) -match '/Set-UserLocale:nl-NL'))
# The two not asked for must not be touched: setting a system locale nobody
# asked for changes the ANSI code page under every non-Unicode program.
Test-Case 'system locale untouched' $false ([bool](@($flat) -match '/Set-SysLocale'))
Test-Case 'time zone untouched'     $false ([bool](@($flat) -match '/Set-TimeZone'))
# Trust the read-back, not the exit code.
Test-Case 'read back afterwards'    $true ([bool](@($flat) -match '/Get-Intl'))

Write-Host 'Refuses to do nothing' -ForegroundColor Cyan
$threw = $false
try { Set-WfImageLocale -MountPath $mount -Confirm:$false } catch { $threw = $true }
Test-Case 'threw' $true $threw

Write-Host 'A UI language the image does not have is refused first' -ForegroundColor Cyan

# It used to be attempted and explained afterwards, which was the wrong order.
# The settings are applied one at a time, so asking for a Dutch UI and Dutch
# formats set the formats, failed on the language, and left the image in a state
# nobody asked for. DISM is unambiguous -- "if the language is not installed in
# the Windows image, the command will fail" -- so there is nothing to gain by
# trying. The stub image reports en-US and nothing else.
$script:DismArgs = @(); $script:Logged = @()
$msg = ''
try { Set-WfImageLocale -MountPath $mount -UILanguage 'fr-FR' -UserLocale 'fr-FR' -Confirm:$false }
catch { $msg = $_.Exception.Message }

Test-Case 'it refuses'            $true ([bool]($msg -match 'does not have the fr-FR display language'))
Test-Case 'and says what is there' $true ([bool]($msg -match 'It has: en-us'))
Test-Case 'and where to get one'  $true ([bool]($msg -match 'Add-WfLanguage'))

# The format operator binds to the string on its left, so "a" + "b" -f $x
# formats only "b" -- and the first placeholder ships as a literal {0}. It did.
Test-Case 'the message is formatted, not literal' $false ([bool]($msg -match '\{0\}'))

# Nothing was applied. That is the whole point of checking first.
$flat2 = @($script:DismArgs | ForEach-Object { $_ -join ' ' })
Test-Case 'nothing was set' $false ([bool](@($flat2) -match '/Set-'))

# --------------------------------------------------------------------- OEM
Write-Host 'OEM information' -ForegroundColor Cyan
$script:RegEdits = @()
$oem = Set-WfOemInformation -MountPath $mount -Manufacturer 'Centric' -Model 'POS 2026' `
                            -SupportPhone '+31 000' -Confirm:$false
Test-Case 'three values' 3 (@($oem.PSObject.Properties).Count)
Test-Case 'one registry edit' 1 $script:RegEdits.Count

$threw2 = $false
try { Set-WfOemInformation -MountPath $mount -Confirm:$false } catch { $threw2 = $true }
Test-Case 'refuses to write nothing' $true $threw2

Write-Host 'A logo that is not in the image is called out' -ForegroundColor Cyan
$script:Logged = @()
$null = Set-WfOemInformation -MountPath $mount -Logo 'C:\Branding\logo.bmp' -Confirm:$false
Test-Case 'warned' $true ([bool]($script:Logged -match 'not in the image yet'))

# ------------------------------------------------------------ local policy
Write-Host 'Local policy must actually be a policy file' -ForegroundColor Cyan
$notPol = Join-Path $mount 'notapol.pol'
Set-Content -LiteralPath $notPol -Value 'Windows Registry Editor Version 5.00' -Force
$msg = ''
try { Set-WfLocalPolicy -MountPath $mount -MachinePolicy $notPol -Confirm:$false } catch { $msg = $_.Exception.Message }
# A .reg copied here would be silently ignored by Windows forever.
Test-Case 'rejected'      $true ([bool]($msg -match "not a Registry.pol"))
Test-Case 'says what it saw' $true ([bool]($msg -match "starts with 'Wind'"))

Write-Host 'A real one is accepted' -ForegroundColor Cyan
$realPol = Join-Path $mount 'real.pol'
$bytes = [byte[]]@(0x50,0x52,0x65,0x67,0x01,0x00,0x00,0x00) + (New-Object byte[] 32)
[IO.File]::WriteAllBytes($realPol, $bytes)
$r = Set-WfLocalPolicy -MountPath $mount -MachinePolicy $realPol -Confirm:$false
Test-Case 'applied'        @('computer') $r.Applied
Test-Case 'landed in the right place' $true `
    (Test-Path -LiteralPath (Join-Path $mount 'Windows/System32/GroupPolicy/Machine/Registry.pol'))

Write-Host 'Replacing an existing policy says so' -ForegroundColor Cyan
# Not merged -- a .pol is one binary blob, and quietly replacing one that has
# settings in it is how a baseline goes missing.
$script:Logged = @()
$null = Set-WfLocalPolicy -MountPath $mount -MachinePolicy $realPol -Confirm:$false
Test-Case 'warned' $true ([bool]($script:Logged -match 'not merged, they are gone'))

# ---------------------------------------------------------------- slimming
Write-Host 'Provisioned apps: only what was named' -ForegroundColor Cyan
$script:Apps = @(
    [pscustomobject]@{ DisplayName='Microsoft.XboxGameOverlay'; PackageName='xbox_1'; Version='1.0'; PublisherId='p' },
    [pscustomobject]@{ DisplayName='Microsoft.ZuneMusic';       PackageName='zune_1'; Version='1.0'; PublisherId='p' },
    [pscustomobject]@{ DisplayName='Microsoft.VCLibs.140.00';   PackageName='vc_1';   Version='1.0'; PublisherId='p' },
    [pscustomobject]@{ DisplayName='Microsoft.WindowsStore';    PackageName='store_1';Version='1.0'; PublisherId='p' }
)
$script:Removed = @()
function Get-AppxProvisionedPackage { param($Path, $ErrorAction) return @($script:Apps) }
function Remove-AppxProvisionedPackage { param($Path, $PackageName, $ErrorAction) $script:Removed += $PackageName }

$res = Remove-WfProvisionedApp -MountPath $mount -Name 'Microsoft.Zune*' -Confirm:$false
Test-Case 'removed the one named' @('zune_1') $script:Removed
Test-Case 'reported'              'Removed'   $res[0].Result

Write-Host 'The load-bearing ones are refused' -ForegroundColor Cyan
# Removing VCLibs breaks applications installed later, and nothing says so at
# the time.
$script:Removed = @()
$res2 = Remove-WfProvisionedApp -MountPath $mount -Name 'Microsoft.VCLibs*','Microsoft.WindowsStore' -Confirm:$false
Test-Case 'nothing removed' 0 $script:Removed.Count
Test-Case 'both refused'    @('RefusedAsRisky','RefusedAsRisky') @($res2 | ForEach-Object { $_.Result })

Write-Host '...unless you insist' -ForegroundColor Cyan
$script:Removed = @()
$null = Remove-WfProvisionedApp -MountPath $mount -Name 'Microsoft.VCLibs*' -Force -Confirm:$false
Test-Case 'removed with -Force' @('vc_1') $script:Removed

Write-Host 'A pattern that matches nothing is not an error' -ForegroundColor Cyan
$script:Logged = @()
$res3 = @(Remove-WfProvisionedApp -MountPath $mount -Name 'Nothing.Like.This' -Confirm:$false)
Test-Case 'empty result' 0 $res3.Count
Test-Case 'said so'      $true ([bool]($script:Logged -match "Nothing matches"))

Write-Host 'Capabilities: only installed ones are candidates' -ForegroundColor Cyan
function Get-WindowsCapability {
    param($Path, $ErrorAction)
    @(
        [pscustomobject]@{ Name='Media.WindowsMediaPlayer~~~~0.0.12.0'; State='Installed' },
        [pscustomobject]@{ Name='App.Support.QuickAssist~~~~0.0.1.0';   State='NotPresent' }
    )
}
$script:CapRemoved = @()
function Remove-WindowsCapability { param($Path, $Name, $ErrorAction) $script:CapRemoved += $Name }

$null = Remove-WfImageCapability -MountPath $mount -Name 'Media.WindowsMediaPlayer*','App.Support.QuickAssist*' -Confirm:$false
Test-Case 'removed the installed one'      1 $script:CapRemoved.Count
Test-Case 'skipped the one not present'    $false ([bool](@($script:CapRemoved) -match 'QuickAssist'))

Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
