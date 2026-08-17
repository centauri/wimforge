# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# One image, many countries.
#
# Four things here are worth checking mechanically, because all four fail
# silently on a shipped terminal rather than loudly on the machine that built it.
#
#   The GeoIDs. They are not ISO numbers, they are not alphabetical, and Belgium
#   is 21 while Germany is 94. A wrong one produces a working machine that is
#   quietly in the wrong country, and nothing about it looks wrong.
#
#   The answer file. It is the ONLY way to set a home location on a running
#   machine, and its parser answers anything it dislikes by rejecting the file
#   with no error at all. So it has to be well-formed XML with exactly the
#   element names Microsoft documents, and the template the till runs has to be
#   the same one that was checked here -- not a second copy that drifted.
#
#   The generated scripts. A till-side script nobody can look at without a
#   Windows machine and a wim is a script that ships wrong. Both of them are
#   generated without a mount, parsed, and read.
#
#   The batch quoting. 'Belgium (Dutch)' inside a parenthesised block ends the
#   block early and the rest of the menu becomes commands.

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
. (Join-Path $root 'WimForge\Public\Region.ps1')

Write-Host ''
Write-Host 'Region presets' -ForegroundColor Cyan

$all = @(Get-WfRegionPreset)
Test-Case 'six countries' 6 $all.Count
Test-Case 'ids' 'NL, BE-nl, BE-fr, DE, SE, UK' (@($all | ForEach-Object { $_.Id }) -join ', ')

# From Microsoft's Table of Geographical Locations. Written out one at a time
# rather than in a loop, so a failure names the country.
Test-Case 'GeoID Netherlands'    176 (@($all | Where-Object { $_.Id -eq 'NL' })[0].GeoId)
Test-Case 'GeoID Belgium (nl)'   21  (@($all | Where-Object { $_.Id -eq 'BE-nl' })[0].GeoId)
Test-Case 'GeoID Belgium (fr)'   21  (@($all | Where-Object { $_.Id -eq 'BE-fr' })[0].GeoId)
Test-Case 'GeoID Germany'        94  (@($all | Where-Object { $_.Id -eq 'DE' })[0].GeoId)
Test-Case 'GeoID Sweden'         221 (@($all | Where-Object { $_.Id -eq 'SE' })[0].GeoId)
Test-Case 'GeoID United Kingdom' 242 (@($all | Where-Object { $_.Id -eq 'UK' })[0].GeoId)

# Both halves of Belgium are the same country and must say so. This is the exact
# mistake the two-preset design exists to prevent -- two rows, one home location.
$be = @($all | Where-Object { $_.Id -like 'BE-*' })
Test-Case 'both Belgian presets share one home location' 1 (@($be | ForEach-Object { $_.GeoId } | Sort-Object -Unique).Count)

# There is no nl-BE or fr-BE display language. Microsoft does not ship one, so a
# preset offering Belgian MENUS would be offering something that cannot exist --
# and the failure lands at build time, inside DISM, as "the command will fail".
Test-Case 'Belgian Dutch menus are nl-NL'  'nl-NL' (@($all | Where-Object { $_.Id -eq 'BE-nl' })[0].UILanguage)
Test-Case 'Belgian French menus are fr-FR' 'fr-FR' (@($all | Where-Object { $_.Id -eq 'BE-fr' })[0].UILanguage)
Test-Case 'Belgian Dutch formats are nl-BE'  'nl-BE' (@($all | Where-Object { $_.Id -eq 'BE-nl' })[0].UserLocale)
Test-Case 'Belgian French formats are fr-BE' 'fr-BE' (@($all | Where-Object { $_.Id -eq 'BE-fr' })[0].UserLocale)

# The input locale is a language:layout pair of hex ids. A malformed one is
# accepted by DISM and produces a keyboard nobody asked for.
$badPairs = @($all | Where-Object { $_.InputLocale -notmatch '^[0-9a-f]{4}:[0-9a-f]{8}$' } |
                     ForEach-Object { "$($_.Id)=$($_.InputLocale)" })
Test-Case 'every input locale is lcid:layout' '' ($badPairs -join ', ')

