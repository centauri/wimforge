# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Superseded-copy removal, against a fixture built from a real harvest.
#
# The numbers here are from an actual Dell Pro 14 harvest: 9 copies of
# ibtusb.inf, 7 of iigd_ext.inf, 3 of socthermalprovider_sw.inf. That is what a
# year-old laptop's driver store looks like, and all of it was being exported.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Private\Core.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

# Select-WfNewestDriverPackage lives in Drivers.ps1 next to its callers, but it
# needs none of them.
$drivers = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Drivers.ps1') -Raw
$start   = $drivers.IndexOf('function Select-WfNewestDriverPackage')
$end     = $drivers.IndexOf('function Get-WfExportedPackageFolder')
Invoke-Expression $drivers.Substring($start, $end - $start)

function New-Pkg {
    param([string] $Key, [string] $Id, [string] $Version, [string] $Date)
    [pscustomobject]@{ Key = $Key; Id = $Id; Version = $Version; Date = $Date }
}

Write-Host 'Newest version wins' -ForegroundColor Cyan
$r = Select-WfNewestDriverPackage -Package @(
    (New-Pkg 'ibtusb.inf' 'a' '22.120.0.4'  '01/15/2024'),
    (New-Pkg 'ibtusb.inf' 'b' '23.60.0.2'   '11/02/2024'),
    (New-Pkg 'ibtusb.inf' 'c' '23.100.0.3'  '06/11/2025')
)
Test-Case 'one kept'   1 $r.Keep.Count
Test-Case 'the newest' 'c' $r.Keep[0].Id
Test-Case 'two dropped' @('a','b') @($r.Drop | ForEach-Object { $_.Id } | Sort-Object)

Write-Host 'Version is compared as a version, not as text' -ForegroundColor Cyan
# The trap: '9.60.0.1' sorts after '23.100.0.3' as a string, so a text compare
# keeps a driver two years out of date.
$r2 = Select-WfNewestDriverPackage -Package @(
    (New-Pkg 'x.inf' 'old' '9.60.0.1'   '01/01/2022'),
    (New-Pkg 'x.inf' 'new' '23.100.0.3' '06/11/2025')
)
Test-Case 'kept the higher version' 'new' $r2.Keep[0].Id

Write-Host 'Date breaks a version tie' -ForegroundColor Cyan
$r3 = Select-WfNewestDriverPackage -Package @(
    (New-Pkg 'y.inf' 'older' '1.0.0.1' '03/04/2023'),
    (New-Pkg 'y.inf' 'newer' '1.0.0.1' '09/17/2025')
)
Test-Case 'later date wins' 'newer' $r3.Keep[0].Id

Write-Host 'A package with no usable version loses to one that has' -ForegroundColor Cyan
$r4 = Select-WfNewestDriverPackage -Package @(
    (New-Pkg 'z.inf' 'nover' $null      $null),
    (New-Pkg 'z.inf' 'ver'   '2.1.0.0' '01/01/2025')
)
Test-Case 'the described one wins' 'ver' $r4.Keep[0].Id

Write-Host 'Different inf names are never compared' -ForegroundColor Cyan
# This is the safety property. Two different drivers must both survive however
# their versions compare.
$r5 = Select-WfNewestDriverPackage -Package @(
    (New-Pkg 'netwtw6e.inf' 'wifi'  '23.100.0.3' '06/11/2025'),
    (New-Pkg 'ibtusb.inf'   'bt'    '1.0.0.0'    '01/01/2020')
)
Test-Case 'both kept'    2 $r5.Keep.Count
Test-Case 'none dropped' 0 $r5.Drop.Count

Write-Host 'Case does not make two packages different' -ForegroundColor Cyan
$r6 = Select-WfNewestDriverPackage -Package @(
    (New-Pkg 'IBTUSB.INF' 'upper' '1.0.0.0' '01/01/2024'),
    (New-Pkg 'ibtusb.inf' 'lower' '2.0.0.0' '01/01/2025')
)
Test-Case 'treated as one' 1 $r6.Keep.Count
Test-Case 'newest wins'    'lower' $r6.Keep[0].Id

Write-Host 'Nothing in, nothing out' -ForegroundColor Cyan
$r7 = Select-WfNewestDriverPackage -Package @()
Test-Case 'no keeps' 0 $r7.Keep.Count
Test-Case 'no drops' 0 $r7.Drop.Count

