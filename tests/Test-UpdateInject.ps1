# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Add-WfUpdate -File and Invoke-WfUpdateInject, with DISM and the mount stubbed.
# Real files on disk, because the file-resolution logic is half the point.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# Core first, for the real ConvertTo-WfNaturalKey -- apply order is behaviour
# under test here, so stubbing the sort key would test nothing. Everything else
# Core defines is overridden by the stubs further down, which is why they come
# after both dot-sources and not before.
. (Join-Path $root 'WimForge\Private\Core.ps1')
# The real Get-WfUpdateSet, because reading the set marker off disk is the
# behaviour under test -- a stub would just assert that a stub was called.
. (Join-Path $root 'WimForge\Public\Updates.ps1')
# And the real error classifier. Without it the "a failure discards the mount"
# cases below were passing on the WRONG exception: Add-WfUpdate's catch block
# called Get-WfDismError, that call itself failed with "term not recognized",
# and the test saw an exception and called it a pass. It never once exercised
# the fatal-versus-not-applicable decision it exists to check.
. (Join-Path $root 'WimForge\Public\DismErrors.ps1')
. (Join-Path $root 'WimForge\Public\Servicing.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

# ------------------------------------------------------------- a real folder
$updates = Join-Path ([IO.Path]::GetTempPath()) ('wf-updates-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $updates -Force | Out-Null
foreach ($n in @('02-second.msu', '01-first.msu', 'stale.cab')) {
    Set-Content -LiteralPath (Join-Path $updates $n) -Value 'x' -Force
}

# ------------------------------------------------------------------- stubs
function Get-WfConfig      { @{ UpdateRoot = $script:UpdRoot; MountPath = 'C:\WimMount'; HistoryFile = 'C:\h.json' } }
function Write-WfLog       { param([string]$Message, [string]$Level) }
function Assert-WfElevated { }
function Assert-WfPath     { param([string]$Path, [string]$Label) return $Path }
function Join-WfPath       { param([string]$Path, [string]$ChildPath) return (Join-Path $Path $ChildPath) }
# What generation the mounted image is. 0 means "could not tell", which must
# never cause a package to be refused.
$script:ImgBuild = 0
# 'Client', 'Server' or '' for an image whose hive does not say -- which is the
# only thing separating a Server 2025 image from a Windows 11 24H2 one, since
# both are build 26100.
$script:ImgType = ''
function Get-WfOfflineCurrentVersion {
    param([string]$MountPath)
    if ($script:ImgBuild -eq 0) { throw 'no registry' }
    $cv = @{ CurrentBuildNumber = "$($script:ImgBuild)" }
    if ($script:ImgType) { $cv['InstallationType'] = $script:ImgType }
    return $cv
}

$script:UpdRoot  = $updates
$script:Applied  = @()
$script:Explode  = ''
$script:ExplodeWith = ''
$script:Attempts = 0
$script:FailOnce = $false
function Add-WindowsPackage {
    param([string]$Path, [string]$PackagePath, [string]$ErrorAction, [string]$ScratchDirectory, [string]$LogPath)
    $leaf = Split-Path $PackagePath -Leaf
    $script:Attempts++
    if ($script:Explode -and $leaf -eq $script:Explode) {
        # -FailOnce models the retry case: fail, then succeed once the caller has
        # changed the conditions. Without it the retry is indistinguishable from
        # a second identical failure.
        if ($script:FailOnce) { $script:FailOnce = $false }
        $code = $script:ExplodeWith
        if (-not $code) { $code = '0x80070002' }
        throw "$code pretend failure on $leaf"
    }
    $script:Applied += $leaf
}

# ------------------------------------------------------- Add-WfUpdate -File
Write-Host 'Add-WfUpdate applies only the named files' -ForegroundColor Cyan
$script:Applied = @()
$r = Add-WfUpdate -File @('02-second.msu', '01-first.msu')
Test-Case 'name order, not the order given' @('01-first.msu','02-second.msu') $script:Applied
Test-Case 'stale.cab left alone'            $false ($script:Applied -contains 'stale.cab')
Test-Case 'reported as applied'             @('Applied','Applied') @($r | ForEach-Object { $_.Status })

Write-Host 'Full paths work as well as names' -ForegroundColor Cyan
$script:Applied = @()
$null = Add-WfUpdate -File @((Join-Path $updates '01-first.msu'))
Test-Case 'one file' @('01-first.msu') $script:Applied

Write-Host 'A name that is not there stops everything' -ForegroundColor Cyan
$script:Applied = @()
$msg = ''
try { Add-WfUpdate -File @('01-first.msu', 'imaginary.msu') } catch { $msg = $_.Exception.Message }
Test-Case 'threw'              $true  ([bool]($msg -match 'imaginary\.msu'))
# Nothing applied: believing you have a file and not having it is not the same
# situation as an empty folder, and half-applying is the worst outcome.
Test-Case 'applied nothing'    0      $script:Applied.Count

Write-Host 'No -File still means the whole folder' -ForegroundColor Cyan
$script:Applied = @()
$null = Add-WfUpdate
Test-Case 'everything, in name order' @('01-first.msu','02-second.msu','stale.cab') $script:Applied

# ------------------------------------------- checkpoint before the cumulative
# Windows 11 24H2 servicing is checkpoint-based: one catalog entry downloads as
# two files, and the newer cumulative will not install unless the checkpoint it
# builds on goes first. Nothing in the file names says "checkpoint" -- the only
# signal is that its KB number is lower, so the apply order IS the correctness
# condition, and it is invisible until an injection fails with 0x800f081f.
Write-Host 'A checkpoint cumulative goes in before the update that needs it' -ForegroundColor Cyan

$ck = Join-Path ([IO.Path]::GetTempPath()) ('wf-ckpt-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $ck -Force | Out-Null
foreach ($n in @(
    'windows11.0-kb5121767-x64_588e6404d4e9.msu',   # 2026-07 cumulative
    'windows11.0-kb5043080-x64_953449672073.msu'    # the 24H2 checkpoint
)) { Set-Content -LiteralPath (Join-Path $ck $n) -Value 'x' -Force }

$script:UpdRoot = $ck
$script:Applied = @()
$null = Add-WfUpdate
Test-Case 'checkpoint first' @(
    'windows11.0-kb5043080-x64_953449672073.msu',
    'windows11.0-kb5121767-x64_588e6404d4e9.msu'
) $script:Applied

Remove-Item -LiteralPath $ck -Recurse -Force -ErrorAction SilentlyContinue
$script:UpdRoot = $updates

# ---------------------------------------- a checkpoint set is ONE package
# The failure that prompted this: applying the set file-by-file, oldest first,
# meant handing DISM the original 26100.1742 baseline and asking it to install
# that into an image already at 26100.7623. It refused, as it should.
#
# Checkpoints are not steps, and they must not sit beside the target either:
# with a checkpoint .msu in the same directory DISM routes the pair through the
# Windows Update Agent and dies. One Add-WindowsPackage, target alone.
Write-Host 'A checkpoint set is applied as one package, not several' -ForegroundColor Cyan

$set = Join-Path ([IO.Path]::GetTempPath()) ('wf-set-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $set -Force | Out-Null
foreach ($n in @(
    'windows11.0-kb5121767-x64_588e.msu',   # the update
    'windows11.0-kb5043080-x64_9534.msu'    # a checkpoint it may be rebuilt from
)) { Set-Content -LiteralPath (Join-Path $set $n) -Value 'x' -Force }

[pscustomobject]@{
    KB     = 'KB5121767'
    Target = 'windows11.0-kb5121767-x64_588e.msu'
    Files  = @('windows11.0-kb5043080-x64_9534.msu','windows11.0-kb5121767-x64_588e.msu')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $set 'wimforge-set.json') -Force

$script:UpdRoot = $set
$script:Applied = @()
$r = Add-WfUpdate

Test-Case 'exactly one package is applied' 1 $script:Applied.Count
Test-Case 'and it is the update, not the checkpoint' `
    'windows11.0-kb5121767-x64_588e.msu' $script:Applied[0]

# The checkpoint is reported rather than silently dropped -- "1 applied" out of
# two files on disk would otherwise look like something went missing.
$ckRow = @($r | Where-Object { $_.Status -eq 'Checkpoint' })
Test-Case 'the checkpoint is accounted for' 1 $ckRow.Count
Test-Case 'and explained'                   $true ($ckRow[0].Reason -match 'Not applied on its own')

# Without the marker it is just a folder with two updates in it, and both must
# still be applied -- otherwise an ordinary Updates folder holding two months of
# cumulative updates would quietly lose one.
Write-Host 'An unmarked folder still applies everything' -ForegroundColor Cyan
Remove-Item -LiteralPath (Join-Path $set 'wimforge-set.json') -Force
$script:Applied = @()
$null = Add-WfUpdate
Test-Case 'both files applied' 2 $script:Applied.Count

# A marker naming a file that is not there must not silently apply nothing.
Write-Host 'A stale marker does not swallow the folder' -ForegroundColor Cyan
[pscustomobject]@{ KB = 'KB5121767'; Target = 'gone.msu' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $set 'wimforge-set.json') -Force
$script:Applied = @()
$null = Add-WfUpdate
Test-Case 'it falls back to applying what is there' 2 $script:Applied.Count

Remove-Item -LiteralPath $set -Recurse -Force -ErrorAction SilentlyContinue
$script:UpdRoot = $updates

# -------------------------------------------------- Invoke-WfUpdateInject
Write-Host 'Invoke-WfUpdateInject: mount, apply, commit' -ForegroundColor Cyan
$script:Steps   = @()
$script:History = $null
function Mount-WfImage {
    param([string]$ImagePath, [int]$Index, [switch]$ReadOnly, [switch]$WorkingCopy)
    $script:Steps += "mount:$ImagePath#$Index"
    $path = $ImagePath
    if ($WorkingCopy) { $path = [IO.Path]::ChangeExtension($ImagePath, 'working.wim') }
    return [pscustomobject]@{ ImagePath = $path; Index = $Index; MountPath = 'C:\WimMount' }
}
function Dismount-WfImage {
    param([string]$MountPath, [switch]$Save, [switch]$Discard)
    if ($Save) { $script:Steps += 'commit' } else { $script:Steps += 'discard' }
}
function Invoke-WfCleanup { param([string]$MountPath, [switch]$ResetBase) $script:Steps += 'cleanup' }
# $null means "nothing is open", which is the state every case above assumes.
$script:OpenMount = $null
function Get-WfCurrentMount { param([string]$MountPath) return $script:OpenMount }
function Write-WfHistory  {
    param([string]$Action, [string]$ImagePath, [hashtable]$Detail, [string]$Notes)
    $script:History = [pscustomobject]@{ Action=$Action; ImagePath=$ImagePath; Detail=$Detail }
}

$script:Applied = @(); $script:Steps = @()
$r = Invoke-WfUpdateInject -ImagePath 'D:\Images\Base.wim' -Index 2 -File @('01-first.msu')
Test-Case 'order of operations' @('mount:D:\Images\Base.wim#2','commit') $script:Steps
Test-Case 'applied the one file' @('01-first.msu') $script:Applied
Test-Case 'history names the image' 'D:\Images\Base.wim' $script:History.ImagePath
Test-Case 'history lists what went in' @('01-first.msu') $script:History.Detail['Applied']

Write-Host 'A working copy is what gets recorded, not the master' -ForegroundColor Cyan
$script:Applied = @(); $script:Steps = @()
$null = Invoke-WfUpdateInject -ImagePath 'D:\Images\Base.wim' -File @('01-first.msu') -WorkingCopy
Test-Case 'history names the copy' 'D:\Images\Base.working.wim' $script:History.ImagePath
Test-Case 'flagged as a copy'      $true $script:History.Detail['WorkingCopy']

Write-Host 'Cleanup runs before the commit when asked for' -ForegroundColor Cyan
$script:Applied = @(); $script:Steps = @()
$null = Invoke-WfUpdateInject -ImagePath 'D:\Images\Base.wim' -File @('01-first.msu') -Cleanup
Test-Case 'cleanup then commit' @('mount:D:\Images\Base.wim#1','cleanup','commit') $script:Steps

Write-Host 'A failure discards the mount and does not commit' -ForegroundColor Cyan
$script:Applied = @(); $script:Steps = @(); $script:History = $null
$script:Explode = '01-first.msu'
$threw = $false
try { Invoke-WfUpdateInject -ImagePath 'D:\Images\Base.wim' -File @('01-first.msu') } catch { $threw = $true }
$script:Explode = ''
Test-Case 'error surfaced'      $true  $threw
Test-Case 'discarded, no commit' @('mount:D:\Images\Base.wim#1','discard') $script:Steps
Test-Case 'no history written'  $true  ($null -eq $script:History)

Write-Host 'An image that is already open is used, not refused' -ForegroundColor Cyan

# Opening a 10 GB WIM costs two minutes, so it is always deliberate. Injecting
# into it used to fail with "Mount folder is not empty -- run Repair-WfMount",
# which is both the wrong diagnosis and advice to destroy the mount.
$script:OpenMount = [pscustomobject]@{
    ImagePath = 'D:\Images\Base.wim'; Index = 1; MountPath = 'C:\WimMount'
    Status = 'Ok'; ReadOnly = $false
}

$script:Applied = @(); $script:Steps = @(); $script:History = $null
$null = Invoke-WfUpdateInject -ImagePath 'D:\Images\Base.wim' -File @('01-first.msu')

# No mount, and no commit. Both halves matter: it did not open this mount, so it
# does not close it -- the operator does, when they are done with it.
Test-Case 'no second mount and no commit' @() $script:Steps
Test-Case 'the update still went in'      @('01-first.msu') $script:Applied

# The history has to say the .wim on disk did NOT change, or it reads as proof
# the updates are in the image when they are one discard away from gone.
Test-Case 'history says uncommitted' $false $script:History.Detail['Committed']
Test-Case 'and says why'             $true  $script:History.Detail['ReusedMount']

Write-Host 'A failure leaves someone else''s mount alone' -ForegroundColor Cyan

# The dangerous case. Discarding here would throw away not just this injection
# but everything the operator had already done in that mount.
$script:Applied = @(); $script:Steps = @(); $script:History = $null
$script:Explode = '01-first.msu'
$threw = $false
try { Invoke-WfUpdateInject -ImagePath 'D:\Images\Base.wim' -File @('01-first.msu') } catch { $threw = $true }
$script:Explode = ''
Test-Case 'error surfaced'   $true $threw
Test-Case 'nothing discarded' @()  $script:Steps

Write-Host 'Conflicts are refused rather than papered over' -ForegroundColor Cyan

# Silently updating whatever happened to be mounted is the one outcome worse
# than refusing, because it is not visible until much later.
function Test-Refusal {
    param([string] $Name, [scriptblock] $Body, [string] $Expect)
    $msg = ''
    try { & $Body } catch { $msg = "$($_.Exception.Message)" }
    Test-Case $Name $true ($msg -match $Expect)
}

Test-Refusal 'a different image' { Invoke-WfUpdateInject -ImagePath 'D:\Images\Other.wim' -File @('01-first.msu') } 'A different image is open'
Test-Refusal 'a different index' { Invoke-WfUpdateInject -ImagePath 'D:\Images\Base.wim' -Index 3 -File @('01-first.msu') } 'index 3 was asked for'
Test-Refusal 'a working copy'    { Invoke-WfUpdateInject -ImagePath 'D:\Images\Base.wim' -File @('01-first.msu') -WorkingCopy } 'WorkingCopy would mount a second image'

$script:OpenMount.ReadOnly = $true
Test-Refusal 'a read-only mount' { Invoke-WfUpdateInject -ImagePath 'D:\Images\Base.wim' -File @('01-first.msu') } 'open READ-ONLY'

$script:OpenMount = $null

Write-Host 'Checkpoints held below the target are invisible to the apply' -ForegroundColor Cyan

# The layout is the fix. Microsoft documents putting the target and every prior
# checkpoint in ONE folder and pointing DISM at the target -- and that is the
# combination that fails: with a checkpoint .msu beside the target, DISM routes
# the pair through the Windows Update Agent and dies (0x800401E3 here,
# 0x80070228 for others), surfacing as the Unattend.xml message.
#
# So the checkpoints live one directory down. Two things have to hold: the
# recursive folder scan must not sweep them back up as work, and the target must
# be applied alone.
$sep = Join-Path ([IO.Path]::GetTempPath()) ('wf-sep-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path (Join-Path $sep 'checkpoints') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $sep 'windows11.0-kb5121767-x64_588e.msu') -Value 'x' -Force
Set-Content -LiteralPath (Join-Path $sep 'checkpoints\windows11.0-kb5043080-x64_9534.msu') -Value 'x' -Force

[pscustomobject]@{
    KB          = 'KB5121767'
    Target      = 'windows11.0-kb5121767-x64_588e.msu'
    Checkpoints = @('windows11.0-kb5043080-x64_9534.msu')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sep 'wimforge-set.json') -Force

$script:UpdRoot = $sep
$script:Applied = @()
$null = Add-WfUpdate

Test-Case 'only the target is applied' @('windows11.0-kb5121767-x64_588e.msu') $script:Applied

# And it stays where it was put. A checkpoint copied up next to the target and
# left there would break the NEXT run, silently, for the same reason.
Test-Case 'the checkpoint stays below' $false `
    (Test-Path -LiteralPath (Join-Path $sep 'windows11.0-kb5043080-x64_9534.msu'))

# The branch that actually runs.
#
# Download+inject does NOT scan the folder. It passes an explicit -File list of
# what was downloaded, and that list contained the checkpoint -- so the previous
# fix, which filtered only the folder scan, did nothing at all in production.
# DISM was handed the exact file the checkpoints folder exists to keep from it.
#
# One rule, both branches, asserted on the branch that was missing it.
$script:Applied = @()
$null = Add-WfUpdate -File @(
    (Join-Path $sep 'windows11.0-kb5121767-x64_588e.msu'),
    (Join-Path $sep 'checkpoints\windows11.0-kb5043080-x64_9534.msu')
)
Test-Case 'a named checkpoint is refused too' @('windows11.0-kb5121767-x64_588e.msu') $script:Applied

# Reported, not silently dropped: a caller that asked for two files and got one
# applied needs to see where the other went.
$script:Applied = @()
$rows = Add-WfUpdate -File @((Join-Path $sep 'checkpoints\windows11.0-kb5043080-x64_9534.msu'))
Test-Case 'and nothing is applied when only a checkpoint is named' 0 $script:Applied.Count
Test-Case 'with a row explaining why' $true `
    (@($rows | Where-Object { $_.Status -eq 'Checkpoint' }).Count -ge 1)

Write-Host 'Unless DISM says the prerequisite is genuinely missing' -ForegroundColor Cyan

# Applying alone is right because a checkpoint already in the image needs no
# applying. If the image turns out to be older than that, DISM says so with
# 0x800f0831 -- and only then is Microsoft's documented layout worth trying.
$script:Applied = @(); $script:Attempts = 0
$script:Explode = 'windows11.0-kb5121767-x64_588e.msu'
$script:ExplodeWith = '0x800f0831'
$script:FailOnce = $true
$null = Add-WfUpdate -ContinueOnError
$script:Explode = ''; $script:ExplodeWith = ''

# The retry happened: the same package was attempted a second time.
Test-Case 'it tried again' $true ($script:Attempts -ge 2)

# And the folder is put back either way, so the next run starts clean.
Test-Case 'the checkpoint is not left behind' $false `
    (Test-Path -LiteralPath (Join-Path $sep 'windows11.0-kb5043080-x64_9534.msu'))

Remove-Item -LiteralPath $sep -Recurse -Force -ErrorAction SilentlyContinue
$script:UpdRoot = $updates

Write-Host 'A package from the wrong Windows generation is refused' -ForegroundColor Cyan

# A servicing run applied a Windows 11 24H2 package to a Windows 10 19044 image,
# because the Updates folder is a folder: it accumulates, and anyone testing two
# images in an afternoon has both generations sitting in it. DISM went looking
# for a 26100 servicing stack inside a WinSxS that only has 19041 and failed five
# layers down, naming neither the image nor the package.
$gen = Join-Path ([IO.Path]::GetTempPath()) ('wf-gen-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $gen -Force | Out-Null
foreach ($n in @(
    'windows10.0-kb5099539-x64_f001.msu',
    'windows11.0-kb5121767-x64_588e.msu',
    'some-oem-package.cab'
)) { Set-Content -LiteralPath (Join-Path $gen $n) -Value 'x' -Force }

$script:UpdRoot  = $gen
$script:ImgBuild = 19044          # Windows 10 LTSC 2021
$script:Applied  = @()
$rows = Add-WfUpdate -ContinueOnError

Test-Case 'the Windows 10 package applies' $true ($script:Applied -contains 'windows10.0-kb5099539-x64_f001.msu')
Test-Case 'the Windows 11 one does not'    $false ($script:Applied -contains 'windows11.0-kb5121767-x64_588e.msu')

# NotApplicable, not Failed. Nothing went wrong -- the file simply is not for
# this image, and calling that a failure makes a good run report as broken.
$bad = @($rows | Where-Object { $_.Package -eq 'windows11.0-kb5121767-x64_588e.msu' })
Test-Case 'reported as not applicable' 'NotApplicable' $bad[0].Status
Test-Case 'and says which is which'    $true ($bad[0].Reason -match 'Windows 11 package cannot be applied to a Windows 10 image')

# A name that carries no generation is left alone. An unrecognised name is not
# a mismatch, and refusing OEM .cab packages would be a worse bug than the one
# this fixes.
Test-Case 'an unnamed package is untouched' $true ($script:Applied -contains 'some-oem-package.cab')

# And the check runs the other way round too.
$script:ImgBuild = 26100
$script:Applied  = @()
$null = Add-WfUpdate -ContinueOnError
Test-Case 'on a Windows 11 image the 11 package applies' $true ($script:Applied -contains 'windows11.0-kb5121767-x64_588e.msu')
Test-Case 'and the 10 package does not'                  $false ($script:Applied -contains 'windows10.0-kb5099539-x64_f001.msu')

# If the image build cannot be read, nothing is refused. Guessing on absent
# evidence would block work that would have succeeded.
$script:ImgBuild = 0
$script:Applied  = @()
$null = Add-WfUpdate -ContinueOnError
Test-Case 'an unreadable image refuses nothing' 3 $script:Applied.Count

Remove-Item -LiteralPath $gen -Recurse -Force -ErrorAction SilentlyContinue
$script:UpdRoot = $updates

# ------------------------------------------- Server 2025 versus Windows 11 24H2
Write-Host 'A Server 2025 package is not applied to a client image' -ForegroundColor Cyan

# The generation check above cannot see this one: Server 2025 and Windows 11 24H2
# are both build 26100 and BOTH packages are named windows11.0. They also share a
# KB number -- searching KB5062553 in the catalog returns a Windows 11 x64 entry,
# a Windows 11 arm64 entry and a "Microsoft server operating system version 24H2"
# entry. Three download buttons, one search, and on disk the only difference is
# '-2025' in the middle of the file name.
$srv = Join-Path ([IO.Path]::GetTempPath()) ('wf-srv-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $srv -Force | Out-Null
foreach ($n in @(
    'windows11.0-kb5062553-x64-2025_7f21.msu',   # Server 2025
    'windows11.0-kb5062553-x64_9ab3.msu'         # Windows 11 24H2, same KB
)) { Set-Content -LiteralPath (Join-Path $srv $n) -Value 'x' -Force }

$script:UpdRoot  = $srv
$script:ImgBuild = 26100
$script:ImgType  = 'Client'
$script:Applied  = @()
$rows = Add-WfUpdate -ContinueOnError

Test-Case 'the client package applies' $true  ($script:Applied -contains 'windows11.0-kb5062553-x64_9ab3.msu')
Test-Case 'the server one does not'    $false ($script:Applied -contains 'windows11.0-kb5062553-x64-2025_7f21.msu')

$srvRow = @($rows | Where-Object { $_.Package -match '2025' })
Test-Case 'reported as not applicable' 'NotApplicable' $srvRow[0].Status
Test-Case 'and names the marker'       $true ($srvRow[0].Reason -match 'Windows Server 2025 build of the update')
# The advice has to include the catalog's wording, because "search for Windows
# Server 2025" is what everyone tries and it returns nothing.
Test-Case 'and the catalog wording'    $true ($srvRow[0].WhatToDo -match 'Microsoft server operating system version 24H2')

Write-Host 'On a server image the server package is the one that applies' -ForegroundColor Cyan
$script:ImgType = 'Server'
$script:Applied = @()
$null = Add-WfUpdate -ContinueOnError
Test-Case 'the server package applies' $true ($script:Applied -contains 'windows11.0-kb5062553-x64-2025_7f21.msu')

# The other direction is an inference from a MISSING marker, so it is not
# refused -- it is attempted, and DISM decides. Refusing on absent evidence
# would block a legitimate update the day Microsoft changes the naming.
Test-Case 'and the client one is still tried' $true ($script:Applied -contains 'windows11.0-kb5062553-x64_9ab3.msu')

Write-Host 'An image that does not say which it is refuses nothing' -ForegroundColor Cyan
$script:ImgType = ''
$script:Applied = @()
$null = Add-WfUpdate -ContinueOnError
Test-Case 'both attempted' 2 $script:Applied.Count

Remove-Item -LiteralPath $srv -Recurse -Force -ErrorAction SilentlyContinue
$script:UpdRoot  = $updates
$script:ImgBuild = 0
$script:ImgType  = ''

Write-Host 'A hard failure stops the run, even under -ContinueOnError' -ForegroundColor Cyan

# -ContinueOnError means "hand me a report instead of an exception". It does not
# mean "keep servicing an image that just failed to service": a package that
# hard-fails can leave pending operations behind, and stacking more updates on
# top turns one diagnosable failure into an image nobody can reason about.
$script:Applied = @(); $script:Steps = @(); $script:Attempts = 0
$script:Explode = '01-first.msu'
$r = Add-WfUpdate -ContinueOnError
$script:Explode = ''

Test-Case 'it did not throw' $true ($null -ne $r)

# 01-first.msu is the one that fails, so nothing at all lands -- and crucially
# the two packages after it are never attempted.
Test-Case 'nothing was applied' 0 $script:Applied.Count

# Named rather than omitted -- "3 packages, 0 applied" would otherwise look like
# two more silent failures.
$skippedRows = @($r | Where-Object { $_.Status -eq 'Skipped' })
Test-Case 'the rest are reported as skipped' 2 $skippedRows.Count
Test-Case 'and say why' $true ($skippedRows[0].Reason -match 'earlier package failed')

# Not-applicable is a different thing and must NOT stop anything: it is the
# expected outcome of an Updates folder spanning more than one build.
$script:Applied = @()
$script:ExplodeWith = '0x800f081e'
$script:Explode = '01-first.msu'
$r = Add-WfUpdate -ContinueOnError
$script:Explode = ''; $script:ExplodeWith = ''
Test-Case 'a not-applicable package does not stop the run' @('02-second.msu','stale.cab') $script:Applied

Write-Host 'A servicing run says which steps it is running' -ForegroundColor Cyan

# "I did a servicing run, shouldn't that do a cleanup?" was not answerable from
# the log. A skipped step logs nothing at all, so its absence looks exactly like
# a step that ran and had nothing to do -- and answering the question meant
# reading the source to learn that Invoke-WfCleanup logs on entry.
$svcSrc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw

Test-Case 'the plan is logged'    $true ($svcSrc -match 'Write-WfLog \("Plan -- "')
foreach ($step in @('updates','drivers','payload','cleanup','export')) {
    Test-Case "  it names $step" $true ($svcSrc -match "'$step\: \{0\}'")
}

# SKIPPED rather than "no": the word has to be conspicuous in a wall of log.
Test-Case 'a skipped step is named SKIPPED' $true ($svcSrc -match "\{ 'SKIPPED' \}")

# A package that was not for this image is a THIRD outcome, and the summary had
# only two. A run that passed over a Windows 10 cumulative sitting in the Updates
# folder reported 'Applied 1, Failed 0' -- true, and it reads as though the
# folder held one file. The skip was a WARN in the log; the summary is what goes
# into history and into the grid.
# .Contains, not -like: in a wildcard pattern [ ] is a character class, so
# -like '*$summary[''UpdatesSkipped'']*' quietly matches nothing at all.
Test-Case 'the summary counts what was passed over' $true `
    ($svcSrc.Contains('$summary[''UpdatesSkipped''] = $notApplied.Count'))
Test-Case 'from the not-applicable rows' $true `
    ($svcSrc -like '*$notApplied = @($u | Where-Object { $_.Status -eq ''NotApplicable'' })*')
Test-Case 'and names the files' $true `
    ($svcSrc -like '*were not for this image and were passed over*')

# Skipping cleanup earns its own warning, because the cost lands somewhere that
# looks unrelated -- a dismount that runs for hours.
Test-Case 'skipping cleanup is called out'  $true ($svcSrc -match 'cleanup is off, so the commit has to write the superseded payload')
Test-Case 'and the cost is named'           $true ($svcSrc -match 'dismount to take considerably longer')

Write-Host 'Injecting an update says what it cost' -ForegroundColor Cyan

# An audit of the GUI: eight tabs write into the image and only one mentions
# cleanup. That is correct rather than inconsistent -- drivers, registry edits,
# payload files, locale, lockdown and recovery write files and keys, and cleanup
# reclaims nothing from any of them. Injecting a cumulative is the single
# operation that leaves GB of superseded payload behind, so the note belongs
# there, and its absence everywhere else is a fact rather than an omission.
#
# It lands hardest on the reused-mount path, where the operator is one click from
# committing: this is the last moment cleanup is cheap, and afterwards it costs
# another full mount.
$svcSrc2 = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw

Test-Case 'a successful inject says so'      $true ($svcSrc2 -match 'The component store now holds the payload these update')
Test-Case 'only when something applied'      $true ($svcSrc2 -match '(?s)if \(\$ok\.Count -gt 0\) \{\s*Write-WfLog \("The component store')
# The label is quoted verbatim, and checked against the button that actually
# exists -- directions to a control nobody can find waste more time than saying
# nothing would have.
$guiSrc2 = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeGui.ps1') -Raw
Test-Case 'and points at where to reclaim it' $true ($svcSrc2 -match "'Component cleanup' button on the Servicing tab")
Test-Case 'and that button exists'            $true ($guiSrc2 -match "Add-WfButton \`$tabServicing 'Component cleanup'")
Test-Case 'naming the one-way part'           $true ($svcSrc2 -match 'no longer be uninstalled')

Write-Host 'A servicing run says where the time went' -ForegroundColor Cyan

# One run reported 213.1 minutes and nothing else. The interesting fact was
# invisible inside that number -- mount 2m, apply 26m, COMMIT 184m -- and finding
# it meant subtracting timestamps out of the log by hand. A commit taking 86% of
# a run is a diagnosis; a single total is a complaint.
$svcSrc3 = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw

Test-Case 'phases are timed'   $true ($svcSrc3 -match '\$phase\s*=\s*\[ordered\]@\{\}')
foreach ($ph in @('CopyAndMount','Updates','Drivers','Cleanup','Commit','Export')) {
    Test-Case "  $ph is stamped" $true ($svcSrc3 -match "& \`$stamp '$ph'")
}

# Ordered, because the interesting thing is the shape of the run, not a bag of
# numbers.
Test-Case 'the breakdown is logged'   $true ($svcSrc3 -match "Phases'\]\)")
Test-Case 'and kept in the history'   $true ($svcSrc3 -match "\`$summary\['Phases'\]\s*=")

# A dominant phase is called out rather than left for the operator to compute.
Test-Case 'a phase over 60% is named' $true ($svcSrc3 -match '\-lt 0\.6.*continue')
Test-Case 'and a slow commit is explained' $true ($svcSrc3 -match "if \(\`$k -eq 'Commit'\)")
Test-Case 'naming both real causes'        $true ($svcSrc3 -match 'real-time antivirus scanning the mount folder' -and $svcSrc3 -match 'cleanup being skipped')

# Short runs are not annotated -- a 3-minute run that is 70% mount is normal and
# saying so every time would train people to ignore the line that matters.
Test-Case 'short runs are left alone' $true ($svcSrc3 -match '\$total -gt 20')

Write-Host 'Cleanup is three choices, not two' -ForegroundColor Cyan

# "Skip it" and "/ResetBase" were the only settings, and the second is the
# irreversible one: ResetBase discards the backups that let an update be
# uninstalled from the deployed OS. Someone still iterating on an image who does
# not want that has, until now, had to skip cleanup entirely -- paying full size
# AND a much longer commit for reversibility they could have kept anyway.
Test-Case 'the module offers the middle option' $true ($svcSrc -match '\[switch\]\s*\$KeepUninstall')
Test-Case 'and it cleans without ResetBase'     $true ($svcSrc -match '(?s)if \(\$KeepUninstall\) \{\s*Invoke-WfCleanup\s*\r?\n')
Test-Case 'the plan says which was used'        $true ($svcSrc -match "'yes, no /ResetBase'")

# ResetBase stays the default: for an image about to ship it is what you want,
# and the middle option has to be chosen rather than drifted into.
Test-Case 'ResetBase is still the default' $true ($svcSrc -match "else \{ 'yes, /ResetBase' \}")

foreach ($f in @('Start-WimForgeGui.ps1', 'Start-WimForgeMenu.ps1')) {
    $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw

    # The warning belongs where the decision is made. By the time the run logs
    # its plan the operator has already walked away.
    Test-Case "$f warns before the run" $true ($src -match 'superseded payload|supersedes')
    Test-Case "$f names the real cost"  $true ($src -match 'dismount takes considerably longer|takes considerably longer')
    Test-Case "$f offers the middle option" $true ($src -match 'without /ResetBase')
    Test-Case "$f passes it through"        $true ($src -match 'KeepUninstall')
}

# Setting .Checked inside a CheckedChanged handler re-enters it -- the same
# WinForms trap as the job-drain re-entrancy, and it would fire the dialog twice.
$gui2 = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeGui.ps1') -Raw
Test-Case 'the checkbox handler guards re-entry' $true ($gui2 -match 'if \(\$script:SvcCleanupBusy\) \{ return \}')
Test-Case 'and releases the guard'               $true ($gui2 -match 'finally \{ \$script:SvcCleanupBusy = \$false \}')

Remove-Item -LiteralPath $updates -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
