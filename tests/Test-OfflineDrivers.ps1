# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The no-mount driver list, and the version blob decoder.
#
# The decoder is the risky part: the layout of that registry value is not
# documented, so the rule is that it must produce nothing rather than something
# wrong. A fabricated driver date in a hardware validation document is worse
# than a blank one.

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

function New-Blob {
    <# date at $DateAt, packed version at $VerAt, guid at $GuidAt #>
    param([datetime] $Date, [int[]] $Version, [guid] $Guid,
          [int] $DateAt = 0, [int] $VerAt = 8, [int] $GuidAt = 16)

    $b = New-Object byte[] 32
    [Array]::Copy([BitConverter]::GetBytes($Date.ToFileTimeUtc()), 0, $b, $DateAt, 8)

    $packed = ([uint64]$Version[0] -shl 48) -bor ([uint64]$Version[1] -shl 32) -bor
              ([uint64]$Version[2] -shl 16) -bor  [uint64]$Version[3]
    [Array]::Copy([BitConverter]::GetBytes($packed), 0, $b, $VerAt, 8)
    [Array]::Copy($Guid.ToByteArray(), 0, $b, $GuidAt, 16)
    return $b
}

$netClass = [guid]'4d36e972-e325-11ce-bfc1-08002be10318'

Write-Host 'Version blob: the ordinary layout' -ForegroundColor Cyan
$d = New-Blob -Date ([datetime]'2025-11-04') -Version @(10,0,19041,1234) -Guid $netClass
$r = ConvertFrom-WfDriverVersionBlob -Blob $d
Test-Case 'date'    '2025-11-04'        $r.Date.ToString('yyyy-MM-dd')
Test-Case 'version' '10.0.19041.1234'   $r.Version
Test-Case 'guid'    $netClass           $r.ClassGuid

Write-Host 'Version blob: the other plausible ordering' -ForegroundColor Cyan
# The layout is undocumented, so both orderings are tried and the credible one
# wins. This is the one where the GUID comes first.
$d2 = New-Blob -Date ([datetime]'2024-06-01') -Version @(6,0,9200,17) -Guid $netClass -DateAt 16 -VerAt 24 -GuidAt 0
$r2 = ConvertFrom-WfDriverVersionBlob -Blob $d2
Test-Case 'date'    '2024-06-01'   $r2.Date.ToString('yyyy-MM-dd')
Test-Case 'version' '6.0.9200.17'  $r2.Version
Test-Case 'guid'    $netClass      $r2.ClassGuid

Write-Host 'Version blob: nonsense produces nothing, not a guess' -ForegroundColor Cyan
$junk = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $junk[$i] = 0xFF }      # date would be year 30828
$r3 = ConvertFrom-WfDriverVersionBlob -Blob $junk
Test-Case 'no date'    $true ($null -eq $r3.Date)
Test-Case 'no version' $true ($null -eq $r3.Version)

$r4 = ConvertFrom-WfDriverVersionBlob -Blob $null
Test-Case 'null blob'  $true ($null -eq $r4.Date)

$r5 = ConvertFrom-WfDriverVersionBlob -Blob (New-Object byte[] 8)
Test-Case 'short blob' $true ($null -eq $r5.Date)

# All-zero is a real case: a driver package with no version recorded. FILETIME 0
# is 1601, which is outside the credible window, so it must come back empty.
$r6 = ConvertFrom-WfDriverVersionBlob -Blob (New-Object byte[] 32)
Test-Case 'all zero'   $true ($null -eq $r6.Date)

Write-Host 'A date in the future is not credible either' -ForegroundColor Cyan
$far = New-Blob -Date ((Get-Date).AddYears(40)) -Version @(1,0,0,0) -Guid $netClass
$r7  = ConvertFrom-WfDriverVersionBlob -Blob $far
Test-Case 'rejected'   $true ($null -eq $r7.Date)

Write-Host 'The package list survives an undecodable version' -ForegroundColor Cyan
# The list is the part that matters; it must not depend on the blob at all.
$r8 = ConvertFrom-WfDriverVersionBlob -Blob $junk
Test-Case 'still returns an object' $true ($null -ne $r8)

Write-Host 'Inf name comes out of the package key' -ForegroundColor Cyan
# Keys look like 'igdlh64.inf_amd64_9a8b7c6d5e4f3210'. The library is keyed on
# the original inf name, which is exactly what that prefix is.
foreach ($case in @(
    @{ Key = 'igdlh64.inf_amd64_9a8b7c6d5e4f3210'; Inf = 'igdlh64.inf' },
    @{ Key = 'e1d68x64.inf_amd64_0123456789abcdef'; Inf = 'e1d68x64.inf' },
    @{ Key = 'some.vendor.name.inf_x86_ffff';       Inf = 'some.vendor.name.inf' }
)) {
    $m = [regex]::Match($case.Key, '^(?<inf>.+?\.inf)_', 'IgnoreCase')
    $got = $case.Key
    if ($m.Success) { $got = $m.Groups['inf'].Value }
    Test-Case $case.Key $case.Inf $got
}

Write-Host 'A missing image is not an error, just an empty list' -ForegroundColor Cyan
function Write-WfLog { param([string]$Message, [string]$Level) }
function Join-WfPath { param([string]$Path, [string]$ChildPath) return (Join-Path $Path $ChildPath) }
$r9 = @(Get-WfImageDriverPackage -ImagePath (Join-Path ([IO.Path]::GetTempPath()) 'nope.wim'))
Test-Case 'empty array' 0 $r9.Count

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
