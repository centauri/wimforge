# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    DismErrors.ps1 -- turning a hex code into something you can act on.

    DISM's failure messages are technically accurate and practically useless. The
    one everybody meets first:

        Add-WindowsPackage : The specified package is not applicable to this
        image. Error: 0x800f081e

    Which is true, and says nothing about why -- and the why is nearly always one
    of three ordinary things: the update is already in the image, it is for a
    different edition, or it is for a different build. All three have different
    answers and none of them is "the tool is broken".

    So every DISM failure this toolkit surfaces goes through here first. The
    original message is always kept: the translation is added, never substituted,
    because a wrong guess about an unfamiliar code must not hide the only real
    evidence there was.

    Codes are the CBS and Windows Update ones actually seen while servicing
    offline images. Anything not listed comes back untranslated and says so.
#>

function Get-WfDismLogTail {
<#
.SYNOPSIS
    The error lines DISM wrote to its own log during the last few minutes.
.DESCRIPTION
    "For more information, review the log file" is where a servicing failure
    usually stops being diagnosable, because the log is a 40 MB file in a folder
    nobody has open and the interesting part is eleven lines somewhere in the
    middle. Worse, the message DISM raises to PowerShell often carries no hex
    code at all while the log line right behind it does -- so the one piece of
    information that would identify the failure is the piece that gets dropped.

    This reads the tail of dism.log, keeps the lines DISM itself marked as errors,
    and hands them back. It is best-effort by design: no log, no permission, or a
    different DISM build all produce an empty result rather than an exception, and
    a diagnostic must never become the thing that fails.
.PARAMETER Since
    Ignore entries older than this. Passing the time the operation started keeps
    the previous run's failures out of this run's diagnosis.
.PARAMETER MaxLines
    How many error lines to return, newest last.
.PARAMETER LogPath
    Defaults to %WINDIR%\Logs\DISM\dism.log.
#>
    [CmdletBinding()]
    param(
        [datetime] $Since,
        [int]      $MaxLines = 12,
        [string]   $LogPath
    )

    # Everything about locating the log is inside the try, including building the
    # path. Join-Path validates the drive, so on a machine where %WINDIR% is not
    # set it throws "a drive with the name 'C' does not exist" -- and this is a
    # diagnostic that runs while handling somebody else's failure. Throwing here
    # replaces the real error with a meaningless one.
    try {
        if (-not $LogPath) {
            $windir = $env:WINDIR
            if (-not $windir) { $windir = 'C:\Windows' }
            $LogPath = Join-Path $windir 'Logs\DISM\dism.log'
        }
        if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return @() }
    }
    catch { return @() }

    # -Tail reads backwards from the end. dism.log runs to tens of megabytes on a
    # machine that services images regularly, and reading all of it to look at the
    # last page would be slower than the operation that just failed.
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $LogPath -Tail 600 -ErrorAction Stop) }
    catch { return @() }

    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        # DISM's own severity column, plus anything carrying an HRESULT -- some
        # of the most useful lines are logged at Info with the code attached.
        if ($line -notmatch '(?i)\berror\b|hr\s*[:=]\s*0x|0x8[0-9a-f]{7}') { continue }

        if ($Since) {
            $t = [regex]::Match($line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
            if ($t.Success) {
                $when = [datetime]::MinValue
                if ([datetime]::TryParse($t.Groups[1].Value, [ref]$when) -and $when -lt $Since) { continue }
            }
        }
        [void]$keep.Add($line.Trim())
    }

    if ($keep.Count -le $MaxLines) { return $keep.ToArray() }
    return $keep.ToArray()[($keep.Count - $MaxLines)..($keep.Count - 1)]
}

