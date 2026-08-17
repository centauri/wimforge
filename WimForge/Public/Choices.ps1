# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Choices.ps1 -- the lists behind every "pick one" in the front-ends.

    Typing '0413:00020409' from memory is not a user interface, and neither is
    typing 'W. Europe Standard Time' and finding out it was wrong twenty minutes
    into a servicing run. Everything here answers "what are my options" from a
    real source rather than from a list somebody typed once:

      time zones      the machine's own time zone database
      locales         .NET's culture list
      keyboards       the local keyboard layout registry
      UI languages    the IMAGE's installed languages -- because setting one that
                      is not in there fails, so offering it would be a lie

    Nothing here is hardcoded except the keyboard-filter key names, which are a
    fixed set defined by the Keyboard Filter feature itself.
#>

function ConvertTo-WfLcidHex {
    <#
        A culture name to the four hex digits DISM wants, or '' if it is not a
        culture at all.

        Not just a call to GetCultureInfo: given a well-formed tag that no locale
        exists for -- 'zz-ZZ' -- .NET does not throw. It hands back a custom
        culture with LCID 0x1000, the "unspecified custom locale" placeholder. So
        a typo comes out as '1000:00020409', which is a plausible-looking string
        that means nothing, and the keyboard is silently not what was asked for.

        0x1000 is therefore treated as no answer, which is what it is.

        Private to this file -- it is arithmetic, not a capability.
    #>
    param([string] $Name)

    if (-not $Name) { return '' }
    if ($Name -match '^[0-9A-Fa-f]{4}$') { return $Name.ToLowerInvariant() }

    try {
        $ci = [System.Globalization.CultureInfo]::GetCultureInfo($Name)
    }
    catch {
        return ''
    }

    if (-not $ci -or $ci.LCID -eq 0x1000) { return '' }
    return ('{0:x4}' -f $ci.LCID)
}

function Get-WfTimeZoneChoice {
<#
.SYNOPSIS
    The time zones this machine knows about, for picking rather than typing.
.DESCRIPTION
    Read from the running machine's time zone database, which is the same
    database the image will use. Ids are what DISM wants; the display name is
    what a human recognises.
.PARAMETER Filter
    Narrows the list -- 'Europe', 'Amsterdam', 'UTC'. Matched against both the id
    and the display name, so either works.
.EXAMPLE
    Get-WfTimeZoneChoice -Filter Europe
#>
    [CmdletBinding()]
    param([string] $Filter)

    $zones = @()
    try {
        $zones = @([System.TimeZoneInfo]::GetSystemTimeZones())
    }
    catch {
        Write-WfLog "Could not read the time zone database: $($_.Exception.Message)" -Level WARN
        return @()
    }

    $out = foreach ($z in $zones) {
        [pscustomobject]@{
            Id      = $z.Id
            Name    = $z.DisplayName
            Offset  = $z.BaseUtcOffset.ToString()
        }
    }

    if ($Filter) {
        $out = @($out | Where-Object { $_.Id -like "*$Filter*" -or $_.Name -like "*$Filter*" })
    }

    return @($out | Sort-Object Id)
}

function Get-WfLocaleChoice {
<#
.SYNOPSIS
    The locales available for system and user regional settings.
.DESCRIPTION
    From .NET's culture list, so it is the same set Windows knows. Specific
    cultures only -- 'nl' on its own is not a locale Windows accepts here, it
    wants 'nl-NL'.
.PARAMETER Filter
    'Dutch', 'nl-', 'Belgium' -- matched against the name and both display forms.
.EXAMPLE
    Get-WfLocaleChoice -Filter Dutch
#>
    [CmdletBinding()]
    param([string] $Filter)

    $cultures = @()
    try {
        $cultures = @([System.Globalization.CultureInfo]::GetCultures(
            [System.Globalization.CultureTypes]::SpecificCultures))
    }
    catch {
        Write-WfLog "Could not read the culture list: $($_.Exception.Message)" -Level WARN
        return @()
    }

    $out = foreach ($c in $cultures) {
        [pscustomobject]@{
            Name        = $c.Name
            DisplayName = $c.DisplayName
            EnglishName = $c.EnglishName
            Lcid        = $c.LCID
        }
    }

    if ($Filter) {
        $out = @($out | Where-Object {
            $_.Name -like "*$Filter*" -or $_.DisplayName -like "*$Filter*" -or $_.EnglishName -like "*$Filter*"
        })
    }

    return @($out | Sort-Object Name)
}

