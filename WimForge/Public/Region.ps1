# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Region.ps1 -- one image, many countries.

    Languages.ps1 makes the point this file depends on: a DISPLAY LANGUAGE is a
    package that has to be inside the image, a REGION is a setting that can be
    changed in seconds. So an estate spanning the Netherlands, Belgium, Germany
    and Sweden ships ONE wim with the languages baked in, and picks the region
    per site.

    Three places the region can be decided, and this file covers all three
    because a real deployment uses more than one:

      1. In the image, at build time.  Set-WfImageRegion. Whatever the till does
         if nobody tells it anything. Get this right and most sites need nothing
         else.

      2. In WinPE, at deployment.      New-WfRegionPeScript. The technician
         applying the wim picks a country from a menu; the answer is dropped into
         the applied image as a two-line json file. No unattend.xml, no second
         wim, no rebuilding anything.

      3. At first boot.                New-WfRegionFirstBoot. Reads that json and
         applies it before anyone logs on. If it is not there, the image's baked-in
         default stands -- or, with -Ask, the first person to log on gets one
         question with a countdown.

    ---------------------------------------------------------------- the GeoID

    The home location -- "Regional format" is one thing, "Country or region" is
    another, and it is the second one that decides which store, which Windows
    Update content, and which of the government-facing bits of Windows apply.

    It has an id, not a name: the Netherlands is 176, Belgium 21, Germany 94,
    Sweden 221, the United Kingdom 242. Those come from Microsoft's Table of
    Geographical Locations and are not guessable -- they are not ISO numbers and
    they are not alphabetical.

    And here is the trap that shapes half of this file: THERE IS NO GeoID IN
    unattend.xml. Microsoft-Windows-International-Core has UILanguage,
    UILanguageFallback, SystemLocale, UserLocale and InputLocale. That is the
    lot. An answer file cannot set the home location, so every build that relies
    only on unattend.xml has tills sitting in Dutch shops reporting themselves as
    American, and nobody notices until something region-aware behaves oddly.

    Two ways round it, and this file uses both:

      offline   write Control Panel\International\Geo\Nation into the default
                user hive. Set-WfImageGeoId.

      running   the international settings answer file, applied with
                `control.exe intl.cpl,,/f:"<file>"`. That format is a different
                thing from unattend.xml and it DOES have LocationPreferences/GeoID,
                plus flags to copy the whole set to the default user account and
                to the system account in one call. Microsoft documents it in
                "Automate regional and language settings"; the schema below is
                theirs, element for element.

    Time zone is in neither, so it is set with tzutil.
#>

