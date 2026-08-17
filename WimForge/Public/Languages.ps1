# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Languages.ps1 -- a library of display languages, and putting them in an image.

    Why a library rather than reaching into the ISO on every build, which is the
    same argument as the driver library: the "Languages and Optional Features"
    ISO is several gigabytes, it is not on every machine that services an image,
    and its file names are not something anyone should be typing. Imported once
    into a folder per language, every build after that reads the folder.

    The distinction this whole file rests on, because it decides what is even
    possible: a DISPLAY LANGUAGE is a package and a REGION is a setting.

      Region -- user locale, system locale, keyboard, home location, time zone.
                Nothing to install. Set it offline, at deployment through an
                answer file, or on a running till, and it costs seconds.

      Display language -- a language pack cab plus its Features on Demand, which
                must physically be in the image. DISM is blunt about it: "If the
                language is not installed in the Windows image, the command will
                fail." An unattend.xml asking for a UI language that is not there
                fails just as surely, only more quietly.

    So an estate spanning the Netherlands, Belgium, Germany and Sweden needs ONE
    image with the right languages baked in, and the region chosen per site. And
    note there is no nl-BE or fr-BE display language -- Microsoft does not ship
    one. Belgium is Dutch or French menus with Belgian formats and an AZERTY
    layout on top.
#>

function Get-WfLanguageFileKind {
    <#
        What a file from the Languages ISO actually is, from its name.

        Two shapes matter:

          Microsoft-Windows-Client-Language-Pack_x64_nl-nl.cab
          Microsoft-Windows-LanguageFeatures-Basic-nl-nl-Package~31bf...~amd64~~.cab

        The first is the display language itself. The second is one of the
        satellites -- Basic, Fonts, OCR, Handwriting, Speech, TextToSpeech --
        which Microsoft recommends shipping alongside it.

        Returns Kind ('LanguagePack', 'Feature', 'Unknown'), Feature (the
        satellite's name when it is one) and Language (the tag, lower case).
        Never throws: an ISO holds plenty of files that are none of these.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Name)

    $result = [pscustomobject]@{ Kind = 'Unknown'; Feature = ''; Language = '' }
    $n = "$Name"

    # LIPs are named Language-Interface-Pack and behave the same way here.
    $lp = [regex]::Match($n, '(?i)Client-Language(?:-Interface)?-Pack_[^_]+_([a-z]{2,3}(?:-[A-Za-z]+)+)\.cab$')
    if ($lp.Success) {
        $result.Kind     = 'LanguagePack'
        $result.Language = $lp.Groups[1].Value.ToLowerInvariant()
        return $result
    }

    $fod = [regex]::Match($n, '(?i)LanguageFeatures-([A-Za-z]+)-([a-z]{2,3}(?:-[A-Za-z]+)+)-Package')
    if ($fod.Success) {
        $result.Kind     = 'Feature'
        $result.Feature  = $fod.Groups[1].Value
        $result.Language = $fod.Groups[2].Value.ToLowerInvariant()
        return $result
    }

    return $result
}

function Get-WfLanguageApplyOrder {
    <#
        The order packages go into an image.

        The language pack first, because the satellites attach to it. Basic next
        because Microsoft lists it as required; the rest are optional and their
        order between themselves does not matter -- it is fixed here only so two
        runs of the same build produce the same log.
    #>
    return @('Basic', 'Fonts', 'OCR', 'Handwriting', 'Speech', 'TextToSpeech')
}