function Get-WfKeyboardChoice {
<#
.SYNOPSIS
    Keyboard layouts, paired with a language, in the form DISM wants.
.DESCRIPTION
    The input locale DISM takes is a language:layout pair of hex ids --
    '0413:00020409' is Dutch on a US-International keyboard. Nobody remembers
    those, and a wrong one is not obvious until a terminal types the wrong
    character for the euro sign.

    Layout names come from the local machine's keyboard layout registry, which is
    the authority on what each id actually is. Pair them with a language from
    Get-WfLocaleChoice to get the value.
.PARAMETER Filter
    'United States', 'Dutch', 'International'.
.PARAMETER Language
    A culture name, e.g. 'nl-NL'. When given, each layout comes back with the
    ready-made InputLocale string for that language.
.EXAMPLE
    Get-WfKeyboardChoice -Language nl-NL -Filter 'International'
#>
    [CmdletBinding()]
    param(
        [string] $Filter,
        [string] $Language
    )

    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
    if (-not (Test-Path -LiteralPath $root)) {
        Write-WfLog 'The keyboard layout registry is not readable on this machine.' -Level WARN
        return @()
    }

    $lcidHex = ''
    if ($Language) {
        $lcidHex = ConvertTo-WfLcidHex -Name $Language
        if (-not $lcidHex) {
            Write-WfLog "'$Language' is not a culture this machine knows -- the layout ids are still listed." -Level WARN
        }
    }

    $out = foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }

        $text = $props.'Layout Display Name'
        if (-not $text) { $text = $props.'Layout Text' }
        if (-not $text) { continue }

        # The display name is often an indirect string (@dll,-id). Resolving it
        # properly needs SHLoadIndirectString; the plain Layout Text is already
        # readable, so fall back to that rather than showing an @-reference.
        if ($text -match '^@') {
            if ($props.'Layout Text') { $text = $props.'Layout Text' } else { continue }
        }

        $entry = [pscustomobject]@{
            LayoutId    = $k.PSChildName
            Layout      = $text
            InputLocale = ''
        }
        if ($lcidHex) { $entry.InputLocale = "{0}:{1}" -f $lcidHex, $k.PSChildName }
        $entry
    }

    $out = @($out)
    if ($Filter) { $out = @($out | Where-Object { $_.Layout -like "*$Filter*" -or $_.LayoutId -like "*$Filter*" }) }

    return @($out | Sort-Object Layout)
}

function Get-WfUiLanguageChoice {
<#
.SYNOPSIS
    The UI languages actually present in an image.
.DESCRIPTION
    Not a list of every language Windows has -- a list of the ones this image can
    be set to. Setting a UI language whose pack is not in the image fails, so
    offering the full list would be offering a choice that does not exist.

    Read from dism /Get-Intl via Get-WfImageLocale.
.PARAMETER Locale
    A Get-WfImageLocale result that has already been read. Both front-ends show
    the current settings before offering to change them, which means they already
    have this -- and reading it again would be a second dism call inside the same
    mount for an answer that cannot have changed.
.PARAMETER MountPath
    Where the image is mounted. Only used when -Locale is not supplied.
.EXAMPLE
    Get-WfUiLanguageChoice
.EXAMPLE
    $now = Get-WfImageLocale
    Get-WfUiLanguageChoice -Locale $now
#>
    [CmdletBinding()]
    param(
        [string] $MountPath,
        [object] $Locale
    )

    $intl = $Locale
    if (-not $intl) { $intl = Get-WfImageLocale -MountPath $MountPath }
    if (-not $intl) { return @() }

    $langs = @($intl.InstalledLanguages | Where-Object { $_ })
    if ($langs.Count -eq 0 -and $intl.UILanguage) {
        # Some images report the current UI language without listing it as
        # installed. It is demonstrably there, so it belongs in the list.
        $langs = @($intl.UILanguage)
    }

    $out = foreach ($l in ($langs | Sort-Object -Unique)) {
        $display = $l
        try { $display = [System.Globalization.CultureInfo]::GetCultureInfo($l).DisplayName }
        catch { }

        [pscustomobject]@{
            Language = $l
            Name     = $display
            Current  = ($l -eq $intl.UILanguage)
        }
    }

    $out = @($out)
    Write-WfLog ("{0} UI language(s) in this image" -f $out.Count) -Level OK
    if ($out.Count -le 1) {
        Write-WfLog 'Only one, so the UI language is not really a choice here. Add a language pack to change that.' -Level INFO
    }
    return $out
}