function Get-WfRegionPreset {
<#
.SYNOPSIS
    The countries this toolkit knows, as ready-made sets of regional settings.
.DESCRIPTION
    A region is five separate settings that people set individually and get
    inconsistent: user locale, system locale, keyboard, home location, time zone.
    Set the formats to Dutch and leave the home location at 244 and the till is
    half Dutch and half American, which is worse than either.

    So they travel together, as a row per country.

    Two things in these rows are worth reading before trusting them:

      UILanguage is a SUGGESTION. It is the menu language that goes with the
      country, and it only works if that language pack is in the image. On an
      estate whose support notes are in English -- which is most of them -- the
      usual answer is to keep en-US menus and take only the formats, which is
      Set-WfImageRegion -UILanguage en-US.

      Belgium is two presets, not one. There is no nl-BE or fr-BE display
      language; Microsoft does not ship one. Belgian menus are Dutch (nl-NL) or
      French (fr-FR), with Belgian formats and a Belgian keyboard on top. The
      keyboard is the part that gets noticed -- Belgian French is AZERTY, and a
      till with a QWERTY layout under an AZERTY keycap set produces support calls
      within the hour.
.PARAMETER Id
    One or more preset ids -- NL, BE-nl, BE-fr, DE, SE, UK. Omit for all of them.
.EXAMPLE
    Get-WfRegionPreset | Format-Table Id, Country, UserLocale, GeoId, InputLocale, TimeZone
.EXAMPLE
    Get-WfRegionPreset -Id BE-fr
#>
    [CmdletBinding()]
    param([string[]] $Id)

    # GeoIds are from Microsoft's Table of Geographical Locations. They are not
    # ISO 3166 numeric codes and they are not in any order -- Belgium is 21 and
    # Germany is 94 -- so they are written down rather than derived.
    #
    # Keyboard ids are the eight-hex-digit layout ids under
    # HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts. InputLocale pairs
    # one with the language's lcid, which is what DISM and the answer file want.
    $rows = @(
        @{
            Id = 'NL'; Country = 'Netherlands'
            GeoId = 176
            UserLocale = 'nl-NL'; SystemLocale = 'nl-NL'
            InputLocale = '0413:00020409'; Keyboard = 'United States-International'
            TimeZone = 'W. Europe Standard Time'
            UILanguage = 'nl-NL'; UIFallback = 'en-US'
            Note = 'Dutch offices type on US-International, not on the Dutch layout -- the Dutch layout is almost never what is on the desk.'
        }
        @{
            Id = 'BE-nl'; Country = 'Belgium (Dutch)'
            GeoId = 21
            UserLocale = 'nl-BE'; SystemLocale = 'nl-BE'
            InputLocale = '0813:00000813'; Keyboard = 'Belgian (Period)'
            TimeZone = 'Romance Standard Time'
            UILanguage = 'nl-NL'; UIFallback = 'en-US'
            Note = 'No nl-BE display language exists. The menus are nl-NL; the formats, home location and keyboard are Belgian.'
        }
        @{
            Id = 'BE-fr'; Country = 'Belgium (French)'
            GeoId = 21
            UserLocale = 'fr-BE'; SystemLocale = 'fr-BE'
            InputLocale = '080c:0000080c'; Keyboard = 'Belgian French (AZERTY)'
            TimeZone = 'Romance Standard Time'
            UILanguage = 'fr-FR'; UIFallback = 'en-US'
            Note = 'No fr-BE display language exists. The menus are fr-FR. AZERTY -- get this wrong and the keycaps lie.'
        }
        @{
            Id = 'DE'; Country = 'Germany'
            GeoId = 94
            UserLocale = 'de-DE'; SystemLocale = 'de-DE'
            InputLocale = '0407:00000407'; Keyboard = 'German (QWERTZ)'
            TimeZone = 'W. Europe Standard Time'
            UILanguage = 'de-DE'; UIFallback = 'en-US'
            Note = 'QWERTZ, and the y and z keys are swapped from what a Dutch tester expects.'
        }
        @{
            Id = 'SE'; Country = 'Sweden'
            GeoId = 221
            UserLocale = 'sv-SE'; SystemLocale = 'sv-SE'
            InputLocale = '041d:0000041d'; Keyboard = 'Swedish'
            TimeZone = 'W. Europe Standard Time'
            UILanguage = 'sv-SE'; UIFallback = 'en-US'
            Note = 'Stockholm is in the same zone as Amsterdam and Berlin, despite being further north than either.'
        }
        @{
            Id = 'UK'; Country = 'United Kingdom'
            GeoId = 242
            UserLocale = 'en-GB'; SystemLocale = 'en-GB'
            InputLocale = '0809:00000809'; Keyboard = 'United Kingdom'
            TimeZone = 'GMT Standard Time'
            UILanguage = 'en-GB'; UIFallback = 'en-US'
            Note = 'The one preset whose display language is already in a stock image, so it costs nothing to offer.'
        }
    )

    $out = foreach ($r in $rows) {
        [pscustomobject]@{
            Id           = $r.Id
            Country      = $r.Country
            GeoId        = $r.GeoId
            UserLocale   = $r.UserLocale
            SystemLocale = $r.SystemLocale
            InputLocale  = $r.InputLocale
            Keyboard     = $r.Keyboard
            TimeZone     = $r.TimeZone
            UILanguage   = $r.UILanguage
            UIFallback   = $r.UIFallback
            Note         = $r.Note
        }
    }

    $out = @($out)
    if ($Id) {
        $wanted = @($Id | ForEach-Object { "$_".Trim().ToLowerInvariant() })
        $picked = @($out | Where-Object { $wanted -contains $_.Id.ToLowerInvariant() })

        # A typo here would otherwise become an empty result and a build that
        # quietly sets nothing.
        $found   = @($picked | ForEach-Object { $_.Id.ToLowerInvariant() })
        $missing = @($wanted | Where-Object { $found -notcontains $_ })
        if ($missing.Count -gt 0) {
            throw ("No region preset called: {0}. There is: {1}." -f `
                   ($missing -join ', '), (@($out | ForEach-Object { $_.Id }) -join ', '))
        }
        $out = $picked
    }

    return @($out)
}

function Get-WfRegionAnswerXmlTemplate {
    <#
        The international settings answer file, as a format string.

        This is NOT unattend.xml. It is the separate format that
        `control.exe intl.cpl,,/f:"<file>"` reads, and the only reason it is
        worth knowing about is that it can do the two things unattend.xml cannot:
        set the GeoID, and copy the finished set to the default user account and
        the system account -- which is what makes the settings reach users
        created later and the logon screen, rather than only the account that ran
        it.

        The element names come from Microsoft's own sample and are exact.
        Attributes that are not in that sample are deliberately not emitted:
        this parser reacts to something it does not recognise by rejecting the
        whole file with an event-log entry and no visible error, so guessing at
        an extra attribute costs a silent no-op.

        Placeholders, in order: GeoID, MUI language, MUI fallback, system locale,
        input locale, user locale.

        One function so there is one copy. The first-boot script generated by
        New-WfRegionFirstBoot embeds this same template verbatim -- there is a
        test that fails if the two ever drift apart, because a till applying a
        subtly different answer file from the one that was tested is exactly the
        kind of thing nobody would find.
    #>
    return @'
<?xml version="1.0" encoding="UTF-8"?>
<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend">
  <gs:UserList>
    <gs:User UserID="Current" CopySettingsToDefaultUserAcct="true" CopySettingsToSystemAcct="true"/>
  </gs:UserList>
  <gs:LocationPreferences>
    <gs:GeoID Value="{0}"/>
  </gs:LocationPreferences>
  <gs:MUILanguagePreferences>
    <gs:MUILanguage Value="{1}"/>
    <gs:MUIFallback Value="{2}"/>
  </gs:MUILanguagePreferences>
  <gs:SystemLocale Name="{3}"/>
  <gs:InputPreferences>
    <gs:InputLanguageID Action="add" ID="{4}"/>
  </gs:InputPreferences>
  <gs:UserLocale>
    <gs:Locale Name="{5}" SetAsCurrent="true" ResetAllSettings="false"/>
  </gs:UserLocale>
</gs:GlobalizationServices>
'@
}

function Get-WfRegionAnswerXml {
<#
.SYNOPSIS
    The international settings answer file for one region preset, as text.
.DESCRIPTION
    Fills in Get-WfRegionAnswerXmlTemplate from a preset. Apply it on a running
    machine with:

        control.exe intl.cpl,,/f:"C:\ProgramData\WimForge\region.xml"

    Useful on its own for fixing a till that was deployed with the wrong region,
    without reimaging it.
.PARAMETER Id
    A preset id from Get-WfRegionPreset.
.PARAMETER UILanguage
    Override the preset's menu language -- en-US on an estate that wants English
    menus with local formats. Must be a display language the machine actually has.
.PARAMETER UIFallback
    What the menus fall back to for anything the display language does not
    translate. Defaults to the preset's, which is en-US throughout.
.EXAMPLE
    Get-WfRegionAnswerXml -Id BE-fr
.EXAMPLE
    Get-WfRegionAnswerXml -Id NL -UILanguage en-US | Set-Content C:\region.xml -Encoding UTF8
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $UILanguage,
        [string] $UIFallback
    )

    $p = @(Get-WfRegionPreset -Id $Id)[0]

    $mui = $p.UILanguage
    if ($UILanguage) { $mui = $UILanguage }
    $fallback = $p.UIFallback
    if ($UIFallback) { $fallback = $UIFallback }

    return ((Get-WfRegionAnswerXmlTemplate) -f `
        $p.GeoId, $mui, $fallback, $p.SystemLocale, $p.InputLocale, $p.UserLocale)
}

function Set-WfImageGeoId {
<#
.SYNOPSIS
    Sets the home location in a mounted image -- the one thing unattend.xml cannot do.
.DESCRIPTION
    Microsoft-Windows-International-Core has no GeoID element. Neither does
    dism /Set-*. So the home location is written straight into the default user
    hive, at Control Panel\International\Geo, which is where Windows reads it
    from when it creates a profile.

    Nation is the id as a string. Name is the two-letter code, which some
    components read instead; both are written because writing one and not the
    other is the sort of half-configured state that works until it does not.

    This reaches accounts created after the image is deployed, which on a till is
    all of them. It does not reach an account that already exists in the image --
    if there is one, set its region on the running machine.
.PARAMETER GeoId
    From Get-WfRegionPreset, or Microsoft's Table of Geographical Locations.
    Netherlands 176, Belgium 21, Germany 94, Sweden 221, United Kingdom 242.
.PARAMETER CountryCode
    The two-letter code. Derived from the GeoId for the presets; supply it for
    anything else.
.EXAMPLE
    Set-WfImageGeoId -GeoId 176 -CountryCode NL
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [int] $GeoId,
        [string] $CountryCode,
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    if (-not $CountryCode) {
        $known = @{ 176 = 'NL'; 21 = 'BE'; 94 = 'DE'; 221 = 'SE'; 242 = 'GB'; 84 = 'FR'; 223 = 'CH'; 244 = 'US' }
        if ($known.ContainsKey($GeoId)) { $CountryCode = $known[$GeoId] }
    }

    if (-not $PSCmdlet.ShouldProcess($MountPath, "Set the home location to GeoID $GeoId")) { return }

    Write-WfLog ("Setting the home location to {0}{1}" -f $GeoId, $(if ($CountryCode) { " ($CountryCode)" } else { '' })) -Level STEP

    $geoId = $GeoId
    $code  = $CountryCode

    Invoke-WfRegistryEdit -MountPath $MountPath -Action {
        param($keys)
        if (-not $keys.ContainsKey('Default')) {
            throw 'The default user hive did not load, so the home location cannot be written.'
        }
        $path = Join-WfPath $keys.Default 'Control Panel\International\Geo'
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -LiteralPath $path -Name 'Nation' -Value ([string]$geoId) -PropertyType String -Force | Out-Null
        if ($code) {
            New-ItemProperty -LiteralPath $path -Name 'Name' -Value $code -PropertyType String -Force | Out-Null
        }
    }

    Write-WfLog '  written to the default user hive' -Level OK
    Write-WfHistory -Action 'Home location' -ImagePath $MountPath -Detail @{
        GeoId = $GeoId; CountryCode = $CountryCode
    } | Out-Null

    return [pscustomobject]@{ GeoId = $GeoId; CountryCode = $CountryCode; MountPath = $MountPath }
}

function Set-WfImageRegion {
<#
.SYNOPSIS
    Applies a country preset to a mounted image -- formats, keyboard, home
    location, time zone, and optionally the menu language.
.DESCRIPTION
    The baked-in default. Whatever the till does when nothing else tells it
    otherwise, which for most sites is the only region setting that ever happens.

    Five settings from one id, so they cannot end up inconsistent with each
    other. Four of them go through dism; the home location goes through the
    registry, because dism and unattend.xml both refuse to carry it.

    The menu language is the one that can fail, and it fails hard: DISM's words
    are "If the language is not installed in the Windows image, the command will
    fail." So it is checked first. If the image does not have the preset's
    display language, this does NOT stop -- it applies everything else and says
    which language pack would be needed. A preset that refuses to set Dutch
    formats because it could not also set Dutch menus would be useless on the
    English-menus-Dutch-formats build that most of this estate wants.

    Use -RequireUILanguage to make that a failure instead, on a build where the
    menus are the point.
.PARAMETER Id
    A preset from Get-WfRegionPreset -- NL, BE-nl, BE-fr, DE, SE, UK.
.PARAMETER UILanguage
    Override the preset's menu language. en-US is the common one: English menus,
    local formats.
.PARAMETER RequireUILanguage
    Fail if the display language is not in the image, instead of carrying on
    without it.
.PARAMETER SkipTimeZone
    Leave the time zone alone. Worth it on an image deployed across zones by a
    task sequence that sets it later.
.PARAMETER SkipUILanguage
    Do not touch the menu language at all, whatever the preset says.
.EXAMPLE
    Set-WfImageRegion -Id NL -UILanguage en-US
.EXAMPLE
    Set-WfImageRegion -Id BE-fr -RequireUILanguage
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $UILanguage,
        [switch] $RequireUILanguage,
        [switch] $SkipUILanguage,
        [switch] $SkipTimeZone,
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $p = @(Get-WfRegionPreset -Id $Id)[0]
    Write-WfLog ("Region preset {0} -- {1}" -f $p.Id, $p.Country) -Level STEP
    Write-WfLog ("  {0}" -f $p.Note) -Level INFO

    $wantUi = $p.UILanguage
    if ($UILanguage)   { $wantUi = $UILanguage }
    if ($SkipUILanguage) { $wantUi = '' }

    # What the image can actually do, read once and used for both the decision
    # and the log. An image whose language list will not read is not evidence of
    # absence, so it is left alone -- same rule as the update generation guard.
    $installed = @()
    $couldRead = $false
    if ($wantUi) {
        try {
            $before = Get-WfImageLocale -MountPath $MountPath
            $installed = @(@($before.InstalledLanguages) + @($before.UILanguage) |
                           Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)
            $couldRead = $true
        }
        catch {
            Write-WfLog "Could not read the image's languages, so the menu language is attempted as asked: $($_.Exception.Message)" -Level WARN
        }
    }

    $uiSkippedReason = ''
    if ($wantUi -and $couldRead -and $installed.Count -gt 0 -and
        ($installed -notcontains "$wantUi".ToLowerInvariant())) {

        $uiSkippedReason = ("{0} is not in this image (it has {1})" -f $wantUi, ($installed -join ', '))

        if ($RequireUILanguage) {
            throw ("Region {0} wants {1} menus and this image does not have that display language -- it has {2}. " +
                   "Add-WfLanguage -Language {1} puts it in from the language library; Get-WfLanguageLibrary lists " +
                   "what is available. Drop -RequireUILanguage to set the formats without the menus." -f `
                   $p.Id, $wantUi, ($installed -join ', '))
        }

        Write-WfLog ("  the menu language is left alone: {0}." -f $uiSkippedReason) -Level WARN
        Write-WfLog ("  formats, keyboard, home location and time zone are still set. Add-WfLanguage -Language {0} would make the menus available too." -f $wantUi) -Level INFO
        $wantUi = ''
    }

    if (-not $PSCmdlet.ShouldProcess($MountPath, ("Apply region preset {0}" -f $p.Id))) { return }

    # dism first, registry second. If dism fails there is no point writing a home
    # location into an image whose formats were not set.
    $localeArgs = @{
        SystemLocale = $p.SystemLocale
        UserLocale   = $p.UserLocale
        InputLocale  = $p.InputLocale
        MountPath    = $MountPath
    }
    if ($wantUi)       { $localeArgs['UILanguage'] = $wantUi }
    if (-not $SkipTimeZone) { $localeArgs['TimeZone'] = $p.TimeZone }

    $locale = Set-WfImageLocale @localeArgs

    $geo = Set-WfImageGeoId -GeoId $p.GeoId -CountryCode (Get-WfRegionCountryCode -Id $p.Id) -MountPath $MountPath

    # Recorded in the image so the deployment side does not have to be told
    # again what the build already decided. New-WfRegionFirstBoot reads this for
    # its default, and the first-boot prompt shows it as the pre-selected answer.
    $stampDir = Join-WfPath $MountPath 'ProgramData\WimForge'
    New-WfDirectory $stampDir | Out-Null
    $stamp = [pscustomobject]@{
        Id         = $p.Id
        Country    = $p.Country
        UILanguage = $wantUi
        BuiltUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
    $stamp | ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath (Join-WfPath $stampDir 'region-default.json') -Encoding UTF8

    Write-WfLog ("Region {0} applied and recorded as this image's default." -f $p.Id) -Level OK
    if ($uiSkippedReason) {
        Write-WfLog ("The menus are NOT {0} in this image. {1}" -f $p.UILanguage, $uiSkippedReason) -Level WARN
    }

    Write-WfHistory -Action 'Region preset' -ImagePath $MountPath -Detail @{
        Id = $p.Id; UILanguage = $wantUi; GeoId = $p.GeoId
        TimeZone = $(if ($SkipTimeZone) { '' } else { $p.TimeZone })
        UiSkipped = $uiSkippedReason
    } | Out-Null

    return [pscustomobject]@{
        Id              = $p.Id
        Country         = $p.Country
        UILanguage      = $wantUi
        UILanguageSkipped = $uiSkippedReason
        GeoId           = $p.GeoId
        Applied         = $locale
        Geo             = $geo
        DefaultRecorded = (Join-WfPath $stampDir 'region-default.json')
    }
}

function Get-WfRegionCountryCode {
    <#
        The two-letter code for a preset id. BE-nl and BE-fr are both BE, which
        is the whole reason this is a lookup rather than a substring.
    #>
    param([Parameter(Mandatory)] [string] $Id)

    switch -Regex ("$Id") {
        '^(?i)NL$'    { return 'NL' }
        '^(?i)BE-'    { return 'BE' }
        '^(?i)DE$'    { return 'DE' }
        '^(?i)SE$'    { return 'SE' }
        '^(?i)UK$'    { return 'GB' }
        default       { return '' }
    }
}

function Write-WfRegionAnswer {
<#
.SYNOPSIS
    Drops the chosen region into an applied image, for the first boot to pick up.
.DESCRIPTION
    The deployment side of the flow, and deliberately the smallest part of it:
    one small json file naming a preset. Everything about what that preset means
    is already in the image, baked into the first-boot script -- so this file
    cannot be wrong in an interesting way, only absent or naming a region that
    does not exist, and both of those are checked at first boot.

    Written after the image is applied and before the machine reboots into it.
    TargetRoot is the volume the image was just applied to, which in WinPE is
    rarely C: -- WinPE assigns letters in its own order.

    A technician with WinPE and no PowerShell can do the same thing with two
    lines of batch, which is what New-WfRegionPeScript generates:

        md W:\ProgramData\WimForge 2>nul
        echo {"Id":"BE-nl"}> W:\ProgramData\WimForge\region.json
.PARAMETER Id
    A preset id.
.PARAMETER TargetRoot
    The root of the applied image -- 'W:\', or a mounted image's path for testing.
.PARAMETER UILanguage
    Override the menu language for this machine. Only works if that display
    language is in the image; the first-boot script checks and says so in its log
    if it is not.
.PARAMETER Force
    Overwrite an answer that is already there.
.EXAMPLE
    Write-WfRegionAnswer -Id BE-fr -TargetRoot W:\
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $TargetRoot,
        [string] $UILanguage,
        [switch] $Force
    )

    $p = @(Get-WfRegionPreset -Id $Id)[0]

    if (-not (Test-Path -LiteralPath $TargetRoot)) {
        throw "$TargetRoot does not exist. In WinPE the applied volume is usually not C: -- check with diskpart what letter it got."
    }

    $dir  = Join-WfPath $TargetRoot 'ProgramData\WimForge'
    $file = Join-WfPath $dir 'region.json'

    if ((Test-Path -LiteralPath $file) -and -not $Force) {
        throw "$file already exists. Use -Force to replace it."
    }

    if (-not $PSCmdlet.ShouldProcess($file, "Record region $($p.Id)")) { return }

    New-WfDirectory $dir | Out-Null

    $answer = [ordered]@{ Id = $p.Id }
    if ($UILanguage) { $answer['UILanguage'] = $UILanguage }
    $answer['WrittenUtc'] = (Get-Date).ToUniversalTime().ToString('o')

    ([pscustomobject]$answer) | ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $file -Encoding UTF8

    Write-WfLog ("Region {0} recorded at {1}" -f $p.Id, $file) -Level OK
    Write-WfLog '  The first boot applies it and never asks. Delete the file to fall back to the image default.' -Level INFO

    return [pscustomobject]@{ Id = $p.Id; UILanguage = $UILanguage; Path = $file }
}

function Get-WfRegionAnswer {
<#
.SYNOPSIS
    Reads back the region answer, and the image's baked-in default, from a volume.
.DESCRIPTION
    Both files, because the pair is what decides what a till comes up as: the
    answer wins if it is there, the default stands if it is not.

    Works against an applied volume, a mounted image, or a running machine's C:.
.PARAMETER TargetRoot
    Defaults to the configured mount path, so it reads a mounted image.
.EXAMPLE
    Get-WfRegionAnswer -TargetRoot W:\
#>
    [CmdletBinding()]
    param([string] $TargetRoot)

    if (-not $TargetRoot) { $TargetRoot = (Get-WfConfig)['MountPath'] }

    $dir = Join-WfPath $TargetRoot 'ProgramData\WimForge'

    $read = {
        param([string] $Leaf)
        $path = Join-WfPath $dir $Leaf
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        try   { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
        catch { Write-WfLog "$path is not readable json: $($_.Exception.Message)" -Level WARN; return $null }
    }

    $answer  = & $read 'region.json'
    $default = & $read 'region-default.json'

    $effective = ''
    $source    = 'none'
    if ($answer -and $answer.Id)       { $effective = $answer.Id;  $source = 'answer' }
    elseif ($default -and $default.Id) { $effective = $default.Id; $source = 'image default' }

    if ($effective) {
        Write-WfLog ("This volume comes up as {0}, from the {1}." -f $effective, $source) -Level OK
    }
    else {
        Write-WfLog 'No region answer and no recorded image default on this volume.' -Level WARN
    }

    return [pscustomobject]@{
        Effective = $effective
        Source    = $source
        Answer    = $answer
        Default   = $default
        Path      = $dir
    }
}

function New-WfRegionPeScript {
<#
.SYNOPSIS
    Generates the WinPE fragment that asks which country and records the answer.
.DESCRIPTION
    The deployment half of the flow, as batch, because WinPE only has PowerShell
    if somebody added the optional component -- and a deployment script that
    depends on an optional component is one that fails on the boot.wim nobody
    prepared.

    What it does is deliberately tiny. It does not set anything. It writes one
    json file into the volume the image was just applied to, naming a country.
    All the actual work happens at first boot, inside Windows, where the tools
    for it exist.

    That split is the point: WinPE cannot set a Windows machine's regional
    settings, and every attempt to make it do so ends in loading offline hives
    from a preinstallation environment and getting it half right. Recording an
    answer is something WinPE can do perfectly.

    Paste the output into startnet.cmd after the /Apply-Image step, or call it
    from there. It expects the applied volume's letter in %WF_DST% if that is
    already set -- New-WfRecoveryBootImage's generated script uses the same
    variable -- and finds it by looking for \Windows\System32 otherwise.
.PARAMETER Offer
    Which presets to put on the menu. Defaults to all of them. Offer only the
    countries the estate actually has: a menu with one wrong entry on it is a
    machine deployed wrong.
.PARAMETER DefaultId
    The entry taken when the countdown runs out, which is what happens on a
    machine nobody is standing in front of. Omit for no default -- the script
    then waits, and a technician has to answer.
.PARAMETER TimeoutSeconds
    How long to wait before taking the default. Ignored without -DefaultId.
.PARAMETER Path
    Where to write the fragment. Omit to return the lines instead.
.EXAMPLE
    New-WfRegionPeScript -Offer NL, BE-nl, BE-fr -DefaultId NL -Path C:\Imaging\Pe\region.cmd
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]] $Offer,
        [string]   $DefaultId,
        [int]      $TimeoutSeconds = 60,
        [string]   $Path
    )

    $presets = @(Get-WfRegionPreset -Id $Offer)
    if ($DefaultId) {
        $null = Get-WfRegionPreset -Id $DefaultId
        if (@($presets | Where-Object { $_.Id -eq $DefaultId }).Count -eq 0) {
            throw ("The default {0} is not on the menu. -Offer has: {1}." -f `
                   $DefaultId, (@($presets | ForEach-Object { $_.Id }) -join ', '))
        }
    }

    # choice.exe takes a set of CHARACTERS, not a set of numbers. Ten entries
    # would produce /C 12345678910, which is the digits 1,2,...,9,1,0 -- a menu
    # where 1 selects the first entry and the tenth is unreachable. Nobody would
    # see that until the tenth country was added.
    if ($presets.Count -gt 9) {
        throw ("A choice menu can only carry nine entries, and {0} were offered. Narrow -Offer to the countries this estate actually has." -f $presets.Count)
    }

    $cmd = New-Object System.Collections.Generic.List[string]
    $cmd.Add('@echo off')
    $cmd.Add('rem WimForge -- record the region for the machine being deployed.')
    $cmd.Add('rem Generated. Nothing here changes a setting: it writes one json file')
    $cmd.Add('rem into the applied image, and the first boot reads it.')
    $cmd.Add('')
    # The applied volume. WinPE letters are not Windows letters, so the letter is
    # found by looking for the thing that was just laid down rather than assumed.
    $cmd.Add('if not "%WF_DST%"=="" goto :have_target')
    $cmd.Add('for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (')
    $cmd.Add('    if exist %%d:\Windows\System32\ntoskrnl.exe set WF_DST=%%d:')
    $cmd.Add(')')
    $cmd.Add(':have_target')
    $cmd.Add('if "%WF_DST%"=="" (')
    $cmd.Add('    echo   No applied Windows volume was found, so the region cannot be recorded.')
    $cmd.Add('    echo   The machine will come up with the region baked into the image.')
    $cmd.Add('    goto :eof')
    $cmd.Add(')')
    $cmd.Add('')
    $cmd.Add('echo.')
    $cmd.Add('echo   Which country is this machine for?')
    $cmd.Add('echo.')

    $n = 0
    foreach ($p in $presets) {
        $n++
        # No parentheses and no angle brackets. Both mean something to the
        # command processor, and a marker is not worth a broken menu.
        $marker = ''
        if ($DefaultId -and $p.Id -eq $DefaultId) { $marker = '   -- default' }
        # Batch eats these. Parentheses are the ones that matter -- 'Belgium
        # (Dutch)' inside a parenthesised block ends the block early, and the
        # rest of the menu becomes commands. They become a dash rather than
        # vanishing, because 'Belgium  Dutch' is not a country.
        $safeCountry = (($p.Country -replace '\s*\(([^)]*)\)\s*', ' - $1') -replace '[<>|&^()]', ' ').Trim()
        $cmd.Add(('echo     {0}. {1}{2}' -f $n, $safeCountry, $marker))
    }

    $cmd.Add('echo.')
    $cmd.Add('set WF_REGION=')

    if ($DefaultId) {
        $defaultIndex = 1 + [array]::IndexOf(@($presets | ForEach-Object { $_.Id }), $DefaultId)
        $cmd.Add(('echo   Nothing typed within {0} seconds takes {1}.' -f $TimeoutSeconds, $DefaultId))
        $cmd.Add('echo.')
        # choice.exe is in WinPE and does the countdown properly. timeout.exe is
        # not reliably there, and set /p cannot time out at all.
        $cmd.Add(('choice /C {0} /N /T {1} /D {2} /M "  Pick a number: "' -f `
                  (1..$n -join ''), $TimeoutSeconds, $defaultIndex))
        $cmd.Add('set WF_PICK=%ERRORLEVEL%')
    }
    else {
        $cmd.Add(('choice /C {0} /N /M "  Pick a number: "' -f (1..$n -join '')))
        $cmd.Add('set WF_PICK=%ERRORLEVEL%')
    }

    $i = 0
    foreach ($p in $presets) {
        $i++
        $cmd.Add(('if "%WF_PICK%"=="{0}" set WF_REGION={1}' -f $i, $p.Id))
    }

    $cmd.Add('')
    $cmd.Add('if "%WF_REGION%"=="" (')
    $cmd.Add('    echo   Nothing was chosen. The image default stands.')
    $cmd.Add('    goto :eof')
    $cmd.Add(')')
    $cmd.Add('')
    $cmd.Add('md "%WF_DST%\ProgramData\WimForge" 2>nul')
    # One line, no pretty-printing: a batch echo cannot produce multi-line json
    # without a temp file, and the first-boot reader does not care.
    $cmd.Add('echo {"Id":"%WF_REGION%"}> "%WF_DST%\ProgramData\WimForge\region.json"')
    $cmd.Add('echo.')
    $cmd.Add('echo   Recorded %WF_REGION%. The first boot applies it.')
    $cmd.Add('goto :eof')

    if ($Path) {
        if ($PSCmdlet.ShouldProcess($Path, 'Write the WinPE region fragment')) {
            New-WfDirectory (Split-Path $Path -Parent) | Out-Null
            # ASCII, no BOM: read by the command processor before anything sets a
            # code page, and a BOM on line one stops @echo off working.
            Set-Content -LiteralPath $Path -Value $cmd -Encoding Ascii -Force
            Write-WfLog ("WinPE region fragment written to {0}, {1} line(s)" -f $Path, $cmd.Count) -Level OK
            Write-WfLog '  Call it from startnet.cmd after /Apply-Image, with %WF_DST% set to the applied volume.' -Level INFO
        }
    }

    return [pscustomobject]@{
        Path    = $Path
        Lines   = $cmd.ToArray()
        Offered = @($presets | ForEach-Object { $_.Id })
        Default = $DefaultId
    }
}

function New-WfRegionFirstBoot {
<#
.SYNOPSIS
    Puts the region applier into a mounted image, to run at first boot.
.DESCRIPTION
    The half that does the work. Runs from SetupComplete.cmd as SYSTEM, before
    anyone logs on:

      * region.json present  -- applies it and never asks. This is the deployed
                                case: WinPE already recorded the answer.
      * region.json absent   -- the region baked into the image at build time
                                stands, and nothing happens.
      * -Ask, and absent     -- one question at the first logon, with the image
                                default pre-selected and a countdown.

    The question cannot live in SetupComplete.cmd. That script runs as SYSTEM
    with no interactive desktop, so anything that waits for input hangs the
    machine forever with a blank screen and no way to know why. So -Ask does the
    only correct thing: SetupComplete registers a RunOnce entry, and the question
    appears at the first interactive logon, where there is a desktop and a person.

    That split has a second benefit. Applied by the first-boot script as SYSTEM,
    the settings reach the machine, the logon screen and every account created
    afterwards -- but not an account that already existed. Applied by the RunOnce
    at logon, they reach the person who is standing there. Between them the
    ground is covered.

    How it applies them: the international settings answer file, through
    `control.exe intl.cpl,,/f:`. That format, unlike unattend.xml, carries the
    GeoID and can copy the finished set to the default user and system accounts
    in one call. The time zone is not in it, so tzutil does that. Then it reads
    the settings back and logs them, because this is a machine nobody will be
    looking at.
.PARAMETER Offer
    Presets the question offers. Defaults to all of them. Ignored without -Ask,
    except that every offered preset's values are baked into the script.
.PARAMETER DefaultId
    The pre-selected answer, and what the countdown takes. Defaults to whatever
    Set-WfImageRegion recorded as this image's region.
.PARAMETER Ask
    Ask at the first logon when no answer was recorded. Without this, a machine
    deployed without an answer silently keeps the image default -- which is the
    right behaviour for an estate that images per country.
.PARAMETER TimeoutSeconds
    How long the question waits before taking the default.
.PARAMETER LogPath
    Where the applier logs, as the till will see it.
.PARAMETER NoSetupComplete
    Write the script into the image but do not wire SetupComplete.cmd. For a
    build that calls it from its own provisioning script.
.EXAMPLE
    New-WfRegionFirstBoot -Offer NL, BE-nl, BE-fr, DE, SE
.EXAMPLE
    New-WfRegionFirstBoot -Ask -DefaultId NL -TimeoutSeconds 45
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]] $Offer,
        [string]   $DefaultId,
        [switch]   $Ask,
        [int]      $TimeoutSeconds = 60,
        [string]   $LogPath = 'C:\Windows\Temp\WimForge-Region.log',
        [string]   $MountPath,
        [switch]   $NoSetupComplete
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $presets = @(Get-WfRegionPreset -Id $Offer)

    # What the build already decided, rather than making the caller say it twice.
    if (-not $DefaultId) {
        $recorded = Join-WfPath $MountPath 'ProgramData\WimForge\region-default.json'
        if (Test-Path -LiteralPath $recorded) {
            try { $DefaultId = (Get-Content -LiteralPath $recorded -Raw | ConvertFrom-Json).Id } catch { }
            if ($DefaultId) { Write-WfLog "Default taken from the image: $DefaultId" -Level INFO }
        }
    }
    if ($DefaultId) {
        $null = Get-WfRegionPreset -Id $DefaultId
        if (@($presets | Where-Object { $_.Id -eq $DefaultId }).Count -eq 0) {
            throw ("The default {0} is not among the offered presets ({1}), so the countdown would have nothing to take." -f `
                   $DefaultId, (@($presets | ForEach-Object { $_.Id }) -join ', '))
        }
    }
    elseif ($Ask) {
        Write-WfLog 'No default region is recorded in this image, so the question has nothing to pre-select and will wait for an answer.' -Level WARN
        Write-WfLog '  Set-WfImageRegion records one. Or pass -DefaultId.' -Level INFO
    }

    if (-not $PSCmdlet.ShouldProcess($MountPath, 'Install the first-boot region applier')) { return }

    $scriptLines = New-WfRegionScriptBody -Preset $presets -DefaultId $DefaultId `
                                          -TimeoutSeconds $TimeoutSeconds -LogPath $LogPath -Ask:$Ask

    $scriptsDir = Join-WfPath $MountPath 'Windows\Setup\Scripts'
    New-WfDirectory $scriptsDir | Out-Null
    $target = Join-WfPath $scriptsDir 'WimForge-Region.ps1'

    # UTF8 with a BOM, deliberately, and the opposite of the rule for .cmd:
    # PowerShell 5.1 reads a BOM-less file as the machine's ANSI code page, and
    # this script carries country names with accents in them.
    Set-Content -LiteralPath $target -Value $scriptLines -Encoding UTF8 -Force
    Write-WfLog ("Region applier written to Windows\Setup\Scripts\WimForge-Region.ps1, {0} line(s)" -f $scriptLines.Count) -Level OK

    $wired = $false
    if (-not $NoSetupComplete) {
        $cmd = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\WimForge-Region.ps1" -Mode Apply'
        Set-WfFirstBootScript -Command $cmd -LogPath $LogPath -MountPath $MountPath -Append | Out-Null
        $wired = $true
    }
    else {
        Write-WfLog 'SetupComplete.cmd not touched. Run it yourself with: -Mode Apply' -Level INFO
    }

    if ($Ask) {
        Write-WfLog ("With no recorded answer, the first person to log on gets one question, {0}s countdown." -f $TimeoutSeconds) -Level INFO
    }
    else {
        Write-WfLog 'With no recorded answer, the image default stands and nobody is asked.' -Level INFO
    }

    Write-WfHistory -Action 'Region first boot' -ImagePath $MountPath -Detail @{
        Offered = (@($presets | ForEach-Object { $_.Id }) -join ', ')
        Default = $DefaultId; Ask = [bool]$Ask; Timeout = $TimeoutSeconds
        SetupComplete = $wired
    } | Out-Null

    return [pscustomobject]@{
        Path          = $target
        Lines         = $scriptLines.Count
        Offered       = @($presets | ForEach-Object { $_.Id })
        Default       = $DefaultId
        Ask           = [bool]$Ask
        SetupComplete = $wired
        LogPath       = $LogPath
    }
}

function New-WfRegionScriptBody {
    <#
        Builds the script that runs on the till.

        Separated from New-WfRegionFirstBoot so it can be generated and read
        without a mounted image, which is how the tests check it -- a generated
        script nobody can look at without a Windows machine and a wim is a
        generated script that gets shipped wrong.

        Two things it must not do, both learned from SetupComplete.cmd:

          it must not prompt in -Mode Apply, which runs as SYSTEM with no
          desktop, where a prompt hangs the machine with nothing on screen;

          it must not fail. A region that did not get set is a machine with the
          wrong date format. A first-boot script that throws is a machine that
          may not finish setting itself up at all. So every step is inside a try
          and everything lands in the log.
    #>
    param(
        [Parameter(Mandatory)] [object[]] $Preset,
        [string] $DefaultId,
        [int]    $TimeoutSeconds = 60,
        [string] $LogPath = 'C:\Windows\Temp\WimForge-Region.log',
        [switch] $Ask
    )

    $L = New-Object System.Collections.Generic.List[string]
    $add = { param([string] $s) $L.Add($s) }

    & $add '# WimForge -- region applier. Generated by New-WfRegionFirstBoot.'
    & $add '# Edit the image, not this file: it is overwritten on the next build.'
    & $add '#'
    & $add '# -Mode Apply  runs from SetupComplete.cmd as SYSTEM, before any logon.'
    & $add '#              No desktop, so it never prompts.'
    & $add '# -Mode Ask    runs from RunOnce at the first interactive logon, where'
    & $add '#              there is a person to answer.'
    & $add 'param('
    & $add "    [ValidateSet('Apply','Ask')] [string] `$Mode = 'Apply',"
    & $add '    [string] $RegionId'
    & $add ')'
    & $add ''
    & $add '$ErrorActionPreference = ''Continue'''
    & $add ("`$LogPath = '{0}'" -f $LogPath)
    & $add ''
    & $add 'function Write-Line {'
    & $add '    param([string] $Text)'
    & $add '    $line = ''[{0:yyyy-MM-dd HH:mm:ss}] {1}'' -f (Get-Date), $Text'
    & $add '    Write-Host $line'
    & $add '    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }'
    & $add '}'
    & $add ''

    # -------------------------------------------------- the baked-in preset table
    & $add '# The regions this image was built to offer. Values come from the build,'
    & $add '# so a till never has to be told what a country means.'
    & $add '$Regions = @('
    foreach ($p in $Preset) {
        & $add ("    @{{ Id = '{0}'; Country = '{1}'; GeoId = {2}; UserLocale = '{3}'; SystemLocale = '{4}'; InputLocale = '{5}'; TimeZone = '{6}'; UILanguage = '{7}'; UIFallback = '{8}' }}" -f `
            $p.Id, ($p.Country -replace "'", "''"), $p.GeoId, $p.UserLocale, $p.SystemLocale,
            $p.InputLocale, $p.TimeZone, $p.UILanguage, $p.UIFallback)
    }
    & $add ')'
    & $add ''
    & $add ("`$DefaultId = '{0}'" -f $DefaultId)
    & $add ("`$TimeoutSeconds = {0}" -f $TimeoutSeconds)
    & $add "`$StateDir = Join-Path `$env:ProgramData 'WimForge'"
    & $add "`$AnswerFile = Join-Path `$StateDir 'region.json'"
    & $add "`$DefaultFile = Join-Path `$StateDir 'region-default.json'"
    & $add "`$AppliedFile = Join-Path `$StateDir 'region-applied.json'"
    & $add ''

    # -------------------------------------------------------- the answer file
    & $add '# The international settings answer file. NOT unattend.xml -- this is the'
    & $add '# format control.exe intl.cpl reads, and the only one that carries the'
    & $add '# GeoID and the copy-to-default-user and copy-to-system flags.'
    & $add '$Template = @'''
    foreach ($line in ((Get-WfRegionAnswerXmlTemplate) -split "`r?`n")) {
        & $add $line
    }
    & $add "'@"
    & $add ''
    & $add 'function Get-RegionRow {'
    & $add '    param([string] $Id)'
    & $add '    foreach ($r in $Regions) { if ($r.Id -eq $Id) { return $r } }'
    & $add '    return $null'
    & $add '}'
    & $add ''
    & $add 'function Set-Region {'
    & $add '    param($Row, [string] $UILanguage)'
    & $add ''
    & $add '    $mui = $Row.UILanguage'
    & $add '    if ($UILanguage) { $mui = $UILanguage }'
    & $add ''
    & $add '    # A menu language the machine does not have is not an error worth'
    & $add '    # failing over -- the formats still matter. It is worth saying, though,'
    & $add '    # because it is the one part of this that cannot be fixed without the'
    & $add '    # language pack.'
    & $add '    try {'
    & $add '        $have = @((Get-ChildItem ''HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages'' -ErrorAction Stop).PSChildName)'
    & $add '        if ($have.Count -gt 0 -and ($have -notcontains $mui)) {'
    & $add '            Write-Line ("  the menus stay as they are: {0} is not installed (this image has {1})" -f $mui, ($have -join '', ''))'
    & $add '            # The fallback if it is there, rather than whatever happens to be'
    & $add '            # first in the registry -- on an image with three languages that'
    & $add '            # would be an arbitrary one.'
    & $add '            if ($have -contains $Row.UIFallback) { $mui = $Row.UIFallback } else { $mui = $have[0] }'
    & $add '        }'
    & $add '    }'
    & $add '    catch { }'
    & $add ''
    & $add '    $xml = $Template -f $Row.GeoId, $mui, $Row.UIFallback, $Row.SystemLocale, $Row.InputLocale, $Row.UserLocale'
    & $add '    $file = Join-Path $env:TEMP ''WimForge-region.xml'''
    & $add '    # No byte order mark. Set-Content -Encoding UTF8 writes one on'
    & $add '    # PowerShell 5.1, and the intl.cpl parser answers anything it does not'
    & $add '    # like by rejecting the file with no error at all -- so the one input'
    & $add '    # it might object to is not worth leaving in.'
    & $add '    [System.IO.File]::WriteAllText($file, $xml, (New-Object System.Text.UTF8Encoding($false)))'
    & $add ''
    & $add '    Write-Line ("  applying {0}: {1} formats, {2} keyboard, home location {3}, menus {4}" -f $Row.Id, $Row.UserLocale, $Row.InputLocale, $Row.GeoId, $mui)'
    & $add ''
    & $add '    # This returns immediately and does its work in a child process, so'
    & $add '    # -Wait is not optional: without it the read-back below runs before'
    & $add '    # anything has been written and reports the old settings.'
    & $add '    try {'
    & $add '        Start-Process -FilePath ''control.exe'' -ArgumentList ("intl.cpl,,/f:`"{0}`"" -f $file) -Wait -WindowStyle Hidden -ErrorAction Stop'
    & $add '    }'
    & $add '    catch { Write-Line ("  intl.cpl failed: {0}" -f $_.Exception.Message) }'
    & $add ''
    & $add '    # The time zone is in no answer file of any kind.'
    & $add '    try {'
    & $add '        & tzutil.exe /s $Row.TimeZone'
    & $add '        if ($LASTEXITCODE -eq 0) { Write-Line ("  time zone {0}" -f $Row.TimeZone) }'
    & $add '        else { Write-Line ("  tzutil refused {0} (exit {1})" -f $Row.TimeZone, $LASTEXITCODE) }'
    & $add '    }'
    & $add '    catch { Write-Line ("  time zone failed: {0}" -f $_.Exception.Message) }'
    & $add ''
    & $add '    # Read back rather than trusting it. intl.cpl reports nothing at all --'
    & $add '    # not an exit code, not a message -- so the only way to know it took is'
    & $add '    # to go and look.'
    & $add '    $geo = ''''; $loc = '''''
    & $add '    try { $geo = (Get-ItemProperty ''HKCU:\Control Panel\International\Geo'' -Name Nation -ErrorAction Stop).Nation } catch { }'
    & $add '    try { $loc = (Get-ItemProperty ''HKCU:\Control Panel\International'' -Name LocaleName -ErrorAction Stop).LocaleName } catch { }'
    & $add '    Write-Line ("  read back: home location {0}, user locale {1}" -f $geo, $loc)'
    & $add ''
    & $add '    if ("$geo" -ne "$($Row.GeoId)") {'
    & $add '        Write-Line ("  WARNING the home location did not take -- wanted {0}, got {1}. Check the Application event log for an intl.cpl entry." -f $Row.GeoId, $geo)'
    & $add '    }'
    & $add ''
    & $add '    # Windows 11 has a supported way to push the current account''s settings'
    & $add '    # to the welcome screen and to new accounts. The answer file flags do'
    & $add '    # the same thing and this is belt and braces, so a machine without the'
    & $add '    # cmdlet is not a problem.'
    & $add '    try {'
    & $add '        if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {'
    & $add '            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction Stop'
    & $add '            Write-Line ''  copied to the welcome screen and to new accounts'''
    & $add '        }'
    & $add '    }'
    & $add '    catch { Write-Line ("  the copy to system accounts failed: {0}" -f $_.Exception.Message) }'
    & $add ''
    & $add '    try {'
    & $add '        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }'
    & $add '        [pscustomobject]@{ Id = $Row.Id; UILanguage = $mui; GeoIdReadBack = "$geo"; LocaleReadBack = "$loc"; AppliedUtc = (Get-Date).ToUniversalTime().ToString(''o'') } |'
    & $add '            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $AppliedFile -Encoding UTF8'
    & $add '    }'
    & $add '    catch { }'
    & $add ''
    & $add '    Write-Line ''  a restart is needed before the system locale and the logon screen follow.'''
    & $add '}'
    & $add ''

    # ------------------------------------------------------------- Apply mode
    & $add 'if ($Mode -eq ''Apply'') {'
    & $add '    Write-Line ''WimForge region: starting.'''
    & $add ''
    & $add '    $answer = $null'
    & $add '    if (Test-Path -LiteralPath $AnswerFile) {'
    & $add '        try { $answer = Get-Content -LiteralPath $AnswerFile -Raw | ConvertFrom-Json }'
    & $add '        catch { Write-Line ("region.json is not readable json, so it is ignored: {0}" -f $_.Exception.Message) }'
    & $add '    }'
    & $add ''
    & $add '    if ($answer -and $answer.Id) {'
    & $add '        $row = Get-RegionRow -Id $answer.Id'
    & $add '        if ($row) {'
    & $add '            Write-Line ("deployment recorded {0} -- applying it, no question asked." -f $answer.Id)'
    & $add '            Set-Region -Row $row -UILanguage $answer.UILanguage'
    & $add '        }'
    & $add '        else {'
    & $add '            Write-Line ("region.json names {0}, which this image was not built with. It knows: {1}. The image default stands." -f $answer.Id, (($Regions | ForEach-Object { $_.Id }) -join '', ''))'
    & $add '        }'
    & $add '        Write-Line ''WimForge region: done.'''
    & $add '        exit 0'
    & $add '    }'
    & $add ''
    & $add '    Write-Line ''no region was recorded at deployment.'''

    if ($Ask) {
        & $add ''
        & $add '    # The question cannot be asked here: this runs as SYSTEM with no'
        & $add '    # desktop, and anything waiting for input would hang the machine'
        & $add '    # with a blank screen. So it is handed to the first logon, which'
        & $add '    # has both a desktop and a person.'
        & $add '    try {'
        & $add '        $runOnce = ''HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'''
        & $add '        if (-not (Test-Path -LiteralPath $runOnce)) { New-Item -Path $runOnce -Force | Out-Null }'
        & $add '        $me = Join-Path $env:SystemRoot ''Setup\Scripts\WimForge-Region.ps1'''
        & $add '        $val = ''powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode Ask'' -f $me'
        & $add '        New-ItemProperty -LiteralPath $runOnce -Name ''WimForgeRegion'' -Value $val -PropertyType String -Force | Out-Null'
        & $add '        Write-Line ''the first person to log on will be asked. RunOnce registered.'''
        & $add ''
        & $add '        # RunOnce deletes the value before running it, and Windows deletes'
        & $add '        # SetupComplete.cmd after it runs -- so this script has to survive'
        & $add '        # both. It lives in Setup\Scripts, which Windows does not clear.'
        & $add '    }'
        & $add '    catch { Write-Line ("could not register the question: {0}. The image default stands." -f $_.Exception.Message) }'
    }
    else {
        & $add '    Write-Line ''the region baked into this image stands. Nobody is asked.'''
    }

    & $add ''
    & $add '    Write-Line ''WimForge region: done.'''
    & $add '    exit 0'
    & $add '}'
    & $add ''

    # --------------------------------------------------------------- Ask mode
    & $add 'if ($Mode -eq ''Ask'') {'
    & $add '    Write-Line ''WimForge region: asking.'''
    & $add ''
    & $add '    if ($RegionId) {'
    & $add '        $row = Get-RegionRow -Id $RegionId'
    & $add '        if ($row) { Set-Region -Row $row; Write-Line ''done.''; exit 0 }'
    & $add '        Write-Line ("{0} is not a region this image knows." -f $RegionId)'
    & $add '        exit 1'
    & $add '    }'
    & $add ''
    & $add '    $default = $DefaultId'
    & $add '    if (-not $default) {'
    & $add '        try { $default = (Get-Content -LiteralPath $DefaultFile -Raw | ConvertFrom-Json).Id } catch { }'
    & $add '    }'
    & $add '    if (-not $default -and $Regions.Count -gt 0) { $default = $Regions[0].Id }'
    & $add ''
    & $add '    $chosen = $null'
    & $add '    try {'
    & $add '        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop'
    & $add '        Add-Type -AssemblyName System.Drawing -ErrorAction Stop'
    & $add ''
    & $add '        $form = New-Object System.Windows.Forms.Form'
    & $add '        $form.Text = ''Region'''
    & $add '        $form.ClientSize = New-Object System.Drawing.Size(420, 260)'
    & $add '        $form.FormBorderStyle = ''FixedDialog'''
    & $add '        $form.StartPosition = ''CenterScreen'''
    & $add '        $form.TopMost = $true'
    & $add '        $form.MinimizeBox = $false; $form.MaximizeBox = $false'
    & $add ''
    & $add '        $label = New-Object System.Windows.Forms.Label'
    & $add '        $label.Text = ''Which country is this machine for?'''
    & $add '        $label.SetBounds(14, 14, 392, 20)'
    & $add '        $form.Controls.Add($label)'
    & $add ''
    & $add '        $list = New-Object System.Windows.Forms.ListBox'
    & $add '        $list.SetBounds(14, 40, 392, 132)'
    & $add '        foreach ($r in $Regions) { [void]$list.Items.Add(("{0}  --  {1}" -f $r.Id, $r.Country)) }'
    & $add '        $ix = 0'
    & $add '        for ($i = 0; $i -lt $Regions.Count; $i++) { if ($Regions[$i].Id -eq $default) { $ix = $i } }'
    & $add '        if ($list.Items.Count -gt 0) { $list.SelectedIndex = $ix }'
    & $add '        $form.Controls.Add($list)'
    & $add ''
    & $add '        $count = New-Object System.Windows.Forms.Label'
    & $add '        $count.SetBounds(14, 180, 392, 20)'
    & $add '        $form.Controls.Add($count)'
    & $add ''
    & $add '        $ok = New-Object System.Windows.Forms.Button'
    & $add '        $ok.Text = ''Use this one'''
    & $add '        $ok.SetBounds(226, 210, 180, 30)'
    & $add '        $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK'
    & $add '        $form.Controls.Add($ok)'
    & $add '        $form.AcceptButton = $ok'
    & $add ''
    & $add '        $keep = New-Object System.Windows.Forms.Button'
    & $add '        $keep.Text = ''Leave it as it is'''
    & $add '        $keep.SetBounds(14, 210, 180, 30)'
    & $add '        $keep.DialogResult = [System.Windows.Forms.DialogResult]::Cancel'
    & $add '        $form.Controls.Add($keep)'
    & $add '        $form.CancelButton = $keep'
    & $add ''
    & $add '        # The countdown takes the pre-selected answer, so a machine put on a'
    & $add '        # shelf and forgotten still ends up configured rather than waiting'
    & $add '        # on a dialog nobody will ever click.'
    & $add '        $script:Left = $TimeoutSeconds'
    & $add '        $count.Text = ("Taking {0} in {1} seconds." -f $default, $script:Left)'
    & $add '        $timer = New-Object System.Windows.Forms.Timer'
    & $add '        $timer.Interval = 1000'
    & $add '        $timer.Add_Tick({'
    & $add '            $script:Left--'
    & $add '            if ($script:Left -le 0) { $timer.Stop(); $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() }'
    & $add '            else { $count.Text = ("Taking {0} in {1} seconds." -f $default, $script:Left) }'
    & $add '        })'
    & $add '        # Any click or keystroke stops the clock: somebody is here, so there'
    & $add '        # is no reason to snatch the dialog away mid-decision.'
    & $add '        $list.Add_SelectedIndexChanged({ $timer.Stop(); $count.Text = '''' })'
    & $add '        $timer.Start()'
    & $add ''
    & $add '        $result = $form.ShowDialog()'
    & $add '        $timer.Stop()'
    & $add ''
    & $add '        if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedIndex -ge 0) {'
    & $add '            $chosen = $Regions[$list.SelectedIndex]'
    & $add '        }'
    & $add '    }'
    & $add '    catch {'
    & $add '        # No desktop, no WinForms, or a locked-down till. Taking the default'
    & $add '        # silently beats leaving the machine unconfigured.'
    & $add '        Write-Line ("could not show the question ({0}), so the default is taken." -f $_.Exception.Message)'
    & $add '        $chosen = Get-RegionRow -Id $default'
    & $add '    }'
    & $add ''
    & $add '    if (-not $chosen) {'
    & $add '        Write-Line ''nothing was chosen. The settings are left as they are.'''
    & $add '        exit 0'
    & $add '    }'
    & $add ''
    & $add '    Set-Region -Row $chosen'
    & $add ''
    & $add '    try {'
    & $add '        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }'
    & $add '        [pscustomobject]@{ Id = $chosen.Id; WrittenUtc = (Get-Date).ToUniversalTime().ToString(''o'') } |'
    & $add '            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $AnswerFile -Encoding UTF8'
    & $add '    }'
    & $add '    catch { }'
    & $add ''
    & $add '    Write-Line ''WimForge region: done. A restart finishes it.'''
    & $add '    exit 0'
    & $add '}'

    return $L.ToArray()
}
