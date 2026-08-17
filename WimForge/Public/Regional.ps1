# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Regional.ps1 -- locale, time zone and OEM identity, applied to the image
    rather than to the answer file.

    Both of these live in unattend.xml in most builds, which means they are right
    only when the answer file is used. Deploy the same image with WDS defaults, or
    from a USB stick somebody built in a hurry, and the terminal comes up in US
    date format. Baking them into the image means the answer file becomes a place
    to OVERRIDE the defaults rather than the only thing that sets them.
#>

function Get-WfImageLocale {
<#
.SYNOPSIS
    Reports the international settings baked into a mounted image.
.DESCRIPTION
    Runs dism /Get-Intl and parses it. Worth doing before and after: DISM accepts
    a locale it cannot honour without complaint in some versions, and the only
    way to know it took is to read it back.
#>
    [CmdletBinding()]
    param([string] $MountPath)

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $output = Invoke-WfDism @("/Image:$MountPath", '/Get-Intl') -PassThruOutput
    $text   = ($output -join "`n")

    $get = {
        param([string] $Label)
        $m = [regex]::Match($text, '(?im)^\s*' + [regex]::Escape($Label) + '\s*:\s*(.+?)\s*$')
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    }

    $result = [pscustomobject]@{
        UILanguage       = (& $get 'Default system UI language')
        SystemLocale     = (& $get 'System locale')
        UserLocale       = (& $get 'User locale for default user')
        InputLocale      = (& $get 'Active keyboard(s)')
        InstalledLanguages = @([regex]::Matches($text, '(?im)^\s*Installed language\(s\)\s*:\s*(.+?)\s*$') |
                               ForEach-Object { $_.Groups[1].Value })
        Raw              = $text
    }

    Write-WfLog ("UI {0}, system {1}, user {2}" -f `
        $result.UILanguage, $result.SystemLocale, $result.UserLocale) -Level OK
    return $result
}

function Set-WfImageLocale {
<#
.SYNOPSIS
    Sets UI language, locales, keyboard and time zone in a mounted image.
.DESCRIPTION
    The four settings people conflate, kept apart because they do different
    things and are routinely set wrong together:

      UILanguage   what the menus are in. Requires that language pack to be in
                   the image already -- DISM cannot invent it.
      SystemLocale the ANSI code page for programs that are not Unicode-aware.
                   Changing this needs a reboot to take effect, which the
                   deployment supplies anyway.
      UserLocale   date, time, number and currency formats. This is the one that
                   makes 04/08 mean the fourth of August.
      InputLocale  the keyboard layout, as a language:layout pair.

    An English UI with Dutch regional formats -- the usual answer for a Dutch
    estate whose support notes are in English -- is UILanguage en-US with
    SystemLocale and UserLocale nl-NL.

    Anything left blank is not touched.
.PARAMETER InputLocale
    Language and keyboard as DISM wants them: '0409:00000409' is US English on a
    US keyboard, '0413:00020409' is Dutch on a US-International layout.
.PARAMETER TimeZone
    A Windows time zone id, e.g. 'W. Europe Standard Time'. Run
    `tzutil /l` for the full list.
.EXAMPLE
    Set-WfImageLocale -UILanguage en-US -SystemLocale nl-NL -UserLocale nl-NL -TimeZone 'W. Europe Standard Time'
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $UILanguage,
        [string] $SystemLocale,
        [string] $UserLocale,
        [string] $InputLocale,
        [string] $TimeZone,
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $steps = New-Object System.Collections.Generic.List[object]
    if ($UILanguage)   { $steps.Add(@{ Arg = "/Set-UILang:$UILanguage";     What = "UI language $UILanguage" }) }
    if ($SystemLocale) { $steps.Add(@{ Arg = "/Set-SysLocale:$SystemLocale";What = "system locale $SystemLocale" }) }
    if ($UserLocale)   { $steps.Add(@{ Arg = "/Set-UserLocale:$UserLocale"; What = "user locale $UserLocale" }) }
    if ($InputLocale)  { $steps.Add(@{ Arg = "/Set-InputLocale:$InputLocale"; What = "keyboard $InputLocale" }) }
    if ($TimeZone)     { $steps.Add(@{ Arg = "/Set-TimeZone:$TimeZone";     What = "time zone $TimeZone" }) }

    if ($steps.Count -eq 0) { throw 'Nothing to set. Supply at least one of -UILanguage, -SystemLocale, -UserLocale, -InputLocale, -TimeZone.' }

    # A UI language the image does not have is refused BEFORE anything is applied.
    #
    # DISM's own words: "If the language is not installed in the Windows image,
    # the command will fail." It is not a warning and there is no partial
    # success. What made that worth catching here is the ORDER -- the settings
    # are applied one at a time, so a run asking for a Dutch UI and Dutch formats
    # used to set the formats, fail on the language, and leave the image in a
    # state nobody asked for.
    #
    # Only refused when the image positively says otherwise. An image whose
    # language list cannot be read is left alone: refusing on absent evidence
    # would block work that would have succeeded, which is the same rule the
    # update generation guard follows.
    if ($UILanguage) {
        $installed = @()
        try {
            $before   = Get-WfImageLocale -MountPath $MountPath
            $installed = @(@($before.InstalledLanguages) + @($before.UILanguage) |
                           Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)
        }
        catch { }

        if ($installed.Count -gt 0 -and ($installed -notcontains "$UILanguage".ToLowerInvariant())) {
            throw (("This image does not have the {0} display language, so the UI cannot be set to it -- " +
                    "DISM would fail and the other settings would already have been applied. It has: {1}. " +
                    "Add-WfLanguage puts a language pack in from the language library, and " +
                    "Get-WfLanguageLibrary lists what is available.") -f `
                    $UILanguage, ($installed -join ', '))
        }
    }

    if (-not $PSCmdlet.ShouldProcess($MountPath, ("Set {0} regional setting(s)" -f $steps.Count))) { return }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($s in $steps) {
        Write-WfLog ("Setting the {0}" -f $s.What) -Level STEP
        try {
            Invoke-WfDism @("/Image:$MountPath", $s.Arg) | Out-Null
            $results.Add([pscustomobject]@{ Setting = $s.What; Result = 'Set' })
            Write-WfLog '  set' -Level OK
        }
        catch {
            $msg = $_.Exception.Message.Trim()
            $results.Add([pscustomobject]@{ Setting = $s.What; Result = "Failed: $msg" })

            # By far the most common failure, and the message DISM gives for it
            # is not obvious.
            if ($s.Arg -like '/Set-UILang:*') {
                Write-WfLog "  failed: $msg" -Level ERROR
                Write-WfLog '  A UI language can only be set to one already in the image. Add the language pack first, or leave the UI language alone.' -Level WARN
            }
            else {
                Write-WfLog "  failed: $msg" -Level ERROR
            }
        }
    }

    # Read it back rather than trusting the exit codes: some DISM versions accept
    # a setting they then do not apply.
    Write-WfLog 'Reading the settings back' -Level STEP
    $now = Get-WfImageLocale -MountPath $MountPath

    Write-WfHistory -Action 'Regional settings' -ImagePath $MountPath -Detail @{
        UILanguage = $UILanguage; SystemLocale = $SystemLocale; UserLocale = $UserLocale
        InputLocale = $InputLocale; TimeZone = $TimeZone
        Failed = @($results | Where-Object { $_.Result -ne 'Set' }).Count
    } | Out-Null

    return [pscustomobject]@{
        Applied = $results.ToArray()
        Now     = $now
    }
}

