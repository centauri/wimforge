# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
.SYNOPSIS
    Console menu for the WimForge.

.DESCRIPTION
    A numbered menu over the WimForge module. Every option is a thin
    wrapper around a module function, so anything you can do here you can also do
    from a script or a scheduled task -- the menu is a convenience, never the only
    way in.

    Run from an elevated ADK "Deployment and Imaging Tools Environment" prompt.

.EXAMPLE
    .\Start-WimForgeMenu.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,

    # Relaunch elevated immediately without asking. Handy for a shortcut.
    [switch] $Elevate
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- module load
$modulePath = Join-Path $PSScriptRoot 'WimForge\WimForge.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "WimForge not found next to this script (looked for $modulePath)."
}
Import-Module $modulePath -Force -ErrorAction Stop

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host ''
    Write-Host 'WARNING: this is PowerShell Core. Image servicing is only reliable under' -ForegroundColor Yellow
    Write-Host '         Windows PowerShell 5.1, where the DISM module runs natively.' -ForegroundColor Yellow
    Write-Host ''
}

$script:Config = Get-WfConfig -Path $ConfigPath

# What was last read off an image, for the Updates menu. Held for the session
# only: it describes one image at one moment, and writing it to the config would
# quietly outlive the image it came from.
$script:UpdateTarget = $null

# The image everything works on, chosen once. Every operation that used to ask
# "which image?" now uses this, so a session is: pick the image, then do things
# to it. Change it from the main menu.
$script:WorkingImage = $script:Config['BaseImage']
$script:WorkingIndex = 1

# ------------------------------------------------------------------ elevation
# A process cannot elevate itself -- Windows only grants administrator rights at
# process creation. So this relaunches and lets the current session exit.

