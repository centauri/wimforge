# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Get-WfImageUpdateTarget with DISM stubbed out. Every branch that decides what
# to search for is exercised here, because the alternative is finding out on a
# real image at the end of a twenty-minute mount.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Public\Updates.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

# --------------------------------------------------------------------- the fake
$fakeWim = Join-Path ([IO.Path]::GetTempPath()) 'wf-fake-image.wim'
Set-Content -LiteralPath $fakeWim -Value 'not really a wim' -Force

$script:Mounted   = @()      # what Get-WindowsImage -Mounted answers
$script:Header    = $null    # what the WIM header answers
$script:Hive      = @{}      # what a MOUNTED image's registry answers
$script:Extract   = @{}      # what the no-mount extraction answers
$script:Packages  = @()
$script:Elevated  = $true
$script:MountDirty = $false
$script:Calls     = @()

function Get-WfConfig {
    @{ MountPath = 'C:\WimMount'; BaseImage = 'C:\Images\Base.wim'
       UpdateProduct = 'Configured Product'; UpdateArchitecture = 'x64' }
}
function Write-WfLog     { param([string]$Message, [string]$Level) }
function Test-WfElevated { $script:Elevated }
function New-WfDirectory { param([string]$Path) $script:Calls += 'newdir'; return $Path }
function Get-ChildItem   { param([string]$LiteralPath, [switch]$Force)
                           if ($script:MountDirty) { return @('leftover') }; return @() }
function Mount-WindowsImage {
    param([string]$ImagePath, [int]$Index, [string]$Path, [switch]$ReadOnly, [string]$ErrorAction)
    $script:Calls += "mount:$ImagePath#$Index"
}
function Dismount-WindowsImage {
    param([string]$Path, [switch]$Discard, [string]$ErrorAction)
    $script:Calls += 'dismount'
}
function Get-WindowsImage {
    param([switch]$Mounted, [string]$ImagePath, [int]$Index, [string]$ErrorAction)
    if ($Mounted) { return @($script:Mounted) }
    if ($null -eq $script:Header) { throw 'no header' }
    return $script:Header
}
function Get-WindowsPackage {
    param([string]$Path, [string]$ErrorAction)
    return @($script:Packages)
}
function Get-WfOfflineCurrentVersion { param([string]$MountPath) return $script:Hive }
function Get-WfImageCurrentVersion {
    param([string]$ImagePath, [int]$Index, [switch]$Refresh)
    $script:Calls += 'extract'
    return $script:Extract
}

function Reset-Fakes {
    $script:Mounted    = @()
    $script:Header     = [pscustomobject]@{ ImageName='LTSC 2021 POS'; Architecture=9
                                            EditionId='IoTEnterpriseS'; Version='10.0.19041'; SPBuild=1288 }
    $script:Hive       = @{}
    $script:Extract    = @{}
    $script:Packages   = @()
    $script:Elevated   = $true
    $script:MountDirty = $false
    $script:Calls      = @()
}

# ------------------------------------------------------------------- the tests
Write-Host 'Falls back to mounting when the direct read fails' -ForegroundColor Cyan
Reset-Fakes
$script:Hive = @{ CurrentBuild='19044'; UBR=7417; DisplayVersion='21H2'; EditionID='IoTEnterpriseS' }
$script:Packages = @(
    [pscustomobject]@{ PackageName='Package_for_RollupFix~31bf3856ad364e35~amd64~~19044.7417.1.10'; PackageState='Installed' },
    [pscustomobject]@{ PackageName='Package_for_KB5011048~31bf3856ad364e35~amd64~~19044.1.1';       PackageState='Installed' },
    [pscustomobject]@{ PackageName='Package_for_KB5099999~31bf3856ad364e35~amd64~~19044.1.1';       PackageState='Superseded' }
)
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1

