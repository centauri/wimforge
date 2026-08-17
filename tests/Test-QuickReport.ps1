# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Get-WfImageReport -Quick: the no-mount half of the inventory.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Public\Updates.ps1')     # ConvertTo-WfArchitectureName
. (Join-Path $root 'WimForge\Public\Servicing.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

$fakeWim = Join-Path ([IO.Path]::GetTempPath()) 'wf-report-image.wim'
Set-Content -LiteralPath $fakeWim -Value ('x' * 4096) -Force

$script:Cv    = @{}
$script:Calls = @()

function Get-WfConfig      { @{ MountPath = 'C:\WimMount' } }
function Write-WfLog       { param([string]$Message, [string]$Level) $script:Logged += @("$Level|$Message") }
function Assert-WfElevated { }
function Assert-WfPath     { param([string]$Path, [string]$Label) return $Path }
function New-WfDirectory   { param([string]$Path) $script:Calls += 'newdir'; return $Path }
function Mount-WindowsImage   { $script:Calls += 'mount' }
function Dismount-WindowsImage { $script:Calls += 'dismount' }
function Join-WfPath { param([string]$Path, [string]$ChildPath) return (Join-Path $Path $ChildPath) }
function Get-WfImageCurrentVersion {
    param([string]$ImagePath, [int]$Index, [switch]$Refresh)
    $script:Calls += 'extract'
    return $script:Cv
}
$script:Drivers = @()
function Get-WfImageDriverPackage {
    param([string]$ImagePath, [int]$Index)
    $script:Calls += 'drivers'
    return @($script:Drivers)
}
function Get-WindowsImage {
    param([string]$ImagePath, [int]$Index, [string]$ErrorAction)
    [pscustomobject]@{ ImageName='LTSC 2024 POS'; Architecture=9; EditionId='IoTEnterpriseS'
                       Version='10.0.26100'; SPBuild=1000; ImageSize=(18GB) }
}

Write-Host 'Quick report reads the image without mounting it' -ForegroundColor Cyan
$script:Calls = @(); $script:Logged = @()
$script:Cv = @{ CurrentBuild='26100'; UBR=1742; DisplayVersion='24H2'; EditionID='IoTEnterpriseS' }
$script:Drivers = @(
    [pscustomobject]@{ Driver='e1d68x64.inf'; ClassName='Net';     ProviderName='Intel'; Version='12.19.2.45'; Date=(Get-Date '2025-03-04') },
    [pscustomobject]@{ Driver='igdlh64.inf';  ClassName='Display'; ProviderName='Intel'; Version='31.0.101.5';  Date=(Get-Date '2025-05-09') },
    [pscustomobject]@{ Driver='rtux64.inf';   ClassName='Net';     ProviderName='Realtek'; Version=$null;       Date=$null }
)
$r = Get-WfImageReport -ImagePath $fakeWim -Index 1 -Quick

Test-Case 'no mount, both reads' @('extract','drivers') $script:Calls
Test-Case 'driver count'  3 $r.DriverCount
Test-Case 'grouped by class' 'Net=2, Display=1' $r.DriversByClass
# Updates need a mount, so they are unknown here -- not zero, which would read
# as "this image has no updates in it".
Test-Case 'updates unknown, not zero' $true ($null -eq $r.UpdateCount)
Test-Case 'scope'        'quick'        $r.Scope
Test-Case 'name'         'LTSC 2024 POS' $r.ImageName
Test-Case 'release'      '24H2'         $r.Release
Test-Case 'edition'      'IoTEnterpriseS' $r.EditionId
Test-Case 'architecture' 'x64'          $r.Architecture
# The UBR comes from the registry, not the header's SPBuild -- the header's is
# the media's UBR and does not move when the image is serviced.
Test-Case 'build.ubr'    '10.0.26100.1742' $r.FullBuild
Test-Case 'image size'   18                $r.SizeGB


Write-Host 'When the registry cannot be read it says so and uses the header' -ForegroundColor Cyan
$script:Calls = @(); $script:Logged = @(); $script:Drivers = @()
$script:Cv = @{}
$r2 = Get-WfImageReport -ImagePath $fakeWim -Index 1 -Quick
Test-Case 'header version' '10.0.26100'      $r2.Version
Test-Case 'header SPBuild' '10.0.26100.1000' $r2.FullBuild
Test-Case 'warned'         $true ([bool]($script:Logged -match 'may name the wrong release'))
Test-Case 'no release'     ''    $r2.Release
Test-Case 'no drivers either, and not zero' $true ($null -eq $r2.DriverCount)

Remove-Item -LiteralPath $fakeWim -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
