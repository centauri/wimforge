# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The ORDER is the feature. Everything else here is plumbing around it.
#
# Microsoft's rule, from "Update Windows installation media with Dynamic Update":
#
#   "It's important to apply the latest cumulative update LAST, to ensure
#    Features on Demand, Optional Components, and Languages are updated from
#    their initial release state."
#
# Applied last, the cumulative brings everything just added forward with it.
# Applied first -- or applied to an image built months ago -- it cannot, and the
# image accumulates components stuck at the level they shipped at. On Windows 10
# that is untidy. On 24H2, where a cumulative is a UUP package reconstructing
# differential payload, it is eventually fatal: the apply dies inside the Windows
# Update Agent with 0x800401E3 and a message about an Unattend.xml.
#
# So this test records every DISM call and asserts the SEQUENCE. Reading the
# source for the right words would pass just as happily with the calls in the
# wrong order, which is the only thing that actually matters.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

. (Join-Path $root 'WimForge\Private\Core.ps1')
. (Join-Path $root 'WimForge\Public\ReferenceImage.ps1')

# ------------------------------------------------------------------ fixtures
$work  = Join-Path ([IO.Path]::GetTempPath()) ('wf-ref-' + [guid]::NewGuid().ToString('N').Substring(0,6))
$media = Join-Path $work 'media'
New-Item -ItemType Directory -Path (Join-Path $media 'sources') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $media 'sources\install.wim') -Value 'x' -Force
Set-Content -LiteralPath (Join-Path $media 'sources\boot.wim')    -Value 'x' -Force

$lcu = Join-Path $work 'lcu.msu'
Set-Content -LiteralPath $lcu -Value 'x' -Force
$lp = Join-Path $work 'lp-en-gb.cab'
Set-Content -LiteralPath $lp -Value 'x' -Force

# --------------------------------------------------------------------- stubs
$script:Calls   = New-Object System.Collections.Generic.List[string]
$script:Mounted = New-Object System.Collections.Generic.List[string]
$script:FailOn  = ''

function Get-WfConfig      { @{ ImageRoot = $script:Out; ImageNamePrefix = 'REF'; LogRoot = $script:Out; MountPath = 'C:\WimMount' } }
function Write-WfLog       { param([string]$Message, [string]$Level, [switch]$NoConsole) }
function Assert-WfElevated { }
function Assert-WfPath     { param([string]$Path, [string]$Label) return $Path }
function Write-WfHistory   { param($Action, $ImagePath, $Detail, $Notes) $script:History = $Detail }
# dism.exe does two jobs here now: the component cleanup it always did, and
# applying UUP packages, which Add-WindowsPackage cannot do from inside a
# PowerShell host (0x800401E3 -- see Add-WfPackageOffline). Both arrive through
# this one stub, so it tells them apart the way the real thing does: by whether
# there is a /PackagePath in the arguments.
function Invoke-WfDism {
    param([string[]]$Arguments, [switch]$PassThruOutput)
    $pkg = @($Arguments | Where-Object { $_ -like '/PackagePath:*' })
    if ($pkg.Count -eq 0) { $script:Calls.Add('cleanup'); return }

    $leaf = Split-Path ($pkg[0] -replace '^/PackagePath:', '') -Leaf
    if ($script:FailOn -and $leaf -eq $script:FailOn) { throw "pretend failure on $leaf" }
    $script:Calls.Add("pkg:$leaf")
}