Test-Case 'tried the fast read first' @("extract","newdir","mount:$fakeWim#1","dismount") $script:Calls
Test-Case 'product from the hive'   'Windows 10 Version 21H2' $t.Product
Test-Case 'alternative is 22H2'     @('Windows 10 Version 22H2') $t.ProductAlternative
Test-Case 'architecture decoded'    'x64'   $t.Architecture
Test-Case 'build and ubr'           '19044.7417' $t.FullBuild
Test-Case 'ltsc spotted'            $true   $t.IsLtsc
Test-Case 'precise'                 $true   $t.Precise
Test-Case 'source'                  'mounted image' $t.Source
Test-Case 'only installed KBs'      @('KB5011048') $t.InstalledKB
Test-Case 'package count'           2 $t.PackageCount
Test-Case 'no notes'                0 @($t.Notes).Count

Write-Host 'Uses a mount that is already there, and leaves it alone' -ForegroundColor Cyan
Reset-Fakes
$script:Mounted = @([pscustomobject]@{ Path='C:\WimMount'; ImagePath='C:\Images\Base.wim'; ImageIndex=1 })
$script:Hive    = @{ CurrentBuild='19044'; UBR=7417; DisplayVersion='21H2' }
$t = Get-WfImageUpdateTarget
Test-Case 'nothing mounted or dismounted' 0 $script:Calls.Count
Test-Case 'took the mounted image'  'C:\Images\Base.wim' $t.ImagePath
Test-Case 'product'                 'Windows 10 Version 21H2' $t.Product

Write-Host 'Header only: the 19041 family cannot be pinned down' -ForegroundColor Cyan
Reset-Fakes
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1 -NoMount
Test-Case 'tried to extract, did not mount' @('extract') $script:Calls
Test-Case 'not precise'            $false  $t.Precise
Test-Case 'guessed the newest'     'Windows 10 Version 22H2' $t.Product
Test-Case 'ubr from SPBuild'       '19041.1288' $t.FullBuild
Test-Case 'said so'                $true   ([bool](@($t.Notes) -match 'cannot tell one release'))

Write-Host 'Unelevated degrades instead of throwing' -ForegroundColor Cyan
Reset-Fakes
$script:Elevated = $false
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1
Test-Case 'did not read or mount'  0      $script:Calls.Count
Test-Case 'still has architecture' 'x64'  $t.Architecture
Test-Case 'note about elevation'   $true  ([bool](@($t.Notes) -match 'Not elevated'))

Write-Host 'A dirty mount folder is reported, not blundered into' -ForegroundColor Cyan
Reset-Fakes
$script:MountDirty = $true
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1
Test-Case 'no mount attempted'  @('extract','newdir') $script:Calls
Test-Case 'note names the fix'  $true ([bool](@($t.Notes) -match 'Repair-WfMount'))

Write-Host 'The fast path: read the hive out of the .wim, no mount at all' -ForegroundColor Cyan
Reset-Fakes
$script:Extract = @{ CurrentBuild='26100'; UBR=1742; DisplayVersion='24H2'; EditionID='IoTEnterpriseS' }
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1
Test-Case 'extracted, never mounted' @('extract') $script:Calls
Test-Case 'product'   'Windows 11 Version 24H2' $t.Product
Test-Case 'precise'   $true         $t.Precise
Test-Case 'source'    'image file'  $t.Source
Test-Case 'build'     '26100.1742'  $t.FullBuild
Test-Case 'no packages without a mount' 0 $t.PackageCount

Write-Host '-NoMount is no obstacle when the file can be read directly' -ForegroundColor Cyan
Reset-Fakes
$script:Extract = @{ CurrentBuild='19044'; UBR=7417; DisplayVersion='21H2' }
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1 -NoMount
Test-Case 'still exact'   $true $t.Precise
Test-Case 'no mount'      @('extract') $script:Calls
Test-Case 'no complaints' 0 @($t.Notes).Count

