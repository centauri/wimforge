# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Media.ps1 -- the step everybody skips, and what it costs.

    Service the images on a set of installation media -- install.wim, boot.wim,
    winre.wim -- and the media is still not finished. Windows Setup runs from
    \sources\setup.exe on the MEDIA, and hands off to the copy of Setup that is
    inside the boot image. Servicing boot.wim moves its copy forward a build; the
    one on the media stays where it was.

    Microsoft is unusually direct about the consequence:

        "For the second image, we save setup.exe and setuphost.exe for later use,
         to ensure these versions matches the \sources\setup.exe and
         \sources\setuphost.exe version from the installation media. If these
         binaries aren't identical, Windows Setup will fail during installation."

    So the last thing a media refresh does is take Setup back OUT of the serviced
    boot image and put it on the media. Two files, three lines of copying, and
    without it the whole servicing run produces media that will not install.

    setuphost.exe is new: Microsoft's script only copies it when the boot image
    is build 26100 or later -- Windows 11 24H2 and everything after. On older
    media there is no such file and looking for one is not an error.

    The boot manager files come along for the ride, and honestly: Microsoft's
    script copies them and their documentation never says why. It is done here
    because their procedure does it, not because there is a reason worth quoting.

    ORDERING. There are two orders in play and they are easy to conflate:

      inside boot.wim   servicing stack, then languages, then the cumulative
                        update LAST, then cleanup -- and only then is Setup
                        worth taking out. New-WfReferenceImage does this part.

      on the media      the Setup Dynamic Update is expanded into \sources
                        FIRST, and the copy from boot.wim comes after. That way
                        round because the Dynamic Update package can carry its
                        own setup.exe, and expanding it afterwards would put the
                        older one back.
#>

function Get-WfMediaSetupIndex {
<#
.SYNOPSIS
    Which index of a boot.wim carries Windows Setup.
.DESCRIPTION
    Conventionally index 1 is WinPE and index 2 is Windows Setup, and Microsoft's
    own media script simply tests for index 2. But that mapping is nowhere stated
    in their documentation -- it is inferred from a script -- and a custom
    boot.wim built with copype has one index which may well be the Setup one.

    So this asks the image instead of assuming: the Setup index is the one that
    actually has \sources\setup.exe in it. That costs a mount per index in the
    worst case and removes a whole class of "worked on Microsoft media, did
    nothing on ours".

    Index 2 is tried first, because on Microsoft media it is the answer and
    trying it first means one mount instead of two.
.PARAMETER BootImagePath
    The boot.wim to look inside. Mounted read-only, one index at a time.
.PARAMETER Candidate
    Only look at these indexes. Omit to consider all of them.
.OUTPUTS
    The index as an integer, or 0 when no index carries Setup -- which is the
    honest answer for a plain WinPE and not an error.
.EXAMPLE
    Get-WfMediaSetupIndex -BootImagePath C:\Media\Win11\sources\boot.wim
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BootImagePath,
        [int[]] $Candidate
    )

    $indexes = @()
    if ($Candidate) { $indexes = @($Candidate) }
    else {
        $indexes = @(Get-WindowsImage -ImagePath $BootImagePath -ErrorAction Stop |
                     ForEach-Object { [int]$_.ImageIndex })
    }

    # Index 2 first, because on Microsoft media it is the answer and trying it
    # first means one mount instead of two.
    $ordered = @($indexes | Sort-Object { if ($_ -eq 2) { 0 } else { $_ } })

    foreach ($i in $ordered) {
        $has = $false
        try {
            $has = Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $i -ReadOnly -Body {
                param($peMount)
                return (Test-Path -LiteralPath (Join-WfPath $peMount 'sources\setup.exe'))
            }
        }
        catch {
            Write-WfLog ("Could not read index {0}: {1}" -f $i, $_.Exception.Message) -Level WARN
            continue
        }

        if ($has) {
            Write-WfLog ("Index {0} carries Windows Setup." -f $i) -Level OK
            return $i
        }
        Write-WfLog ("Index {0} has no sources\setup.exe -- that is plain WinPE." -f $i) -Level INFO
    }

    return 0
}