function Get-WfRelaunchArguments {
    $a = @()
    if ($ConfigPath) { $a += @('-ConfigPath', "`"$ConfigPath`"") }
    # `return $a` on an empty array unrolls to $null, which would put a stray
    # empty argument on the relaunch command line. The comma keeps it an array.
    return ,$a
}

function Invoke-WfRelaunchElevated {
    <# Returns $true when an elevated process started and this one should exit. #>
    if (Start-WfElevated -ScriptPath $PSCommandPath -Arguments (Get-WfRelaunchArguments)) {
        Write-Host ''
        Write-Host '   An elevated window has opened. Closing this one.' -ForegroundColor Green
        Write-Host ''
        Start-Sleep -Seconds 2
        return $true
    }
    Write-Host ''
    Write-Host '   Elevation was cancelled -- continuing without administrator rights.' -ForegroundColor Yellow
    Write-Host '   Read-only actions still work; anything that mounts an image will not.' -ForegroundColor Yellow
    Write-Host ''
    Start-Sleep -Seconds 3
    return $false
}

if (-not (Test-WfElevated)) {
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host '   Not running as administrator.' -ForegroundColor Yellow
    Write-Host '   DISM cannot mount an image without it, so most of this tool' -ForegroundColor Yellow
    Write-Host '   will fail. Reports and the driver library still work.' -ForegroundColor Yellow
    Write-Host '  ------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host ''

    $doElevate = $Elevate
    if (-not $Elevate) {
        $answer = Read-Host '   Restart elevated now? [Y/n]'
        $doElevate = ($answer -eq '' -or $answer -match '^[Yy]')
    }
    if ($doElevate -and (Invoke-WfRelaunchElevated)) { return }
}

# ------------------------------------------------------------------- helpers

function Show-Header {
    <#
        The full wordmark on the main menu, a single line everywhere else --
        otherwise five lines of banner push the actual content off a short console.
    #>
    param([string] $Title, [switch] $Full)

    Clear-Host
    $cfg = $script:Config

    if ($Full) {
        Show-WfBanner
    }
    else {
        Show-WfBanner -Compact
        Write-Host ''
    }

    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host "   $Title" -ForegroundColor White
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkCyan

    # The working image first: it is what almost every action below acts on, so
    # it should never be a surprise which one that is.
    if ($script:WorkingImage) {
        Write-Host '   Working on : ' -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0}  index {1}" -f (Split-Path $script:WorkingImage -Leaf), $script:WorkingIndex) `
                   -NoNewline -ForegroundColor Cyan

        # Whether it is OPEN goes on the END of this line, not on one of its own.
        # It is a property of the image named to the left of it, it changes what
        # every action costs, and it is needed on every screen -- so it earns a
        # place in the header and does not earn a row.
        $state = Get-WfMountBadge
        Write-Host ('   ' + $state.Text) -ForegroundColor $state.Colour

        if ($script:WorkingSummary) {
            Write-Host ("                {0}" -f $script:WorkingSummary) -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host '   Working on : nothing selected yet' -ForegroundColor Yellow
    }

    Write-Host ("   Drivers    : {0}" -f $cfg['DriverRoot'])  -ForegroundColor DarkGray
    Write-Host ("   Mount path : {0}" -f $cfg['MountPath'])   -ForegroundColor DarkGray
    Write-Host ''
}

function Set-WfWorkingImage {
    <#
        Chooses the image everything else acts on, and reads what it is straight
        away -- that costs seconds now, and knowing the release and build before
        doing anything to an image is worth more than the seconds.
    #>
    param([string] $Prompt = 'Which image do you want to work on?')

    $picked = Select-WfImage -Prompt $Prompt -Default $script:WorkingImage
    if (-not $picked) { return $false }

    $idx = Select-WfIndex -ImagePath $picked
    if ($null -eq $idx) { return $false }

    $script:WorkingImage   = $picked
    $script:WorkingIndex   = $idx
    $script:WorkingSummary = ''

    # A fresh image means whatever was read off the last one no longer applies.
    $script:UpdateTarget = $null

    Write-Host ''
    Write-Host '   Reading it...' -ForegroundColor Cyan
    try {
        $t = Get-WfImageUpdateTarget -ImagePath $picked -Index $idx -IncludePackage:$false -NoMount:$false
        $script:UpdateTarget   = $t
        $script:WorkingSummary = ('{0} {1}' -f $t.Product, $t.Architecture)
        if ($t.FullBuild) { $script:WorkingSummary = "$($script:WorkingSummary), build $($t.FullBuild)" }
        Show-WfTargetSummary $t
    }
    catch {
        Write-Host "   Could not read it: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '   The image is still selected; only the identity read failed.' -ForegroundColor DarkGray
        Write-Host ''
    }

    Read-Host '   Press Enter to continue' | Out-Null
    return $true
}

function Confirm-WfWorkingImage {
    <#
        Every action that used to ask "which image?" calls this instead. If one
        is already chosen it says so and gets on with it; the point of choosing
        once is not being asked eleven more times. Change it from the main menu.
    #>
    if ($script:WorkingImage -and (Test-Path -LiteralPath $script:WorkingImage)) {
        Write-Host ''
        Write-Host '   Working image: ' -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0}  index {1}" -f (Split-Path $script:WorkingImage -Leaf), $script:WorkingIndex) -ForegroundColor Cyan
        if ($script:WorkingSummary) {
            Write-Host ("                  {0}" -f $script:WorkingSummary) -ForegroundColor DarkGray
        }
        Write-Host '   (main menu -> Choose the image to work on, to change it)' -ForegroundColor DarkGray
        Write-Host ''
        return $true
    }

    if ($script:WorkingImage) {
        Write-Host ''
        Write-Host ("   The working image is not there: {0}" -f $script:WorkingImage) -ForegroundColor Yellow
    }
    else {
        Write-Host ''
        Write-Host '   No image chosen yet.' -ForegroundColor Yellow
    }
    return (Set-WfWorkingImage)
}

function Update-WfMountNote {
    <#
        Refreshes the one-line mount state shown in the header. Cheap, and only
        meaningful when elevated -- unelevated the mount table cannot be read at
        all, which is why nothing is claimed in that case.
    #>
    $script:MountNote = ''
    if (-not (Test-WfElevated)) { return }

    try {
        $m = Get-WfCurrentMount
        if ($m) {
            $mode = 'read/write'
            if ($m.ReadOnly) { $mode = 'read-only' }
            $script:MountNote = ('{0} index {1} ({2}) -- operations will reuse this mount' -f `
                (Split-Path $m.ImagePath -Leaf), $m.Index, $mode)
        }
    }
    catch { }
}

function Read-MenuChoice {
    param(
        [Parameter(Mandatory)] [string]   $Prompt,
        [Parameter(Mandatory)] [object[]] $Items,
        [string] $BackLabel = 'Back'
    )

    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('   {0,2}. {1}' -f ($i + 1), $Items[$i].Label)
        if ($Items[$i].Hint) {
            Write-Host ('       {0}' -f $Items[$i].Hint) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host ('    0. {0}' -f $BackLabel) -ForegroundColor DarkGray
    Write-Host ''

    $raw = Read-Host $Prompt
    if ($raw -eq '0' -or $raw -eq '') { return $null }

    $n = 0
    if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
        return $Items[$n - 1]
    }

    Write-Host '   Not a valid choice.' -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    return (Read-MenuChoice -Prompt $Prompt -Items $Items -BackLabel $BackLabel)
}

function Read-WfValue {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [string] $Default
    )
    if ($Default) {
        $answer = Read-Host ("   {0} [{1}]" -f $Prompt, $Default)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer
    }
    return (Read-Host "   $Prompt")
}

function Read-WfInt {
    <#
        $ErrorActionPreference is Stop for this script, so a bare [int] cast on a
        typo throws a terminating error that unwinds every menu loop and drops the
        operator out of the tool entirely. Never cast operator input directly.
    #>
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [int] $Default = 1
    )
    while ($true) {
        $raw = Read-WfValue $Prompt "$Default"
        $n = 0
        if ([int]::TryParse($raw, [ref]$n)) { return $n }
        Write-Host '   Enter a number.' -ForegroundColor Yellow
    }
}

function Read-WfPick {
    <#
        Search-then-number, for the settings that have a real list behind them.

        A drop-down is not an option in a console, and a numbered list is not an
        option either when the list is eight hundred locales long. So: type part
        of what you want, get the matches numbered, pick one. Paste a value you
        already know and it is taken as-is, because an operator who knows the
        answer should not have to search for it.

        Items are objects with Label (what is shown) and Value (what is returned).
    #>
    param(
        [Parameter(Mandatory)] [string]   $Prompt,
        [Parameter(Mandatory)] [object[]] $Items,
        [string] $Default,
        [string] $BlankMeans = 'leave it alone',
        [int]    $PageSize = 24,

        # For the ones that hold a path. A list of what was found is the fast
        # answer; a file browser is the one that always works.
        [switch] $Browse,
        [string] $BrowseFilter = 'All files (*.*)|*.*'
    )

    $items = @($Items | Where-Object { $_ })
    if ($items.Count -eq 0) {
        if ($Browse) {
            Write-Host ''
            Write-Host "   Nothing found for $Prompt." -ForegroundColor Yellow
            Write-Host '   B to browse for it, or type the path.' -ForegroundColor DarkGray
            $raw = (Read-WfValue $Prompt $Default).Trim()
            if ($raw -match '^[Bb]$') {
                $start = ''
                if ($Default) { $start = Split-Path $Default -Parent }
                $picked = Show-WfFileDialog -Title $Prompt -Filter $BrowseFilter -InitialDirectory $start
                if ($picked) { return $picked }
                return $Default
            }
            return $raw
        }
        Write-Host "   No options available for $Prompt -- falling back to typing it." -ForegroundColor Yellow
        return (Read-WfValue $Prompt $Default)
    }

    $hint = $BlankMeans
    if ($Default) { $hint = "keep $Default" }

    while ($true) {
        Write-Host ''
        Write-Host ("   {0}" -f $Prompt) -ForegroundColor White
        if ($Browse) {
            Write-Host ("   Type part of it to search, B to browse, Enter to {0}, or ? for all." -f $hint) -ForegroundColor DarkGray
        }
        else {
            Write-Host ("   Type part of it to search, Enter to {0}, or ? to see them all." -f $hint) -ForegroundColor DarkGray
        }
        $raw = (Read-Host '   Search').Trim()

        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }

        if ($Browse -and $raw -match '^[Bb]$') {
            $start = ''
            if ($Default) { $start = Split-Path $Default -Parent }
            $picked = Show-WfFileDialog -Title $Prompt -Filter $BrowseFilter -InitialDirectory $start
            if ($picked) { return $picked }
            continue
        }

        # An exact value is an answer, not a search term.
        $exact = @($items | Where-Object { $_.Value -eq $raw })
        if ($exact.Count -eq 1) { return $exact[0].Value }

        $hits = $items
        if ($raw -ne '?') {
            $hits = @($items | Where-Object { $_.Label -like "*$raw*" -or $_.Value -like "*$raw*" })
        }
        $hits = @($hits)

        if ($hits.Count -eq 0) {
            Write-Host "   Nothing matches '$raw'." -ForegroundColor Yellow
            continue
        }

        $shown = @($hits | Select-Object -First $PageSize)
        for ($i = 0; $i -lt $shown.Count; $i++) {
            Write-Host ('   {0,3}. {1}' -f ($i + 1), $shown[$i].Label)
        }
        if ($hits.Count -gt $shown.Count) {
            Write-Host ('        ... {0} more. Narrow the search to see them.' -f ($hits.Count - $shown.Count)) -ForegroundColor DarkGray
        }
        Write-Host ('     0. search again') -ForegroundColor DarkGray

        $answer = (Read-Host '   Number').Trim()
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $shown.Count) {
            $picked = $shown[$n - 1]
            Write-Host ('   -> {0}' -f $picked.Value) -ForegroundColor DarkGray
            return $picked.Value
        }
        if ($answer -eq '0' -or $answer -eq '') { continue }
        Write-Host '   Not a valid choice.' -ForegroundColor Yellow
    }
}

function Read-WfPickMany {
    <#
        The same idea as Read-WfPick where more than one answer is right -- which
        keys to block, mostly. Short enough lists that they all fit on a screen,
        so there is no searching: numbers, comma separated, or 'all'.

        Items are objects with Label, Value and optionally Hint. Returns an array
        of values, possibly empty.
    #>
    param(
        [Parameter(Mandatory)] [string]   $Prompt,
        [Parameter(Mandatory)] [object[]] $Items,
        [string[]] $Default = @()
    )

    $items = @($Items | Where-Object { $_ })
    if ($items.Count -eq 0) { return @() }

    Write-Host ''
    for ($i = 0; $i -lt $items.Count; $i++) {
        $mark = ' '
        if ($Default -contains $items[$i].Value) { $mark = '*' }
        Write-Host ('   {0}{1,3}. {2}' -f $mark, ($i + 1), $items[$i].Label)
        if ($items[$i].Hint) { Write-Host ('        {0}' -f $items[$i].Hint) -ForegroundColor DarkGray }
    }
    Write-Host ''
    if ($Default.Count -gt 0) {
        Write-Host ('   * = the suggested set. Enter takes it: {0}' -f ($Default -join ', ')) -ForegroundColor DarkGray
    }
    Write-Host "   Numbers comma separated, 'all' for everything, 'none' for nothing." -ForegroundColor DarkGray

    $raw = (Read-Host ('   {0}' -f $Prompt)).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return @($Default) }
    if ($raw -eq 'none') { return @() }
    if ($raw -eq 'all')  { return @($items | ForEach-Object { $_.Value }) }

    $picked = New-Object System.Collections.Generic.List[object]
    foreach ($part in ($raw -split ',')) {
        $part = $part.Trim()
        if (-not $part) { continue }
        $n = 0
        if ([int]::TryParse($part, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) {
            if (-not $picked.Contains($items[$n - 1].Value)) { $picked.Add($items[$n - 1].Value) }
        }
        else {
            # A name typed straight in is still an answer, as long as it is one
            # of the real ones -- a typo here silently does nothing at first boot.
            $match = @($items | Where-Object { $_.Value -eq $part })
            if ($match.Count -eq 1) {
                if (-not $picked.Contains($match[0].Value)) { $picked.Add($match[0].Value) }
            }
            else {
                Write-Host ("   Ignoring '{0}' -- not one of the choices." -f $part) -ForegroundColor Yellow
            }
        }
    }
    return $picked.ToArray()
}

function Confirm-WfMountNeeded {
    <#
        Asked before anything spends minutes opening an image.

        Three answers, because there are genuinely three things somebody wants:
        keep it open (they are about to do several things), open just for this
        (one look, then leave the disk tidy), or stop. The first was previously
        not offered at all -- every read opened and closed its own mount, so five
        reads cost five mounts.

        When the image is ALREADY open this does not ask: it is already paid for,
        and closing it would be the expensive mistake.

        Returns 'keep', 'once' or 'no'.
    #>
    param([string] $What = 'This')

    $open = $null
    try { $open = Get-WfCurrentMount } catch { }
    if ($open) {
        Write-Host ''
        Write-Host ("   Using the image already open ({0} index {1}). It stays open." -f `
            (Split-Path $open.ImagePath -Leaf), $open.Index) -ForegroundColor Green
        return 'keep'
    }

    Write-Host ''
    Write-Host "   $What needs the image opened, which takes a few minutes." -ForegroundColor Yellow
    Write-Host ''
    Write-Host '     K  open it and LEAVE IT OPEN -- everything after this is instant' -ForegroundColor DarkGray
    Write-Host '     O  open it just for this one read, then close it again' -ForegroundColor DarkGray
    Write-Host '     C  cancel' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   If you have more than one thing to do with this image, K saves the time.' -ForegroundColor DarkGray

    $answer = (Read-WfValue 'Open it?' 'K').Trim()
    switch -Regex ($answer) {
        '^[Kk]' { return 'keep' }
        '^[Oo]' { return 'once' }
        default { return 'no' }
    }
}

function Get-WfMountBadge {
    <#
        Mount state as a short coloured badge, for the end of a line that already
        exists. Terse on purpose: a header is glanced at, and anything long
        enough to read properly is long enough to wrap and cost the row it was
        meant to save.
    #>
    if (-not (Test-WfElevated)) {
        return [pscustomobject]@{ Text = '[NOT ELEVATED]'; Colour = 'Red' }
    }

    $m = $null
    try { $m = Get-WfCurrentMount } catch { }

    if (-not $m) {
        return [pscustomobject]@{ Text = '[CLOSED]'; Colour = 'DarkGray' }
    }

    $mode = 'rw'
    if ($m.ReadOnly) { $mode = 'ro' }

    # An image open that is NOT the one being worked on is the state worth
    # shouting about: every action will refuse until it is closed.
    if ($script:WorkingImage -and
        ("$($m.ImagePath)".TrimEnd('\') -ne "$($script:WorkingImage)".TrimEnd('\'))) {
        return [pscustomobject]@{
            Text   = ("[WRONG IMAGE OPEN: {0}]" -f (Split-Path $m.ImagePath -Leaf))
            Colour = 'Red'
        }
    }

    return [pscustomobject]@{ Text = ("[OPEN {0}]" -f $mode); Colour = 'Green' }
}

function Read-WfSizePick {
    <#
        A number chosen from the sizes that suit a reference build, or typed if
        none of them do.

        Separate from Read-WfPick because the answer is an int and because the
        options carry a "would not fit on this host" mark that has to survive
        into what is shown.
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('Memory', 'Disk', 'Cpu')] [string] $Kind,
        [Parameter(Mandatory)] [string] $Prompt,
        [object] $HostFact,
        [int]    $Default
    )

    $sizes = @(Get-WfVmSizeChoice -Kind $Kind -HostFact $HostFact)
    if ($sizes.Count -eq 0) { return (Read-WfInt $Prompt $Default) }

    if (-not $Default) {
        $d = @($sizes | Where-Object { $_.Default }) | Select-Object -First 1
        if ($d) { $Default = $d.Value }
    }

    Write-Host ''
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s    = $sizes[$i]
        $mark = ' '
        if ($s.Value -eq $Default) { $mark = '*' }
        $colour = 'DarkGray'
        if (-not $s.Fits) { $colour = 'Yellow' }
        Write-Host ('   {0}{1,2}. {2,-6}' -f $mark, ($i + 1), $s.Label) -NoNewline
        Write-Host ("  {0}" -f $s.Note) -ForegroundColor $colour
    }
    Write-Host ''

    while ($true) {
        $raw = (Read-WfValue "$Prompt (a number from the list, or your own)" "$Default").Trim()
        $n = 0
        if ([int]::TryParse($raw, [ref]$n)) {
            # A single digit that is also a list position is ambiguous, and the
            # list is what was just shown -- so the list wins, except where the
            # number is itself one of the offered values.
            if ($n -ge 1 -and $n -le $sizes.Count -and -not ($sizes | Where-Object { $_.Value -eq $n })) {
                return $sizes[$n - 1].Value
            }
            if ($n -gt 0) { return $n }
        }
        Write-Host '   Enter a number.' -ForegroundColor Yellow
    }
}

function ConvertTo-WfPickItem {
    <#
        Turns whatever a Get-Wf*Choice function returns into the Label/Value pairs
        Read-WfPick shows. The label leads with the value so that prefix typing --
        'nl-', 'W. Europe' -- lands where the operator expects.
    #>
    param(
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [string] $ValueProperty,
        [Parameter(Mandatory)] [string[]] $LabelProperty
    )

    $pairs = foreach ($row in @($Source | Where-Object { $_ })) {
        $extra = @($LabelProperty | ForEach-Object { $row.$_ } | Where-Object { $_ })
        [pscustomobject]@{
            Value = $row.$ValueProperty
            Label = ('{0,-34} {1}' -f $row.$ValueProperty, ($extra -join '  --  ')).TrimEnd()
        }
    }
    return @($pairs)
}

function Show-WfFolderDialog {
    <# Folder browser for the settings editor, with a typed fallback. #>
    param(
        [string] $Description = 'Select a folder',
        [string] $StartPath
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg             = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $Description
        $dlg.ShowNewFolderButton = $true
        if ($StartPath -and (Test-Path -LiteralPath $StartPath)) { $dlg.SelectedPath = $StartPath }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        return $null
    }
    catch {
        Write-Host '   Folder browser unavailable -- type the path instead.' -ForegroundColor Yellow
        $typed = Read-Host '   Path'
        if ([string]::IsNullOrWhiteSpace($typed)) { return $null }
        return $typed.Trim('"')
    }
}

function Show-WfSetupWizard {
<#
    First-run setup. Everything the toolkit needs, chosen once, without anyone
    opening a JSON file.
#>
    param([switch] $Force)

    $state = Test-WfSetupRequired
    if (-not $state.Required -and -not $Force) { return $false }

    Clear-Host
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '   WimForge -- setup' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ''

    if ($state.Reasons.Count -gt 0) {
        Write-Host '   Why you are seeing this:' -ForegroundColor Yellow
        foreach ($r in $state.Reasons) { Write-Host "     - $r" -ForegroundColor Yellow }
        Write-Host ''
    }

    # --- the workspace root, from which almost everything else follows --------
    Write-Host '   Everything the toolkit reads and writes lives under one workspace' -ForegroundColor DarkGray
    Write-Host '   folder: images, drivers, updates, payload, logs and the build history.' -ForegroundColor DarkGray
    Write-Host '   Put it on a drive with room -- images run to several GB each.' -ForegroundColor DarkGray
    Write-Host ''

    $drives = @()
    try {
        $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
                    Sort-Object FreeSpace -Descending)
    } catch { }

    if ($drives.Count -gt 0) {
        Write-Host '   Local fixed drives:' -ForegroundColor Cyan
        foreach ($d in $drives) {
            Write-Host ('     {0}  {1,7:N1} GB free of {2,7:N1} GB   {3}' -f `
                $d.DeviceID, ($d.FreeSpace / 1GB), ($d.Size / 1GB), $d.VolumeName)
        }
        Write-Host ''
    }

    $suggested = Get-WfSuggestedRoot

    # The candidates, including "next to the toolkit" -- which is the obvious
    # instinct and is right or wrong depending entirely on where the toolkit
    # happens to be sitting. Better to offer it with the reason attached than to
    # leave the operator to guess.
    $options = @(Get-WfWorkspaceOption)
    if ($options.Count -gt 0) {
        Write-Host '   Where it could go:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $options.Count; $i++) {
            $o    = $options[$i]
            $mark = ' '
            if ($o.Recommended) { $mark = '*' }
            Write-Host ('   {0}{1,2}. {2}' -f $mark, ($i + 1), $o.Path)

            $tail = $o.Why
            if ($o.FreeGb -gt 0) { $tail = ('{0}, {1:N1} GB free' -f $tail, $o.FreeGb) }
            $colour = 'DarkGray'
            if ($o.Note -like 'not advised*') { $colour = 'Yellow' }
            if ($o.Note) { $tail = "$tail -- $($o.Note)" }
            Write-Host ('        {0}' -f $tail) -ForegroundColor $colour
        }
        Write-Host ''
    }

    Write-Host '   A number, a path of your own, or B to browse.' -ForegroundColor DarkGray
    $root = Read-WfValue 'Workspace folder' $suggested

    $n = 0
    if ([int]::TryParse($root, [ref]$n) -and $n -ge 1 -and $n -le $options.Count) {
        $root = $options[$n - 1].Path
    }
    elseif ($root -match '^[Bb]$') {
        $picked = Show-WfFolderDialog -Description 'Choose the imaging workspace folder' -StartPath $suggested
        if ($picked) { $root = $picked } else { $root = $suggested }
    }

    Write-Host ''
    Write-Host "   Using $root" -ForegroundColor Green
    Set-WfWorkspaceRoot -Path $root -Confirm:$false | Out-Null

    # --- the bits that are not derived from the root -------------------------
    Write-Host ''
    Write-Host '   Two more things the workspace cannot guess.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   The mount folder does NOT follow the workspace, on purpose. A mounted' -ForegroundColor DarkGray
    Write-Host '   image is a live NTFS projection of a whole Windows installation held' -ForegroundColor DarkGray
    Write-Host '   open by a filter driver -- not a folder of files. So it wants a short' -ForegroundColor DarkGray
    Write-Host '   path on a local disk, away from anything that scans, syncs or version-' -ForegroundColor DarkGray
    Write-Host '   controls the workspace. The default is fine unless that drive is tight.' -ForegroundColor DarkGray
    Write-Host ''
    $cfg   = Get-WfConfig
    $mount = Read-WfValue 'Mount folder' $cfg['MountPath']

    # Judged before it is saved rather than at the first failed mount.
    $verdict = $null
    try { $verdict = Test-WfMountPath -Path $mount -WorkspaceRoot $root } catch { }
    if ($verdict -and $verdict.Verdict -ne 'OK') {
        Write-Host ''
        foreach ($f in $verdict.Findings) {
            if ($f.Status -eq 'OK') { continue }
            $colour = 'Yellow'
            if ($f.Status -eq 'FAIL') { $colour = 'Red' }
            Write-Host ("   {0}: {1}" -f $f.Check, $f.Detail) -ForegroundColor $colour
        }
        Write-Host ''
        if ($verdict.Verdict -eq 'FAIL') {
            Write-Host '   That will not work. Enter somewhere else, or Enter to keep it anyway.' -ForegroundColor Red
            $again = Read-WfValue 'Mount folder' $mount
            if ($again) { $mount = $again }
        }
    }

    Write-Host ''
    Write-Host '   WDS shares, if you publish from this workstation. Leave blank to skip;' -ForegroundColor DarkGray
    Write-Host '   publishing will just tell you it is not configured.' -ForegroundColor DarkGray
    $wds     = Read-WfValue 'WDS install image share' $cfg['WdsShare']
    $wdsBoot = Read-WfValue 'WDS boot image share'    $cfg['WdsBootShare']

    Write-Host ''
    $prefix = Read-WfValue 'Image name prefix' $cfg['ImageNamePrefix']

    Set-WfConfig -Settings @{
        MountPath       = $mount
        ScratchPath     = (Join-Path (Split-Path $mount -Qualifier) 'WimScratch')
        WdsShare        = $wds
        WdsBootShare    = $wdsBoot
        ImageNamePrefix = $prefix
        SetupComplete   = $true
    } -Confirm:$false | Out-Null

    # --- create the folders --------------------------------------------------
    Write-Host ''
    Write-Host '   Creating the folder structure...' -ForegroundColor Cyan
    $created = Initialize-WfWorkspace -IncludeMountPath
    $created | Format-Table Setting, Path, Status, Detail -AutoSize | Out-Host

    $script:Config = Get-WfConfig -Refresh

    Write-Host ''
    Write-Host "   Setup complete. Configuration saved to $(Get-WfConfigPath)" -ForegroundColor Green
    Write-Host '   Change any of it later from Housekeeping > Settings.' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '   Press Enter to continue' | Out-Null
    return $true
}

function Show-WfSettingsEditor {
<#
    Every setting, editable in place, with a browser for anything path-shaped.
    This is what replaces hand-editing the JSON.
#>
    $pathLike   = 'WorkspaceRoot','ImageRoot','DriverRoot','UpdateRoot','PayloadRoot','LogRoot','MountPath','ScratchPath','WdsShare','WdsBootShare'
    $fileLike   = 'BaseImage','PeImage','UnattendPath','HistoryFile'

    :settings while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor DarkCyan
        Write-Host '   Settings' -ForegroundColor Cyan
        Write-Host "   $(Get-WfConfigPath)" -ForegroundColor DarkGray
        Write-Host '  ============================================================' -ForegroundColor DarkCyan
        Write-Host ''

        $keys = @($script:Config.Keys | Sort-Object)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $key   = $keys[$i]
            $value = $script:Config[$key]
            if ($value -is [array]) { $value = $value -join ', ' }
            if ($null -eq $value -or "$value" -eq '') { $value = '(not set)' }

            # Flag anything pointing at a drive that is not here -- the exact
            # failure that sends people into the JSON in the first place.
            $colour = 'Gray'
            if ($key -in $pathLike -or $key -in $fileLike) {
                $q = $null
                try { $q = Split-Path -Qualifier "$value" -ErrorAction Stop } catch { }
                if ($q -and -not (Test-Path -LiteralPath "$q\")) { $colour = 'Red' }
                elseif ("$value" -ne '(not set)' -and -not (Test-Path -LiteralPath "$value")) { $colour = 'Yellow' }
                else { $colour = 'Green' }
            }
            Write-Host ('   {0,2}. {1,-24} ' -f ($i + 1), $key) -NoNewline
            Write-Host $value -ForegroundColor $colour
        }

        Write-Host ''
        Write-Host '   green = exists   yellow = missing folder   red = missing drive' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    R. Move the whole workspace to another folder' -ForegroundColor DarkGray
        Write-Host '    C. Create any missing folders' -ForegroundColor DarkGray
        Write-Host '    W. Re-run the setup wizard' -ForegroundColor DarkGray
        Write-Host '    0. Back' -ForegroundColor DarkGray
        Write-Host ''

        $raw = Read-Host '   Choose'
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq '0') { return }

        switch -Regex ($raw.Trim()) {
            '^[Rr]$' {
                $picked = Show-WfFolderDialog -Description 'New workspace folder' -StartPath $script:Config['WorkspaceRoot']
                if (-not $picked) { $picked = Read-WfValue 'New workspace folder' $script:Config['WorkspaceRoot'] }
                if ($picked) {
                    Set-WfWorkspaceRoot -Path $picked -CreateFolders -Confirm:$false | Out-Null
                    $script:Config = Get-WfConfig -Refresh
                    Write-Host '   Workspace repointed. Existing files are NOT moved.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                }
                continue settings
            }
            '^[Cc]$' {
                Initialize-WfWorkspace -IncludeMountPath |
                    Format-Table Setting, Path, Status, Detail -AutoSize | Out-Host
                Read-Host '   Press Enter to continue' | Out-Null
                continue settings
            }
            '^[Ww]$' {
                Show-WfSetupWizard -Force | Out-Null
                continue settings
            }
        }

        $n = 0
        if (-not ([int]::TryParse($raw, [ref]$n)) -or $n -lt 1 -or $n -gt $keys.Count) {
            Write-Host '   Not a valid choice.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue settings
        }

        $key     = $keys[$n - 1]
        $current = $script:Config[$key]
        Write-Host ''
        Write-Host "   $key" -ForegroundColor Cyan
        Write-Host "   currently: $current" -ForegroundColor DarkGray
        Write-Host ''

        $newValue = $null

        if ($key -in $pathLike) {
            Write-Host '   Enter a path, B to browse, or leave blank to keep it.' -ForegroundColor DarkGray
            $answer = Read-Host '   Value'
            if ($answer -match '^[Bb]$') {
                $newValue = Show-WfFolderDialog -Description $key -StartPath "$current"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($answer)) {
                $newValue = $answer.Trim('"')
            }
        }
        elseif ($key -in $fileLike) {
            Write-Host '   Enter a path, B to browse, or leave blank to keep it.' -ForegroundColor DarkGray
            $answer = Read-Host '   Value'
            if ($answer -match '^[Bb]$') {
                $filter = 'All files (*.*)|*.*'
                if ($key -in 'BaseImage','PeImage') { $filter = 'Windows images (*.wim)|*.wim|All files (*.*)|*.*' }
                elseif ($key -eq 'UnattendPath')    { $filter = 'Answer files (*.xml)|*.xml|All files (*.*)|*.*' }
                $start = $null
                try { $start = Split-Path "$current" -Parent } catch { }
                $newValue = Show-WfFileDialog -Title $key -Filter $filter -InitialDirectory $start
            }
            elseif (-not [string]::IsNullOrWhiteSpace($answer)) {
                $newValue = $answer.Trim('"')
            }
        }
        elseif ($key -eq 'BootDriverClasses') {
            Write-Host '   Comma-separated INF classes injected into the PE image.' -ForegroundColor DarkGray
            $answer = Read-Host '   Value'
            if (-not [string]::IsNullOrWhiteSpace($answer)) {
                $newValue = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
        elseif ($current -is [int] -or $key -in 'DefaultIndex','KeepPublishedVersions') {
            $answer = Read-Host '   Value (number)'
            if (-not [string]::IsNullOrWhiteSpace($answer)) {
                $parsed = 0
                if ([int]::TryParse($answer, [ref]$parsed)) { $newValue = $parsed }
                else { Write-Host '   Not a number -- unchanged.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
            }
        }
        elseif ($current -is [bool]) {
            $answer = Read-Host '   Value (true/false)'
            if (-not [string]::IsNullOrWhiteSpace($answer)) { $newValue = ($answer -match '^(1|t|true|y|yes)$') }
        }
        else {
            $answer = Read-Host '   Value'
            if (-not [string]::IsNullOrWhiteSpace($answer)) { $newValue = $answer }
        }

        if ($null -ne $newValue) {
            $script:Config = Set-WfConfig -Settings @{ $key = $newValue } -Confirm:$false
            Write-Host "   $key set." -ForegroundColor Green
            Start-Sleep -Milliseconds 700
        }
    }
}

function Show-WfFileDialog {
    <#
        A real file browser from the console. The 5.1 console host is STA, which
        WinForms needs; if something launched it -MTA the dialog throws, so this
        falls back to typing rather than taking the menu down.
    #>
    param(
        [string] $Title  = 'Select a Windows image',
        [string] $Filter = 'Windows images (*.wim)|*.wim|All files (*.*)|*.*',
        [string] $InitialDirectory
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg        = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = $Title
        $dlg.Filter = $Filter
        if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory)) {
            $dlg.InitialDirectory = $InitialDirectory
        }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
        return $null
    }
    catch {
        Write-Host "   File browser unavailable ($($_.Exception.Message.Split([Environment]::NewLine)[0]))." -ForegroundColor Yellow
        Write-Host '   Type the path instead.' -ForegroundColor Yellow
        $typed = Read-Host '   Path'
        if ([string]::IsNullOrWhiteSpace($typed)) { return $null }
        return $typed.Trim('"')
    }
}

function Select-WfImage {
<#
    Picks a WIM: numbered list of what is actually in the image folder, with
    browse and type-a-path as fallbacks. Beats making the operator remember and
    retype a path every time, and it surfaces what each file contains.
#>
    param(
        [string] $Prompt  = 'Select an image',
        [string] $Default,
        [string] $Folder,
        [switch] $BootImages
    )

    if (-not $Default) { $Default = $script:Config['BaseImage'] }
    if (-not $Folder) {
        $Folder = $script:Config['ImageRoot']
        if ($BootImages -and $script:Config['PeImage']) {
            $peFolder = Split-Path $script:Config['PeImage'] -Parent
            if ($peFolder) { $Folder = $peFolder }
        }
    }

    Write-Host ''
    Write-Host "   $Prompt" -ForegroundColor Cyan
    Write-Host "   Folder: $Folder" -ForegroundColor DarkGray
    Write-Host ''

    $images = @()
    try {
        $images = @(Get-WfImageInventory -Path $Folder -IncludePeImage)
    }
    catch {
        Write-Host "   Could not read the image folder: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($images.Count -eq 0) {
        Write-Host '   No .wim files found there.' -ForegroundColor Yellow
    }
    else {
        for ($i = 0; $i -lt $images.Count; $i++) {
            $img = $images[$i]
            $marker = ' '
            if ($Default -and $img.Path -eq $Default) { $marker = '*' }

            Write-Host ('  {0}{1,2}. {2,-40} {3,7:N2} GB  {4}  {5} idx' -f `
                $marker, ($i + 1), $img.Name, $img.SizeGB,
                $img.Modified.ToString('yyyy-MM-dd'), $img.Indexes)

            if ($img.ImageNames) {
                Write-Host ('        {0}' -f $img.ImageNames) -ForegroundColor DarkGray
            }
            if ($img.Notes) {
                Write-Host ('        note: {0}' -f $img.Notes) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        Write-Host '   * = current default' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '    B. Browse for a file...' -ForegroundColor DarkGray
    Write-Host '    T. Type a path' -ForegroundColor DarkGray
    Write-Host '    0. Cancel' -ForegroundColor DarkGray
    Write-Host ''
    if ($Default) { Write-Host "   Enter = $Default" -ForegroundColor DarkGray }

    while ($true) {
        $raw = Read-Host '   Choose'

        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($Default) { Show-WfIndexSummary -ImagePath $Default; return $Default }
            Write-Host '   No default set -- pick a number, B or T.' -ForegroundColor Yellow
            continue
        }

        switch -Regex ($raw.Trim()) {
            '^0$' { return $null }
            '^[Bb]$' {
                $picked = Show-WfFileDialog -InitialDirectory $Folder
                if ($picked) { Show-WfIndexSummary -ImagePath $picked; return $picked }
                Write-Host '   Nothing selected.' -ForegroundColor Yellow
                continue
            }
            '^[Tt]$' {
                $typed = Read-Host '   Path'
                if (-not [string]::IsNullOrWhiteSpace($typed)) {
                    $typed = $typed.Trim('"')
                    Show-WfIndexSummary -ImagePath $typed
                    return $typed
                }
                continue
            }
            default {
                $n = 0
                if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $images.Count) {
                    # What is in the file, before anything is done to it.
                    Show-WfIndexSummary -ImagePath $images[$n - 1].Path
                    return $images[$n - 1].Path
                }
                Write-Host '   Not a valid choice.' -ForegroundColor Yellow
            }
        }
    }
}

function Show-WfIndexSummary {
    <#
        Prints what is inside a WIM the moment it is chosen. Cheap -- this is the
        header, not a mount -- and it removes a whole class of mistake: an
        install.wim carries every edition as a separate index with near-identical
        names, and picking the wrong one is not visible until much later.
    #>
    param([Parameter(Mandatory)] [string] $ImagePath)

    $info = @()
    try { $info = @(Get-WfImageInfo -ImagePath $ImagePath) }
    catch {
        Write-Host "   Could not read the indexes: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }
    if ($info.Count -eq 0) { return }

    Write-Host ''
    if ($info.Count -eq 1) {
        Write-Host ('   One index: {0}. {1}  ({2}, {3}, {4:N2} GB)' -f `
            $info[0].ImageIndex, $info[0].ImageName, $info[0].EditionId,
            $info[0].Architecture, $info[0].SizeGB) -ForegroundColor DarkGray
        return
    }

    Write-Host ('   {0} indexes in this file:' -f $info.Count) -ForegroundColor Cyan
    foreach ($i in $info) {
        Write-Host ('     {0,2}. {1,-40} {2,-16} {3,-6} {4,7:N2} GB' -f `
            $i.ImageIndex, $i.ImageName, $i.EditionId, $i.Architecture, $i.SizeGB)
        if ($i.Note) { Write-Host ('         {0}' -f $i.Note) -ForegroundColor Yellow }
    }
}

function Select-WfIndex {
<#
    Picks an index inside a WIM, showing what each one actually is. Auto-selects
    when there is only one, which is the common case and saves a keystroke --
    and for a Microsoft media boot.wim it makes the 1-vs-2 distinction visible
    instead of leaving it to memory.
#>
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [int] $Default = 1
    )

    $info = @()
    try { $info = @(Get-WfImageInfo -ImagePath $ImagePath) }
    catch {
        Write-Host "   Could not read indexes: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '   (0 to cancel)' -ForegroundColor DarkGray
        $n = Read-WfInt 'Index' $Default
        if ($n -eq 0) { return $null }
        return $n
    }

    if ($info.Count -eq 0) { return $Default }

    if ($info.Count -eq 1) {
        Write-Host ("   Single index: {0} ({1}) -- selected automatically." -f $info[0].ImageIndex, $info[0].ImageName) -ForegroundColor DarkGray
        return [int]$info[0].ImageIndex
    }

    Write-Host ''
    Write-Host '   Indexes in this image:' -ForegroundColor Cyan
    Write-Host ''
    foreach ($i in $info) {
        Write-Host ('   {0,2}. {1,-44} {2,8:N2} GB' -f $i.ImageIndex, $i.ImageName, $i.SizeGB)

        # Edition is what tells two near-identical index names apart on retail
        # media, so it goes on its own line rather than being truncated away.
        $detail = @()
        if ($i.EditionId)    { $detail += $i.EditionId }
        if ($i.Architecture) { $detail += $i.Architecture }
        if ($i.Languages)    { $detail += $i.Languages }
        if ($detail.Count -gt 0) {
            Write-Host ('       {0}' -f ($detail -join '  |  ')) -ForegroundColor DarkGray
        }
        if ($i.ImageDescription -and $i.ImageDescription -ne $i.ImageName) {
            Write-Host ('       {0}' -f $i.ImageDescription) -ForegroundColor DarkGray
        }
        if ($i.Note) {
            Write-Host ('       {0}' -f $i.Note) -ForegroundColor Yellow
        }
    }
    Write-Host ''

    # 0 cancels. Without it, an operator who picked the wrong WIM is stuck in
    # this loop with no way out but Ctrl+C, which kills the whole tool.
    $valid = @($info.ImageIndex)
    Write-Host '   (0 to cancel)' -ForegroundColor DarkGray
    while ($true) {
        $n = Read-WfInt 'Index' $Default
        if ($n -eq 0) { return $null }
        if ($valid -contains $n) { return $n }
        Write-Host ("   That image only has index(es): {0}, or 0 to cancel" -f ($valid -join ', ')) -ForegroundColor Yellow
    }
}

function Confirm-WfAction {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host ''
    Write-Host "   $Message" -ForegroundColor Yellow
    $answer = Read-Host '   Type YES to continue'
    return ($answer -ceq 'YES')
}

function Invoke-WfMenuAction {
    <#
        Every menu action goes through here so a failure never drops the operator
        back to a bare prompt with a red wall of text and no idea what state the
        mount is in.
    #>
    param(
        [Parameter(Mandatory)] [string]      $Title,
        [Parameter(Mandatory)] [scriptblock] $Action
    )

    Show-Header $Title
    try {
        $result = & $Action
        if ($null -ne $result) {
            Write-Host ''
            $result | Format-Table -AutoSize | Out-Host
        }
        Write-Host ''
        Write-Host '   Done.' -ForegroundColor Green
    }
    catch {
        $message = $_.Exception.Message
        Write-Host ''
        Write-Host "   FAILED: $message" -ForegroundColor Red
        Write-Host ''

        # A DISM hex code on its own tells an operator nothing. When it is one
        # this toolkit recognises, what it means and what to do about it go right
        # under it rather than into a log nobody opens mid-run.
        try {
            $why = Get-WfDismError -Message $message
            if ($why.Recognised) {
                Write-Host "   $($why.Summary)" -ForegroundColor Yellow
                Write-Host ''
                foreach ($line in ($why.WhatToDo -split '(?<=\.)\s+')) {
                    if ($line.Trim()) { Write-Host "   $($line.Trim())" -ForegroundColor DarkGray }
                }
                Write-Host ''
            }
        }
        catch { }

        # Assert-WfElevated tags its message so this can offer the one thing
        # that actually fixes it, rather than leaving the operator to work out
        # that "requires administrator rights" means restart the whole window.
        if ($message -match 'NEEDS ELEVATION') {
            Write-Host '   This needs administrator rights, and a running process cannot' -ForegroundColor Yellow
            Write-Host '   grant them to itself -- the tool has to restart elevated.' -ForegroundColor Yellow
            Write-Host ''
            $answer = Read-Host '   Restart elevated now? [Y/n]'
            if ($answer -eq '' -or $answer -match '^[Yy]') {
                if (Invoke-WfRelaunchElevated) { exit }
            }
        }
        else {
            Write-Host '   If a mount was left behind, use Housekeeping > Repair stale mounts.' -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Read-Host '   Press Enter to continue' | Out-Null
}

# The driver library this session works against, when it is not the configured
# one. Held for the life of the menu rather than written to the config: an
# engineer with two libraries -- last quarter's, a colleague's, one on a share
# for a customer's fleet -- should not have to edit a setting and remember to put
# it back, which is exactly how the wrong drivers get into an image.
$script:DriverRootOverride = ''

function Get-WfMenuDriverRoot {
    <# The override if one is set, otherwise whatever the configuration says. #>
    if ($script:DriverRootOverride) { return $script:DriverRootOverride }
    return [string](Get-WfConfig)['DriverRoot']
}

function Set-WfMenuDriverRoot {
    <#
        Point this session at a different driver library, or clear it back to the
        configured one. Browsed for, with the typed fallback Show-WfFolderDialog
        already provides for a session with no desktop.
    #>
    Show-Header 'Driver library folder'
    $current = Get-WfMenuDriverRoot
    Write-Host "   Now using: $current" -ForegroundColor Cyan
    if ($script:DriverRootOverride) {
        Write-Host "   Configured: $((Get-WfConfig)['DriverRoot'])" -ForegroundColor DarkGray
        Write-Host '   This is an override and lasts until the menu closes.' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '   Enter chooses a folder. Type "reset" to go back to the configured one.' -ForegroundColor DarkGray
    $answer = (Read-Host '   Choose').Trim()

    if ($answer -eq 'reset') {
        $script:DriverRootOverride = ''
        Write-Host "   Back to the configured library: $((Get-WfConfig)['DriverRoot'])" -ForegroundColor Green
        Read-Host '   Press Enter to continue' | Out-Null
        return
    }

    $picked = Show-WfFolderDialog -Description 'Driver library folder -- one subfolder per hardware model' -StartPath $current
    if ($picked) {
        $script:DriverRootOverride = $picked
        Write-Host "   This session now uses: $picked" -ForegroundColor Green
    }
    Read-Host '   Press Enter to continue' | Out-Null
}

function Select-WfModel {
    <# Lets the operator pick models from the library, or all of them. #>
    $root    = Get-WfMenuDriverRoot
    $library = @(Get-WfDriverLibrary -DriverRoot $root)
    if ($library.Count -eq 0) {
        # Naming the folder, because "empty" and "pointed somewhere else" look
        # identical from here and have different answers.
        Write-Host "   The driver library is empty: $root" -ForegroundColor Yellow
        Write-Host '   Harvest a reference machine, or point DriverRoot at an existing library under Settings.' -ForegroundColor DarkGray
        return $null
    }

    Write-Host "   Models in $root" -ForegroundColor Cyan
    for ($i = 0; $i -lt $library.Count; $i++) {
        $age = '?'
        if ($null -ne $library[$i].AgeDays) { $age = '{0}d' -f $library[$i].AgeDays }
        Write-Host ('   {0,2}. {1,-32} {2,4} INFs  {3,3} boot  {4,7} MB  harvested {5} ago' -f `
            ($i + 1), $library[$i].Model, $library[$i].InfCount, $library[$i].BootRelevant,
            $library[$i].SizeMB, $age)
    }
    Write-Host ''
    $raw = Read-Host '   Numbers separated by commas, or Enter for all'
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $picked = New-Object System.Collections.Generic.List[string]
    foreach ($part in $raw -split ',') {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $library.Count) {
            $picked.Add($library[$n - 1].Model)
        }
    }
    if ($picked.Count -eq 0) { return $null }
    return $picked.ToArray()
}

# ---------------------------------------------------------------- sub-menus

function Show-ServicingMenu {
    :menu while ($true) {
        Show-Header 'Image servicing'
        $items = @(
            @{ Label = 'Run full servicing (updates + drivers + cleanup + export)'; Hint = 'The monthly job. Works on a copy; discards the mount on failure.'; Key = 'full' }
            @{ Label = 'Apply updates only';        Hint = 'Mount, apply everything in the Updates folder, commit.';      Key = 'updates' }
            @{ Label = 'Inject drivers only';       Hint = 'Mount, inject the driver library, commit.';                   Key = 'drivers' }
            @{ Label = 'Component cleanup / analyse'; Hint = 'See what the component store costs, optionally ResetBase.'; Key = 'cleanup' }
            @{ Label = 'Export / recompress an image'; Hint = 'Rewrite a WIM at maximum compression.';                    Key = 'export' }
            @{ Label = 'Mount an image (manual)';   Hint = 'For hand work. Remember to dismount.';                        Key = 'mount' }
            @{ Label = 'Dismount (commit or discard)'; Hint = '';                                                         Key = 'dismount' }
        ) | ForEach-Object { [pscustomobject]$_ }

        $choice = Read-MenuChoice -Prompt '   Choose' -Items $items
        if (-not $choice) { return }

        switch ($choice.Key) {
            'full' {
                Show-Header 'Run full servicing'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src   = $script:WorkingImage
                $idx   = $script:WorkingIndex
                $name  = Read-WfValue 'Output file name' ('{0}-{1}.wim' -f $script:Config['ImageNamePrefix'], (Get-Date -Format 'yyyy-MM'))
                $notes = Read-WfValue 'Notes for the build history' ''

                Write-Host ''
                Write-Host '   Stages -- Enter accepts the default for each.' -ForegroundColor Cyan
                $doUpd    = (Read-WfValue 'Apply updates?'                  'Y') -match '^[Yy]'
                $doDrv    = (Read-WfValue 'Inject the driver library?'      'Y') -match '^[Yy]'
                $doPay    = (Read-WfValue 'Copy the payload tree?'          'N') -match '^[Yy]'
                # Three answers, not two. "Skip it" and "/ResetBase" were the
                # only settings, and the second is the irreversible one --
                # clean-without-ResetBase reclaims the space and keeps updates
                # uninstallable, which is what an image still being iterated on
                # wants. Saying no to cleanup entirely costs size AND a much
                # longer commit, for no gain in reversibility.
                $doClean       = (Read-WfValue 'Component cleanup (/ResetBase)?' 'Y') -match '^[Yy]'
                $keepUninstall = $false
                if (-not $doClean) {
                    Write-Host '   Without cleanup the commit has to compress every superseded payload:' -ForegroundColor Yellow
                    Write-Host '   the dismount takes considerably longer and the image ships several GB larger.' -ForegroundColor Yellow
                    if ((Read-WfValue 'Clean without /ResetBase instead, keeping updates uninstallable? (Y/n)' 'Y') -match '^[Yy]') {
                        $doClean       = $true
                        $keepUninstall = $true
                    }
                }
                $doExport = (Read-WfValue 'Export a compressed final image?' 'Y') -match '^[Yy]'

                $models = $null
                if ($doDrv) { $models = Select-WfModel }

                Invoke-WfMenuAction 'Run full servicing' {
                    $p = @{
                        SourceImage  = $src
                        Index        = $idx
                        OutputName   = $name
                        Notes        = $notes
                        SkipUpdates  = (-not $doUpd)
                        SkipDrivers  = (-not $doDrv)
                        SkipCleanup   = (-not $doClean)
                        KeepUninstall = $keepUninstall
                        SkipExport   = (-not $doExport)
                        ApplyPayload = $doPay
                    }
                    if ($models) { $p['Models'] = $models }
                    if ($script:DriverRootOverride) { $p['DriverRoot'] = $script:DriverRootOverride }
                    Invoke-WfServicingRun @p
                }.GetNewClosure()
            }
            'updates' {
                Show-Header 'Apply updates'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex
                Invoke-WfMounted 'Apply updates' $src { Add-WfUpdate -ContinueOnError } -Index $idx
            }
            'drivers' {
                Show-Header 'Inject drivers'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex
                $models = Select-WfModel

                Write-Host ''
                Write-Host '   Skipping Microsoft-provided packages leaves the library alone --' -ForegroundColor DarkGray
                Write-Host '   this only decides what goes into this image.' -ForegroundColor DarkGray
                $noMs = (Read-WfValue 'Leave Microsoft-provided drivers out? (y/N)' 'N') -match '^[Yy]'

                Invoke-WfMounted 'Inject drivers' $src {
                    Add-WfDriver -Models $models -DriverRoot (Get-WfMenuDriverRoot) -ExcludeMicrosoft:$noMs
                }.GetNewClosure() -Index $idx
            }
            'cleanup' {
                Show-Header 'Component cleanup'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex
                $reset = (Read-WfValue 'Run /ResetBase? (y/N)' 'N') -match '^[Yy]'
                Invoke-WfMounted 'Component cleanup' $src { Invoke-WfCleanup -ResetBase:$reset }.GetNewClosure() -Index $idx
            }
            'export' {
                Show-Header 'Export image'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $dst = Read-WfValue 'Destination' (Join-Path $script:Config['ImageRoot'] 'export.wim')
                Invoke-WfMenuAction 'Export image' {
                    Export-WfImage -SourcePath $src -DestinationPath $dst -Force
                }.GetNewClosure()
            }
            'mount' {
                Show-Header 'Mount image'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex
                $ro  = (Read-WfValue 'Read-only? (y/N)' 'N') -match '^[Yy]'
                Invoke-WfMenuAction 'Mount image' {
                    Mount-WfImage -ImagePath $src -Index $idx -ReadOnly:$ro
                }.GetNewClosure()
            }
            'dismount' {
                Show-Header 'Dismount'
                $discard = (Read-WfValue 'Discard changes? (y/N)' 'N') -match '^[Yy]'
                # Both halves stated. Committing is the documented default, but a
                # commit that depends on a silent default is what made a
                # 46-minute apply vanish once already -- reading the call should
                # not require reading the function.
                Invoke-WfMenuAction 'Dismount' {
                    if ($discard) { Dismount-WfImage -Discard }
                    else          { Dismount-WfImage -Save }
                }.GetNewClosure()
            }
        }
    }
}

function Show-DriverMenu {
    :menu while ($true) {
        Show-Header 'Driver library'
        $items = @(
            @{ Label = 'Show the library';            Hint = 'One row per model: INF count, size, how old the harvest is.'; Key = 'list' }
            @{ Label = 'Driver library folder';       Hint = 'Work against a different library than the configured one, for this session.'; Key = 'root' }
            @{ Label = 'Harvest this machine';        Hint = 'Run on a known-good reference machine of a model.';           Key = 'harvest' }
            @{ Label = 'Remove a model';              Hint = 'Retire hardware you no longer support.';                      Key = 'remove' }
            @{ Label = 'Remove superseded duplicates';    Hint = 'The driver store keeps every old version; this keeps the newest.'; Key = 'dedupe' }
            @{ Label = 'Compare an image to the library'; Hint = 'Is the published image carrying current drivers?';        Key = 'compare' }
        ) | ForEach-Object { [pscustomobject]$_ }

        $choice = Read-MenuChoice -Prompt '   Choose' -Items $items
        if (-not $choice) { return }

        switch ($choice.Key) {
            'list' {
                $root = Get-WfMenuDriverRoot
                Write-Host "   Reading $root" -ForegroundColor DarkGray
                Invoke-WfMenuAction 'Driver library' { Get-WfDriverLibrary -DriverRoot $root }.GetNewClosure()
            }
            'root' { Set-WfMenuDriverRoot }
            'harvest' {
                Show-Header 'Harvest drivers'
                $cs   = Get-CimInstance Win32_ComputerSystem
                $auto = '{0}_{1}' -f ($cs.Manufacturer -replace '[^A-Za-z0-9]+','_'), ($cs.Model -replace '[^A-Za-z0-9]+','_')
                Write-Host "   This machine: $($cs.Manufacturer) $($cs.Model)" -ForegroundColor Cyan
                Write-Host ''
                $name  = Read-WfValue 'Model folder name' $auto.Trim('_')
                $force = (Read-WfValue 'Replace if it already exists? (y/N)' 'N') -match '^[Yy]'

                Write-Host ''
                Write-Host '   Microsoft-provided packages are the ones Windows Update handed this' -ForegroundColor DarkGray
                Write-Host '   machine rather than the ones the vendor shipped -- generic display,' -ForegroundColor DarkGray
                Write-Host '   audio, Bluetooth and the like. An image at the same patch level' -ForegroundColor DarkGray
                Write-Host '   already has them; a terminal that never reaches Windows Update may' -ForegroundColor DarkGray
                Write-Host '   not. Either way the count is reported and the list is logged.' -ForegroundColor DarkGray
                $noMs = (Read-WfValue 'Leave Microsoft-provided drivers out? (y/N)' 'N') -match '^[Yy]'

                Write-Host ''
                Write-Host '   The driver store also keeps every version it has ever staged, and' -ForegroundColor DarkGray
                Write-Host '   all of them get exported -- nine copies of one Bluetooth driver is' -ForegroundColor DarkGray
                Write-Host '   normal on a year-old machine. Only the newest of each is kept unless' -ForegroundColor DarkGray
                Write-Host '   you say otherwise here.' -ForegroundColor DarkGray
                $keepAll = (Read-WfValue 'Keep every version? (y/N)' 'N') -match '^[Yy]'

                # -Destination IS the library root for a harvest: the folder the
                # model subfolder is created in.
                $root = Get-WfMenuDriverRoot
                Write-Host "   Into $root" -ForegroundColor DarkGray
                Invoke-WfMenuAction 'Harvest drivers' {
                    Export-WfModelDriver -ModelName $name -Destination $root -KeepAllVersions:$keepAll `
                                         -ExcludeMicrosoft:$noMs -Force:$force
                }.GetNewClosure()
            }
            'remove' {
                Show-Header 'Remove a model'
                $models = Select-WfModel
                if ($models) {
                    foreach ($m in $models) {
                        if (Confirm-WfAction "Remove '$m' from the driver library?") {
                            Invoke-WfMenuAction "Remove $m" {
                                Remove-WfModelDriver -Model $m -DriverRoot (Get-WfMenuDriverRoot) -Confirm:$false
                            }.GetNewClosure()
                        }
                    }
                }
            }
            'dedupe' {
                Show-Header 'Remove superseded duplicates'
                Write-Host '   The Windows driver store keeps every version of a package it has ever' -ForegroundColor DarkGray
                Write-Host '   staged, and a harvest exports all of them. Only the newest of each inf' -ForegroundColor DarkGray
                Write-Host '   is kept; packages with different inf names are never compared, so' -ForegroundColor DarkGray
                Write-Host '   nothing that is genuinely a different driver can be removed.' -ForegroundColor DarkGray
                Write-Host ''

                $models = Select-WfModel
                $scope  = 'the whole library'
                if ($models -and @($models).Count -gt 0) { $scope = @($models) -join ', ' }

                Write-Host ''
                Write-Host "   Scope: $scope" -ForegroundColor Cyan
                Write-Host ''

                # Always shown before anything is deleted. -WhatIf lists exactly
                # what would go, which is the only way to be sure it agrees with
                # you before it is irreversible.
                Invoke-WfMenuAction 'Superseded duplicates' {
                    Remove-WfDuplicateDriver -Model $models -DriverRoot (Get-WfMenuDriverRoot) -WhatIf |
                        Select-Object Model, Inf, Version, KeptVersion, Removed
                }.GetNewClosure()

                if (Confirm-WfAction "Remove the superseded packages listed above from $scope?") {
                    Invoke-WfMenuAction 'Remove superseded duplicates' {
                        Remove-WfDuplicateDriver -Model $models -DriverRoot (Get-WfMenuDriverRoot) -Confirm:$false |
                            Select-Object Model, Inf, Version, KeptVersion, SizeBytes
                    }.GetNewClosure()
                }
            }

            'compare' {
                Show-Header 'Compare image to library'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                Write-Host ''
                $how = @(
                    @{ Label = 'Read the registry';  Hint = 'Seconds, no mount. Versions come from an undocumented field, so some may read as unknown.'; Key = 'quick' }
                    @{ Label = 'Mount the image';    Hint = 'Minutes. Versions straight from DISM, which is the authority.';                             Key = 'full'  }
                ) | ForEach-Object { [pscustomobject]$_ }

                $pick = Read-MenuChoice -Prompt '   How' -Items $how
                if (-not $pick) { continue menu }
                $quick = ($pick.Key -eq 'quick')

                Invoke-WfMenuAction 'Compare image to library' {
                    Compare-WfDriver -ImagePath $src -Index $idx -DriverRoot (Get-WfMenuDriverRoot) -Quick:$quick |
                        Where-Object { $_.Status -ne 'Match' } |
                        Select-Object Inf, LibraryVersion, ImageVersion, Status, Models, ReadFrom
                }.GetNewClosure()
            }
        }
    }
}

function Show-BootMenu {
    :menu while ($true) {
        Show-Header 'Boot image and publishing'
        $items = @(
            @{ Label = 'Show indexes in a boot image'; Hint = 'Do this first. Media boot.wim boots index 2, custom PE is index 1.'; Key = 'indexes' }
            @{ Label = 'Inject PE drivers';            Hint = 'Network, storage, chipset and USB only.';                            Key = 'inject' }
            @{ Label = 'Publish an image to WDS';      Hint = 'Copy, verify by hash, write a sidecar, prune old versions.';          Key = 'publish' }
            @{ Label = 'Publish a boot image to WDS';  Hint = '';                                                                    Key = 'publishboot' }
            @{ Label = 'What is in a boot image?';     Hint = 'Size, scratch space, components, tools -- and whether it fits in RAM.'; Key = 'pereport' }
            @{ Label = 'Optional components';          Hint = 'PowerShell and the rest, with their dependencies, from the ADK.';       Key = 'peoc' }
            @{ Label = 'Your own software in PE';      Hint = 'Copy a tool in. Refuses .msi and the wrong architecture.';               Key = 'petool' }
            @{ Label = 'Build startnet.cmd';           Hint = 'wpeinit first, then your tools, then the payload on the media.';         Key = 'pestartnet' }
            @{ Label = 'Scratch space';                Hint = 'The writeable part of the RAM disk. Five values, no others.';            Key = 'pescratch' }
            @{ Label = 'Replace the PE shell';         Hint = 'Run your application instead of the prompt, with wpeinit still called.'; Key = 'peshell' }
            @{ Label = 'Menu HTA for WinPE';           Hint = 'A known-good starting point, plus the fix that stops HTAs failing.';      Key = 'pehta' }
        ) | ForEach-Object { [pscustomobject]$_ }

        $choice = Read-MenuChoice -Prompt '   Choose' -Items $items
        if (-not $choice) { return }

        switch ($choice.Key) {
            'indexes' {
                Show-Header 'Boot image indexes'
                $src = Select-WfImage -Prompt 'Which boot image?' -Default $script:Config['PeImage'] -BootImages
                if (-not $src) { continue menu }   # cancelled
                Invoke-WfMenuAction 'Boot image indexes' {
                    Get-WfImageInfo -ImagePath $src
                }.GetNewClosure()
            }
            'inject' {
                Show-Header 'Inject PE drivers'
                $src = Select-WfImage -Prompt 'Which boot image?' -Default $script:Config['PeImage'] -BootImages
                if (-not $src) { continue }
                $idx = Select-WfIndex -ImagePath $src
                if ($null -eq $idx) { continue menu }   # cancelled
                $out = Read-WfValue 'Export to' (Join-Path $script:Config['ImageRoot'] ('WinPE-POS-{0}.wim' -f (Get-Date -Format 'yyyy-MM')))
                $models = Select-WfModel
                Invoke-WfMenuAction 'Inject PE drivers' {
                    Add-WfBootDriver -BootImagePath $src -Index $idx -Models $models -DriverRoot (Get-WfMenuDriverRoot) -ExportPath $out -WorkingCopy
                }.GetNewClosure()
            }
            'publish' {
                Show-Header 'Publish to WDS'
                $src   = Select-WfImage -Prompt 'Which image to publish?' -Default $script:WorkingImage
                if (-not $src) { continue menu }   # cancelled
                $notes = Read-WfValue 'Notes' ''
                if (Confirm-WfAction "Publish $(Split-Path $src -Leaf) to $($script:Config['WdsShare'])?") {
                    Invoke-WfMenuAction 'Publish to WDS' {
                        Publish-WfImage -ImagePath $src -Notes $notes -Confirm:$false
                    }.GetNewClosure()
                }
            }
            'publishboot' {
                Show-Header 'Publish boot image to WDS'
                $src   = Select-WfImage -Prompt 'Which boot image to publish?' -Default $script:Config['PeImage'] -BootImages
                if (-not $src) { continue menu }   # cancelled
                $notes = Read-WfValue 'Notes' ''
                if (Confirm-WfAction "Publish $(Split-Path $src -Leaf) to $($script:Config['WdsBootShare'])?") {
                    Invoke-WfMenuAction 'Publish boot image' {
                        Publish-WfImage -ImagePath $src -BootImage -Notes $notes -Confirm:$false
                    }.GetNewClosure()
                }
            }
            'pereport' {
                Show-Header 'What is in a boot image'
                Write-Host '   WinPE boots into memory, and the whole image has to fit in a' -ForegroundColor DarkGray
                Write-Host '   contiguous block of physical RAM plus its scratch space. This says' -ForegroundColor DarkGray
                Write-Host '   how much that is before the image goes onto a stick.' -ForegroundColor DarkGray
                Write-Host ''
                $src = Select-WfImage -Prompt 'Which boot image?' -Default $script:Config['PeImage'] -BootImages
                if (-not $src) { continue menu }
                $idx = Select-WfIndex -ImagePath $src
                if ($null -eq $idx) { continue menu }
                Invoke-WfMenuAction 'Boot image report' {
                    Get-WfPeReport -BootImagePath $src -Index $idx
                }.GetNewClosure()
            }
            'peoc' {
                Show-Header 'WinPE optional components'
                Write-Host '   Ask for PowerShell and its dependencies go in first, in the order' -ForegroundColor DarkGray
                Write-Host '   Microsoft documents. A component added out of order installs cleanly' -ForegroundColor DarkGray
                Write-Host '   and then does not work.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   PowerShell and its chain cost well over a hundred megabytes, and all' -ForegroundColor Yellow
                Write-Host '   of it is RAM on every terminal that boots the image.' -ForegroundColor Yellow
                Write-Host ''

                $ocRoot = $null
                try { $ocRoot = Get-WfAdkWinPeRoot } catch { }
                if ($ocRoot) { Write-Host "   From $ocRoot" -ForegroundColor DarkGray; Write-Host '' }

                $shelf = @()
                try { $shelf = @(Get-WfPeOptionalComponent | Where-Object { $_.Present }) } catch { }
                if ($shelf.Count -eq 0) {
                    Write-Host '   Nothing available -- the ADK WinPE add-on is not on this machine.' -ForegroundColor Yellow
                    Write-Host '   It is a separate download from the ADK itself. Drivers, tools and' -ForegroundColor DarkGray
                    Write-Host '   startnet.cmd all still work without it.' -ForegroundColor DarkGray
                    Read-Host '   Press Enter to continue' | Out-Null
                    continue menu
                }

                $src = Select-WfImage -Prompt 'Which boot image?' -Default $script:Config['PeImage'] -BootImages
                if (-not $src) { continue menu }
                $idx = Select-WfIndex -ImagePath $src
                if ($null -eq $idx) { continue menu }

                $pickedOcs = Read-WfPickMany -Prompt 'Components to add' -Items @($shelf | ForEach-Object {
                    [pscustomobject]@{ Label = ('{0,-26} {1,6} MB' -f $_.Name, $_.SizeMB)
                                       Value = $_.Name; Hint = $_.What } })
                if (@($pickedOcs).Count -eq 0) { continue menu }

                Invoke-WfMenuAction 'PE optional components' {
                    Add-WfPeOptionalComponent -Component $pickedOcs -BootImagePath $src -Index $idx -Confirm:$false
                }.GetNewClosure()
            }
            'petool' {
                Show-Header 'Your own software in WinPE'
                Write-Host '   Small tools go into the image. Anything large should live on the' -ForegroundColor DarkGray
                Write-Host '   media instead and be found at run time -- startnet.cmd below does' -ForegroundColor DarkGray
                Write-Host '   that, and it costs the boot image nothing.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Two things WinPE will not do whatever you try: run an .msi (there is' -ForegroundColor Yellow
                Write-Host '   no Windows Installer service in it) and run a 32-bit binary in a' -ForegroundColor Yellow
                Write-Host '   64-bit PE (there is no WoW64). Both are checked before anything is' -ForegroundColor Yellow
                Write-Host '   copied, because both fail silently on the terminal.' -ForegroundColor Yellow
                Write-Host ''

                $src = Select-WfImage -Prompt 'Which boot image?' -Default $script:Config['PeImage'] -BootImages
                if (-not $src) { continue menu }
                $idx = Select-WfIndex -ImagePath $src
                if ($null -eq $idx) { continue menu }

                Write-Host ''
                Write-Host '   Blank lists what is already in there instead of adding anything.' -ForegroundColor DarkGray
                $toolSrc = Read-WfValue 'Tool folder or file' ''
                if (-not $toolSrc) {
                    Invoke-WfMenuAction 'PE tools' {
                        Get-WfPeTool -BootImagePath $src -Index $idx
                    }.GetNewClosure()
                    continue menu
                }

                Write-Host ''
                Write-Host '   Blank means nothing launches it -- it is there to run by hand at the' -ForegroundColor DarkGray
                Write-Host '   PE prompt, which is right for a diagnostic somebody reaches for.' -ForegroundColor DarkGray
                $toolCmd = Read-WfValue 'What to run inside it, relative to the folder' ''
                $toolArg = Read-WfValue 'Arguments for it' ''

                Invoke-WfMenuAction 'PE tool' {
                    $toolArgs = @{ Source = $toolSrc; BootImagePath = $src; Index = $idx; Force = $true; Confirm = $false }
                    if ($toolCmd) { $toolArgs['Command']   = $toolCmd }
                    if ($toolArg) { $toolArgs['Arguments'] = $toolArg }
                    Add-WfPeTool @toolArgs
                }.GetNewClosure()
            }
            'pestartnet' {
                Show-Header 'Build startnet.cmd'
                Write-Host '   wpeinit always goes first and cannot be moved. It installs the Plug' -ForegroundColor DarkGray
                Write-Host '   and Play devices, processes Unattend.xml and brings up the network,' -ForegroundColor DarkGray
                Write-Host '   so anything above it runs on a machine with no drivers and looks' -ForegroundColor DarkGray
                Write-Host '   broken for reasons that have nothing to do with it.' -ForegroundColor DarkGray
                Write-Host ''

                $src = Select-WfImage -Prompt 'Which boot image?' -Default $script:Config['PeImage'] -BootImages
                if (-not $src) { continue menu }
                $idx = Select-WfIndex -ImagePath $src
                if ($null -eq $idx) { continue menu }

                $netAll = Confirm-WfAction 'Launch every tool in the image that recorded a command?'

                Write-Host ''
                Write-Host '   A folder searched for on every volume at run time -- the way large' -ForegroundColor DarkGray
                Write-Host '   software should travel, since it costs the boot image nothing.' -ForegroundColor DarkGray
                Write-Host '   WinPE drive letters change every boot, so it is found, not assumed.' -ForegroundColor DarkGray
                $netPayload = Read-WfValue 'Payload folder on the media (blank to skip)' ''
                $netPayCmd  = ''
                if ($netPayload) { $netPayCmd = Read-WfValue 'What to run inside it' '' }

                Write-Host ''
                Write-Host '   A region fragment from the Region menu, called after the payload.' -ForegroundColor DarkGray
                $netRegion = Read-WfValue 'Region script file name (blank to skip)' ''

                Invoke-WfMenuAction 'PE startnet' {
                    $netArgs = @{ BootImagePath = $src; Index = $idx; Confirm = $false }
                    if ($netAll)     { $netArgs['AllTools']       = $true }
                    if ($netPayload) { $netArgs['PayloadFolder']  = $netPayload }
                    if ($netPayCmd)  { $netArgs['PayloadCommand'] = $netPayCmd }
                    if ($netRegion)  { $netArgs['RegionScript']   = $netRegion }
                    New-WfPeStartnet @netArgs
                }.GetNewClosure()
            }
            'pescratch' {
                Show-Header 'WinPE scratch space'
                Write-Host '   The writeable part of the RAM disk. Anything your tools write comes' -ForegroundColor DarkGray
                Write-Host '   out of it, and running out shows up as a disk-full error against a' -ForegroundColor DarkGray
                Write-Host '   drive nobody thinks of as a drive.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Five values exist and no others: 512MB is the default on a machine' -ForegroundColor DarkGray
                Write-Host '   with more than 1GB of RAM, 32MB below that.' -ForegroundColor DarkGray
                Write-Host ''

                $src = Select-WfImage -Prompt 'Which boot image?' -Default $script:Config['PeImage'] -BootImages
                if (-not $src) { continue menu }
                $idx = Select-WfIndex -ImagePath $src
                if ($null -eq $idx) { continue menu }

                $scratchPick = Read-WfPick -Prompt 'Scratch space' -Items @(
                    @(32, 64, 128, 256, 512) | ForEach-Object {
                        [pscustomobject]@{ Label = ('{0} MB' -f $_); Value = "$_"; Hint = '' } })
                if (-not $scratchPick) { continue menu }

                $scratchMb = 0
                if (-not [int]::TryParse($scratchPick, [ref]$scratchMb)) { continue menu }

                Invoke-WfMenuAction 'PE scratch space' {
                    Set-WfPeScratchSpace -SizeMB $scratchMb -BootImagePath $src -Index $idx -Confirm:$false
                }.GetNewClosure()
            }
            'peshell' {
                Show-Header 'Replace the PE shell'
                Write-Host '   For a deployment console that should look like a product rather than' -ForegroundColor DarkGray
                Write-Host '   like a command window.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Replacing the shell means startnet.cmd never runs -- and startnet.cmd' -ForegroundColor Yellow
                Write-Host '   is what calls wpeinit. So this points winpeshl.ini at a small' -ForegroundColor Yellow
                Write-Host '   generated wrapper that runs wpeinit and then your application,' -ForegroundColor Yellow
                Write-Host '   instead of at the application directly.' -ForegroundColor Yellow
                Write-Host ''

                $src = Select-WfImage -Prompt 'Which boot image?' -Default $script:Config['PeImage'] -BootImages
                if (-not $src) { continue menu }
                $idx = Select-WfIndex -ImagePath $src
                if ($null -eq $idx) { continue menu }

                Write-Host ''
                Write-Host '   Blank puts the normal command prompt back.' -ForegroundColor DarkGray
                $shellCmd = Read-WfValue 'Application, as the terminal sees it' '%SystemRoot%\Tools\'
                $shellArg = ''
                if ($shellCmd -and $shellCmd -ne '%SystemRoot%\Tools\') { $shellArg = Read-WfValue 'Arguments' '' }

                Invoke-WfMenuAction 'PE shell' {
                    if (-not $shellCmd -or $shellCmd -eq '%SystemRoot%\Tools\') {
                        Set-WfPeShell -Remove -BootImagePath $src -Index $idx -Confirm:$false
                    }
                    else {
                        $shellArgs = @{ Command = $shellCmd; BootImagePath = $src; Index = $idx; Confirm = $false }
                        if ($shellArg) { $shellArgs['Arguments'] = $shellArg }
                        Set-WfPeShell @shellArgs
                    }
                }.GetNewClosure()
            }
            'pehta' {
                Show-Header 'Menu HTA for WinPE'
                Write-Host '   An HTA is a few kilobytes of HTML and gives a deployment console a' -ForegroundColor DarkGray
                Write-Host '   real front end. It is also the thing with two documented ways to' -ForegroundColor DarkGray
                Write-Host '   fail before your own HTML is in question, so this generates one that' -ForegroundColor DarkGray
                Write-Host '   is known to run -- boot it once, then edit HTML against a path you' -ForegroundColor DarkGray
                Write-Host '   know works.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   It needs WinPE-HTA in the boot image, which pulls in WinPE-Scripting.' -ForegroundColor Yellow
                Write-Host ''

                $htaItems = @(
                    @{ Label = 'Generate a menu HTA';        Hint = 'Buttons that run commands. VBScript, so the engine change cannot bite it.'; Key = 'make' }
                    @{ Label = 'How would a file be started?'; Hint = 'What WinPE would run, and what has to be in the image first.';             Key = 'how' }
                    @{ Label = 'Fix HTAs in a boot image';   Hint = 'The legacy JScript engine, for an image that broke after an ADK upgrade.';  Key = 'jscript' }
                ) | ForEach-Object { [pscustomobject]$_ }

                $htaChoice = Read-MenuChoice -Prompt '   Choose' -Items $htaItems
                if (-not $htaChoice) { continue menu }

                switch ($htaChoice.Key) {
                    'make' {
                        $htaTitle = Read-WfValue 'Heading and window title' 'Deployment'
                        $htaPath  = Read-WfValue 'Write the .hta to' 'C:\Imaging\Pe\Menu\menu.hta'
                        if (-not $htaPath) { continue menu }

                        Write-Host ''
                        Write-Host '   Buttons, one per line, as  Label = command. Blank line to finish.' -ForegroundColor DarkGray
                        Write-Host '   For example:  Deploy = X:\deploy.cmd' -ForegroundColor DarkGray
                        Write-Host ''

                        $htaItemList = @()
                        while ($true) {
                            $line = Read-Host ('   Button {0}' -f ($htaItemList.Count + 1))
                            if (-not "$line".Trim()) { break }
                            $at = $line.IndexOf('=')
                            if ($at -lt 1) {
                                Write-Host '   That is not  Label = command.' -ForegroundColor Yellow
                                continue
                            }
                            $htaItemList += @{ Label = $line.Substring(0, $at).Trim(); Command = $line.Substring($at + 1).Trim() }
                        }
                        if ($htaItemList.Count -eq 0) { continue menu }

                        Invoke-WfMenuAction 'Menu HTA' {
                            New-WfPeMenuHta -Title $htaTitle -Item $htaItemList -Path $htaPath -Confirm:$false
                        }.GetNewClosure()
                    }
                    'how' {
                        $htaWhat = Read-WfValue 'A file name -- menu.hta, run.cmd, Diag.exe, deploy.ps1' 'menu.hta'
                        if (-not $htaWhat) { continue menu }

                        Invoke-WfMenuAction 'Launch rule' {
                            $how = Get-WfPeLaunchCommand -Command $htaWhat -Path ('%SystemRoot%\Tools\<tool>\' + $htaWhat)
                            Write-WfLog ("{0}: {1}" -f $htaWhat, $how.Kind) -Level OK
                            if ($how.Line)     { Write-WfLog ("  startnet would say:  {0}" -f $how.Line) -Level INFO }
                            if ($how.Requires) { Write-WfLog ("  needs {0} in the boot image" -f $how.Requires) -Level WARN }
                            if ($how.Note)     { Write-WfLog ("  {0}" -f $how.Note) -Level INFO }
                            $how
                        }.GetNewClosure()
                    }
                    'jscript' {
                        Write-Host ''
                        Write-Host '   Microsoft replaced the JScript engine in the ADK for Windows 11' -ForegroundColor DarkGray
                        Write-Host '   22H2. An HTA written for the old one comes up with "An error has' -ForegroundColor DarkGray
                        Write-Host '   occurred in the script on this page" and nothing else to go on.' -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host '   Adding an HTA as a tool does this for you. This is for an image' -ForegroundColor DarkGray
                        Write-Host '   that already has one and broke after an ADK upgrade.' -ForegroundColor DarkGray
                        Write-Host ''

                        $src = Select-WfImage -Prompt 'Which boot image?' -Default $script:Config['PeImage'] -BootImages
                        if (-not $src) { continue menu }
                        $idx = Select-WfIndex -ImagePath $src
                        if ($null -eq $idx) { continue menu }

                        $jsUndo = -not (Confirm-WfAction 'Turn the legacy engine ON? (No puts the modern one back)')

                        Invoke-WfMenuAction 'PE JScript engine' {
                            $jsArgs = @{ BootImagePath = $src; Index = $idx; Confirm = $false }
                            if ($jsUndo) { $jsArgs['Remove'] = $true }
                            Enable-WfPeLegacyJScript @jsArgs
                        }.GetNewClosure()
                    }
                }
            }
        }
    }
}

function Invoke-WfMounted {
    <#
        Mount, run the body, commit -- and discard on any failure.

        Deliberately NOT -WorkingCopy: these are single changes applied to the
        image the operator named, so the change has to land in that file. A
        working copy would commit into a throwaway *.working.wim, report success,
        and leave the master untouched -- the worst kind of bug, because it looks
        like it worked. Discarding on failure already protects the master.
    #>
    param(
        [Parameter(Mandatory)] [string]      $Title,
        [Parameter(Mandatory)] [string]      $Image,
        [Parameter(Mandatory)] [scriptblock] $Body,
        [int] $Index = 1
    )
    # Invoke-WfWithMount reuses a mount that is already open and leaves it open,
    # so a run of customisations costs one mount rather than one each. When
    # nothing is mounted it mounts, commits, and discards on failure -- exactly
    # what this did before.
    Invoke-WfMenuAction $Title {
        # The inner block is a literal, NOT another .GetNewClosure(): a closure
        # copies the executing scope's locals, and inside this closure $Body
        # lives in the closure's own module scope rather than as a local -- so
        # GetNewClosure would capture nothing and hand Invoke-WfWithMount a null.
        # A plain literal resolves $Body against this closure's scope, correctly.
        Invoke-WfWithMount -ImagePath $Image -Index $Index -Body { & $Body }
    }.GetNewClosure()
}

function Show-CustomiseMenu {
    :menu while ($true) {
        Show-Header 'Offline customisation'
        $items = @(
            @{ Label = 'Apply .reg file(s) to an image'; Hint = 'Target HKLM\WF_SOFTWARE, WF_SYSTEM or WF_DEFAULT in the file.'; Key = 'reg' }
            @{ Label = 'Copy the payload tree';          Hint = 'Payload folder mirrors C:\ on the deployed machine.';             Key = 'payload' }
            @{ Label = 'Import certificates';            Hint = 'Into the offline machine store.';                                  Key = 'cert' }
            @{ Label = 'Check unattend.xml';             Hint = 'Flags hard-coded names, stray keys, SkipRearm.';                   Key = 'testunattend' }
            @{ Label = 'Place unattend.xml in an image'; Hint = 'Copies to Windows\Panther\unattend.xml.';                          Key = 'setunattend' }
            @{ Label = 'Enable a feature (.NET 3.5 etc)'; Hint = 'NetFx3 needs -Source \sources\sxs from the LTSC media.';          Key = 'feature' }
            @{ Label = 'Device lockdown';                 Hint = 'UWF, Shell Launcher, Keyboard Filter, Custom Logon -- what IoT Enterprise is for.'; Key = 'lockdown' }
            @{ Label = 'First-boot script';               Hint = 'SetupComplete.cmd -- runs once as SYSTEM before anyone logs on.';   Key = 'firstboot' }
            @{ Label = 'Regional settings and time zone'; Hint = 'Baked into the image, so they are right without an answer file.';    Key = 'locale' }
            @{ Label = 'Display languages';               Hint = 'A region is a setting; a language is a package. Import from the ISO, then add.'; Key = 'lang' }
            @{ Label = 'Region -- one image, many countries'; Hint = 'Country presets, the home location unattend cannot set, and the WinPE-to-first-boot pair.'; Key = 'region' }
            @{ Label = 'OEM support information';         Hint = 'Who built this terminal and which number to ring.';                  Key = 'oem' }
            @{ Label = 'Local group policy';              Hint = 'Drop a prepared Registry.pol in. Applies with no domain.';           Key = 'policy' }
            @{ Label = 'Slim the image down';             Hint = 'Provisioned apps, capabilities and features. Lists before removing.'; Key = 'slim' }
            @{ Label = 'Drivers into the recovery image'; Hint = 'WinRE gets none of the image drivers -- so recovery boots blind.';   Key = 'winre' }
            @{ Label = 'Recovery and reset';              Hint = 'Getting a terminal back to the image it shipped with.';             Key = 'recovery' }
        ) | ForEach-Object { [pscustomobject]$_ }

        $choice = Read-MenuChoice -Prompt '   Choose' -Items $items
        if (-not $choice) { return }

        switch ($choice.Key) {
            'reg' {
                Show-Header 'Apply .reg files'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex
                $file = Read-WfValue 'Path to .reg file' ''
                Invoke-WfMounted 'Apply .reg files' $src { Invoke-WfRegistryEdit -RegFile $file }.GetNewClosure() -Index $idx
            }
            'payload' {
                Show-Header 'Copy payload'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex
                Invoke-WfMounted 'Copy payload' $src { Copy-WfPayload } -Index $idx
            }
            'cert' {
                Show-Header 'Import certificates'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex
                $cert  = Read-WfValue 'Path to .cer' ''
                $store = Read-WfValue 'Store (Root/CA/TrustedPublisher)' 'Root'
                Invoke-WfMounted 'Import certificates' $src {
                    Import-WfCertificate -CertificatePath $cert -Store $store
                }.GetNewClosure() -Index $idx
            }
            'testunattend' {
                Show-Header 'Check unattend.xml'
                $path = Read-WfPick -Prompt 'unattend.xml' -Items @() `
                                    -Default $script:Config['UnattendPath'] -Browse `
                                    -BrowseFilter 'Answer files (*.xml)|*.xml|All files (*.*)|*.*'
                Invoke-WfMenuAction 'Check unattend.xml' { Test-WfUnattend -Path $path }.GetNewClosure()
            }
            'setunattend' {
                Show-Header 'Place unattend.xml'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex
                $path = Read-WfPick -Prompt 'unattend.xml' -Items @() `
                                    -Default $script:Config['UnattendPath'] -Browse `
                                    -BrowseFilter 'Answer files (*.xml)|*.xml|All files (*.*)|*.*'
                Invoke-WfMounted 'Place unattend.xml' $src { Set-WfUnattend -Path $path }.GetNewClosure() -Index $idx
            }
            'feature' {
                Show-Header 'Enable a feature'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex
                $feature = Read-WfValue 'Feature name' 'NetFx3'
                $source  = Read-WfValue 'Source (\sources\sxs on the LTSC media), blank for none' ''
                Invoke-WfMounted 'Enable a feature' $src {
                    Add-WfCapability -Feature $feature -Source $source
                }.GetNewClosure() -Index $idx
            }

            'lockdown' {
                Show-Header 'Device lockdown'
                Write-Host '   These features exist only on Enterprise and IoT Enterprise, which is' -ForegroundColor DarkGray
                Write-Host '   what a POS estate is licensed for and almost never uses.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Enabling them is done in the image. Configuring UWF, Keyboard Filter' -ForegroundColor DarkGray
                Write-Host '   and Shell Launcher needs uwfmgr and WMI, which an offline image cannot' -ForegroundColor DarkGray
                Write-Host '   reach -- so those settings go into a first-boot script instead.' -ForegroundColor DarkGray
                Write-Host ''

                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                $steps = @(
                    @{ Label = 'What does this image have?';   Hint = 'Lists the lockdown features and whether they are on.';        Key = 'show' }
                    @{ Label = 'Enable the features';          Hint = 'Costs nothing at runtime -- an unconfigured filter filters nothing.'; Key = 'enable' }
                    @{ Label = 'Suppress the logon UI';        Hint = 'Custom Logon. Pure registry, so it goes fully into the image.'; Key = 'logon' }
                    @{ Label = 'Replace the shell';            Hint = 'Run your application instead of Explorer. No way back from the terminal.'; Key = 'shell' }
                    @{ Label = 'Configure UWF and the rest';   Hint = 'Writes the first-boot script that applies them on the terminal.'; Key = 'config' }
                ) | ForEach-Object { [pscustomobject]$_ }

                $step = Read-MenuChoice -Prompt '   Which' -Items $steps
                if (-not $step) { continue menu }

                switch ($step.Key) {
                    'show' {
                        # Read-only: listing features changes nothing, and a
                        # read-only mount cannot be committed by accident.
                        # Uses the open image when there is one and never closes it; asks
                        # first when there is not, because opening costs minutes and that is
                        # the operator's decision, not a side effect of a read button.
                        $mountChoice = Confirm-WfMountNeeded 'Listing the lockdown features'
                        if ($mountChoice -eq 'no') { continue menu }
                        if ($mountChoice -eq 'keep' -and -not (Get-WfCurrentMount)) {
                            # Opened here so the call below finds it open and leaves it open.
                            Invoke-WfMenuAction 'Open the image' {
                                Mount-WfImage -ImagePath $src -Index $idx -ReadOnly
                            }.GetNewClosure()
                        }

                        Invoke-WfMenuAction 'Lockdown features' {
                            Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfLockdownFeature }
                        }.GetNewClosure()
                    }
                    'enable' {
                        Write-Host ''
                        Write-Host '   Enter to take all of them, or name the ones you want:' -ForegroundColor DarkGray
                        Write-Host '   Uwf, ShellLauncher, KeyboardFilter, CustomLogon, UnbrandedBoot' -ForegroundColor DarkGray
                        $raw = Read-WfValue 'Features (comma separated, blank = all)' ''
                        $feat = @('All')
                        if ($raw) { $feat = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                        Invoke-WfMounted 'Enable lockdown features' {
                            Enable-WfLockdownFeature -Feature $feat
                        }.GetNewClosure() $src -Index $idx
                    }
                    'logon' {
                        Write-Host ''
                        $undo = (Read-WfValue 'Put the ordinary logon experience back instead? (y/N)' 'N') -match '^[Yy]'
                        Invoke-WfMounted 'Custom logon' {
                            Set-WfCustomLogon -Revert:$undo -Confirm:$false
                        }.GetNewClosure() $src -Index $idx
                    }
                    'shell' {
                        Show-Header 'Replace the shell'
                        Write-Host '   This is the classic machine-wide Winlogon shell replacement, which' -ForegroundColor DarkGray
                        Write-Host '   works on any edition and can be set entirely offline.' -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host '   There is no way out of it from the terminal. Have support access' -ForegroundColor Yellow
                        Write-Host '   sorted before this reaches a shop.' -ForegroundColor Yellow
                        Write-Host ''
                        Write-Host "   'explorer.exe' puts the desktop back." -ForegroundColor DarkGray
                        $shell = Read-WfValue 'Shell command line' 'explorer.exe'
                        if (-not $shell) { continue menu }
                        if (Confirm-WfAction "Set the machine shell to $shell?") {
                            Invoke-WfMounted 'Replace the shell' {
                                Set-WfShellLauncher -Shell $shell -Confirm:$false
                            }.GetNewClosure() $src -Index $idx
                        }
                    }
                    'config' {
                        Show-Header 'Configure lockdown at first boot'
                        Write-Host '   Blank any of these to leave that feature alone.' -ForegroundColor DarkGray
                        Write-Host ''
                        $vols = Read-WfValue 'UWF: volumes to protect (comma separated)' 'C:'
                        $exc  = ''
                        if ($vols) {
                            Write-Host ''
                            Write-Host '   Exclusions matter more than the filter does. A till that discards' -ForegroundColor Yellow
                            Write-Host '   its own transaction log every night is worse than no filter.' -ForegroundColor Yellow
                            $exc = Read-WfValue 'UWF: paths to exclude (comma separated)' ''
                        }
                        Write-Host ''
                        Write-Host '   Keyboard Filter: which combinations should never reach Windows.' -ForegroundColor DarkGray
                        Write-Host '   These names are fixed by the feature -- one typed slightly wrong' -ForegroundColor DarkGray
                        Write-Host '   is accepted and then blocks nothing, so they are picked, not typed.' -ForegroundColor DarkGray
                        $keyItems = @(Get-WfKeyboardFilterChoice | ForEach-Object {
                            [pscustomobject]@{ Value = $_.Key; Label = $_.Key; Hint = $_.What }
                        })
                        $keyList = @(Read-WfPickMany -Prompt 'Keys to block' -Items $keyItems `
                                                     -Default @('Ctrl+Alt+Del', 'Alt+Tab', 'Windows'))

                        $slSh  = Read-WfValue 'Shell Launcher: application (blank to skip)' ''

                        $volList = @($vols -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                        $excList = @($exc  -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

                        Invoke-WfMounted 'Lockdown first-boot script' {
                            New-WfLockdownFirstBoot -ProtectVolume $volList -Exclusion $excList `
                                                    -BlockKey $keyList -ShellLauncherShell $slSh `
                                                    -Append -Confirm:$false
                        }.GetNewClosure() $src -Index $idx
                    }
                }
            }

            'locale' {
                Show-Header 'Regional settings'
                Write-Host '   These usually live only in unattend.xml, which means they are right' -ForegroundColor DarkGray
                Write-Host '   only when the answer file is used. In the image, they are the default' -ForegroundColor DarkGray
                Write-Host '   and the answer file becomes a way to override them.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Leave any of them blank to leave that setting alone.' -ForegroundColor DarkGray
                Write-Host ''

                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                # Read what is in there now before offering to change it, and keep
                # the answer: the UI languages this image actually has are the
                # only ones worth offering, and this read already knows them.
                Show-Header 'Current regional settings'
                $now      = $null
                $uiChoice = @()
                try {
                    # Uses the open image when there is one and never closes it; asks
                    # first when there is not, because opening costs minutes and that is
                    # the operator's decision, not a side effect of a read button.
                    $mountChoice = Confirm-WfMountNeeded 'Reading the regional settings'
                    if ($mountChoice -eq 'no') { continue menu }
                    if ($mountChoice -eq 'keep' -and -not (Get-WfCurrentMount)) {
                        # Opened here so the call below finds it open and leaves it open.
                        Invoke-WfMenuAction 'Open the image' {
                            Mount-WfImage -ImagePath $src -Index $idx -ReadOnly
                        }.GetNewClosure()
                    }

                    $now = Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body {
                        Get-WfImageLocale
                    }
                    if ($now) {
                        Write-Host ''
                        $now | Select-Object UILanguage, SystemLocale, UserLocale, InputLocale |
                            Format-List | Out-Host

                        # Handed the reading rather than left to take it again --
                        # a second dism call inside the same mount for an answer
                        # that cannot have changed in between.
                        $uiChoice = ConvertTo-WfPickItem -Source (Get-WfUiLanguageChoice -Locale $now) `
                                                         -ValueProperty Language -LabelProperty Name
                    }
                }
                catch {
                    Write-Host ''
                    Write-Host "   Could not read the current settings: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host '   The settings below can still be set; nothing is pre-filled from the image.' -ForegroundColor DarkGray
                }

                Show-Header 'Regional settings'
                Write-Host '   Every one of these is a list now. Enter on its own leaves that' -ForegroundColor DarkGray
                Write-Host '   setting exactly as it is.' -ForegroundColor DarkGray

                if ($uiChoice.Count -eq 0) {
                    Write-Host ''
                    Write-Host '   No UI language list -- a UI language can only be set to one already' -ForegroundColor Yellow
                    Write-Host '   in the image, so there is nothing to offer. Add a language pack first.' -ForegroundColor Yellow
                    $ui = ''
                }
                elseif ($uiChoice.Count -eq 1) {
                    Write-Host ''
                    Write-Host ("   Only one UI language in this image ({0}), so it is not a choice." -f $uiChoice[0].Value) -ForegroundColor DarkGray
                    $ui = ''
                }
                else {
                    $ui = Read-WfPick -Prompt 'UI language (the language the menus are in)' -Items $uiChoice
                }

                $locales = ConvertTo-WfPickItem -Source (Get-WfLocaleChoice) `
                                                -ValueProperty Name -LabelProperty EnglishName
                $sys = Read-WfPick -Prompt 'System locale (the ANSI code page for non-Unicode programs)' -Items $locales
                $usr = Read-WfPick -Prompt 'User locale (date, time, number and currency formats)' -Items $locales

                # The keyboard is two decisions, and asking for them as one string
                # is how '0413:00020409' ends up being typed from memory. The
                # language comes from what was just chosen; only the layout is asked.
                $kbd  = ''
                $kbLang = $usr
                if (-not $kbLang) { $kbLang = $sys }
                if (-not $kbLang) { $kbLang = $ui }
                if (-not $kbLang -and $now) { $kbLang = $now.UserLocale }

                if ($kbLang) {
                    $layouts = ConvertTo-WfPickItem -Source (Get-WfKeyboardChoice) `
                                                    -ValueProperty LayoutId -LabelProperty Layout
                    Write-Host ''
                    Write-Host ("   The keyboard language is taken from {0}; pick the physical layout." -f $kbLang) -ForegroundColor DarkGray
                    Write-Host '   A Dutch estate on US-International hardware is nl-NL plus US-International.' -ForegroundColor DarkGray
                    $layoutId = Read-WfPick -Prompt 'Keyboard layout' -Items $layouts
                    if ($layoutId) { $kbd = Get-WfInputLocaleValue -Language $kbLang -LayoutId $layoutId }
                }
                else {
                    Write-Host ''
                    Write-Host '   No locale chosen, so there is no language to pair a layout with.' -ForegroundColor DarkGray
                    Write-Host '   Choose a system or user locale to set the keyboard as well.' -ForegroundColor DarkGray
                }

                $zones = ConvertTo-WfPickItem -Source (Get-WfTimeZoneChoice) `
                                              -ValueProperty Id -LabelProperty Name
                $tz = Read-WfPick -Prompt 'Time zone' -Items $zones

                if (-not ($ui -or $sys -or $usr -or $kbd -or $tz)) {
                    Write-Host ''
                    Write-Host '   Nothing chosen, so nothing to change.' -ForegroundColor DarkGray
                    Write-Host ''
                    [void](Read-Host '   Enter to go back')
                    continue menu
                }

                Show-Header 'Regional settings'
                Write-Host '   About to set:' -ForegroundColor DarkGray
                foreach ($pair in @(
                    @{ N = 'UI language';   V = $ui  }
                    @{ N = 'System locale'; V = $sys }
                    @{ N = 'User locale';   V = $usr }
                    @{ N = 'Keyboard';      V = $kbd }
                    @{ N = 'Time zone';     V = $tz  })) {
                    if ($pair.V) { Write-Host ('     {0,-14} {1}' -f $pair.N, $pair.V) }
                }
                Write-Host ''
                if (-not (Confirm-WfAction 'Apply these to the image?')) { continue menu }

                Invoke-WfMounted 'Regional settings' {
                    Set-WfImageLocale -UILanguage $ui -SystemLocale $sys -UserLocale $usr `
                                      -InputLocale $kbd -TimeZone $tz -Confirm:$false
                }.GetNewClosure() $src -Index $idx
            }

            'lang' {
                Show-Header 'Display languages'
                Write-Host '   A region is a setting and can be changed at any time. A display' -ForegroundColor DarkGray
                Write-Host '   language is a PACKAGE: the menus can only be set to a language' -ForegroundColor DarkGray
                Write-Host '   whose pack is already in the image. DISM does not invent one --' -ForegroundColor DarkGray
                Write-Host '   "if the language is not installed in the Windows image, the' -ForegroundColor DarkGray
                Write-Host '   command will fail".' -ForegroundColor DarkGray
                Write-Host ''

                $langItems = @(
                    @{ Label = 'Show the language library';   Hint = 'What has been imported, and whether each has its pack.'; Key = 'list' }
                    @{ Label = 'Import from the Languages ISO'; Hint = 'Once per language, from the ISO matching this build.';  Key = 'import' }
                    @{ Label = 'Languages in an image';       Hint = 'What the image actually carries, and its satellites.';   Key = 'inimage' }
                    @{ Label = 'Add languages to an image';    Hint = 'Pack first, then its Features on Demand.';               Key = 'add' }
                ) | ForEach-Object { [pscustomobject]$_ }

                $langChoice = Read-MenuChoice -Prompt '   Choose' -Items $langItems
                if (-not $langChoice) { continue menu }

                switch ($langChoice.Key) {
                    'list' {
                        Invoke-WfMenuAction 'Language library' { Get-WfLanguageLibrary }
                    }
                    'import' {
                        $src = Read-WfValue 'Languages ISO or folder' 'E:\'
                        if (-not $src) { continue menu }
                        Write-Host ''
                        Write-Host '   Blank imports every language on the source, which is a lot of disk.' -ForegroundColor DarkGray
                        $raw  = Read-WfValue 'Language tags, comma separated (nl-NL, de-DE, sv-SE)' ''
                        $list = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

                        Invoke-WfMenuAction 'Import languages' {
                            $p = @{ Source = $src; Confirm = $false }
                            if ($list -and $list.Count -gt 0) { $p['Language'] = $list }
                            Import-WfLanguagePack @p
                        }.GetNewClosure()
                    }
                    'inimage' {
                        if (-not (Confirm-WfWorkingImage)) { continue menu }
                        Invoke-WfMounted 'Image languages' { Get-WfImageLanguage } `
                            $script:WorkingImage -Index $script:WorkingIndex
                    }
                    'add' {
                        if (-not (Confirm-WfWorkingImage)) { continue menu }

                        $shelf = @()
                        try { $shelf = @(Get-WfLanguageLibrary) } catch { }
                        if ($shelf.Count -eq 0) {
                            Write-Host '   The language library is empty -- import from the ISO first.' -ForegroundColor Yellow
                            Read-Host '   Press Enter to continue' | Out-Null
                            continue menu
                        }

                        $pickedLangs = Read-WfPickMany -Prompt 'Languages to add' -Items @($shelf | ForEach-Object {
                            $note = 'no language pack'
                            if ($_.HasLanguagePack) { $note = $_.Features }
                            [pscustomobject]@{ Label = ('{0,-8} {1,-28} {2}' -f $_.Language, $_.Name, $note)
                                               Value = $_.Language; Hint = '' } })
                        if (@($pickedLangs).Count -eq 0) { continue menu }

                        # The rule that catches everyone. A language added after a
                        # cumulative update carries resources only up to the build
                        # its pack shipped with -- nothing fails, and the symptom
                        # is English strings in a translated menu on a shipped
                        # till. So the update goes in again afterwards.
                        Write-Host ''
                        Write-Host '   Microsoft requires the cumulative update to be re-applied after' -ForegroundColor DarkGray
                        Write-Host '   languages are added, or the new language stops at the build its' -ForegroundColor DarkGray
                        Write-Host '   pack shipped with. Leave blank and the run says what is owed.' -ForegroundColor DarkGray
                        $lcu = Read-WfValue 'Cumulative update .msu to re-apply (blank to skip)' ''

                        Invoke-WfMounted 'Add languages' {
                            $p = @{ Language = $pickedLangs; Confirm = $false }
                            if ($lcu) { $p['CumulativeUpdate'] = $lcu }
                            Add-WfLanguage @p
                        }.GetNewClosure() $script:WorkingImage -Index $script:WorkingIndex
                    }
                }
            }

            'region' {
                Show-Header 'Region -- one image, many countries'
                Write-Host '   A country is five settings that have to agree with each other:' -ForegroundColor DarkGray
                Write-Host '   formats, keyboard, home location, time zone and menus. Picked' -ForegroundColor DarkGray
                Write-Host '   together here so they cannot drift apart.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   The home location is the one nothing else can set. There is no' -ForegroundColor DarkGray
                Write-Host '   GeoID in unattend.xml, so an image configured only from an answer' -ForegroundColor DarkGray
                Write-Host '   file has Dutch terminals reporting themselves as American.' -ForegroundColor DarkGray
                Write-Host ''

                $presets = @(Get-WfRegionPreset)
                $presets | Format-Table Id, Country, UserLocale, InputLocale, GeoId, TimeZone, UILanguage -AutoSize | Out-Host

                $regionItems = @(
                    @{ Label = 'Set the region in an image';    Hint = 'The default a till comes up with when nothing else says otherwise.'; Key = 'apply' }
                    @{ Label = 'Region in an image';            Hint = 'What is baked in, and what a deployment recorded on top of it.';    Key = 'inimage' }
                    @{ Label = 'WinPE picker script';           Hint = 'A menu at deployment. Writes the answer; changes nothing itself.';   Key = 'pe' }
                    @{ Label = 'First-boot applier';            Hint = 'Reads the answer and applies it before anyone logs on.';             Key = 'firstboot' }
                    @{ Label = 'Answer file for one till';      Hint = 'For a terminal already in a shop with the wrong region on it.';      Key = 'answer' }
                ) | ForEach-Object { [pscustomobject]$_ }

                $regionChoice = Read-MenuChoice -Prompt '   Choose' -Items $regionItems
                if (-not $regionChoice) { continue menu }

                $regionPick = ConvertTo-WfPickItem -Source $presets -ValueProperty Id -LabelProperty Country

                switch ($regionChoice.Key) {
                    'apply' {
                        if (-not (Confirm-WfWorkingImage)) { continue menu }

                        $id = Read-WfPick -Prompt 'Country' -Items $regionPick
                        if (-not $id) { continue menu }

                        Write-Host ''
                        Write-Host '   Most estates want English menus with local formats -- the support' -ForegroundColor DarkGray
                        Write-Host '   notes are in English and the dates are not.' -ForegroundColor DarkGray
                        $english = Confirm-WfAction 'Keep the menus in English (en-US)?'

                        Invoke-WfMounted 'Region' {
                            $regionArgs = @{ Id = $id; Confirm = $false }
                            if ($english) { $regionArgs['UILanguage'] = 'en-US' }
                            Set-WfImageRegion @regionArgs
                        }.GetNewClosure() $script:WorkingImage -Index $script:WorkingIndex
                    }
                    'inimage' {
                        if (-not (Confirm-WfWorkingImage)) { continue menu }
                        Invoke-WfMounted 'Image region' {
                            Get-WfImageLocale | Out-Null
                            Get-WfRegionAnswer
                        } $script:WorkingImage -Index $script:WorkingIndex
                    }
                    'pe' {
                        Write-Host ''
                        Write-Host '   Offer only the countries this estate actually has. A menu with a' -ForegroundColor DarkGray
                        Write-Host '   wrong entry on it is a machine deployed wrong.' -ForegroundColor DarkGray

                        $offered = Read-WfPickMany -Prompt 'Countries on the WinPE menu' -Items @($presets | ForEach-Object {
                            [pscustomobject]@{ Label = ('{0,-6} {1,-20} {2}' -f $_.Id, $_.Country, $_.UserLocale)
                                               Value = $_.Id; Hint = '' } })
                        if (@($offered).Count -eq 0) { continue menu }

                        Write-Host ''
                        Write-Host '   Blank means no countdown: the script waits for an answer, which is' -ForegroundColor DarkGray
                        Write-Host '   wrong for a machine nobody is standing in front of.' -ForegroundColor DarkGray
                        $peDefault = Read-WfValue 'Country taken when the countdown runs out (blank for none)' ''
                        $peWait    = Read-WfValue 'Seconds to wait' '60'
                        $pePath    = Read-WfValue 'Write the script to' 'C:\Imaging\Pe\region.cmd'
                        if (-not $pePath) { continue menu }

                        Invoke-WfMenuAction 'WinPE region script' {
                            $peArgs = @{ Offer = $offered; Path = $pePath; Confirm = $false }
                            if ($peDefault) { $peArgs['DefaultId'] = $peDefault }
                            $seconds = 0
                            if ([int]::TryParse($peWait, [ref]$seconds) -and $seconds -gt 0) { $peArgs['TimeoutSeconds'] = $seconds }
                            New-WfRegionPeScript @peArgs
                        }.GetNewClosure()
                    }
                    'firstboot' {
                        if (-not (Confirm-WfWorkingImage)) { continue menu }

                        Write-Host ''
                        Write-Host '   Every country ticked here has its settings baked into the script,' -ForegroundColor DarkGray
                        Write-Host '   so a till never has to be told what a country means.' -ForegroundColor DarkGray

                        $fbOffer = Read-WfPickMany -Prompt 'Countries this image may be deployed to' -Items @($presets | ForEach-Object {
                            [pscustomobject]@{ Label = ('{0,-6} {1,-20} {2}' -f $_.Id, $_.Country, $_.UserLocale)
                                               Value = $_.Id; Hint = '' } })
                        if (@($fbOffer).Count -eq 0) { continue menu }

                        Write-Host ''
                        Write-Host '   The question cannot be asked during setup: SetupComplete runs as' -ForegroundColor DarkGray
                        Write-Host '   SYSTEM with no desktop, and anything waiting for input there hangs' -ForegroundColor DarkGray
                        Write-Host '   the machine with a blank screen. So it appears at the first logon.' -ForegroundColor DarkGray
                        $fbAsk = Confirm-WfAction 'Ask at the first logon when the deployment recorded nothing?'

                        $fbDefault = ''
                        $fbWait    = '60'
                        if ($fbAsk) {
                            Write-Host ''
                            Write-Host '   Blank takes whatever Set-WfImageRegion recorded in the image.' -ForegroundColor DarkGray
                            $fbDefault = Read-WfValue 'Pre-selected country (blank to use the image default)' ''
                            $fbWait    = Read-WfValue 'Seconds before the countdown takes it' '60'
                        }

                        Invoke-WfMounted 'First-boot region' {
                            $fbArgs = @{ Offer = $fbOffer; Confirm = $false }
                            if ($fbAsk)     { $fbArgs['Ask'] = $true }
                            if ($fbDefault) { $fbArgs['DefaultId'] = $fbDefault }
                            $seconds = 0
                            if ([int]::TryParse($fbWait, [ref]$seconds) -and $seconds -gt 0) { $fbArgs['TimeoutSeconds'] = $seconds }
                            New-WfRegionFirstBoot @fbArgs
                        }.GetNewClosure() $script:WorkingImage -Index $script:WorkingIndex
                    }
                    'answer' {
                        $id = Read-WfPick -Prompt 'Country' -Items $regionPick
                        if (-not $id) { continue menu }

                        $english  = Confirm-WfAction 'Keep the menus in English (en-US)?'
                        $xmlPath  = Read-WfValue 'Write the answer file to' ("C:\Imaging\region-{0}.xml" -f $id)
                        if (-not $xmlPath) { continue menu }

                        Invoke-WfMenuAction 'Region answer file' {
                            $xmlArgs = @{ Id = $id }
                            if ($english) { $xmlArgs['UILanguage'] = 'en-US' }
                            $xml = Get-WfRegionAnswerXml @xmlArgs
                            Set-Content -LiteralPath $xmlPath -Value $xml -Encoding UTF8
                            Write-WfLog "Written to $xmlPath" -Level OK
                            Write-WfLog ('On the terminal, as an administrator: control.exe intl.cpl,,/f:"{0}"' -f $xmlPath) -Level INFO
                            Write-WfLog '  Then set the time zone with tzutil, and restart -- the system locale and the logon screen only follow after a reboot.' -Level INFO
                            [pscustomobject]@{ Id = $id; Path = $xmlPath }
                        }.GetNewClosure()
                    }
                }
            }

            'oem' {
                Show-Header 'OEM support information'
                Write-Host '   Shows in System properties. Worth more than it looks on an estate' -ForegroundColor DarkGray
                Write-Host '   somebody else supports: it saves a call being routed three times.' -ForegroundColor DarkGray
                Write-Host ''

                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                $man   = Read-WfValue 'Manufacturer'  ''
                $mod   = Read-WfValue 'Model'         ''
                $phone = Read-WfValue 'Support phone' ''
                $url   = Read-WfValue 'Support URL'   ''
                $hours = Read-WfValue 'Support hours' ''
                $logo  = Read-WfValue 'Logo path as the terminal sees it (120x120 bmp)' ''

                if (-not ($man -or $mod -or $phone -or $url -or $hours -or $logo)) { continue menu }

                Invoke-WfMounted 'OEM information' {
                    Set-WfOemInformation -Manufacturer $man -Model $mod -SupportPhone $phone `
                                         -SupportUrl $url -SupportHours $hours -Logo $logo -Confirm:$false
                }.GetNewClosure() $src -Index $idx
            }

            'policy' {
                Show-Header 'Local group policy'
                Write-Host '   Copies a prepared Registry.pol into the image. Group Policy processes' -ForegroundColor DarkGray
                Write-Host '   it at boot, so the settings apply on a machine that has never seen a' -ForegroundColor DarkGray
                Write-Host '   domain -- which is a terminal at a third-party site.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Make one by setting what you want in gpedit.msc on a reference machine' -ForegroundColor DarkGray
                Write-Host '   and taking \Windows\System32\GroupPolicy\Machine\Registry.pol from it.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Replaced, not merged. Whatever is in the image now is gone.' -ForegroundColor Yellow
                Write-Host ''

                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                $machinePol = Read-WfValue 'Computer policy .pol (blank to skip)' ''
                $userPol    = Read-WfValue 'User policy .pol (blank to skip)'     ''
                if (-not $machinePol -and -not $userPol) { continue menu }

                Invoke-WfMounted 'Local group policy' {
                    Set-WfLocalPolicy -MachinePolicy $machinePol -UserPolicy $userPol -Confirm:$false
                }.GetNewClosure() $src -Index $idx
            }

            'slim' {
                Show-Header 'Slim the image down'
                Write-Host '   Nothing here has a "remove everything unnecessary" option, because' -ForegroundColor DarkGray
                Write-Host '   nothing can know what is unnecessary on your estate. List first,' -ForegroundColor DarkGray
                Write-Host '   then name what goes.' -ForegroundColor DarkGray
                Write-Host ''

                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                $what = @(
                    @{ Label = 'List provisioned apps';   Hint = 'Installed for every new user. Few on LTSC, dozens otherwise.'; Key = 'listapp' }
                    @{ Label = 'Remove provisioned apps'; Hint = 'By name or wildcard. Load-bearing ones are refused.';          Key = 'delapp' }
                    @{ Label = 'List capabilities';       Hint = 'WordPad, Media Player, RSAT and friends.';                      Key = 'listcap' }
                    @{ Label = 'Remove capabilities';     Hint = 'By name or wildcard.';                                          Key = 'delcap' }
                    @{ Label = 'Disable features';        Hint = 'Add -Remove to take the payload out as well.';                   Key = 'delfeat' }
                ) | ForEach-Object { [pscustomobject]$_ }

                $pick = Read-MenuChoice -Prompt '   Which' -Items $what
                if (-not $pick) { continue menu }

                switch ($pick.Key) {
                    'listapp' {
                        # Uses the open image when there is one and never closes it; asks
                        # first when there is not, because opening costs minutes and that is
                        # the operator's decision, not a side effect of a read button.
                        $mountChoice = Confirm-WfMountNeeded 'Listing the provisioned apps'
                        if ($mountChoice -eq 'no') { continue menu }
                        if ($mountChoice -eq 'keep' -and -not (Get-WfCurrentMount)) {
                            # Opened here so the call below finds it open and leaves it open.
                            Invoke-WfMenuAction 'Open the image' {
                                Mount-WfImage -ImagePath $src -Index $idx -ReadOnly
                            }.GetNewClosure()
                        }

                        Invoke-WfMenuAction 'Provisioned apps' {
                            Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfProvisionedApp }
                        }.GetNewClosure()
                    }
                    'delapp' {
                        $names = Read-WfValue 'Names or wildcards, comma separated' ''
                        if (-not $names) { continue menu }
                        $force = (Read-WfValue 'Also remove the load-bearing ones? (y/N)' 'N') -match '^[Yy]'
                        $list  = @($names -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                        Invoke-WfMounted 'Remove provisioned apps' {
                            Remove-WfProvisionedApp -Name $list -Force:$force -Confirm:$false
                        }.GetNewClosure() $src -Index $idx
                    }
                    'listcap' {
                        # Uses the open image when there is one and never closes it; asks
                        # first when there is not, because opening costs minutes and that is
                        # the operator's decision, not a side effect of a read button.
                        $mountChoice = Confirm-WfMountNeeded 'Listing the capabilities'
                        if ($mountChoice -eq 'no') { continue menu }
                        if ($mountChoice -eq 'keep' -and -not (Get-WfCurrentMount)) {
                            # Opened here so the call below finds it open and leaves it open.
                            Invoke-WfMenuAction 'Open the image' {
                                Mount-WfImage -ImagePath $src -Index $idx -ReadOnly
                            }.GetNewClosure()
                        }

                        Invoke-WfMenuAction 'Capabilities' {
                            Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfImageCapability }
                        }.GetNewClosure()
                    }
                    'delcap' {
                        $names = Read-WfValue 'Capability names or wildcards, comma separated' ''
                        if (-not $names) { continue menu }
                        $list = @($names -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                        Invoke-WfMounted 'Remove capabilities' {
                            Remove-WfImageCapability -Name $list -Confirm:$false
                        }.GetNewClosure() $src -Index $idx
                    }
                    'delfeat' {
                        $names = Read-WfValue 'Feature names or wildcards, comma separated' ''
                        if (-not $names) { continue menu }
                        Write-Host ''
                        Write-Host '   Removing the payload saves real space but means turning the' -ForegroundColor DarkGray
                        Write-Host '   feature back on later needs a source.' -ForegroundColor DarkGray
                        $strip = (Read-WfValue 'Remove the payload too? (y/N)' 'N') -match '^[Yy]'
                        $list  = @($names -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                        Invoke-WfMounted 'Disable features' {
                            Disable-WfImageFeature -Name $list -Remove:$strip -Confirm:$false
                        }.GetNewClosure() $src -Index $idx
                    }
                }
            }

            'winre' {
                Show-Header 'Drivers into the recovery image'
                Write-Host '   Winre.wim is a second WinPE living inside the installed image, and it' -ForegroundColor DarkGray
                Write-Host '   is what runs when a terminal will not boot. It gets none of the drivers' -ForegroundColor DarkGray
                Write-Host '   injected into the image around it.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   So on a machine whose storage controller needs a driver, recovery comes' -ForegroundColor DarkGray
                Write-Host '   up with no disk to reset and no network to reach a share -- which you' -ForegroundColor DarkGray
                Write-Host '   find out on the day you need it.' -ForegroundColor DarkGray
                Write-Host ''

                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                $models = Select-WfModel
                Invoke-WfMounted 'Recovery drivers' {
                    Add-WfRecoveryDriver -Models $models -DriverRoot (Get-WfMenuDriverRoot)
                }.GetNewClosure() $src -Index $idx
            }

            'recovery' {
                Show-Header 'Recovery and reset'
                Write-Host '   Before anything else, the finding that decides how this works:' -ForegroundColor Yellow
                Write-Host ''
                Write-Host '   reagentc /setosimage -- the command that registers a custom OS image' -ForegroundColor DarkGray
                Write-Host '   for Reset this PC -- is documented as "not used in Windows 10 or' -ForegroundColor DarkGray
                Write-Host '   later". It still exists and still appears to work. It does nothing.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   So there are two honest routes, and they answer different questions:' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '     Reset this PC   rebuilds Windows from the machine, then re-applies' -ForegroundColor DarkGray
                Write-Host '                     your provisioning packages and runs your scripts.' -ForegroundColor DarkGray
                Write-Host '                     Built into the image, nothing extra on the disk.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '     Boot menu       the WIM itself on a partition, and an entry that' -ForegroundColor DarkGray
                Write-Host '                     boots WinPE and applies it. Exactly the image that' -ForegroundColor DarkGray
                Write-Host '                     left the workshop, every time. Needs the partition.' -ForegroundColor DarkGray
                Write-Host ''

                $steps = @(
                    @{ Label = 'What is configured now?';         Hint = 'reagentc /info, against the image or this machine.';                Key = 'status' }
                    @{ Label = 'Register a recovery image';       Hint = 'reagentc /setreimage -- after servicing winre.wim.';                Key = 'setre' }
                    @{ Label = 'Scripts to run during a reset';   Hint = 'ResetConfig.xml. Four defined points in Reset this PC.';            Key = 'resetcfg' }
                    @{ Label = 'Packages to re-apply on reset';   Hint = 'Provisioning packages into \Recovery\Customizations.';              Key = 'ppkg' }
                    @{ Label = 'Prepare the recovery WinPE';      Hint = 'Makes a boot.wim that finds the payload and applies it.';           Key = 'pe' }
                    @{ Label = 'Add the boot menu entry';         Hint = 'Stages the WIM on a partition at first boot and adds the entry.';   Key = 'entry' }
                ) | ForEach-Object { [pscustomobject]$_ }

                $step = Read-MenuChoice -Prompt '   Which' -Items $steps
                if (-not $step) { continue menu }

                # The WinPE preparation is the only one here that works on a
                # boot.wim rather than on the working image, so it does not need
                # one selected.
                if ($step.Key -ne 'pe') {
                    if (-not (Confirm-WfWorkingImage)) { continue menu }
                }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                switch ($step.Key) {
                    'status' {
                        # Uses the open image when there is one and never closes it; asks
                        # first when there is not, because opening costs minutes and that is
                        # the operator's decision, not a side effect of a read button.
                        $mountChoice = Confirm-WfMountNeeded 'Reading the recovery configuration'
                        if ($mountChoice -eq 'no') { continue menu }
                        if ($mountChoice -eq 'keep' -and -not (Get-WfCurrentMount)) {
                            # Opened here so the call below finds it open and leaves it open.
                            Invoke-WfMenuAction 'Open the image' {
                                Mount-WfImage -ImagePath $src -Index $idx -ReadOnly
                            }.GetNewClosure()
                        }

                        Invoke-WfMenuAction 'Recovery configuration' {
                            Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfRecoveryStatus }
                        }.GetNewClosure()
                    }
                    'setre' {
                        Show-Header 'Register a recovery image'
                        Write-Host '   This is the path as the TERMINAL will see it, not as this machine' -ForegroundColor DarkGray
                        Write-Host '   sees it, and it is the folder holding winre.wim rather than the' -ForegroundColor DarkGray
                        Write-Host '   file itself.' -ForegroundColor DarkGray
                        $path = Read-WfValue 'Folder holding winre.wim on the terminal' 'R:\Recovery\WindowsRE'
                        if (-not $path) { continue menu }
                        Invoke-WfMounted 'Register recovery image' {
                            Set-WfRecoveryImage -Path $path -Confirm:$false
                        }.GetNewClosure() $src -Index $idx
                    }
                    'resetcfg' {
                        Show-Header 'Scripts to run during a reset'
                        Write-Host '   Four points, and only one of them usually matters: the script that' -ForegroundColor DarkGray
                        Write-Host '   runs after a full wipe has laid Windows back down, which is where' -ForegroundColor DarkGray
                        Write-Host '   the till application gets put back.' -ForegroundColor DarkGray
                        Write-Host ''
                        $folder = Read-WfValue 'Folder of scripts to copy into \Recovery\OEM' ''
                        if (-not $folder) { continue menu }

                        $phases = @(
                            @{ Value = 'FactoryReset_AfterImageApply';  Label = 'FactoryReset_AfterImageApply';  Hint = 'after a full wipe and reinstall -- the usual one' }
                            @{ Value = 'FactoryReset_AfterDiskFormat';  Label = 'FactoryReset_AfterDiskFormat';  Hint = 'after the disk is wiped, before Windows goes down' }
                            @{ Value = 'BasicReset_AfterImageApply';    Label = 'BasicReset_AfterImageApply';    Hint = 'after a keep-my-files reset' }
                            @{ Value = 'BasicReset_BeforeImageApply';   Label = 'BasicReset_BeforeImageApply';   Hint = 'before a keep-my-files reset starts' }
                        ) | ForEach-Object { [pscustomobject]$_ }

                        $chosen = @(Read-WfPickMany -Prompt 'Phases to hook' -Items $phases `
                                                    -Default @('FactoryReset_AfterImageApply'))
                        if ($chosen.Count -eq 0) { continue menu }

                        $scripts = New-Object System.Collections.Generic.List[object]
                        foreach ($p in $chosen) {
                            $rel = Read-WfValue "Script for $p (relative to that folder)" ''
                            if ($rel) { $scripts.Add(@{ Phase = $p; Path = $rel; Duration = 5 }) }
                        }
                        if ($scripts.Count -eq 0) { continue menu }
                        $list = $scripts.ToArray()

                        Invoke-WfMounted 'Reset configuration' {
                            Set-WfResetConfig -Script $list -ScriptSource $folder -Confirm:$false
                        }.GetNewClosure() $src -Index $idx
                    }
                    'ppkg' {
                        Show-Header 'Packages to re-apply on reset'
                        Write-Host '   Anything in \Recovery\Customizations is re-applied after a reset has' -ForegroundColor DarkGray
                        Write-Host '   rebuilt Windows. This is the modern answer to "reset should bring' -ForegroundColor DarkGray
                        Write-Host '   our image back" -- it gets to the same place from the other side.' -ForegroundColor DarkGray
                        $raw = Read-WfValue 'Provisioning packages (.ppkg, comma separated)' ''
                        if (-not $raw) { continue menu }
                        $pkgs = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                        Invoke-WfMounted 'Reset customizations' {
                            Add-WfResetCustomization -Package $pkgs -Confirm:$false
                        }.GetNewClosure() $src -Index $idx
                    }
                    'pe' {
                        Show-Header 'Prepare the recovery WinPE'
                        Write-Host '   Takes a WinPE boot.wim and writes a startnet.cmd into it that finds' -ForegroundColor DarkGray
                        Write-Host '   the payload, asks once, and applies it. The boot.wim is modified in' -ForegroundColor DarkGray
                        Write-Host '   place, so work on a copy.' -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host '   Put the storage and network drivers in FIRST, with the boot image' -ForegroundColor Yellow
                        Write-Host '   drivers option. Recovery that cannot see the disk does nothing.' -ForegroundColor Yellow
                        Write-Host ''
                        $pe  = Read-WfValue 'WinPE boot.wim to prepare' ''
                        if (-not $pe) { continue menu }
                        $wim = Read-WfValue 'Factory image file name (as it will be on the partition)' 'Plus-POS.wim'
                        $ai  = Read-WfInt  'Index of it to apply' 1
                        $lbl = Read-WfValue 'Label of the volume it restores ONTO' 'OSDisk'
                        $un  = (Read-WfValue 'Restore without asking? Dangerous. (y/N)' 'N') -match '^[Yy]'
                        if ($un -and -not (Confirm-WfAction 'A terminal that boots that entry by accident loses everything on it. Sure?')) { continue menu }

                        Invoke-WfMenuAction 'Recovery WinPE' {
                            New-WfRecoveryBootImage -BootImage $pe -ImageFile $wim -ApplyIndex $ai `
                                                    -TargetLabel $lbl -Unattended:$un -Confirm:$false
                        }.GetNewClosure()
                    }
                    'entry' {
                        Show-Header 'Add the boot menu entry'
                        Write-Host '   An image has no partitions and no BCD, so this cannot be done here.' -ForegroundColor DarkGray
                        Write-Host '   What goes into the image is a script that does it on the terminal at' -ForegroundColor DarkGray
                        Write-Host '   first boot -- the same seam the lockdown configuration uses.' -ForegroundColor DarkGray
                        Write-Host ''
                        Write-Host '   The payload cannot live on the volume it restores. A restore that' -ForegroundColor Yellow
                        Write-Host '   formats C: destroys the WIM it is applying halfway through. This' -ForegroundColor Yellow
                        Write-Host '   needs its own partition, sized for the image when the disk is laid' -ForegroundColor Yellow
                        Write-Host '   out -- a stock 500MB recovery partition will not hold a POS image.' -ForegroundColor Yellow
                        Write-Host ''
                        $tgt = Read-WfValue 'Label of the partition to stage the payload on' 'WFRECOVERY'
                        $rst = Read-WfValue 'Label of the partition it restores onto'        'OSDisk'
                        $wim = Read-WfValue 'Factory image file name'                        'Plus-POS.wim'
                        $pe  = Read-WfValue 'Prepared WinPE file name'                       'boot.wim'
                        $fld = Read-WfValue 'Folder for the payload, on the media and the partition' 'Recovery\WimForge'
                        $dsc = Read-WfValue 'What the boot menu entry is called' 'Restore the factory image'
                        $to  = Read-WfInt   'Boot menu timeout in seconds (0 leaves it alone)' 10

                        Invoke-WfMounted 'Recovery first boot' {
                            New-WfRecoveryFirstBoot -TargetLabel $tgt -RestoreLabel $rst -ImageFile $wim `
                                                    -BootImageFile $pe -PayloadFolder $fld -Description $dsc `
                                                    -Timeout $to -Append -Confirm:$false
                        }.GetNewClosure() $src -Index $idx
                    }
                }
            }

            'firstboot' {
                Show-Header 'First-boot script'
                Write-Host '   SetupComplete.cmd runs once, as SYSTEM, after setup and before the' -ForegroundColor DarkGray
                Write-Host '   first logon. It has no desktop -- anything that waits for input hangs' -ForegroundColor DarkGray
                Write-Host '   the machine with nothing on screen. Windows deletes it afterwards, so' -ForegroundColor DarkGray
                Write-Host '   the log it writes is the only record.' -ForegroundColor DarkGray
                Write-Host ''

                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                $file = Read-WfValue 'Script to run (.ps1 or .cmd, blank for none)' ''
                $cmd  = Read-WfValue 'Or a single command line (blank for none)' ''
                if (-not $file -and -not $cmd) { continue menu }

                $log    = Read-WfValue 'Log path on the terminal' 'C:\Windows\Temp\WimForge-FirstBoot.log'
                $append = (Read-WfValue 'Add to an existing SetupComplete.cmd? (y/N)' 'N') -match '^[Yy]'

                $cmdList = @()
                if ($cmd) { $cmdList = @($cmd) }

                Invoke-WfMounted 'First-boot script' {
                    Set-WfFirstBootScript -ScriptFile $file -Command $cmdList -LogPath $log `
                                          -Append:$append -Confirm:$false
                }.GetNewClosure() $src -Index $idx
            }
        }
    }
}

function Show-BuildMenu {
    :menu while ($true) {
        Show-Header 'Build operations'
        $items = @(
            @{ Label = 'Capture a new base image';   Hint = 'From a sysprepped reference VM VHDX, or a drive letter in WinPE.'; Key = 'capture' }
            @{ Label = 'Build a USB deployment stick'; Hint = 'ERASES the target disk. FAT32 boot + NTFS images.';              Key = 'usb' }
            @{ Label = 'Validate this machine';      Hint = 'Run on a freshly imaged terminal.';                                Key = 'validate' }
            @{ Label = 'Reference image from clean media'; Hint = 'Servicing stack, languages, features, cumulative LAST. Takes hours.'; Key = 'reference' }
            @{ Label = 'Refresh Setup on the media'; Hint = 'The step that stops Setup failing after boot.wim has been serviced.'; Key = 'mediasetup' }
        ) | ForEach-Object { [pscustomobject]$_ }

        $choice = Read-MenuChoice -Prompt '   Choose' -Items $items
        if (-not $choice) { return }

        switch ($choice.Key) {
            'capture' {
                Show-Header 'Capture a base image'
                $vhdx  = Read-WfValue 'Reference VM VHDX (blank to capture a drive letter instead)' ''
                $notes = Read-WfValue 'Notes' ''
                if ($vhdx) {
                    Invoke-WfMenuAction 'Capture base image' {
                        New-WfCapture -VhdxPath $vhdx -Notes $notes
                    }.GetNewClosure()
                }
                else {
                    $drive = Read-WfValue 'Source drive' 'C:'
                    Invoke-WfMenuAction 'Capture base image' {
                        New-WfCapture -SourceDrive $drive -Notes $notes
                    }.GetNewClosure()
                }
            }
            'usb' {
                Show-Header 'Build USB deployment media'
                Write-Host '   Removable disks:' -ForegroundColor Cyan
                Get-Disk | Where-Object { $_.BusType -eq 'USB' } |
                    Format-Table Number, FriendlyName, @{n='GB';e={[math]::Round($_.Size/1GB,1)}} -AutoSize | Out-Host

                $num = Read-WfValue 'Disk number' ''
                $pe  = Read-WfValue 'WinPE media folder (from copype)' 'C:\WinPE_amd64'
                $img = Select-WfImage -Prompt 'Which image goes on the stick?' -Default $script:WorkingImage
                if (-not $img) { continue menu }   # cancelled

                if ($num -and (Confirm-WfAction "This ERASES disk $num completely. Continue?")) {
                    Invoke-WfMenuAction 'Build USB media' {
                        New-WfUsbMedia -DiskNumber ([int]$num) -PeMediaPath $pe -ImagePath $img -Confirm:$false
                    }.GetNewClosure()
                }
            }
            'validate' {
                Show-Header 'Validate this machine'
                $pattern = Read-WfValue 'Expected hostname pattern (regex), blank to skip' ''
                $report  = Read-WfValue 'Write report to (blank for none)' ''
                Invoke-WfMenuAction 'Validate this machine' {
                    Test-WfDeployedMachine -ExpectedHostnamePattern $pattern -ReportPath $report
                }.GetNewClosure()
            }
            'reference' {
                Show-Header 'Reference image from clean media'
                Write-Host '   The alternative to re-servicing last month''s output. Re-servicing' -ForegroundColor DarkGray
                Write-Host '   accumulates state: every language pack and feature stays at whatever' -ForegroundColor DarkGray
                Write-Host '   level it went in, and eventually a cumulative arrives that cannot' -ForegroundColor DarkGray
                Write-Host '   reconcile them. Building from clean media has no such history.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Servicing stack, then languages, then features, then the cumulative' -ForegroundColor DarkGray
                Write-Host '   update LAST -- across winre.wim, boot.wim and install.wim.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   This takes hours and it writes to the media folder. Work on a copy of' -ForegroundColor Yellow
                Write-Host '   the extracted media, not on the only one you have.' -ForegroundColor Yellow
                Write-Host ''

                $refMediaPath = Read-WfValue 'Extracted media folder (holds \sources)' ''
                if (-not $refMediaPath) { continue menu }
                $refLcuPath = Read-WfValue 'Cumulative update .msu' ''
                if (-not $refLcuPath) { continue menu }

                $refFodPath = Read-WfValue 'Features on Demand ISO (blank to skip)' ''
                $refCapRaw  = Read-WfValue 'Capabilities, comma separated (blank for none)' ''
                $refIdxRaw  = Read-WfValue 'install.wim indexes, comma separated (blank for all)' ''
                $refOutPath = Read-WfValue 'Output .wim (blank for the default)' ''
                $refNotes   = Read-WfValue 'Notes' ''
                $refKeepUn  = Confirm-WfAction 'Leave the updates uninstallable (skip /ResetBase)?'

                $refCaps = @($refCapRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $refIdx  = @()
                foreach ($part in @($refIdxRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                    $n = 0
                    if ([int]::TryParse($part, [ref]$n)) { $refIdx += $n }
                }

                if (-not (Confirm-WfAction 'Start the build?')) { continue menu }

                Invoke-WfMenuAction 'Reference image' {
                    $refArgs = @{ MediaPath = $refMediaPath; LcuPath = $refLcuPath }
                    if ($refFodPath)      { $refArgs['FodSource']     = $refFodPath }
                    if ($refCaps.Count)   { $refArgs['Capability']    = $refCaps }
                    if ($refIdx.Count)    { $refArgs['Index']         = $refIdx }
                    if ($refOutPath)      { $refArgs['OutputPath']    = $refOutPath }
                    if ($refKeepUn)       { $refArgs['KeepUninstall'] = $true }
                    if ($refNotes)        { $refArgs['Notes']         = $refNotes }
                    New-WfReferenceImage @refArgs
                }.GetNewClosure()
            }
            'mediasetup' {
                Show-Header 'Refresh Setup on the media'
                Write-Host '   Windows Setup exists twice: once on the media at \sources\setup.exe' -ForegroundColor DarkGray
                Write-Host '   and once inside boot.wim. Servicing boot.wim moves its copy forward' -ForegroundColor DarkGray
                Write-Host '   and leaves the media behind, and Microsoft is blunt about what that' -ForegroundColor DarkGray
                Write-Host '   produces: "if these binaries aren''t identical, Windows Setup will' -ForegroundColor DarkGray
                Write-Host '   fail during installation."' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Nothing about the media looks wrong without this step, which is why' -ForegroundColor Yellow
                Write-Host '   it is the one that gets left out.' -ForegroundColor Yellow
                Write-Host ''

                $mediaPath = Read-WfValue 'Extracted media folder' ''
                if (-not $mediaPath) { continue menu }

                Write-Host ''
                Write-Host '   Blank just reports which index of boot.wim carries Setup, and stops.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   A Setup Dynamic Update has to be expanded BEFORE the copy, not after:' -ForegroundColor DarkGray
                Write-Host '   the package can carry its own setup.exe, so expanding it afterwards' -ForegroundColor DarkGray
                Write-Host '   would put the older binary straight back.' -ForegroundColor DarkGray
                $mediaDu = Read-WfValue 'Setup Dynamic Update .cab (blank for none)' ''

                if (-not (Confirm-WfAction 'Refresh the Setup binaries on this media?')) {
                    Invoke-WfMenuAction 'Setup index' {
                        Get-WfMediaSetupIndex -BootImagePath (Join-Path $mediaPath 'sources\boot.wim')
                    }.GetNewClosure()
                    continue menu
                }

                Invoke-WfMenuAction 'Media Setup refresh' {
                    $mediaArgs = @{ MediaPath = $mediaPath; Confirm = $false }
                    if ($mediaDu) { $mediaArgs['SetupDynamicUpdate'] = $mediaDu }
                    Update-WfMediaSetupFile @mediaArgs
                }.GetNewClosure()
            }
        }
    }
}

function Show-WfTargetSummary {
    <#
        Prints what was read off an image. Kept out of the menu body because the
        menu header and the detect action both want it, and because writing to
        $script: from inside a closure silently does nothing.
    #>
    param([Parameter(Mandatory)] $Target)

    Write-Host ''
    Write-Host ('   Product      : {0} {1}' -f $Target.Product, $Target.Architecture) -ForegroundColor Cyan
    if ($Target.ImageName) { Write-Host ('   Image        : {0}' -f $Target.ImageName) }
    if ($Target.FullBuild) { Write-Host ('   Build        : {0}' -f $Target.FullBuild) }
    if ($Target.EditionId) {
        $ed = $Target.EditionId
        if ($Target.IsLtsc) { $ed = "$ed (LTSC)" }
        Write-Host ('   Edition      : {0}' -f $ed)
    }
    if ($Target.ProductAlternative -and @($Target.ProductAlternative).Count -gt 0) {
        Write-Host ('   Also tries   : {0}' -f (@($Target.ProductAlternative) -join ', ')) -ForegroundColor DarkGray
    }
    if ($Target.PackageCount) {
        Write-Host ('   Installed    : {0} packages, {1} with a KB number' -f `
            $Target.PackageCount, @($Target.InstalledKB).Count) -ForegroundColor DarkGray

        # The KBs themselves, not just how many. This is the answer to "what is
        # already in this WIM" and having counted them without showing them is
        # the sort of thing that sends somebody to a mounted image with
        # Get-WindowsPackage to find out what the tool already knew.
        $kbs = @($Target.InstalledKB | Sort-Object -Unique)
        if ($kbs.Count -gt 0) {
            $line = '   Already in   : '
            $shown = @($kbs | Select-Object -First 12)
            Write-Host ($line + ($shown -join ', ')) -ForegroundColor DarkGray
            if ($kbs.Count -gt $shown.Count) {
                Write-Host ('                  ... and {0} more' -f ($kbs.Count - $shown.Count)) -ForegroundColor DarkGray
            }
        }
    }
    elseif ($null -ne $Target.PSObject.Properties['PackageCount']) {
        Write-Host '   Installed    : not listed -- that needs a mount, so search results will' -ForegroundColor DarkGray
        Write-Host '                  show "?" rather than whether they are already applied' -ForegroundColor DarkGray
    }

    $srcColour = 'DarkGray'
    if (-not $Target.Precise) { $srcColour = 'Yellow' }
    Write-Host ('   Read from    : {0}' -f $Target.Source) -ForegroundColor $srcColour

    foreach ($n in @($Target.Notes)) {
        Write-Host "   ! $n" -ForegroundColor Yellow
    }
    Write-Host ''
}

function Show-UpdatesMenu {
    :menu while ($true) {
        Show-Header 'Updates'

        $cfg    = $script:Config
        $target = $script:UpdateTarget

        if ($target) {
            $line = $target.Product
            if ($target.FullBuild) { $line = "$line  (image is at $($target.FullBuild))" }
            Write-Host ("   Catalog search : {0} {1}" -f $line, $target.Architecture) -ForegroundColor Cyan
            $from = Split-Path $target.ImagePath -Leaf
            if (-not $from) { $from = 'the mounted image' }
            $how = 'read from the image'
            if (-not $target.Precise) { $how = 'guessed from the WIM header -- not exact' }
            Write-Host ("                    {0}, {1}" -f $from, $how) -ForegroundColor DarkGray
        }
        else {
            Write-Host ("   Catalog search : {0} {1}" -f $cfg['UpdateProduct'], $cfg['UpdateArchitecture']) -ForegroundColor DarkGray
            Write-Host '                    typed in, not read from an image' -ForegroundColor DarkGray
        }
        Write-Host ("   Updates folder : {0}" -f $cfg['UpdateRoot']) -ForegroundColor DarkGray

        # What is already staged matters more than what is available: everything
        # in that folder gets applied by the next servicing run.
        try {
            $have = @(Get-WfUpdateFolder)
            if ($have.Count -eq 0) {
                Write-Host '   Nothing downloaded yet.' -ForegroundColor Yellow
            }
            else {
                Write-Host ''
                Write-Host '   Ready to be applied by the next servicing run:' -ForegroundColor Cyan
                foreach ($u in $have) {
                    Write-Host ('     {0,-11} {1,8:N1} MB  {2}  {3}' -f `
                        $u.KB, $u.SizeMB, $u.Modified.ToString('yyyy-MM-dd'), $u.File)
                }
            }
        }
        catch { Write-Host "   Could not read the Updates folder: $($_.Exception.Message)" -ForegroundColor Yellow }
        Write-Host ''

        $items = @(
            @{ Label = 'Read the target from an image'; Hint = 'Works out product, release and architecture from the image itself.'; Key = 'detect' }
            @{ Label = 'Search the catalog';        Hint = 'Pick a category or type a query, then choose what to download.'; Key = 'search' }
            @{ Label = 'Get the latest cumulative'; Hint = 'One step: newest match for the current product, downloaded.';    Key = 'latest' }
            @{ Label = 'Show the Updates folder';   Hint = 'What a servicing run would apply, in the order it applies it.';   Key = 'folder' }
            @{ Label = 'Remove a downloaded update';Hint = 'Clear out last month before servicing again.';                    Key = 'remove' }
            @{ Label = 'Search settings';           Hint = 'Product and architecture used to build the search.';              Key = 'settings' }
        ) | ForEach-Object { [pscustomobject]$_ }

        $choice = Read-MenuChoice -Prompt '   Choose' -Items $items
        if (-not $choice) { return }

        switch ($choice.Key) {

            'detect' {
                Show-Header 'Read the target from an image'
                Write-Host '   Which Windows an image is cannot be read from the WIM header alone:' -ForegroundColor DarkGray
                Write-Host '   DISM reports version 10.0.19041 for every image in that family, so 2004' -ForegroundColor DarkGray
                Write-Host '   and 21H2 look identical there. The release only exists in the image''s' -ForegroundColor DarkGray
                Write-Host '   registry -- pulled straight out of the .wim, without mounting it.' -ForegroundColor DarkGray
                Write-Host ''

                $sources = @(
                    @{ Label = 'The working image';       Hint = 'Whatever is chosen on the main menu.';                       Key = 'working' }
                    @{ Label = 'Whatever is mounted now'; Hint = 'Free and instant if an image is mounted.';                   Key = 'mounted' }
                    @{ Label = 'A different image file';  Hint = 'Reads that one without changing what you are working on.';   Key = 'file' }
                ) | ForEach-Object { [pscustomobject]$_ }

                $src = Read-MenuChoice -Prompt '   Read from' -Items $sources
                if (-not $src) { continue menu }

                $path = ''
                $idx  = 1
                if ($src.Key -eq 'working') {
                    if (-not (Confirm-WfWorkingImage)) { continue menu }
                    $path = $script:WorkingImage
                    $idx  = $script:WorkingIndex
                }
                elseif ($src.Key -eq 'file') {
                    $path = Select-WfImage -Prompt 'Which image' -Default $script:WorkingImage
                    if (-not $path) { continue menu }
                    $picked = Select-WfIndex -ImagePath $path
                    if ($null -eq $picked) { continue menu }
                    $idx = $picked
                }

                Write-Host ''
                Write-Host '   That read takes seconds. Listing the updates ALREADY in the image is' -ForegroundColor DarkGray
                Write-Host '   the one thing that needs a mount, so it costs a minute or two -- and' -ForegroundColor DarkGray
                Write-Host '   it lets search results be marked as already applied.' -ForegroundColor DarkGray
                $withPackages = (Read-WfValue 'Also list what is already installed? (y/N)' 'N') -match '^[Yy]'
                $nomount = $false

                Show-Header 'Read the target from an image'
                Write-Host '   Reading...' -ForegroundColor Cyan

                # Deliberately not inside Invoke-WfMenuAction: this has to write
                # $script:UpdateTarget, and a closure cannot -- the assignment
                # lands in the closure's own scope and is thrown away.
                $found = $null
                try {
                    $found = Get-WfImageUpdateTarget -ImagePath $path -Index $idx `
                                                     -IncludePackage:$withPackages -NoMount:$nomount
                }
                catch {
                    Write-Host ''
                    Write-Host "   FAILED: $($_.Exception.Message)" -ForegroundColor Red
                    if ($_.Exception.Message -match 'NEEDS ELEVATION') {
                        Write-Host '   Restart elevated from Housekeeping to mount images.' -ForegroundColor Yellow
                    }
                    Write-Host ''
                    Read-Host '   Press Enter to continue' | Out-Null
                    continue menu
                }

                $script:UpdateTarget = $found
                Show-WfTargetSummary $found

                Write-Host '   Searches from here on use this until you leave the menu.' -ForegroundColor DarkGray
                Write-Host ''
                if ((Read-WfValue 'Also save it as the stored default? (y/N)' 'N') -match '^[Yy]') {
                    $script:Config = Set-WfConfig -Confirm:$false -Settings @{
                        UpdateProduct      = $found.Product
                        UpdateArchitecture = $found.Architecture
                    }
                    Write-Host '   Saved.' -ForegroundColor Green
                }
                Write-Host ''
                Read-Host '   Press Enter to continue' | Out-Null
            }

            'search' {
                Show-Header 'Search the catalog'

                $cats = @(
                    @{ Label = 'Cumulative update';        Hint = 'The monthly LCU. Includes the servicing stack since Feb 2021.'; Key = 'Cumulative' }
                    @{ Label = '.NET Framework cumulative';Hint = 'Shipped separately from the OS cumulative.';                     Key = 'DotNet' }
                    @{ Label = 'Defender platform';        Hint = 'Goes stale quickly -- fetch shortly before a rollout.';          Key = 'Defender' }
                    @{ Label = 'Type my own query';        Hint = 'Free text, exactly as the catalog search box takes it.';         Key = 'Any' }
                ) | ForEach-Object { [pscustomobject]$_ }

                $cat = Read-MenuChoice -Prompt '   Which kind' -Items $cats
                if (-not $cat) { continue menu }

                $query = ''
                if ($cat.Key -eq 'Any') {
                    $query = Read-WfValue 'Search text' ''
                    if (-not $query) { continue menu }
                }

                $preview = (Read-WfValue 'Include Preview updates? (y/N)' 'N') -match '^[Yy]'

                Write-Host ''
                Write-Host '   Searching...' -ForegroundColor Cyan

                $prod = $script:Config['UpdateProduct']
                $arch = $script:Config['UpdateArchitecture']
                $alts = @()
                $kbs  = @()
                $imgBuild = ''
                if ($script:UpdateTarget) {
                    $prod     = $script:UpdateTarget.Product
                    $arch     = $script:UpdateTarget.Architecture
                    $alts     = @($script:UpdateTarget.ProductAlternative)
                    $kbs      = @($script:UpdateTarget.InstalledKB)
                    $imgBuild = "$($script:UpdateTarget.FullBuild)"
                }

                $results = @()
                try {
                    $results = @(Find-WfUpdate -Category $cat.Key -Query $query -Product $prod `
                                               -ProductAlternative $alts -Architecture $arch -KnownKB $kbs `
                                               -ImageBuild $imgBuild -IncludePreview:$preview -First 25)
                }
                catch {
                    Write-Host ''
                    Write-Host "   FAILED: $($_.Exception.Message)" -ForegroundColor Red
                    Write-Host ''
                    Read-Host '   Press Enter to continue' | Out-Null
                    continue menu
                }

                if ($results.Count -eq 0) {
                    Write-Host '   Nothing found.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    continue menu
                }

                Show-Header 'Search results'
                for ($i = 0; $i -lt $results.Count; $i++) {
                    $r = $results[$i]
                    $when = ''
                    if ($r.LastUpdated) { $when = $r.LastUpdated.ToString('yyyy-MM-dd') }
                    # Compared against the value. 'InImage' is three-state now --
                    # yes, no, or '?' when the image's packages were never listed
                    # -- and a truthiness test would call every unchecked result
                    # 'already in the image', which is the exact opposite of what
                    # it means.
                    # Build comparison first: for a cumulative it is the only
                    # one of the two that can answer at all, because an installed
                    # LCU carries no KB number to match against.
                    $flag   = ''
                    $colour = 'Gray'
                    if     ($r.InImage -eq 'yes')   { $flag = '  <- already in the image'; $colour = 'DarkGray' }
                    elseif ($r.VsImage -eq 'newer') { $flag = ('  <- moves the image to {0}' -f $r.TargetBuild); $colour = 'Green' }
                    elseif ($r.VsImage -eq 'same')  { $flag = '  <- the build the image is already at'; $colour = 'DarkGray' }
                    elseif ($r.VsImage -eq 'older') { $flag = ('  <- older than the image ({0})' -f $r.TargetBuild); $colour = 'DarkGray' }
                    elseif ($r.VsImage -eq 'other release') { $flag = '  <- a different release'; $colour = 'Yellow' }
                    elseif ($r.InImage -eq '?')     { $flag = '  <- not checked' }

                    Write-Host ('   {0,2}. {1,-11} {2,8:N1} MB  {3}' -f ($i + 1), $r.KB, $r.SizeMB, $when) -NoNewline
                    Write-Host $flag -ForegroundColor $colour
                    Write-Host ('       {0}' -f $r.Title) -ForegroundColor DarkGray
                }
                Write-Host ''

                if (@($results | Where-Object { $_.InImage -eq '?' -and $_.VsImage -eq '?' }).Count -gt 0) {
                    Write-Host '   "not checked" means nobody looked. Read the target from an image' -ForegroundColor DarkGray
                    Write-Host '   first and both comparisons become possible.' -ForegroundColor DarkGray
                    Write-Host ''
                }
                if ($script:UpdateTarget -and $script:UpdateTarget.FullBuild) {
                    Write-Host ('   The image is at {0}. Cumulative updates do not carry their KB in the' -f $script:UpdateTarget.FullBuild) -ForegroundColor DarkGray
                    Write-Host '   package name, so that build number is the reliable way to read its level.' -ForegroundColor DarkGray
                    Write-Host ''
                }
                Write-Host '   Numbers separated by commas, or 0 to cancel.' -ForegroundColor DarkGray
                $raw = Read-Host '   Download which'
                if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq '0') { continue menu }

                $picked = New-Object System.Collections.Generic.List[object]
                foreach ($part in $raw -split ',') {
                    $n = 0
                    if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $results.Count) {
                        $picked.Add($results[$n - 1])
                    }
                }
                if ($picked.Count -eq 0) { continue menu }

                $totalMb = ($picked | Measure-Object SizeMB -Sum).Sum
                Write-Host ''
                Write-Host ("   {0} update(s), about {1:N0} MB" -f $picked.Count, $totalMb) -ForegroundColor Cyan
                Write-Host ''

                $what = @(
                    @{ Label = 'Download only';       Hint = 'Into the Updates folder. The next servicing run applies it.';       Key = 'get' }
                    @{ Label = 'Download and inject'; Hint = 'Apply just these to an image now. Mounts it, so it takes a while.'; Key = 'inject' }
                ) | ForEach-Object { [pscustomobject]$_ }

                $do = Read-MenuChoice -Prompt '   Then' -Items $what
                if (-not $do) { continue menu }

                if ($do.Key -eq 'get') {
                    Invoke-WfMenuAction 'Download updates' {
                        $picked | Save-WfUpdate
                    }.GetNewClosure()
                    continue menu
                }

                # ---------------------------------------------------- inject
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $img = $script:WorkingImage
                $ii  = $script:WorkingIndex

                # If that image is already open, this becomes a different
                # operation: no mount, and no commit either. Asking about a
                # working copy would be offering something that cannot happen.
                $openNow = $null
                try { $openNow = Get-WfCurrentMount } catch { }
                $sameOpen = $openNow -and ("$($openNow.ImagePath)".TrimEnd('\') -eq "$img".TrimEnd('\')) -and (-not $openNow.ReadOnly)

                Write-Host ''
                if ($sameOpen) {
                    $ii   = [int]$openNow.Index
                    $copy = $false
                    Write-Host "   $(Split-Path $img -Leaf) index $ii is already open -- it will be used as it is." -ForegroundColor Green
                    Write-Host '   It stays open afterwards, and the changes are NOT in the .wim until' -ForegroundColor Yellow
                    Write-Host '   you close it and choose commit. Discarding throws them away.' -ForegroundColor Yellow
                }
                else {
                    Write-Host '   The image is committed in place, as every other single change is.' -ForegroundColor DarkGray
                    Write-Host '   A working copy leaves the master untouched and writes *.working.wim.' -ForegroundColor DarkGray
                    $copy = (Read-WfValue 'Work on a copy instead? (y/N)' 'N') -match '^[Yy]'
                }

                Invoke-WfMenuAction 'Download and inject' {
                    $got = @($picked | Save-WfUpdate)

                    # Only what is actually on disk gets applied -- a failed
                    # download must not quietly drop out of the injection list.
                    # Downloaded, present, AND the update itself. A checkpoint set downloads
                    # as several files and only one of them is ever applied -- handing the
                    # whole list to the injector is what put a checkpoint in front of DISM
                    # and failed with the Unattend.xml error. IsTarget is absent on rows from
                    # an older run, so a missing value counts as true rather than dropping
                    # the file silently.
                    $files = @($got | Where-Object {
                                  ($_.Status -eq 'Downloaded' -or $_.Status -eq 'AlreadyPresent') -and
                                  ($null -eq $_.IsTarget -or $_.IsTarget)
                              } | ForEach-Object { $_.Path })
                    $bad   = @($got | Where-Object { $_.Status -ne 'Downloaded' -and $_.Status -ne 'AlreadyPresent' })

                    if ($bad.Count -gt 0) {
                        throw ("{0} download(s) failed, so nothing was injected: {1}" -f $bad.Count, (($bad | ForEach-Object { $_.File }) -join ', '))
                    }
                    if ($files.Count -eq 0) { throw 'Nothing was downloaded, so there is nothing to inject.' }

                    Invoke-WfUpdateInject -ImagePath $img -Index $ii -File $files -WorkingCopy:$copy `
                                          -Notes 'Injected from the Updates menu'
                }.GetNewClosure()
            }

            'latest' {
                Show-Header 'Get the latest cumulative'
                Write-Host '   Takes the newest cumulative for the configured product and' -ForegroundColor DarkGray
                Write-Host '   downloads it into the Updates folder.' -ForegroundColor DarkGray
                Write-Host ''
                $dry  = (Read-WfValue 'Just show what would be downloaded? (y/N)' 'N') -match '^[Yy]'
                $prod = $script:Config['UpdateProduct']
                $arch = $script:Config['UpdateArchitecture']
                $alts = @()
                $kbs  = @()
                if ($script:UpdateTarget) {
                    $prod = $script:UpdateTarget.Product
                    $arch = $script:UpdateTarget.Architecture
                    $alts = @($script:UpdateTarget.ProductAlternative)
                    $kbs  = @($script:UpdateTarget.InstalledKB)
                }
                Invoke-WfMenuAction 'Get the latest cumulative' {
                    Get-WfLatestUpdate -Category Cumulative -Product $prod -ProductAlternative $alts `
                                       -Architecture $arch -KnownKB $kbs -ImageBuild $imgBuild `
                                       -WhatIfOnly:$dry
                }.GetNewClosure()
            }

            'folder' {
                Invoke-WfMenuAction 'Updates folder' {
                    Get-WfUpdateFolder | Select-Object KB, File, SizeMB, Modified, AgeDays
                }
            }

            'remove' {
                Show-Header 'Remove a downloaded update'
                $have = @(Get-WfUpdateFolder)
                if ($have.Count -eq 0) {
                    Write-Host '   Nothing to remove.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    continue menu
                }
                for ($i = 0; $i -lt $have.Count; $i++) {
                    Write-Host ('   {0,2}. {1,-11} {2,8:N1} MB  {3}' -f ($i + 1), $have[$i].KB, $have[$i].SizeMB, $have[$i].File)
                }
                Write-Host ''
                $n = Read-WfInt 'Which one (0 to cancel)' 0
                if ($n -lt 1 -or $n -gt $have.Count) { continue menu }
                $file = $have[$n - 1].File

                if (Confirm-WfAction "Delete $file from the Updates folder?") {
                    Invoke-WfMenuAction 'Remove a downloaded update' {
                        Remove-WfUpdate -File $file -Confirm:$false
                    }.GetNewClosure()
                }
            }

            'settings' {
                Show-Header 'Catalog search settings'
                Write-Host '   These build the search text for the category options, and the words' -ForegroundColor DarkGray
                Write-Host '   are a Microsoft naming convention rather than anything derivable --' -ForegroundColor DarkGray
                Write-Host '   typed slightly wrong they return nothing and look like there is no' -ForegroundColor DarkGray
                Write-Host '   update available. So they are picked.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   The one that catches everyone: a servicing family shares ONE' -ForegroundColor Yellow
                Write-Host '   cumulative, titled with the newest release in it. An LTSC 2021 image' -ForegroundColor Yellow
                Write-Host '   is build 19044 and needs the update titled "Windows 10 Version 22H2".' -ForegroundColor Yellow

                # Whatever was read off an image goes to the top of the list, so
                # the answer that came from evidence is the first one offered.
                $prodItems = ConvertTo-WfPickItem -Source (Get-WfUpdateProductChoice -Target $script:UpdateTarget) `
                                                  -ValueProperty Product -LabelProperty Note
                $prod = Read-WfPick -Prompt 'Product' -Items $prodItems `
                                    -Default $script:Config['UpdateProduct']

                $archItems = ConvertTo-WfPickItem -Source (Get-WfUpdateArchitectureChoice) `
                                                  -ValueProperty Architecture -LabelProperty Note
                $arch = Read-WfPick -Prompt 'Architecture' -Items $archItems `
                                    -Default $script:Config['UpdateArchitecture']

                # Assigned out here, not in the closure below: a closure gets its
                # own scope, so $script:Config = ... inside one updates nothing and
                # the menu would keep showing the old values until a restart.
                $script:Config = Set-WfConfig -Confirm:$false -Settings @{
                    UpdateProduct = $prod; UpdateArchitecture = $arch
                }

                # Typed settings replace anything read off an image; otherwise the
                # menu would show one product and search with another.
                $script:UpdateTarget = $null

                Invoke-WfMenuAction 'Catalog search settings' {
                    "Searching for: $prod $arch"
                }.GetNewClosure()
            }
        }
    }
}

function Show-ReferenceVmMenu {
    :menu while ($true) {
        Show-Header 'Reference VM'

        # Which machine are we talking to? Everything below happens there, and
        # the paths asked for are as THAT machine sees them.
        $hv = $script:Config['HyperVHost']
        if ($hv) {
            Write-Host "   Hyper-V host: " -NoNewline
            Write-Host $hv -ForegroundColor Cyan
        }
        else {
            Write-Host "   Hyper-V host: " -NoNewline
            Write-Host "$env:COMPUTERNAME (this machine)" -ForegroundColor Cyan
        }

        # State next: almost every decision here depends on whether the VM is
        # running, and on whether the pre-sysprep checkpoint exists yet.
        $vm = $null
        try { $vm = Get-WfReferenceVm } catch {
            Write-Host "   Cannot reach the Hyper-V host: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ''
        }

        if ($vm -and $vm.Exists) {
            $colour = 'Yellow'
            if ($vm.State -eq 'Running') { $colour = 'Green' }
            elseif ($vm.State -eq 'Off') { $colour = 'Gray' }
            Write-Host ("   {0}  " -f $vm.Name) -NoNewline
            Write-Host $vm.State -ForegroundColor $colour -NoNewline
            Write-Host ("   {0} GB / {1} vCPU   {2} checkpoint(s)" -f $vm.MemoryGB, $vm.CpuCount, $vm.CheckpointCount)
            if ($vm.Checkpoints) {
                foreach ($c in $vm.Checkpoints) { Write-Host "      * $c" -ForegroundColor DarkGray }
            }
            if (-not $vm.GuestServices) {
                Write-Host '      Guest Service Interface is off -- file copy into the VM will fail' -ForegroundColor Yellow
            }
        }
        elseif ($vm) {
            Write-Host ("   {0} does not exist on the host yet." -f $vm.Name) -ForegroundColor Yellow
        }

        $credState = 'not set'
        if ($script:GuestCredUser) { $credState = $script:GuestCredUser }
        Write-Host ("   guest credentials: {0}" -f $credState) -ForegroundColor DarkGray
        Write-Host ''

        $items = @(
            @{ Label = 'Hyper-V host';               Hint = 'Which machine runs Hyper-V. Blank means this one.';                 Key = 'sethost' }
            @{ Label = 'Host check';                 Hint = 'Hyper-V reachable, module present, credentials.';                 Key = 'check' }
            @{ Label = 'Create the reference VM';    Hint = 'Gen 2, Secure Boot, automatic checkpoints off.';                   Key = 'create' }
            @{ Label = 'Start / connect';            Hint = 'Then install Windows and press Ctrl+Shift+F3 at first OOBE.';      Key = 'start' }
            @{ Label = 'Set guest credentials';      Hint = 'Needed for anything that runs inside the VM.';                     Key = 'cred' }
            @{ Label = 'Prepare audit mode';         Hint = 'Runs the Start stage inside the VM. Do this before installing.';   Key = 'prep' }
            @{ Label = 'Checkpoint';                 Hint = 'Take this BEFORE sealing -- it is the master you rebuild from.';   Key = 'snap' }
            @{ Label = 'Restore a checkpoint';       Hint = 'How a rebuild starts: restore, patch, re-seal.';                   Key = 'restore' }
            @{ Label = 'Clean up and seal';          Hint = 'PreSeal cleanup then sysprep /generalize /oobe /shutdown.';        Key = 'seal' }
            @{ Label = 'Shut down / turn off';       Hint = '';                                                                 Key = 'stop' }
            @{ Label = 'Capture into a base image';  Hint = 'VM must be sealed and powered off.';                               Key = 'capture' }
            @{ Label = 'Remove a checkpoint';        Hint = 'Frees the disk a checkpoint holds. The VM keeps its state.';        Key = 'delsnap' }
            @{ Label = 'Host credentials';           Hint = 'Only needed when Hyper-V is on a separate server.';                 Key = 'hostcred' }
            @{ Label = 'Copy a file into the VM';    Hint = 'Over the Guest Service Interface. No network, no credentials.';     Key = 'copyin' }
            @{ Label = 'Where is the disk?';         Hint = 'VHDX location, and how this workstation reaches it.';                Key = 'vhd' }
            @{ Label = 'Run a command inside the VM';Hint = 'PowerShell Direct. For poking around during a build.';             Key = 'exec' }
        ) | ForEach-Object { [pscustomobject]$_ }

        $choice = Read-MenuChoice -Prompt '   Choose' -Items $items
        if (-not $choice) { return }

        switch ($choice.Key) {

            'sethost' {
                Show-Header 'Hyper-V host'
                Write-Host '   Leave blank for this machine. A name or FQDN points the whole' -ForegroundColor DarkGray
                Write-Host '   Reference VM section at that server instead, over WinRM.' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '   Remember that ISO and VM folder paths are then as the SERVER' -ForegroundColor Yellow
                Write-Host '   sees them, not as this workstation does.' -ForegroundColor Yellow
                Write-Host ''
                $current = $script:Config['HyperVHost']
                if (-not $current) { $current = '(this machine)' }
                Write-Host "   currently: $current" -ForegroundColor DarkGray
                Write-Host ''
                Write-Host "   Enter a host name, or '-' to clear it back to this machine." -ForegroundColor DarkGray
                $answer = Read-Host '   Hyper-V host'

                if ($answer -eq '-') { $answer = '' }
                elseif ([string]::IsNullOrWhiteSpace($answer)) { continue menu }

                $script:Config = Set-WfConfig -Confirm:$false -Settings @{ HyperVHost = $answer.Trim() }

                Invoke-WfMenuAction 'Hyper-V host' {
                    Write-Host '   Checking the new host...' -ForegroundColor Cyan
                    Test-WfHyperV
                }
            }

            'check' { Invoke-WfMenuAction 'Hyper-V host check' { Test-WfHyperV } }

            'create' {
                Show-Header 'Create the reference VM'
                $cfg = $script:Config

                # Read the host first. Every one of these is a name or a path on
                # the HOST, not on this workstation, which is the thing that
                # catches people out when the host is a server somewhere.
                Write-Host '   Reading the Hyper-V host...' -ForegroundColor DarkGray
                $facts = Get-WfVmHostFact

                if (-not $facts.Reachable) {
                    Write-Host ''
                    Write-Host "   Could not read the host: $($facts.Error)" -ForegroundColor Yellow
                    Write-Host '   Everything below can still be typed in; there is just nothing to' -ForegroundColor DarkGray
                    Write-Host '   pick from.' -ForegroundColor DarkGray
                }
                else {
                    Write-Host ("   {0}: {1} logical processors, {2} GB total, {3} GB assigned to {4} running VM(s)" -f `
                        $facts.ComputerName, $facts.LogicalProcessors, $facts.TotalMemoryGB,
                        $facts.AssignedMemoryGB, $facts.RunningVms) -ForegroundColor Green
                }

                # The name, checked against what is already on the host rather
                # than left for New-VM to reject after the rest is filled in.
                $suggest = Get-WfVmNameSuggestion -Preferred $cfg['ReferenceVmName']
                if ($suggest.Taken) {
                    Write-Host ''
                    Write-Host ("   '{0}' already exists on the host." -f $cfg['ReferenceVmName']) -ForegroundColor Yellow
                }
                $name = Read-WfValue 'VM name' $suggest.Name

                $isoItems = ConvertTo-WfPickItem -Source (Get-WfVmIsoChoice) -ValueProperty Path `
                                                 -LabelProperty Name, Note

                # Browsing is only offered when the host IS this machine. On a
                # remote host a local file browser returns a path this
                # workstation can see and the host cannot, and New-VM then says
                # the ISO does not exist while pointing at a file that plainly
                # does -- which is a genuinely baffling half hour.
                $canBrowse = -not (Test-WfVmHostIsRemote)
                if (-not $canBrowse) {
                    Write-Host ''
                    Write-Host '   The host is another machine, so the ISO path has to be one THAT' -ForegroundColor DarkGray
                    Write-Host '   machine can see. Pick from the list above or type it as the host' -ForegroundColor DarkGray
                    Write-Host '   sees it; browsing from here would find the wrong file.' -ForegroundColor DarkGray
                }

                $iso = Read-WfPick -Prompt 'LTSC 2021 ISO (path ON THE HYPER-V HOST)' -Items $isoItems `
                                   -Default $cfg['ReferenceIsoPath'] -Browse:$canBrowse `
                                   -BrowseFilter 'Disc images (*.iso)|*.iso|All files (*.*)|*.*'
                if (-not $iso) {
                    Write-Host '   An ISO is required.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    continue menu
                }

                $folderItems = @()
                if ($facts.VirtualMachinePath) {
                    $folderItems += [pscustomobject]@{ Value = $facts.VirtualMachinePath; Label = "$($facts.VirtualMachinePath)   the host's own VM folder" }
                }
                if ($facts.VirtualHardDiskPath) {
                    $folderItems += [pscustomobject]@{ Value = $facts.VirtualHardDiskPath; Label = "$($facts.VirtualHardDiskPath)   the host's virtual disk folder" }
                }
                $path = Read-WfPick -Prompt 'VM folder on the host (blank = Hyper-V default)' `
                                    -Items $folderItems -Default $cfg['ReferenceVmPath'] `
                                    -BlankMeans 'use the Hyper-V default'

                # The one that fails quietly. An Internal or Private switch makes
                # a VM that comes up perfectly and has no route off the host, so
                # each one says what it actually means.
                $switches = @(Get-WfVmSwitchChoice)
                $swDefault = $cfg['ReferenceVmSwitch']
                if (-not $swDefault) {
                    $best = @($switches | Where-Object { $_.Suitable }) | Select-Object -First 1
                    if ($best) { $swDefault = $best.Name }
                }
                $swItems = ConvertTo-WfPickItem -Source $switches -ValueProperty Name -LabelProperty Type, What
                $sw = Read-WfPick -Prompt 'Virtual switch (blank = no network)' -Items $swItems `
                                  -Default $swDefault -BlankMeans 'give it no network'

                if ($sw) {
                    $chosen = @($switches | Where-Object { $_.Name -eq $sw })
                    if ($chosen.Count -eq 1 -and -not $chosen[0].Suitable) {
                        Write-Host ''
                        Write-Host ("   '{0}' is a {1} switch: {2}." -f $sw, $chosen[0].Type, $chosen[0].What) -ForegroundColor Yellow
                        Write-Host '   Nothing fails at creation. The VM comes up fine and the missing' -ForegroundColor Yellow
                        Write-Host '   network shows up hours later, when updates will not install.' -ForegroundColor Yellow
                        if (-not (Confirm-WfAction 'Use it anyway?')) { continue menu }
                    }
                }

                # Sizes are the one list with nothing to read off the host, so
                # they are the sizes worth offering for THIS job -- capped by what
                # the host has, with anything that would overcommit it marked.
                $mem  = Read-WfSizePick -Kind Memory -Prompt 'Memory GB' -HostFact $facts -Default $cfg['ReferenceVmMemoryGB']
                $disk = Read-WfSizePick -Kind Disk   -Prompt 'Disk GB'   -HostFact $facts -Default $cfg['ReferenceVmVhdSizeGB']
                $cpu  = Read-WfSizePick -Kind Cpu    -Prompt 'vCPU'      -HostFact $facts -Default $cfg['ReferenceVmCpuCount']

                Write-Host ''
                Write-Host '   Processor compatibility hides the newer instruction sets from the' -ForegroundColor DarkGray
                Write-Host '   guest so the VM can be moved to a host with an older CPU. It does' -ForegroundColor DarkGray
                Write-Host '   NOT affect the captured image -- a WIM carries no processor features' -ForegroundColor DarkGray
                Write-Host '   either way -- so leave it off unless this VM itself will be moved.' -ForegroundColor DarkGray
                $compatDefault = 'N'
                if ($cfg['ReferenceVmCompatibleCpu']) { $compatDefault = 'Y' }
                $compat = (Read-WfValue 'Hide newer CPU instructions? (y/N)' $compatDefault) -match '^[Yy]'

                # Remember the answers so the next build does not ask again.
                $script:Config = Set-WfConfig -Confirm:$false -Settings @{
                    ReferenceVmName = $name; ReferenceIsoPath = $iso; ReferenceVmPath = $path
                    ReferenceVmSwitch = $sw; ReferenceVmMemoryGB = $mem
                    ReferenceVmVhdSizeGB = $disk; ReferenceVmCpuCount = $cpu
                    ReferenceVmCompatibleCpu = $compat
                }

                Invoke-WfMenuAction 'Create the reference VM' {
                    New-WfReferenceVm -Name $name -IsoPath $iso -Path $path -SwitchName $sw `
                                      -MemoryGB $mem -VhdSizeGB $disk -CpuCount $cpu `
                                      -CompatibleCpu:$compat
                }.GetNewClosure()
            }

            'start' {
                Show-Header 'Start the reference VM'
                $connect = (Read-WfValue 'Open the VM console too? (Y/n)' 'Y') -match '^[Yy]'
                Invoke-WfMenuAction 'Start the reference VM' {
                    Start-WfReferenceVm -Connect:$connect
                    Write-Host ''
                    Write-Host '   Install Windows, then press Ctrl+Shift+F3 at the FIRST OOBE screen.' -ForegroundColor Cyan
                    Write-Host '   That drops into audit mode. Do not click through OOBE.' -ForegroundColor Cyan
                }.GetNewClosure()
            }

            'cred' {
                Show-Header 'Guest credentials'
                Write-Host '   PowerShell Direct needs an account inside the VM, and Windows will' -ForegroundColor DarkGray
                Write-Host '   not accept the blank password the audit-mode Administrator starts' -ForegroundColor DarkGray
                Write-Host '   with. Inside the VM, once:' -ForegroundColor DarkGray
                Write-Host ''
                Write-Host '       net user Administrator <password>' -ForegroundColor White
                Write-Host ''
                Write-Host '   It is held in memory for this session only, never written down.' -ForegroundColor DarkGray
                Write-Host ''
                Invoke-WfMenuAction 'Set guest credentials' {
                    $u = Set-WfGuestCredential
                    if ($u) { $script:GuestCredUser = $u }
                    "Stored for $u"
                }
            }

            'prep' {
                Show-Header 'Prepare audit mode'
                Write-Host '   Applies the imaging policies inside the VM: no drivers from Windows' -ForegroundColor DarkGray
                Write-Host '   Update, hibernation off, reserved storage off, no sleep.' -ForegroundColor DarkGray
                Write-Host '   Run this BEFORE installing the application stack.' -ForegroundColor DarkGray
                Write-Host ''
                Invoke-WfMenuAction 'Prepare audit mode' {
                    Initialize-WfReferenceBuild -Stage Start
                }
            }

            'snap' {
                Show-Header 'Checkpoint'
                Write-Host '   Take this once the stack is installed and BEFORE sealing.' -ForegroundColor Cyan
                Write-Host '   It is the master: later rebuilds restore it, patch, re-seal.' -ForegroundColor Cyan
                Write-Host ''
                $cpName = Read-WfValue 'Checkpoint name' 'audit-mode pre-sysprep'
                Invoke-WfMenuAction 'Checkpoint' {
                    New-WfReferenceCheckpoint -CheckpointName $cpName
                }.GetNewClosure()
            }

            'restore' {
                Show-Header 'Restore a checkpoint'
                $snaps = @()
                try { $snaps = @(Get-WfReferenceCheckpoint) } catch { }
                if ($snaps.Count -eq 0) {
                    Write-Host '   No checkpoints on this VM.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    continue menu
                }
                for ($i = 0; $i -lt $snaps.Count; $i++) {
                    Write-Host ('   {0,2}. {1,-40} {2}' -f ($i + 1), $snaps[$i].Name, $snaps[$i].Created)
                }
                Write-Host ''
                $n = Read-WfInt 'Which checkpoint (0 to cancel)' 0
                if ($n -lt 1 -or $n -gt $snaps.Count) { continue menu }
                $cpName = $snaps[$n - 1].Name

                if (Confirm-WfAction "Restore to '$cpName'? Everything since it is discarded.") {
                    Invoke-WfMenuAction 'Restore a checkpoint' {
                        Restore-WfReferenceCheckpoint -CheckpointName $cpName -Confirm:$false
                    }.GetNewClosure()
                }
            }

            'seal' {
                Show-Header 'Clean up and seal'
                Write-Host '   This runs the PreSeal cleanup inside the VM and then sysprep' -ForegroundColor Yellow
                Write-Host '   /generalize /oobe /shutdown. It is NOT reversible.' -ForegroundColor Yellow
                Write-Host ''
                if ($vm -and $vm.CheckpointCount -eq 0) {
                    Write-Host '   WARNING: this VM has no checkpoints. Take one first -- without it' -ForegroundColor Red
                    Write-Host '   a bad seal means rebuilding from the ISO.' -ForegroundColor Red
                    Write-Host ''
                }
                # Browsable, but the configured one stays the default -- most
                # builds use the same answer file every time and should not have
                # to go and find it again.
                $unattend = Read-WfPick -Prompt 'Answer file (for sealing)' -Items @() `
                                        -Default $script:Config['UnattendPath'] -Browse `
                                        -BrowseFilter 'Answer files (*.xml)|*.xml|All files (*.*)|*.*'

                if (Confirm-WfAction 'Seal the reference build? This cannot be undone.') {
                    Invoke-WfMenuAction 'Clean up and seal' {
                        Initialize-WfReferenceBuild -Stage PreSeal -Sysprep -UnattendPath $unattend
                    }.GetNewClosure()
                }
            }

            'stop' {
                Show-Header 'Stop the reference VM'
                $hard = (Read-WfValue 'Force power off instead of a clean shutdown? (y/N)' 'N') -match '^[Yy]'
                Invoke-WfMenuAction 'Stop the reference VM' {
                    Stop-WfReferenceVm -TurnOff:$hard
                }.GetNewClosure()
            }

            'capture' {
                Show-Header 'Capture into a base image'
                if ($vm -and $vm.State -ne 'Off') {
                    Write-Host "   $($vm.Name) is $($vm.State). It must be sealed and powered off." -ForegroundColor Yellow
                    Write-Host ''
                }
                $dest  = Read-WfValue 'Destination WIM (blank = auto-named in the image folder)' ''
                $notes = Read-WfValue 'Notes for the build history' ''
                Invoke-WfMenuAction 'Capture into a base image' {
                    Invoke-WfReferenceCapture -DestinationPath $dest -Notes $notes
                }.GetNewClosure()
            }

            'delsnap' {
                Show-Header 'Remove a checkpoint'
                $snaps = @()
                try { $snaps = @(Get-WfReferenceCheckpoint) } catch { }
                if ($snaps.Count -eq 0) {
                    Write-Host '   No checkpoints on this VM.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    continue menu
                }
                for ($i = 0; $i -lt $snaps.Count; $i++) {
                    Write-Host ('   {0,2}. {1,-40} {2}' -f ($i + 1), $snaps[$i].Name, $snaps[$i].Created)
                }
                Write-Host ''
                $n = Read-WfInt 'Which checkpoint (0 to cancel)' 0
                if ($n -lt 1 -or $n -gt $snaps.Count) { continue menu }
                $cpName = $snaps[$n - 1].Name

                if (Confirm-WfAction "Delete checkpoint '$cpName'? The VM keeps its current state.") {
                    Invoke-WfMenuAction 'Remove a checkpoint' {
                        Remove-WfReferenceCheckpoint -CheckpointName $cpName -Confirm:$false
                    }.GetNewClosure()
                }
            }

            'hostcred' {
                Show-Header 'Hyper-V host credentials'
                if (-not (Test-WfVmHostIsRemote)) {
                    Write-Host '   Hyper-V is local -- no host credentials needed.' -ForegroundColor Green
                    Write-Host ''
                    Read-Host '   Press Enter to continue' | Out-Null
                    continue menu
                }
                Invoke-WfMenuAction 'Hyper-V host credentials' {
                    $u = Set-WfHostCredential
                    "Stored for $u"
                }
            }

            'copyin' {
                Show-Header 'Copy a file into the VM'
                Write-Host '   Uses the Guest Service Interface over VMBus -- no network and no' -ForegroundColor DarkGray
                Write-Host '   guest credentials required.' -ForegroundColor DarkGray
                Write-Host ''
                $src = Read-WfValue 'File on this workstation (B to browse)' ''
                if ($src -match '^[Bb]$') { $src = Show-WfFileDialog -Title 'File to copy into the VM' -Filter 'All files (*.*)|*.*' }
                if (-not $src) { continue menu }
                $dest = Read-WfValue 'Destination inside the guest' ("C:\WimForgeBuild\" + (Split-Path $src -Leaf))
                Invoke-WfMenuAction 'Copy a file into the VM' {
                    Copy-WfToReferenceVm -SourcePath $src -DestinationPath $dest
                }.GetNewClosure()
            }

            'vhd' {
                Invoke-WfMenuAction 'Reference VHDX' { Get-WfReferenceVhdPath }
            }

            'exec' {
                Show-Header 'Run a command inside the VM'
                $cmd = Read-WfValue 'PowerShell to run in the guest' 'Get-ComputerInfo | Select-Object OsName, OsVersion, CsName'
                if (-not $cmd) { continue menu }
                Invoke-WfMenuAction 'Run inside the VM' {
                    Invoke-WfReferenceCommand -ScriptBlock ([scriptblock]::Create($cmd))
                }.GetNewClosure()
            }
        }
    }
}

function Show-HousekeepingMenu {
    :menu while ($true) {
        Show-Header 'Housekeeping'
        $items = @(
            @{ Label = 'Environment check';      Hint = 'Elevation, DISM version, paths, stale mounts, free space.'; Key = 'env' }
            @{ Label = 'Restart elevated';       Hint = 'Reopen this tool as administrator (a process cannot elevate itself).'; Key = 'elevate' }
            @{ Label = 'Repair stale mounts';    Hint = 'Run this when servicing refuses to start.';                 Key = 'repair' }
            @{ Label = 'List images';            Hint = 'Everything in the image folder: size, age, indexes, notes.'; Key = 'images' }
            @{ Label = 'Image inventory report'; Hint = 'Build, drivers, updates and size of any WIM.';              Key = 'report' }
            @{ Label = 'Build history';          Hint = 'What was done to which image, and by whom.';                Key = 'history' }
            @{ Label = 'Settings';               Hint = 'Every path, editable here with a folder browser. No JSON.'; Key = 'config' }
            @{ Label = 'About';                  Hint = 'Version, author, licence and where to report a problem.';   Key = 'about' }
            @{ Label = 'Open today''s log';      Hint = '';                                                          Key = 'log' }
        ) | ForEach-Object { [pscustomobject]$_ }

        $choice = Read-MenuChoice -Prompt '   Choose' -Items $items
        if (-not $choice) { return }

        switch ($choice.Key) {
            'env'    { Invoke-WfMenuAction 'Environment check' { Test-WfEnvironment } }
            'elevate' {
                Show-Header 'Restart elevated'
                if (Test-WfElevated) {
                    Write-Host '   Already running as administrator -- nothing to do.' -ForegroundColor Green
                    Write-Host ''
                    Read-Host '   Press Enter to continue' | Out-Null
                }
                else {
                    Write-Host '   A running process cannot grant itself administrator rights, so' -ForegroundColor Yellow
                    Write-Host '   this opens a new elevated window and closes the current one.' -ForegroundColor Yellow
                    Write-Host '   Any unsaved state in this session is lost -- there is none unless' -ForegroundColor Yellow
                    Write-Host '   an image is currently mounted.' -ForegroundColor Yellow
                    Write-Host ''
                    $answer = Read-Host '   Continue? [Y/n]'
                    if ($answer -eq '' -or $answer -match '^[Yy]') {
                        if (Invoke-WfRelaunchElevated) { exit }
                    }
                }
            }
            'images' {
                Show-Header 'Images'
                Invoke-WfMenuAction 'Images' {
                    Get-WfImageInventory -IncludePeImage |
                        Select-Object Name, SizeGB, Modified, AgeDays, Indexes, ImageNames, Notes
                }
            }
            'repair' {
                Show-Header 'Repair stale mounts'
                $force = (Read-WfValue 'Also force-clear leftover files in the mount folder? (y/N)' 'N') -match '^[Yy]'
                Invoke-WfMenuAction 'Repair stale mounts' { Repair-WfMount -Force:$force }.GetNewClosure()
            }
            'report' {
                Show-Header 'Image inventory'
                if (-not (Confirm-WfWorkingImage)) { continue menu }
                $src = $script:WorkingImage
                $idx = $script:WorkingIndex

                Write-Host ''
                $depth = @(
                    @{ Label = 'Identity and build';  Hint = 'Seconds. Read straight out of the .wim, nothing mounted.';   Key = 'quick' }
                    @{ Label = 'Everything';          Hint = 'Adds drivers, updates and features. Mounts, so minutes.';    Key = 'full'  }
                ) | ForEach-Object { [pscustomobject]$_ }

                $how = Read-MenuChoice -Prompt '   How much' -Items $depth
                if (-not $how) { continue menu }
                $quick = ($how.Key -eq 'quick')

                $features = $false
                if (-not $quick) {
                    $features = (Read-WfValue 'Also list enabled optional features? (y/N)' 'N') -match '^[Yy]'
                }

                Invoke-WfMenuAction 'Image inventory' {
                    Get-WfImageReport -ImagePath $src -Index $idx -Quick:$quick -IncludeFeatures:$features |
                        Select-Object ImageName, EditionId, Release, Architecture, FullBuild, SizeGB, FileSizeGB, DriverCount, UpdateCount, DriversByClass, Scope
                }.GetNewClosure()
            }
            'history' {
                Show-Header 'Build history'
                Invoke-WfMenuAction 'Build history' {
                    Get-WfHistory -Last 25 |
                        Select-Object TimestampUtc, Action, ImageFile, Operator, Notes
                }
            }
            'config' { Show-WfSettingsEditor }
            'about' {
                Clear-Host
                Show-WfBanner
                $about = Get-WfAbout
                Write-Host ("   {0}" -f $about.Description) -ForegroundColor Gray
                Write-Host ''
                Write-Host ("   Version    : {0}" -f $about.Version)
                Write-Host ("   Author     : {0}" -f $about.Author)
                Write-Host ("   Licence    : {0}" -f $about.License)
                Write-Host ("   Repository : {0}" -f $about.Repository)
                Write-Host ("   Config     : {0}" -f (Get-WfConfigPath))
                Write-Host ("   PowerShell : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
                Write-Host ''
                Read-Host '   Press Enter to continue' | Out-Null
            }
            'log' {
                $log = Join-Path $script:Config['LogRoot'] ('WimForge-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
                if (Test-Path -LiteralPath $log) { Start-Process notepad.exe $log }
                else {
                    Write-Host "   No log for today at $log" -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                }
            }
        }
    }
}

# ------------------------------------------------------------------ main loop

# A first run, or a configuration pointing at drives this machine does not have,
# goes straight to setup rather than letting every action fail one at a time.
Show-WfSetupWizard | Out-Null

while ($true) {
    Update-WfMountNote
    Show-Header 'Main menu' -Full

    $items = @(
        @{ Label = 'Choose the image to work on'; Hint = 'Everything below acts on this one, until you change it.'; Key = 'pick' }
        @{ Label = 'Image servicing';        Hint = 'Updates, drivers, cleanup, export -- the monthly job.'; Key = 'servicing' }
        @{ Label = 'Driver library';         Hint = 'Harvest, list, retire, compare.';                       Key = 'drivers' }
        @{ Label = 'Boot image and WDS';     Hint = 'PE drivers and publishing.';                            Key = 'boot' }
        @{ Label = 'Offline customisation';  Hint = 'Registry, payload, certificates, unattend, features.';  Key = 'customise' }
        @{ Label = 'Updates';                Hint = 'Search the Microsoft Update Catalog and download what you need.'; Key = 'updates' }
        @{ Label = 'Reference VM';           Hint = 'Build the base image: create, prepare, checkpoint, seal, capture.'; Key = 'vm' }
        @{ Label = 'Build operations';       Hint = 'Capture, USB media, post-deploy validation.';            Key = 'build' }
        @{ Label = 'Housekeeping';           Hint = 'Environment check, stale mounts, reports, history.';    Key = 'house' }
    ) | ForEach-Object { [pscustomobject]$_ }

    $choice = Read-MenuChoice -Prompt '   Choose' -Items $items -BackLabel 'Exit'
    if (-not $choice) {
        $about = Get-WfAbout
        Write-Host ''
        Write-Host ("   {0} {1}  --  {2}" -f $about.Name, $about.Version, $about.Repository) -ForegroundColor DarkGray
        Write-Host ''
        break
    }

    switch ($choice.Key) {
        'pick'      { Show-Header 'Choose the image to work on'; Set-WfWorkingImage | Out-Null }
        'servicing' { Show-ServicingMenu }
        'drivers'   { Show-DriverMenu }
        'boot'      { Show-BootMenu }
        'customise' { Show-CustomiseMenu }
        'updates'   { Show-UpdatesMenu }
        'vm'        { Show-ReferenceVmMenu }
        'build'     { Show-BuildMenu }
        'house'     { Show-HousekeepingMenu }
    }
}