Write-Host '-IncludePackage costs a mount, and says what it bought' -ForegroundColor Cyan
Reset-Fakes
$script:Extract  = @{ CurrentBuild='19044'; UBR=7417; DisplayVersion='21H2' }
$script:Hive     = @{ CurrentBuild='19044'; UBR=7417; DisplayVersion='21H2'; EditionID='IoTEnterpriseS' }
$script:Packages = @([pscustomobject]@{ PackageName='Package_for_KB5011048~amd64~~19044.1.1'; PackageState='Installed' })
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1 -IncludePackage
Test-Case 'mounted for the packages' @("newdir","mount:$fakeWim#1","dismount") $script:Calls
Test-Case 'got the KBs'   @('KB5011048') $t.InstalledKB
Test-Case 'still precise' $true $t.Precise

Write-Host '-IncludePackage with -NoMount gives up the packages, not the release' -ForegroundColor Cyan
Reset-Fakes
$script:Extract = @{ CurrentBuild='19044'; UBR=7417; DisplayVersion='21H2' }
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1 -IncludePackage -NoMount
Test-Case 'no mount'          0 (@($script:Calls | Where-Object { $_ -like 'mount*' })).Count
Test-Case 'no packages'       0 $t.PackageCount
Test-Case 'said what it skipped' $true ([bool](@($t.Notes) -match 'package list was skipped'))
# The release is still exact: no mount was coming, so the direct read was worth
# doing even though the packages were what was asked for.
Test-Case 'release still exact'  $true $t.Precise
Test-Case 'product'              'Windows 10 Version 21H2' $t.Product

Write-Host 'Windows 11' -ForegroundColor Cyan
Reset-Fakes
$script:Header = [pscustomobject]@{ ImageName='Win11 Ent'; Architecture='ARM64'
                                    EditionId='Enterprise'; Version='10.0.22621'; SPBuild=3737 }
$script:Hive   = @{ CurrentBuild='22631'; UBR=3737; DisplayVersion='23H2'; EditionID='Enterprise' }
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1
Test-Case 'family'        'Windows 11' $t.OsFamily
Test-Case 'product'       'Windows 11 Version 23H2' $t.Product
Test-Case 'no later ones' 0 @($t.ProductAlternative).Count
Test-Case 'arm64 kept'    'arm64' $t.Architecture
Test-Case 'not ltsc'      $false  $t.IsLtsc

Write-Host 'An unreadable hive falls back to the header' -ForegroundColor Cyan
Reset-Fakes
$script:Mounted = @([pscustomobject]@{ Path='C:\WimMount'; ImagePath=$fakeWim; ImageIndex=1 })
$script:Hive    = @{}
$t = Get-WfImageUpdateTarget
Test-Case 'not precise'   $false $t.Precise
Test-Case 'note'          $true  ([bool](@($t.Notes) -match 'registry could not be read'))
Test-Case 'still guesses' 'Windows 10 Version 22H2' $t.Product

Write-Host 'The image still gets dismounted when reading blows up' -ForegroundColor Cyan
Reset-Fakes
# Extraction returns nothing, so this takes the mount path -- which is the one
# with something to clean up.
function Get-WfOfflineCurrentVersion { param([string]$MountPath) throw 'hive exploded' }
$threw = $false
try { Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1 } catch { $threw = $true }
Test-Case 'error surfaced'  $true $threw
Test-Case 'dismounted anyway' $true ($script:Calls -contains 'dismount')
function Get-WfOfflineCurrentVersion { param([string]$MountPath) return $script:Hive }
function Get-WfImageCurrentVersion {
    param([string]$ImagePath, [int]$Index, [switch]$Refresh)
    $script:Calls += 'extract'
    return $script:Extract
}

Write-Host 'A server image is not dressed up as a client one' -ForegroundColor Cyan
Reset-Fakes
$script:Header = [pscustomobject]@{ ImageName='Server 2025 Datacenter'; Architecture=9
                                    EditionId='ServerDatacenter'; Version='10.0.26100'; SPBuild=1742
                                    InstallationType='Server' }
$script:Hive   = @{ CurrentBuild='26100'; UBR=1742; DisplayVersion='24H2'
                    EditionID='ServerDatacenter'; InstallationType='Server'
                    ProductName='Windows Server 2025 Datacenter' }
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1
# Build 26100 alone would make this look like Windows 11 24H2 and send the
# search after a client cumulative.
Test-Case 'not called Windows 11'  'Windows Server 2025' $t.OsFamily

