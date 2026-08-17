# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    ReferenceImage.ps1 -- build a reference image from clean media, in the order
    Microsoft documents.

    THE PROBLEM THIS EXISTS FOR

    The other way to keep an image current is to take last month's output and add
    this month's cumulative to it. That works for years on Windows 10, and then
    stops working on Windows 11 24H2, in a way that takes a week to diagnose.

    A 24H2 cumulative is a checkpoint update: a UUP package whose payload is
    differential, stored in a .psf, and reconstructed against what is already in
    the image. When the image carries Features on Demand and language packs that
    were added from local media, that reconstruction needs a source for content
    the image can no longer reach, and the apply dies inside the Windows Update
    Agent with 0x800401E3 -- surfacing as "An error occurred applying the
    Unattend.xml file from the .msu package", which names neither the image nor
    the package nor the actual problem.

    Microsoft's answer is not a workaround. It is to build the image in a
    specific order, from clean media, every time:

        servicing stack -> languages -> features -> optional components -> LCU

    with the cumulative applied LAST, "to ensure Features on Demand, Optional
    Components, and Languages are updated from their initial release state".
    That last clause is the whole point: applied last, the cumulative brings
    everything that was just added forward with it. Applied first -- or applied
    to an image built months ago -- it cannot.

    See "Update Windows installation media with Dynamic Update" on Microsoft
    Learn, which this implements.

    WHAT IT KEYS ON

    Build family, never product name. Windows 11 24H2, Windows 11 25H2 and
    Windows Server 2025 are all the same servicing generation, and a pipeline
    that branches on "is this Windows 11" needs editing for each of them while
    one that branches on the build number does not.
#>

function Expand-WfUpdatePackage {
<#
.SYNOPSIS
    Expands a WIM-format .msu into a folder so its parts can be read.
.DESCRIPTION
    Windows 11 24H2 and later ship cumulative updates as WIM containers wearing a
    .msu extension. Inside are the update itself, its manifests, a .psf payload
    store, and -- usefully -- a standalone servicing stack cabinet.

    Get-WindowsImage and Expand-WindowsImage validate on the file EXTENSION, so a
    .msu is refused outright no matter what the bytes say. The file is copied to
    a .wim name first for that reason alone.

    Returns the folder, or $null for a cabinet-format package, which has no WIM
    to expand and needs none of this.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Destination
    )

    $check = Test-WfUpdateContainer -Path $Path -MinimumBytes 0
    if (-not $check.Ok)          { throw "Not a usable update package: $Path -- $($check.Reason)" }
    if ($check.Kind -ne 'Wim')   {
        Write-WfLog "$(Split-Path $Path -Leaf) is a cabinet package -- nothing to expand." -Level INFO
        return $null
    }

    New-WfDirectory $Destination | Out-Null
    $asWim = Join-WfPath $Destination 'package.wim'

    Write-WfLog "Expanding $(Split-Path $Path -Leaf) ($(Format-WfSize (Get-Item -LiteralPath $Path).Length))" -Level STEP
    Copy-Item -LiteralPath $Path -Destination $asWim -Force

    $out = Join-WfPath $Destination 'content'
    New-WfDirectory $out | Out-Null
    Expand-WindowsImage -ImagePath $asWim -Index 1 -ApplyPath $out -ErrorAction Stop | Out-Null

    Remove-Item -LiteralPath $asWim -Force -ErrorAction SilentlyContinue
    return $out
}

function Get-WfLcuServicingStack {
<#
.SYNOPSIS
    The servicing stack cabinet bundled inside a cumulative update, if there is one.
.DESCRIPTION
    Microsoft's sequence starts with the servicing stack, and for a modern
    cumulative that stack is already in the box -- SSU-26100.8872-x64.cab, sitting
    beside the payload. No separate download, no version to look up.

    Returns $null when the package carries no SSU, which is normal and not an
    error: the caller simply skips that step.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ExpandedPath)

    if (-not (Test-Path -LiteralPath $ExpandedPath)) { return $null }

    $ssu = @(Get-ChildItem -LiteralPath $ExpandedPath -Filter 'SSU-*.cab' -File -ErrorAction SilentlyContinue |
             Sort-Object { ConvertTo-WfNaturalKey $_.Name })
    if ($ssu.Count -eq 0) { return $null }

    # Newest, if a package ever ships more than one.
    return $ssu[-1].FullName
}

