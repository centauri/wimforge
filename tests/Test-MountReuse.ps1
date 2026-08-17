# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Invoke-WfWithMount: one mount, many operations.
#
# The rule it encodes is that whoever mounted an image decides when it is
# committed. An operation that finds a mount open uses it and leaves it; an
# operation that mounts for itself commits and closes. Getting that backwards
# either throws away someone's work or leaves a mount behind.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Public\Updates.ps1')      # ConvertTo-WfArchitectureName
. (Join-Path $root 'WimForge\Public\Servicing.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

$script:Steps   = @()
$script:Current = $null

function Get-WfConfig      { @{ MountPath = 'C:\WimMount' } }
function Write-WfLog       { param([string]$Message, [string]$Level) $script:Logged += @("$Level|$Message") }
function Assert-WfElevated { }
function Get-WfCurrentMount { return $script:Current }
function Mount-WfImage {
    param([string]$ImagePath, [int]$Index, [switch]$ReadOnly, [switch]$WorkingCopy)
    $script:Steps += "mount:$(Split-Path $ImagePath -Leaf)#$Index"
    return [pscustomobject]@{ ImagePath = $ImagePath; Index = $Index; MountPath = 'C:\WimMount' }
}
function Dismount-WfImage {
    param([string]$MountPath, [switch]$Save, [switch]$Discard)
    if ($Save) { $script:Steps += 'commit' } else { $script:Steps += 'discard' }
}

function Reset { $script:Steps = @(); $script:Current = $null; $script:Logged = @() }

Write-Host 'Nothing mounted: mount, run, commit' -ForegroundColor Cyan
Reset
$r = Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 2 -Body { param($mp) "ran at $mp" }
Test-Case 'order'    @('mount:base.wim#2','commit') $script:Steps
Test-Case 'body ran' 'ran at C:\WimMount' $r

Write-Host 'Read-only mounts are discarded, not committed' -ForegroundColor Cyan
Reset
$null = Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 1 -ReadOnly -Body { 'looked' }
Test-Case 'discarded' @('mount:base.wim#1','discard') $script:Steps

Write-Host 'Already mounted: use it, and leave it open' -ForegroundColor Cyan
Reset
$script:Current = [pscustomobject]@{ ImagePath='D:\base.wim'; Index=2; MountPath='C:\WimMount'; ReadOnly=$false }
$r2 = Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 2 -Body { param($mp) "ran at $mp" }
Test-Case 'nothing mounted or dismounted' 0 $script:Steps.Count
Test-Case 'body still ran'  'ran at C:\WimMount' $r2
Test-Case 'said so'         $true ([bool]($script:Logged -match 'stays mounted'))

Write-Host 'Three operations against one mount' -ForegroundColor Cyan
# The whole point: five customisations used to cost five mounts.
Reset
$script:Current = [pscustomobject]@{ ImagePath='D:\base.wim'; Index=1; MountPath='C:\WimMount'; ReadOnly=$false }
foreach ($n in 1..3) { $null = Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 1 -Body { 'change' } }
Test-Case 'still no mount traffic' 0 $script:Steps.Count

Write-Host 'A different image mounted is an error, not a silent dismount' -ForegroundColor Cyan
Reset
$script:Current = [pscustomobject]@{ ImagePath='D:\other.wim'; Index=1; MountPath='C:\WimMount'; ReadOnly=$false }
$msg = ''
try { Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 1 -Body { 'should not run' } } catch { $msg = $_.Exception.Message }
Test-Case 'threw'              $true ([bool]($msg -match 'A different image is mounted'))
Test-Case 'named both images'  $true ([bool](($msg -match 'other\.wim') -and ($msg -match 'base\.wim')))
Test-Case 'touched nothing'    0 $script:Steps.Count

Write-Host 'Same file, different index, is also a different image' -ForegroundColor Cyan
Reset
$script:Current = [pscustomobject]@{ ImagePath='D:\base.wim'; Index=3; MountPath='C:\WimMount'; ReadOnly=$false }
$msg2 = ''
try { Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 1 -Body { 'no' } } catch { $msg2 = $_.Exception.Message }
Test-Case 'threw' $true ([bool]($msg2 -match 'different image is mounted'))

Write-Host 'A read-only mount will not take changes' -ForegroundColor Cyan
Reset
$script:Current = [pscustomobject]@{ ImagePath='D:\base.wim'; Index=1; MountPath='C:\WimMount'; ReadOnly=$true }
$msg3 = ''
try { Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 1 -Body { 'change it' } } catch { $msg3 = $_.Exception.Message }
Test-Case 'threw'          $true ([bool]($msg3 -match 'read-only'))
Test-Case 'says what to do' $true ([bool]($msg3 -match 'read/write'))
# ...but a read-only operation against a read-only mount is fine.
Reset
$script:Current = [pscustomobject]@{ ImagePath='D:\base.wim'; Index=1; MountPath='C:\WimMount'; ReadOnly=$true }
$r3 = Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 1 -ReadOnly -Body { 'just looking' }
Test-Case 'read-only work allowed' 'just looking' $r3

Write-Host 'A failure discards -- but only a mount we opened' -ForegroundColor Cyan
Reset
$threw = $false
try { Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 1 -Body { throw 'boom' } } catch { $threw = $true }
Test-Case 'error surfaced' $true $threw
Test-Case 'discarded'      @('mount:base.wim#1','discard') $script:Steps

Reset
$script:Current = [pscustomobject]@{ ImagePath='D:\base.wim'; Index=1; MountPath='C:\WimMount'; ReadOnly=$false }
$threw2 = $false
try { Invoke-WfWithMount -ImagePath 'D:\base.wim' -Index 1 -Body { throw 'boom' } } catch { $threw2 = $true }
Test-Case 'error surfaced'  $true $threw2
# Somebody else's mount is left exactly as it was: they may want to look at it.
Test-Case 'left their mount alone' 0 $script:Steps.Count

Write-Host 'Get-WfCurrentMount matches on the configured mount path' -ForegroundColor Cyan
# Re-dot-sourcing restores the real Get-WfCurrentMount over the stub above.
# Removing the stub would take the real one with it -- same name, one entry.
. (Join-Path $root 'WimForge\Public\Servicing.ps1')
function Get-WindowsImage {
    param([switch]$Mounted, [string]$ErrorAction)
    @(
        [pscustomobject]@{ Path='C:\SomewhereElse'; ImagePath='D:\other.wim'; ImageIndex=1; MountMode='ReadWrite'; MountStatus='Ok' },
        [pscustomobject]@{ Path='C:\WimMount\';     ImagePath='D:\base.wim';  ImageIndex=4; MountMode='ReadOnly';  MountStatus='Ok' }
    )
}
$cur = Get-WfCurrentMount
Test-Case 'found ours, not the other' 'D:\base.wim' $cur.ImagePath
Test-Case 'trailing slash ignored'    4 $cur.Index
Test-Case 'read-only spotted'         $true $cur.ReadOnly

function Get-WindowsImage { param([switch]$Mounted, [string]$ErrorAction) @() }
Test-Case 'nothing mounted' $true ($null -eq (Get-WfCurrentMount))

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