function Set-WfOemInformation {
<#
.SYNOPSIS
    Writes the manufacturer, model and support details shown in System properties.
.DESCRIPTION
    Small, and worth more than it looks on an estate somebody else supports. A
    terminal that says who built it and which number to ring saves a call being
    routed three times before it reaches you.

    The logo must be a 120x120 bitmap already inside the image -- give the path
    as the TERMINAL will see it, and put the file there with the payload copy.
.EXAMPLE
    Set-WfOemInformation -Manufacturer 'Centric' -Model 'POS Terminal 2026' -SupportPhone '+31 ...' -SupportUrl 'https://...'
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Manufacturer,
        [string] $Model,
        [string] $SupportPhone,
        [string] $SupportUrl,
        [string] $SupportHours,
        [string] $Logo,
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $values = @{}
    if ($Manufacturer) { $values['Manufacturer'] = $Manufacturer }
    if ($Model)        { $values['Model']        = $Model }
    if ($SupportPhone) { $values['SupportPhone'] = $SupportPhone }
    if ($SupportUrl)   { $values['SupportURL']   = $SupportUrl }
    if ($SupportHours) { $values['SupportHours'] = $SupportHours }
    if ($Logo)         { $values['Logo']         = $Logo }

    if ($values.Count -eq 0) { throw 'Nothing to write. Supply at least one value.' }

    if ($Logo -and $Logo -match '^([A-Za-z]):\\(.+)$') {
        $inImage = Join-WfPath $MountPath $Matches[2]
        if (-not (Test-Path -LiteralPath $inImage)) {
            Write-WfLog "$Logo is not in the image yet. Copy it in with the payload, or System properties shows a blank space." -Level WARN
        }
    }

    if (-not $PSCmdlet.ShouldProcess($MountPath, 'Write OEM support information')) { return }

    Write-WfLog ("Writing {0} OEM value(s)" -f $values.Count) -Level STEP

    Invoke-WfRegistryEdit -MountPath $MountPath -Action {
        param($keys)
        $path = Join-WfPath $keys.Software 'Microsoft\Windows\CurrentVersion\OEMInformation'
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        foreach ($name in $values.Keys) {
            New-ItemProperty -LiteralPath $path -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null
        }
    }

    Write-WfLog 'Written' -Level OK
    Write-WfHistory -Action 'OEM information' -ImagePath $MountPath -Detail $values | Out-Null
    return [pscustomobject]$values
}