# The lcid half must be the language's own, or the keyboard is paired with the
# wrong language and the layout silently does not apply.
$mismatched = @()
foreach ($p in $all) {
    $lcid = ($p.InputLocale -split ':')[0]
    $want = ''
    try { $want = '{0:x4}' -f [System.Globalization.CultureInfo]::GetCultureInfo($p.UserLocale).LCID } catch { }
    if ($want -and $lcid -ne $want) { $mismatched += ("{0}: {1} for {2}, expected {3}" -f $p.Id, $lcid, $p.UserLocale, $want) }
}
Test-Case 'the lcid matches the user locale' '' ($mismatched -join '; ')

# Fallback exists so a half-translated menu falls back to something readable
# rather than to the resource id.
$noFallback = @($all | Where-Object { -not $_.UIFallback } | ForEach-Object { $_.Id })
Test-Case 'every preset has a menu fallback' '' ($noFallback -join ', ')

# A typo in an id has to fail rather than quietly produce nothing.
$threw = 'no'
try { Get-WfRegionPreset -Id 'NLL' | Out-Null } catch { $threw = 'yes' }
Test-Case 'an unknown id is refused' 'yes' $threw

Test-Case 'BE-nl and BE-fr both map to BE' 'BE, BE' `
    ((@('BE-nl','BE-fr') | ForEach-Object { Get-WfRegionCountryCode -Id $_ }) -join ', ')
Test-Case 'UK maps to GB' 'GB' (Get-WfRegionCountryCode -Id 'UK')

Write-Host ''
Write-Host 'The international settings answer file' -ForegroundColor Cyan

$xml = Get-WfRegionAnswerXml -Id 'BE-fr'

# Well-formed, because the parser's response to anything else is silence.
$parsed = $null
$parseError = ''
try { $parsed = [xml]$xml } catch { $parseError = $_.Exception.Message }
Test-Case 'the answer file is valid XML' '' $parseError

Test-Case 'namespace'    'urn:longhornGlobalizationUnattend' $parsed.DocumentElement.NamespaceURI
Test-Case 'GeoID'        '21'    $parsed.GlobalizationServices.LocationPreferences.GeoID.Value
Test-Case 'system locale' 'fr-BE' $parsed.GlobalizationServices.SystemLocale.Name
Test-Case 'user locale'   'fr-BE' $parsed.GlobalizationServices.UserLocale.Locale.Name
Test-Case 'input locale'  '080c:0000080c' $parsed.GlobalizationServices.InputPreferences.InputLanguageID.ID
Test-Case 'menus'         'fr-FR' $parsed.GlobalizationServices.MUILanguagePreferences.MUILanguage.Value

# These two flags are the whole reason this format is used instead of the
# registry: they push the finished settings to accounts created later and to the
# logon screen. Without them the answer file configures only whoever ran it,
# which at first boot is SYSTEM -- an account nobody ever sees.
$user = $parsed.GlobalizationServices.UserList.User
Test-Case 'copies to the default user account' 'true' $user.CopySettingsToDefaultUserAcct
Test-Case 'copies to the system account'       'true' $user.CopySettingsToSystemAcct

# English menus with local formats -- what most of this estate actually wants.
$en = [xml](Get-WfRegionAnswerXml -Id 'NL' -UILanguage 'en-US')
Test-Case 'the menu override takes'          'en-US' $en.GlobalizationServices.MUILanguagePreferences.MUILanguage.Value
Test-Case 'and leaves the formats alone'     'nl-NL' $en.GlobalizationServices.UserLocale.Locale.Name
Test-Case 'and leaves the home location alone' '176' $en.GlobalizationServices.LocationPreferences.GeoID.Value

# Every preset has to produce a parseable file, not just the one spot-checked.
$badXml = @()
foreach ($p in $all) {
    try { $null = [xml](Get-WfRegionAnswerXml -Id $p.Id) } catch { $badXml += $p.Id }
}
Test-Case 'every preset produces valid XML' '' ($badXml -join ', ')

Write-Host ''
Write-Host 'The first-boot script' -ForegroundColor Cyan

$body = New-WfRegionScriptBody -Preset (Get-WfRegionPreset -Id NL, 'BE-nl', 'DE') `
                               -DefaultId 'NL' -TimeoutSeconds 45 -Ask
$text = ($body -join "`n")

