# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Servicing.ps1 -- the core WIM operations: inspect, mount, update, clean,
    export, and the one-shot servicing run that chains them together.
#>

function Get-WfImageInfo {
<#
.SYNOPSIS
    Lists the indexes inside a WIM, and what each one actually is.
.DESCRIPTION
    Run this before servicing anything with more than one index. On Microsoft
    media boot.wim index 1 is the base WinPE and index 2 is Windows Setup -- and
    index 2 is the one WDS actually boots. Injecting into the wrong index
    produces a deployment that silently skips a hardware model.

    An install.wim from retail media carries every edition as a separate index,
    all with near-identical names, which is the other way of picking the wrong
    one. Edition and architecture are listed here for that reason.

    Nothing is mounted: this is the WIM header, so it costs a file read whatever
    the image's size. The build shown is the header's, which for the whole
    19041 family is 10.0.19041 no matter which release the image really is --
    Get-WfImageUpdateTarget is what answers that properly.

    Note is a plain-language reading of what the index is for, so the choice
    does not depend on recognising the convention.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImagePath
    )

    $ImagePath = Assert-WfPath -Path $ImagePath -Label 'Image'
    $all = @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)

    foreach ($i in $all) {
        $note = ''
        $name = [string]$i.ImageName

        if ($name -match 'Windows Setup')            { $note = 'Windows Setup -- this is the one WDS boots' }
        elseif ($name -match 'Microsoft Windows PE') { $note = 'base WinPE' }
        elseif ($name -match 'Windows Recovery')     { $note = 'recovery environment' }
        elseif ($all.Count -eq 1)                    { $note = 'the only index' }

        [pscustomobject]@{
            ImageIndex       = $i.ImageIndex
            ImageName        = $name
            ImageDescription = [string]$i.ImageDescription
            EditionId        = [string]$i.EditionId
            Architecture     = (ConvertTo-WfArchitectureName $i.Architecture)
            Version          = [string]$i.Version
            Languages        = (@($i.Languages) -join ', ')
            SizeGB           = [math]::Round($i.ImageSize / 1GB, 2)
            Note             = $note
        }
    }
}