Write-Host 'The real harvest' -ForegroundColor Cyan
# Rebuilt from the folder listing of an actual Dell Pro 14 harvest.
$real = @()
$counts = @{
    'ibtusb.inf' = 9; 'iigd_ext.inf' = 7; 'socthermalprovider_sw.inf' = 3
    'cui_dch.inf' = 2; 'cvusbdrv.inf' = 2; 'dellinstrumentation.inf' = 2
    'dtt_sw.inf' = 2; 'firmware.inf' = 2; 'hideventfilter.inf' = 2
    'iastorhsacomponent.inf' = 2; 'iastorvd.inf' = 2; 'intcdaud.inf' = 2
    'intcpmt.inf' = 2; 'ipf_acpi.inf' = 2; 'netwtw6e.inf' = 2
    'npu.inf' = 2; 'npu_extension.inf' = 2; 'raptorlakesystem.inf' = 2
    'alderlakepch-ssystem.inf' = 2; 'igcl_ipf_provider_ext.inf' = 2
    'igcl_ipf_provider_sw.inf' = 2; 'kpe_apo_win.inf' = 2
    'modsprovider_sw.inf' = 2; 'mshdadac.inf' = 2
    'perfmonprovider_sw.inf' = 2; 'rt68cx21x64.inf' = 2
    'socthermalprovider_ext.inf' = 2; 'systemconfigprovider_sw.inf' = 2
    'voiceclarityep_audio_component.inf' = 2
}
foreach ($inf in $counts.Keys) {
    for ($i = 1; $i -le $counts[$inf]; $i++) {
        $real += New-Pkg $inf "$inf#$i" "1.0.0.$i" ("01/0$([Math]::Min($i,9))/2025")
    }
}
# ...plus a few that appear only once and must all survive.
foreach ($single in @('e1d.inf','rt640x64.inf','wintun.inf','goodixmocusb.inf')) {
    $real += New-Pkg $single "$single#1" '1.0.0.0' '01/01/2025'
}

$r8 = Select-WfNewestDriverPackage -Package $real
# 29 duplicated inf names plus 4 singles; 71 packages in, 33 out, 42 removed --
# the same 42 counted off the real folder listing.
Test-Case 'names counted'      29 $counts.Keys.Count
Test-Case 'packages in'        71 ($real.Count - 4)
Test-Case 'one per inf kept'   ($counts.Keys.Count + 4) $r8.Keep.Count
Test-Case 'the rest dropped'   42 $r8.Drop.Count
Test-Case 'nine ibtusb become one' 1 @($r8.Keep | Where-Object { $_.Key -eq 'ibtusb.inf' }).Count
Test-Case 'and it is the newest'   'ibtusb.inf#9' (@($r8.Keep | Where-Object { $_.Key -eq 'ibtusb.inf' })[0].Id)
Test-Case 'singles all survive'    4 @($r8.Keep | Where-Object { $_.Id -like '*#1' -and $_.Key -in @('e1d.inf','rt640x64.inf','wintun.inf','goodixmocusb.inf') }).Count

Write-Host 'DriverVer parsing' -ForegroundColor Cyan
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wf-dv-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function New-Inf { param([string]$Name,[string]$Body)
    $p = Join-Path $tmp $Name; Set-Content -LiteralPath $p -Value $Body -Force; return $p }

$a = New-Inf 'both.inf' "[Version]`r`nDriverVer = 07/12/2024,23.40.1.5"
Test-Case 'date'    '07/12/2024'  (Get-WfInfDriverVer $a).Date
Test-Case 'version' '23.40.1.5'   (Get-WfInfDriverVer $a).Version

$b = New-Inf 'spaced.inf' "[Version]`r`nDriverVer= 12/31/2025 , 1.2.3.4   ; a comment"
Test-Case 'whitespace and comment' '1.2.3.4' (Get-WfInfDriverVer $b).Version

# Legal, and it happens: a version with no date.
$c = New-Inf 'versiononly.inf' "[Version]`r`nDriverVer = 10.0.19041.1"
Test-Case 'version only, no date' $true ($null -eq (Get-WfInfDriverVer $c).Date)
Test-Case 'and the version reads' '10.0.19041.1' (Get-WfInfDriverVer $c).Version

$d = New-Inf 'none.inf' "[Version]`r`nClass = Net"
Test-Case 'no DriverVer' $true ($null -eq (Get-WfInfDriverVer $d).Version)

Test-Case 'missing file' $true ($null -eq (Get-WfInfDriverVer (Join-Path $tmp 'nope.inf')).Version)

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
