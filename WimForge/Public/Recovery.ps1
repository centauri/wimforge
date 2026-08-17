# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Recovery.ps1 -- getting a terminal back to the image it shipped with.

    Read this before using any of it, because the obvious approach does not work.

    THE THING THAT DOES NOT WORK

    `reagentc /setosimage` is the command that registers a custom OS image for
    push-button reset. It is documented, it still exists, and Microsoft's own
    reference for it says:

        "Note: This setting isn't used in Windows 10 or later."

    So on every SKU this toolkit targets, pointing Reset-this-PC at a WIM you
    built is not a supported operation. It will not fail loudly; it simply is not
    the mechanism any more.

    WHAT REPLACED IT

    Push-button reset on Windows 10 and 11 rebuilds Windows from the files
    already on the machine, then re-applies whatever it finds in two places:

        \Recovery\OEM\ResetConfig.xml   scripts to run at four defined points
        \Recovery\Customizations\*.ppkg provisioning packages to re-apply

    Both are plain files in the image, which means -- unlike the rest of the
    push-button reset documentation, which describes doing this on a running
    machine -- they can be put there offline, at build time. That is what
    Set-WfResetConfig and Add-WfResetCustomization do. It gets you "reset comes
    back with our applications and our settings", which is most of what a factory
    image is wanted for.

    WHAT ACTUALLY GIVES YOU THE WIM BACK

    If you want the literal thing -- the WIM on a partition, an entry in the boot
    menu, and a terminal that can be put back to the exact image it left the
    workshop with -- that is not a push-button reset feature at all. It is a
    WinPE boot entry: a ramdisk osloader entry in the BCD pointing at a boot.wim,
    which is a long-standing and supported BCD capability.

    Two functions build it:

        New-WfRecoveryBootImage  prepares the WinPE that does the applying
        New-WfRecoveryFirstBoot  stages the payload and adds the boot entry

    The second one runs on the terminal, not here, for a reason that cannot be
    worked around: partitions and a BCD store do not exist in an offline image.
    So it goes through the same first-boot seam the lockdown configuration uses.

    A WARNING WORTH READING TWICE

    The recovery payload cannot live on the volume it restores. A restore that
    formats C: and then applies the WIM destroys the WIM it is applying halfway
    through, and the terminal is left with no operating system and no way back.
    New-WfRecoveryFirstBoot refuses the system volume outright. A stock Windows
    recovery partition is ~500MB-1GB and will not hold a POS image either, so
    this needs a partition sized for it, made when the disk is laid out.
#>

