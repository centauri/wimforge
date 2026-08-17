# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Core.ps1 -- configuration, logging, guards and small shared helpers.

    Everything in here is private to the module. Public functions call these;
    the menu and the GUI never do.
#>

# --------------------------------------------------------------------- logging

function Join-WfPath {
    <#
        Pure string path joining. Used everywhere in this module INSTEAD of
        Join-WfPath, because Join-Path resolves the drive qualifier through the
        provider and throws DriveNotFoundException when the drive is not present
        on this machine.

        That is not a hypothetical: a configuration carried over from another
        workstation points at, say, D:\Imaging, and every path the toolkit builds
        from it explodes before the tool has even drawn its first menu. Building
        the string is always safe; whether the path is reachable is a question for
        Test-Path, at the point where it actually matters.
    #>
    param(
        [AllowEmptyString()] [string] $Path,
        [AllowEmptyString()] [string] $ChildPath
    )

    if ([string]::IsNullOrEmpty($Path))      { return $ChildPath }
    if ([string]::IsNullOrEmpty($ChildPath)) { return $Path }

    # 'C:' means "current directory on C:", not the root -- normalise it, which
    # is what Join-WfPath would have done.
    if ($Path -match '^[A-Za-z]:$') { return ($Path + '\' + $ChildPath.TrimStart('\', '/')) }

    $sep = '\'
    if ($Path -notmatch '[\\]' -and $Path -match '/') { $sep = '/' }   # non-Windows paths in tests

    return ($Path.TrimEnd('\', '/') + $sep + $ChildPath.TrimStart('\', '/'))
}

function Get-WfFallbackLogRoot {
    if ($env:ProgramData) { return (Join-WfPath $env:ProgramData 'WimForge\Logs') }
    if ($env:TEMP)        { return (Join-WfPath $env:TEMP 'WimForge\Logs') }
    return (Join-WfPath ([System.IO.Path]::GetTempPath()) 'WimForge\Logs')
}

function Initialize-WfLog {
    <#
        One log file per day under the configured LogRoot, plus everything echoed
        to the console. Long image jobs get diagnosed from these files weeks later,
        so the format is deliberately greppable: ISO timestamp, level, message.

        This must NEVER throw. It is the first thing Get-WfConfig calls, so a
        LogRoot pointing at a drive that does not exist on this machine -- a
        config copied from another workstation, say -- would otherwise spray
        DriveNotFoundException across the screen before the tool has even started.
        An unreachable LogRoot silently falls back to ProgramData instead.
    #>
    [CmdletBinding()]
    param([string] $LogRoot)

    # Cleared on every call: a problem recorded when LogRoot pointed at a missing
    # drive must not survive the operator fixing it, or Test-WfSetupRequired keeps
    # insisting setup is needed forever.
    $script:WfLogRootProblem = $null

    $chosen = $LogRoot
    if (-not $chosen) { $chosen = Get-WfFallbackLogRoot }

    $resolved = $null
    foreach ($candidate in @($chosen, (Get-WfFallbackLogRoot)) | Select-Object -Unique) {
        if (-not $candidate) { continue }
        try {
            if (-not (Test-Path -LiteralPath $candidate)) {
                New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop | Out-Null
            }
            $resolved = $candidate
            break
        }
        catch {
            # Remembered so the front-ends can tell the operator their configured
            # log folder is not usable, without the failure being fatal.
            $script:WfLogRootProblem = "Log folder unavailable ($candidate): $($_.Exception.Message)"
        }
    }

    if (-not $resolved) {
        # Nowhere to write. Console-only logging from here on.
        $script:WfLogPath = $null
        return $null
    }

    $script:WfLogPath = Join-WfPath $resolved ('WimForge-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    return $script:WfLogPath
}

function Get-WfLogRootProblem {
    <# Whatever Initialize-WfLog could not do, or $null if all was well. #>
    return $script:WfLogRootProblem
}

function Write-WfLog {
<#
.SYNOPSIS
    Writes one line to the run log, the console, and any front-end listening.
.DESCRIPTION
    The single logging call for the whole toolkit, so that a servicing run leaves
    the same record whether it was started from the GUI, the console menu or a
    scheduled task.

    Three destinations, and the order matters. The file first, because it is the
    one that survives: a run that fails at 03:00 is read from the log the next
    morning. Then the console, colour-coded by level. Then the sink, which is how
    the GUI mirrors the same lines into its log pane without the module ever
    referencing WinForms.

    A logging failure never propagates. A full disk or a locked file is not a
    reason to abandon a four-hour image build, so a failed write is recorded to
    the verbose stream and the run carries on.
.PARAMETER Message
    The line. Written as given -- the timestamp and level are added here.
.PARAMETER Level
    INFO, WARN, ERROR, STEP or OK. STEP prints a blank line and a heading, which
    is what gives a long run its structure when read back.
.PARAMETER NoConsole
    Write to the log and the sink but not to the console. For the inner lines of
    something that would otherwise flood the screen.
.EXAMPLE
    Write-WfLog 'Mounting the working copy' -Level STEP
.EXAMPLE
    Write-WfLog "Injected $($result.Added) driver(s)" -Level OK
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','STEP','OK')] [string] $Level = 'INFO',
        [switch] $NoConsole
    )

    if (-not $script:WfLogPath) { Initialize-WfLog | Out-Null }

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    if ($script:WfLogPath) {
        try {
            Add-Content -LiteralPath $script:WfLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            # Never let a logging failure take down an image job.
            Write-Verbose "Log write failed: $($_.Exception.Message)"
        }
    }

    if (-not $NoConsole) {
        switch ($Level) {
            'STEP'  { Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
            'OK'    { Write-Host "    $Message" -ForegroundColor Green }
            'WARN'  { Write-Host "    $Message" -ForegroundColor Yellow }
            'ERROR' { Write-Host "    $Message" -ForegroundColor Red }
            default { Write-Host "    $Message" }
        }
    }

    # Front-ends (the GUI) subscribe to this to mirror the log into a text pane.
    if ($script:WfLogSink) {
        try { & $script:WfLogSink $line $Level } catch { }
    }
}

function Register-WfLogSink {
<#
.SYNOPSIS
    Subscribes a scriptblock to every subsequent log line.
.DESCRIPTION
    How a front-end mirrors the log into its own window without the module
    knowing anything about it. Write-WfLog calls the sink with the formatted line
    and its level; what happens next is the front-end's business.

    Deliberately one sink rather than a list. Two front-ends never run in the
    same process, and a list would invite a subscriber that is never removed.

    The sink is called inside a try that swallows everything. A front-end that
    throws while painting its log pane must not take down the image job that was
    only trying to report progress.
.PARAMETER Sink
    Receives two arguments: the formatted line, and the level as a string. Pass
    $null to unsubscribe.
.EXAMPLE
    Register-WfLogSink -Sink { param($Line, $Level) $script:Sync.Queue.Enqueue($Line) }
#>
    [CmdletBinding()]
    param([scriptblock] $Sink)
    $script:WfLogSink = $Sink
}

# ---------------------------------------------------------------------- guards

function Assert-WfElevated {
    <#
        The message text matters: both front-ends match on 'NEEDS ELEVATION' to
        offer a relaunch instead of just reporting a failure, so do not reword it
        without updating them.
    #>
    if (-not (Test-WfElevated)) {
        throw 'NEEDS ELEVATION: this operation requires administrator rights (DISM mounts do not work without them).'
    }
}

function Assert-WfPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Label = 'Path'
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function New-WfDirectory {
    <#
        Tolerates an empty path so callers can pass `Split-Path <file> -Parent`
        without guarding: a bare filename has no parent, and blowing up on that
        after a long-running job has already done its work is the worst possible
        moment to fail.
    #>
    param([AllowEmptyString()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return $Path
}

# ------------------------------------------------------------------ small bits

function Get-WfSafeName {
    <# Turns a manufacturer/model string into something safe for a folder name. #>
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'Unknown' }
    return ($Text -replace '[^A-Za-z0-9\.\-]+', '_').Trim('_')
}

function Get-WfInfProvider {
    <#
        Reads Provider= out of an INF, resolving the %token% indirection that
        almost every INF uses: Provider=%MSFT% in [Version], with MSFT="Microsoft"
        down in [Strings]. Reading the raw value would give "%MSFT%" and match
        nothing.

        Used to tell Microsoft-provided packages apart from vendor ones. DISM's
        own ProviderName is preferred wherever it is available -- this is for the
        case where all we have is a folder of INFs on disk.

        Same ANSI/UTF-16 caveat as Get-WfInfClass: vendor packages ship both.
    #>
    param([Parameter(Mandatory)] [string] $InfPath)

    try   { $text = Get-Content -LiteralPath $InfPath -Raw -ErrorAction Stop }
    catch { return $null }

    $m = [regex]::Match($text, '(?im)^\s*Provider\s*=\s*(.+?)\s*(?:;.*)?$')
    if (-not $m.Success) { return $null }

    $value = $m.Groups[1].Value.Trim().Trim('"')
    if ($value -notmatch '^%(.+)%$') { return $value }

    # A token. Find it in [Strings]; the localised [Strings.0409] wins if present
    # but the neutral section is the one that is always there.
    $token = $Matches[1]
    $sm = [regex]::Match($text, '(?im)^\s*' + [regex]::Escape($token) + '\s*=\s*(.+?)\s*(?:;.*)?$')
    if ($sm.Success) { return $sm.Groups[1].Value.Trim().Trim('"') }

    return $value
}

function Get-WfInfDriverVer {
    <#
        Reads DriverVer out of an INF: 'DriverVer = 07/12/2024,23.40.1.5'.

        This is how a driver package states its own date and version, and it is
        the only source available when all you have is a folder on disk -- no
        DISM, no driver store, just files. Used to tell which of several copies of
        the same package is the newest.

        Returns Date and Version as strings, either of which may be $null: some
        INFs give only one, and a few give neither.
    #>
    param([Parameter(Mandatory)] [string] $InfPath)

    $result = [pscustomobject]@{ Date = $null; Version = $null }

    try   { $text = Get-Content -LiteralPath $InfPath -Raw -ErrorAction Stop }
    catch { return $result }

    $m = [regex]::Match($text, '(?im)^\s*DriverVer\s*=\s*([^;\r\n]+)')
    if (-not $m.Success) { return $result }

    $parts = @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -ge 1) { $result.Date = $parts[0] }
    if ($parts.Count -ge 2) { $result.Version = $parts[1] }

    # A DriverVer with only a version and no date is legal and does happen.
    if ($result.Date -and $result.Date -notmatch '^\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}$') {
        $result.Version = $result.Date
        $result.Date    = $null
    }
    return $result
}

function Test-WfMicrosoftProvider {
    <#
        One place to decide what counts as Microsoft-provided, so the harvest and
        the injection cannot drift apart on it.

        Deliberately narrow: it matches Microsoft as the provider, not any string
        containing the word. A vendor calling itself "Microsoft Partner Ltd" is
        not Microsoft, and dropping its driver silently would be exactly the kind
        of thing that is not noticed until a terminal has no touchscreen.
    #>
    param([string] $ProviderName)

    if (-not $ProviderName) { return $false }
    return ($ProviderName.Trim() -match '^Microsoft( Corporation| Windows.*)?$')
}

function Get-WfInfClass {
    <#
        Reads Class= out of an INF. Handles ANSI and UTF-16 INFs -- vendor packages
        ship both, and a UTF-16 INF read as ANSI silently produces no match, which
        would quietly drop a storage driver out of a boot image.
    #>
    param([Parameter(Mandatory)] [string] $InfPath)

    try {
        $text = Get-Content -LiteralPath $InfPath -Raw -ErrorAction Stop
    }
    catch {
        return $null
    }
    $m = [regex]::Match($text, '(?im)^\s*Class\s*=\s*([A-Za-z0-9_]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Format-WfSize {
    param([double] $Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Test-WfUpdateContainer {
    <#
        Is this downloaded file actually an update package?

        An .msu is a container, and there are TWO container formats in use:

          MSCF   a cabinet. Everything up to and including Windows 10, and still
                 how .cab packages arrive.
          MSWIM  a WIM. Windows 11 24H2 and Server 2025 cumulative updates ship
                 this way. The extension did not change; the bytes behind it did.

        Checking for MSCF alone threw away a perfectly good 5.4 GB download of
        KB5121767 -- the file was fine, the check was wrong. DISM takes either.

        This stays an allow-list rather than "reject known-bad", because the
        failure it exists to catch is a proxy login page or a transfer cut short,
        and those can look like anything.

        Returns Ok/Kind/Signature/Reason rather than throwing, because the caller
        wants to discard the file and carry on to the next URL, not unwind.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [long] $MinimumBytes = 1MB
    )

    $result = [pscustomobject]@{ Ok = $false; Kind = 'Unknown'; Signature = ''; Reason = '' }

    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Reason = 'the file is not there'
        return $result
    }

    # Eight bytes off the front, via a stream. ReadAllBytes would pull a 5 GB
    # cumulative entirely into memory to inspect a header -- which works right
    # up until it doesn't.
    $magic = New-Object byte[] 8
    $read  = 0
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try   { $read = $stream.Read($magic, 0, 8) }
        finally { $stream.Dispose() }
    }
    catch {
        $result.Reason = "it could not be read -- $($_.Exception.Message)"
        return $result
    }

    if ($read -lt 4) {
        $result.Reason = 'it is empty or all but empty'
        return $result
    }

    # Unprintable bytes become dots so the signature is safe to put in a message.
    $result.Signature = -join ($magic[0..($read - 1)] | ForEach-Object {
        if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' }
    })

    if     ($result.Signature.StartsWith('MSCF'))  { $result.Kind = 'Cab' }
    elseif ($result.Signature.StartsWith('MSWIM')) { $result.Kind = 'Wim' }
    else {
        $result.Reason = "it is neither a cabinet nor a WIM (starts with '$($result.Signature)') -- usually a proxy login page, or a transfer cut short"
        return $result
    }

    # A container header is four bytes of reassurance and no more. A cumulative
    # that arrives at 40 KB has a valid header and is still useless.
    $length = (Get-Item -LiteralPath $Path).Length
    if ($MinimumBytes -gt 0 -and $length -lt $MinimumBytes) {
        $result.Reason = ('it is only {0} -- far too small for an update package' -f (Format-WfSize $length))
        return $result
    }

    $result.Ok = $true
    return $result
}

function Test-WfFileDigest {
    <#
        Does this file match the hash the catalog published for it?

        The Update Catalog's download dialog carries a digest per file, which is
        a far better answer than "is the length right" -- it catches a corrupted
        transfer that happens to be the correct size, and it is per-file, so it
        does not have the flaw the catalog's SIZE field has (that one is the total
        for the whole entry, which is what made a two-file update re-download the
        smaller half on every single run).

        The algorithm is not stated anywhere in the response, so it is inferred
        from the digest's length -- 20 bytes is SHA-1, 32 is SHA-256. That matters
        for more than tidiness: guessing wrong and trying both would mean two full
        passes over a 5 GB file to answer one question.

        Both base64 and hex are accepted because the encoding is equally
        undocumented and equally liable to change without notice.

        Returns rather than throws, and reports Checked = $false when there is no
        usable digest -- an unverifiable file is not a failed one.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Digest
    )

    $result = [pscustomobject]@{
        Ok = $true; Checked = $false; Algorithm = ''; Expected = "$Digest"; Actual = ''; Reason = ''
    }

    if (-not $Digest) { $result.Reason = 'the catalog published no digest'; return $result }
    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Ok = $false; $result.Reason = 'the file is not there'; return $result
    }

    # Decode, purely to learn how many bytes the hash is.
    #
    # Both encodings are tried and the one that yields a plausible hash length
    # wins, because "is this base64 or hex" has no safe answer on its own: a
    # 64-character hex SHA-256 is ALSO valid base64 (its alphabet is a subset,
    # and 64 is a multiple of 4). Decoding it as base64 succeeds, produces 48
    # meaningless bytes, and the digest is quietly written off as unreadable.
    $candidates = New-Object System.Collections.Generic.List[byte[]]

    if ($Digest -match '^[0-9a-fA-F]+$' -and ($Digest.Length % 2) -eq 0) {
        $hex = New-Object byte[] ($Digest.Length / 2)
        for ($i = 0; $i -lt $hex.Length; $i++) {
            $hex[$i] = [Convert]::ToByte($Digest.Substring($i * 2, 2), 16)
        }
        [void]$candidates.Add($hex)
    }
    try { [void]$candidates.Add([Convert]::FromBase64String($Digest)) } catch { }

    $want = $null
    foreach ($c in $candidates) { if ($c.Length -eq 20 -or $c.Length -eq 32) { $want = $c; break } }

    if (-not $want) {
        if ($candidates.Count -eq 0) {
            $result.Reason = "the digest is in a format this does not read: $Digest"
        }
        else {
            # Every length it could be, because an all-hex-looking base64 string
            # is genuinely two candidates and naming only the first is confusing.
            $lengths = @($candidates | ForEach-Object { $_.Length } | Sort-Object -Unique)
            $result.Reason = ("a digest of {0} byte(s) is neither SHA-1 nor SHA-256" -f ($lengths -join ' or '))
        }
        return $result
    }

    if ($want.Length -eq 20) { $result.Algorithm = 'SHA1' } else { $result.Algorithm = 'SHA256' }

    $have = $null
    try {
        $alg = [System.Security.Cryptography.HashAlgorithm]::Create($result.Algorithm)
        try {
            # ComputeHash(Stream) reads in blocks. ReadAllBytes on a 5 GB package
            # would need 5 GB of RAM to check 32 bytes of it.
            $fs = [System.IO.File]::OpenRead($Path)
            try   { $have = $alg.ComputeHash($fs) }
            finally { $fs.Dispose() }
        }
        finally { if ($alg) { $alg.Dispose() } }
    }
    catch {
        $result.Reason = "the file could not be hashed -- $($_.Exception.Message)"
        return $result
    }

    $result.Checked = $true
    $result.Actual  = [Convert]::ToBase64String($have)

    $same = ($have.Length -eq $want.Length)
    if ($same) {
        for ($i = 0; $i -lt $have.Length; $i++) {
            if ($have[$i] -ne $want[$i]) { $same = $false; break }
        }
    }

    if (-not $same) {
        $result.Ok     = $false
        $result.Reason = "the $($result.Algorithm) hash does not match what the catalog published"
    }
    return $result
}

function Get-WfWorkingCopyPath {
    <#
        Where the working copy of an image goes.

        This was one line -- ChangeExtension($ImagePath, 'working.wim') -- and it
        stacks. Service a file that is already someone's working copy and the log
        fills up with Win11IoTLTSC2024_FEC_XPOSH.working.working.wim, which is
        exactly the moment anyone is trying to work out which of three similar
        file names is the one that matters.

        Stripping the suffix before adding it back would name the copy after the
        source, so a collision is renamed rather than allowed: copying a file over
        itself is the sort of thing that empties it.

        Deliberately NOT avoiding files that merely exist. A leftover working copy
        from an interrupted run is overwritten, which is the old behaviour and the
        right one -- accumulating .working-2, -3, -4 across a month of failed runs
        would fill a disk with images nobody meant to keep.
    #>
    param([Parameter(Mandatory)] [string] $ImagePath)

    # Split by hand rather than through [IO.Path] or Split-Path, for the same
    # reason Join-WfPath exists: those go through the provider and answer for the
    # platform they are running on, and a path is being taken apart here, not
    # resolved. Pure string work gives the same answer everywhere, which is also
    # what makes it testable off a Windows box.
    $leaf = @($ImagePath -split '[\\/]')[-1]
    $dir  = $ImagePath.Substring(0, $ImagePath.Length - $leaf.Length).TrimEnd('\', '/')

    $stem = $leaf -replace '\.[^.]+$', ''          # drop the extension
    $stem = $stem -replace '(?i)\.working(-\d+)?$', ''   # and any suffix already there

    $copy = Join-WfPath $dir ($stem + '.working.wim')
    if ($copy -eq $ImagePath) { $copy = Join-WfPath $dir ($stem + '.working-2.wim') }
    return $copy
}

function Get-WfPackageIdentity {
    <#
        What is this update package FOR, read off its file name?

        Microsoft names a package for the release family it belongs to, and that
        name is the only signal available before anything is applied:

          windows10.0-kb5099539-x64_<hash>.msu        Windows 10 -- and Server
                                                      2019 and 2022, which are
                                                      named identically
          windows11.0-kb5121767-x64_<hash>.msu        Windows 11 client
          windows11.0-kb5062553-x64-2025_<hash>.msu   Windows Server 2025

        The last one is the reason this function exists. Windows 11 24H2 and
        Server 2025 are the same build -- 26100 -- and the catalog issues them
        under the SAME KB NUMBER: searching KB5062553 returns a Windows 11 x64
        entry, a Windows 11 arm64 entry and a "Microsoft server operating system
        version 24H2" entry. Three files, one KB, and by the time they are on
        disk the only thing telling them apart is the -2025 in the middle of the
        name. Downloading the wrong one is a click, not a mistake anyone would
        notice making.

        IsServer is deliberately three-valued:

          $true   the -2025 marker is there. This IS a server package.
          $false  a windows11.0 package without it -- server packages in that
                  generation always carry the marker, so its absence means
                  client.
          $null   a windows10.0 package. Server 2019 and Server 2022 packages
                  are named exactly like the client ones, so the name cannot
                  answer the question and this must not pretend it can.

        Generation is what the download folder is named after, so that a Server
        2025 cumulative and a Windows 11 24H2 cumulative -- same KB, same build,
        different images -- never end up in one directory.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Name)

    $result = [pscustomobject]@{ Major = 0; IsServer = $null; Generation = ''; ServerRelease = '' }

    $m = [regex]::Match("$Name", '(?i)^windows(\d+)\.0-')
    if (-not $m.Success) { return $result }

    $result.Major = [int]$m.Groups[1].Value

    # Anchored to the architecture token rather than searched for loosely: the
    # catalog appends a hash to the file name, and a bare '2025' would sooner or
    # later match four hex digits and file a client update as a server one.
    # The lookahead rather than \b: the catalog appends _<hash> to the file name,
    # and '_' is a word character, so \b never fires between '2025' and '_'.
    $srv = [regex]::Match("$Name", '(?i)-(?:x64|x86|arm64)-(\d{4})(?=[_.\-]|$)')
    if ($srv.Success) {
        $result.IsServer      = $true
        $result.ServerRelease = $srv.Groups[1].Value
        $result.Generation    = 'Server' + $srv.Groups[1].Value
        return $result
    }

    if ($result.Major -ge 11) { $result.IsServer = $false }
    $result.Generation = 'Windows' + $result.Major
    return $result
}

function ConvertTo-WfNaturalKey {
    <#
        A sort key that compares runs of digits as numbers rather than text.

        This exists because update packages have to be applied in age order and
        their age is encoded as a KB number in the file name. Plain string sort
        gets that right only by luck: it happens to work while every KB is seven
        digits starting with 5, and quietly puts "kb999999" after "kb5043080".
        The same trap catches the documented 01-/02- prefix escape hatch, where
        "10-" sorts before "2-".

        Padding every digit run to a fixed width makes both compare correctly,
        and leaves everything else ordering exactly as it did.
    #>
    param([string] $Text)
    if (-not $Text) { return '' }
    return [regex]::Replace($Text.ToLowerInvariant(), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
}

function Get-WfFolderSize {
    param([Parameter(Mandatory)] [string] $Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return 0 }
    return $sum
}

function New-WfDismOutputState {
    <#
        The state one dism.exe run's output is folded into.

        Split out of Invoke-WfDism so the folding can be TESTED. What it does is
        not obvious -- it drops thousands of lines on purpose, keeps a few, and
        lets one through per minute -- and none of that could be exercised while
        it lived inside a function whose first act is to launch dism.exe.
    #>
    param(
        [int] $HeartbeatSeconds = 60,
        [datetime] $Now = (Get-Date)
    )

    return @{
        Bar              = '^\[[=\s]*\d+[.,]?\d*%[=\s]*\]$'
        LastBar          = $null
        Dropped          = 0
        Beats            = 0
        HeartbeatSeconds = $HeartbeatSeconds
        LastBeat         = $Now
        Kept             = (New-Object System.Collections.Generic.List[string])
        All              = (New-Object System.Collections.Generic.List[string])
    }
}

function Add-WfDismOutputLine {
    <#
        One chunk of dism.exe output, folded into the state.

        DISM draws its progress bar by rewriting ONE line with carriage returns.
        On a live console that is a moving bar; captured, every redraw becomes
        its own line, and a single /ResetBase writes several hundred
        near-identical bars into the log. Applying a 24H2 cumulative produced
        11,522 of them.

        So they are dropped -- with two exceptions.

        The last bar of a run is kept, because it is the evidence the operation
        reached the end rather than stopping at 43%.

        And one is let through every HeartbeatSeconds. That one is not
        decoration: the same 24H2 apply took 17 minutes 49 seconds and printed
        NOTHING for the whole of it, because the output was collected first and
        written afterwards. On the longest single step of a three-hour run the
        only sign of life was a marquee. A percentage once a minute is the
        smallest thing that answers "is it still going".

        $Now is a parameter rather than a call to Get-Date so a test can drive
        the clock. Timing behaviour that can only be tested by waiting is timing
        behaviour that does not get tested.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [AllowEmptyString()]   [string]    $Raw,
        [datetime] $Now = (Get-Date)
    )

    # Split on the carriage returns first: several redraws can arrive inside a
    # single element, since the stream only breaks on newlines.
    foreach ($piece in ("$Raw" -split "`r")) {
        $t = "$piece".Trim()
        if (-not $t) { continue }
        $State.All.Add($t)

        if ($t -match $State.Bar) {
            $State.LastBar = $t
            $State.Dropped++

            if (($Now - $State.LastBeat).TotalSeconds -ge $State.HeartbeatSeconds) {
                Write-WfLog ("  still working -- {0}" -f $t) -Level INFO
                $State.LastBeat = $Now
                $State.Beats++
                # Written, so neither collapsed nor written again later.
                $State.LastBar  = $null
                $State.Dropped--
            }
            continue
        }

        # A run of bars has ended -- emit the final one before whatever follows
        # it, so the log keeps its order.
        if ($State.LastBar) {
            Write-WfLog $State.LastBar -Level INFO -NoConsole
            $State.LastBar = $null
            $State.Dropped--
        }
        Write-WfLog $t -Level INFO -NoConsole
        $State.Kept.Add($t)
    }
}

function Complete-WfDismOutput {
    <# The trailing bar, and the disclosure of what was dropped. #>
    param([Parameter(Mandatory)] [hashtable] $State)

    if ($State.LastBar) {
        Write-WfLog $State.LastBar -Level INFO -NoConsole
        $State.LastBar = $null
        $State.Dropped--
    }

    # Said rather than silently swallowed: a reader should know the log is a
    # summary of what DISM printed, not a transcript of it.
    if ($State.Dropped -gt 0) {
        Write-WfLog ("({0} progress-bar redraws collapsed)" -f $State.Dropped) -Level INFO -NoConsole
    }
}

function Invoke-WfDism {
    <#
        dism.exe wrapper -- for /ResetBase and /AnalyzeComponentStore, which the
        DISM PowerShell module does not expose, and for applying WIM-format .msu
        packages, which it exposes and cannot do (see Add-WfPackageOffline).

        The output is STREAMED rather than collected and written at the end, so a
        long operation reports progress while it is running instead of in one
        burst once it is over.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $PassThruOutput,
        # How often a long operation is allowed to say it is still alive.
        [int] $HeartbeatSeconds = 60
    )

    Write-WfLog ("dism.exe {0}" -f ($Arguments -join ' ')) -Level INFO

    $state = New-WfDismOutputState -HeartbeatSeconds $HeartbeatSeconds

    # A native command's stderr, redirected with 2>&1, arrives as ErrorRecord
    # objects -- and under $ErrorActionPreference = 'Stop' those terminate the
    # pipeline as a NativeCommandError. Collecting the output into a variable
    # never had that problem; streaming it does. Assigning the preference here
    # makes a function-local copy, so nothing outside this call is affected.
    $ErrorActionPreference = 'Continue'

    & dism.exe @Arguments 2>&1 | ForEach-Object { Add-WfDismOutputLine -State $state -Raw "$_" }
    $code = $LASTEXITCODE

    Complete-WfDismOutput -State $state

    if ($code -ne 0) {
        # Carry DISM's own words into the exception, not just the exit code.
        #
        # An exit code alone is nearly useless to the classifier: Get-WfDismError
        # reads a MESSAGE and looks for 0x........ in it, and dism.exe puts the
        # code in its output ("Error: 0x800f081e") while returning a decimal exit
        # status that does not always match. Throwing only "exit 2" meant every
        # dism.exe failure came back unrecognised, which is exactly the outcome
        # this toolkit exists to avoid -- and it matters more now that package
        # application goes through dism.exe rather than Add-WindowsPackage.
        $detail = @($state.Kept | Where-Object {
            $_ -match '0x[0-9a-fA-F]{8}' -or $_ -match '(?i)^error[:\s]' -or $_ -match '(?i)^the .*(failed|error)'
        } | Select-Object -Last 4)

        $suffix = ''
        if ($detail.Count -gt 0) { $suffix = ' -- ' + ($detail -join ' ') }
        elseif ($state.Kept.Count -gt 0) { $suffix = ' -- ' + (@($state.Kept | Select-Object -Last 2) -join ' ') }

        throw ("dism.exe failed (exit {0}){1}. Arguments: {2}" -f $code, $suffix, ($Arguments -join ' '))
    }
    if ($PassThruOutput) { return $state.All }
}

function Add-WfPackageOffline {
    <#
        Applies ONE package to a mounted image, and decides how.

        Cabinet-format packages go through Add-WindowsPackage, which is the
        obvious thing and has never given trouble. WIM-format .msu files -- the
        UUP packages Windows 11 24H2, 25H2 and Server 2025 ship as -- go through
        dism.exe instead, in its own process.

        That split is not stylistic. It is the conclusion of a long hunt:

          Add-WindowsPackage  ->  0x800401E3, five times out of five, and
                                  surfacing as "An error occurred applying the
                                  Unattend.xml file from the .msu package".
          dism.exe /Add-Package on the SAME image, the SAME package, minutes
                                  later ->  "The operation completed successfully."

        Everything else had already been eliminated by then: the download was
        SHA-verified against the catalog, the host servicing stack (26100.8737)
        was newer than the image (26100.7623), the scratch volume had 244 GB
        free, wuauserv was Manual/Running, the WUA COM object could be created
        by hand, no WSUS policy was in the way, the checkpoint was not beside
        the target, and a clean vanilla 24H2 image failed identically.

        What is left is the hosting. DISM does not unpack a UUP package itself;
        it hands it to the Windows Update Agent over COM. The cmdlet loads
        DismApi IN-PROCESS, inside the PowerShell host, and on a locked-down
        machine that COM activation comes back MK_E_UNAVAILABLE. dism.exe is a
        separate process with its own apartment and its own hosting, and there
        the same activation succeeds.

        So the fix is not "use another machine". It is: for the packages that
        need the update agent, let the process Microsoft ships do the asking.

        Returns 'DismExe' or 'Cmdlet' -- which one ran is worth having in the
        log and worth being able to assert in a test.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $MountPath,
        [Parameter(Mandatory)] [string] $PackagePath,
        [string] $ScratchDirectory,
        [string] $LogPath
    )

    # MinimumBytes 0 because size is not the question here -- format is. A file
    # too small to be a real package fails at apply time with DISM's own words,
    # which is a better message than anything invented at this point.
    $kind = 'Unknown'
    try { $kind = (Test-WfUpdateContainer -Path $PackagePath -MinimumBytes 0).Kind } catch { }

    if ($kind -ne 'Wim') {
        $params = @{ Path = $MountPath; PackagePath = $PackagePath; ErrorAction = 'Stop' }
        if ($ScratchDirectory) { $params['ScratchDirectory'] = $ScratchDirectory }
        if ($LogPath)          { $params['LogPath']          = $LogPath }
        Add-WindowsPackage @params | Out-Null
        return 'Cmdlet'
    }

    # Trailing backslashes are stripped before these become command-line
    # arguments: PowerShell quotes an argument containing spaces, and a trailing
    # \ then escapes the closing quote, which hands dism.exe a mangled path.
    $dismArgs = @(
        ('/Image:{0}'       -f $MountPath.TrimEnd('\')),
        '/Add-Package',
        ('/PackagePath:{0}' -f $PackagePath)
    )
    if ($ScratchDirectory) { $dismArgs += ('/ScratchDir:{0}' -f $ScratchDirectory.TrimEnd('\')) }
    if ($LogPath)          { $dismArgs += ('/LogPath:{0}'    -f $LogPath) }

    Invoke-WfDism -Arguments $dismArgs | Out-Null
    return 'DismExe'
}

function Get-WfLocalUbr {
    <#
        Win32_OperatingSystem.Version stops at major.minor.build; the UBR (the
        patch level, .7417 in 10.0.19044.7417) only exists in the registry, and
        the UBR is the number that actually tells you what is installed.
    #>
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -ErrorAction SilentlyContinue
    if ($p) { return $p.UBR }
    return $null
}

function ConvertTo-WfHashtable {
    <#
        PS 5.1's ConvertFrom-Json has no -AsHashtable, and the config code wants a
        mutable hashtable rather than a PSCustomObject.

        Scalars are tested FIRST and returned untouched. That ordering is not
        cosmetic: [PSCustomObject] is a type accelerator for PSObject, and in
        PowerShell *everything* satisfies `-is [PSCustomObject]` -- including a
        plain string. Testing that branch first turns every string in the config
        into a hashtable of its .Length property, which silently destroyed
        BootDriverClasses and took the boot-driver filter down with it.
    #>
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    # Scalars: strings, numbers, booleans, dates. Return as-is.
    if ($InputObject -is [string] -or
        $InputObject -is [bool] -or
        $InputObject -is [datetime] -or
        $InputObject -is [decimal] -or
        $InputObject.GetType().IsPrimitive) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($k in $InputObject.Keys) { $out[$k] = ConvertTo-WfHashtable $InputObject[$k] }
        return $out
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        return @($InputObject | ForEach-Object { ConvertTo-WfHashtable $_ })
    }

    # Anything left with properties -- notably ConvertFrom-Json's PSCustomObjects
    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Name.Count -gt 0) {
        $out = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $out[$p.Name] = ConvertTo-WfHashtable $p.Value }
        return $out
    }

    return $InputObject
}
