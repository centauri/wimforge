# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Drivers.ps1 -- the driver library.

    Layout on disk:
        <DriverRoot>\<Vendor>_<Model>\...              exported INF packages
        <DriverRoot>\<Vendor>_<Model>\_manifest.csv    what was harvested
        <DriverRoot>\<Vendor>_<Model>\_system.json     which machine it came from

    The library is harvested from working reference machines rather than assembled
    from vendor driver packs. A vendor pack contains every variant for every board
    revision; feeding all of that to the PnP ranker is how a terminal ends up
    running a driver that almost matches.
#>

function Select-WfNewestDriverPackage {
    <#
        Given several copies of the same driver package, decides which one to
        keep. Pure: it takes descriptions and returns Keep and Drop, touching
        nothing on disk, because the consequences of getting it wrong are not
        the sort you want discovered by running it.

        Each input needs Key (what makes two packages the same -- the inf name),
        Id (something to identify it by), Version and Date.

        Newest wins: version first, date as the tie-break. A package whose
        version will not parse loses to one whose version will, rather than being
        compared as text -- '10.0.1' sorts before '9.0.1' as a string.
    #>
    param([object[]] $Package)

    $keep = New-Object System.Collections.Generic.List[object]
    $drop = New-Object System.Collections.Generic.List[object]

    foreach ($group in ($Package | Group-Object { "$($_.Key)".ToLower() })) {
        if ($group.Count -eq 1) { $keep.Add($group.Group[0]); continue }

        $ranked = @($group.Group | Sort-Object `
            @{ Expression = {
                $v = $null
                if ([version]::TryParse("$($_.Version)", [ref]$v)) { $v } else { [version]'0.0.0.0' }
              }; Descending = $true },
            @{ Expression = {
                $d = [datetime]::MinValue
                if ($_.Date -and [datetime]::TryParse("$($_.Date)", [ref]$d)) { $d } else { [datetime]::MinValue }
              }; Descending = $true },
            @{ Expression = { "$($_.Id)" }; Descending = $false })

        $keep.Add($ranked[0])
        foreach ($loser in $ranked[1..($ranked.Count - 1)]) { $drop.Add($loser) }
    }

    # .ToArray(), not @(). Wrapping a List[object] in @() throws "Argument types
    # do not match" on PowerShell 7 -- List[string] and ArrayList are fine, it is
    # List[object] specifically. Since this module is meant to be callable from
    # either host, the pattern is avoided rather than relied on.
    return [pscustomobject]@{ Keep = $keep.ToArray(); Drop = $drop.ToArray() }
}

function Get-WfExportedPackageFolder {
    <#
        The folder Export-WindowsDriver writes a package into.

        It reuses the driver store's own folder name, which is the parent of
        OriginalFileName -- 'ibtusb.inf_amd64_066635c10f2d559a'. Deriving it
        rather than searching by inf name matters here: nine copies of ibtusb.inf
        in one harvest is normal, and a name search cannot tell them apart.
    #>
    param($Driver, [string] $Root)

    if (-not $Driver.OriginalFileName) { return $null }
    $leaf = Split-Path (Split-Path $Driver.OriginalFileName -Parent) -Leaf
    if (-not $leaf) { return $null }

    $candidate = Join-WfPath $Root $leaf
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Remove-WfDuplicateDriver {
<#
.SYNOPSIS
    Removes superseded copies of the same driver from a harvested model folder.
.DESCRIPTION
    The Windows driver store keeps every version of a package it has ever staged,
    and Export-WindowsDriver exports all of them. A harvest from a laptop that has
    been patched for a year routinely contains nine copies of the Intel Bluetooth
    driver and seven of the graphics extension -- all but one superseded.

    That is not merely wasteful. The whole reason this toolkit harvests from a
    known-good machine rather than from vendor packs is to avoid handing the PnP
    ranker a pile of near-identical candidates; shipping nine versions of one
    driver does exactly what the design set out to avoid.

    Newest wins, by DriverVer: version first, date as the tie-break. Packages
    whose inf names differ are never compared, so nothing that is genuinely a
    different driver can be removed.

    Run without -Confirm:$false to be asked. Use -WhatIf to see the list first.
.PARAMETER Model
    A model folder name, or several. Omit for the whole library.
.EXAMPLE
    Remove-WfDuplicateDriver -WhatIf
.EXAMPLE
    Remove-WfDuplicateDriver -Model Dell_Inc._Dell_Pro_14_PC14250
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string[]] $Model,
        [string]   $DriverRoot
    )

    $cfg = Get-WfConfig
    if (-not $DriverRoot) { $DriverRoot = $cfg['DriverRoot'] }
    $DriverRoot = Assert-WfPath -Path $DriverRoot -Label 'Driver root'

    $modelDirs = @(Get-ChildItem -LiteralPath $DriverRoot -Directory)
    if ($Model) {
        $missing = @($Model | Where-Object { $_ -notin $modelDirs.Name })
        if ($missing.Count -gt 0) { throw "Model folder(s) not found under ${DriverRoot}: $($missing -join ', ')" }
        $modelDirs = @($modelDirs | Where-Object { $_.Name -in $Model })
    }

    $report = New-Object System.Collections.Generic.List[object]

    foreach ($dir in $modelDirs) {
        # One entry per package folder, described by the inf inside it.
        $packages = New-Object System.Collections.Generic.List[object]

        foreach ($sub in Get-ChildItem -LiteralPath $dir.FullName -Directory) {
            $infs = @(Get-ChildItem -LiteralPath $sub.FullName -Filter '*.inf' -File)
            if ($infs.Count -ne 1) {
                # Zero or several infs in one folder: not the ordinary shape, so
                # it is left alone rather than guessed about.
                if ($infs.Count -gt 1) {
                    Write-WfLog ("$($sub.Name) holds $($infs.Count) INFs, so it was left alone") -Level WARN
                }
                continue
            }

            $ver = Get-WfInfDriverVer $infs[0].FullName
            $packages.Add([pscustomobject]@{
                Key     = $infs[0].Name
                Id      = $sub.Name
                Path    = $sub.FullName
                Version = $ver.Version
                Date    = $ver.Date
                Size    = (Get-WfFolderSize $sub.FullName)
            })
        }

        if ($packages.Count -eq 0) { continue }

        $split = Select-WfNewestDriverPackage -Package $packages
        if ($split.Drop.Count -eq 0) {
            Write-WfLog ("{0}: no duplicates" -f $dir.Name) -Level OK
            continue
        }

        $freed = ($split.Drop | Measure-Object Size -Sum).Sum
        Write-WfLog ("{0}: {1} superseded package(s), {2}" -f `
            $dir.Name, $split.Drop.Count, (Format-WfSize $freed)) -Level STEP

        foreach ($d in $split.Drop) {
            $kept = @($split.Keep | Where-Object { "$($_.Key)".ToLower() -eq "$($d.Key)".ToLower() })[0]
            Write-WfLog ("  {0}  {1} -> superseded by {2}" -f `
                $d.Key, (Format-WfVersionLabel $d), (Format-WfVersionLabel $kept)) -Level INFO

            $report.Add([pscustomobject]@{
                Model      = $dir.Name
                Inf        = $d.Key
                Removed    = $d.Id
                Version    = $d.Version
                Date       = $d.Date
                KeptId     = $kept.Id
                KeptVersion= $kept.Version
                SizeBytes  = $d.Size
            })

            if ($PSCmdlet.ShouldProcess($d.Path, 'Remove superseded driver package')) {
                Remove-Item -LiteralPath $d.Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($report.Count -eq 0) {
        Write-WfLog 'Nothing to remove.' -Level OK
        return @()
    }

    $total = ($report | Measure-Object SizeBytes -Sum).Sum
    Write-WfLog ("{0} superseded package(s) removed, {1} freed" -f $report.Count, (Format-WfSize $total)) -Level OK
    return $report.ToArray()
}

function Format-WfVersionLabel {
    <# 'v23.40.1.5 (2024-07-12)', with whatever parts exist. #>
    param($Package)

    $bits = @()
    if ($Package.Version) { $bits += "v$($Package.Version)" }
    if ($Package.Date)    { $bits += "($($Package.Date))" }
    if ($bits.Count -eq 0) { return 'no DriverVer' }
    return ($bits -join ' ')
}

function Export-WfModelDriver {
<#
.SYNOPSIS
    Harvests the third-party INF drivers from this machine into the driver library.
.DESCRIPTION
    Run on one known-good machine per hardware model -- clean Device Manager, all
    peripherals working, vendor packages installed. Export-WindowsDriver returns
    exactly what Windows actually staged, which is the set that demonstrably works.
.PARAMETER ModelName
    Override the auto-detected Vendor_Model folder name. Mandatory with -Path.
.PARAMETER Path
    Harvest from a mounted offline image instead of the running machine.
.PARAMETER KeepAllVersions
    Keep every copy of a package the driver store is holding.

    Off by default, and that default is the important part. The store keeps every
    version it has ever staged, and Export-WindowsDriver exports all of them: a
    year-old laptop routinely yields nine copies of the Intel Bluetooth driver and
    seven of the graphics extension. Handing all of that to the PnP ranker is
    precisely what harvesting from a known-good machine was meant to avoid, so
    only the newest of each is kept and the rest are named in the log.
.PARAMETER ExcludeMicrosoft
    Leave out packages whose provider is Microsoft.

    These are the drivers Windows Update handed the machine rather than the ones
    the vendor shipped -- generic display, audio, Bluetooth, class drivers of
    various kinds. Whether you want them depends on the target: an image that is
    already at the same patch level almost certainly has them, so they are bulk
    for no gain. A terminal that never reaches Windows Update may genuinely need
    one, and that is the case worth thinking about before switching this on.

    Off by default, so nothing is dropped from a harvest without being asked for.
    Either way the count is reported, and what was left out is listed.
#>
    [CmdletBinding()]
    param(
        [string] $Destination,
        [string] $ModelName,
        [string] $Path,
        [switch] $KeepAllVersions,
        [switch] $ExcludeMicrosoft,
        [switch] $Force
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $Destination) { $Destination = $cfg['DriverRoot'] }

    # In offline mode the local CIM data describes this workstation, not the
    # image, so none of it may be recorded as provenance.
    $cs = $null; $bios = $null; $os = $null
    if ($Path) {
        if (-not $ModelName) {
            throw '-ModelName is required with -Path: the local machine identity does not describe an offline image.'
        }
    }
    else {
        $cs   = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $os   = Get-CimInstance Win32_OperatingSystem
        if (-not $ModelName) {
            $ModelName = '{0}_{1}' -f (Get-WfSafeName $cs.Manufacturer), (Get-WfSafeName $cs.Model)
        }
    }

    $modelPath = Join-WfPath $Destination $ModelName

    if (Test-Path -LiteralPath $modelPath) {
        if (-not $Force) { throw "Model folder already exists: $modelPath. Use -Force to replace it." }
        Write-WfLog "Replacing existing $modelPath" -Level WARN
        Remove-Item -LiteralPath $modelPath -Recurse -Force
    }
    New-WfDirectory $modelPath | Out-Null

    Write-WfLog "Harvesting drivers for $ModelName" -Level STEP

    $exportArgs = @{ Destination = $modelPath }
    if ($Path) { $exportArgs['Path'] = $Path } else { $exportArgs['Online'] = $true }
    $drivers = @(Export-WindowsDriver @exportArgs)

    Write-WfLog ("{0} driver package(s) exported" -f $drivers.Count) -Level OK

    # ------------------------------------------------------ superseded copies
    # The driver store holds every version it has ever staged and this exported
    # all of them. Group by inf name, keep the newest, delete the rest.
    $superseded = @()

    if (-not $KeepAllVersions) {
        $described = @($drivers | ForEach-Object {
            $inf = $_.Driver
            if ($_.OriginalFileName) { $inf = Split-Path $_.OriginalFileName -Leaf }
            [pscustomobject]@{
                Key     = $inf
                Id      = $_.Driver
                Version = $_.Version
                Date    = $_.Date
                Driver  = $_
            }
        })

        $split      = Select-WfNewestDriverPackage -Package $described
        $superseded = @($split.Drop)

        if ($superseded.Count -gt 0) {
            $freed = 0
            foreach ($d in $superseded) {
                $kept = @($split.Keep | Where-Object { "$($_.Key)".ToLower() -eq "$($d.Key)".ToLower() })[0]
                Write-WfLog ("  superseded: {0} {1} -- keeping {2}" -f `
                    $d.Key, (Format-WfVersionLabel $d), (Format-WfVersionLabel $kept)) -Level INFO

                $folder = Get-WfExportedPackageFolder -Driver $d.Driver -Root $modelPath
                if ($folder) {
                    $freed += (Get-WfFolderSize $folder)
                    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
                }
                else {
                    Write-WfLog ("  could not locate the exported folder for {0}, so it was left in place" -f $d.Key) -Level WARN
                }
            }

            Write-WfLog ("{0} superseded package(s) removed, {1} freed" -f `
                $superseded.Count, (Format-WfSize $freed)) -Level OK

            $keptIds = @($split.Keep | ForEach-Object { $_.Id })
            $drivers = @($drivers | Where-Object { $keptIds -contains $_.Driver })
            Write-WfLog ("{0} package(s) kept" -f $drivers.Count) -Level OK
        }
        else {
            Write-WfLog 'No superseded copies in this harvest.' -Level OK
        }
    }

    # ------------------------------------------------- Microsoft-provided ones
    # Export-WindowsDriver has already written everything to disk, so excluding
    # is a matter of taking them back out. DISM's own ProviderName is used rather
    # than parsing the INFs, because it is the authority on what the package
    # says about itself.
    $microsoft = @($drivers | Where-Object { Test-WfMicrosoftProvider $_.ProviderName })

    if ($microsoft.Count -gt 0) {
        Write-WfLog ("{0} of those are Microsoft-provided" -f $microsoft.Count) -Level INFO
    }

    if ($ExcludeMicrosoft -and $microsoft.Count -gt 0) {
        $removed = 0
        foreach ($m in $microsoft) {
            Write-WfLog ("  left out: {0} ({1}, {2})" -f $m.Driver, $m.ClassName, $m.ProviderName) -Level INFO

            # Located by the driver store's own folder name, not by searching for
            # the inf: several packages legitimately share an inf name.
            $folder = Get-WfExportedPackageFolder -Driver $m -Root $modelPath
            if ($folder) {
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
        Write-WfLog ("Excluded {0} Microsoft-provided package(s)" -f $removed) -Level OK

        $drivers = @($drivers | Where-Object { -not (Test-WfMicrosoftProvider $_.ProviderName) })
        Write-WfLog ("{0} package(s) kept" -f $drivers.Count) -Level OK
    }

    $manifest = $drivers | Select-Object `
        @{ n = 'InfName';       e = { if ($_.OriginalFileName) { Split-Path $_.OriginalFileName -Leaf } else { $_.Driver } } },
        @{ n = 'PublishedName'; e = { $_.Driver } },
        ClassName, ProviderName, Version, Date, BootCritical,
        @{ n = 'SourceInf';     e = { $_.OriginalFileName } }

    $manifest | Sort-Object ClassName, ProviderName |
        Export-Csv -LiteralPath (Join-WfPath $modelPath '_manifest.csv') -NoTypeInformation -Encoding UTF8

    $source = 'running system'
    if ($Path) { $source = "offline image: $Path" }

    $system = [ordered]@{
        ModelFolder      = $ModelName
        Source           = $source
        DriverCount      = $drivers.Count
        Superseded       = $superseded.Count
        KeptAllVersions  = [bool]$KeepAllVersions
        MicrosoftFound   = $microsoft.Count
        MicrosoftExcluded = [bool]$ExcludeMicrosoft
        HarvestedUtc     = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        HarvestedBy      = "$env:USERDOMAIN\$env:USERNAME"
    }
    if (-not $Path) {
        $ubr = Get-WfLocalUbr
        $osBuild = $os.Version
        if ($ubr) { $osBuild = "$($os.Version).$ubr" }

        $system['Manufacturer'] = $cs.Manufacturer
        $system['Model']        = $cs.Model
        $system['SystemSku']    = $cs.SystemSKUNumber
        $system['BiosVersion']  = $bios.SMBIOSBIOSVersion
        $system['BiosDate']     = $bios.ReleaseDate
        $system['SerialNumber'] = $bios.SerialNumber
        $system['OsCaption']    = $os.Caption
        $system['OsBuild']      = $osBuild
    }
    ([pscustomobject]$system | ConvertTo-Json) |
        Set-Content -LiteralPath (Join-WfPath $modelPath '_system.json') -Encoding UTF8

    # Devices still unhealthy here mean a gap you are about to bake into the image.
    $bad = @()
    if (-not $Path) {
        $bad = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                 Where-Object { $_.Status -ne 'OK' -and $_.Status -ne 'Unknown' })
        foreach ($d in $bad) {
            Write-WfLog ("Unhealthy device on the reference machine: {0} [{1}] {2}" -f $d.FriendlyName, $d.Class, $d.Status) -Level WARN
        }
        if ($bad.Count -gt 0) {
            Write-WfLog 'Resolve these and re-harvest, or the image inherits the same gaps.' -Level WARN
        }
    }

    $bootRelevant = @($manifest | Where-Object { $_.ClassName -in $cfg['BootDriverClasses'] }).Count
    Write-WfLog ("{0} boot/network relevant package(s) for the PE image" -f $bootRelevant) -Level INFO

    Write-WfHistory -Action 'Driver harvest' -ImagePath $modelPath -Detail @{
        Model = $ModelName; DriverCount = $drivers.Count; BootRelevant = $bootRelevant
        Superseded = $superseded.Count; KeptAllVersions = [bool]$KeepAllVersions
        MicrosoftFound = $microsoft.Count; MicrosoftExcluded = [bool]$ExcludeMicrosoft
    } | Out-Null

    return [pscustomobject]@{
        Model             = $ModelName
        Path              = $modelPath
        DriverCount       = $drivers.Count
        Superseded        = $superseded.Count
        MicrosoftFound    = $microsoft.Count
        MicrosoftExcluded = [bool]$ExcludeMicrosoft
        BootRelevant      = $bootRelevant
        SizeBytes         = Get-WfFolderSize $modelPath
        Unhealthy         = $bad
    }
}

function Get-WfDriverLibrary {
<#
.SYNOPSIS
    Summarises the driver library: one row per model, with counts, size and age.
.DESCRIPTION
    The library at a glance, and the shape both front-ends offer as a pick list so
    a model is chosen rather than typed.

    Age is the column to read. A harvest is a photograph of one machine on one
    day; a folder that has not been refreshed in a year is shipping drivers a
    year older than the vendor's current ones, and nothing else in the toolkit
    will tell you that.
.PARAMETER DriverRoot
    Defaults to the configured driver library.
.EXAMPLE
    Get-WfDriverLibrary | Format-Table Model, InfCount, SizeMB, AgeDays
#>
    [CmdletBinding()]
    param([string] $DriverRoot)

    $cfg = Get-WfConfig
    if (-not $DriverRoot) { $DriverRoot = $cfg['DriverRoot'] }
    $DriverRoot = Assert-WfPath -Path $DriverRoot -Label 'Driver root'

    $out = New-Object System.Collections.Generic.List[object]

    foreach ($dir in Get-ChildItem -LiteralPath $DriverRoot -Directory) {
        $infs = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.inf' -Recurse -File)

        $classes = @{}
        foreach ($i in $infs) {
            $c = Get-WfInfClass $i.FullName
            if (-not $c) { $c = '(none)' }
            if ($classes.ContainsKey($c)) { $classes[$c]++ } else { $classes[$c] = 1 }
        }

        $bootCount = 0
        foreach ($c in $cfg['BootDriverClasses']) {
            if ($classes.ContainsKey($c)) { $bootCount += $classes[$c] }
        }

        $harvested = $null
        $sysFile = Join-WfPath $dir.FullName '_system.json'
        if (Test-Path -LiteralPath $sysFile) {
            try { $harvested = (Get-Content -LiteralPath $sysFile -Raw | ConvertFrom-Json).HarvestedUtc } catch { }
        }

        $ageDays = $null
        if ($harvested) {
            try { $ageDays = [math]::Round(((Get-Date) - [datetime]$harvested).TotalDays) } catch { }
        }

        $out.Add([pscustomobject]@{
            Model        = $dir.Name
            InfCount     = $infs.Count
            BootRelevant = $bootCount
            Classes      = (($classes.GetEnumerator() | Sort-Object Value -Descending |
                             ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ', ')
            SizeMB       = [math]::Round((Get-WfFolderSize $dir.FullName) / 1MB, 1)
            HarvestedUtc = $harvested
            AgeDays      = $ageDays
            Path         = $dir.FullName
        })
    }

    return $out
}

function Remove-WfModelDriver {
<#
.SYNOPSIS
    Removes a model from the driver library.
.DESCRIPTION
    Retires hardware you no longer support. The image only shrinks on the next
    servicing run -- this does not touch any existing WIM.
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $Model,
        [string] $DriverRoot
    )

    $cfg = Get-WfConfig
    if (-not $DriverRoot) { $DriverRoot = $cfg['DriverRoot'] }

    $path = Join-WfPath $DriverRoot $Model
    if (-not (Test-Path -LiteralPath $path)) { throw "Model not found in library: $Model" }

    if ($PSCmdlet.ShouldProcess($path, 'Remove model from driver library')) {
        $size = Get-WfFolderSize $path
        Remove-Item -LiteralPath $path -Recurse -Force
        Write-WfLog ("Removed {0} from the library ({1})" -f $Model, (Format-WfSize $size)) -Level OK
        Write-WfHistory -Action 'Driver model removed' -ImagePath $path -Detail @{ Model = $Model } | Out-Null
    }
}

function Add-WfDriver {
<#
.SYNOPSIS
    Injects the driver library into a mounted image.
.DESCRIPTION
    Recursive, unsigned-optional, and filtered by model and class so the same
    library can serve a full image and a boot image that has to fit in RAM.

    Every driver that goes in is reported, not just the count. A model whose
    folder was empty, or whose INFs all failed, produces the same "done" from
    DISM as a model that worked -- so the per-driver result is the only way to
    know the difference before a terminal is in a shop.
.PARAMETER Models
    Subset of model folder names. Omit to inject everything.
.PARAMETER ClassFilter
    Only inject these INF classes. Used by Add-WfBootDriver for the PE image.
.PARAMETER ForceUnsigned
    Allow unsigned / non-WHQL packages. Some POS OEM drivers need this.
.PARAMETER ExcludeMicrosoft
    Skip packages whose provider is Microsoft, without touching the library. The
    same choice Export-WfModelDriver offers at harvest time, available here for
    libraries that were harvested with everything -- and reversible, which the
    harvest-time one is not.

    The provider comes from each model's _manifest.csv, which recorded what DISM
    said at harvest. Where there is no manifest the INF is read directly.
#>
    [CmdletBinding()]
    param(
        [string]   $MountPath,
        [string]   $DriverRoot,
        [string[]] $Models,
        [string[]] $ClassFilter,
        [switch]   $ExcludeMicrosoft,
        [switch]   $ForceUnsigned
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $MountPath)  { $MountPath  = $cfg['MountPath'] }
    if (-not $DriverRoot) { $DriverRoot = $cfg['DriverRoot'] }

    $DriverRoot = Assert-WfPath -Path $DriverRoot -Label 'Driver root'

    $modelDirs = @(Get-ChildItem -LiteralPath $DriverRoot -Directory)
    if ($Models) {
        $missing = @($Models | Where-Object { $_ -notin $modelDirs.Name })
        if ($missing.Count -gt 0) {
            throw "Model folder(s) not found under ${DriverRoot}: $($missing -join ', ')"
        }
        $modelDirs = @($modelDirs | Where-Object { $_.Name -in $Models })
    }
    if ($modelDirs.Count -eq 0) { throw "No model folders found under $DriverRoot" }

    Write-WfLog ("Driver library: {0}" -f (($modelDirs.Name) -join ', ')) -Level STEP

    # What the harvest recorded, per model. Cheaper and more trustworthy than
    # re-reading every INF, since it is what DISM reported at the time.
    $providerByInf = @{}
    if ($ExcludeMicrosoft) {
        foreach ($dir in $modelDirs) {
            $csv = Join-WfPath $dir.FullName '_manifest.csv'
            if (-not (Test-Path -LiteralPath $csv)) { continue }
            try {
                foreach ($row in Import-Csv -LiteralPath $csv) {
                    if ($row.InfName) { $providerByInf[($dir.Name + '|' + $row.InfName.ToLower())] = $row.ProviderName }
                }
            }
            catch {
                Write-WfLog "Could not read $csv, so providers there come from the INFs instead: $($_.Exception.Message)" -Level WARN
            }
        }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($dir in $modelDirs) {
        foreach ($inf in Get-ChildItem -LiteralPath $dir.FullName -Filter '*.inf' -Recurse -File) {
            $provider = $null
            if ($ExcludeMicrosoft) {
                $key = $dir.Name + '|' + $inf.Name.ToLower()
                if ($providerByInf.ContainsKey($key)) { $provider = $providerByInf[$key] }
                else { $provider = Get-WfInfProvider $inf.FullName }
            }

            $candidates.Add([pscustomobject]@{
                Model    = $dir.Name
                Path     = $inf.FullName
                Name     = $inf.Name
                Class    = Get-WfInfClass $inf.FullName
                Provider = $provider
            })
        }
    }

    $selected = $candidates
    if ($ClassFilter) {
        $selected = @($candidates | Where-Object { $_.Class -in $ClassFilter })
        Write-WfLog ("Class filter {0}: {1} of {2} INFs selected" -f ($ClassFilter -join '/'), $selected.Count, $candidates.Count) -Level WARN
    }

    if ($ExcludeMicrosoft) {
        $ms = @($selected | Where-Object { Test-WfMicrosoftProvider $_.Provider })
        if ($ms.Count -gt 0) {
            foreach ($m in $ms) {
                Write-WfLog ("  skipping Microsoft-provided [{0}] {1}" -f $m.Model, $m.Name) -Level INFO
            }
            $selected = @($selected | Where-Object { -not (Test-WfMicrosoftProvider $_.Provider) })
            Write-WfLog ("{0} Microsoft-provided package(s) skipped, {1} left" -f $ms.Count, @($selected).Count) -Level WARN
        }
        else {
            Write-WfLog 'No Microsoft-provided packages in the selection.' -Level INFO
        }
    }

    if (@($selected).Count -eq 0) { throw 'No drivers selected -- nothing to inject.' }

    Write-WfLog ("Injecting {0} driver package(s)" -f @($selected).Count) -Level STEP

    $added  = 0
    $failed = New-Object System.Collections.Generic.List[object]

    foreach ($inf in $selected) {
        $params = @{ Path = $MountPath; Driver = $inf.Path }
        if ($ForceUnsigned) { $params['ForceUnsigned'] = $true }
        try {
            Add-WindowsDriver @params -ErrorAction Stop | Out-Null
            $added++
        }
        catch {
            $failed.Add([pscustomobject]@{
                Model = $inf.Model
                Inf   = $inf.Name
                Class = $inf.Class
                Error = $_.Exception.Message.Trim()
            })
        }
    }

    Write-WfLog ("Added {0}" -f $added) -Level OK
    foreach ($f in $failed) {
        Write-WfLog ("Failed: [{0}] {1} ({2}) -- {3}" -f $f.Model, $f.Inf, $f.Class, $f.Error) -Level ERROR
    }
    if ($failed.Count -gt 0) {
        Write-WfLog 'Unsigned packages need -ForceUnsigned. An architecture mismatch cannot be fixed by a flag.' -Level WARN
    }

    return [pscustomobject]@{
        Models    = @($modelDirs.Name)
        Candidate = $candidates.Count
        Selected  = @($selected).Count
        Added     = $added
        Failed    = $failed.Count
        Failures  = $failed
    }
}

function Compare-WfDriver {
<#
.SYNOPSIS
    Compares the drivers inside an image against the current driver library.
.DESCRIPTION
    Answers the question you actually have before a rollout: is the published
    image carrying the driver versions the library says it should? Anything
    reported as OlderInImage means the library has moved on and the image needs
    another servicing run.
.PARAMETER Quick
    Read the image's driver list out of its registry instead of mounting it --
    seconds rather than minutes. The comparison is the same; only the version
    numbers are less certain, because the registry stores them in an
    undocumented form that this decodes cautiously. A driver whose version could
    not be established is reported as VersionUnknown rather than guessed at.

    Falls back to mounting on its own if the registry route comes back empty.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [int]    $Index = 1,
        [string] $DriverRoot,
        [switch] $Quick
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $DriverRoot) { $DriverRoot = $cfg['DriverRoot'] }

    $ImagePath = Assert-WfPath -Path $ImagePath -Label 'Image'
    $mount     = New-WfDirectory $cfg['MountPath']

    # Library side: InfName -> newest version present
    $library = @{}
    foreach ($csv in Get-ChildItem -LiteralPath $DriverRoot -Filter '_manifest.csv' -Recurse -File) {
        $model = Split-Path (Split-Path $csv.FullName -Parent) -Leaf
        foreach ($row in Import-Csv -LiteralPath $csv.FullName) {
            $key = $row.InfName.ToLower()
            if (-not $library.ContainsKey($key)) {
                $library[$key] = [pscustomobject]@{ Inf = $row.InfName; Version = $row.Version; Models = @($model) }
            }
            else {
                $library[$key].Models += $model
                try {
                    if ([version]$row.Version -gt [version]$library[$key].Version) {
                        $library[$key].Version = $row.Version
                    }
                } catch { }
            }
        }
    }

    Write-WfLog "Comparing image against $($library.Count) library driver(s)" -Level STEP

    # The registry route first when asked for. It is only a fallback away from
    # the mount, so nothing is lost if the image predates DriverDatabase or the
    # hive will not load.
    $fromRegistry = @()
    if ($Quick) {
        $fromRegistry = @(Get-WfImageDriverPackage -ImagePath $ImagePath -Index $Index)
        if ($fromRegistry.Count -eq 0) {
            Write-WfLog 'Nothing came back from the registry, so the image will be mounted after all.' -Level WARN
        }
    }
    $useRegistry = ($fromRegistry.Count -gt 0)

    $mounted = $false
    $results = New-Object System.Collections.Generic.List[object]
    try {
        $inImage = @{}

        if ($useRegistry) {
            foreach ($d in $fromRegistry) { $inImage[$d.Driver.ToLower()] = $d }
        }
        else {
            Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $mount -ReadOnly -ErrorAction Stop | Out-Null
            $mounted = $true

            foreach ($d in Get-WindowsDriver -Path $mount | Where-Object { -not $_.Inbox }) {
                $leaf = $d.OriginalFileName
                if ($leaf) { $leaf = Split-Path $leaf -Leaf } else { $leaf = $d.Driver }
                $inImage[$leaf.ToLower()] = $d
            }
        }

        foreach ($key in $library.Keys) {
            $lib = $library[$key]
            $status = 'MissingFromImage'
            $imgVer = $null

            if ($inImage.ContainsKey($key)) {
                $imgVer = $inImage[$key].Version
                $status = 'Match'
                if (-not $imgVer) {
                    # Present, version not established. Saying so is the honest
                    # answer; calling it a match would hide a stale driver.
                    $status = 'VersionUnknown'
                }
                else {
                    try {
                        if ([version]$imgVer -lt [version]$lib.Version)     { $status = 'OlderInImage' }
                        elseif ([version]$imgVer -gt [version]$lib.Version) { $status = 'NewerInImage' }
                    }
                    catch { $status = 'VersionUnparsed' }
                }
            }

            $results.Add([pscustomobject]@{
                Inf            = $lib.Inf
                LibraryVersion = $lib.Version
                ImageVersion   = $imgVer
                Status         = $status
                Models         = ($lib.Models | Sort-Object -Unique) -join ', '
                ReadFrom       = $(if ($useRegistry) { 'registry' } else { 'mount' })
            })
        }

        # Drivers in the image that the library knows nothing about -- usually a
        # leftover from an older base capture, which is exactly what you want to
        # find before it wins a PnP ranking contest.
        foreach ($key in $inImage.Keys) {
            if (-not $library.ContainsKey($key)) {
                $results.Add([pscustomobject]@{
                    Inf            = $inImage[$key].Driver
                    LibraryVersion = $null
                    ImageVersion   = $inImage[$key].Version
                    Status         = 'NotInLibrary'
                    Models         = ''
                    ReadFrom       = $(if ($useRegistry) { 'registry' } else { 'mount' })
                })
            }
        }
    }
    finally {
        if ($mounted) {
            try {
                Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null
            }
            catch {
                Write-WfLog "Dismount failed after comparison: $($_.Exception.Message)" -Level ERROR
                Write-WfLog 'The image is still mounted. Run Repair-WfMount before the next operation.' -Level ERROR
            }
        }
    }

    $summary = $results | Group-Object Status | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
    Write-WfLog ($summary -join '  ') -Level OK

    return $results | Sort-Object Status, Inf
}