function Get-WindowsImage {
    param([string]$ImagePath, [int]$Index, [switch]$Mounted)
    if ($ImagePath -match 'boot\.wim') {
        return @([pscustomobject]@{ ImageIndex = 1; Version = '10.0.26100.1' },
                 [pscustomobject]@{ ImageIndex = 2; Version = '10.0.26100.1' })
    }
    return @([pscustomobject]@{ ImageIndex = 1; Version = '10.0.26100.1' })
}
function Mount-WindowsImage {
    param([string]$ImagePath, [int]$Index, [string]$Path, [switch]$ReadOnly, [string]$ErrorAction)
    $script:Calls.Add("mount:$(Split-Path $ImagePath -Leaf)#$Index")
    $script:Mounted.Add($Path)
}
function Dismount-WindowsImage {
    param([string]$Path, [switch]$Save, [switch]$Discard, [string]$ErrorAction)
    $script:Calls.Add($(if ($Discard) { 'discard' } else { 'commit' }))
    [void]$script:Mounted.Remove($Path)
}
$script:ViaCmdlet = New-Object System.Collections.Generic.List[string]
function Add-WindowsPackage {
    param([string]$Path, [string]$PackagePath, [string]$ScratchDirectory, [string]$LogPath, [string]$ErrorAction)
    $leaf = Split-Path $PackagePath -Leaf
    $script:ViaCmdlet.Add($leaf)
    if ($script:FailOn -and $leaf -eq $script:FailOn) { throw "pretend failure on $leaf" }
    $script:Calls.Add("pkg:$leaf")
}
function Add-WindowsCapability {
    param([string]$Path, [string]$Name, [string]$Source, [switch]$LimitAccess, [string]$ErrorAction)
    $script:Calls.Add("cap:$Name")
}
function Export-WindowsImage {
    param([string]$SourceImagePath, [int]$SourceIndex, [string]$DestinationImagePath, [string]$CompressionType, [string]$ErrorAction)
    $script:Calls.Add('export')
    Set-Content -LiteralPath $DestinationImagePath -Value 'x' -Force
}
function Expand-WindowsImage {
    param([string]$ImagePath, [int]$Index, [string]$ApplyPath, [string]$ErrorAction)
    # A real LCU expands to a folder carrying its own servicing stack cabinet.
    Set-Content -LiteralPath (Join-Path $ApplyPath 'SSU-26100.8872-x64.cab') -Value 'x' -Force
}
function Test-WfUpdateContainer {
    param([string]$Path, [long]$MinimumBytes)
    # Faithful enough for what depends on it: the .msu files here stand for the
    # UUP packages 24H2 and Server 2025 ship, and the .cab files for language
    # packs and servicing stacks, which are cabinets. That split is what decides
    # whether a package goes to dism.exe or to Add-WindowsPackage.
    $kind = 'Cab'
    if ($Path -match '\.msu$') { $kind = 'Wim' }
    return [pscustomobject]@{ Ok = $true; Kind = $kind; Reason = '' }
}

$script:Out = Join-Path $work 'out'
New-Item -ItemType Directory -Path $script:Out -Force | Out-Null

Write-Host 'The cumulative update goes in LAST' -ForegroundColor Cyan

$script:Calls.Clear()
$null = New-WfReferenceImage -MediaPath $media -LcuPath $lcu `
            -LanguagePack @($lp) -Capability @('Language.OCR~~~en-GB~0.0.1.0') `
            -FodSource 'E:\' -BuildRoot (Join-Path $work 'b') -SkipWinRe

# The install.wim leg, isolated from the boot.wim work that precedes it.
$all      = @($script:Calls)
$startIx  = [array]::IndexOf($all, 'mount:install.wim#1')
$installLeg = @($all[$startIx..($all.Count - 1)])

$ssuAt  = [array]::IndexOf($installLeg, 'pkg:SSU-26100.8872-x64.cab')
$lpAt   = [array]::IndexOf($installLeg, 'pkg:lp-en-gb.cab')
$capAt  = [array]::IndexOf($installLeg, 'cap:Language.OCR~~~en-GB~0.0.1.0')
$lcuAt  = [array]::IndexOf($installLeg, 'pkg:lcu.msu')

Test-Case 'servicing stack first'      $true ($ssuAt -ge 0 -and $ssuAt -lt $lpAt)
Test-Case 'then languages'             $true ($lpAt  -ge 0 -and $lpAt  -lt $capAt)
Test-Case 'then features'              $true ($capAt -ge 0 -and $capAt -lt $lcuAt)
Test-Case 'and the cumulative LAST'    $true ($lcuAt -gt $capAt)

# And it goes in through dism.exe, not the cmdlet. Add-WindowsPackage cannot
# unpack a UUP package from inside a PowerShell host -- it comes back
# MK_E_UNAVAILABLE after several minutes of expanding, which on a build that
# takes hours is the most expensive possible place to find out.
Test-Case 'the cumulative did not go through the cmdlet' $false ($script:ViaCmdlet -contains 'lcu.msu')
Test-Case 'the language pack did'                        $true  ($script:ViaCmdlet -contains 'lp-en-gb.cab')

# Cleanup after the cumulative, commit after cleanup. Cleaning first would
# reclaim nothing the update is about to supersede.
$cleanAt  = [array]::IndexOf($installLeg, 'cleanup')
$commitAt = [array]::IndexOf($installLeg, 'commit')
Test-Case 'cleanup follows the update' $true ($cleanAt -gt $lcuAt)
Test-Case 'and commit follows cleanup' $true ($commitAt -gt $cleanAt)