function Get-WfRecoveryStatus {
<#
.SYNOPSIS
    What the recovery environment on a machine or an image is set to.
.DESCRIPTION
    Runs reagentc /info and parses it. Worth doing before anything else here:
    the two most common surprises are WinRE being disabled outright (which
    happens whenever a servicing run replaces winre.wim without re-registering
    it) and the recovery location pointing at a partition that no longer exists.

    Against an offline image, pass -MountPath and it queries that image's
    configuration rather than this machine's.
.PARAMETER MountPath
    The mounted image. Defaults to the configured mount point, like everything
    else here.
.PARAMETER Online
    Ask about the running machine instead of an image.
.EXAMPLE
    Get-WfRecoveryStatus
.EXAMPLE
    Get-WfRecoveryStatus -Online
#>
    [CmdletBinding()]
    param(
        [string] $MountPath,
        [switch] $Online
    )

    Assert-WfElevated
    if (-not $Online -and -not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    # Not $args: that is an automatic variable, and reusing it here is the kind
    # of thing that works until somebody adds a splat to this function.
    $reArgs = @('/info')
    $what   = 'this machine'
    if (-not $Online) {
        $windows = Join-WfPath $MountPath 'Windows'
        $reArgs += @('/target', $windows)
        $what    = $MountPath
    }

    Write-WfLog "Reading the recovery configuration of $what" -Level STEP

    $output = & reagentc.exe @reArgs 2>&1
    $code   = $LASTEXITCODE
    $text   = (@($output | ForEach-Object { "$_" }) -join "`n")

    foreach ($line in ($text -split "`n")) {
        $t = $line.Trim()
        if ($t) { Write-WfLog $t -Level INFO -NoConsole }
    }

    if ($code -ne 0) {
        # Not a throw. reagentc returns non-zero for "there is no configuration
        # here", which is a perfectly good answer to the question being asked.
        Write-WfLog "reagentc exited $code -- treating that as 'nothing configured'." -Level WARN
    }

    $get = {
        param([string[]] $Label)
        foreach ($l in $Label) {
            $m = [regex]::Match($text, '(?im)^\s*' + [regex]::Escape($l) + '\s*:\s*(.+?)\s*$')
            if ($m.Success) { return $m.Groups[1].Value.Trim() }
        }
        return ''
    }

    # reagentc's labels differ between builds and localisations, so each one is
    # asked for under every spelling it is known by rather than the one this
    # machine happens to use.
    $status   = & $get @('Windows RE status', 'Windows RE-status')
    $location = & $get @('Windows RE location')
    $reimage  = & $get @('Recovery image location')
    $reIndex  = & $get @('Recovery image index')
    $custom   = & $get @('Custom image location')
    $bcd      = & $get @('BCD identifier', 'Boot Configuration Data (BCD) identifier')

    $enabled = ($status -match '(?i)^enabled')

    if ($enabled) { Write-WfLog "WinRE is enabled, at $location" -Level OK }
    else {
        Write-WfLog "WinRE is not enabled here." -Level WARN
        Write-WfLog 'A servicing run that replaced winre.wim without re-registering it is the usual cause. Set-WfRecoveryImage puts it back.' -Level INFO
    }

    if ($custom) {
        Write-WfLog "A custom recovery image is registered at $custom -- note that /setosimage is not used in Windows 10 or later, so this may be inherited and inert." -Level WARN
    }

    return [pscustomobject]@{
        Target            = $what
        Enabled           = $enabled
        Status            = $status
        WinReLocation     = $location
        RecoveryImagePath = $reimage
        RecoveryImageIndex= $reIndex
        CustomImagePath   = $custom
        BcdIdentifier     = $bcd
        ExitCode          = $code
        Raw               = $text
    }
}

function Set-WfRecoveryImage {
<#
.SYNOPSIS
    Registers a winre.wim so the machine knows where its recovery environment is.
.DESCRIPTION
    reagentc /setreimage. This is the one recovery registration that IS supported
    on Windows 10 and 11, and it is the counterpart to Add-WfRecoveryDriver: once
    you have serviced winre.wim -- added a storage or network driver so recovery
    can actually see the disk it is meant to repair -- the machine still has to
    be told where the serviced copy is.

    Offline, pass -MountPath and it targets that image's Windows directory.

    This is NOT the command for pointing reset at a custom OS image. That is
    /setosimage, and it is documented as not used in Windows 10 or later. See the
    notes at the top of this file for what to do instead.
.PARAMETER Path
    The folder holding winre.wim, as the TARGET machine will see it -- typically
    something like R:\Recovery\WindowsRE. The file itself must be named
    winre.wim and must be in that folder.
.PARAMETER MountPath
    The mounted image. Defaults to the configured mount point.
.PARAMETER Online
    Configure the running machine instead of an image.
.EXAMPLE
    Set-WfRecoveryImage -Path 'R:\Recovery\WindowsRE'
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $MountPath,
        [switch] $Online
    )

    Assert-WfElevated
    if (-not $Online -and -not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $reArgs = @('/setreimage', '/path', $Path)
    $what   = 'this machine'
    if (-not $Online) {
        $windows = Join-WfPath $MountPath 'Windows'
        if (-not (Test-Path -LiteralPath $windows)) {
            throw "No Windows directory at $windows -- is $MountPath really a mounted image?"
        }
        $reArgs += @('/target', $windows)
        $what    = $MountPath
    }

    # The path is on the target machine, so it usually does not exist here and
    # cannot be checked. What CAN be checked is the shape of it: reagentc takes
    # a folder, and a folder ending in winre.wim is the mistake people make.
    if ($Path -match '\.wim$') {
        # Trimmed by hand rather than with Split-Path: this is a path on the
        # TARGET machine, and Split-Path resolves against the separator rules of
        # the host it runs on -- which quietly returns nothing when the two
        # disagree, turning a helpful message into a blank one.
        $folder = $Path -replace '[\\/][^\\/]+$', ''
        throw "-Path takes the FOLDER containing winre.wim, not the file itself. Try '$folder'."
    }

    if (-not $PSCmdlet.ShouldProcess($what, "Register the recovery image at $Path")) { return }

    Write-WfLog "Registering the recovery image at $Path" -Level STEP
    $output = & reagentc.exe @reArgs 2>&1
    $code   = $LASTEXITCODE
    $text   = (@($output | ForEach-Object { "$_" }) -join "`n")

    foreach ($line in ($text -split "`n")) {
        $t = $line.Trim()
        if ($t) { Write-WfLog $t -Level INFO -NoConsole }
    }

    if ($code -ne 0) {
        throw ("reagentc /setreimage failed (exit {0}). {1}" -f $code, $text.Trim())
    }

    Write-WfLog 'Registered.' -Level OK

    Write-WfHistory -Action 'Register recovery image' -ImagePath $what -Detail @{
        Path = $Path
    } | Out-Null

    return [pscustomobject]@{
        Target = $what
        Path   = $Path
        Result = 'Registered'
        Raw    = $text
    }
}

function Set-WfResetConfig {
<#
.SYNOPSIS
    Writes ResetConfig.xml into an image, so push-button reset runs your scripts.
.DESCRIPTION
    Push-button reset on Windows 10 and 11 has four extensibility points, and a
    ResetConfig.xml in \Recovery\OEM names a script for each. This is the part of
    push-button reset that still works the way the documentation says, and unlike
    the rest of the deployment guide -- which describes doing all of this on a
    running machine -- these are plain files, so they can be put in offline.

    The four phases, and what each is for:

      BasicReset_BeforeImageApply   before "Reset this PC, keep my files" starts
      BasicReset_AfterImageApply    after it, before the machine comes back
      FactoryReset_AfterDiskFormat  after "remove everything" wipes the disk
      FactoryReset_AfterImageApply  after that, before first boot

    The one that matters for a POS estate is FactoryReset_AfterImageApply: it is
    where a script that re-joins the domain, re-installs the till application or
    re-applies a provisioning package goes.

    Each script gets a Duration, which is only an estimate for the progress bar.
    It does not limit anything -- a script that hangs still hangs the reset.
.PARAMETER Script
    Ordered hashtables of @{ Phase = '...'; Path = 'Fabrikam\Thing.cmd'; Duration = 2 }.
    Path is relative to \Recovery\OEM, which is where the script must also be
    copied -- use -ScriptSource for that.
.PARAMETER ScriptSource
    A folder whose contents are copied into \Recovery\OEM. The Path values above
    are relative to it.
.PARAMETER MountPath
    The mounted image.
.EXAMPLE
    Set-WfResetConfig -ScriptSource D:\Imaging\ResetScripts -Script @(
        @{ Phase = 'FactoryReset_AfterImageApply'; Path = 'Centric\Provision.cmd'; Duration = 5 })
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object[]] $Script,
        [string] $ScriptSource,
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $valid = @('BasicReset_BeforeImageApply', 'BasicReset_AfterImageApply',
               'FactoryReset_AfterDiskFormat', 'FactoryReset_AfterImageApply')

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($Script | Where-Object { $_ })) {
        $phase = "$($s['Phase'])"
        $path  = "$($s['Path'])"
        $mins  = 2
        if ($s['Duration']) { [void][int]::TryParse("$($s['Duration'])", [ref]$mins) }

        if ($phase -notin $valid) {
            throw ("'{0}' is not a push-button reset phase. The four are: {1}" -f $phase, ($valid -join ', '))
        }
        if (-not $path) { throw "Every script needs a Path, relative to \Recovery\OEM." }
        if ([System.IO.Path]::IsPathRooted($path)) {
            throw "Path must be relative to \Recovery\OEM, not absolute: $path"
        }

        $entries.Add([pscustomobject]@{ Phase = $phase; Path = $path; Duration = $mins })
    }

    if ($entries.Count -eq 0) { throw 'No scripts given, so there is nothing to configure.' }

    $oemDir = Join-WfPath $MountPath 'Recovery\OEM'
    $xmlPath= Join-WfPath $oemDir 'ResetConfig.xml'

    if (-not $PSCmdlet.ShouldProcess($xmlPath, ("Write ResetConfig.xml with {0} script(s)" -f $entries.Count))) { return }

    New-WfDirectory $oemDir | Out-Null

    if ($ScriptSource) {
        $src = Assert-WfPath -Path $ScriptSource -Label 'Script source folder'
        Write-WfLog "Copying reset scripts from $src" -Level STEP
        Copy-Item -Path (Join-Path $src '*') -Destination $oemDir -Recurse -Force
    }

    # Every named script has to actually be there. A ResetConfig.xml pointing at
    # a file that was never copied is accepted without complaint, and the miss
    # only shows up during a reset -- which is the worst possible time to find out.
    $missing = @()
    foreach ($e in $entries) {
        $full = Join-WfPath $oemDir $e.Path
        if (-not (Test-Path -LiteralPath $full)) { $missing += $e.Path }
    }
    if ($missing.Count -gt 0) {
        throw ("These scripts are named in the configuration but are not in \Recovery\OEM: {0}. Copy them in with -ScriptSource, or correct the paths." -f ($missing -join ', '))
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $lines.Add('<Reset>')
    foreach ($e in $entries) {
        $lines.Add(('    <Run Phase="{0}">' -f $e.Phase))
        $lines.Add(('        <Path>{0}</Path>' -f [System.Security.SecurityElement]::Escape($e.Path)))
        $lines.Add(('        <Duration>{0}</Duration>' -f $e.Duration))
        $lines.Add('    </Run>')
    }
    $lines.Add('</Reset>')

    # UTF-8 without a BOM, explicitly. The documentation is unusually direct
    # about this -- "Do not use Unicode or ANSI" -- and PowerShell 5.1's -Encoding
    # UTF8 writes a BOM, which is exactly the thing being warned against.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($xmlPath, (($lines -join "`r`n") + "`r`n"), $utf8)

    Write-WfLog ("ResetConfig.xml written with {0} script(s)" -f $entries.Count) -Level OK
    Write-WfLog 'This runs during Reset this PC. It does not restore a WIM -- reset rebuilds Windows from the machine, then runs these.' -Level INFO

    Write-WfHistory -Action 'Reset configuration' -ImagePath $MountPath -Detail @{
        Scripts = $entries.Count
        Phases  = @($entries | ForEach-Object { $_.Phase }) -join ', '
    } | Out-Null

    return [pscustomobject]@{
        Path    = $xmlPath
        Scripts = $entries.ToArray()
    }
}

