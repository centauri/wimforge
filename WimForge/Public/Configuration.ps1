# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Configuration.ps1 -- where everything lives, plus the environment self-check
    and the build history log.

    One JSON file holds every path the toolkit uses, so moving the image share
    is a one-line edit rather than a search through scripts. It is resolved in
    this order: an explicit -Path, then WimForge.config.json next to the
    module, then %ProgramData%\WimForge\config.json.
#>

function Get-WfConfig {
<#
.SYNOPSIS
    Loads the toolkit configuration, creating a default one if none exists.
.DESCRIPTION
    Read once and cached for the session, so the hundreds of calls that ask for a
    path do not each hit the disk. Set-WfConfig is what writes and refreshes it.

    A missing configuration is not an error -- it is a first run. Rather than
    fail, this builds a default from a real drive on this machine and hands that
    back, which is what makes the toolkit usable before anything has been set up.
.PARAMETER Path
    Explicit config file to load. Omit to use the standard search order.
.PARAMETER Refresh
    Re-read from disk instead of returning the cached copy.
#>
    [CmdletBinding()]
    param(
        [string] $Path,
        [switch] $Refresh
    )

    if ($script:WfConfig -and -not $Refresh -and -not $Path) { return $script:WfConfig }

    # An explicit -Path that does not exist is an error, not a reason to quietly
    # fall through to a different configuration.
    if ($Path -and -not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    $candidates = @()
    if ($Path) {
        $candidates += $Path
    }
    elseif ($script:WfConfigPath) {
        # A -Refresh after an explicit -Path must reload THAT file. Without this,
        # every Set-WfConfig followed by a refresh silently jumps back to the
        # default config, and a front-end started with -ConfigPath quietly ends up
        # running against a different file than the one it was told to use.
        $candidates += $script:WfConfigPath
    }
    $candidates += (Join-WfPath (Split-Path $PSScriptRoot -Parent) 'WimForge.config.json')
    if ($env:ProgramData) {
        $candidates += (Join-WfPath $env:ProgramData 'WimForge\config.json')
    }

    $found = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

    if (-not $found) {
        # First run on this machine. Defaults are derived from a drive that
        # actually exists here, never a hardcoded letter.
        $found = $candidates[-1]
        Write-WfLog "No configuration found -- writing defaults to $found" -Level WARN
        New-WfDirectory (Split-Path $found -Parent) | Out-Null
        (Get-WfDefaultConfig | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath $found -Encoding UTF8
    }

    $cfg = $null
    try {
        $raw = Get-Content -LiteralPath $found -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $cfg = ConvertTo-WfHashtable $raw
    }
    catch {
        Write-WfLog "Configuration at $found is unreadable ($($_.Exception.Message)) -- using defaults." -Level ERROR
    }

    # A corrupt or empty file must not take the whole tool down; the front-ends
    # can still start and let the operator fix it from Settings.
    if ($cfg -isnot [hashtable]) { $cfg = @{} }

    # Anything added to the defaults after a site already has a config file gets
    # filled in here, so upgrading the toolkit never breaks on a missing key.
    $defaults = Get-WfDefaultConfig
    foreach ($key in $defaults.Keys) {
        if (-not $cfg.ContainsKey($key)) { $cfg[$key] = $defaults[$key] }
    }

    $script:WfConfig     = $cfg
    $script:WfConfigPath = $found

    Initialize-WfLog -LogRoot $cfg['LogRoot'] | Out-Null
    return $cfg
}

function Get-WfConfigPath {
<#
.SYNOPSIS
    Returns the file the current configuration was loaded from.
.DESCRIPTION
    Worth asking when something is not where you expected it. A machine can have
    more than one configuration -- the launchers accept -ConfigPath -- and the
    answer to "why is it looking there" is usually this.
.EXAMPLE
    Get-WfConfigPath
#>
    [CmdletBinding()]
    param()
    if (-not $script:WfConfigPath) { Get-WfConfig | Out-Null }
    return $script:WfConfigPath
}

function Get-WfSuggestedRoot {
<#
.SYNOPSIS
    Suggests an imaging workspace root on a drive that actually exists here.
.DESCRIPTION
    Picks the fixed local drive with the most free space -- images are large, and
    the system drive is rarely the right home for them. Falls back to the system
    drive when nothing else qualifies. Never returns a path on a drive that is not
    present, which is exactly the failure a config copied between workstations
    produces.
#>
    [CmdletBinding()]
    param([int] $MinimumFreeGb = 30)

    $best = $null
    try {
        # DriveType 3 = local fixed disk. Removable and network drives are not
        # somewhere to point a build workspace.
        $best = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
                Where-Object { $_.FreeSpace -ge ($MinimumFreeGb * 1GB) } |
                Sort-Object FreeSpace -Descending |
                Select-Object -First 1
    }
    catch { }

    $drive = $env:SystemDrive
    if ($best) { $drive = $best.DeviceID }
    if (-not $drive) { $drive = 'C:' }

    return (Join-WfPath $drive 'Imaging')
}

function Get-WfWorkspaceOption {
<#
.SYNOPSIS
    The candidate workspace folders on this machine, each with why it is or is
    not a good idea.
.DESCRIPTION
    First run used to suggest one folder. This offers the real choices instead --
    the roomiest fixed drive, the system drive, and the folder the toolkit is
    sitting in -- because "put everything next to the tool" is a reasonable
    instinct and whether it is right depends entirely on where the tool ended up.

    Next to the tool is fine when the tool lives on a data drive with room. It is
    a bad idea when the tool lives in a source-controlled folder, on a memory
    stick, or under a profile folder, and this says which of those is the case
    rather than making the operator guess.

    The mount folder is deliberately NOT one of these. It does not follow the
    workspace, for reasons Test-WfMountPath spells out.
.EXAMPLE
    Get-WfWorkspaceOption | Format-Table Path, Free, Note
#>
    [CmdletBinding()]
    param()

    $out = New-Object System.Collections.Generic.List[object]

    $drives = @()
    try {
        $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
                    Sort-Object FreeSpace -Descending)
    }
    catch { }

    $add = {
        param([string] $Path, [string] $Why, [string] $Note, [bool] $Recommended)
        if (-not $Path) { return }
        if ($out | Where-Object { $_.Path -eq $Path }) { return }

        $freeGb = 0
        try {
            $q = Split-Path -Qualifier $Path -ErrorAction Stop
            $d = $drives | Where-Object { $_.DeviceID -eq $q } | Select-Object -First 1
            if ($d) { $freeGb = [math]::Round($d.FreeSpace / 1GB, 1) }
        }
        catch { }

        $out.Add([pscustomobject]@{
            Path        = $Path
            Why         = $Why
            FreeGb      = $freeGb
            Note        = $Note
            Recommended = $Recommended
        })
    }

    # The roomiest fixed drive. Images run to several GB each and a servicing run
    # keeps a working copy, so room is the thing that matters most.
    if ($drives.Count -gt 0) {
        & $add (Join-WfPath $drives[0].DeviceID 'Imaging') 'the fixed drive with the most room' '' $true
    }

    # The system drive, named explicitly rather than left implied -- on a
    # single-disk workstation it is the only answer, and saying so is better than
    # appearing to have no second option.
    $sys = $env:SystemDrive
    if (-not $sys) { $sys = 'C:' }
    & $add (Join-WfPath $sys 'Imaging') 'the system drive' '' $false

    # Next to the toolkit. Public\ -> WimForge\ -> the folder the front-ends and
    # the launchers live in.
    $toolRoot = $null
    try { $toolRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } catch { }

    if ($toolRoot) {
        $beside   = Join-WfPath $toolRoot 'Workspace'
        $problems = New-Object System.Collections.Generic.List[string]

        # Source control is the big one. A workspace next to the tool puts several
        # GB of images and an expanded driver library inside the working tree,
        # where git will try to track every file of it.
        $probe = $toolRoot
        for ($i = 0; $i -lt 6 -and $probe; $i++) {
            if (Test-Path -LiteralPath (Join-WfPath $probe '.git')) {
                $problems.Add('it is inside a git working tree')
                break
            }
            $parent = Split-Path $probe -Parent
            if ($parent -eq $probe) { break }
            $probe = $parent
        }

        foreach ($sync in @('OneDrive', 'Dropbox', 'Box', 'Google Drive', 'iCloudDrive')) {
            if ($toolRoot -like "*\$sync*") { $problems.Add("it is inside a $sync folder"); break }
        }

        if ($env:USERPROFILE -and $toolRoot -like "$env:USERPROFILE*") {
            $problems.Add('it is inside your user profile')
        }

        try {
            $q = Split-Path -Qualifier $toolRoot -ErrorAction Stop
            $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$q'" -ErrorAction Stop
            if ($d.DriveType -eq 2) { $problems.Add('it is on removable media') }
            if ($d.DriveType -eq 4) { $problems.Add('it is on a network drive') }
        }
        catch {
            if ($toolRoot -like '\\*') { $problems.Add('it is on a network path') }
        }

        $note = 'everything in one place, which travels with the toolkit'
        if ($problems.Count -gt 0) {
            $note = 'not advised here: ' + (($problems | Sort-Object -Unique) -join ', ')
        }

        & $add $beside 'next to the toolkit' $note ($problems.Count -eq 0)
    }

    return $out.ToArray()
}

function Test-WfMountPath {
<#
.SYNOPSIS
    Whether a folder is somewhere an image can actually be mounted.
.DESCRIPTION
    The mount folder is the one path in this toolkit that does not follow the
    workspace, and the reason is worth having written down, because "put
    everything under one folder" is otherwise the obvious thing to do.

    A mounted image is not a copy of a WIM. It is a live NTFS projection of a
    Windows installation -- fifteen-odd GB of it, with hardlinks, reparse points
    and ACLs -- and it is held open by a filter driver until it is dismounted.
    That has consequences that a folder full of files does not:

      the file system      Hardlinks, reparse points and ACLs are NTFS features.
                           A FAT32 or exFAT stick cannot represent a Windows
                           installation at all.

      other software       Anything that walks the folder holds files open:
                           real-time antivirus, a sync client, a search indexer,
                           a backup agent. A file still open at dismount is what
                           produces "the directory could not be completely
                           unmounted", and the mount is then stale until it is
                           cleaned up by hand.

      source control       A workspace inside a git working tree is untidy. A
                           MOUNT inside one means git enumerating a full Windows
                           installation on every status.

      path length          This is the one that surprises people. The deepest
                           paths inside a serviced image are in WinSxS and run to
                           roughly 200 characters on their own. Windows
                           PowerShell 5.1 is bound by MAX_PATH at 260, and this
                           toolkit does walk the mounted image -- comparing
                           drivers, reading INFs. A short mount root leaves room
                           for that; a deep one does not, and the failure lands
                           in the middle of a servicing run rather than at the
                           start.

      profile folders      Microsoft's own guidance is direct about this: "Don't
                           mount images to protected folders, such as your
                           User\Documents folder."

    So the default is a short path at the root of a local disk -- C:\WimMount --
    and Set-WfWorkspaceRoot deliberately leaves it alone when the workspace moves.

    This reports rather than refuses. Every finding says what would go wrong, so
    an operator who knows their machine can overrule it.
.PARAMETER Path
    The folder to judge. Defaults to the configured mount path.
.PARAMETER WorkspaceRoot
    The workspace, so a mount inside it can be pointed out. Defaults to the
    configured one.
.EXAMPLE
    Test-WfMountPath
.EXAMPLE
    Test-WfMountPath -Path 'C:\Users\dev\source\repos\imaging\WimForge\Mount'
#>
    [CmdletBinding()]
    param(
        [string] $Path,
        [string] $WorkspaceRoot
    )

    $cfg = $null
    try { $cfg = Get-WfConfig } catch { }

    if (-not $Path)          { if ($cfg) { $Path          = $cfg['MountPath'] } }
    if (-not $WorkspaceRoot) { if ($cfg) { $WorkspaceRoot = $cfg['WorkspaceRoot'] } }

    if (-not $Path) { throw 'No mount path given and none is configured.' }

    $findings = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string] $Check, [string] $Status, [string] $Detail)
        $findings.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    }

    # --- the volume ---------------------------------------------------------
    $qualifier = $null
    try { $qualifier = Split-Path -Qualifier $Path -ErrorAction Stop } catch { }

    if ($Path -like '\\*') {
        & $add 'Volume' 'FAIL' 'A UNC path has no local volume for the WIM filter driver to attach to. The mount folder has to be on a local disk; the image file itself can live on a share.'
    }
    elseif (-not $qualifier) {
        & $add 'Volume' 'WARN' "Could not work out which drive '$Path' is on."
    }
    else {
        # "The query failed" and "the drive is not there" are different answers
        # and want different words. Telling somebody their C: drive does not
        # exist because WMI would not answer is a baffling thing to read.
        $disk      = $null
        $cimFailed = $false
        try   { $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$qualifier'" -ErrorAction Stop }
        catch { $cimFailed = $true }

        if ($cimFailed) {
            & $add 'Volume' 'WARN' "Could not query the volumes on this machine, so $qualifier was not checked. Everything else below still applies."
        }
        elseif (-not $disk) {
            & $add 'Volume' 'FAIL' "Drive $qualifier does not exist on this machine."
        }
        else {
            switch ([int]$disk.DriveType) {
                2 { & $add 'Volume' 'FAIL' "$qualifier is removable. Mounting to a stick is slow, and if it is FAT32 or exFAT it cannot hold a Windows installation at all." }
                4 { & $add 'Volume' 'FAIL' "$qualifier is a network drive. The mount folder has to be on a local disk." }
                5 { & $add 'Volume' 'FAIL' "$qualifier is optical media." }
                3 { & $add 'Volume' 'OK'   "$qualifier is a local fixed disk." }
                default { & $add 'Volume' 'WARN' "$qualifier is drive type $($disk.DriveType)." }
            }

            $fs = "$($disk.FileSystem)"
            if ($fs -and $fs -ne 'NTFS') {
                & $add 'File system' 'FAIL' "$qualifier is $fs. A Windows image needs NTFS -- hardlinks, reparse points and ACLs have nowhere to go otherwise."
            }
            elseif ($fs) {
                & $add 'File system' 'OK' "$qualifier is NTFS."
            }

            # A mounted desktop image expands to roughly 15 GB, and a servicing
            # run wants scratch on top of that.
            $freeGb = [math]::Round($disk.FreeSpace / 1GB, 1)
            if     ($freeGb -lt 20) { & $add 'Free space' 'FAIL' "$freeGb GB free on $qualifier. A mounted image alone is around 15 GB before scratch." }
            elseif ($freeGb -lt 40) { & $add 'Free space' 'WARN' "$freeGb GB free on $qualifier. Enough to mount, tight for a servicing run that also exports." }
            else                    { & $add 'Free space' 'OK'   "$freeGb GB free on $qualifier." }
        }
    }

    # --- path length --------------------------------------------------------
    #
    # 260 is MAX_PATH. Something on the order of 200 goes on the deepest WinSxS
    # paths inside a serviced image, which leaves roughly 60 characters for the
    # mount root before this toolkit's own enumeration of the mount starts
    # failing under Windows PowerShell 5.1. Treated as a budget rather than a
    # cliff, because how deep an image goes depends on what has been serviced
    # into it.
    $len    = $Path.Length
    $budget = 260 - 200
    if     ($len -gt $budget)      { & $add 'Path length' 'FAIL' "$len characters. Roughly $budget is the practical ceiling: the deepest paths inside a serviced image run to about 200, and MAX_PATH is 260." }
    elseif ($len -gt ($budget / 2)) { & $add 'Path length' 'WARN' "$len characters, against a practical ceiling of about ${budget}: MAX_PATH is 260 and the deepest paths inside a serviced image run to roughly 200 on their own. It will work, but there is little room left. A short root like C:\WimMount leaves the most." }
    else                            { & $add 'Path length' 'OK'   "$len characters, comfortably inside the MAX_PATH budget." }

    # --- where it sits ------------------------------------------------------
    if ($qualifier -and ($Path.TrimEnd('\') -eq $qualifier)) {
        & $add 'Location' 'FAIL' 'That is the root of a drive, not a folder. Mount into a folder on it.'
    }

    if ($env:USERPROFILE -and $Path -like "$env:USERPROFILE*") {
        & $add 'Profile folder' 'FAIL' "It is inside your user profile. Microsoft's guidance is explicit: don't mount images to protected folders such as User\Documents."
    }

    foreach ($sync in @('OneDrive', 'Dropbox', 'Box', 'Google Drive', 'iCloudDrive')) {
        if ($Path -like "*\$sync*") {
            & $add 'Sync folder' 'FAIL' "It is inside a $sync folder. The sync client will try to upload a mounted Windows installation, and files it holds open make the dismount fail."
            break
        }
    }

    # Walk up looking for a repository. A mount inside a working tree makes every
    # git status enumerate a full Windows installation.
    $probe = $Path
    for ($i = 0; $i -lt 8 -and $probe; $i++) {
        if (Test-Path -LiteralPath (Join-WfPath $probe '.git')) {
            & $add 'Source control' 'WARN' "It is inside a git working tree ($probe). Every status enumerates the whole mounted image. Exclude it, or mount somewhere else."
            break
        }
        $parent = Split-Path $probe -Parent
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }

    if ($WorkspaceRoot -and $Path -like "$($WorkspaceRoot.TrimEnd('\'))\*") {
        & $add 'Workspace' 'WARN' "It is inside the workspace ($WorkspaceRoot). That is tidy, but it means anything scanning or backing up the workspace is also scanning a live mount -- and folder-size reporting counts the image twice."
    }

    if ($findings.Count -eq 0 -or -not ($findings | Where-Object { $_.Status -ne 'OK' })) {
        & $add 'Verdict' 'OK' 'Nothing here would get in the way of a mount.'
    }

    $verdict = 'OK'
    if ($findings | Where-Object { $_.Status -eq 'WARN' }) { $verdict = 'WARN' }
    if ($findings | Where-Object { $_.Status -eq 'FAIL' }) { $verdict = 'FAIL' }

    return [pscustomobject]@{
        Path     = $Path
        Verdict  = $verdict
        Findings = $findings.ToArray()
    }
}

function Get-WfDefaultConfig {
<#
.SYNOPSIS
    The default configuration, with every path derived from a real drive.
.DESCRIPTION
    Not a hardcoded C:\Imaging. The roots are derived from the drives this machine
    actually has, with the mount folder deliberately kept off the workspace root:
    it wants a short path on a local disk for reasons the README sets out at
    length.

    Used on first run, and by Settings to show what a value would go back to.
.PARAMETER Root
    Workspace root. Defaults to Get-WfSuggestedRoot.
#>
    [CmdletBinding()]
    param([string] $Root)

    if (-not $Root) { $Root = Get-WfSuggestedRoot }

    $images = Join-WfPath $Root 'Images'
    $scratchDrive = $env:SystemDrive
    if (-not $scratchDrive) { $scratchDrive = 'C:' }

    return @{
        SetupComplete    = $false

        WorkspaceRoot    = $Root

        # Where the master and published images live
        ImageRoot        = $images
        BaseImage        = (Join-WfPath $images 'LTSC2021-Base.wim')
        PeImage          = (Join-WfPath $images 'WinPE-POS.wim')

        # Inputs
        DriverRoot       = (Join-WfPath $Root 'Drivers')
        UpdateRoot       = (Join-WfPath $Root 'Updates')
        PayloadRoot      = (Join-WfPath $Root 'Payload')
        # One folder per display language, holding its language pack and the
        # Features on Demand that go with it. Filled once from the "Languages and
        # Optional Features" ISO; every build after that reads the library, so
        # the ISO does not have to be present on the machine doing the work.
        LanguageRoot     = (Join-WfPath $Root 'Languages')
        UnattendPath     = (Join-WfPath $Root 'unattend.xml')

        # Working areas. The mount folder wants to be on a fast local disk; DISM
        # does not support mounting to a network path.
        MountPath        = (Join-WfPath $scratchDrive 'WimMount')
        ScratchPath      = (Join-WfPath $scratchDrive 'WimScratch')
        LogRoot          = (Join-WfPath $Root 'Logs')

        # Publishing targets -- these are site-specific, so they stay as examples
        # until setup replaces them.
        WdsShare         = ''
        WdsBootShare     = ''

        # Reference build VM. HyperVHost empty means this machine.
        HyperVHost           = ''
        ReferenceVmName      = 'LTSC2021-POS-Reference'
        ReferenceVmPath      = ''
        ReferenceIsoPath     = ''
        ReferenceVmSwitch    = ''
        ReferenceVmMemoryGB  = 4
        ReferenceVmVhdSizeGB = 80
        ReferenceVmCpuCount  = 2
        # Off: the captured WIM carries no processor features either way, and off
        # is faster for the servicing that happens inside the VM. On only matters
        # if the VM itself gets moved to a host with an older CPU.
        ReferenceVmCompatibleCpu = $false

        # Microsoft Update Catalog search defaults
        UpdateProduct        = 'Windows 10 Version 21H2'
        UpdateArchitecture   = 'x64'

        # Behaviour
        ImageNamePrefix  = 'REFERENCE'
        BootDriverClasses = @('Net','SCSIAdapter','HDC','System','USB')
        DefaultIndex     = 1
        KeepPublishedVersions = 3
        HistoryFile      = (Join-WfPath $Root 'build-history.json')
    }
}

function Set-WfWorkspaceRoot {
<#
.SYNOPSIS
    Repoints every derived path at a new workspace root, in one call.
.DESCRIPTION
    This is the thing that makes the config editable without opening JSON: pick a
    folder, and ImageRoot, DriverRoot, UpdateRoot, PayloadRoot, LogRoot, the
    unattend path and the history file all follow. Settings that are not derived
    from the root -- the WDS shares, the mount path, the name prefix -- are left
    alone.
.PARAMETER CreateFolders
    Also create the folder tree.
.EXAMPLE
    Set-WfWorkspaceRoot -Path E:\Imaging -CreateFolders
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $CreateFolders
    )

    $cfg      = Get-WfConfig
    $defaults = Get-WfDefaultConfig -Root $Path

    $derived = @(
        'WorkspaceRoot','ImageRoot','DriverRoot','UpdateRoot','PayloadRoot',
        'LanguageRoot','LogRoot','UnattendPath','HistoryFile','BaseImage','PeImage'
    )

    $changes = @{}
    foreach ($key in $derived) { $changes[$key] = $defaults[$key] }

    if ($PSCmdlet.ShouldProcess($Path, 'Repoint the workspace')) {
        Set-WfConfig -Settings $changes -Confirm:$false | Out-Null
        Write-WfLog "Workspace root set to $Path" -Level OK

        if ($CreateFolders) { Initialize-WfWorkspace | Out-Null }
    }

    return Get-WfConfig -Refresh
}

function Initialize-WfWorkspace {
<#
.SYNOPSIS
    Creates the folder tree the configuration points at.
.DESCRIPTION
    Everything the toolkit needs to exist before a servicing run. Reports what it
    made and what it could not, rather than failing on the first bad path -- a
    WDS share being unreachable should not stop the local folders being created.
#>
    [CmdletBinding()]
    param([switch] $IncludeMountPath)

    $cfg = Get-WfConfig

    $folders = @('ImageRoot','DriverRoot','UpdateRoot','PayloadRoot','LanguageRoot','LogRoot')
    if ($IncludeMountPath) { $folders += @('MountPath','ScratchPath') }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($key in $folders) {
        $path = $cfg[$key]
        if (-not $path) {
            $results.Add([pscustomobject]@{ Setting = $key; Path = ''; Status = 'Not set'; Detail = '' })
            continue
        }
        if (Test-Path -LiteralPath $path) {
            $results.Add([pscustomobject]@{ Setting = $key; Path = $path; Status = 'Exists'; Detail = '' })
            continue
        }
        try {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ Setting = $key; Path = $path; Status = 'Created'; Detail = '' })
            Write-WfLog "Created $path" -Level OK
        }
        catch {
            $results.Add([pscustomobject]@{
                Setting = $key; Path = $path; Status = 'Failed'; Detail = $_.Exception.Message
            })
            Write-WfLog "Could not create $path -- $($_.Exception.Message)" -Level ERROR
        }
    }

    return $results
}

