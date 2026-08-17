# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Display languages: the library, and the order they go into an image.
#
# The rule this file exists to pin is Microsoft's, and it is the one that costs
# money to get wrong:
#
#   "If an update package was added to the image before languages, reinstall the
#    update package after adding languages."
#
# Skip that and the image ends up with a language whose resources stop at the
# build its pack shipped with. Nothing fails, nothing logs, and the symptom is
# English strings scattered through a Dutch menu on a till that is already in a
# shop. So Add-WfLanguage either re-applies the update or says out loud that it
# still needs doing -- and both of those are checked here.
#
# The other half is that a display language is a PACKAGE and a region is a
# SETTING. Region can be set at will; a UI language cannot be set to something
# the image does not contain, because DISM says "the command will fail".

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
. (Join-Path $root 'WimForge\Public\DismErrors.ps1')
. (Join-Path $root 'WimForge\Public\Languages.ps1')

# ------------------------------------------------------------------ fixtures
$work = Join-Path ([IO.Path]::GetTempPath()) ('wf-lang-' + [guid]::NewGuid().ToString('N').Substring(0,6))
$iso  = Join-Path $work 'iso\LanguagesAndOptionalFeatures'
$lib  = Join-Path $work 'library'
New-Item -ItemType Directory -Path $iso -Force | Out-Null

# Real file names off the Languages ISO, and a couple of things that are not
# language packages at all -- an ISO is full of those and they must be ignored
# rather than copied into the library.
$isoFiles = @(
    'Microsoft-Windows-Client-Language-Pack_x64_nl-nl.cab'
    'Microsoft-Windows-LanguageFeatures-Basic-nl-nl-Package~31bf3856ad364e35~amd64~~.cab'
    'Microsoft-Windows-LanguageFeatures-Fonts-PanEuropeanSupplementalFonts-Package~31bf3856ad364e35~amd64~~.cab'
    'Microsoft-Windows-LanguageFeatures-OCR-nl-nl-Package~31bf3856ad364e35~amd64~~.cab'
    'Microsoft-Windows-LanguageFeatures-Speech-nl-nl-Package~31bf3856ad364e35~amd64~~.cab'
    'Microsoft-Windows-LanguageFeatures-TextToSpeech-nl-nl-Package~31bf3856ad364e35~amd64~~.cab'
    'Microsoft-Windows-LanguageFeatures-Handwriting-nl-nl-Package~31bf3856ad364e35~amd64~~.cab'
    'Microsoft-Windows-Client-Language-Pack_x64_sv-se.cab'
    'Microsoft-Windows-LanguageFeatures-Basic-sv-se-Package~31bf3856ad364e35~amd64~~.cab'
    'Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35~amd64~~.cab'
    'Microsoft-Windows-NetFx3-OnDemand-Package~31bf3856ad364e35~amd64~~.cab'
)
foreach ($f in $isoFiles) {
    # MSCF, so Add-WfPackageOffline routes these through the cmdlet rather than
    # dism.exe. Real bytes, because that decision is made by reading them.
    $bytes = New-Object byte[] 64
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('MSCF'), $bytes, 4)
    [IO.File]::WriteAllBytes((Join-Path $iso $f), $bytes)
}

# --------------------------------------------------------------------- stubs
function Get-WfConfig      { @{ LanguageRoot = $script:Lib; MountPath = 'C:\WimMount'; ScratchPath = $script:Scratch } }
function Write-WfLog       { param([string]$Message, [string]$Level, [switch]$NoConsole) $script:Logged += @("$Level|$Message") }
function Assert-WfElevated { }
function Write-WfHistory   { param($Action, $ImagePath, $Detail, $Notes) $script:History = $Detail }

$script:Lib     = $lib
$script:Scratch = (Join-Path $work 'scratch')
$script:Logged  = @()
$script:Applied = @()
$script:Present = @('en-US')
$script:HasLcu  = $true
$script:FailOn  = ''

function Add-WindowsPackage {
    param([string]$Path, [string]$PackagePath, [string]$ErrorAction, [string]$ScratchDirectory, [string]$LogPath)
    $leaf = Split-Path $PackagePath -Leaf
    if ($script:FailOn -and $leaf -like $script:FailOn) { throw "0x800f081e pretend failure on $leaf" }
    $script:Applied += $leaf
}
function Invoke-WfDism { param([string[]]$Arguments, [switch]$PassThruOutput) }
function Get-WfImageLocale {
    param([string]$MountPath)
    [pscustomobject]@{ UILanguage = 'en-US'; InstalledLanguages = @($script:Present) }
}
function Get-WindowsPackage {
    param([string]$Path, [string]$ErrorAction)
    if (-not $script:HasLcu) { return @() }
    return @([pscustomobject]@{ PackageName = 'Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8894.1.10' })
}