function Update-WfMediaSetupFile {
<#
.SYNOPSIS
    Copies Setup out of a serviced boot image onto the media, which is what stops
    Setup failing at install time.
.DESCRIPTION
    The last step of a media refresh, and the one that gets left out because
    nothing about the media looks wrong without it.

    Windows Setup exists twice: once on the media at \sources\setup.exe and once
    inside boot.wim. Servicing boot.wim updates its copy and leaves the media's
    behind, and Microsoft's guidance is blunt about what that produces -- "if
    these binaries aren't identical, Windows Setup will fail during installation."

    What gets copied:

      sources\setup.exe        always
      sources\setuphost.exe    only when the boot image is build 26100 or later.
                               It does not exist before Windows 11 24H2, and its
                               absence on older media is not a problem.
      the boot manager         bootmgfw.efi over every bootmgfw.efi, bootx64.efi,
                               bootia32.efi and bootaa64.efi found anywhere on the
                               media, and bootmgr.efi over every bootmgr.efi.
                               Found by searching rather than by path, which is
                               how Microsoft's own script does it and means it
                               works on media laid out differently.

    Which index holds Setup is asked rather than assumed. Microsoft's script
    tests for index 2, but that mapping is not documented anywhere and a
    copype-built image has one index -- so this looks for the index that actually
    contains sources\setup.exe.
.PARAMETER MediaPath
    The extracted media -- the folder holding \sources.
.PARAMETER BootImagePath
    The serviced boot.wim. Defaults to <MediaPath>\sources\boot.wim, which is the
    one whose Setup the media's Setup has to match.
.PARAMETER Index
    Force a particular index instead of finding the Setup one.
.PARAMETER SetupDynamicUpdate
    The Setup Dynamic Update .cab, expanded into \sources BEFORE the copy. Passing
    it here rather than doing it separately is the point: the Dynamic Update can
    carry its own setup.exe, so expanding it AFTER this copy would silently put
    the older binary back and undo the whole step.
.PARAMETER SkipBootManager
    Copy only the Setup binaries.
.EXAMPLE
    Update-WfMediaSetupFile -MediaPath C:\Media\Win11-24H2
.EXAMPLE
    Update-WfMediaSetupFile -MediaPath C:\Media\Win11-24H2 -SetupDynamicUpdate C:\Updates\setup-du.cab
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $MediaPath,
        [string] $BootImagePath,
        [int]    $Index,
        [string] $SetupDynamicUpdate,
        [switch] $SkipBootManager
    )

    Assert-WfElevated

    $MediaPath = Assert-WfPath -Path $MediaPath -Label 'Media'
    $sources   = Join-WfPath $MediaPath 'sources'
    if (-not (Test-Path -LiteralPath $sources)) {
        throw "$MediaPath has no \sources folder, so it is not extracted installation media."
    }

    if (-not $BootImagePath) { $BootImagePath = Join-WfPath $sources 'boot.wim' }
    $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'

    # ------------------------------------------------- the Dynamic Update first
    #
    # Before the copy, deliberately. Expanding it afterwards would overwrite the
    # setup.exe that was just taken out of the serviced boot image with the one
    # from the update package, and the version mismatch this whole function
    # exists to prevent would be back.
    if ($SetupDynamicUpdate) {
        $SetupDynamicUpdate = Assert-WfPath -Path $SetupDynamicUpdate -Label 'Setup Dynamic Update'
        if ($PSCmdlet.ShouldProcess($sources, 'Expand the Setup Dynamic Update')) {
            Write-WfLog "Expanding the Setup Dynamic Update into \sources" -Level STEP
            Write-WfLog '  first, because it can carry its own setup.exe -- doing it after the copy below would put the older one back.' -Level INFO

            & expand.exe $SetupDynamicUpdate -F:* $sources | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "expand.exe failed on $SetupDynamicUpdate (exit $LASTEXITCODE)."
            }
            Write-WfLog '  expanded' -Level OK
        }
    }

    # ------------------------------------------------------------- which index
    if (-not $Index) {
        Write-WfLog 'Finding the index that carries Windows Setup' -Level STEP
        $Index = Get-WfMediaSetupIndex -BootImagePath $BootImagePath
        if (-not $Index) {
            throw ("No index of {0} contains sources\setup.exe, so there is no Setup to copy out of it. " +
                   "That is a plain WinPE rather than installation media boot.wim -- point -BootImagePath at the media's own boot.wim." -f $BootImagePath)
        }
    }

    # ------------------------------------------------------- what is in there
    $imageVersion = $null
    try {
        $info = @(Get-WindowsImage -ImagePath $BootImagePath -Index $Index -ErrorAction Stop)[0]
        $imageVersion = [System.Version]"$($info.Version)"
        Write-WfLog ("Boot image index {0} is version {1}" -f $Index, $imageVersion) -Level INFO
    }
    catch {
        Write-WfLog "Could not read the boot image version, so setuphost.exe is looked for rather than predicted: $($_.Exception.Message)" -Level WARN
    }

    # setuphost.exe arrived with Windows 11 24H2. Microsoft's script gates it on
    # exactly this comparison.
    $wantSetupHost = $true
    if ($imageVersion) {
        $wantSetupHost = ($imageVersion -ge [System.Version]'10.0.26100')
        if (-not $wantSetupHost) {
            Write-WfLog ("Version {0} is before 10.0.26100, so there is no setuphost.exe to copy. That is correct, not a failure." -f $imageVersion) -Level INFO
        }
    }

    if (-not $PSCmdlet.ShouldProcess($MediaPath, 'Refresh the Setup binaries from the boot image')) { return }

    # ----------------------------------------------------- out of the boot image
    $stage = Join-WfPath ((Get-WfConfig)['ScratchPath']) ('media-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-WfDirectory $stage | Out-Null

    $taken = @()
    try {
        $taken = Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -ReadOnly -Body {
            param($peMount)

            $got = New-Object System.Collections.Generic.List[object]

            $wanted = @(
                @{ From = 'sources\setup.exe';                 To = 'setup.exe';     Required = $true }
                @{ From = 'sources\setuphost.exe';             To = 'setuphost.exe'; Required = $false }
                @{ From = 'Windows\boot\efi\bootmgfw.efi';     To = 'bootmgfw.efi';  Required = $false }
                @{ From = 'Windows\boot\efi\bootmgr.efi';      To = 'bootmgr.efi';   Required = $false }
            )

            foreach ($w in $wanted) {
                if ($w.To -eq 'setuphost.exe' -and -not $wantSetupHost) { continue }
                if ($w.To -like 'boot*' -and $SkipBootManager) { continue }

                $src = Join-WfPath $peMount $w.From
                if (-not (Test-Path -LiteralPath $src)) {
                    if ($w.Required) {
                        throw ("{0} is not in this boot image, so the media's Setup cannot be matched to it." -f $w.From)
                    }
                    Write-WfLog ("  not in this image: {0}" -f $w.From) -Level INFO
                    continue
                }

                Copy-Item -LiteralPath $src -Destination (Join-WfPath $stage $w.To) -Force
                $got.Add([pscustomobject]@{ Name = $w.To; Bytes = (Get-Item -LiteralPath $src).Length })
                Write-WfLog ("  took {0}" -f $w.To) -Level OK
            }

            return $got.ToArray()
        }

        # -------------------------------------------------------- onto the media
        $written = New-Object System.Collections.Generic.List[object]

        foreach ($leaf in @('setup.exe', 'setuphost.exe')) {
            $from = Join-WfPath $stage $leaf
            if (-not (Test-Path -LiteralPath $from)) { continue }

            $to = Join-WfPath $sources $leaf

            # Reported rather than silently overwritten. On a run that has already
            # been done once, "same version" is the expected answer and seeing it
            # is how you know this step is not quietly doing nothing.
            $wasVersion = ''
            if (Test-Path -LiteralPath $to) {
                try { $wasVersion = (Get-Item -LiteralPath $to).VersionInfo.FileVersion } catch { }
            }
            $newVersion = ''
            try { $newVersion = (Get-Item -LiteralPath $from).VersionInfo.FileVersion } catch { }

            Copy-Item -LiteralPath $from -Destination $to -Force
            $written.Add([pscustomobject]@{ File = "sources\$leaf"; Was = $wasVersion; Now = $newVersion })

            if ($wasVersion -and $newVersion -and $wasVersion -eq $newVersion) {
                Write-WfLog ("sources\{0} was already at {1} -- copied anyway, nothing changed." -f $leaf, $newVersion) -Level INFO
            }
            else {
                Write-WfLog ("sources\{0}: {1} -> {2}" -f $leaf, $(if ($wasVersion) { $wasVersion } else { 'unknown' }), `
                             $(if ($newVersion) { $newVersion } else { 'unknown' })) -Level OK
            }
        }

        # ------------------------------------------------------ the boot manager
        #
        # Searched for, not addressed by path. Microsoft's script walks the media
        # for b*.efi and overwrites by FILE NAME -- bootmgfw.efi goes over all four
        # of the names the firmware might look for. Media laid out differently
        # still gets serviced, and nothing is written to a path that does not
        # already hold a boot manager.
        $bootFiles = @()
        if (-not $SkipBootManager) {
            $fw  = Join-WfPath $stage 'bootmgfw.efi'
            $mgr = Join-WfPath $stage 'bootmgr.efi'

            foreach ($f in @(Get-ChildItem -LiteralPath $MediaPath -Force -Recurse -Filter 'b*.efi' -ErrorAction SilentlyContinue)) {
                $n = $f.Name.ToLowerInvariant()

                if (@('bootmgfw.efi', 'bootx64.efi', 'bootia32.efi', 'bootaa64.efi') -contains $n) {
                    if (Test-Path -LiteralPath $fw) {
                        Copy-Item -LiteralPath $fw -Destination $f.FullName -Force
                        $bootFiles += $f.FullName.Substring($MediaPath.Length).TrimStart('\')
                    }
                }
                elseif ($n -eq 'bootmgr.efi') {
                    if (Test-Path -LiteralPath $mgr) {
                        Copy-Item -LiteralPath $mgr -Destination $f.FullName -Force
                        $bootFiles += $f.FullName.Substring($MediaPath.Length).TrimStart('\')
                    }
                }
            }

            if ($bootFiles.Count -gt 0) {
                Write-WfLog ("Boot manager refreshed in {0} place(s): {1}" -f $bootFiles.Count, ($bootFiles -join ', ')) -Level OK
            }
            else {
                Write-WfLog 'No boot manager files found on this media to refresh.' -Level INFO
            }
        }

        Write-WfLog 'The media Setup now matches the boot image Setup.' -Level OK

        Write-WfHistory -Action 'Media Setup refresh' -ImagePath $MediaPath -Detail @{
            BootImage = $BootImagePath; Index = $Index
            Version = "$imageVersion"
            Files = (@($written | ForEach-Object { $_.File }) -join ', ')
            BootManager = $bootFiles.Count
            DynamicUpdate = $SetupDynamicUpdate
        } | Out-Null

        return [pscustomobject]@{
            MediaPath   = $MediaPath
            BootImage   = $BootImagePath
            Index       = $Index
            Version     = "$imageVersion"
            Taken       = $taken
            Written     = $written.ToArray()
            BootManager = $bootFiles
        }
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