function Get-WfDismError {
<#
.SYNOPSIS
    Explains a DISM failure in terms of what to do about it.
.DESCRIPTION
    Pulls the hex code out of a DISM or CBS message and returns the code, a plain
    explanation, what to do next, and whether it is fatal.

    "Fatal" here means something went wrong. A package that does not apply to the
    image is NOT fatal -- it is the expected outcome of pointing an Updates folder
    holding several builds at one image, and treating it as a failure means a
    servicing run that was entirely successful reports as broken.
.PARAMETER Message
    The exception message, or any text containing the code.
.EXAMPLE
    Get-WfDismError -Message $_.Exception.Message
#>
    [CmdletBinding()]
    param([string] $Message)

    $result = [pscustomobject]@{
        Code        = ''
        Summary     = ''
        WhatToDo    = ''
        Fatal       = $true
        Recognised  = $false
        Original    = "$Message"
    }

    if (-not $Message) {
        $result.Summary = 'No message was given.'
        return $result
    }

    $m = [regex]::Match($Message, '0x[0-9a-fA-F]{8}')
    if (-not $m.Success) {
        # Not every DISM failure carries a code, and a few of the codeless ones
        # are actively misleading rather than "plain enough on their own". Those
        # are matched on their text.
        $byText = @(
            @{
                Match   = 'Unattend\.xml file from the \.msu package'
                Summary = 'DISM could not apply the descriptor that lives inside the .msu.'
                # This message is a poor witness. It is raised for anything that
                # goes wrong while the MSU manager is working, and the actual
                # cause is a code it does not print -- which is why the log tail
                # below matters more than this text does.
                #
                # Ordered by what has actually turned out to be true, which is
                # not the order things were guessed in. Two earlier leads here --
                # a disabled Windows Update service, then a checkpoint .msu in
                # the same folder -- were both disproven: the failure reproduces
                # with wuauserv Manual/Running and with the target alone.
                WhatToDo = 'Nothing is missing from your disk: every .msu carries its own XML, and applying that XML is how DISM installs the package. The error is about that file, not about an answer file of yours. This message is raised for several different underlying faults, so read the dism.log lines below -- they carry the code that identifies which. In order of likelihood: the package is a UUP one (Windows 11 24H2 and later, Server 2025) and was applied with Add-WindowsPackage, which cannot reach the Windows Update Agent from inside PowerShell and fails as 0x800401E3 -- apply it with dism.exe /Add-Package instead, which is what WimForge now does; or another .msu is sitting in the same folder as the one being applied, which can fail as 0x80070228 -- apply the target on its own; or the servicing stack here is older than the image, which needs a 24H2 host or the matching ADK; or there is not enough scratch space to expand a multi-GB package; or, for older cabinet-format .msu files, the package needs extracting and its inner .cab applying instead.'
                Fatal   = $true
            }
        )
        foreach ($t in $byText) {
            if ($Message -match $t.Match) {
                $result.Summary    = $t.Summary
                $result.WhatToDo   = $t.WhatToDo
                $result.Fatal      = $t.Fatal
                $result.Recognised = $true
                return $result
            }
        }

        $result.Summary = $Message.Trim()
        return $result
    }

    $result.Code = $m.Value.ToLowerInvariant()

    # Keyed on the code, which is what actually varies. The text is written for
    # somebody standing in front of a failed servicing run, not for a reference
    # manual -- each one says what happened and what to try.
    $known = @{
        '0x800f081e' = @{
            Summary  = 'The package does not apply to this image.'
            WhatToDo = 'Almost always one of three things: it is already in the image, it is for a different edition, or it is for a different build. Read this image on the Updates tab -- the release it reports is the one the update has to match, and remember an LTSC 2021 image (build 19044) takes updates titled "Windows 10 Version 22H2".'
            Fatal    = $false
        }
        '0x800f0831' = @{
            Summary  = 'A package this update builds on is missing from the image.'
            WhatToDo = 'The image is behind: this update expects an earlier cumulative that was never applied. Apply the current combined cumulative first -- since February 2021 the servicing stack and the LCU ship as one .msu, so there is usually nothing to sequence by hand.'
            Fatal    = $true
        }
        '0x800f0823' = @{
            Summary  = 'The image needs a newer servicing stack before this update can apply.'
            WhatToDo = 'Apply the current combined cumulative for this release first, then retry.'
            Fatal    = $true
        }
        '0x800f0922' = @{
            Summary  = 'The image ran out of room, or a step could not complete.'
            WhatToDo = 'Usually disk space. A cumulative needs several GB free on the mount volume AND on the scratch volume, and the two are often the same disk. Housekeeping > Environment check reports both.'
            Fatal    = $true
        }
        '0x80070070' = @{
            Summary  = 'Not enough disk space.'
            WhatToDo = 'Free space on the volume holding the mount and the scratch folder, then retry. A cumulative wants several GB beyond the mounted image itself.'
            Fatal    = $true
        }
        '0x80070005' = @{
            Summary  = 'Access denied.'
            WhatToDo = 'Either the session is not elevated, or something is holding files in the mount open -- real-time antivirus and sync clients are the usual culprits. Test-WfMountPath says whether the mount folder is somewhere that happens.'
            Fatal    = $true
        }
        '0x80070020' = @{
            Summary  = 'A file in the mount is locked by another process.'
            WhatToDo = 'Something is reading the mounted image while DISM writes to it: antivirus, a backup agent, an open Explorer window, or a search indexer. Close what you can and exclude the mount folder from scanning.'
            Fatal    = $true
        }
        '0x80070570' = @{
            Summary  = 'The file is corrupt or unreadable.'
            WhatToDo = 'The download is bad. Delete it from the Updates folder and fetch it again -- Save-WfUpdate checks the cabinet header, so a file that got past that and still reads as corrupt was damaged after it landed.'
            Fatal    = $true
        }
        '0x800f0825' = @{
            Summary  = 'The package applied but could not be committed permanently.'
            WhatToDo = 'Usually a component store that needs repairing. Run component cleanup against the image, then retry; if it repeats, the base image is the problem rather than the update.'
            Fatal    = $true
        }
        '0x800f082f' = @{
            Summary  = 'The package could not be staged.'
            WhatToDo = 'Generally a corrupted component store in the image. Try component cleanup, and if the same package fails on a fresh copy of the base image, re-capture the base.'
            Fatal    = $true
        }
        '0x800f0805' = @{
            Summary  = 'DISM did not recognise the package.'
            WhatToDo = 'Either the file is not a real .msu/.cab, or the path is wrong. A downloaded HTML error page saved with a .msu name looks exactly like this.'
            Fatal    = $true
        }
        '0x8007007b' = @{
            Summary  = 'The path or file name is not valid.'
            WhatToDo = 'Check for a stray quote in the path, and for a path long enough to be running into MAX_PATH -- a mount folder deep inside a project directory is the usual cause.'
            Fatal    = $true
        }
        '0x800f0906' = @{
            Summary  = 'The source files could not be downloaded.'
            WhatToDo = 'Enabling a feature such as NetFx3 needs a source. Point it at \sources\sxs on the matching installation media rather than letting it reach for Windows Update.'
            Fatal    = $true
        }
        '0x800f081f' = @{
            Summary  = 'The source files could not be found.'
            WhatToDo = 'Same as above, but the source given does not contain what was asked for. Check it is the \sources\sxs folder from media matching this image''s build.'
            Fatal    = $true
        }
        '0xc1420127' = @{
            Summary  = 'The image is still mounted somewhere.'
            WhatToDo = 'A previous run was interrupted and left the mount behind. Housekeeping > Repair stale mounts discards it and runs dism /Cleanup-Mountpoints.'
            Fatal    = $true
        }
        '0xc1420117' = @{
            Summary  = 'The mount folder is in use.'
            WhatToDo = 'Something has the folder open -- an Explorer window in it is enough. Close it and retry; if that does not help, Repair stale mounts.'
            Fatal    = $true
        }
        '0x80070002' = @{
            Summary  = 'The file was not found.'
            WhatToDo = 'The path does not exist as this machine sees it. On anything to do with the reference VM, check whether the path is meant to be one the Hyper-V HOST can see rather than this workstation.'
            Fatal    = $true
        }
        # MK_E_UNAVAILABLE. A COM error, which is a strange thing to meet in the
        # middle of offline servicing -- until you read the lines around it:
        #
        #   ReportEventDownloadRequestEnd: hr = [0x800401E3]
        #   MsuManager: Failed getting the download request.
        #               CDismMsuManager::ProcessWithUpdateAgent(hr:0x800401e3)
        #   MsuManager: Failed to install UUP package.
        #
        # A Windows 11 24H2 cumulative is a UUP package in WIM-format .msu
        # clothing, and DISM does not unpack those itself. It hands them to the
        # Windows Update Agent, over COM, on THIS machine. The activation comes
        # back MK_E_UNAVAILABLE and the message that surfaces talks about an
        # Unattend.xml, which is three layers away from the actual problem.
        #
        # Two earlier explanations of this entry were WRONG and are recorded
        # here so nobody spends an evening on them again:
        #
        #   "wuauserv is disabled"      -- it fails with wuauserv Manual/Running,
        #                                  and the WUA COM object creates fine by
        #                                  hand from the same PowerShell session.
        #   "the checkpoint is beside   -- it fails with the target .msu alone in
        #    the target"                   its own folder, and a clean vanilla
        #                                  24H2 image fails identically.
        #
        # What finally separated cause from coincidence was running the SAME
        # package against the SAME mounted image with dism.exe:
        #
        #   dism.exe /Image:C:\WimMount /Add-Package /PackagePath:<the .msu>
        #   ...
        #   The operation completed successfully.
        #
        # Five failures from the cmdlet, one success from the executable, minutes
        # apart. The difference is the process: Add-WindowsPackage loads DismApi
        # in-process inside the PowerShell host, and on a locked-down machine the
        # update agent cannot be activated from there. dism.exe asks from its own
        # process and gets an answer.
        #
        # Nothing is wrong with the image, the package or the network.
        '0x800401e3' = @{
            Summary  = 'DISM could not reach the Windows Update Agent from inside PowerShell, so the UUP package could not be unpacked.'
            WhatToDo = 'This is NOT about the Windows Update service -- it fails with wuauserv Manual/Running, and it is not about a checkpoint sitting beside the target either; it fails with the update alone in its own folder, and on a clean untouched image. A Windows 11 24H2 (or 25H2, or Server 2025) cumulative is a UUP package, and DISM hands those to the Windows Update Agent over COM instead of unpacking them itself. Add-WindowsPackage loads DISM in-process, inside the PowerShell host, and on a hardened workstation that COM activation is refused -- MK_E_UNAVAILABLE. The same package applies to the same image when dism.exe does it, because dism.exe is a separate process. WimForge now applies WIM-format packages with dism.exe /Add-Package for exactly this reason, so seeing this code again means something bypassed that path -- Add-WindowsPackage called directly, or an old copy of the module. To reproduce the working call by hand:  dism.exe /Image:<mount> /Add-Package /PackagePath:<the .msu> /ScratchDir:<scratch>'
            Fatal    = $true
        }
    }

    if ($known.ContainsKey($result.Code)) {
        $entry             = $known[$result.Code]
        $result.Summary    = $entry.Summary
        $result.WhatToDo   = $entry.WhatToDo
        $result.Fatal      = $entry.Fatal
        $result.Recognised = $true
    }
    else {
        $result.Summary  = "DISM failed with $($result.Code)."
        $result.WhatToDo = 'Not a code this toolkit has seen before. The full message is below, and the DISM log at %WINDIR%\Logs\DISM\dism.log has the detail.'
    }

    return $result
}