# ------------------------------------------------------------------- import
Write-Host 'Importing from the ISO takes the language files and nothing else' -ForegroundColor Cyan

$script:Logged = @()
$r = Import-WfLanguagePack -Source (Join-Path $work 'iso') -Language 'nl-NL' -LibraryRoot $lib -Confirm:$false
Test-Case 'one language imported' 'Imported' $r[0].Status

$landed = @(Get-ChildItem -LiteralPath (Join-Path $lib 'nl-nl') -Filter '*.cab' | ForEach-Object { $_.Name })
Test-Case 'the language pack came across' $true ([bool](@($landed) -match 'Client-Language-Pack_x64_nl-nl'))
Test-Case 'so did its satellites' @('Basic','Handwriting','OCR','Speech','TextToSpeech') `
    @($landed | ForEach-Object { [regex]::Match($_, 'LanguageFeatures-([A-Za-z]+)-') } |
      Where-Object { $_.Success } | ForEach-Object { $_.Groups[1].Value } | Sort-Object)

# An ISO is mostly other things. Copying NetFx3 into the language library would
# be quietly wrong -- it would show up as a language file forever after.
Test-Case 'nothing that is not a language' $false ([bool](@($landed) -match 'NetFx3|InternetExplorer'))

# The supplemental font pack carries no language tag at all: Microsoft names
# those after the script (PanEuropeanSupplementalFonts, Jpan), so no per-language
# folder is the right home and it is deliberately NOT imported. Deliberate is
# only acceptable if it is said out loud, so that is what is checked.
Test-Case 'the untagged font pack is left behind' $false ([bool](@($landed) -match 'PanEuropean'))
Test-Case 'and it is named in the log'            $true `
    ([bool]($script:Logged -match 'WARN\|1 feature cab\(s\) here carry no language tag'))
Test-Case 'with the file itself'                  $true ([bool]($script:Logged -match 'PanEuropeanSupplementalFonts'))

Write-Host 'A second import is refused rather than duplicated' -ForegroundColor Cyan
$r2 = Import-WfLanguagePack -Source (Join-Path $work 'iso') -Language 'nl-NL' -LibraryRoot $lib -Confirm:$false
Test-Case 'already present' 'AlreadyPresent' $r2[0].Status

Write-Host 'A language the source does not have is named, with what it does have' -ForegroundColor Cyan
$msg = ''
try { Import-WfLanguagePack -Source (Join-Path $work 'iso') -Language 'fr-FR' -LibraryRoot $lib -Confirm:$false }
catch { $msg = $_.Exception.Message }
Test-Case 'it refuses'        $true ([bool]($msg -match 'Not in this source: fr-FR'))
Test-Case 'and lists the set' $true ([bool]($msg -match 'nl-nl') -and [bool]($msg -match 'sv-se'))

# ------------------------------------------------------------------ library
Write-Host 'The library reads back as a list' -ForegroundColor Cyan
$null = Import-WfLanguagePack -Source (Join-Path $work 'iso') -Language 'sv-SE' -LibraryRoot $lib -Confirm:$false

$shelf = @(Get-WfLanguageLibrary -LibraryRoot $lib)
Test-Case 'two languages'        2     $shelf.Count
Test-Case 'each has its pack'    $true (@($shelf | Where-Object { -not $_.HasLanguagePack }).Count -eq 0)
Test-Case 'and a readable name'  $true ([bool](@($shelf | Where-Object { $_.Language -eq 'nl-nl' })[0].Name -match 'Dutch'))

# A folder with satellites but no pack cannot give an image a UI language, and
# that has to be visible in the list rather than discovered at apply time.
$halfDir = Join-Path $lib 'de-de'
New-Item -ItemType Directory -Path $halfDir -Force | Out-Null
$bytes = New-Object byte[] 64
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('MSCF'), $bytes, 4)
[IO.File]::WriteAllBytes((Join-Path $halfDir 'Microsoft-Windows-LanguageFeatures-Basic-de-de-Package~31bf3856ad364e35~amd64~~.cab'), $bytes)

$shelf2 = @(Get-WfLanguageLibrary -LibraryRoot $lib)
$de = @($shelf2 | Where-Object { $_.Language -eq 'de-de' })[0]
Test-Case 'a pack-less folder is listed' $true ($null -ne $de)
Test-Case 'and marked as such'           $false $de.HasLanguagePack

# ------------------------------------------------------------------- adding
Write-Host 'The language pack goes in before its satellites' -ForegroundColor Cyan