function Get-WfBuildFamily {
<#
.SYNOPSIS
    The build number of an image, and whether it is a checkpoint-servicing one.
.DESCRIPTION
    26100 and up is the generation where cumulative updates became checkpoint /
    UUP packages -- Windows 11 24H2, Windows 11 25H2 and Windows Server 2025 all
    share it. Everything about this pipeline keys on that number rather than on
    "Windows 11", so a new release in the same family needs no code change and
    Server needs no special case.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [int] $Index = 1
    )

    $build = 0
    try {
        $img = Get-WindowsImage -ImagePath $ImagePath -Index $Index -ErrorAction Stop
        $m = [regex]::Match("$($img.Version)", '^\d+\.\d+\.(\d+)')
        if ($m.Success) { $build = [int]$m.Groups[1].Value }
    }
    catch { }

    return [pscustomobject]@{
        Build      = $build
        Checkpoint = ($build -ge 26100)
        Generation = $(if ($build -ge 26100) { '26100+' } elseif ($build -ge 22000) { 'Win11' } elseif ($build -gt 0) { 'Win10' } else { 'unknown' })
    }
}

function New-WfReferenceImage {
<#
.SYNOPSIS
    Builds a reference image from clean media in Microsoft's documented order.
.DESCRIPTION
    Servicing stack, then languages, then features, then optional components, and
    the cumulative update LAST -- across winre.wim, boot.wim and install.wim.

    This is the alternative to re-servicing last month's output. Re-servicing
    accumulates state: every FOD and language pack added along the way stays at
    whatever level it was added, and eventually a cumulative arrives that cannot
    reconcile them. Building from clean media each time has no such history.

    Nothing is committed if any step fails. Every mount is discarded on the way
    out, so a failed run leaves the media exactly as it found it.
.PARAMETER MediaPath
    The extracted ISO -- the folder containing sources\install.wim.
.PARAMETER LcuPath
    The cumulative update .msu. Its servicing stack is used automatically if it
    carries one.
.PARAMETER FodSource
    The mounted Features on Demand ISO, for -Capability and -LanguagePack.
.PARAMETER Capability
    Capability names to add, as Get-WindowsCapability reports them. Read them off
    an existing image to reproduce it: Get-WindowsCapability -Path <mount> |
    Where State -eq Installed | Select -Expand Name
.PARAMETER LanguagePack
    Language pack .cab files to add before the features.
.PARAMETER Index
    Which install.wim indexes to service. Default: all of them. Server media
    carries four (Standard and Datacenter, Core and Desktop Experience), and
    servicing the wrong one is a quiet way to ship the wrong image.
.PARAMETER KeepUninstall
    Clean the component store but stop short of /ResetBase, leaving the updates
    uninstallable from the deployed OS.
.EXAMPLE
    New-WfReferenceImage -MediaPath D:\ -LcuPath C:\Updates\lcu.msu -FodSource E:\ `
                         -Capability (Get-Content .\caps.txt) -Index 1
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $MediaPath,
        [Parameter(Mandatory)] [string] $LcuPath,
        [string]   $FodSource,
        [string[]] $Capability   = @(),
        [string[]] $LanguagePack = @(),
        [int[]]    $Index,
        [string]   $OutputPath,
        [string]   $BuildRoot,
        [switch]   $SkipBootWim,
        [switch]   $SkipWinRe,
        [switch]   $SkipCleanup,
        [switch]   $KeepUninstall,
        [switch]   $SkipExport,
        [string]   $Notes
    )

    Assert-WfElevated
    $cfg = Get-WfConfig

    $MediaPath = Assert-WfPath -Path $MediaPath -Label 'Media'
    $LcuPath   = Assert-WfPath -Path $LcuPath   -Label 'Cumulative update'

    $installWim = Join-WfPath $MediaPath 'sources\install.wim'
    $bootWim    = Join-WfPath $MediaPath 'sources\boot.wim'
    if (-not (Test-Path -LiteralPath $installWim)) {
        throw "No sources\install.wim under $MediaPath. -MediaPath wants the root of the extracted ISO, not the sources folder."
    }

    # Short by design, and not negotiable.
    #
    # A serviced WinSxS path runs to about 200 characters on its own, and the
    # mount root is added to every one of them. MAX_PATH is 260. A build root of
    # C:\Users\someone\Documents\Imaging\Build\mount-install has already spent a
    # third of the budget before DISM writes a single file, and the failure lands
    # deep inside a component nobody can map back to a path length.
    if (-not $BuildRoot) { $BuildRoot = Join-WfPath (Split-Path -Qualifier $installWim) 'WfBuild' }
    if ($BuildRoot.Length -gt 24) {
        Write-WfLog "Build root $BuildRoot is $($BuildRoot.Length) characters. Mount paths under it plus a serviced WinSxS path can exceed MAX_PATH -- something like C:\WfBuild is safer." -Level WARN
    }

    $mInstall = Join-WfPath $BuildRoot 'i'
    $mWinRe   = Join-WfPath $BuildRoot 'r'
    $mBoot    = Join-WfPath $BuildRoot 'b'
    $scratch  = Join-WfPath $BuildRoot 's'
    $expanded = Join-WfPath $BuildRoot 'x'

    foreach ($d in @($BuildRoot, $mInstall, $mWinRe, $mBoot, $scratch)) { New-WfDirectory $d | Out-Null }

    $started = Get-Date
    $summary = [ordered]@{}
    $phase   = [ordered]@{}
    $script:WfRefMark = $started
    $stamp = {
        param([string] $Name)
        $now = Get-Date
        $phase[$Name] = [math]::Round(($now - $script:WfRefMark).TotalMinutes, 1)
        $script:WfRefMark = $now
    }

    $family = Get-WfBuildFamily -ImagePath $installWim -Index 1
    Write-WfLog "=== Reference image build: $(Split-Path $MediaPath -Leaf), build $($family.Build) ($($family.Generation)) ===" -Level STEP

    # The SSU rides inside the cumulative on this generation. Pulling it out is
    # what makes "servicing stack first" possible without a separate download.
    $ssu = $null
    if ($family.Checkpoint) {
        $content = Expand-WfUpdatePackage -Path $LcuPath -Destination $expanded
        if ($content) {
            $ssu = Get-WfLcuServicingStack -ExpandedPath $content
            if ($ssu) { Write-WfLog "Servicing stack found inside the update: $(Split-Path $ssu -Leaf)" -Level OK }
            else      { Write-WfLog 'The update carries no separate servicing stack -- the cumulative supplies it.' -Level INFO }
        }
    }
    & $stamp 'Expand'

    $plan = @(
        ('winre: {0}'    -f $(if ($SkipWinRe)   { 'SKIPPED' } else { 'yes' })),
        ('boot.wim: {0}' -f $(if ($SkipBootWim) { 'SKIPPED' } else { 'yes' })),
        ('languages: {0}' -f $LanguagePack.Count),
        ('capabilities: {0}' -f $Capability.Count),
        ('cleanup: {0}'  -f $(if ($SkipCleanup) { 'SKIPPED' } elseif ($KeepUninstall) { 'yes, no /ResetBase' } else { 'yes, /ResetBase' })),
        ('export: {0}'   -f $(if ($SkipExport)  { 'SKIPPED' } else { 'yes' }))
    )
    Write-WfLog ("Plan -- " + ($plan -join ',  ')) -Level INFO

    if ($Capability.Count -gt 0 -and -not $FodSource) {
        throw "$($Capability.Count) capabilities were asked for but no -FodSource was given. Capabilities come from the Features on Demand ISO; without it they cannot be added and the cumulative would then have nothing to bring forward."
    }

    # --------------------------------------------------------------- helpers
    $addPackage = {
        param([string] $MountPath, [string] $Package, [string] $What)
        Write-WfLog "  + $What" -Level INFO
        # Not Add-WindowsPackage. A UUP cumulative has to be unpacked by the
        # Windows Update Agent, and that COM activation fails in-process inside
        # PowerShell (0x800401E3) while succeeding in dism.exe's own process.
        # Add-WfPackageOffline picks per package; see its comment for the proof.
        $null = Add-WfPackageOffline -MountPath $MountPath -PackagePath $Package -ScratchDirectory $scratch
    }

    $cleanMount = {
        param([string] $MountPath)
        if ($SkipCleanup) { return }
        if ($KeepUninstall) { Invoke-WfDism @("/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup') }
        else                { Invoke-WfDism @("/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase') }
    }

    # Which indexes. Server media carries four and the wrong one ships silently.
    $allIndexes = @(Get-WindowsImage -ImagePath $installWim | ForEach-Object { [int]$_.ImageIndex })
    if (-not $Index -or $Index.Count -eq 0) { $Index = $allIndexes }
    $unknown = @($Index | Where-Object { $allIndexes -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw ("install.wim has indexes {0}; asked for {1}." -f ($allIndexes -join ', '), ($unknown -join ', '))
    }
    Write-WfLog ("Servicing install.wim index(es): {0} of {1}" -f ($Index -join ', '), ($allIndexes -join ', ')) -Level INFO

    $mounted = New-Object System.Collections.Generic.List[string]
    $summary['Indexes'] = ($Index -join ', ')

    try {
        # ------------------------------------------------------------ boot.wim
        # WinPE and Windows Setup. Neither takes languages or features -- they
        # get the servicing stack and the cumulative, nothing else.
        if (-not $SkipBootWim -and (Test-Path -LiteralPath $bootWim)) {
            foreach ($bi in @(Get-WindowsImage -ImagePath $bootWim | ForEach-Object { [int]$_.ImageIndex })) {
                Write-WfLog "boot.wim index $bi" -Level STEP
                Mount-WindowsImage -ImagePath $bootWim -Index $bi -Path $mBoot -ErrorAction Stop | Out-Null
                $mounted.Add($mBoot)

                if ($ssu) { & $addPackage $mBoot $ssu 'servicing stack' }
                & $addPackage $mBoot $LcuPath 'cumulative update'
                & $cleanMount $mBoot

                Dismount-WindowsImage -Path $mBoot -Save -ErrorAction Stop | Out-Null
                $mounted.Remove($mBoot) | Out-Null
            }
            & $stamp 'BootWim'
        }

        # -------------------------------------------------------- install.wim
        foreach ($ix in $Index) {
            Write-WfLog "install.wim index $ix" -Level STEP
            Mount-WindowsImage -ImagePath $installWim -Index $ix -Path $mInstall -ErrorAction Stop | Out-Null
            $mounted.Add($mInstall)

            # ---- winre.wim, which lives INSIDE the image being serviced.
            #
            # Serviced here rather than left alone because a customer who resets
            # the device lands on whatever build the recovery image holds. An
            # un-serviced winre.wim quietly undoes every update on first reset.
            $winreIn = Join-WfPath $mInstall 'Windows\System32\Recovery\Winre.wim'
            if (-not $SkipWinRe -and (Test-Path -LiteralPath $winreIn)) {
                Write-WfLog '  winre.wim' -Level STEP
                $winreTmp = Join-WfPath $BuildRoot 'winre.wim'
                Copy-Item -LiteralPath $winreIn -Destination $winreTmp -Force

                Mount-WindowsImage -ImagePath $winreTmp -Index 1 -Path $mWinRe -ErrorAction Stop | Out-Null
                $mounted.Add($mWinRe)
                if ($ssu) { & $addPackage $mWinRe $ssu 'servicing stack' }
                & $addPackage $mWinRe $LcuPath 'cumulative update'
                & $cleanMount $mWinRe
                Dismount-WindowsImage -Path $mWinRe -Save -ErrorAction Stop | Out-Null
                $mounted.Remove($mWinRe) | Out-Null

                # Exported before it goes back: a serviced WIM does not shrink on
                # its own, and this one is carried inside install.wim, so its
                # size is paid twice.
                $winreOut = Join-WfPath $BuildRoot 'winre-export.wim'
                Remove-Item -LiteralPath $winreOut -Force -ErrorAction SilentlyContinue
                Export-WindowsImage -SourceImagePath $winreTmp -SourceIndex 1 `
                                    -DestinationImagePath $winreOut -ErrorAction Stop | Out-Null

                Copy-Item -LiteralPath $winreOut -Destination $winreIn -Force
                Remove-Item -LiteralPath $winreTmp -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $winreOut -Force -ErrorAction SilentlyContinue
            }

            # ---- THE ORDER. This is the whole reason the function exists.
            #
            # Servicing stack, then languages, then features, then the cumulative
            # LAST -- so that everything added above is brought forward by it
            # rather than being left at the level it shipped at.
            if ($ssu) { & $addPackage $mInstall $ssu 'servicing stack' }

            foreach ($lp in $LanguagePack) {
                if (-not (Test-Path -LiteralPath $lp)) { throw "Language pack not found: $lp" }
                & $addPackage $mInstall $lp ("language pack " + (Split-Path $lp -Leaf))
            }

            foreach ($cap in $Capability) {
                if (-not $cap) { continue }
                Write-WfLog "  + capability $cap" -Level INFO
                Add-WindowsCapability -Path $mInstall -Name $cap -Source $FodSource -LimitAccess -ErrorAction Stop | Out-Null
            }

            & $addPackage $mInstall $LcuPath 'cumulative update (last, so the above is updated with it)'

            & $cleanMount $mInstall
            Dismount-WindowsImage -Path $mInstall -Save -ErrorAction Stop | Out-Null
            $mounted.Remove($mInstall) | Out-Null
        }
        & $stamp 'InstallWim'
    }
    catch {
        Write-WfLog 'Build failed -- discarding every mount so the media is left as it was.' -Level ERROR
        Write-WfLog $_.Exception.Message -Level ERROR

        # Reverse order: winre is nested inside install, and discarding the outer
        # one first would leave the inner mount orphaned.
        foreach ($m in ($mounted.ToArray() | Sort-Object -Descending)) {
            try { Dismount-WindowsImage -Path $m -Discard -ErrorAction Stop | Out-Null }
            catch { Write-WfLog "Discard failed for $m -- run Repair-WfMount." -Level ERROR }
        }
        throw
    }

    # -------------------------------------------------------------- export
    if (-not $OutputPath) {
        $OutputPath = Join-WfPath $cfg['ImageRoot'] ('{0}-{1}.wim' -f $cfg['ImageNamePrefix'], (Get-Date -Format 'yyyy-MM'))
    }
    New-WfDirectory (Split-Path $OutputPath -Parent) | Out-Null
    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue

    if ($SkipExport) {
        Copy-Item -LiteralPath $installWim -Destination $OutputPath -Force
        $summary['CopiedTo'] = $OutputPath
    }
    else {
        Write-WfLog "Exporting to $OutputPath" -Level STEP
        foreach ($ix in $Index) {
            Export-WindowsImage -SourceImagePath $installWim -SourceIndex $ix `
                                -DestinationImagePath $OutputPath -CompressionType Max -ErrorAction Stop | Out-Null
        }
        $summary['ExportedTo'] = $OutputPath
    }
    & $stamp 'Export'

    $summary['Build']           = $family.Build
    $summary['Generation']      = $family.Generation
    $summary['Languages']       = $LanguagePack.Count
    $summary['Capabilities']    = $Capability.Count
    $summary['DurationMinutes'] = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
    $summary['Phases']          = (($phase.Keys | ForEach-Object { "{0} {1}m" -f $_, $phase[$_] }) -join ', ')

    Write-WfHistory -Action 'Reference image build' -ImagePath $OutputPath -Detail $summary -Notes $Notes | Out-Null

    Write-WfLog "=== Reference image complete in $($summary['DurationMinutes']) min ===" -Level OK
    Write-WfLog ("    " + $summary['Phases']) -Level INFO

    return [pscustomobject]$summary
}