function Test-WfSetupRequired {
<#
.SYNOPSIS
    True when the toolkit has not been set up on this machine yet.
.DESCRIPTION
    Either setup has never been run, or the configured paths point somewhere that
    does not exist -- which is what a config copied from another workstation looks
    like. Returns the reason too, so the front-ends can say why.
#>
    [CmdletBinding()]
    param()

    $cfg     = Get-WfConfig
    $reasons = New-Object System.Collections.Generic.List[string]

    if (-not $cfg['SetupComplete']) {
        $reasons.Add('Setup has not been run on this machine yet.')
    }

    foreach ($key in 'ImageRoot','DriverRoot','UpdateRoot','LogRoot') {
        $path = $cfg[$key]
        if (-not $path) { $reasons.Add("$key is not set."); continue }

        # A missing drive is a different problem from a missing folder: the folder
        # can be created, the drive letter cannot.
        $qualifier = $null
        try { $qualifier = Split-Path -Qualifier $path -ErrorAction Stop } catch { }

        if ($qualifier -and -not (Test-Path -LiteralPath "$qualifier\")) {
            $reasons.Add("$key points at drive $qualifier, which does not exist on this machine.")
        }
        elseif (-not (Test-Path -LiteralPath $path)) {
            $reasons.Add("$key folder does not exist: $path")
        }
    }

    $problem = Get-WfLogRootProblem
    if ($problem) { $reasons.Add($problem) }

    return [pscustomobject]@{
        Required = ($reasons.Count -gt 0)
        Reasons  = $reasons
    }
}

function Set-WfConfig {
<#
.SYNOPSIS
    Updates one or more configuration values and writes them back to disk.
.DESCRIPTION
    Writes the file and refreshes the cached copy in the same call, so the next
    read cannot see stale values. Only the keys supplied are touched; everything
    else in the file is left alone, which matters because the file is also edited
    by hand.
.EXAMPLE
    Set-WfConfig -Settings @{ DriverRoot = '\\srv01\Imaging$\Drivers' }
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Settings
    )

    $cfg = Get-WfConfig
    foreach ($key in $Settings.Keys) {
        if ($PSCmdlet.ShouldProcess($key, "Set to '$($Settings[$key])'")) {
            $cfg[$key] = $Settings[$key]
            Write-WfLog "Config: $key = $($Settings[$key])" -Level INFO
        }
    }

    ($cfg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:WfConfigPath -Encoding UTF8
    $script:WfConfig = $cfg
    return $cfg
}

function Test-WfUpdateAgent {
<#
.SYNOPSIS
    Is the Windows Update Agent available to unpack a modern .msu?
.DESCRIPTION
    Offline servicing looks like it should have nothing to do with Windows
    Update, and for cabinet-format packages that is true. It is not true for
    Windows 11 24H2.

    A 24H2 cumulative is a UUP package delivered as a WIM-format .msu, and DISM
    does not unpack those itself -- it hands them to the Windows Update Agent
    over COM, on this machine. A disabled wuauserv is therefore worth catching
    before an expansion that takes several minutes to fail.

    What this check is NOT: an explanation of 0x800401E3. That was the first
    guess and it was wrong -- the failure reproduces exactly with wuauserv
    Manual/Running, and its real cause is that Add-WindowsPackage hosts DISM
    inside the PowerShell process, where the agent cannot be activated at all.
    WimForge applies WIM-format packages with dism.exe for that reason. This
    check remains because a disabled service would break the executable too, and
    catching it costs one CIM query.

    Returns Ok/StartMode/State/Reason. Never throws: a machine where the service
    cannot be queried at all reports Unknown and lets the operation proceed,
    because refusing on the strength of a failed query would be worse than
    letting DISM try.
#>
    [CmdletBinding()]
    param()

    $result = [pscustomobject]@{
        Ok = $true; Known = $false; StartMode = 'Unknown'; State = 'Unknown'; Reason = ''
    }

    $svc = $null
    try   { $svc = Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -ErrorAction Stop }
    catch { }

    if (-not $svc) {
        $result.Reason = 'the Windows Update service could not be queried'
        return $result
    }

    $result.Known     = $true
    $result.StartMode = "$($svc.StartMode)"
    $result.State     = "$($svc.State)"

    # Disabled is the one that actually stops servicing. Stopped is fine: DISM
    # starts it on demand, which is what "Manual" is for.
    if ($result.StartMode -eq 'Disabled') {
        $result.Ok     = $false
        $result.Reason = 'the Windows Update service (wuauserv) is Disabled, so DISM cannot start it to unpack a 24H2 update'
    }
    return $result
}

function Test-WfDefenderExclusion {
<#
.SYNOPSIS
    Is real-time antivirus scanning the folders this toolkit writes to?
.DESCRIPTION
    Servicing a WIM writes hundreds of thousands of small files into the mount,
    the scratch folder and the .wim itself, and real-time protection scans every
    one of them -- twice, since the commit reads them all back to recompress.

    The effect is not a slowdown, it is a different order of magnitude. A commit
    that should take minutes can run for hours, and nothing in DISM's output
    suggests why: it reports honest progress against work that is genuinely
    happening, just at a fraction of the speed it could.

    This reports which of the configured paths are excluded and which are not. It
    changes nothing -- exclusions on a managed machine are usually policy, and a
    tool that silently altered antivirus configuration would deserve everything
    it got.

    Returns one row per path plus the real-time state. Never throws: no Defender
    module, third-party AV, or a locked-down query all report Unknown, because
    "I could not tell" and "you are unprotected" are very different answers.
#>
    [CmdletBinding()]
    param([string[]] $Path)

    $result = [pscustomobject]@{
        Known = $false; RealTime = 'Unknown'; Excluded = @(); NotExcluded = @(); Note = ''
    }

    if (-not $Path -or $Path.Count -eq 0) {
        $cfg  = Get-WfConfig
        $Path = @($cfg['MountPath'], $cfg['ImageRoot'], $cfg['UpdateRoot'],
                  (Join-WfPath $cfg['LogRoot'] 'DismScratch')) | Where-Object { $_ }
    }

    $prefs = $null
    try { $prefs = Get-MpPreference -ErrorAction Stop } catch { }
    if (-not $prefs) {
        $result.Note = 'Defender could not be queried -- third-party antivirus, or the cmdlets are unavailable.'
        return $result
    }

    $result.Known = $true
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if ($status.RealTimeProtectionEnabled) { $result.RealTime = 'On' } else { $result.RealTime = 'Off' }
    }
    catch { }

    $ex = @($prefs.ExclusionPath) | Where-Object { $_ }

    foreach ($p in $Path) {
        $norm = "$p".TrimEnd('\')
        # An exclusion on a parent folder covers everything under it, so a
        # literal comparison would report C:\Imaging\Updates as unprotected on a
        # machine where C:\Imaging is excluded.
        $covered = @($ex | Where-Object {
            $e = "$_".TrimEnd('\')
            $norm -eq $e -or $norm.StartsWith($e + '\', [StringComparison]::OrdinalIgnoreCase)
        })
        if ($covered.Count -gt 0) { $result.Excluded    += $norm }
        else                      { $result.NotExcluded += $norm }
    }
    return $result
}

function Test-WfEnvironment {
<#
.SYNOPSIS
    Pre-flight check: elevation, DISM version, configured paths, stale mounts,
    and free disk space on the mount volume.
.DESCRIPTION
    Run this first, every time. Most failed image jobs are one of these five
    things, and finding out before a 20-minute mount is cheaper than after.
#>
    [CmdletBinding()]
    param()

    $cfg     = Get-WfConfig
    $results = New-Object System.Collections.Generic.List[object]

    function Add-Result {
        param([string] $Check, [string] $Status, [string] $Detail)
        $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    }

    # Elevation
    try   { Assert-WfElevated; Add-Result 'Elevation' 'OK' 'Running elevated' }
    catch { Add-Result 'Elevation' 'FAIL' $_.Exception.Message }

    # PowerShell edition -- 7.x works for most things but the DISM shim is flaky
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Add-Result 'PowerShell' 'WARN' "Running $($PSVersionTable.PSVersion) (Core). Use Windows PowerShell 5.1 for image servicing."
    }
    else {
        Add-Result 'PowerShell' 'OK' "Windows PowerShell $($PSVersionTable.PSVersion)"
    }

    # DISM comes in two flavours and they are resolved independently, which is the
    # bit that trips people up:
    #
    #   * the CMDLETS (Mount-WindowsImage and friends) come from the in-box DISM
    #     PowerShell module. The ADK's "Deployment and Imaging Tools Environment"
    #     shortcut does NOT change that -- it sets PATH, not PSModulePath.
    #   * dism.exe on PATH is what that shortcut redirects, and this toolkit only
    #     shells out to it for /ResetBase, /AnalyzeComponentStore and
    #     /Cleanup-Mountpoints.
    #
    # Microsoft documents this as a compatibility matrix rather than a stated
    # rule -- see 'DISM supported platforms'. Read down it and newer-services-older
    # holds, older-services-newer does not. Since the in-box version is this
    # machine's own Windows version, servicing a down-level image is fine either
    # way; the ADK only becomes necessary when the image is NEWER than the
    # workstation, which is exactly the case the docs tell you to install it for.
    try {
        $dism   = Get-Command dism.exe -ErrorAction Stop
        $ver    = (Get-Item $dism.Source).VersionInfo.ProductVersion
        $isAdk  = $dism.Source -like '*Windows Kits*'
        $flavour = 'in-box'
        if ($isAdk) { $flavour = 'ADK' }
        Add-Result 'DISM (exe)' 'OK' "$ver  ($flavour)  $($dism.Source)"
    }
    catch {
        Add-Result 'DISM (exe)' 'FAIL' 'dism.exe not found on PATH'
    }

    try {
        $dismModule = Get-Module Dism -ListAvailable | Select-Object -First 1
        if ($dismModule) {
            Add-Result 'DISM (module)' 'OK' "$($dismModule.Version)  $($dismModule.ModuleBase)"
        }
        else {
            Add-Result 'DISM (module)' 'FAIL' 'The DISM PowerShell module was not found. Image servicing will not work.'
        }
    }
    catch {
        Add-Result 'DISM (module)' 'WARN' $_.Exception.Message
    }

    # Servicing capability -- and, where possible, measured against the image
    # rather than left as a rule for the operator to apply.
    #
    # This is worth doing properly because of how the failure presents. Servicing
    # a newer image than the host does not say "wrong DISM version". It fails
    # inside the package with something like "An error occurred applying the
    # Unattend.xml file from the .msu package", which reads as a problem with the
    # update, or with an answer file, or with anything except the one thing it is.
    $osVer     = [Environment]::OSVersion.Version
    $hostBuild = 0
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $hostBuild = [int]$cv.CurrentBuildNumber
    }
    catch { $hostBuild = [int]$osVer.Build }

    $imgBuild = 0
    $imgName  = ''
    $base     = $cfg['BaseImage']
    if ($base -and (Test-Path -LiteralPath $base)) {
        try {
            # Reads the WIM header only -- no mount, so this stays a pre-flight
            # check rather than becoming the twenty minutes it exists to save.
            $wim = Get-WindowsImage -ImagePath $base -Index 1 -ErrorAction Stop
            $imgName = Split-Path $base -Leaf
            $bm = [regex]::Match("$($wim.Version)", '^\d+\.\d+\.(\d+)')
            if ($bm.Success) { $imgBuild = [int]$bm.Groups[1].Value }
        }
        catch { }
    }

    if ($imgBuild -gt 0 -and $hostBuild -gt 0) {
        if ($imgBuild -gt $hostBuild) {
            Add-Result 'Servicing ceiling' 'FAIL' `
                ("$imgName is build $imgBuild and this workstation is build $hostBuild. Older DISM cannot service a newer image. " +
                 "Updates will fail part-way through with messages that do not mention the version at all. Install the Windows ADK matching build $imgBuild " +
                 "and work from its Deployment and Imaging Tools Environment, or run this on a build $imgBuild machine.")
        }
        else {
            Add-Result 'Servicing ceiling' 'OK' `
                "$imgName is build $imgBuild, this workstation is build $hostBuild -- newer services older, so this is fine."
        }
    }
    else {
        Add-Result 'Servicing ceiling' 'INFO' `
            "This workstation is $osVer, so it can service any image up to that build. A newer image needs a matching ADK. (No base image is configured, so nothing was compared.)"
    }

    # Offline servicing that needs Windows Update running. Counter-intuitive, and
    # invisible until a 24H2 cumulative fails seven minutes in with a message
    # about an Unattend.xml.
    $agent = Test-WfUpdateAgent
    if (-not $agent.Known) {
        Add-Result 'Windows Update Agent' 'INFO' `
            'Could not be queried. DISM needs it to unpack Windows 11 24H2 updates, which are UUP packages.'
    }
    elseif (-not $agent.Ok) {
        Add-Result 'Windows Update Agent' 'FAIL' `
            ("wuauserv is $($agent.StartMode)/$($agent.State). DISM unpacks Windows 11 24H2 cumulative updates through the Windows Update Agent, " +
             "so a disabled service fails servicing with 0x800401E3 even though nothing is downloaded from Windows Update. " +
             "Fix with: Set-Service wuauserv -StartupType Manual; Start-Service wuauserv")
    }
    else {
        Add-Result 'Windows Update Agent' 'OK' `
            "wuauserv is $($agent.StartMode)/$($agent.State) -- DISM can use it to unpack UUP-format updates."
    }

    # Real-time antivirus over the mount and scratch folders. Not a correctness
    # problem, which is why it goes unnoticed: everything works, it just takes
    # hours instead of minutes, and DISM's progress bar reports honest progress
    # the whole time.
    $av = Test-WfDefenderExclusion
    if (-not $av.Known) {
        Add-Result 'Antivirus exclusions' 'INFO' $av.Note
    }
    elseif ($av.RealTime -ne 'On') {
        Add-Result 'Antivirus exclusions' 'OK' "Real-time protection is $($av.RealTime) -- nothing is scanning the mount."
    }
    elseif ($av.NotExcluded.Count -eq 0) {
        Add-Result 'Antivirus exclusions' 'OK' 'Every servicing path is excluded from real-time scanning.'
    }
    else {
        Add-Result 'Antivirus exclusions' 'WARN' `
            ("Real-time protection is scanning: {0}. A WIM commit writes hundreds of thousands of files and reads them all back, so this can turn minutes into hours. Exclude them with:  {1}   (needs admin, and may be blocked by policy on a managed machine.)" -f `
                ($av.NotExcluded -join ', '),
                (($av.NotExcluded | ForEach-Object { "Add-MpPreference -ExclusionPath '$_'" }) -join '; '))
    }

    # The ADK matters most for the OTHER tools -- copype, MakeWinPEMedia, oscdimg
    # and bcdboot are only on PATH inside its environment.
    $kitsRoot = $null
    try {
        $kitsRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop).KitsRoot10
    }
    catch { }

    if ($kitsRoot) {
        $adkEnv = 'not active'
        if ($env:DISMRoot) { $adkEnv = 'active (Deployment and Imaging Tools Environment)' }
        Add-Result 'Windows ADK' 'OK' "$kitsRoot  -- environment $adkEnv"

        if (-not $env:DISMRoot) {
            Add-Result 'ADK tools on PATH' 'WARN' `
                'copype, MakeWinPEMedia, oscdimg and bcdboot are not reachable. Start from the Deployment and Imaging Tools Environment if you need boot media.'
        }
    }
    else {
        Add-Result 'Windows ADK' 'WARN' `
            'Not installed. Servicing still works with the in-box DISM, but building WinPE media needs the ADK Deployment Tools.'
    }

    # Configured paths
    foreach ($key in 'ImageRoot','DriverRoot','UpdateRoot','MountPath') {
        $p = $cfg[$key]
        if (Test-Path -LiteralPath $p) { Add-Result $key 'OK' $p }
        else { Add-Result $key 'WARN' "Missing: $p" }
    }

    # Whether the mount folder is somewhere an image can actually be mounted,
    # which is a different question from whether it exists. A mount folder on a
    # sync drive or six folders deep inside a repository exists perfectly well
    # and then fails in the middle of a servicing run.
    try {
        $mountCheck = Test-WfMountPath -Path $cfg['MountPath'] -WorkspaceRoot $cfg['WorkspaceRoot']
        foreach ($f in $mountCheck.Findings) {
            if ($f.Status -eq 'OK') { continue }
            Add-Result "Mount folder: $($f.Check)" $f.Status $f.Detail
        }
        if ($mountCheck.Verdict -eq 'OK') {
            Add-Result 'Mount folder' 'OK' "$($cfg['MountPath']) is a sound place to mount"
        }
    }
    catch {
        Add-Result 'Mount folder' 'WARN' $_.Exception.Message
    }

    # Stale mounts -- the single most common reason a run fails on the first step
    try {
        $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop)
        if ($mounted.Count -eq 0) {
            Add-Result 'Mounts' 'OK' 'No images currently mounted'
        }
        else {
            foreach ($m in $mounted) {
                $status = if ($m.MountStatus -eq 'Ok') { 'WARN' } else { 'FAIL' }
                Add-Result 'Mounts' $status ("{0} -> {1} ({2})" -f $m.ImagePath, $m.Path, $m.MountStatus)
            }
        }
    }
    catch {
        Add-Result 'Mounts' 'WARN' "Could not query mounts: $($_.Exception.Message)"
    }

    # Free space on the mount volume. A mounted LTSC image plus scratch wants
    # room; running out mid-servicing corrupts the mount.
    try {
        $qualifier = Split-Path -Qualifier $cfg['MountPath']
        $drive     = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction Stop
        $freeGb    = [math]::Round($drive.Free / 1GB, 1)
        $status    = if ($freeGb -lt 20) { 'WARN' } else { 'OK' }
        Add-Result 'Free space' $status "$freeGb GB free on $qualifier (20 GB recommended)"
    }
    catch {
        Add-Result 'Free space' 'WARN' "Could not determine free space: $($_.Exception.Message)"
    }

    return $results
}