$script:Applied = @(); $script:Logged = @()
$rows = Add-WfLanguage -Language 'nl-NL' -MountPath 'C:\WimMount' -LibraryRoot $lib `
                       -CumulativeUpdate (Join-Path $iso 'Microsoft-Windows-Client-Language-Pack_x64_sv-se.cab') -Confirm:$false

$lpIx = [array]::FindIndex([string[]]$script:Applied, [Predicate[string]]{ param($x) $x -match 'Client-Language-Pack' })
$fodIx = [array]::FindIndex([string[]]$script:Applied, [Predicate[string]]{ param($x) $x -match 'LanguageFeatures' })
Test-Case 'the pack is first'   $true (($lpIx -ge 0) -and ($lpIx -lt $fodIx))

# Basic before the rest, because Microsoft lists it as the required one.
$basicIx = [array]::FindIndex([string[]]$script:Applied, [Predicate[string]]{ param($x) $x -match 'LanguageFeatures-Basic' })
$ocrIx   = [array]::FindIndex([string[]]$script:Applied, [Predicate[string]]{ param($x) $x -match 'LanguageFeatures-OCR' })
Test-Case 'Basic before OCR'    $true (($basicIx -ge 0) -and ($basicIx -lt $ocrIx))

# ------------------------------------------------- the cumulative update rule
Write-Host 'The cumulative update is re-applied afterwards' -ForegroundColor Cyan

Test-Case 'the update went in last' $true ($script:Applied[-1] -match 'sv-se')
Test-Case 'and it is reported'      $true (@($rows | Where-Object { $_.Status -eq 'UpdateReapplied' }).Count -eq 1)
Test-Case 'with the reason'         $true ([bool](@($rows | Where-Object { $_.Status -eq 'UpdateReapplied' })[0].Reason -match 'as Microsoft requires'))

Write-Host 'Without one, an image that has an update is told so' -ForegroundColor Cyan

# This is the case that would otherwise ship: languages added on top of a
# serviced image, a clean-looking run, and resources that stop at the pack's
# build. The run has to say what is still owed.
$script:Applied = @(); $script:Logged = @(); $script:Present = @('en-US')
$rows2 = Add-WfLanguage -Language 'nl-NL' -MountPath 'C:\WimMount' -LibraryRoot $lib -Confirm:$false

Test-Case 'it is flagged'  1 @($rows2 | Where-Object { $_.Status -eq 'UpdateReapplyNeeded' }).Count
Test-Case 'and warned'     $true ([bool]($script:Logged -match 'WARN\|This image already has a cumulative update'))
Test-Case 'saying what to do' $true ([bool]($script:Logged -match 'before shipping this image'))

Write-Host 'An image with no update is not nagged' -ForegroundColor Cyan
$script:HasLcu = $false; $script:Applied = @(); $script:Logged = @()
$rows3 = Add-WfLanguage -Language 'sv-SE' -MountPath 'C:\WimMount' -LibraryRoot $lib -Confirm:$false
Test-Case 'nothing owed' 0 @($rows3 | Where-Object { $_.Status -eq 'UpdateReapplyNeeded' }).Count
$script:HasLcu = $true

# --------------------------------------------------------------- refusals
Write-Host 'Adding refuses what it cannot do' -ForegroundColor Cyan

$msg2 = ''
try { Add-WfLanguage -Language 'fi-FI' -MountPath 'C:\WimMount' -LibraryRoot $lib -Confirm:$false }
catch { $msg2 = $_.Exception.Message }
Test-Case 'a language not in the library' $true ([bool]($msg2 -match 'not in the library'))
Test-Case 'and lists what is'             $true ([bool]($msg2 -match 'nl-nl'))

$msg3 = ''
try { Add-WfLanguage -Language 'de-DE' -MountPath 'C:\WimMount' -LibraryRoot $lib -Confirm:$false }
catch { $msg3 = $_.Exception.Message }
Test-Case 'a folder with no pack' $true ([bool]($msg3 -match 'no language pack cab'))

Write-Host 'A language already in the image is skipped' -ForegroundColor Cyan
$script:Present = @('en-US','nl-nl'); $script:Applied = @()
$rows4 = Add-WfLanguage -Language 'nl-NL' -MountPath 'C:\WimMount' -LibraryRoot $lib -Confirm:$false
Test-Case 'nothing applied'   0 $script:Applied.Count
Test-Case 'and said as much'  'AlreadyPresent' $rows4[0].Status
$script:Present = @('en-US')

Write-Host 'A failed pack does not drag its satellites in behind it' -ForegroundColor Cyan
$script:Applied = @(); $script:Logged = @(); $script:FailOn = '*Client-Language-Pack*'
$rows5 = Add-WfLanguage -Language 'nl-NL' -MountPath 'C:\WimMount' -LibraryRoot $lib -Confirm:$false
$script:FailOn = ''
Test-Case 'nothing was applied'    0 $script:Applied.Count
Test-Case 'the failure is reported' 1 @($rows5 | Where-Object { $_.Status -eq 'Failed' }).Count
Test-Case 'and the reason given'   $true ([bool]($script:Logged -match 'satellites are not attempted'))

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
