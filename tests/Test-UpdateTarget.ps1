# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Unit tests for the pure parts of the image-target detection.
# These need no DISM, no image and no network, so they run anywhere.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Public\Updates.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ',')
    $a = ($Actual   -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else {
        Write-Host "  FAIL $Name" -ForegroundColor Red
        Write-Host "       expected [$e]  got [$a]" -ForegroundColor Red
        $script:Fail++
    }
}

Write-Host 'Build to release' -ForegroundColor Cyan
Test-Case '19044 is 21H2'      '21H2' (Get-WfWindowsRelease -Build 19044)
Test-Case '19045 is 22H2'      '22H2' (Get-WfWindowsRelease -Build 19045)
Test-Case '17763 is 1809'      '1809' (Get-WfWindowsRelease -Build 17763)
Test-Case '22631 is 23H2'      '23H2' (Get-WfWindowsRelease -Build 22631)
Test-Case '26100 is 24H2'      '24H2' (Get-WfWindowsRelease -Build 26100)
Test-Case 'unknown build null' ''     (Get-WfWindowsRelease -Build 12345)

Write-Host 'Later releases in the same servicing family' -ForegroundColor Cyan
# A 21H2 image (LTSC 2021) must be able to fall back to 22H2: one package,
# titled with the newest release still serviced.
Test-Case '21H2 falls back to 22H2'   @('22H2')       (Get-WfLaterRelease -Build 19044 -Release '21H2')
Test-Case '2004 falls back newest-first' @('22H2','21H2','21H1','20H2') (Get-WfLaterRelease -Build 19041 -Release '2004')
Test-Case '22H2 is the newest already'   @()          (Get-WfLaterRelease -Build 19045 -Release '22H2')
Test-Case '22H2 (win11) to 23H2'         @('23H2')    (Get-WfLaterRelease -Build 22621 -Release '22H2')
Test-Case '24H2 to 25H2'                 @('25H2')    (Get-WfLaterRelease -Build 26100 -Release '24H2')
Test-Case 'build outside any family'     @()          (Get-WfLaterRelease -Build 17763 -Release '1809')
Test-Case 'release not in its family'    @()          (Get-WfLaterRelease -Build 19044 -Release 'nonsense')

Write-Host 'Architecture names' -ForegroundColor Cyan
Test-Case 'numeric 9 is x64'    'x64'   (ConvertTo-WfArchitectureName 9)
Test-Case 'numeric 0 is x86'    'x86'   (ConvertTo-WfArchitectureName 0)
Test-Case 'numeric 12 is arm64' 'arm64' (ConvertTo-WfArchitectureName 12)
Test-Case 'text x64'            'x64'   (ConvertTo-WfArchitectureName 'x64')
Test-Case 'text AMD64'          'x64'   (ConvertTo-WfArchitectureName 'AMD64')
Test-Case 'text ARM64 cased'    'arm64' (ConvertTo-WfArchitectureName 'ARM64')
Test-Case 'null is empty'       ''      (ConvertTo-WfArchitectureName $null)
Test-Case 'unknown passes through' 'ia64' (ConvertTo-WfArchitectureName 'ia64')

Write-Host 'Category queries' -ForegroundColor Cyan
Test-Case 'cumulative' 'Cumulative Update for Windows 10 Version 21H2 x64' `
    (Get-WfCategoryQuery -Category 'Cumulative' -Product 'Windows 10 Version 21H2' -Architecture 'x64')
Test-Case 'defender ignores product' 'Update for Microsoft Defender Antivirus antimalware platform' `
    (Get-WfCategoryQuery -Category 'Defender' -Product 'Windows 10 Version 21H2' -Architecture 'x64')

Write-Host 'Header-only guess (the 19041 family problem)' -ForegroundColor Cyan
# The WIM header reports 10.0.19041 for every image in the family. Reading it as
# 2004 would search for an update that has not shipped since 2021, so the
# detection takes the newest member instead.
$base   = Get-WfWindowsRelease -Build 19041
$newest = @(Get-WfLaterRelease -Build 19041 -Release $base)
Test-Case 'header 19041 guesses 22H2' '22H2' $newest[0]

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