function Import-WfLanguagePack {
<#
.SYNOPSIS
    Copies a display language out of the Languages ISO into the language library.
.DESCRIPTION
    Run once per language, from the "Languages and Optional Features" ISO for the
    build you are servicing -- the packs are version-matched, and a 24H2 pack does
    not belong in a 22H2 image.

    Everything for one language lands in its own folder, with a small manifest
    recording where it came from and when. After that the ISO is not needed: the
    machine building an image reads the library.

    Only .cab packages are taken. The .appx Language Experience Packs cannot be
    added to an offline image at all -- Microsoft's documentation says so plainly
    -- so quietly copying them would only lead to a confusing failure later.
.PARAMETER Source
    The mounted ISO, or the LanguagesAndOptionalFeatures folder inside it.
    Searched recursively.
.PARAMETER Language
    Language tags, e.g. nl-NL, de-DE, sv-SE. Omit to import every language the
    source contains, which is rarely what you want -- that is a lot of disk.
.PARAMETER LibraryRoot
    Where the library lives. Defaults to the configured LanguageRoot.
.PARAMETER Force
    Replace a language already in the library.
.EXAMPLE
    Import-WfLanguagePack -Source E:\ -Language nl-NL, de-DE, sv-SE
.EXAMPLE
    Import-WfLanguagePack -Source E:\LanguagesAndOptionalFeatures
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [string[]] $Language,
        [string]   $LibraryRoot,
        [switch]   $Force
    )

    $cfg = Get-WfConfig
    if (-not $LibraryRoot) { $LibraryRoot = $cfg['LanguageRoot'] }

    $Source = Assert-WfPath -Path $Source -Label 'Language source'
    New-WfDirectory $LibraryRoot | Out-Null

    Write-WfLog "Reading $Source" -Level STEP
    $cabs = @(Get-ChildItem -LiteralPath $Source -Filter '*.cab' -File -Recurse -ErrorAction SilentlyContinue)
    Write-WfLog ("{0} .cab file(s) found" -f $cabs.Count) -Level INFO

    # Classified first, then filtered, so the log can say what the source holds
    # even when the language asked for is not among it.
    $known = @($cabs | ForEach-Object {
        $kind = Get-WfLanguageFileKind -Name $_.Name
        if ($kind.Kind -eq 'Unknown') { return }
        [pscustomobject]@{ File = $_; Kind = $kind.Kind; Feature = $kind.Feature; Language = $kind.Language }
    } | Where-Object { $_ })

    # Feature cabs that carry no language tag are real and are NOT imported: the
    # supplemental font packs are named after the script rather than the locale
    # (Fonts-PanEuropeanSupplementalFonts, Fonts-Jpan), so no per-language folder
    # is the right home for them. Said out loud, because a file that silently
    # does not get copied is the kind of thing found out from a menu rendering
    # with missing glyphs six months later.
    $untagged = @($cabs | Where-Object {
        $_.Name -match '(?i)LanguageFeatures' -and (Get-WfLanguageFileKind -Name $_.Name).Kind -eq 'Unknown'
    })
    if ($untagged.Count -gt 0) {
        Write-WfLog ("{0} feature cab(s) here carry no language tag and are not imported: {1}" -f `
            $untagged.Count, ((@($untagged | Select-Object -First 3 | ForEach-Object { $_.Name })) -join ', ')) -Level WARN
        Write-WfLog '  Those are script-wide rather than per-language -- add them by hand if an image needs them.' -Level INFO
    }

    $available = @($known | ForEach-Object { $_.Language } | Sort-Object -Unique)
    if ($available.Count -eq 0) {
        throw ("No language packages found under $Source. The Languages ISO keeps them in " +
               "\LanguagesAndOptionalFeatures; a Windows installation ISO does not contain them at all.")
    }
    Write-WfLog ("Languages in this source: {0}" -f ($available -join ', ')) -Level OK

    $wanted = @($available)
    if ($Language) {
        $wanted  = @()
        $missing = @()
        foreach ($l in $Language) {
            $tag = "$l".ToLowerInvariant()
            if ($available -contains $tag) { $wanted += $tag } else { $missing += $l }
        }
        if ($missing.Count -gt 0) {
            throw ("Not in this source: {0}. It has: {1}." -f ($missing -join ', '), ($available -join ', '))
        }
    }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($tag in $wanted) {
        $files = @($known | Where-Object { $_.Language -eq $tag })
        $dest  = Join-WfPath $LibraryRoot $tag

        if ((Test-Path -LiteralPath $dest) -and -not $Force) {
            Write-WfLog "$tag is already in the library -- skipped. Use -Force to replace it." -Level WARN
            $results.Add([pscustomobject]@{ Language = $tag; Files = 0; Status = 'AlreadyPresent' })
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($dest, "Import $tag")) { continue }

        Write-WfLog ("Importing {0}: {1} file(s)" -f $tag, $files.Count) -Level STEP
        New-WfDirectory $dest | Out-Null

        $copied = 0
        foreach ($f in $files) {
            Copy-Item -LiteralPath $f.File.FullName -Destination (Join-WfPath $dest $f.File.Name) -Force
            $copied++
        }

        # A manifest, for the same reason the driver library has one: six months
        # later "which ISO did this come from" is a real question.
        $manifest = [pscustomobject]@{
            Language     = $tag
            ImportedUtc  = (Get-Date).ToUniversalTime().ToString('o')
            Source       = $Source
            LanguagePack = @($files | Where-Object { $_.Kind -eq 'LanguagePack' } | ForEach-Object { $_.File.Name })
            Features     = @($files | Where-Object { $_.Kind -eq 'Feature' }      | ForEach-Object { $_.Feature })
        }
        $manifest | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-WfPath $dest '_language.json') -Encoding UTF8

        $hasLp = @($files | Where-Object { $_.Kind -eq 'LanguagePack' }).Count -gt 0
        if (-not $hasLp) {
            Write-WfLog "  no language pack cab for $tag -- only satellites. A UI language cannot be set from this alone." -Level WARN
        }

        Write-WfLog ("  {0} file(s) into {1}" -f $copied, $dest) -Level OK
        $results.Add([pscustomobject]@{ Language = $tag; Files = $copied; Status = 'Imported' })
    }

    return $results.ToArray()
}

function Get-WfLanguageLibrary {
<#
.SYNOPSIS
    What is in the language library: one row per language.
.DESCRIPTION
    The same shape as Get-WfDriverLibrary, and for the same reason -- the front
    ends offer this as a list so nothing is typed from memory.

    HasLanguagePack is the column that matters. A folder holding only satellites
    cannot give an image a new UI language, and finding that out at build time is
    much better than finding it out from DISM.
.PARAMETER LibraryRoot
    Defaults to the configured LanguageRoot.
.EXAMPLE
    Get-WfLanguageLibrary | Format-Table Language, Name, HasLanguagePack, Features, SizeMB
#>
    [CmdletBinding()]
    param([string] $LibraryRoot)

    $cfg = Get-WfConfig
    if (-not $LibraryRoot) { $LibraryRoot = $cfg['LanguageRoot'] }

    if (-not (Test-Path -LiteralPath $LibraryRoot)) {
        Write-WfLog "The language library is empty: $LibraryRoot" -Level WARN
        Write-WfLog 'Import-WfLanguagePack fills it from the "Languages and Optional Features" ISO.' -Level INFO
        return @()
    }

    $out = New-Object System.Collections.Generic.List[object]

    foreach ($dir in Get-ChildItem -LiteralPath $LibraryRoot -Directory) {
        $cabs = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.cab' -File)
        if ($cabs.Count -eq 0) { continue }

        $kinds    = @($cabs | ForEach-Object { Get-WfLanguageFileKind -Name $_.Name })
        $features = @($kinds | Where-Object { $_.Kind -eq 'Feature' } | ForEach-Object { $_.Feature } | Sort-Object -Unique)
        $hasLp    = @($kinds | Where-Object { $_.Kind -eq 'LanguagePack' }).Count -gt 0

        $imported = $null
        $mf = Join-WfPath $dir.FullName '_language.json'
        if (Test-Path -LiteralPath $mf) {
            try { $imported = (Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json).ImportedUtc } catch { }
        }

        $ageDays = $null
        if ($imported) {
            try { $ageDays = [math]::Round(((Get-Date) - [datetime]$imported).TotalDays) } catch { }
        }

        $name = $dir.Name
        try { $name = [System.Globalization.CultureInfo]::GetCultureInfo($dir.Name).DisplayName } catch { }

        $bytes = ($cabs | Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { $bytes = 0 }

        $out.Add([pscustomobject]@{
            Language        = $dir.Name
            Name            = $name
            HasLanguagePack = $hasLp
            Features        = ($features -join ', ')
            FeatureCount    = $features.Count
            FileCount       = $cabs.Count
            SizeMB          = [math]::Round($bytes / 1MB, 1)
            AgeDays         = $ageDays
            Path            = $dir.FullName
        })
    }

    Write-WfLog ("{0} language(s) in {1}" -f $out.Count, $LibraryRoot) -Level OK
    return $out.ToArray()
}

function Get-WfImageLanguage {
<#
.SYNOPSIS
    The display languages actually inside a mounted image, and their satellites.
.DESCRIPTION
    Two sources, because neither is complete on its own. dism /Get-Intl names the
    installed UI languages and which one is current; the package list says which
    Features on Demand came with them. A language with the pack but no Basic
    satellite works and looks odd in places, and that is worth being able to see
    before an image ships rather than after.
.PARAMETER MountPath
    Defaults to the configured mount path.
.EXAMPLE
    Get-WfImageLanguage | Format-Table Language, Name, IsUiLanguage, Features
#>
    [CmdletBinding()]
    param([string] $MountPath)

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $intl = Get-WfImageLocale -MountPath $MountPath

    $packages = @()
    try {
        $packages = @(Get-WindowsPackage -Path $MountPath -ErrorAction Stop |
                      Where-Object { "$($_.PackageName)" -match 'LanguageFeatures|LanguagePack' })
    }
    catch {
        Write-WfLog "Could not list packages: $($_.Exception.Message)" -Level WARN
    }

    $tags = @(@($intl.InstalledLanguages) + @($intl.UILanguage) |
              Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($tag in $tags) {
        $mine = @($packages | Where-Object { "$($_.PackageName)" -match [regex]::Escape($tag) })
        $features = @($mine | ForEach-Object {
            $m = [regex]::Match("$($_.PackageName)", '(?i)LanguageFeatures-([A-Za-z]+)-')
            if ($m.Success) { $m.Groups[1].Value }
        } | Where-Object { $_ } | Sort-Object -Unique)

        $name = $tag
        try { $name = [System.Globalization.CultureInfo]::GetCultureInfo($tag).DisplayName } catch { }

        $out.Add([pscustomobject]@{
            Language     = $tag
            Name         = $name
            IsUiLanguage = ($tag -eq "$($intl.UILanguage)".ToLowerInvariant())
            Features     = ($features -join ', ')
            PackageCount = $mine.Count
        })
    }

    Write-WfLog ("{0} display language(s) in this image" -f $out.Count) -Level OK
    return $out.ToArray()
}

function Add-WfLanguage {
<#
.SYNOPSIS
    Adds display languages from the library to a mounted image.
.DESCRIPTION
    The language pack first, then its Features on Demand. That is the easy half.

    The half that catches people is the cumulative update. Microsoft's guidance
    is explicit: languages go in BEFORE the latest cumulative, and if the image
    already has one, the update must be reinstalled afterwards or the image ends
    up with a language whose resources stop at the build the pack shipped with.
    Nothing about that failure is visible at build time -- it shows up as English
    strings in a Dutch menu on a shipped till.

    So: pass -CumulativeUpdate and this re-applies it for you. Leave it out on an
    image that already has one and the run says loudly what still needs doing
    rather than reporting a clean finish it has not earned.

    New-WfReferenceImage already gets this order right when building from clean
    media. This is the same rule for an image that already exists.
.PARAMETER Language
    Tags from the library, e.g. nl-NL. Get-WfLanguageLibrary lists them.
.PARAMETER CumulativeUpdate
    The .msu to re-apply after the languages are in. Strongly recommended on any
    image that has been serviced.
.PARAMETER SkipFeatures
    Add the language pack only, no satellites. Smaller, and Microsoft does not
    recommend it -- handwriting, speech and OCR simply will not be there.
.PARAMETER Force
    Add a language the image already reports as installed.
.EXAMPLE
    Add-WfLanguage -Language nl-NL -CumulativeUpdate C:\Imaging\Updates\Windows11\KB5121767\windows11.0-kb5121767-x64.msu
.EXAMPLE
    Add-WfLanguage -Language de-DE, sv-SE -SkipFeatures
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string[]] $Language,
        [string] $MountPath,
        [string] $LibraryRoot,
        [string] $CumulativeUpdate,
        [switch] $SkipFeatures,
        [switch] $Force
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $MountPath)   { $MountPath   = $cfg['MountPath'] }
    if (-not $LibraryRoot) { $LibraryRoot = $cfg['LanguageRoot'] }

    $library = @(Get-WfLanguageLibrary -LibraryRoot $LibraryRoot)
    if ($library.Count -eq 0) {
        throw "The language library at $LibraryRoot is empty. Import-WfLanguagePack -Source <the Languages ISO> fills it."
    }

    # What is already in there, so a second run is not a second install.
    $present = @()
    try {
        $intl = Get-WfImageLocale -MountPath $MountPath
        $present = @(@($intl.InstalledLanguages) + @($intl.UILanguage) |
                     Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() })
    }
    catch { }

    $scratch = $null
    try { $scratch = New-WfDirectory $cfg['ScratchPath'] } catch { }

    $results = New-Object System.Collections.Generic.List[object]
    $added   = 0

    foreach ($l in $Language) {
        $tag  = "$l".ToLowerInvariant()
        $lang = @($library | Where-Object { $_.Language -eq $tag })[0]

        if (-not $lang) {
            throw ("{0} is not in the library. It has: {1}." -f $l, (@($library | ForEach-Object { $_.Language }) -join ', '))
        }
        if (-not $lang.HasLanguagePack) {
            throw ("{0} has no language pack cab in the library -- only satellites. Re-import it from the Languages ISO." -f $l)
        }

        if (($present -contains $tag) -and -not $Force) {
            Write-WfLog "$tag is already in this image -- skipped." -Level INFO
            $results.Add([pscustomobject]@{ Language = $tag; Package = ''; Status = 'AlreadyPresent'; Reason = 'The image already reports this display language.' })
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($MountPath, "Add $tag")) { continue }

        # Ordered: the pack, then Basic, then the rest. Get-WfLanguageApplyOrder
        # says why.
        $cabs  = @(Get-ChildItem -LiteralPath $lang.Path -Filter '*.cab' -File)
        $order = Get-WfLanguageApplyOrder

        $plan = @($cabs | ForEach-Object {
            $k = Get-WfLanguageFileKind -Name $_.Name
            $rank = 99
            if ($k.Kind -eq 'LanguagePack') { $rank = 0 }
            elseif ($k.Kind -eq 'Feature') {
                $ix = [array]::IndexOf($order, $k.Feature)
                if ($ix -ge 0) { $rank = 1 + $ix } else { $rank = 90 }
            }
            [pscustomobject]@{ File = $_; Kind = $k.Kind; Feature = $k.Feature; Rank = $rank }
        } | Where-Object { $_.Kind -ne 'Unknown' })

        if ($SkipFeatures) { $plan = @($plan | Where-Object { $_.Kind -eq 'LanguagePack' }) }
        $plan = @($plan | Sort-Object Rank, { $_.File.Name })

        Write-WfLog ("Adding {0}: {1} package(s)" -f $tag, $plan.Count) -Level STEP

        foreach ($p in $plan) {
            $what = $p.Kind
            if ($p.Feature) { $what = $p.Feature }
            Write-WfLog ("  + {0} ({1})" -f $p.File.Name, $what) -Level INFO
            try {
                $params = @{ MountPath = $MountPath; PackagePath = $p.File.FullName }
                if ($scratch) { $params['ScratchDirectory'] = $scratch }
                $null = Add-WfPackageOffline @params
                $results.Add([pscustomobject]@{ Language = $tag; Package = $p.File.Name; Status = 'Added'; Reason = '' })
                $added++
            }
            catch {
                $msg = $_.Exception.Message.Trim()
                $why = Get-WfDismError -Message $msg
                $results.Add([pscustomobject]@{
                    Language = $tag; Package = $p.File.Name; Status = 'Failed'
                    Reason = ($why.Summary + ' ' + $why.WhatToDo).Trim()
                })
                Write-WfLog ("  failed: {0}" -f $msg) -Level ERROR

                # The pack failing makes its satellites pointless, and carrying on
                # would bury the one line that matters under five more.
                if ($p.Kind -eq 'LanguagePack') {
                    Write-WfLog '  the language pack itself failed, so its satellites are not attempted.' -Level WARN
                    break
                }
            }
        }
    }

    # ------------------------------------------------ the cumulative update rule
    if ($added -gt 0) {
        if ($CumulativeUpdate) {
            $CumulativeUpdate = Assert-WfPath -Path $CumulativeUpdate -Label 'Cumulative update'
            Write-WfLog 'Re-applying the cumulative update, so the new language gets the resources it added' -Level STEP
            Write-WfLog '  Microsoft: a language added after an update needs that update reinstalled, or the language stops at the build its pack shipped with.' -Level INFO
            try {
                $params = @{ MountPath = $MountPath; PackagePath = $CumulativeUpdate }
                if ($scratch) { $params['ScratchDirectory'] = $scratch }
                $null = Add-WfPackageOffline @params
                $results.Add([pscustomobject]@{
                    Language = ''; Package = (Split-Path $CumulativeUpdate -Leaf)
                    Status = 'UpdateReapplied'; Reason = 'Re-applied after the languages, as Microsoft requires.' })
                Write-WfLog '  re-applied' -Level OK
            }
            catch {
                $msg = $_.Exception.Message.Trim()
                $results.Add([pscustomobject]@{
                    Language = ''; Package = (Split-Path $CumulativeUpdate -Leaf)
                    Status = 'Failed'; Reason = $msg })
                Write-WfLog ("  the re-apply failed: {0}" -f $msg) -Level ERROR
            }
        }
        else {
            # Is there an update in there to re-apply? If so, say so -- a run that
            # reports success while leaving the image half-localised is worse than
            # one that says what is missing.
            $hasUpdate = $false
            try {
                $hasUpdate = @(Get-WindowsPackage -Path $MountPath -ErrorAction Stop |
                               Where-Object { "$($_.PackageName)" -match 'RollupFix|Package_for_KB' }).Count -gt 0
            }
            catch { }

            if ($hasUpdate) {
                Write-WfLog 'This image already has a cumulative update, and no -CumulativeUpdate was given.' -Level WARN
                Write-WfLog 'The languages just added carry resources only up to the build their packs shipped with. Re-run with -CumulativeUpdate pointing at the .msu, or apply the update again, before shipping this image.' -Level WARN
                $results.Add([pscustomobject]@{
                    Language = ''; Package = ''; Status = 'UpdateReapplyNeeded'
                    Reason = 'The image has a cumulative update that must be re-applied after adding languages.' })
            }
        }
    }

    Write-WfHistory -Action 'Add languages' -ImagePath $MountPath -Detail @{
        Languages = ($Language -join ', ')
        Added     = $added
        Failed    = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
        Reapplied = [bool]$CumulativeUpdate
    } | Out-Null

    return $results.ToArray()
}