Write-Host 'boot.wim is serviced, but takes no languages or features' -ForegroundColor Cyan

$bootLeg = @($all[0..($startIx - 1)])
Test-Case 'both boot indexes mounted' 2 (@($bootLeg | Where-Object { $_ -match '^mount:boot\.wim' }).Count)
Test-Case 'it gets the cumulative'    $true ($bootLeg -contains 'pkg:lcu.msu')
Test-Case 'but no language pack'      $false ($bootLeg -contains 'pkg:lp-en-gb.cab')
Test-Case 'and no capability'         $false ([bool]@($bootLeg | Where-Object { $_ -like 'cap:*' }).Count)

Write-Host 'The servicing stack is taken from inside the update' -ForegroundColor Cyan

# No separate SSU download to chase: a checkpoint cumulative carries one, which
# is what makes "servicing stack first" possible at all.
$exp = Join-Path $work 'expand'
New-Item -ItemType Directory -Path $exp -Force | Out-Null
Set-Content -LiteralPath (Join-Path $exp 'SSU-26100.8872-x64.cab') -Value 'x' -Force
Set-Content -LiteralPath (Join-Path $exp 'other.cab') -Value 'x' -Force
Test-Case 'the SSU cab is found' 'SSU-26100.8872-x64.cab' (Split-Path (Get-WfLcuServicingStack -ExpandedPath $exp) -Leaf)

$none = Join-Path $work 'expand-none'
New-Item -ItemType Directory -Path $none -Force | Out-Null
Test-Case 'and no SSU is not an error' $true ($null -eq (Get-WfLcuServicingStack -ExpandedPath $none))

Write-Host 'Nothing is committed when a step fails' -ForegroundColor Cyan

# The failure mode that matters. A half-built image written out as the finished
# article is worse than no image, because it looks like one.
$script:Calls.Clear()
$script:Mounted.Clear()
$script:FailOn = 'lcu.msu'
$threw = $false
try {
    $null = New-WfReferenceImage -MediaPath $media -LcuPath $lcu -BuildRoot (Join-Path $work 'b2') -SkipWinRe -SkipBootWim
}
catch { $threw = $true }
$script:FailOn = ''

Test-Case 'it threw'            $true  $threw
Test-Case 'nothing committed'   $false ($script:Calls -contains 'commit')
Test-Case 'the mount discarded' $true  ($script:Calls -contains 'discard')
Test-Case 'and nothing exported' $false ($script:Calls -contains 'export')
Test-Case 'no mount left behind' 0     $script:Mounted.Count

Write-Host 'Capabilities without a source are refused up front' -ForegroundColor Cyan

# Refused before the mount rather than after it: capabilities come from the FOD
# ISO, and discovering that forty minutes in wastes the whole run.
$msg = ''
try {
    $null = New-WfReferenceImage -MediaPath $media -LcuPath $lcu `
                -Capability @('Language.OCR~~~en-GB~0.0.1.0') -BuildRoot (Join-Path $work 'b3')
}
catch { $msg = $_.Exception.Message }
Test-Case 'it refuses'   $true ($msg -match 'no -FodSource was given')
Test-Case 'and says why' $true ($msg -match 'cumulative would then have nothing to bring forward')

Write-Host 'It keys on the build family, not the product name' -ForegroundColor Cyan

# Windows 11 24H2, Windows 11 25H2 and Windows Server 2025 are one servicing
# generation. Branching on "is this Windows 11" needs an edit for each of them;
# branching on the build does not, and Server falls out for free.
$src = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\ReferenceImage.ps1') -Raw
Test-Case 'checkpoint is a build test' $true ($src -match '\$build -ge 26100')
Test-Case 'and no product-name branch' $false ($src -match "-match 'Windows 11'|-eq 'Windows 11'")

Write-Host 'An unknown index is refused, not silently skipped' -ForegroundColor Cyan

# Server media carries four indexes -- Standard and Datacenter, Core and Desktop
# Experience. Servicing the wrong one, or silently servicing none, ships an
# image nobody checked.
$msg = ''
try {
    $null = New-WfReferenceImage -MediaPath $media -LcuPath $lcu -Index @(1,7) -BuildRoot (Join-Path $work 'b4') -SkipWinRe -SkipBootWim
}
catch { $msg = $_.Exception.Message }
Test-Case 'it names what is there' $true ($msg -match 'install\.wim has indexes 1')
Test-Case 'and what was asked for' $true ($msg -match 'asked for 7')

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
