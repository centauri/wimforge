# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Get-WfImageInfo: the index table both front-ends show before anyone picks an
# index. Nothing here mounts; it is all the WIM header.

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

function Write-WfLog   { param([string]$Message, [string]$Level) }
function Assert-WfPath { param([string]$Path, [string]$Label) return $Path }

$script:Images = @()
function Get-WindowsImage {
    param([string]$ImagePath, [int]$Index, [switch]$Mounted, [string]$ErrorAction)
    return @($script:Images)
}

Write-Host 'A Microsoft media boot.wim' -ForegroundColor Cyan
# The distinction that costs a rollout: index 2 is what WDS boots.
$script:Images = @(
    [pscustomobject]@{ ImageIndex=1; ImageName='Microsoft Windows PE (x64)'; ImageDescription='Microsoft Windows PE (x64)'
                       EditionId='WindowsPE'; Architecture=9; Version='10.0.26100'; Languages=@('en-US'); ImageSize=(1.6GB) },
    [pscustomobject]@{ ImageIndex=2; ImageName='Microsoft Windows Setup (x64)'; ImageDescription='Microsoft Windows Setup (x64)'
                       EditionId='WindowsPE'; Architecture=9; Version='10.0.26100'; Languages=@('en-US'); ImageSize=(1.8GB) }
)
$r = @(Get-WfImageInfo -ImagePath 'X:\boot.wim')

Test-Case 'both indexes'      2 $r.Count
Test-Case 'PE named'          'base WinPE' $r[0].Note
Test-Case 'setup called out'  $true ([bool]($r[1].Note -match 'WDS boots'))
Test-Case 'architecture'      'x64' $r[1].Architecture
Test-Case 'size'              1.8 $r[1].SizeGB

Write-Host 'Retail install.wim, where the names barely differ' -ForegroundColor Cyan
# This is the other way to pick the wrong index, so edition has to be visible.
$script:Images = @(
    [pscustomobject]@{ ImageIndex=1; ImageName='Windows 11 Pro'; ImageDescription='Windows 11 Pro'
                       EditionId='Professional'; Architecture=9; Version='10.0.26100'; Languages=@('en-US','nl-NL'); ImageSize=(17GB) },
    [pscustomobject]@{ ImageIndex=2; ImageName='Windows 11 Pro N'; ImageDescription='Windows 11 Pro N'
                       EditionId='ProfessionalN'; Architecture=9; Version='10.0.26100'; Languages=@('en-US'); ImageSize=(16GB) }
)
$r2 = @(Get-WfImageInfo -ImagePath 'X:\install.wim')
Test-Case 'editions distinguish them' @('Professional','ProfessionalN') @($r2 | ForEach-Object { $_.EditionId })
Test-Case 'languages joined'          'en-US, nl-NL' $r2[0].Languages
Test-Case 'no note where none applies' '' $r2[0].Note

Write-Host 'A single-index capture' -ForegroundColor Cyan
$script:Images = @(
    [pscustomobject]@{ ImageIndex=1; ImageName='LTSC 2024 POS'; ImageDescription=''
                       EditionId='IoTEnterpriseS'; Architecture=9; Version='10.0.26100'; Languages=@('en-US'); ImageSize=(18GB) }
)
$r3 = @(Get-WfImageInfo -ImagePath 'X:\base.wim')
Test-Case 'one'          1 $r3.Count
Test-Case 'said so'      'the only index' $r3[0].Note
Test-Case 'edition kept' 'IoTEnterpriseS' $r3[0].EditionId

Write-Host 'ARM64 decodes rather than showing 12' -ForegroundColor Cyan
$script:Images = @(
    [pscustomobject]@{ ImageIndex=1; ImageName='Windows 11 Enterprise'; ImageDescription=''
                       EditionId='Enterprise'; Architecture=12; Version='10.0.26100'; Languages=@('en-US'); ImageSize=(15GB) }
)
Test-Case 'arm64' 'arm64' (@(Get-WfImageInfo -ImagePath 'X:\arm.wim'))[0].Architecture

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