function Set-WfLocalPolicy {
<#
.SYNOPSIS
    Bakes a local Group Policy into the image.
.DESCRIPTION
    Copies a prepared Registry.pol into \Windows\System32\GroupPolicy\, which is
    where local policy lives. Group Policy processes it at boot, so the settings
    apply on a machine that has never seen a domain -- which is the case for a
    terminal at a third-party site.

    Produce the .pol on a reference machine: set what you want in gpedit.msc, then
    take \Windows\System32\GroupPolicy\Machine\Registry.pol from it. Microsoft's
    LGPO.exe can build one too.

    Not merged -- replaced. A .pol is a single binary blob, and pretending to
    merge two of them by copying one over the other would silently discard the
    settings in the one underneath. If you need both, merge them where you can
    see what you are doing, with gpedit or LGPO.
.PARAMETER MachinePolicy
    Registry.pol for computer configuration.
.PARAMETER UserPolicy
    Registry.pol for user configuration.
.EXAMPLE
    Set-WfLocalPolicy -MachinePolicy D:\Imaging\Payload\pos-machine.pol
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $MachinePolicy,
        [string] $UserPolicy,
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }
    if (-not $MachinePolicy -and -not $UserPolicy) { throw 'Supply -MachinePolicy, -UserPolicy, or both.' }

    $done = @()

    foreach ($p in @(
        @{ Source = $MachinePolicy; Leaf = 'Machine'; Label = 'computer' }
        @{ Source = $UserPolicy;    Leaf = 'User';    Label = 'user' }
    )) {
        if (-not $p.Source) { continue }

        $resolved = Assert-WfPath -Path $p.Source -Label "$($p.Label) policy"

        # A .pol starts with 'PReg' and a version dword. Copying a .reg file or a
        # text export here would produce a policy Windows silently ignores.
        $magic  = New-Object byte[] 4
        $stream = [System.IO.File]::OpenRead($resolved)
        try   { [void]$stream.Read($magic, 0, 4) }
        finally { $stream.Dispose() }
        $sig = -join ($magic | ForEach-Object { [char]$_ })

        if ($sig -ne 'PReg') {
            throw ("{0} is not a Registry.pol file -- it starts with '{1}', not 'PReg'. Windows would ignore it without a word." -f $resolved, $sig)
        }

        $target = Join-WfPath (Join-WfPath $MountPath 'Windows\System32\GroupPolicy') $p.Leaf
        if (-not $PSCmdlet.ShouldProcess($target, "Replace the $($p.Label) policy")) { continue }

        New-WfDirectory $target | Out-Null
        $dest = Join-WfPath $target 'Registry.pol'

        if (Test-Path -LiteralPath $dest) {
            Write-WfLog "Replacing the $($p.Label) policy already in the image -- its settings are not merged, they are gone." -Level WARN
        }

        Copy-Item -LiteralPath $resolved -Destination $dest -Force
        Write-WfLog ("{0} policy written ({1})" -f $p.Label, (Format-WfSize (Get-Item -LiteralPath $dest).Length)) -Level OK
        $done += $p.Label
    }

    # Without this, Group Policy sees an unchanged version stamp and may not
    # process the new .pol until something else bumps it.
    if ($done.Count -gt 0) {
        Invoke-WfRegistryEdit -MountPath $MountPath -Action {
            param($keys)
            $path = Join-WfPath $keys.Software 'Microsoft\Windows\CurrentVersion\Group Policy\State\Machine'
            if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        }
    }

    Write-WfHistory -Action 'Local policy' -ImagePath $MountPath -Detail @{
        Machine = $MachinePolicy; User = $UserPolicy; Applied = ($done -join ', ')
    } | Out-Null

    return [pscustomobject]@{ Applied = $done; MountPath = $MountPath }
}
