# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The lists behind every "pick one", and the one piece of arithmetic that turns
# two picks back into the string DISM wants.
#
# The reason these are worth testing at all: they exist so that nothing gets
# typed from memory. '0413:00020409' typed slightly wrong is accepted by DISM
# without complaint, and the first anyone knows about it is a till printing the
# wrong character for the euro sign. So the combining has to be right, and the
# lists have to actually come back non-empty on a real machine -- an empty list
# silently turns a picker back into a free-text box.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

# Loaded on its own rather than through the module: this file has no dependency
# on anything but .NET and the registry, and importing the whole module would
# drag in DISM checks that cannot run here.
function Write-WfLog { param([string] $Message, [string] $Level = 'INFO') }
. (Join-Path $root 'WimForge\Public\Choices.ps1')

Write-Host 'Time zones come from the machine, not from a list somebody typed' -ForegroundColor Cyan

$zones = @(Get-WfTimeZoneChoice)
Test-Case 'there are some'            $true ($zones.Count -gt 20)
Test-Case 'every one has an id'       $true (@($zones | Where-Object { -not $_.Id }).Count -eq 0)
Test-Case 'and a display name'        $true (@($zones | Where-Object { -not $_.Name }).Count -eq 0)

# Deliberately not 'UTC': every display name begins '(UTC+01:00)', so filtering
# on that matches the whole list. Worth knowing, and worth not writing a test
# around, because it looks like a broken filter and is not one.
$europe = @(Get-WfTimeZoneChoice -Filter 'Europe')
Test-Case 'filtering narrows it'      $true ($europe.Count -lt $zones.Count -and $europe.Count -gt 0)

# The filter has to match the display name too -- 'Amsterdam' appears only there,
# and it is what somebody would actually search for.
$byCity = @(Get-WfTimeZoneChoice -Filter 'Amsterdam')
Test-Case 'searches the name, not just the id' $true ($byCity.Count -ge 1)

Test-Case 'nothing matching is an empty list, not an error' 0 @(Get-WfTimeZoneChoice -Filter 'zzzznotazone').Count

Write-Host 'Locales are specific cultures only' -ForegroundColor Cyan

$locales = @(Get-WfLocaleChoice)
Test-Case 'there are plenty'          $true ($locales.Count -gt 100)

# 'nl' on its own is a neutral culture, and DISM will not take it. If one of
# those leaked into the list the picker would be offering a value that fails.
Test-Case 'no neutral cultures'       0 @($locales | Where-Object { $_.Name -notmatch '-' }).Count
Test-Case 'nl-NL is in there'         1 @($locales | Where-Object { $_.Name -eq 'nl-NL' }).Count

$dutch = @(Get-WfLocaleChoice -Filter 'nl-')
Test-Case 'filtering by code works'   $true ($dutch.Count -ge 2)   # nl-NL and nl-BE at least

$byLanguage = @(Get-WfLocaleChoice -Filter 'Dutch')
Test-Case 'and by language name'      $true ($byLanguage.Count -ge 1)

Write-Host 'Keyboard layouts' -ForegroundColor Cyan

# This one reads the registry, so on a non-Windows host it is expected to come
# back empty. Both outcomes are correct; what is not correct is throwing.
$layouts = @(Get-WfKeyboardChoice)
Test-Case 'reading them does not throw' $true ($layouts -is [array])

if ($layouts.Count -gt 0) {
    Test-Case 'ids are eight hex digits' 0 @($layouts | Where-Object { $_.LayoutId -notmatch '^[0-9A-Fa-f]{8}$' }).Count
    Test-Case 'none shows a raw @dll,-id reference' 0 @($layouts | Where-Object { $_.Layout -like '@*' }).Count

    $withLang = @(Get-WfKeyboardChoice -Language 'nl-NL')
    Test-Case 'a language fills in the pair' $true (@($withLang | Where-Object { $_.InputLocale -like '0413:*' }).Count -gt 0)
}
else {
    Write-Host '  --   no keyboard registry on this host, so the layout checks are skipped' -ForegroundColor DarkGray
}

Write-Host 'Putting a language and a layout back together' -ForegroundColor Cyan