function Format-WfDismError {
<#
.SYNOPSIS
    A DISM failure written out for a human, explanation first, original last.
.DESCRIPTION
    Order matters. What happened and what to do go at the top, because that is
    what is being looked for; the raw message goes underneath, because when the
    translation is wrong that message is the only real evidence there is and
    hiding it would be the worse failure.
.PARAMETER Message
    The exception message.
.PARAMETER Context
    What was being attempted, e.g. a package name.
.EXAMPLE
    Format-WfDismError -Message $_.Exception.Message -Context 'windows10.0-kb5094127.msu'
#>
    [CmdletBinding()]
    param(
        [string] $Message,
        [string] $Context
    )

    $e     = Get-WfDismError -Message $Message
    $lines = New-Object System.Collections.Generic.List[string]

    if ($Context) { $lines.Add($Context) ; $lines.Add('') }

    $lines.Add($e.Summary)
    if ($e.WhatToDo) { $lines.Add('') ; $lines.Add($e.WhatToDo) }

    if ($e.Original -and $e.Original.Trim() -ne $e.Summary) {
        $lines.Add('')
        $lines.Add('What DISM said:')
        $lines.Add($e.Original.Trim())
    }

    return ($lines -join [Environment]::NewLine)
}

function Get-WfUpdateProductChoice {
<#
.SYNOPSIS
    The product strings worth searching the catalog for, so one can be picked.
.DESCRIPTION
    The catalog is searched by the words in an update's title, and those words
    are a Microsoft naming convention rather than anything derivable. Typed from
    memory they are wrong in ways that return zero results and look like there is
    no update available.

    The one that catches everyone: a servicing family shares a single cumulative,
    and it is titled with the NEWEST release in the family. An LTSC 2021 image is
    build 19044, and the update it needs is titled **Windows 10 Version 22H2**.
    Searching for "21H2" finds nothing. That is not a bug in the catalog and it
    is not a bug here; it is how the packages are named, so the list says so.

    Anything read from an image is put at the top and marked, because it is the
    answer that came from evidence rather than from a list.
.PARAMETER Target
    A Get-WfImageUpdateTarget result, if one has been read.
.EXAMPLE
    Get-WfUpdateProductChoice
#>
    [CmdletBinding()]
    param([object] $Target)

    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    $add = {
        param([string] $Value, [string] $Note, [bool] $FromImage)
        if (-not $Value -or $seen.ContainsKey($Value)) { return }
        $seen[$Value] = $true
        $out.Add([pscustomobject]@{ Product = $Value; Note = $Note; FromImage = $FromImage })
    }

    if ($Target) {
        $note = 'read from the image'
        if (-not $Target.Precise) {
            $note = 'guessed from the image -- the WIM header cannot tell one release in a family from another'
        }
        & $add $Target.Product $note $true

        foreach ($alt in @($Target.ProductAlternative | Where-Object { $_ })) {
            & $add $alt 'also tried, from the image' $true
        }
    }

    # The families this toolkit is pointed at. Written down because there is
    # nothing to read them from -- but each one says what it is FOR, which is the
    # part that is otherwise guesswork.
    & $add 'Windows 10 Version 22H2' 'the LTSC 2021 answer: build 19044 takes updates titled 22H2, because the family shares one cumulative' $false
    & $add 'Windows 10 Version 21H2' 'only if a package is genuinely titled 21H2 -- for LTSC 2021 servicing, use 22H2 above' $false
    & $add 'Windows 10 Version 1809' 'LTSC 2019, build 17763' $false
    & $add 'Windows 10 Version 1607' 'LTSC 2016, build 14393' $false
    & $add 'Windows 11 Version 24H2' 'build 26100, including IoT Enterprise LTSC 2024' $false
    & $add 'Windows 11 Version 23H2' 'build 22631' $false
    & $add 'Windows 11 Version 22H2' 'build 22621' $false
    # Server, where the catalog's own names are the whole problem. From Server
    # 2022 onward Microsoft stopped titling these "Windows Server" at all: the
    # cumulative for Server 2025 is "2025-07 Cumulative Update for Microsoft
    # server operating system version 24H2 for x64-based Systems (KB5062553)".
    # Searching for the name on the box returns nothing at all -- the same trap
    # as the LTSC 2021 one above, and harder to guess your way out of.
    & $add 'Microsoft server operating system version 24H2' 'Server 2025, build 26100 -- the catalog does NOT call this "Windows Server 2025"' $false
    & $add 'Microsoft server operating system version 21H2' 'Server 2022, build 20348 -- same naming, and nothing to do with Windows 10 21H2' $false
    & $add 'Windows Server 2019'     'build 17763 -- old enough to still be titled the obvious way' $false
    & $add 'Windows Server 2016'     'build 14393' $false
    & $add 'Windows Server 2025'     'worth a try as a second search: a few entries for build 26100 are titled this way, but the cumulative is not' $false
    & $add 'Windows Server 2022'     'as above, for build 20348' $false

    return $out.ToArray()
}

function Get-WfUpdateArchitectureChoice {
<#
.SYNOPSIS
    The architectures the catalog labels updates with.
.DESCRIPTION
    A short fixed list, and it is fixed because these are the words in the
    catalog's own titles rather than anything read off a machine. 'amd64' is not
    one of them, which is the mistake worth preventing.
.EXAMPLE
    Get-WfUpdateArchitectureChoice
#>
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ Architecture = 'x64';   Note = '64-bit Intel or AMD -- what a POS estate almost always is' }
        [pscustomobject]@{ Architecture = 'x86';   Note = '32-bit' }
        [pscustomobject]@{ Architecture = 'ARM64'; Note = 'ARM' }
    )
}