function Get-WfImageReport {
<#
.SYNOPSIS
    Full inventory of an image: build and UBR, third-party drivers by model,
    installed updates, enabled features and component store size.
.DESCRIPTION
    Mounts read-only, so it is safe to run against a published image. This is the
    report to attach to a handover or a VALHW document.

    -Quick answers the half of it that needs no mount, in seconds rather than
    minutes: identity, build, UBR, edition, architecture and size. That is what
    most runs of this are actually after -- "which image is this, and how current
    is it". The driver, update and feature lists are the part that needs DISM
    against a mounted path, and they are the part -Quick leaves out.
.PARAMETER Quick
    Skip the mount. No driver, update or feature list; everything else stands.
.PARAMETER IncludeFeatures
    Also enumerate optional features. Slower; off by default. Ignored with -Quick.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [int]    $Index = 1,
        [switch] $Quick,
        [switch] $IncludeFeatures
    )

    Assert-WfElevated
    $cfg       = Get-WfConfig
    $ImagePath = Assert-WfPath -Path $ImagePath -Label 'Image'

    Write-WfLog "Inventory of $(Split-Path $ImagePath -Leaf) index $Index" -Level STEP

    # ------------------------------------------------------------------ quick
    if ($Quick) {
        $img = Get-WindowsImage -ImagePath $ImagePath -Index $Index -ErrorAction Stop

        # The header's Version is the family's base build and its SPBuild is the
        # UBR, so neither alone is the answer. The registry has both, and comes
        # out of the .wim without mounting it.
        $cv    = Get-WfImageCurrentVersion -ImagePath $ImagePath -Index $Index
        $build = ''
        $ubr   = $null

        foreach ($name in @('CurrentBuildNumber', 'CurrentBuild')) {
            if (-not $build -and $cv.ContainsKey($name)) { $build = [string]$cv[$name] }
        }
        if ($cv.ContainsKey('UBR')) { $ubr = $cv['UBR'] }

        $version = [string]$img.Version
        if ($build) { $version = "10.0.$build" }
        if (-not $ubr -and $img.SPBuild) { $ubr = $img.SPBuild }

        $fullBuild = $version
        if ($ubr) { $fullBuild = "$version.$ubr" }

        $release = ''
        foreach ($name in @('DisplayVersion', 'ReleaseId')) {
            if (-not $release -and $cv.ContainsKey($name)) { $release = [string]$cv[$name] }
        }
        $edition = [string]$img.EditionId
        if ($cv.ContainsKey('EditionID')) { $edition = [string]$cv['EditionID'] }

        # Drivers come out of the same registry, from a different hive. Still no
        # mount. Updates and features do not: those live in the COMPONENTS hive,
        # which is hundreds of megabytes and would cost more to extract than the
        # mount it was meant to avoid.
        $drivers = @(Get-WfImageDriverPackage -ImagePath $ImagePath -Index $Index)

        $byClass = ''
        if ($drivers.Count -gt 0) {
            $byClass = ($drivers | Where-Object { $_.ClassName } | Group-Object ClassName |
                        Sort-Object Count -Descending |
                        ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
        }

        $driverCount = $null
        if ($drivers.Count -gt 0) { $driverCount = $drivers.Count }

        $quickReport = [pscustomobject]@{
            ImagePath      = $ImagePath
            Index          = $Index
            ImageName      = $img.ImageName
            EditionId      = $edition
            Release        = $release
            Architecture   = (ConvertTo-WfArchitectureName $img.Architecture)
            Version        = $version
            Ubr            = $ubr
            FullBuild      = $fullBuild
            SizeGB         = [math]::Round($img.ImageSize / 1GB, 2)
            FileSizeGB     = [math]::Round((Get-Item -LiteralPath $ImagePath).Length / 1GB, 2)
            DriverCount    = $driverCount
            DriversByClass = $byClass
            Drivers        = $drivers | Select-Object Driver, ClassName, ProviderName, Version, Date
            # Not available without a mount, and reported as unknown rather
            # than as zero -- which would read as "no updates in this image".
            UpdateCount    = $null
            LatestUpdates  = @()
            Features       = @()
            Scope          = 'quick'
            GeneratedUtc   = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        }

        if ($cv.Count -eq 0) {
            Write-WfLog 'The registry could not be read, so the build below is the header value and may name the wrong release. Run the full report to be sure.' -Level WARN
        }
        Write-WfLog ("Build {0}, {1} third-party drivers. No mount, so no update or feature list -- run the full report for those." -f `
            $quickReport.FullBuild, $drivers.Count) -Level OK
        return $quickReport
    }

    # ------------------------------------------------------------------- full
    $mount = New-WfDirectory $cfg['MountPath']

    $mounted = $false
    try {
        Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $mount -ReadOnly -ErrorAction Stop | Out-Null
        $mounted = $true

        $img      = Get-WindowsImage -ImagePath $ImagePath -Index $Index
        $drivers  = @(Get-WindowsDriver -Path $mount | Where-Object { -not $_.Inbox })
        $packages = @(Get-WindowsPackage -Path $mount | Where-Object { $_.PackageState -eq 'Installed' })

        # UBR of the offline image lives in its SOFTWARE hive, not in ImageVersion
        $ubr = Get-WfOfflineUbr -MountPath $mount

        $features = @()
        if ($IncludeFeatures) {
            $features = @(Get-WindowsOptionalFeature -Path $mount | Where-Object { $_.State -eq 'Enabled' })
        }

        # Statements inside a hashtable literal are avoided throughout this module
        # -- Windows PowerShell 5.1's parser is stricter than 7's about them.
        $fullBuild = $img.Version
        if ($ubr) { $fullBuild = "$($img.Version).$ubr" }

        $report = [pscustomobject]@{
            ImagePath      = $ImagePath
            Index          = $Index
            ImageName      = $img.ImageName
            Architecture   = $img.Architecture
            Version        = $img.Version
            Ubr            = $ubr
            FullBuild      = $fullBuild
            SizeGB         = [math]::Round($img.ImageSize / 1GB, 2)
            FileSizeGB     = [math]::Round((Get-Item -LiteralPath $ImagePath).Length / 1GB, 2)
            DriverCount    = $drivers.Count
            DriversByClass = ($drivers | Group-Object ClassName |
                              Sort-Object Count -Descending |
                              ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
            Drivers        = $drivers | Select-Object Driver, ClassName, ProviderName, Version, Date, BootCritical
            UpdateCount    = $packages.Count
            LatestUpdates  = @($packages | Where-Object { $_.PackageName -match 'RollupFix|LanguagePack|Package_for_KB' } |
                               Sort-Object PackageName | Select-Object -Last 10 -ExpandProperty PackageName)
            Features       = @($features | Select-Object -ExpandProperty FeatureName)
            Scope          = 'full'
            GeneratedUtc   = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        }

        Write-WfLog ("Build {0}, {1} third-party drivers, {2} installed packages" -f $report.FullBuild, $report.DriverCount, $report.UpdateCount) -Level OK
        return $report
    }
    finally {
        # A swallowed dismount failure is how you end up debugging "mount folder
        # is not empty" three operations later with no idea where it came from.
        if ($mounted) {
            try {
                Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null
            }
            catch {
                Write-WfLog "Dismount failed after inventory: $($_.Exception.Message)" -Level ERROR
                Write-WfLog 'The image is still mounted. Run Repair-WfMount before the next operation.' -Level ERROR
            }
        }
    }
}

function Read-WfCurrentVersionHive {
    <#
        Loads a SOFTWARE hive FILE and reads CurrentVersion out of it.

        Takes the file, not a mount, because the file can come from two very
        different places: copied out of a mounted image, or extracted straight
        from the WIM without mounting anything. Both end up here.

        The load key name is randomised: two of these can be in flight at once
        and a fixed name would have them unload each other's hive.

        reg load needs SeRestorePrivilege, so this is an elevated-only path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $HivePath)

    $empty = @{}
    if (-not (Test-Path -LiteralPath $HivePath)) { return $empty }

    $key    = 'WF_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $loaded = $false
    try {
        & reg.exe load "HKLM\$key" $HivePath | Out-Null
        if ($LASTEXITCODE -ne 0) { return $empty }
        $loaded = $true

        $props = Get-ItemProperty "HKLM:\$key\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
        if (-not $props) { return $empty }

        $out = @{}
        foreach ($name in @('CurrentBuild','CurrentBuildNumber','UBR','DisplayVersion',
                            'ReleaseId','ProductName','EditionID','InstallationType',
                            'CurrentVersion','CompositionEditionID','BuildLabEx')) {
            $value = $props.$name
            if ($null -ne $value -and "$value" -ne '') { $out[$name] = $value }
        }
        return $out
    }
    catch {
        Write-WfLog "Could not read the offline registry: $($_.Exception.Message)" -Level WARN
        return $empty
    }
    finally {
        # The registry provider holds handles open; without collecting them the
        # unload fails with Access Denied and any later dismount fails too.
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()

        if ($loaded) {
            # No 2>&1 here. Merging a native command's stderr into the success
            # stream is what raises NativeCommandError under $ErrorActionPreference
            # = 'Stop' -- and this runs in a finally block, where a terminating
            # error would replace the function's return value with something
            # unrecognisable. The exit code says everything the text would.
            & reg.exe unload "HKLM\$key" | Out-Null

            if ($LASTEXITCODE -ne 0) {
                # Worth saying out loud: the key name is randomised, so a hive
                # left loaded is one nobody will find later, and it holds the
                # file open so it cannot be deleted either.
                Write-WfLog "The registry hive HKLM\$key could not be unloaded (exit $LASTEXITCODE). Unload it with: reg unload HKLM\$key" -Level WARN
            }
        }
    }
}

function Get-WfImageCurrentVersion {
    <#
        Reads CurrentVersion out of a WIM WITHOUT mounting it, by extracting just
        the SOFTWARE hive through wimgapi.

        This is the fast path, and it is the one that should normally run: a DISM
        mount projects every file in the image so that four registry values can
        be read, which takes a minute or two and leaves something to clean up if
        it is interrupted. Extracting one file takes seconds and leaves nothing
        behind.

        Results are cached against the image's path, size and timestamp, so
        clicking the same button twice costs nothing the second time -- and an
        image that has been serviced since is read again, because its timestamp
        moved.

        Returns an empty hashtable if the extraction did not work; the caller is
        expected to fall back to mounting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [int]    $Index = 1,
        [switch] $Refresh
    )

    $empty = @{}
    if (-not (Test-Path -LiteralPath $ImagePath)) { return $empty }

    if ($null -eq $script:WfHiveCache) { $script:WfHiveCache = @{} }

    $item = Get-Item -LiteralPath $ImagePath
    $key  = '{0}|{1}|{2}|{3}' -f $ImagePath.ToLowerInvariant(), $Index, $item.Length, $item.LastWriteTimeUtc.Ticks

    if (-not $Refresh -and $script:WfHiveCache.ContainsKey($key)) {
        Write-WfLog 'Already read this image; using what was read before.' -Level INFO
        return $script:WfHiveCache[$key]
    }

    $temp = Join-WfPath $env:TEMP ('WfSoftware-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Write-WfLog "Reading the registry out of $(Split-Path $ImagePath -Leaf) index $Index" -Level STEP
        $got = Export-WfImageFile -ImagePath $ImagePath -Index $Index `
                                  -SourcePath '\Windows\System32\config\SOFTWARE' -Destination $temp
        if (-not $got) { return $empty }

        $cv = Read-WfCurrentVersionHive -HivePath $temp
        if ($cv.Count -gt 0) { $script:WfHiveCache[$key] = $cv }
        return $cv
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-WfImageDriverPackage {
    <#
        Lists the third-party driver packages in an image WITHOUT mounting it.

        Windows records every staged driver package under
        HKLM\SYSTEM\DriverDatabase\DriverPackages, one subkey per package, named
        for the ORIGINAL inf rather than the oemNN.inf it was published as. That
        is more useful than what Get-WindowsDriver returns, because the original
        name is what the driver library is keyed on.

        The SYSTEM hive is a few tens of megabytes, so extracting it is seconds
        rather than the minutes a mount costs.

        A caveat worth stating plainly: the per-package Version value is an
        undocumented binary blob. The layout is not published, so it is decoded
        best-effort and validated -- an implausible date or a class GUID that
        does not exist in the same hive is reported as unknown rather than
        guessed at. The package LIST, which is the part that matters, does not
        depend on that decode at all.

        Returns an empty array if the key is not there, so callers can fall back
        to mounting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [int] $Index = 1
    )

    if (-not (Test-Path -LiteralPath $ImagePath)) { return @() }

    $temp = Join-WfPath $env:TEMP ('WfSystem-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    $key  = 'WF_' + [guid]::NewGuid().ToString('N').Substring(0, 8)

    $loaded = $false
    $out    = New-Object System.Collections.Generic.List[object]

    try {
        Write-WfLog "Reading the driver database out of $(Split-Path $ImagePath -Leaf) index $Index" -Level STEP
        $got = Export-WfImageFile -ImagePath $ImagePath -Index $Index `
                                  -SourcePath '\Windows\System32\config\SYSTEM' -Destination $temp
        if (-not $got) { return @() }

        & reg.exe load "HKLM\$key" $temp | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-WfLog 'The SYSTEM hive could not be loaded; falling back to mounting.' -Level WARN
            return @()
        }
        $loaded = $true

        $root = "HKLM:\$key\DriverDatabase\DriverPackages"
        if (-not (Test-Path -LiteralPath $root)) {
            Write-WfLog 'This image has no DriverDatabase key; falling back to mounting.' -Level WARN
            return @()
        }

        # Class GUID to friendly name, from the same hive. This one IS
        # documented and stable, so it needs no guessing.
        $classNames = @{}
        foreach ($set in @('ControlSet001', 'CurrentControlSet')) {
            $classRoot = "HKLM:\$key\$set\Control\Class"
            if (-not (Test-Path -LiteralPath $classRoot)) { continue }
            foreach ($c in Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue) {
                $name = (Get-ItemProperty -LiteralPath $c.PSPath -Name 'Class' -ErrorAction SilentlyContinue).Class
                if ($name) { $classNames[$c.PSChildName.ToLower()] = $name }
            }
            if ($classNames.Count -gt 0) { break }
        }

        foreach ($pkg in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty -LiteralPath $pkg.PSPath -ErrorAction SilentlyContinue

            # Key names look like 'igdlh64.inf_amd64_9a8b7c6d5e4f3210'. The inf
            # name is everything up to and including '.inf'.
            $inf = $pkg.PSChildName
            $m = [regex]::Match($inf, '^(?<inf>.+?\.inf)_', 'IgnoreCase')
            if ($m.Success) { $inf = $m.Groups['inf'].Value }

            $decoded = ConvertFrom-WfDriverVersionBlob -Blob $props.Version

            $class = ''
            if ($decoded.ClassGuid) {
                $lookup = '{' + $decoded.ClassGuid.ToString().Trim('{', '}') + '}'
                if ($classNames.ContainsKey($lookup.ToLower())) { $class = $classNames[$lookup.ToLower()] }
            }

            $out.Add([pscustomobject]@{
                Driver       = $inf
                PackageKey   = $pkg.PSChildName
                ProviderName = [string]$props.Provider
                SignerName   = [string]$props.SignerName
                ClassName    = $class
                ClassGuid    = $decoded.ClassGuid
                Version      = $decoded.Version
                Date         = $decoded.Date
                Inbox        = $false
                Source       = 'registry'
            })
        }

        Write-WfLog ("{0} driver package(s) read without mounting" -f $out.Count) -Level OK
        return $out.ToArray()
    }
    catch {
        Write-WfLog "Could not read the driver database: $($_.Exception.Message)" -Level WARN
        return @()
    }
    finally {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        if ($loaded) {
            & reg.exe unload "HKLM\$key" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-WfLog "The registry hive HKLM\$key could not be unloaded (exit $LASTEXITCODE). Unload it with: reg unload HKLM\$key" -Level WARN
            }
        }
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-WfDriverVersionBlob {
    <#
        Decodes the Version value of a DriverPackages entry.

        The layout is not documented. It is 32 bytes and is known to carry a
        FILETIME, a packed 4x16-bit version and a class GUID, but not in an order
        anyone has published -- so rather than assert one, both plausible
        orderings are tried and the result is only accepted if it is credible: a
        driver date somewhere between 1990 and a couple of years out, and a GUID
        in the usual shape. Anything else comes back as nulls.

        Being wrong here would be worse than being silent: a made-up driver date
        in a hardware validation document is the kind of thing that gets believed.
    #>
    param($Blob)

    $result = [pscustomobject]@{ Date = $null; Version = $null; ClassGuid = $null }

    $bytes = $Blob -as [byte[]]
    if (-not $bytes -or $bytes.Length -lt 32) { return $result }

    $floor   = [datetime]'1990-01-01'
    $ceiling = (Get-Date).AddYears(2)

    # (date offset, version offset, guid offset)
    foreach ($layout in @(@(0, 8, 16), @(16, 24, 0))) {
        $dateAt = $layout[0]; $verAt = $layout[1]; $guidAt = $layout[2]

        $date = $null
        try {
            $ticks = [BitConverter]::ToInt64($bytes, $dateAt)
            if ($ticks -gt 0) { $date = [datetime]::FromFileTimeUtc($ticks) }
        }
        catch { $date = $null }

        if (-not $date -or $date -lt $floor -or $date -gt $ceiling) { continue }

        # Packed as four 16-bit parts, most significant first.
        $packed = [BitConverter]::ToUInt64($bytes, $verAt)
        $parts  = @(
            [int](($packed -shr 48) -band 0xFFFF)
            [int](($packed -shr 32) -band 0xFFFF)
            [int](($packed -shr 16) -band 0xFFFF)
            [int]( $packed         -band 0xFFFF)
        )

        $guid = $null
        try {
            $g = New-Object byte[] 16
            [Array]::Copy($bytes, $guidAt, $g, 0, 16)
            $candidate = New-Object Guid (,$g)
            if ($candidate -ne [guid]::Empty) { $guid = $candidate }
        }
        catch { $guid = $null }

        $result.Date      = $date
        $result.Version   = ($parts -join '.')
        $result.ClassGuid = $guid
        return $result
    }

    return $result
}

function Get-WfOfflineCurrentVersion {
    <#
        Reads CurrentVersion out of an image that is ALREADY MOUNTED.

        Only for that case -- Get-WfImageCurrentVersion is the one to reach for
        when starting from a .wim file, because it does not mount anything.

        The hive is copied out before loading it. reg load opens a hive
        read/write, so it fails outright against a -ReadOnly DISM mount, and
        copying also guarantees nothing here can write into the image.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $MountPath)

    $hive = Join-WfPath $MountPath 'Windows\System32\config\SOFTWARE'
    if (-not (Test-Path -LiteralPath $hive)) { return @{} }

    $temp = Join-WfPath $env:TEMP ('WfSoftware-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Copy-Item -LiteralPath $hive -Destination $temp -Force
        return (Read-WfCurrentVersionHive -HivePath $temp)
    }
    catch {
        Write-WfLog "Could not copy the offline registry out of the mount: $($_.Exception.Message)" -Level WARN
        return @{}
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-WfOfflineUbr {
    <# Just the UBR, for callers that want nothing else. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $MountPath)

    $cv = Get-WfOfflineCurrentVersion -MountPath $MountPath
    if ($cv.ContainsKey('UBR')) { return $cv['UBR'] }
    return $null
}

function Mount-WfImage {
<#
.SYNOPSIS
    Mounts an image at the configured mount path, refusing if the folder is dirty.
.DESCRIPTION
    The mount every other operation builds on, with the checks that stop a
    servicing run failing twenty minutes in.

    A dirty mount folder is refused rather than mounted over: DISM will happily
    fail against a folder holding a stale mount, and the message it gives names
    the folder rather than the reason. -WorkingCopy mounts a copy instead of the
    master, which is what a monthly servicing run wants -- a bad run then costs a
    re-copy rather than the image.
.PARAMETER WorkingCopy
    Copy the WIM alongside itself as *.working.wim and mount the copy, leaving the
    master untouched. Clears the read-only attribute on the copy, since masters are
    often stored read-only and that is exactly when this switch is wanted.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [int]    $Index = 1,
        [switch] $ReadOnly,
        [switch] $WorkingCopy
    )

    Assert-WfElevated
    $cfg       = Get-WfConfig
    $ImagePath = Assert-WfPath -Path $ImagePath -Label 'Image'
    $mount     = New-WfDirectory $cfg['MountPath']

    if (@(Get-ChildItem -LiteralPath $mount -Force).Count -gt 0) {
        # "Not empty" is the symptom, and on its own it points at the wrong fix.
        # The usual cause is an image that is deliberately open -- and telling
        # someone in that position to run Repair-WfMount invites them to throw
        # away a mount they spent two minutes making and whatever is in it.
        $open = $null
        try { $open = Get-WfCurrentMount -MountPath $mount } catch { }

        if ($open) {
            throw ("$(Split-Path $open.ImagePath -Leaf) index $($open.Index) is already open at $mount. " +
                   "Close it first (commit or discard), or use an operation that works on the open image.")
        }
        throw ("Mount folder is not empty: $mount, but nothing is mounted there -- " +
               "leftover files from an interrupted run. Run Repair-WfMount first.")
    }

    if ($WorkingCopy) {
        $copy = Get-WfWorkingCopyPath -ImagePath $ImagePath
        Write-WfLog "Copying master to $copy" -Level STEP
        Copy-Item -LiteralPath $ImagePath -Destination $copy -Force
        Set-ItemProperty -LiteralPath $copy -Name IsReadOnly -Value $false
        $ImagePath = $copy
    }
    elseif (-not $ReadOnly -and (Get-Item -LiteralPath $ImagePath).IsReadOnly) {
        throw "Image is read-only: $ImagePath. Clear the attribute or use -WorkingCopy."
    }

    Write-WfLog "Mounting $(Split-Path $ImagePath -Leaf) index $Index at $mount" -Level STEP
    $params = @{ ImagePath = $ImagePath; Index = $Index; Path = $mount }
    if ($ReadOnly) { $params['ReadOnly'] = $true }
    Mount-WindowsImage @params -ErrorAction Stop | Out-Null

    Write-WfLog 'Mounted' -Level OK
    return [pscustomobject]@{
        ImagePath = $ImagePath
        Index     = $Index
        MountPath = $mount
        ReadOnly  = [bool]$ReadOnly
    }
}

function Dismount-WfImage {
<#
.SYNOPSIS
    Dismounts the configured mount path, committing or discarding.
.DESCRIPTION
    Committing is the default, and -Save says so explicitly.

    -Save exists because its absence caused real data loss. Four call sites --
    every commit path in the toolkit, including the GUI's Close button and the
    end of an update injection -- were written as "-Save", which reads exactly
    right and is what the underlying Dismount-WindowsImage calls it. The
    parameter did not exist here, so those calls threw, and the catch block
    around them did what it is designed to do: discarded the mount. A Windows 10
    cumulative that took 46 minutes to apply was thrown away at the moment it
    succeeded, and the error said only "A parameter cannot be found that matches
    parameter name 'Save'".

    It survived because committing was a SILENT default: the only correct way to
    ask for it was to say nothing, so a call that said something looked fine and
    was never exercised until an apply finally got that far.
.PARAMETER Save
    Commit the changes. The default, stated out loud.
.PARAMETER Discard
    Throw the changes away and leave the .wim as it was.
#>
    [CmdletBinding()]
    param(
        [switch] $Discard,
        [switch] $Save,
        [string] $MountPath
    )

    Assert-WfElevated

    # Asking for both is a caller bug, and the two outcomes are opposite and
    # irreversible. Guessing which was meant is not an option.
    if ($Discard -and $Save) {
        throw 'Dismount-WfImage: -Save and -Discard are opposites. Pass one, or neither for the default (commit).'
    }

    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    if ($Discard) {
        Write-WfLog "Dismounting and DISCARDING changes at $MountPath" -Level STEP
        Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop | Out-Null
    }
    else {
        Write-WfLog "Dismounting and committing $MountPath" -Level STEP
        Dismount-WindowsImage -Path $MountPath -Save -ErrorAction Stop | Out-Null
    }
    Write-WfLog 'Dismounted' -Level OK
}

function Get-WfCurrentMount {
<#
.SYNOPSIS
    What is mounted at the configured mount path right now, if anything.
.DESCRIPTION
    Returns the mounted image -- path, index, mount folder and status -- or
    $null. This is what lets an operation notice that the image it is about to
    work on is already open, and use it rather than mounting a second time.

    Reading the mount table needs administrator rights; unelevated this returns
    $null, which is indistinguishable from nothing being mounted. Callers that
    care should check elevation themselves.
#>
    [CmdletBinding()]
    param([string] $MountPath)

    $cfg = Get-WfConfig
    if (-not $MountPath) { $MountPath = $cfg['MountPath'] }
    if (-not $MountPath) { return $null }

    $mounted = @()
    try { $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop) }
    catch { return $null }

    $wanted = $MountPath.TrimEnd('\', '/')
    foreach ($m in $mounted) {
        if ("$($m.Path)".TrimEnd('\', '/') -eq $wanted) {
            return [pscustomobject]@{
                ImagePath = $m.ImagePath
                Index     = $m.ImageIndex
                MountPath = $m.Path
                Status    = $m.MountStatus
                ReadOnly  = ($m.MountMode -eq 'ReadOnly')
            }
        }
    }
    return $null
}

function Invoke-WfWithMount {
<#
.SYNOPSIS
    Runs an operation against a mounted image, reusing an existing mount.
.DESCRIPTION
    Every offline change needs the image mounted, and mounting is the slow part.
    Doing five customisations one after another used to mean five mounts and five
    commits -- twenty minutes of DISM to make five changes that each take
    seconds.

    So: if the image is already mounted at the configured mount path, the
    operation runs against that mount and leaves it open. Whoever mounted it
    decides when to commit. If nothing is mounted, this mounts, runs, and commits
    -- the old behaviour, unchanged, for one-off use.

    A mount of a DIFFERENT image is an error rather than something to work
    around. Silently dismounting somebody's work to make room is not a thing this
    should do on its own.

    Failure always discards, and only when this function did the mounting. An
    operation that fails against a mount someone else opened leaves it alone:
    they may well want to inspect it.
.PARAMETER Body
    The work. Runs with the mount in place; the mount path is passed to it.
.PARAMETER ReadOnly
    Mount read-only when mounting is needed. Ignored when reusing a mount.
.EXAMPLE
    Invoke-WfWithMount -ImagePath D:\Images\Base.wim -Index 1 -Body { Add-WfUpdate }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]      $ImagePath,
        [int]                                $Index = 1,
        [Parameter(Mandatory)] [scriptblock] $Body,
        [switch]                             $ReadOnly
    )

    Assert-WfElevated

    $existing = Get-WfCurrentMount

    if ($existing) {
        $same = ("$($existing.ImagePath)".TrimEnd('\') -eq "$ImagePath".TrimEnd('\')) -and
                ([int]$existing.Index -eq [int]$Index)

        if (-not $same) {
            throw ("A different image is mounted: {0} index {1}. Dismount it before working on {2} index {3}." -f `
                (Split-Path $existing.ImagePath -Leaf), $existing.Index, (Split-Path $ImagePath -Leaf), $Index)
        }
        if ($existing.ReadOnly -and -not $ReadOnly) {
            throw ("{0} is mounted read-only, so it cannot be changed. Dismount and mount it read/write first." -f `
                (Split-Path $existing.ImagePath -Leaf))
        }

        Write-WfLog ("Using the mount already open at {0} -- it stays mounted afterwards." -f $existing.MountPath) -Level INFO
        return (& $Body $existing.MountPath)
    }

    $info    = Mount-WfImage -ImagePath $ImagePath -Index $Index -ReadOnly:$ReadOnly
    $ourMount = $true
    try {
        $result = & $Body $info.MountPath
        if ($ReadOnly) { Dismount-WfImage -MountPath $info.MountPath -Discard }
        else           { Dismount-WfImage -MountPath $info.MountPath -Save }
        $ourMount = $false
        return $result
    }
    catch {
        if ($ourMount) {
            Write-WfLog 'Discarding the mount -- the image is left as it was.' -Level WARN
            try   { Dismount-WfImage -MountPath $info.MountPath -Discard }
            catch { Write-WfLog "Discard also failed: $($_.Exception.Message). Run Repair-WfMount." -Level ERROR }
        }
        throw
    }
}

function Repair-WfMount {
<#
.SYNOPSIS
    Clears stale mounts left behind by a crash, reboot or killed session.
.DESCRIPTION
    Tries a clean discard of anything still mounted, then runs
    dism /Cleanup-Mountpoints, then reports what is left. This is the first thing
    to run when a servicing job refuses to start.
#>
    [CmdletBinding()]
    param([switch] $Force)

    Assert-WfElevated
    $cfg = Get-WfConfig

    Write-WfLog 'Checking for mounted images' -Level STEP
    $mounted = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)

    if ($mounted.Count -eq 0) {
        Write-WfLog 'Nothing mounted' -Level OK
    }
    foreach ($m in $mounted) {
        Write-WfLog ("{0} -> {1} [{2}]" -f $m.ImagePath, $m.Path, $m.MountStatus) -Level WARN
        try {
            Dismount-WindowsImage -Path $m.Path -Discard -ErrorAction Stop | Out-Null
            Write-WfLog "Discarded $($m.Path)" -Level OK
        }
        catch {
            Write-WfLog "Could not discard $($m.Path): $($_.Exception.Message)" -Level ERROR
        }
    }

    Write-WfLog 'Running dism /Cleanup-Mountpoints' -Level STEP
    try { Invoke-WfDism @('/Cleanup-Mountpoints') }
    catch { Write-WfLog $_.Exception.Message -Level WARN }

    $mount = $cfg['MountPath']
    if ((Test-Path -LiteralPath $mount) -and @(Get-ChildItem -LiteralPath $mount -Force).Count -gt 0) {
        if ($Force) {
            Write-WfLog "Force-clearing leftover files in $mount" -Level WARN
            Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
            New-WfDirectory $mount | Out-Null
        }
        else {
            Write-WfLog "$mount still contains files. Re-run with -Force to clear it." -Level WARN
        }
    }

    return @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)
}

function Add-WfUpdate {
<#
.SYNOPSIS
    Applies .msu/.cab updates to a mounted image.
.DESCRIPTION
    Since February 2021 the Windows 10 servicing stack update and the cumulative
    update ship as a single combined .msu, so one file is the normal case.

    Windows 11 24H2 brought the exception back: servicing is checkpoint-based, so
    a current cumulative arrives as two files and the checkpoint must go in first.
    Files are applied in natural name order, which puts the lower KB number --
    the older package -- first, and that is the order these need. Prefix them
    01-, 02- if you ever need to override it.
.PARAMETER MountPath
    Defaults to the configured mount path. The image must already be mounted.
.PARAMETER File
    Apply only these files instead of everything in the folder. Each may be a
    full path or just a file name in the Updates folder. This is what "apply the
    two updates I picked" needs -- without it the only unit of work is the whole
    folder, so last month's cumulative goes in again alongside this month's.
#>
    [CmdletBinding()]
    param(
        [string]   $UpdatePath,
        [string]   $MountPath,
        [string[]] $File,
        [switch]   $ContinueOnError
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $UpdatePath) { $UpdatePath = $cfg['UpdateRoot'] }
    if (-not $MountPath)  { $MountPath  = $cfg['MountPath'] }

    $pkgs = @()

    if ($File -and @($File).Count -gt 0) {
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($f in @($File)) {
            if (-not $f) { continue }
            $candidate = $f
            if (-not (Test-Path -LiteralPath $candidate)) { $candidate = Join-WfPath $UpdatePath $f }
            if (Test-Path -LiteralPath $candidate) { $pkgs += @(Get-Item -LiteralPath $candidate) }
            else { $missing.Add($f) }
        }
        # Named files that are not there is a different situation from an empty
        # folder: the caller believed it had them.
        if ($missing.Count -gt 0) {
            throw ("Not found in the Updates folder: {0}" -f ($missing -join ', '))
        }
        $pkgs = @($pkgs | Sort-Object { ConvertTo-WfNaturalKey $_.Name })
    }
    else {
        $UpdatePath = Assert-WfPath -Path $UpdatePath -Label 'Update path'
        $pkgs = @(Get-ChildItem -LiteralPath $UpdatePath -Include '*.msu','*.cab' -File -Recurse |
                    Sort-Object { ConvertTo-WfNaturalKey $_.Name })
    }

    # Nothing in a 'checkpoints' folder is ever applied. One rule, applied to both
    # branches above, because the branch it was missing from is the one that runs.
    #
    # This shipped filtering only the folder scan -- and Download+inject does not
    # use the folder scan. It passes an explicit -File list built from what was
    # downloaded, which includes the checkpoint, so DISM was handed the very file
    # the checkpoints folder exists to keep away from it. The test passed because
    # it exercised the branch I had changed rather than the branch in use.
    $skipped = New-Object System.Collections.Generic.List[object]
    $held    = @($pkgs | Where-Object { (Split-Path $_.DirectoryName -Leaf) -eq 'checkpoints' })

    foreach ($h in $held) {
        Write-WfLog "  $($h.Name) is a held checkpoint -- not applied." -Level INFO
        $skipped.Add([pscustomobject]@{
            Package  = $h.Name
            Status   = 'Checkpoint'
            Reason   = 'Held in .\checkpoints. Applying it on its own is what fails; it is kept only in case a retry needs it.'
            WhatToDo = ''
            Code     = ''
            Error    = $null
        })
    }
    if ($held.Count -gt 0) {
        $pkgs = @($pkgs | Where-Object { (Split-Path $_.DirectoryName -Leaf) -ne 'checkpoints' })
    }

    # The held rows go back even when nothing is left to apply. A caller that
    # named two files and sees an empty result has no way to tell "refused" from
    # "lost", and would reasonably conclude the tool dropped its work.
    if ($pkgs.Count -eq 0) {
        if ($held.Count -eq 0) { Write-WfLog "No .msu or .cab found under $UpdatePath" -Level WARN }
        else { Write-WfLog 'Every file named was a held checkpoint -- there was nothing to apply.' -Level WARN }
        return $skipped.ToArray()
    }

    # A checkpoint set is ONE package. The checkpoints are not steps, and they
    # must not be beside it either.
    #
    # Windows 11 24H2 cumulative updates are checkpoint-based: one catalog entry
    # arrives as several .msu files, only one of which is the update.
    #
    # Two wrong answers were tried before this one. Applying the files in turn
    # asks DISM to install a superseded 26100.1742 baseline into an image already
    # at 26100.7623, which it refuses. Putting them all in one folder and pointing
    # DISM at the target is Microsoft's documented procedure -- and it fails too:
    # with a checkpoint .msu in the same directory, DISM routes the pair through
    # the Windows Update Agent (CDismMsuManager::ProcessWithUpdateAgent) and dies
    # with 0x800401E3 or 0x80070228, both surfacing as the same misleading
    # "error applying the Unattend.xml file from the .msu package".
    #
    # What works is the target alone. A checkpoint that is already in the image
    # does not need applying, and any image past its build already has it -- so
    # Save-WfUpdate keeps them one directory down, and this never puts them back.
    #
    # The set is identified by the marker Save-WfUpdate leaves in the folder, not
    # by guessing from filenames. Guessing would eventually mistake an ordinary
    # Updates folder holding two months of cumulative updates for a set and skip
    # one of them.
    $setForPkg = @{}
    $byDir     = $pkgs | Group-Object { Split-Path $_.FullName -Parent }

    $pkgs = @(foreach ($dir in $byDir) {
        $set = Get-WfUpdateSet -Path $dir.Name
        if (-not $set -or -not $set.Target) { $dir.Group; continue }

        $targetFile = @($dir.Group | Where-Object { $_.Name -eq $set.Target })
        if ($targetFile.Count -eq 0) {
            Write-WfLog ("$($dir.Name) is marked as a checkpoint set but $($set.Target) is not in it -- applying what is there instead.") -Level WARN
            $dir.Group
            continue
        }

        # Anything else that ended up in the target's own directory is reported
        # and excluded. It should not be there; if it is, applying it is the
        # failure mode this whole arrangement exists to avoid.
        foreach ($o in @($dir.Group | Where-Object { $_.Name -ne $set.Target })) {
            $skipped.Add([pscustomobject]@{
                Package  = $o.Name
                Status   = 'Checkpoint'
                Reason   = 'An earlier checkpoint. Not applied on its own, and kept out of the update file directory.'
                WhatToDo = ''
                Code     = ''
                Error    = $null
            })
        }

        $held = @()
        $cp   = Join-Path $dir.Name 'checkpoints'
        if (Test-Path -LiteralPath $cp) {
            $held = @(Get-ChildItem -LiteralPath $cp -Filter '*.msu' -File -ErrorAction SilentlyContinue)
        }

        Write-WfLog ("$($set.KB): applying $($set.Target) on its own. $($held.Count) checkpoint(s) held in .\checkpoints, out of DISM's way.") -Level INFO
        $setForPkg[$targetFile[0].FullName] = [pscustomobject]@{ Set = $set; Held = $held; Folder = $dir.Name }
        $targetFile[0]
    })

    Write-WfLog ("Applying {0} update package(s)" -f $pkgs.Count) -Level STEP
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($s in $skipped) { $results.Add($s) }
    $stopped = $false

    # A scratch directory of our own, and a per-run DISM log.
    #
    # Left to itself DISM uses %TEMP%, which on a domain-joined workstation is
    # often on the smallest volume there is, and unpacking a 5 GB package needs
    # room. Naming it also means the free space can be reported before the
    # operation rather than inferred from the failure afterwards.
    $scratch = $null
    try {
        $scratch = New-WfDirectory (Join-WfPath $cfg['LogRoot'] 'DismScratch')
    }
    catch { $scratch = $null }

    if ($scratch) {
        $free = $null
        try {
            $qualifier = (Split-Path -Qualifier $scratch)
            $free = (Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction Stop).Free
        }
        catch { }
        if ($null -ne $free) {
            Write-WfLog ("Scratch: $scratch ({0} free)" -f (Format-WfSize $free)) -Level INFO
            if ($free -lt 10GB) {
                Write-WfLog '  under 10 GB free -- a cumulative update may not have room to unpack.' -Level WARN
            }
        }
        else { Write-WfLog "Scratch: $scratch" -Level INFO }
    }

    # A UUP package cannot be unpacked without the Windows Update Agent.
    #
    # Checked here rather than at the top of the run, and only when a package
    # actually needs it: cabinet-format .msu and .cab files are unpacked by DISM
    # itself and do not care whether wuauserv exists. Demanding it for those
    # would refuse work that would have succeeded.
    #
    # Worth doing at all because of what it costs not to. Without this the run
    # mounts, downloads, expands 4.85 GB into the scratch folder and fails seven
    # minutes later with a message about an Unattend.xml -- for a service setting
    # that takes one line to read.
    $needsAgent = @($pkgs | Where-Object {
        $_.Extension -eq '.msu' -and (Test-WfUpdateContainer -Path $_.FullName -MinimumBytes 0).Kind -eq 'Wim'
    })

    if ($needsAgent.Count -gt 0) {
        $agent = Test-WfUpdateAgent
        if (-not $agent.Ok) {
            throw ("$($needsAgent[0].Name) is a UUP package, and DISM unpacks those through the Windows Update Agent rather than on its own -- but $($agent.Reason). " +
                   "Nothing is downloaded from Windows Update; the service is simply how the package is expanded. " +
                   "Fix it with:  Set-Service wuauserv -StartupType Manual; Start-Service wuauserv  -- then retry. " +
                   "Stopping here rather than spending several minutes expanding $($needsAgent.Count) package(s) that cannot install.")
        }
        if ($agent.Known) {
            Write-WfLog ("Windows Update Agent: wuauserv is $($agent.StartMode)/$($agent.State) -- needed to unpack $($needsAgent.Count) UUP package(s).") -Level INFO
        }
    }

    # Which generation is the image about to be serviced?
    #
    # Because nothing checked, and a servicing run happily handed a Windows 11
    # 24H2 package to a Windows 10 19044 image. DISM got as far as looking for a
    # 26100 servicing stack inside a WinSxS that only has 19041 -- "Failed to find
    # a matching version for servicing stack ... 10.0.19041.4467" -- and failed
    # somewhere five layers down, in a message that named neither the image nor
    # the package.
    #
    # The Updates folder is a folder. It accumulates. Anyone testing two images in
    # one afternoon ends up with both generations in it, and a servicing run
    # applies everything it finds. Refusing an obvious mismatch costs one regex.
    $imgBuild  = 0
    $imgServer = $null
    try {
        $cv = Get-WfOfflineCurrentVersion -MountPath $MountPath
        foreach ($n in @('CurrentBuildNumber', 'CurrentBuild')) {
            if ($imgBuild -eq 0 -and $cv.ContainsKey($n)) { $imgBuild = [int]$cv[$n] }
        }
        # Server or client, from the image itself. InstallationType is 'Server',
        # 'Server Core' or 'Client' -- and it is the ONLY thing that separates a
        # Server 2025 image from a Windows 11 24H2 one, because the build number
        # is 26100 for both.
        if ($cv.ContainsKey('InstallationType')) {
            $imgServer = ([string]$cv['InstallationType'] -match 'Server')
        }
    }
    catch { }

    # 22000 is where Windows 11 starts. Nothing subtler is needed: this is here
    # to catch 10-versus-11, not to second-guess which release within a family.
    $imgMajor = 0
    if     ($imgBuild -ge 22000) { $imgMajor = 11 }
    elseif ($imgBuild -gt 0)     { $imgMajor = 10 }

    foreach ($p in $pkgs) {
        # The generation is right there in the file name: windows10.0-kbxxxxxxx,
        # windows11.0-kbxxxxxxx, and windows11.0-kbxxxxxxx-x64-2025 for Server
        # 2025. A .cab or a differently-named file yields nothing and is left
        # alone -- an unrecognised name is not a mismatch.
        $id       = Get-WfPackageIdentity -Name $p.Name
        $pkgMajor = $id.Major

        if ($imgMajor -gt 0 -and $pkgMajor -gt 0 -and $pkgMajor -ne $imgMajor) {
            Write-WfLog ("- $($p.Name) is a Windows $pkgMajor package and this image is Windows $imgMajor (build $imgBuild) -- skipped.") -Level WARN
            $results.Add([pscustomobject]@{
                Package  = $p.Name
                Status   = 'NotApplicable'
                Reason   = "A Windows $pkgMajor package cannot be applied to a Windows $imgMajor image (build $imgBuild)."
                WhatToDo = 'Move it out of the Updates folder, or use Download + inject on the Updates tab to apply one chosen package instead of everything in the folder.'
                Code     = ''
                Error    = $null
            })
            continue
        }

        # Server 2025 versus Windows 11 24H2 -- the same build, the same KB, and
        # two different packages. The generation check above cannot see it: both
        # are windows11.0.
        #
        # Only the certain direction is refused. A package carrying the -2025
        # marker IS a server package, so applying it to a client image is a
        # mistake that can be named without qualification. The other way round is
        # an inference from a MISSING marker, and refusing on a missing marker
        # would block a legitimate update the day Microsoft changes the naming.
        # DISM answers that one in seconds with 0x800f081e, which this toolkit
        # already classifies as NotApplicable rather than a failure.
        if ($id.IsServer -eq $true -and $imgServer -eq $false) {
            Write-WfLog ("- $($p.Name) is a Windows Server $($id.ServerRelease) package and this image is a client image (build $imgBuild) -- skipped.") -Level WARN
            $results.Add([pscustomobject]@{
                Package  = $p.Name
                Status   = 'NotApplicable'
                Reason   = "This is the Windows Server $($id.ServerRelease) build of the update (the -$($id.ServerRelease) in its name), and this image is a client image."
                WhatToDo = "Server 2025 and Windows 11 24H2 are both build 26100 and share one KB number, so the catalog offers both under the same search -- the client one is titled 'Windows 11 Version 24H2' and the server one 'Microsoft server operating system version 24H2'. Download the client build instead; WimForge files the two in separate folders."
                Code     = ''
                Error    = $null
            })
            continue
        }

        if ($id.IsServer -eq $false -and $imgServer -eq $true) {
            Write-WfLog ("  $($p.Name) looks like a client package and this is a server image -- trying it anyway; DISM will say if it does not apply.") -Level WARN
        }

        Write-WfLog "+ $($p.Name)" -Level INFO
        $attempted = Get-Date

        $params = @{ MountPath = $MountPath; PackagePath = $p.FullName }
        if ($scratch) { $params['ScratchDirectory'] = $scratch }
        $dismLog = $null
        try {
            $dismLog = Join-WfPath $cfg['LogRoot'] ("dism-{0}.log" -f ($p.BaseName -replace '[^\w\.-]', '_'))
            $params['LogPath'] = $dismLog
        }
        catch { }

        # Written down before the attempt, because a failure that takes the
        # session with it still leaves the exact call in the log.
        Write-WfLog ("  Add-WfPackageOffline -MountPath '{0}' -PackagePath '{1}'{2}" -f `
            $MountPath, $p.FullName, $(if ($scratch) { " -ScratchDirectory '$scratch'" } else { '' })) -Level INFO -NoConsole

        try {
            # Cmdlet or dism.exe is Add-WfPackageOffline's decision, made on the
            # container format: a UUP package needs the update agent, and that
            # activation only succeeds out-of-process. See the comment there.
            $how = Add-WfPackageOffline @params
            if ($how -eq 'DismExe') {
                Write-WfLog '  (applied through dism.exe -- a UUP package cannot be unpacked from inside PowerShell)' -Level INFO -NoConsole
            }
            # Same shape as the failure rows: a grid built from the first object
            # loses every column the first row does not have, so a run whose first
            # package succeeded would show no Reason column for the ones after it.
            $results.Add([pscustomobject]@{
                Package = $p.Name; Status = 'Applied'; Reason = ''
                WhatToDo = ''; Code = ''; Error = $null })
            Write-WfLog "  applied" -Level OK
        }
        catch {
            $msg = $_.Exception.Message.Trim()

            # One retry, and only for the one failure it can fix.
            #
            # Applying the target alone is right when the checkpoint is already
            # in the image, which for anything past the checkpoint's build it is.
            # If DISM says a prerequisite is genuinely missing -- 0x800f0831 --
            # then this image is older than assumed and does need them, so fall
            # back to Microsoft's documented layout: checkpoints beside the
            # target, one attempt, and whatever it says stands.
            #
            # Deliberately NOT attempted for the Unattend.xml/UUP failure, which
            # is caused BY that layout. Retrying into it would turn one failure
            # into two and take another seven minutes doing it.
            $pre = Get-WfDismError -Message $msg
            $info = $setForPkg[$p.FullName]

            if ($pre.Code -eq '0x800f0831' -and $info -and $info.Held.Count -gt 0) {
                Write-WfLog "  a prerequisite is missing, so this image does need the checkpoint(s). Retrying with them alongside." -Level WARN
                $moved = @()
                try {
                    foreach ($h in $info.Held) {
                        $dest = Join-Path $info.Folder $h.Name
                        Copy-Item -LiteralPath $h.FullName -Destination $dest -Force
                        $moved += $dest
                    }
                    $null = Add-WfPackageOffline @params
                    $results.Add([pscustomobject]@{
                        Package = $p.Name; Status = 'Applied'
                        Reason = 'Applied on the second attempt, with the checkpoint(s) alongside.'
                        WhatToDo = ''; Code = ''; Error = $null })
                    Write-WfLog '  applied, with the checkpoint(s)' -Level OK
                    continue
                }
                catch { $msg = $_.Exception.Message.Trim() }
                finally {
                    # Put the folder back the way it was either way. Leaving a
                    # checkpoint beside the target would break the NEXT run.
                    foreach ($m in $moved) { Remove-Item -LiteralPath $m -Force -ErrorAction SilentlyContinue }
                }
            }

            # Classified rather than pattern-matched at the call site. A package
            # that does not apply is the EXPECTED outcome of pointing an Updates
            # folder holding several builds at one image -- calling that 'Failed'
            # makes an entirely successful run report as broken, and the operator
            # then goes looking for a problem that is not there.
            $why = Get-WfDismError -Message $msg

            # When DISM hands PowerShell a message with no hex code in it, the
            # code usually exists -- it is just in dism.log instead. Recovering it
            # is the difference between "review the log file" and a named cause,
            # so the log is read and the classification retried with what it says.
            $tail = @()
            if (-not $why.Code) {
                # The package's OWN log now that -LogPath is set, falling back
                # to the system one. Reading %WINDIR%\Logs\DISM\dism.log here
                # would mean sifting every servicing operation this machine has
                # ever run to find the eleven lines that belong to this package.
                $tail = @(Get-WfDismLogTail -Since $attempted -LogPath $dismLog)
                if ($tail.Count -eq 0) { $tail = @(Get-WfDismLogTail -Since $attempted) }
                $hex  = [regex]::Match(($tail -join ' '), '0x8[0-9a-fA-F]{7}')
                if ($hex.Success) {
                    $better = Get-WfDismError -Message "$msg ($($hex.Value))"
                    # Only if the code actually means something. An unrecognised
                    # code would replace a decent text-matched explanation with
                    # the raw message, which is a step backwards.
                    if ($better.Recognised) {
                        $better.WhatToDo = (@($why.WhatToDo, $better.WhatToDo) |
                                            Where-Object { $_ }) -join ' '
                        $why = $better
                    }
                    else {
                        $why.Code = $hex.Value.ToLowerInvariant()
                    }
                }
            }

            $status = 'Failed'
            if (-not $why.Fatal) { $status = 'NotApplicable' }

            $results.Add([pscustomobject]@{
                Package  = $p.Name
                Status   = $status
                Reason   = $why.Summary
                WhatToDo = $why.WhatToDo
                Code     = $why.Code
                Error    = $msg
            })

            if ($status -eq 'NotApplicable') {
                Write-WfLog "  not applicable: $($why.Summary)" -Level WARN
                if ($why.WhatToDo) { Write-WfLog "  $($why.WhatToDo)" -Level INFO }
            }
            else {
                Write-WfLog "  failed: $($why.Summary)" -Level ERROR
                if ($why.WhatToDo) { Write-WfLog "  $($why.WhatToDo)" -Level INFO }
                Write-WfLog "  DISM said: $msg" -Level INFO -NoConsole

                # Shown, not referred to. "Review the log file" is where most
                # people stop, and the lines it means are right here.
                if ($tail.Count -eq 0) { $tail = @(Get-WfDismLogTail -Since $attempted -LogPath $dismLog) }
                if ($tail.Count -eq 0) { $tail = @(Get-WfDismLogTail -Since $attempted) }
                if ($tail.Count -gt 0) {
                    Write-WfLog "  from dism.log:" -Level INFO
                    foreach ($t in $tail) { Write-WfLog "    $t" -Level INFO }
                }
            }

            if (-not $ContinueOnError -and $why.Fatal) {
                # Rethrown with the explanation attached, so whatever catches
                # this upstream -- a job, a menu action -- has something worth
                # showing rather than the raw hex.
                throw (Format-WfDismError -Message $msg -Context "Applying $($p.Name) failed.")
            }

            # -ContinueOnError means "hand me a report instead of an exception".
            # It does not mean "keep servicing an image that just failed to
            # service". A package that hard-fails can leave pending operations
            # behind, and stacking more updates on top of that turns one
            # diagnosable failure into an image nobody can reason about.
            #
            # Not-applicable is different and does not stop anything -- it is the
            # expected outcome of an Updates folder spanning several builds.
            if ($why.Fatal) {
                $stopped = $true
                Write-WfLog '  stopping here -- nothing else will be applied to an image that just failed a package.' -Level WARN
                break
            }
        }
    }

    # Named, so "3 packages, 1 applied" cannot be misread as two silent failures.
    if ($stopped) {
        $done = @($results | ForEach-Object { $_.Package })
        foreach ($p in $pkgs) {
            if ($done -contains $p.Name) { continue }
            $results.Add([pscustomobject]@{
                Package  = $p.Name
                Status   = 'Skipped'
                Reason   = 'An earlier package failed, so this was not attempted.'
                WhatToDo = 'Fix the failure above, discard the mount, and run this again from a clean mount.'
                Code     = ''
                Error    = $null
            })
        }
    }

    return $results
}

function Invoke-WfUpdateInject {
<#
.SYNOPSIS
    Applies chosen update files to an image in one step: mount, apply, commit.
.DESCRIPTION
    The short path from "these two updates" to "they are in the image", without
    running a whole servicing run and without applying everything that happens to
    be sitting in the Updates folder.

    The named image is mounted and committed in place, which is how every other
    single-change operation in this toolkit behaves. Pass -WorkingCopy to work on
    a copy instead and leave the master alone.

    If that image is ALREADY open, the open mount is used instead of a second one
    being made -- and, following the same rule as every other reuse here, it is
    left open and uncommitted afterwards. That is the difference worth knowing:
    injecting into a freshly mounted image saves the .wim, injecting into one you
    opened yourself does not, until you close it and choose commit.

    Any failure discards the mount rather than leaving a half-serviced image
    behind. The one exception DISM raises that is not really a failure --
    0x800f081e, "the update does not apply to this image" -- is reported and
    skipped, because an Updates folder covering two builds produces it routinely.
.PARAMETER File
    The update files to apply. Full paths, or names in the Updates folder.
.PARAMETER Cleanup
    Also clean the component store afterwards. Slower, and worth it before a
    publish rather than after every update.
.EXAMPLE
    Invoke-WfUpdateInject -ImagePath D:\Imaging\Images\LTSC2021-Base.wim -File 'windows10.0-kb5094127-x64.msu'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [int]      $Index = 1,
        [string[]] $File,
        [switch]   $WorkingCopy,
        [switch]   $Cleanup,
        [switch]   $ContinueOnError,
        [string]   $Notes
    )

    Assert-WfElevated

    $mounted = $null
    $applied = @()

    # -WorkingCopy mounts a copy, so the file that actually received the updates
    # is the one the mount reports, not the one that was asked for. Recorded
    # before the mount object is cleared.
    $written = $ImagePath

    # An image that is already open is used, not refused.
    #
    # Mounting a 10 GB image takes about two minutes, so opening one is a
    # deliberate act and the operator has already paid for it. Walking up to that
    # mount and demanding an empty folder made "open the image, then inject" --
    # the obvious order to do things in -- the one order that could not work.
    #
    # The rule from every other reuse in this toolkit applies here too: a mount
    # this function did not open, it does not close. So a reused mount is left
    # open and UNCOMMITTED, and that is said plainly, because the alternative is
    # someone discarding on close and losing a 5 GB download's worth of work.
    $reused = $false
    $open   = $null
    try { $open = Get-WfCurrentMount } catch { }

    if ($open -and $open.MountPath) {
        if ("$($open.ImagePath)".TrimEnd('\') -ne "$ImagePath".TrimEnd('\')) {
            throw ("A different image is open at $($open.MountPath): $(Split-Path $open.ImagePath -Leaf). " +
                   "Close it before injecting into $(Split-Path $ImagePath -Leaf).")
        }
        if ($open.ReadOnly) {
            throw ("$(Split-Path $open.ImagePath -Leaf) is open READ-ONLY at $($open.MountPath), so nothing can be " +
                   "written to it. Close it and open it again for writing.")
        }
        if ($WorkingCopy) {
            throw ("-WorkingCopy would mount a second image, and $(Split-Path $open.ImagePath -Leaf) is already open. " +
                   "Close it first, or drop -WorkingCopy to update the image that is open.")
        }
        # Same file, different index is still a different image. Applying a
        # cumulative to whichever index happened to be open would be silent and
        # wrong, and only discoverable much later.
        if ($open.Index -and $Index -and [int]$open.Index -ne [int]$Index) {
            throw ("Index $($open.Index) of $(Split-Path $open.ImagePath -Leaf) is open, but index $Index was asked for. " +
                   "Close it and open index $Index, or inject into the one that is open.")
        }
        $reused = $true
        $Index  = [int]$open.Index
    }

    try {
        if ($reused) {
            $mounted = $open
            Write-WfLog "Using the image already open at $($open.MountPath) -- no second mount, and it stays open." -Level OK
        }
        else {
            $mounted = Mount-WfImage -ImagePath $ImagePath -Index $Index -WorkingCopy:$WorkingCopy
        }

        $written = $mounted.ImagePath
        $applied = @(Add-WfUpdate -MountPath $mounted.MountPath -File $File -ContinueOnError:$ContinueOnError)

        if ($Cleanup) { Invoke-WfCleanup -MountPath $mounted.MountPath | Out-Null }

        if ($reused) {
            Write-WfLog ("The image is still open at $($mounted.MountPath) and these changes are NOT saved yet. " +
                         "Close it and choose commit to write them into $(Split-Path $written -Leaf); " +
                         "choosing discard throws them away.") -Level WARN
        }
        else {
            Dismount-WfImage -MountPath $mounted.MountPath -Save
        }
        $mounted = $null
    }
    catch {
        if ($mounted -and -not $reused) {
            Write-WfLog 'Discarding the mount -- the image is left as it was.' -Level WARN
            try { Dismount-WfImage -MountPath $mounted.MountPath -Discard }
            catch { Write-WfLog "Dismount also failed: $($_.Exception.Message). Run Repair-WfMount." -Level ERROR }
        }
        elseif ($mounted) {
            # It was open before this ran, so it stays open. Discarding here would
            # take the operator's own mount down with it, along with anything else
            # they had already done to it.
            Write-WfLog ("The image is still open at $($mounted.MountPath). It may hold partial changes -- " +
                         "close it and choose discard if you want it back as it was.") -Level WARN
        }
        throw
    }

    $ok      = @($applied | Where-Object { $_.Status -eq 'Applied' })
    $skipped = @($applied | Where-Object { $_.Status -eq 'NotApplicable' })
    $failed  = @($applied | Where-Object { $_.Status -ne 'Applied' -and $_.Status -ne 'NotApplicable' })

    Write-WfHistory -Action 'Inject updates' -ImagePath $written -Notes $Notes -Detail @{
        Index        = $Index
        Applied      = @($ok      | ForEach-Object { $_.Package })
        NotApplicable= @($skipped | ForEach-Object { $_.Package })
        Failed       = @($failed  | ForEach-Object { $_.Package })
        WorkingCopy  = [bool]$WorkingCopy
        Cleanup      = [bool]$Cleanup
        # Whether the .wim on disk actually changed. A reused mount is left open,
        # so the history entry would otherwise read as "these updates are in this
        # image" when they are only in the mount and one discard away from gone.
        Committed    = (-not $reused)
        ReusedMount  = $reused
    }

    if ($failed.Count -gt 0) {
        Write-WfLog ("{0} applied, {1} did not apply to this image, {2} FAILED" -f `
            $ok.Count, $skipped.Count, $failed.Count) -Level ERROR
    }
    elseif ($skipped.Count -gt 0) {
        Write-WfLog ("{0} applied. {1} did not apply to this image, which is normal when the Updates folder covers more than one build -- nothing went wrong." -f `
            $ok.Count, $skipped.Count) -Level OK
    }
    else {
        Write-WfLog ("{0} applied, all of them." -f $ok.Count) -Level OK
    }

    # Say what just happened to the size of the image.
    #
    # Injecting a cumulative is the one operation in this toolkit that leaves
    # several GB of now-superseded payload in the component store. Everything
    # else that writes to an image -- drivers, registry, payload files, locale,
    # lockdown, recovery -- writes files and keys, and cleanup reclaims nothing
    # from them. So the note belongs here and nowhere else, and its absence
    # elsewhere is a fact rather than an omission.
    #
    # It matters most on the reused-mount path, where the operator is about to
    # press Close and commit: this is the last moment cleanup is cheap, and after
    # the commit it costs another full mount to do.
    if ($ok.Count -gt 0) {
        Write-WfLog ("The component store now holds the payload these update(s) superseded -- several GB that the commit will compress and ship. " +
                     "The 'Component cleanup' button on the Servicing tab reclaims it (with /ResetBase the updates can no longer be uninstalled, which is normally what an image wants).") -Level INFO
    }

    return $applied
}

function Invoke-WfCleanup {
<#
.SYNOPSIS
    Analyses and optionally resets the component store of a mounted image.
.DESCRIPTION
    Analyse first, then decide. The component store grows with every update, and
    how much of it is reclaimable is a real number this reports rather than
    guesses at.

    /ResetBase is the one to think about. It makes the image smaller and makes
    every update in it permanent -- nothing installed before that point can be
    uninstalled from the deployed machine afterwards. Right for a shipping image,
    wrong for one still being tested, so it is opt-in.
.PARAMETER ResetBase
    Run /StartComponentCleanup /ResetBase. Big size win. Note that afterwards the
    applied updates can no longer be uninstalled from the deployed OS -- normally
    what you want in an image, but it is a one-way door.
#>
    [CmdletBinding()]
    param(
        [string] $MountPath,
        [switch] $ResetBase,
        [switch] $AnalyzeOnly
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    Write-WfLog 'Analysing component store' -Level STEP
    $analysis = Invoke-WfDism @("/Image:$MountPath", '/Cleanup-Image', '/AnalyzeComponentStore') -PassThruOutput
    foreach ($line in $analysis) {
        $t = "$line".Trim()
        if ($t -match 'Actual Size|Shared|Backups|Cache|Reclaimable|Recommended') {
            Write-WfLog $t -Level INFO
        }
    }

    if ($AnalyzeOnly) { return $analysis }

    if ($ResetBase) {
        Write-WfLog 'Component cleanup with /ResetBase (one-way)' -Level STEP
        Invoke-WfDism @("/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
    }
    else {
        Write-WfLog 'Component cleanup' -Level STEP
        Invoke-WfDism @("/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup')
    }
    Write-WfLog 'Cleanup complete' -Level OK
}

function Export-WfImage {
<#
.SYNOPSIS
    Exports an image to a new maximally-compressed WIM.
.DESCRIPTION
    Export rewrites the WIM without the free space left behind by servicing, which
    is usually a larger saving than the drivers cost. This is the file you publish.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [int]    $Index = 1,
        [switch] $Force
    )

    $SourcePath = Assert-WfPath -Path $SourcePath -Label 'Source image'
    New-WfDirectory (Split-Path $DestinationPath -Parent) | Out-Null

    if (Test-Path -LiteralPath $DestinationPath) {
        if (-not $Force) { throw "Destination already exists: $DestinationPath (use -Force)" }
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    Write-WfLog "Exporting to $DestinationPath (max compression)" -Level STEP
    Export-WindowsImage -SourceImagePath $SourcePath -SourceIndex $Index `
        -DestinationImagePath $DestinationPath -CompressionType Max -ErrorAction Stop | Out-Null

    $before = (Get-Item -LiteralPath $SourcePath).Length
    $after  = (Get-Item -LiteralPath $DestinationPath).Length
    Write-WfLog ("{0} -> {1}" -f (Format-WfSize $before), (Format-WfSize $after)) -Level OK

    return [pscustomobject]@{
        Source      = $SourcePath
        Destination = $DestinationPath
        BeforeBytes = $before
        AfterBytes  = $after
    }
}

function Invoke-WfServicingRun {
<#
.SYNOPSIS
    The full monthly job in one call: mount, update, inject drivers, customise,
    clean, commit, export and record history.
.DESCRIPTION
    This is what the menu's "Run full servicing" option calls. Every stage is
    optional; on any failure the mount is discarded rather than left half-serviced.
.EXAMPLE
    Invoke-WfServicingRun -Verbose
.EXAMPLE
    Invoke-WfServicingRun -SourceImage D:\Imaging\Images\LTSC2021-Base.wim `
        -SkipUpdates -Notes 'Driver refresh only, new TCx model added'
#>
    [CmdletBinding()]
    param(
        [string]   $SourceImage,
        [int]      $Index,
        [string[]] $Models,
        # Where the driver library is, when it is not where the config says.
        #
        # A workstation has one configured DriverRoot and an engineer sometimes
        # has two libraries -- last quarter's, a colleague's, one on a share for a
        # customer's fleet. Editing the setting to service one image and
        # remembering to put it back is how the wrong drivers end up in an image.
        [string]   $DriverRoot,
        [string]   $OutputName,
        [switch]   $SkipUpdates,
        [switch]   $SkipDrivers,
        [switch]   $SkipCleanup,
        # Clean, but stop short of /ResetBase.
        #
        # Cleanup used to be all-or-nothing, and the "all" is the irreversible
        # one: /ResetBase discards the backups that let an update be uninstalled
        # from the deployed OS. For a shipped image that is usually wanted. For an
        # image being iterated on, or one that might need a bad cumulative rolled
        # back, it is not -- and the only alternative on offer was skipping
        # cleanup altogether, which costs size AND a much longer commit for no
        # gain in reversibility.
        [switch]   $KeepUninstall,
        [switch]   $SkipExport,
        [switch]   $ApplyPayload,
        [string]   $Notes
    )

    Assert-WfElevated
    $cfg = Get-WfConfig

    if (-not $SourceImage) { $SourceImage = $cfg['BaseImage'] }
    if (-not $PSBoundParameters.ContainsKey('Index')) { $Index = $cfg['DefaultIndex'] }
    if (-not $OutputName) {
        $OutputName = '{0}-{1}.wim' -f $cfg['ImageNamePrefix'], (Get-Date -Format 'yyyy-MM')
    }

    $SourceImage = Assert-WfPath -Path $SourceImage -Label 'Source image'
    $started     = Get-Date
    $summary     = [ordered]@{}

    Write-WfLog "=== Servicing run started: $(Split-Path $SourceImage -Leaf) index $Index ===" -Level STEP

    # Say up front which of the five steps are on.
    #
    # A run that quietly omits two of them is impossible to audit afterwards:
    # a skipped step logs nothing, so its absence looks identical to a step that
    # ran and had nothing to do. "Why did my servicing run not clean up?" should
    # be answerable from the log, not by reading this function.
    #
    # Skipping cleanup is worth calling out specifically. It is not just a size
    # difference -- the commit then has to compress every superseded payload the
    # update just obsoleted, which is a large part of why a dismount can run for
    # hours.
    $plan = @(
        ('updates: {0}'  -f $(if ($SkipUpdates) { 'SKIPPED' } else { 'yes' })),
        ('drivers: {0}'  -f $(if ($SkipDrivers) { 'SKIPPED' } else { 'yes' })),
        ('payload: {0}'  -f $(if ($ApplyPayload) { 'yes' } else { 'no' })),
        ('cleanup: {0}'  -f $(if ($SkipCleanup) { 'SKIPPED' } elseif ($KeepUninstall) { 'yes, no /ResetBase' } else { 'yes, /ResetBase' })),
        ('export: {0}'   -f $(if ($SkipExport) { 'SKIPPED' } else { 'yes' }))
    )
    Write-WfLog ("Plan -- " + ($plan -join ',  ')) -Level INFO

    if ($SkipCleanup) {
        Write-WfLog '  cleanup is off, so the commit has to write the superseded payload too -- expect the dismount to take considerably longer, and the image to be larger.' -Level WARN
    }

    # Where the time actually went.
    #
    # A run reported one number -- 213.1 minutes -- and the interesting fact was
    # invisible inside it: mount 2m, apply 26m, COMMIT 184m. Finding that meant
    # subtracting timestamps out of the log by hand. A commit taking 86% of a run
    # is a diagnosis (antivirus over the mount, cleanup skipped so the superseded
    # payload gets compressed too); a single total is just a complaint.
    $phase = [ordered]@{}
    $mark  = Get-Date
    $stamp = {
        param([string] $Name)
        $now = Get-Date
        $phase[$Name] = [math]::Round(($now - $script:WfPhaseMark).TotalMinutes, 1)
        $script:WfPhaseMark = $now
    }
    $script:WfPhaseMark = $mark

    $mountInfo = Mount-WfImage -ImagePath $SourceImage -Index $Index -WorkingCopy
    $working   = $mountInfo.ImagePath
    & $stamp 'CopyAndMount'

    try {
        if (-not $SkipUpdates) {
            $u = Add-WfUpdate -ContinueOnError
            $summary['UpdatesApplied'] = @($u | Where-Object { $_.Status -eq 'Applied' }).Count
            $summary['UpdatesFailed']  = @($u | Where-Object { $_.Status -eq 'Failed' }).Count

            # Counted and named, because 'Applied 1, Failed 0' is a true summary
            # of a run that also passed over a package sitting in the Updates
            # folder -- and it reads as though the folder held one file. The skip
            # is a WARN in the log, but the summary is what gets kept, shown in a
            # grid and written to history, and it had no room for the third
            # outcome at all.
            $notApplied = @($u | Where-Object { $_.Status -eq 'NotApplicable' })
            $summary['UpdatesSkipped'] = $notApplied.Count
            if ($notApplied.Count -gt 0) {
                Write-WfLog ("{0} package(s) in the Updates folder were not for this image and were passed over: {1}" -f `
                    $notApplied.Count, (($notApplied | ForEach-Object { $_.Package }) -join ', ')) -Level WARN
            }

            # A failed update ends the run. It used to be counted into the
            # summary and then ignored: -ContinueOnError makes Add-WfUpdate
            # return instead of throw, so the catch below never fired and the
            # run walked straight into its normal commit -- writing a
            # half-serviced image out as the finished article, with the failure
            # visible only as a number in a summary nobody reads twice.
            #
            # Throwing here is deliberate: it routes into the catch that already
            # exists, which discards the mount and leaves the master untouched.
            if ($summary['UpdatesFailed'] -gt 0) {
                $names = @($u | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { $_.Package })
                throw ("{0} update(s) failed, so this run will not be committed: {1}" -f `
                        $summary['UpdatesFailed'], ($names -join ', '))
            }
            & $stamp 'Updates'
        }

        if (-not $SkipDrivers) {
            $drvParams = @{ Models = $Models }
            if ($DriverRoot) { $drvParams['DriverRoot'] = $DriverRoot }
            $d = Add-WfDriver @drvParams
            $summary['DriversAdded']  = $d.Added
            $summary['DriversFailed'] = $d.Failed
            $summary['Models']        = ($d.Models -join ', ')
            & $stamp 'Drivers'
        }

        if ($ApplyPayload) {
            $p = Copy-WfPayload
            $summary['PayloadFiles'] = $p.FileCount
        }

        if (-not $SkipCleanup) {
            if ($KeepUninstall) {
                Invoke-WfCleanup
                $summary['Cleanup'] = 'StartComponentCleanup'
            }
            else {
                Invoke-WfCleanup -ResetBase
                $summary['Cleanup'] = 'ResetBase'
            }
            & $stamp 'Cleanup'
        }

        Dismount-WfImage
        & $stamp 'Commit'
    }
    catch {
        Write-WfLog "Servicing failed -- discarding the mount so nothing is left half-serviced." -Level ERROR
        Write-WfLog $_.Exception.Message -Level ERROR
        try { Dismount-WfImage -Discard } catch {
            Write-WfLog "Discard also failed. Run Repair-WfMount." -Level ERROR
        }
        throw
    }

    # Either way the result lands at ImageRoot\OutputName. Leaving a transient
    # *.working.wim as the "finished" image -- and recording that path in the
    # build history -- would make the history useless the moment it is cleaned up.
    $outPath = Join-WfPath $cfg['ImageRoot'] $OutputName
    New-WfDirectory (Split-Path $outPath -Parent) | Out-Null

    if (-not $SkipExport) {
        $export = Export-WfImage -SourcePath $working -DestinationPath $outPath -Index $Index -Force
        $final  = $export.Destination
        $summary['ExportedTo'] = $final
        Remove-Item -LiteralPath $working -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-WfLog "Export skipped -- moving the working copy to $outPath" -Level STEP
        if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }
        Move-Item -LiteralPath $working -Destination $outPath -Force
        $final = $outPath
        $summary['MovedTo'] = $final
    }

    & $stamp 'Export'

    $summary['DurationMinutes'] = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    $summary['SourceImage']     = $SourceImage
    $summary['Phases']          = (($phase.Keys | ForEach-Object { "{0} {1}m" -f $_, $phase[$_] }) -join ', ')

    Write-WfHistory -Action 'Servicing run' -ImagePath $final -Detail $summary -Notes $Notes | Out-Null

    Write-WfLog "=== Servicing run complete in $($summary['DurationMinutes']) min ===" -Level OK
    Write-WfLog ("    " + $summary['Phases']) -Level INFO

    # One phase eating most of the run is a diagnosis, not a slow day. Naming it
    # here is the difference between "that took ages" and knowing which knob it
    # was: real-time antivirus over the mount, and a commit made to compress
    # payload that cleanup would have removed.
    $total = [double]$summary['DurationMinutes']
    if ($total -gt 20) {
        foreach ($k in $phase.Keys) {
            if (([double]$phase[$k] / $total) -lt 0.6) { continue }
            Write-WfLog ("    $k alone was {0}% of that." -f [math]::Round(100 * $phase[$k] / $total)) -Level WARN
            if ($k -eq 'Commit') {
                Write-WfLog '    A commit that dominates a run is nearly always one of two things: real-time antivirus scanning the mount folder (Housekeeping > Environment check reports which paths are excluded), or cleanup being skipped, which leaves the superseded payload for the commit to compress.' -Level WARN
            }
        }
    }
    return [pscustomobject]$summary
}