$gen = Join-Path ([IO.Path]::GetTempPath()) ('wf-region-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
Set-Content -LiteralPath $gen -Value $body -Encoding UTF8

$genErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($gen, [ref]$null, [ref]$genErrors)
Test-Case 'the generated script parses' '' (@($genErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')

# The template the till runs must be the one checked above. Two copies of an XML
# schema is exactly the shape of bug where the tested one is right and the
# shipped one is not, and nothing would ever compare them.
$hereStart = $text.IndexOf("`$Template = @'")
$hereEnd   = $text.IndexOf("`n'@", $hereStart)
$embedded  = ''
if ($hereStart -ge 0 -and $hereEnd -gt $hereStart) {
    $embedded = $text.Substring($hereStart, $hereEnd - $hereStart)
    $embedded = $embedded.Substring($embedded.IndexOf("`n") + 1)
}
$moduleTemplate = ((Get-WfRegionAnswerXmlTemplate) -replace "`r`n", "`n").TrimEnd("`n")
Test-Case 'the embedded template is the module template' $moduleTemplate ($embedded.TrimEnd("`n"))

# Values from the build, so a till never has to be told what a country means.
Test-Case 'the offered countries are baked in' 'True' `
    (($text -match "Id = 'NL'") -and ($text -match "Id = 'BE-nl'") -and ($text -match "Id = 'DE'")).ToString()
Test-Case 'a country NOT offered is absent' 'False' ($text -match "Id = 'SE'").ToString()
Test-Case 'the default is baked in' 'True' ($text -match "\`$DefaultId = 'NL'").ToString()
Test-Case 'the countdown is baked in' 'True' ($text -match "\`$TimeoutSeconds = 45").ToString()

# Apply mode runs as SYSTEM with no desktop. Anything that waits for input there
# hangs the machine with a blank screen and no way to tell why -- which is why
# the question is handed to RunOnce instead.
$applyBlock = ''
$ai = $text.IndexOf("if (`$Mode -eq 'Apply')")
$bi = $text.IndexOf("if (`$Mode -eq 'Ask')")
if ($ai -ge 0 -and $bi -gt $ai) { $applyBlock = $text.Substring($ai, $bi - $ai) }
Test-Case 'Apply mode is present' 'True' ($applyBlock.Length -gt 0).ToString()
Test-Case 'Apply mode never prompts' 'False' `
    (($applyBlock -match 'Read-Host') -or ($applyBlock -match 'ShowDialog') -or ($applyBlock -match 'MessageBox')).ToString()
Test-Case 'Apply mode hands the question to RunOnce' 'True' ($applyBlock -match 'RunOnce').ToString()
Test-Case 'a recorded answer is applied without asking' 'True' ($applyBlock -match 'no question asked').ToString()

# Without -Ask nothing is registered: an estate that images per country should
# never see a prompt.
$quiet = (New-WfRegionScriptBody -Preset (Get-WfRegionPreset -Id NL) -DefaultId 'NL') -join "`n"
# The REGISTRATION, not the word: the header comment explains both modes either
# way, and -Mode Ask stays a valid thing to run by hand on a till that came up
# wrong. What must not happen is a prompt appearing on its own.
Test-Case 'without -Ask nothing is registered to run at logon' 'False' `
    ($quiet -match 'CurrentVersion\\RunOnce').ToString()
Test-Case 'with -Ask it is'  'True' ($text -match 'CurrentVersion\\RunOnce').ToString()

# The time zone is in no answer file of any kind, so it has to be set separately
# or every till outside one zone is an hour out.
Test-Case 'the time zone is set with tzutil' 'True' ($text -match 'tzutil').ToString()

# intl.cpl reports nothing at all -- no exit code, no message -- so the only way
# to know it took is to go and look.
Test-Case 'the settings are read back' 'True' ($text -match 'read back').ToString()
Test-Case 'and a mismatch is logged as a warning' 'True' ($text -match 'the home location did not take').ToString()

# The child process does the work. Without -Wait the read-back runs first and
# reports the old settings, which is worse than not checking at all.
Test-Case 'intl.cpl is waited for' 'True' ($text -match 'intl\.cpl.*-Wait|-Wait.*intl\.cpl').ToString()

# Set-Content -Encoding UTF8 writes a byte order mark on 5.1, and this parser
# rejects what it dislikes in silence.
Test-Case 'the answer file is written without a BOM' 'True' ($text -match 'UTF8Encoding\(\$false\)').ToString()

Write-Host ''
Write-Host 'The WinPE script' -ForegroundColor Cyan

$pe = New-WfRegionPeScript -Offer NL, 'BE-nl', 'BE-fr' -DefaultId 'NL' -TimeoutSeconds 30
$peText = ($pe.Lines -join "`n")

Test-Case 'the menu lists what was offered' 'True' `
    (($peText -match '1\. Netherlands') -and ($peText -match '2\. Belgium') -and ($peText -match '3\. Belgium')).ToString()

# 'Belgium (Dutch)' in a batch echo ends a parenthesised block early and the rest
# of the menu becomes commands. It becomes a dash rather than vanishing, because
# 'Belgium  Dutch' is not a country.
$menuLines = @($pe.Lines | Where-Object { $_ -match '^echo\s+\d+\.' })
Test-Case 'no parentheses survive into the menu' '' `
    (@($menuLines | Where-Object { $_ -match '[()]' }) -join '; ')
Test-Case 'and the country is still readable' 'True' ($peText -match 'Belgium - Dutch').ToString()

# choice.exe takes characters. Ten entries would be /C 12345678910 -- the digits
# 1..9 then 1 and 0, a menu whose tenth entry is unreachable.
Test-Case 'the choice set is one character per entry' 'True' ($peText -match 'choice /C 123 ').ToString()
Test-Case 'the countdown is passed through' 'True' ($peText -match '/T 30 /D 1').ToString()

# Each ERRORLEVEL maps to the right id, in order. A shifted map deploys every
# machine as the country next to the one that was picked.
Test-Case 'pick 1 is NL'    'True' ($peText -match '"%WF_PICK%"=="1" set WF_REGION=NL').ToString()
Test-Case 'pick 2 is BE-nl' 'True' ($peText -match '"%WF_PICK%"=="2" set WF_REGION=BE-nl').ToString()
Test-Case 'pick 3 is BE-fr' 'True' ($peText -match '"%WF_PICK%"=="3" set WF_REGION=BE-fr').ToString()

# WinPE letters are not Windows letters. A script that assumes C: writes the
# answer onto the WinPE ramdisk, where nothing will ever read it.
Test-Case 'the applied volume is found, not assumed' 'True' ($peText -match 'ntoskrnl\.exe').ToString()

# It records an answer and sets nothing. Everything else happens inside Windows,
# where the tools for it exist.
Test-Case 'it writes region.json' 'True' ($peText -match 'region\.json').ToString()
Test-Case 'and changes no setting itself' 'False' `
    (($peText -match 'intl\.cpl') -or ($peText -match 'tzutil') -or ($peText -match 'reg load')).ToString()

# A default that is not on the menu would give the countdown nothing to take.
$threw = 'no'
try { New-WfRegionPeScript -Offer NL, 'DE' -DefaultId 'SE' | Out-Null } catch { $threw = 'yes' }
Test-Case 'a default off the menu is refused' 'yes' $threw

Write-Host ''
Write-Host 'What the front-ends and the manifest agree on' -ForegroundColor Cyan

# Everything this file exports has to be in the manifest, or it is not callable
# from either front-end however well it works.
$manifest = Import-PowerShellDataFile (Join-Path $root 'WimForge\WimForge.psd1')
$missing  = @()
foreach ($fn in @('Get-WfRegionPreset', 'Get-WfRegionAnswerXml', 'Set-WfImageGeoId', 'Set-WfImageRegion',
                  'Write-WfRegionAnswer', 'Get-WfRegionAnswer', 'New-WfRegionPeScript', 'New-WfRegionFirstBoot')) {
    if ($manifest.FunctionsToExport -notcontains $fn) { $missing += $fn }
}
Test-Case 'the manifest exports the region functions' '' ($missing -join ', ')

# Helpers, deliberately not exported: one is arithmetic and the other builds a
# generated file. Exporting them would put them in the front-ends' reach and
# then in the parity report.
$leaked = @()
foreach ($fn in @('New-WfRegionScriptBody', 'Get-WfRegionCountryCode', 'Get-WfRegionAnswerXmlTemplate')) {
    if ($manifest.FunctionsToExport -contains $fn) { $leaked += $fn }
}
Test-Case 'and keeps the helpers to itself' '' ($leaked -join ', ')

Remove-Item -LiteralPath $gen -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) {
    Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'All region checks passed.' -ForegroundColor Green