function Get-WfInputLocaleValue {
<#
.SYNOPSIS
    Builds the language:layout string DISM wants out of two things a human picked.
.DESCRIPTION
    The whole reason the front-ends can offer a language list and a layout list
    separately is that this puts them back together. '0413:00020409' is Dutch on
    a US-International keyboard; nobody should be typing that, and nobody should
    be finding out it was wrong when a terminal types the wrong character for the
    euro sign.

    Language takes a culture name ('nl-NL') or an lcid that is already hex
    ('0413'), because the second one is what comes back out of an image that was
    already set.
.PARAMETER Language
    A culture name, or a four-digit hex lcid.
.PARAMETER LayoutId
    The eight hex digit layout id -- the key name under the keyboard layout
    registry, which is what Get-WfKeyboardChoice returns.
.EXAMPLE
    Get-WfInputLocaleValue -Language nl-NL -LayoutId 00020409
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Language,
        [Parameter(Mandatory)] [string] $LayoutId
    )

    if ($LayoutId -notmatch '^[0-9A-Fa-f]{8}$') {
        Write-WfLog "'$LayoutId' is not a keyboard layout id -- they are eight hex digits, like 00020409." -Level WARN
        return ''
    }

    $lcidHex = ConvertTo-WfLcidHex -Name $Language
    if (-not $lcidHex) {
        Write-WfLog "'$Language' is not a culture this machine knows, so the keyboard cannot be set from it." -Level WARN
        return ''
    }

    return ('{0}:{1}' -f $lcidHex, $LayoutId.ToLowerInvariant())
}

function Get-WfKeyboardFilterChoice {
<#
.SYNOPSIS
    The key combinations Keyboard Filter can block.
.DESCRIPTION
    A fixed set defined by the feature, so this is the one list here that is
    written down rather than read from the machine. The ids are what
    WEKF_PredefinedKey expects.

    Which ones matter depends on the terminal. A customer-facing screen wants
    everything that reaches Windows blocked; a back-office machine probably only
    wants the ones that close the application by accident.
#>
    [CmdletBinding()]
    param()

    $keys = @(
        @{ Id = 'Ctrl+Alt+Del';    What = 'the security screen -- task manager, sign out, lock' }
        @{ Id = 'Ctrl+Shift+Esc';  What = 'task manager directly' }
        @{ Id = 'Ctrl+Esc';        What = 'opens Start' }
        @{ Id = 'Alt+Tab';         What = 'switch away from the application' }
        @{ Id = 'Alt+Esc';         What = 'switch away from the application' }
        @{ Id = 'Alt+F4';          What = 'closes the application -- the classic accidental one' }
        @{ Id = 'Windows';         What = 'the Windows key on its own' }
        @{ Id = 'Windows+L';       What = 'locks the terminal' }
        @{ Id = 'Windows+R';       What = 'the Run box' }
        @{ Id = 'Windows+E';       What = 'File Explorer' }
        @{ Id = 'Windows+X';       What = 'the power user menu' }
        @{ Id = 'Windows+I';       What = 'Settings' }
        @{ Id = 'Windows+P';       What = 'display projection -- easy to hit and confusing to undo' }
        @{ Id = 'Windows+Tab';     What = 'task view' }
        @{ Id = 'F1';              What = 'help' }
        @{ Id = 'F11';             What = 'full screen toggle' }
        @{ Id = 'F12';             What = 'developer tools in a browser-based till' }
    )

    return @($keys | ForEach-Object { [pscustomobject]@{ Key = $_.Id; What = $_.What } })
}