# The pairing a Dutch estate actually wants: Dutch language, US-International keys.
# Dutch offices type on US-International, not on the Dutch layout.
Test-Case 'nl-NL + US-International' '0413:00020409' (Get-WfInputLocaleValue -Language 'nl-NL' -LayoutId '00020409')
Test-Case 'en-US + US'               '0409:00000409' (Get-WfInputLocaleValue -Language 'en-US' -LayoutId '00000409')

# An lcid that is already hex is what comes back out of an image that was set
# before, so round-tripping one has to work.
Test-Case 'an lcid already in hex passes through' '0413:00020409' (Get-WfInputLocaleValue -Language '0413' -LayoutId '00020409')

# Case is not significant to Windows, but two spellings of the same value in a
# history file is noise. Normalised down.
Test-Case 'normalised to lower case' '0413:00020409' (Get-WfInputLocaleValue -Language 'nl-NL' -LayoutId '00020409')

# The failures. Each returns empty rather than throwing, because these are called
# while building a form -- a throw here takes the whole window with it.
Test-Case 'a bad layout id gives nothing'  '' (Get-WfInputLocaleValue -Language 'nl-NL' -LayoutId '20409')
Test-Case 'a layout id with a colon in it' '' (Get-WfInputLocaleValue -Language 'nl-NL' -LayoutId '0413:00020409')

# The one that nearly got through. .NET does not throw on a well-formed tag that
# no locale exists for -- it invents a custom culture with LCID 0x1000 -- so a
# typo used to come back as '1000:00020409': plausible, wrong, and silent.
Test-Case 'a nonsense culture gives nothing' '' (Get-WfInputLocaleValue -Language 'zz-ZZ-nonsense' -LayoutId '00020409')
Test-Case 'and so does a well-formed one that does not exist' '' (Get-WfInputLocaleValue -Language 'qq-QQ' -LayoutId '00020409')
Test-Case 'never returns the 0x1000 placeholder' $false `
    ((Get-WfInputLocaleValue -Language 'qq-QQ' -LayoutId '00020409') -like '1000:*')

Write-Host 'Keyboard Filter keys' -ForegroundColor Cyan

$keys = @(Get-WfKeyboardFilterChoice)
Test-Case 'the fixed set is there'    $true ($keys.Count -ge 15)
Test-Case 'every one is explained'    0 @($keys | Where-Object { -not $_.What }).Count
Test-Case 'no duplicates'             $keys.Count @($keys | Select-Object -ExpandProperty Key | Sort-Object -Unique).Count

# These names go straight to WEKF_PredefinedKey, which takes them verbatim. The
# spelling is the interface.
Test-Case 'Ctrl+Alt+Del spelled as the feature spells it' 1 @($keys | Where-Object { $_.Key -eq 'Ctrl+Alt+Del' }).Count
Test-Case 'Alt+F4 is offered'  1 @($keys | Where-Object { $_.Key -eq 'Alt+F4' }).Count
Test-Case 'no stray whitespace' 0 @($keys | Where-Object { $_.Key -ne $_.Key.Trim() }).Count

Write-Host 'Both front-ends offer the same lists' -ForegroundColor Cyan

# Parity at the function level is checked elsewhere; this is the narrower
# question of whether one front-end still has a free-text box where the other
# now has a picker. That is the drift that would put this work back.
$menu = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeMenu.ps1') -Raw
$gui  = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeGui.ps1')  -Raw

foreach ($fn in @('Get-WfLocaleChoice', 'Get-WfKeyboardChoice', 'Get-WfTimeZoneChoice',
                  'Get-WfInputLocaleValue', 'Get-WfKeyboardFilterChoice')) {
    Test-Case "$fn is used by the console" $true ($menu -match [regex]::Escape($fn))
    Test-Case "$fn is used by the GUI"     $true ($gui  -match [regex]::Escape($fn))
}

# And the values these replaced are gone. A leftover default of
# 'W. Europe Standard Time' in a text box means somebody is still typing it.
Test-Case 'no typed time zone left in the console' $false ($menu -match "Read-WfValue 'Time zone'")
Test-Case 'no typed keyboard left in the console'  $false ($menu -match "Read-WfValue 'Keyboard")
Test-Case 'no typed time zone left in the GUI'     $false ($gui  -match "Add-WfTextBox .*'Time zone'")
Test-Case 'no typed keyboard left in the GUI'      $false ($gui  -match "Add-WfTextBox .*'Keyboard")

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