# And the search string is the catalog's, not the box's. Server 2025 updates are
# titled "Cumulative Update for Microsoft server operating system version 24H2";
# a search for "Windows Server 2025" returns nothing, which reads as "there is no
# update" rather than "you asked the wrong question".
Test-Case 'the catalog name is used' 'Microsoft server operating system version 24H2' $t.Product
Test-Case 'read from the image'      $true  $t.Precise
Test-Case 'said what it is'          $true  ([bool](@($t.Notes) -match 'server image'))
Test-Case 'and warned about the name' $true ([bool](@($t.Notes) -match "does not title its updates 'Windows Server'"))

# The obvious name is kept as a second attempt rather than thrown away.
Test-Case 'the obvious name is offered too' @('Windows Server 2025') @($t.ProductAlternative)

Write-Host 'Server 2022 gets the same treatment' -ForegroundColor Cyan
Reset-Fakes
$script:Header = [pscustomobject]@{ ImageName='Server 2022 Standard'; Architecture=9
                                    EditionId='ServerStandard'; Version='10.0.20348'; SPBuild=169
                                    InstallationType='Server' }
$script:Hive   = @{ CurrentBuild='20348'; UBR=169; EditionID='ServerStandard'
                    InstallationType='Server'; ProductName='Windows Server 2022 Standard' }
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1
# "version 21H2" here has nothing to do with Windows 10 21H2, which is a
# different build, a different package and a different image entirely.
Test-Case 'the catalog name again' 'Microsoft server operating system version 21H2' $t.Product

Write-Host 'A server build with no catalog name is admitted, not invented' -ForegroundColor Cyan
Reset-Fakes
$script:Header = [pscustomobject]@{ ImageName='Server vNext'; Architecture=9
                                    EditionId='ServerDatacenter'; Version='10.0.30000'; SPBuild=1
                                    InstallationType='Server' }
$script:Hive   = @{ CurrentBuild='30000'; UBR=1; EditionID='ServerDatacenter'
                    InstallationType='Server'; ProductName='Windows Server vNext' }
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1
Test-Case 'the configured product is kept' 'Configured Product' $t.Product
Test-Case 'and not claimed as precise'     $false $t.Precise
Test-Case 'with the reason'                $true ([bool](@($t.Notes) -match 'not one this toolkit has a catalog name for'))

Write-Host 'A build past the end of the table is admitted, not guessed' -ForegroundColor Cyan
Reset-Fakes
$script:Header = [pscustomobject]@{ ImageName='Future'; Architecture=9; EditionId='Enterprise'
                                    Version='10.0.29000'; SPBuild=100 }
$script:Hive   = @{ CurrentBuild='29000'; UBR=100; EditionID='Enterprise' }   # no DisplayVersion
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1
Test-Case 'hive read but no release' $false $t.Precise
Test-Case 'configured product kept'  'Configured Product' $t.Product
Test-Case 'build still reported'     '29000.100' $t.FullBuild

Write-Host 'Hive without DisplayVersion still resolves a known build' -ForegroundColor Cyan
Reset-Fakes
$script:Hive = @{ CurrentBuild='17763'; UBR=7314; EditionID='EnterpriseS' }   # LTSC 2019, pre-DisplayVersion
$t = Get-WfImageUpdateTarget -ImagePath $fakeWim -Index 1
Test-Case 'release from the table' 'Windows 10 Version 1809' $t.Product
Test-Case 'exact build, so precise' $true $t.Precise
Test-Case 'no family to fall back to' 0 @($t.ProductAlternative).Count

Write-Host 'Nothing to read at all' -ForegroundColor Cyan
Reset-Fakes
$message = ''
try { Get-WfImageUpdateTarget } catch { $message = $_.Exception.Message }
Test-Case 'says what to do' $true ([bool]($message -match 'Pass -ImagePath'))

Remove-Item -LiteralPath $fakeWim -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