function Add-WfResetCustomization {
<#
.SYNOPSIS
    Puts provisioning packages where push-button reset will re-apply them.
.DESCRIPTION
    \Recovery\Customizations is the folder reset looks in. Anything in there is
    re-applied after Windows has been rebuilt, which is how applications and
    settings survive a reset that has otherwise thrown the machine back to a
    clean Windows.

    This is the modern answer to "reset should bring back OUR image". It does not
    literally restore a WIM -- nothing on Windows 10 or later does, see the notes
    at the top of this file -- but a provisioning package that installs the till
    application and applies the settings gets to the same place from the other
    direction.
.PARAMETER Package
    One or more .ppkg files to copy in.
.PARAMETER MountPath
    The mounted image.
.EXAMPLE
    Add-WfResetCustomization -Package D:\Imaging\Ppkg\TillApps.ppkg
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string[]] $Package,
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Package | Where-Object { $_ })) {
        $resolved = Assert-WfPath -Path $p -Label 'Provisioning package'
        if ($resolved -notmatch '\.ppkg$') {
            throw "Only .ppkg files belong in \Recovery\Customizations -- $resolved is not one."
        }
        $files.Add((Get-Item -LiteralPath $resolved))
    }

    $dest = Join-WfPath $MountPath 'Recovery\Customizations'

    if (-not $PSCmdlet.ShouldProcess($dest, ("Copy in {0} provisioning package(s)" -f $files.Count))) { return }

    New-WfDirectory $dest | Out-Null

    $copied = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-WfPath $dest $f.Name) -Force
        Write-WfLog ("  {0} ({1})" -f $f.Name, (Format-WfSize $f.Length)) -Level OK
        $copied.Add([pscustomobject]@{ Name = $f.Name; Size = (Format-WfSize $f.Length) })
    }

    Write-WfLog ("{0} package(s) in \Recovery\Customizations" -f $copied.Count) -Level OK

    Write-WfHistory -Action 'Reset customizations' -ImagePath $MountPath -Detail @{
        Packages = $copied.Count
    } | Out-Null

    return $copied.ToArray()
}