# ---------------------------------------------------------------- build history

function Write-WfHistory {
<#
.SYNOPSIS
    Appends a build record to the history file.
.DESCRIPTION
    This is the file that answers "what was actually in the image we shipped in
    March" fourteen months later. Every servicing run writes one.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [string] $ImagePath,
        [hashtable] $Detail,
        [string]    $Notes
    )

    $cfg  = Get-WfConfig
    $file = $cfg['HistoryFile']
    New-WfDirectory (Split-Path $file -Parent) | Out-Null

    $history = @()
    if (Test-Path -LiteralPath $file) {
        try {
            $existing = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($existing) { $history = @($existing) }
        }
        catch {
            Write-WfLog "History file unreadable, starting a new one: $($_.Exception.Message)" -Level WARN
        }
    }

    # Round-trip format ('o'), plus a monotonic sequence number. Two runs inside
    # the same second are common (a servicing run writes several entries), and
    # second-resolution timestamps alone make "newest first" a coin toss.
    $entry = [ordered]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Sequence     = $history.Count + 1
        Action       = $Action
        ImagePath    = $ImagePath
        ImageFile    = (Split-Path $ImagePath -Leaf)
        Operator     = "$env:USERDOMAIN\$env:USERNAME"
        Workstation  = $env:COMPUTERNAME
        Notes        = $Notes
    }
    if ($Detail) {
        foreach ($k in $Detail.Keys) { $entry[$k] = $Detail[$k] }
    }

    $history += [pscustomobject]$entry
    ($history | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $file -Encoding UTF8

    Write-WfLog "History: $Action on $(Split-Path $ImagePath -Leaf)" -Level OK
    return [pscustomobject]$entry
}

function Get-WfHistory {
<#
.SYNOPSIS
    Returns the build history, newest first.
.DESCRIPTION
    Every operation that changes an image appends to it: what was done, to which
    file, when, and the details that would otherwise only exist in a log nobody
    kept. Newest first, because the question is nearly always "what happened to
    this image recently".

    This is what makes a published WIM answerable six months later without
    mounting it.
.PARAMETER Last
    Only return the most recent N entries.
.PARAMETER ImageFile
    Filter to one image file name.
#>
    [CmdletBinding()]
    param(
        [int]    $Last,
        [string] $ImageFile
    )

    $cfg  = Get-WfConfig
    $file = $cfg['HistoryFile']
    if (-not (Test-Path -LiteralPath $file)) {
        Write-WfLog "No build history yet at $file" -Level WARN
        return @()
    }

    $history = @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
    if ($ImageFile) { $history = @($history | Where-Object { $_.ImageFile -eq $ImageFile }) }

    # Sequence breaks ties within the same second; older files without it sort
    # on the timestamp alone, which is the previous behaviour.
    $history = @($history | Sort-Object TimestampUtc, Sequence -Descending)
    if ($Last -gt 0) { $history = @($history | Select-Object -First $Last) }
    return $history
}