function New-WfRecoveryBootImage {
<#
.SYNOPSIS
    Prepares the WinPE that puts the factory image back.
.DESCRIPTION
    Takes a WinPE boot.wim and makes it into a recovery environment: it mounts
    it, writes a startnet.cmd that finds the recovery payload and offers to apply
    it, and dismounts. The result is a boot.wim that, when booted, does something
    useful without anybody typing dism commands from memory at a shop counter.

    Where the boot.wim comes from: the Windows ADK's WinPE add-on
    (Windows Preinstallation Environment\amd64\en-us\winpe.wim), or the boot.wim
    from Windows installation media. Either works; the ADK one is smaller.

    Add storage and network drivers to it FIRST, with Add-WfBootDriver. A
    recovery environment that cannot see the disk it is meant to restore is a
    recovery environment that does nothing, and it is the single most common way
    this ends up not working on a hardware model nobody tested it on.

    The generated startnet.cmd is deliberately not silent. It shows what it found
    and asks once before formatting anything -- this boots from the boot menu of
    a machine somebody is standing in front of, not from a first-boot script, so
    there is a person to ask and the cost of not asking is a wiped till.
.PARAMETER BootImage
    The WinPE boot.wim to prepare. Modified in place, so work on a copy.
.PARAMETER PayloadFolder
    Where the recovery payload sits on the recovery partition, as WinPE will see
    it. The generated script searches every volume for this folder, because drive
    letters in WinPE are not the letters Windows uses.
.PARAMETER ImageFile
    File name of the factory image inside that folder.
.PARAMETER ApplyIndex
    Which index of it to apply.
.PARAMETER TargetLabel
    Volume label of the partition to restore ONTO. Matched by label rather than
    letter for the same reason as above. The generated script will not touch a
    volume whose label does not match.
.PARAMETER Unattended
    Skip the confirmation prompt and restore as soon as it boots. Do not use this
    on a machine that boots the entry by accident.
.PARAMETER MountPath
    Scratch mount point for the boot image. Defaults to the configured one with
    '-Pe' appended, so it never collides with an install image mount.
.EXAMPLE
    New-WfRecoveryBootImage -BootImage C:\Imaging\Pe\boot.wim -ImageFile Plus-POS.wim -TargetLabel OSDisk
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $BootImage,
        [string] $PayloadFolder = 'Recovery\WimForge',
        [Parameter(Mandatory)] [string] $ImageFile,
        [int]    $ApplyIndex = 1,
        [Parameter(Mandatory)] [string] $TargetLabel,
        [switch] $Unattended,
        [string] $MountPath
    )

    Assert-WfElevated

    $wim = Assert-WfPath -Path $BootImage -Label 'WinPE boot image'
    if (-not $MountPath) { $MountPath = ((Get-WfConfig)['MountPath']) + '-Pe' }

    if (-not $PSCmdlet.ShouldProcess($wim, 'Turn this WinPE into a recovery environment')) { return }

    $cmd = New-Object System.Collections.Generic.List[string]
    $cmd.Add('@echo off')
    $cmd.Add('rem WimForge recovery environment. Generated -- edit the image, not this.')
    $cmd.Add('wpeinit')
    $cmd.Add('cls')
    $cmd.Add('echo.')
    $cmd.Add('echo   WimForge recovery')
    $cmd.Add('echo   =================')
    $cmd.Add('echo.')
    # WinPE ships PowerShell only if the optional component was added, and a
    # recovery environment that depends on an optional component is a recovery
    # environment that fails on the one boot.wim nobody added it to. So this is
    # batch and diskpart the whole way down.
    $cmd.Add('set WF_SRC=')
    $cmd.Add('set WF_DST=')
    $cmd.Add('for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (')
    $cmd.Add(('    if exist %%d:\{0}\{1} set WF_SRC=%%d:\{0}' -f $PayloadFolder, $ImageFile))
    $cmd.Add(')')
    $cmd.Add('if "%WF_SRC%"=="" (')
    $cmd.Add(('    echo   The recovery payload was not found on any volume.'))
    $cmd.Add(('    echo   Looking for \{0}\{1}' -f $PayloadFolder, $ImageFile))
    $cmd.Add('    echo.')
    $cmd.Add('    echo   Nothing has been changed. Type exit to restart.')
    $cmd.Add('    cmd /k')
    $cmd.Add('    exit /b 1')
    $cmd.Add(')')
    $cmd.Add('echo   Found the image at %WF_SRC%')
    $cmd.Add('')
    # The destination is found by label. A recovery script that assumes C: is
    # the Windows volume is a recovery script that formats the wrong partition
    # the first time it meets a machine with a different disk layout -- in WinPE
    # the letters are assigned in a different order than Windows uses.
    $cmd.Add('for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (')
    $cmd.Add(('    vol %%d: 2>nul | find /i "{0}" >nul && set WF_DST=%%d:' -f $TargetLabel))
    $cmd.Add(')')
    $cmd.Add('if "%WF_DST%"=="" (')
    $cmd.Add(('    echo   No volume is labelled {0}, so there is nothing safe to restore onto.' -f $TargetLabel))
    $cmd.Add('    echo   Nothing has been changed. Type exit to restart.')
    $cmd.Add('    cmd /k')
    $cmd.Add('    exit /b 1')
    $cmd.Add(')')
    $cmd.Add('echo   Restoring onto %WF_DST%')
    $cmd.Add('echo.')

    if (-not $Unattended) {
        $cmd.Add('echo   Everything on %WF_DST% will be replaced by the factory image.')
        $cmd.Add('echo   Anything on it that has not been backed up is gone.')
        $cmd.Add('echo.')
        $cmd.Add('set /p WF_OK=  Type RESTORE to go ahead, anything else to cancel: ')
        $cmd.Add('if /i not "%WF_OK%"=="RESTORE" (')
        $cmd.Add('    echo.')
        $cmd.Add('    echo   Cancelled. Nothing has been changed. Type exit to restart.')
        $cmd.Add('    cmd /k')
        $cmd.Add('    exit /b 0')
        $cmd.Add(')')
    }
    else {
        $cmd.Add('echo   Unattended restore -- starting in 10 seconds. Ctrl-C stops it.')
        $cmd.Add('ping -n 11 127.0.0.1 >nul')
    }

    $cmd.Add('')
    $cmd.Add('echo   Formatting %WF_DST%')
    $cmd.Add(('format %WF_DST% /FS:NTFS /Q /V:{0} /Y' -f $TargetLabel))
    $cmd.Add('if errorlevel 1 goto :failed')
    $cmd.Add('')
    $cmd.Add('echo   Applying the image. This takes several minutes.')
    $cmd.Add(('dism /Apply-Image /ImageFile:"%WF_SRC%\{0}" /Index:{1} /ApplyDir:%WF_DST%\' -f $ImageFile, $ApplyIndex))
    $cmd.Add('if errorlevel 1 goto :failed')
    $cmd.Add('')
    # bcdboot last, and against the restored volume: the boot files have to point
    # at the Windows that was just laid down, not the one that was there before.
    $cmd.Add('echo   Writing the boot files')
    $cmd.Add('bcdboot %WF_DST%\Windows')
    $cmd.Add('if errorlevel 1 goto :failed')
    $cmd.Add('')
    $cmd.Add('echo.')
    $cmd.Add('echo   Done. Restarting in 15 seconds.')
    $cmd.Add('ping -n 16 127.0.0.1 >nul')
    $cmd.Add('wpeutil reboot')
    $cmd.Add('exit /b 0')
    $cmd.Add('')
    $cmd.Add(':failed')
    $cmd.Add('echo.')
    $cmd.Add('echo   The restore failed. The machine is NOT bootable in this state.')
    $cmd.Add('echo   Leave it on and get somebody who can read the messages above.')
    $cmd.Add('cmd /k')

    Write-WfLog "Mounting the WinPE image at $MountPath" -Level STEP
    New-WfDirectory $MountPath | Out-Null
    Mount-WindowsImage -ImagePath $wim -Index 1 -Path $MountPath -ErrorAction Stop | Out-Null

    try {
        $startnet = Join-WfPath $MountPath 'Windows\System32\startnet.cmd'
        Set-Content -LiteralPath $startnet -Value $cmd -Encoding Ascii -Force
        Write-WfLog ("startnet.cmd written, {0} line(s)" -f $cmd.Count) -Level OK

        Dismount-WindowsImage -Path $MountPath -Save -ErrorAction Stop | Out-Null
        Write-WfLog 'WinPE image saved.' -Level OK
    }
    catch {
        Write-WfLog "Failed, discarding the WinPE mount: $($_.Exception.Message)" -Level ERROR
        Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction SilentlyContinue | Out-Null
        throw
    }

    if ($Unattended) {
        Write-WfLog 'This WinPE restores without asking. Anything that boots that entry by accident loses the till.' -Level WARN
    }
    Write-WfLog 'Add storage and network drivers with Add-WfBootDriver if you have not -- recovery that cannot see the disk does nothing.' -Level INFO

    Write-WfHistory -Action 'Recovery WinPE' -ImagePath $wim -Detail @{
        ImageFile = $ImageFile; Index = $ApplyIndex; TargetLabel = $TargetLabel
        Unattended = [bool]$Unattended
    } | Out-Null

    return [pscustomobject]@{
        BootImage   = $wim
        ImageFile   = $ImageFile
        ApplyIndex  = $ApplyIndex
        TargetLabel = $TargetLabel
        Unattended  = [bool]$Unattended
        Lines       = $cmd.Count
    }
}

function New-WfRecoveryFirstBoot {
<#
.SYNOPSIS
    Generates the first-boot script that puts the recovery payload on a partition
    and adds a boot menu entry for it.
.DESCRIPTION
    This is the part that cannot be done offline. An image has no partitions and
    no BCD store, so staging the payload and creating the boot entry has to
    happen on the terminal, once, at first boot -- the same seam the lockdown
    configuration uses.

    What the generated script does, on the terminal:

      1. finds the recovery partition by volume label and gives it a letter
      2. finds the deployment source (the USB stick, or a folder you name)
      3. copies boot.wim, boot.sdi and the factory WIM onto the partition
      4. creates a ramdisk osloader entry in the BCD pointing at boot.wim
      5. adds it to the boot menu, last, so it is never the default

    Step 4 is the interesting one. A ramdisk entry needs the right winload for
    the firmware -- winload.efi on UEFI, winload.exe on BIOS -- and the right
    path inside the boot.wim, which differs between WinPE builds. Rather than
    guess, the generated script asks the BCD how this machine boots and mounts
    the boot.wim briefly to see which winload it actually contains. A guess here
    produces an entry that looks perfect and does not boot, which is discovered
    on the day somebody needs it.

    ABOUT WHERE THE PAYLOAD GOES

    Not on the volume being restored. A restore that formats C: destroys a
    payload sitting on C: partway through applying it, and leaves a terminal with
    no operating system and nothing to fix it with. This refuses the system
    volume. It also refuses a partition too small to hold the WIM, and it says so
    at first boot rather than failing silently.

    A stock Windows recovery partition is 500MB to 1GB and will not hold a POS
    image. This needs a partition made for it, sized when the disk is laid out --
    which is a change to the deployment answer file, not something any of this
    can do for you.
.PARAMETER TargetLabel
    Volume label of the partition to stage the payload onto.
.PARAMETER RestoreLabel
    Volume label of the partition the recovery WinPE will restore ONTO. Passed
    through to the boot entry description so the two are not confused.
.PARAMETER SourcePath
    Where the payload is at first boot. Leave empty and the script searches every
    volume for a folder named as -PayloadFolder.
.PARAMETER PayloadFolder
    Folder name for the payload, on the source and on the target.
.PARAMETER ImageFile
    File name of the factory WIM.
.PARAMETER BootImageFile
    File name of the prepared WinPE, from New-WfRecoveryBootImage.
.PARAMETER Description
    What the boot menu entry is called. This is what somebody reads at 6am in a
    shop, so make it say what it does.
.PARAMETER Timeout
    Boot menu timeout in seconds, so the menu is on screen long enough to choose.
    Zero leaves it alone.
.PARAMETER MountPath
    The mounted image.
.PARAMETER Append
    Add to an existing SetupComplete.cmd rather than replacing it.
.EXAMPLE
    New-WfRecoveryFirstBoot -TargetLabel WFRECOVERY -RestoreLabel OSDisk -ImageFile Plus-POS.wim -BootImageFile boot.wim
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $TargetLabel,
        [string] $RestoreLabel = 'OSDisk',
        [string] $SourcePath,
        [string] $PayloadFolder = 'Recovery\WimForge',
        [Parameter(Mandatory)] [string] $ImageFile,
        [string] $BootImageFile = 'boot.wim',
        [string] $Description = 'Restore the factory image',
        [int]    $Timeout = 10,
        [string] $MountPath,
        [switch] $Append
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $ps = New-Object System.Collections.Generic.List[string]
    $ps.Add('# WimForge recovery staging, applied once at first boot.')
    $ps.Add('# Generated -- edit the image, not this file.')
    $ps.Add('#')
    $ps.Add('# Partitions and a BCD store do not exist in an offline image, which is')
    $ps.Add('# the whole reason this runs here instead of at build time.')
    $ps.Add('$ErrorActionPreference = ''Continue''')
    $ps.Add('function Say { param($m) Write-Output ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }')
    $ps.Add('')
    $ps.Add(('$label   = ''{0}''' -f ($TargetLabel  -replace "'", "''")))
    $ps.Add(('$folder  = ''{0}''' -f ($PayloadFolder -replace "'", "''")))
    $ps.Add(('$wimName = ''{0}''' -f ($ImageFile     -replace "'", "''")))
    $ps.Add(('$peName  = ''{0}''' -f ($BootImageFile -replace "'", "''")))
    $ps.Add(('$descr   = ''{0}''' -f ($Description   -replace "'", "''")))
    if ($SourcePath) {
        $ps.Add(('$source  = ''{0}''' -f ($SourcePath -replace "'", "''")))
    }
    else {
        $ps.Add('$source  = $null')
    }
    $ps.Add('')

    # --- find the recovery partition ---------------------------------------
    $ps.Add('Say "Looking for a volume labelled $label"')
    $ps.Add('$target = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq $label }')
    $ps.Add('if (-not $target) {')
    $ps.Add('    Say "  no volume is labelled $label -- nothing staged, no boot entry added"')
    $ps.Add('    Say "  the recovery partition has to exist and be labelled before this can use it"')
    $ps.Add('    return')
    $ps.Add('}')
    $ps.Add('$target = @($target)[0]')
    $ps.Add('')
    # A partition with no letter is the normal case for a recovery partition,
    # and it needs one for the duration.
    $ps.Add('$letter = $target.DriveLetter')
    $ps.Add('$assigned = $false')
    $ps.Add('if (-not $letter) {')
    $ps.Add('    Say "  it has no drive letter; assigning one"')
    $ps.Add('    $free = [char[]](90..67 | ForEach-Object { [char]$_ }) |')
    $ps.Add('            Where-Object { -not (Test-Path ("{0}:\" -f $_)) } | Select-Object -First 1')
    $ps.Add('    if (-not $free) { Say "  no free drive letters"; return }')
    $ps.Add('    try {')
    $ps.Add('        Get-Partition -Volume $target | Set-Partition -NewDriveLetter $free -ErrorAction Stop')
    $ps.Add('        $letter = $free; $assigned = $true')
    $ps.Add('    }')
    $ps.Add('    catch { Say "  could not assign a letter: $($_.Exception.Message)"; return }')
    $ps.Add('}')
    $ps.Add('$root = "{0}:" -f $letter')
    $ps.Add('Say "  recovery partition is $root"')
    $ps.Add('')

    # --- refuse the system volume ------------------------------------------
    $ps.Add('# The payload cannot live on the volume it restores. A restore that')
    $ps.Add('# formats the volume destroys the image partway through applying it.')
    $ps.Add('$systemRoot = ($env:SystemDrive)')
    $ps.Add('if ($root -eq $systemRoot) {')
    $ps.Add('    Say "  $root is the system volume. Refusing -- a restore would delete the image it is applying."')
    $ps.Add('    return')
    $ps.Add('}')
    $ps.Add('')

    # --- find the source ----------------------------------------------------
    $ps.Add('if (-not $source) {')
    $ps.Add('    Say "Looking for the payload on every volume"')
    $ps.Add('    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {')
    $ps.Add('        $try = Join-Path $d.Root $folder')
    $ps.Add('        if ((Test-Path (Join-Path $try $wimName)) -and $d.Root -notlike "$root*") { $source = $try; break }')
    $ps.Add('    }')
    $ps.Add('}')
    $ps.Add('if (-not $source -or -not (Test-Path (Join-Path $source $wimName))) {')
    $ps.Add('    Say "  the payload was not found. Looked for $folder\$wimName."')
    $ps.Add('    Say "  nothing staged, no boot entry added -- the machine is otherwise fine"')
    $ps.Add('    return')
    $ps.Add('}')
    $ps.Add('Say "  payload is at $source"')
    $ps.Add('')

    # --- space check --------------------------------------------------------
    $ps.Add('$need = (Get-ChildItem -LiteralPath $source -File -ErrorAction SilentlyContinue |')
    $ps.Add('         Measure-Object -Property Length -Sum).Sum')
    $ps.Add('$have = (Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue).SizeRemaining')
    $ps.Add('if ($need -and $have -and $have -lt ($need * 1.05)) {')
    $ps.Add('    Say ("  $root has {0:N1} GB free and the payload needs {1:N1} GB. Not staging." -f ($have/1GB), ($need/1GB))')
    $ps.Add('    Say "  the recovery partition has to be sized for the image when the disk is laid out"')
    $ps.Add('    return')
    $ps.Add('}')
    $ps.Add('')

    # --- copy ---------------------------------------------------------------
    $ps.Add('$dest = Join-Path $root $folder')
    $ps.Add('Say "Copying the payload to $dest"')
    $ps.Add('try {')
    $ps.Add('    New-Item -ItemType Directory -Path $dest -Force | Out-Null')
    $ps.Add('    Copy-Item -Path (Join-Path $source "*") -Destination $dest -Recurse -Force -ErrorAction Stop')
    $ps.Add('}')
    $ps.Add('catch { Say "  copy failed: $($_.Exception.Message)"; return }')
    $ps.Add('')
    $ps.Add('$pe  = Join-Path $dest $peName')
    $ps.Add('$sdi = Join-Path $dest "boot.sdi"')
    $ps.Add('foreach ($f in @($pe, $sdi)) {')
    $ps.Add('    if (-not (Test-Path $f)) {')
    $ps.Add('        Say "  $f is missing, so no boot entry can be made"')
    $ps.Add('        Say "  boot.sdi comes from the ADK or from \boot\boot.sdi on Windows media"')
    $ps.Add('        return')
    $ps.Add('    }')
    $ps.Add('}')
    $ps.Add('')

    # --- which winload? -----------------------------------------------------
    $ps.Add('# Which winload the entry needs depends on the firmware, and where it')
    $ps.Add('# lives depends on the WinPE build. Both are asked rather than assumed:')
    $ps.Add('# a wrong answer here makes an entry that looks right and will not boot,')
    $ps.Add('# which is found out on the morning somebody needs it.')
    $ps.Add('$uefi = $false')
    $ps.Add('try { $uefi = ((& bcdedit /enum "{bootmgr}" 2>&1) -join " ") -match "\.efi" } catch { }')
    $ps.Add('if (-not $uefi) { $uefi = ($env:firmware_type -eq "UEFI") }')
    $ps.Add('$loader = if ($uefi) { "winload.efi" } else { "winload.exe" }')
    $ps.Add('Say ("Firmware looks like {0}, so the entry needs {1}" -f $(if ($uefi) { "UEFI" } else { "BIOS" }), $loader)')
    $ps.Add('')
    $ps.Add('$loaderPath = $null')
    $ps.Add('$peMount = Join-Path $env:TEMP "WimForge-PeProbe"')
    $ps.Add('try {')
    $ps.Add('    New-Item -ItemType Directory -Path $peMount -Force | Out-Null')
    $ps.Add('    Mount-WindowsImage -ImagePath $pe -Index 1 -Path $peMount -ReadOnly -ErrorAction Stop | Out-Null')
    $ps.Add('    foreach ($candidate in @("Windows\System32\Boot\$loader", "Windows\System32\$loader")) {')
    $ps.Add('        if (Test-Path (Join-Path $peMount $candidate)) {')
    $ps.Add('            $loaderPath = "\" + ($candidate -replace "\\Boot\\", "\Boot\")')
    $ps.Add('            break')
    $ps.Add('        }')
    $ps.Add('    }')
    $ps.Add('}')
    $ps.Add('catch { Say "  could not read the boot image: $($_.Exception.Message)" }')
    $ps.Add('finally {')
    $ps.Add('    Dismount-WindowsImage -Path $peMount -Discard -ErrorAction SilentlyContinue | Out-Null')
    $ps.Add('    Remove-Item -LiteralPath $peMount -Recurse -Force -ErrorAction SilentlyContinue')
    $ps.Add('}')
    $ps.Add('if (-not $loaderPath) {')
    $ps.Add('    Say "  $loader is not in that boot image, so no entry was made"')
    $ps.Add('    Say "  a boot.wim for the wrong firmware or architecture is the usual reason"')
    $ps.Add('    return')
    $ps.Add('}')
    $ps.Add('Say "  loader is $loaderPath"')
    $ps.Add('')

    # --- the boot entry -----------------------------------------------------
    $ps.Add('# An entry from a previous run would otherwise accumulate one per')
    $ps.Add('# re-image, and a boot menu with four identical entries is its own')
    $ps.Add('# kind of unusable.')
    $ps.Add('$existing = (& bcdedit /enum osloader 2>&1) -join "`n"')
    $ps.Add('if ($existing -match [regex]::Escape($descr)) {')
    $ps.Add('    Say "A boot entry called ''$descr'' is already there. Leaving it alone."')
    $ps.Add('    return')
    $ps.Add('}')
    $ps.Add('')
    $ps.Add('Say "Creating the boot entry"')
    $ps.Add('$created = & bcdedit /create /d $descr /application osloader 2>&1')
    $ps.Add('$guid = ([regex]::Match(($created -join " "), "\{[0-9a-fA-F\-]+\}")).Value')
    $ps.Add('if (-not $guid) { Say "  bcdedit did not return an identifier: $created"; return }')
    $ps.Add('Say "  $guid"')
    $ps.Add('')
    $ps.Add('$ramdisk = "ramdisk=[{0}]\{1}\{2},{{ramdiskoptions}}" -f $root, $folder, $peName')
    $ps.Add('$steps = @(')
    $ps.Add('    @{ What = "device";     Args = @("/set", $guid, "device", $ramdisk) }')
    $ps.Add('    @{ What = "osdevice";   Args = @("/set", $guid, "osdevice", $ramdisk) }')
    $ps.Add('    @{ What = "path";       Args = @("/set", $guid, "path", $loaderPath) }')
    $ps.Add('    @{ What = "systemroot"; Args = @("/set", $guid, "systemroot", "\Windows") }')
    $ps.Add('    @{ What = "winpe";      Args = @("/set", $guid, "winpe", "yes") }')
    $ps.Add('    @{ What = "detecthal";  Args = @("/set", $guid, "detecthal", "yes") }')
    $ps.Add('    @{ What = "nx";         Args = @("/set", $guid, "nx", "optin") }')
    $ps.Add('    @{ What = "sdi device"; Args = @("/set", "{ramdiskoptions}", "ramdisksdidevice", ("partition={0}" -f $root)) }')
    $ps.Add('    @{ What = "sdi path";   Args = @("/set", "{ramdiskoptions}", "ramdisksdipath", ("\{0}\boot.sdi" -f $folder)) }')
    $ps.Add('    # Last in the menu, deliberately. This must never become the')
    $ps.Add('    # thing a till boots when nobody presses anything.')
    $ps.Add('    @{ What = "menu order"; Args = @("/displayorder", $guid, "/addlast") }')
    $ps.Add(')')
    $ps.Add('$failed = $false')
    $ps.Add('foreach ($s in $steps) {')
    $ps.Add('    $out = & bcdedit @($s.Args) 2>&1')
    $ps.Add('    if ($LASTEXITCODE -ne 0) { Say "  $($s.What) failed: $out"; $failed = $true }')
    $ps.Add('}')
    if ($Timeout -gt 0) {
        $ps.Add(('& bcdedit /timeout {0} 2>&1 | Out-String | Write-Output' -f $Timeout))
    }
    $ps.Add('')
    $ps.Add('if ($failed) {')
    $ps.Add('    Say "The entry is incomplete and would not boot, so it is being removed again."')
    $ps.Add('    & bcdedit /delete $guid /f 2>&1 | Out-String | Write-Output')
    $ps.Add('}')
    $ps.Add('else {')
    $ps.Add('    Say "Boot entry ''$descr'' created."')
    $ps.Add(('    Say "It restores the volume labelled {0} from $dest\$wimName."' -f ($RestoreLabel -replace "'", "''")))
    $ps.Add('}')
    $ps.Add('')
    # The letter came from us, so it goes back. A recovery partition with a
    # drive letter shows up in Explorer, and a visible partition full of a WIM
    # is a partition somebody eventually clears out to make space.
    $ps.Add('if ($assigned) {')
    $ps.Add('    Say "Taking the temporary drive letter back off the recovery partition"')
    $ps.Add('    try { Get-Partition -DriveLetter $letter | Remove-PartitionAccessPath -AccessPath $root -ErrorAction Stop }')
    $ps.Add('    catch { Say "  could not remove it: $($_.Exception.Message)" }')
    $ps.Add('}')
    $ps.Add('Say "recovery staging complete"')

    if (-not $PSCmdlet.ShouldProcess($MountPath, 'Write the recovery first-boot script')) { return }

    $scriptsDir = New-WfDirectory (Join-WfPath $MountPath 'Windows\Setup\Scripts')
    $psPath     = Join-WfPath $scriptsDir 'WimForge-Recovery.ps1'
    Set-Content -LiteralPath $psPath -Value $ps -Encoding UTF8 -Force

    Write-WfLog ("Recovery staging script written, {0} line(s)" -f $ps.Count) -Level OK

    $result = Set-WfFirstBootScript -MountPath $MountPath -Append:$Append -Confirm:$false `
        -Command 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\WimForge-Recovery.ps1"'

    Write-WfLog "The payload must be on the deployment media under $PayloadFolder -- $ImageFile, $BootImageFile and boot.sdi." -Level INFO
    Write-WfLog "A partition labelled $TargetLabel must exist and be big enough for the image. A stock 500MB recovery partition is not." -Level WARN

    Write-WfHistory -Action 'Recovery first boot' -ImagePath $MountPath -Detail @{
        TargetLabel = $TargetLabel; RestoreLabel = $RestoreLabel
        ImageFile = $ImageFile; BootImage = $BootImageFile; Description = $Description
    } | Out-Null

    return [pscustomobject]@{
        ScriptPath    = $psPath
        Lines         = $ps.Count
        SetupComplete = $result.Path
        LogPath       = $result.LogPath
        TargetLabel   = $TargetLabel
        RestoreLabel  = $RestoreLabel
        PayloadFolder = $PayloadFolder
        ImageFile     = $ImageFile
        BootImageFile = $BootImageFile
        Description   = $Description
    }
}
