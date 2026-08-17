# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    PeCustomise.ps1 -- putting your own software into WinPE, and making it run.

    Add-WfBootDriver already puts drivers into a boot image. This is the rest of
    it: optional components, scratch space, your own tools, and the startnet.cmd
    that starts them.

    Four facts decide everything here, and all four are Microsoft's own words.

    1. WinPE runs from RAM, and the whole image has to fit in CONTIGUOUS physical
       memory: "In order to boot Windows PE directly from memory (also known as
       RAM disk boot), a contiguous portion of physical memory (RAM) which can
       hold the entire Windows PE (WIM) image must be available." So every
       megabyte added to boot.wim is a megabyte of RAM on every machine that
       boots it -- on top of the scratch space. The base needs 512MB; a boot
       image with a 900MB toolkit inside it needs a good deal more, and the
       failure on a thin terminal is a machine that will not boot rather than a
       tool that will not start.

       Which is why this file offers two ways to carry software, and pushes
       towards the second for anything large:

         Add-WfPeTool          into the image. Small things. Costs RAM.
         New-WfPeStartnet      -PayloadFolder finds a folder on the media at run
                               time. Costs nothing, works for gigabytes, and is
                               how a USB stick full of tools should be built.

    2. No .msi. The limitations list is explicit -- Windows PE does not support
       ".MSI installation files". There is no Windows Installer service to run
       one. Software goes in as files or it does not go in.

    3. No 32-bit apps on 64-bit WinPE. Also from the limitations list: PE does
       not support "running apps that are compiled for one architecture on a
       different architecture, for example running 32-bit apps on the 64-bit
       version of Windows PE". There is no WoW64 optional component; the only
       emulation component that exists, WinPE-x64-Support, is x64-on-Arm64 and
       nothing to do with this. And 32-bit WinPE itself is gone: "the last
       supported version of 32-bit WinPE is available in the WinPE add-on for
       Windows 10, version 2004."

       So Add-WfPeTool reads the machine type out of every binary it copies and
       refuses the mismatch, because the alternative is finding out from a till
       that says nothing at all when the tool is launched.

    4. "Startnet.cmd starts Wpeinit.exe. Wpeinit.exe installs Plug and Play
       devices, processes Unattend.xml settings, and loads network resources."
       Anything above the wpeinit line runs with no drivers and no network.
       New-WfPeStartnet therefore always emits it first, and will not put it
       anywhere else.

    One more, worth knowing before planning around PE: the shell restarts after
    240 hours of continuous use ("this period is not configurable"), and it is
    documented as not a general-purpose operating system. It is fine for a
    deployment console. It is not somewhere to run a shop.
#>

# The optional components, with the dependency chains Microsoft documents.
#
# Written down rather than discovered because the chains are not derivable from
# the file names, and getting them wrong produces a component that appears to
# install and then does not work. The order within this list IS the install
# order -- WinPE-WMI has to be first for the whole PowerShell chain.
#
# Microsoft's own page contradicts itself once, and this follows the specific
# statement over the loose one: the WinPE-Scripting entry says "the installation
# order is irrelevant", while the WinPE-PowerShell and WinPE-HTA entries on the
# same page give explicit "install X > Y > Z before this" chains. Following the
# chains satisfies both.
$script:WfPeComponents = @(
    @{ Name = 'WinPE-WMI';               Needs = @();                                             What = 'WMI. The bottom of the PowerShell chain and needed on its own for hardware queries.' }
    @{ Name = 'WinPE-NetFX';             Needs = @('WinPE-WMI');                                  What = 'A subset of .NET Framework 4.5. Nothing managed runs without it.' }
    @{ Name = 'WinPE-Scripting';         Needs = @('WinPE-WMI','WinPE-NetFX');                    What = 'Windows Script Host -- vbscript and jscript.' }
    @{ Name = 'WinPE-PowerShell';        Needs = @('WinPE-WMI','WinPE-NetFX','WinPE-Scripting');  What = 'PowerShell. Adds well over a hundred megabytes, all of it RAM at boot.' }
    @{ Name = 'WinPE-StorageWMI';        Needs = @('WinPE-WMI','WinPE-NetFX','WinPE-Scripting','WinPE-PowerShell'); What = 'The storage cmdlets -- Get-Disk, New-Partition, Format-Volume.' }
    @{ Name = 'WinPE-DismCmdlets';       Needs = @('WinPE-WMI','WinPE-NetFX','WinPE-Scripting','WinPE-PowerShell'); What = 'The DISM cmdlets, for applying an image from PowerShell rather than dism.exe.' }
    @{ Name = 'WinPE-SecureBootCmdlets'; Needs = @('WinPE-WMI','WinPE-NetFX','WinPE-Scripting','WinPE-PowerShell'); What = 'Secure Boot cmdlets.' }
    @{ Name = 'WinPE-HTA';               Needs = @('WinPE-Scripting');                            What = 'HTML applications -- the old way to give PE a front end.' }
    @{ Name = 'WinPE-EnhancedStorage';   Needs = @();                                             What = 'Encrypted and enhanced storage devices.' }
    @{ Name = 'WinPE-SecureStartup';     Needs = @();                                             What = 'BitLocker and TPM. Needed to unlock an encrypted volume from PE.' }
    @{ Name = 'WinPE-MDAC';              Needs = @();                                             What = 'Data access -- ADO, for a tool that talks to SQL. Not an installer service.' }
    @{ Name = 'WinPE-WDS-Tools';         Needs = @();                                             What = 'The WDS client tools, including the image capture wizard.' }
    @{ Name = 'WinPE-Dot3Svc';           Needs = @();                                             What = '802.1X wired authentication, for a site whose switches demand it.' }
    @{ Name = 'WinPE-WiFi-Package';      Needs = @();                                             What = 'Wi-Fi. A deployment over Wi-Fi is slow, but it beats no network at all.' }
    @{ Name = 'WinPE-PPPoE';             Needs = @();                                             What = 'PPPoE.' }
    @{ Name = 'WinPE-FMAPI';             Needs = @();                                             What = 'File management API -- undelete and recovery tooling.' }
    @{ Name = 'WinPE-Fonts-Legacy';      Needs = @();                                             What = 'The legacy font set, for a PE that has to show non-Latin text.' }
    @{ Name = 'WinPE-SRT';               Needs = @();                                             What = 'The system recovery tools.' }
    @{ Name = 'WinPE-WinReCfg';          Needs = @();                                             What = 'Configures the recovery environment of an offline image.' }
    @{ Name = 'WinPE-Rejuv';             Needs = @();                                             What = 'Push-button reset support.' }
    @{ Name = 'WinPE-Setup';             Needs = @();                                             What = 'Windows Setup. Only for building an install boot image by hand.' }
    @{ Name = 'WinPE-Setup-Client';      Needs = @('WinPE-Setup');                                What = 'The client half of Setup.' }
    @{ Name = 'WinPE-Setup-Server';      Needs = @('WinPE-Setup');                                What = 'The server half of Setup.' }
)

function Get-WfPeBinaryArchitecture {
    <#
        The architecture a binary was compiled for, read out of the file.

        Every Windows executable starts with a DOS stub whose e_lfanew field, at
        offset 0x3C, points at the real PE header. Four bytes of signature, then
        a two-byte machine type. That is the whole trick, and it is worth doing
        because the alternative is a tool that is silently never going to run.

        Returns 'x86', 'x64', 'arm64', 'arm', or '' for anything that is not a
        Windows binary at all -- a text file, a .png, a zip. Never throws: this
        walks whole folders, and most of what is in them is not an executable.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    try {
        $stream = [System.IO.File]::OpenRead($Path)
    }
    catch { return '' }

    try {
        if ($stream.Length -lt 0x40) { return '' }

        $reader = New-Object System.IO.BinaryReader($stream)

        if ($reader.ReadUInt16() -ne 0x5A4D) { return '' }        # 'MZ'

        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -le 0 -or ($peOffset + 6) -gt $stream.Length) { return '' }

        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return '' }    # 'PE\0\0'

        $machine = $reader.ReadUInt16()
    }
    catch { return '' }
    finally { $stream.Dispose() }

    switch ($machine) {
        0x014C  { return 'x86' }
        0x8664  { return 'x64' }
        0xAA64  { return 'arm64' }
        0x01C4  { return 'arm' }
        0x01C0  { return 'arm' }
        default { return '' }
    }
}

function Get-WfPeLaunchCommand {
<#
.SYNOPSIS
    How a thing actually gets started in WinPE, and what has to be in the image
    first.
.DESCRIPTION
    Not everything worth putting in a boot image is an .exe. An HTA is a few
    kilobytes of HTML and gives a deployment console a real front end; a .cmd is
    the most portable thing there is; a .ps1 is convenient if PowerShell is in
    there anyway.

    They are not started the same way, and getting it wrong is quiet. Writing

        "%SystemRoot%\Tools\Menu\menu.hta"

    into startnet.cmd relies on the .hta file association being registered in
    WinPE. It usually is -- a Microsoft forum thread shows a bare path launching
    one -- but no Microsoft documentation says so, and every deployment product
    that does this in anger goes through mshta.exe explicitly. MDT's own
    LiteTouch.wsf builds `MSHTA.exe "...\Wizard.hta"` rather than trusting the
    association. So this does too: an association is a nice thing to have and a
    terrible thing to depend on.

    Requires is the other half. An HTA in a boot image with no WinPE-HTA is a few
    kilobytes of HTML that can never run, and nothing about the image looks wrong.
.PARAMETER Command
    The thing to run. Only its extension is read, so a relative path, a full path
    or a bare file name all work.
.PARAMETER Path
    The full path as the terminal will see it, used to build Line. Defaults to
    Command.
.PARAMETER Arguments
    Appended to the line.
.EXAMPLE
    Get-WfPeLaunchCommand -Command menu.hta -Path '%SystemRoot%\Tools\Menu\menu.hta'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Command,
        [string] $Path,
        [string] $Arguments
    )

    if (-not $Path) { $Path = $Command }

    $ext = ''
    try { $ext = [System.IO.Path]::GetExtension($Command).ToLowerInvariant() } catch { }

    $kind     = 'Unsupported'
    $launcher = ''
    $requires = ''
    $note     = ''

    switch ($ext) {
        { $_ -in @('.exe', '.com') } {
            $kind = 'Executable'
            $note = 'Started directly.'
            break
        }
        { $_ -in @('.cmd', '.bat') } {
            $kind     = 'Batch'
            $launcher = 'call'
            $note     = 'Called, so startnet.cmd carries on afterwards instead of ending with it.'
            break
        }
        '.hta' {
            $kind     = 'Hta'
            $launcher = 'mshta.exe'
            $requires = 'WinPE-HTA'
            $note     = 'Run through mshta.exe rather than by file association -- the association is undocumented in WinPE, and every deployment product that does this goes through mshta explicitly.'
            break
        }
        '.ps1' {
            $kind     = 'PowerShell'
            $launcher = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
            $requires = 'WinPE-PowerShell'
            $note     = 'ExecutionPolicy Bypass because WinPE''s default is not documented anywhere, and every deployment front end in the wild passes it.'
            break
        }
        { $_ -in @('.vbs', '.wsf') } {
            $kind     = 'VBScript'
            $launcher = 'cscript.exe //nologo'
            $requires = 'WinPE-Scripting'
            $note     = 'cscript rather than wscript: wscript pops message boxes for output, which on a deployment console nobody is watching means a machine sitting on an OK button.'
            break
        }
        '.js' {
            $kind     = 'JScript'
            $launcher = 'cscript.exe //nologo //E:JScript'
            $requires = 'WinPE-Scripting'
            $note     = 'The engine is named explicitly, because .js has been claimed by more than one host over the years.'
            break
        }
        { $_ -in @('.msi', '.msp', '.msix', '.appx') } {
            $kind = 'Unsupported'
            $note = 'Windows PE does not support .MSI installation files -- there is no Windows Installer service in it, so nothing can install this.'
            break
        }
        default {
            $kind = 'Unsupported'
            $note = "Nothing in WinPE knows how to start a '$ext' file."
        }
    }

    $line = ''
    if ($kind -ne 'Unsupported') {
        if ($launcher) { $line = ('{0} "{1}"' -f $launcher, $Path) }
        else           { $line = ('"{0}"' -f $Path) }
        if ($Arguments) { $line = ($line + ' ' + $Arguments) }
    }

    return [pscustomobject]@{
        Kind      = $kind
        Launcher  = $launcher
        Requires  = $requires
        Line      = $line
        Extension = $ext
        Note      = $note
    }
}

function ConvertFrom-WfImageArchitecture {
    <#
        DISM reports architecture as a number. 0 is x86, 9 is amd64, 12 is arm64
        -- the values the SYSTEM_INFO processor architecture constants use, which
        is why 9 and 12 look arbitrary.
    #>
    param($Value)

    switch ("$Value") {
        '0'     { return 'x86' }
        '5'     { return 'arm' }
        '9'     { return 'x64' }
        '12'    { return 'arm64' }
        'x86'   { return 'x86' }
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { return "$Value" }
    }
}

function Get-WfAdkWinPeRoot {
<#
.SYNOPSIS
    Where the ADK keeps the WinPE optional components.
.DESCRIPTION
    Found from the registry rather than from a guessed Program Files path,
    because the ADK can be installed anywhere and frequently is.

    The rule that catches people is not the path, it is the version: "the OCs you
    add to your WinPE image must be from the same ADK build and have the same
    architecture as your WinPE image." An OC from last year's ADK in this year's
    boot image is a component that installs cleanly and then misbehaves.
.PARAMETER Architecture
    amd64 or arm64. Optional components ship for those two only -- there is no
    x86 set any more.
.EXAMPLE
    Get-WfAdkWinPeRoot
#>
    [CmdletBinding()]
    param([ValidateSet('amd64','arm64')] [string] $Architecture = 'amd64')

    $kits = $null
    try {
        $kits = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop).KitsRoot10
    }
    catch { }

    if (-not $kits) {
        Write-WfLog 'The Windows ADK is not installed on this machine, so there are no optional components to add.' -Level WARN
        Write-WfLog '  Drivers, tools and startnet.cmd all still work without it -- only optional components need it.' -Level INFO
        return $null
    }

    $ocs = Join-WfPath (Join-WfPath $kits 'Assessment and Deployment Kit\Windows Preinstallation Environment') `
                       (Join-WfPath $Architecture 'WinPE_OCs')

    if (-not (Test-Path -LiteralPath $ocs)) {
        Write-WfLog "The ADK is installed at $kits but the WinPE add-on is not: $ocs is missing." -Level WARN
        Write-WfLog '  The WinPE add-on is a separate download from the ADK itself.' -Level INFO
        return $null
    }

    return $ocs
}

function Get-WfPeOptionalComponent {
<#
.SYNOPSIS
    The WinPE optional components, what each one is for, and what it needs first.
.DESCRIPTION
    The catalog, joined against what the ADK on this machine actually has. Sizes
    are real, and worth looking at before adding anything: WinPE-PowerShell and
    its chain is not a small thing, and every byte of it is RAM on the terminal.
.PARAMETER Name
    Narrows to particular components. Accepts partial names -- 'PowerShell'
    finds WinPE-PowerShell.
.PARAMETER Architecture
    amd64 or arm64.
.PARAMETER Language
    The language cab to pair with each component. en-us unless the PE has to
    speak something else.
.EXAMPLE
    Get-WfPeOptionalComponent | Format-Table Name, Present, SizeMB, Needs, What
.EXAMPLE
    Get-WfPeOptionalComponent -Name PowerShell
#>
    [CmdletBinding()]
    param(
        [string[]] $Name,
        [ValidateSet('amd64','arm64')] [string] $Architecture = 'amd64',
        [string] $Language = 'en-us'
    )

    $root = Get-WfAdkWinPeRoot -Architecture $Architecture

    $out = New-Object System.Collections.Generic.List[object]

    foreach ($c in $script:WfPeComponents) {
        $cab     = ''
        $langCab = ''
        $sizeMb  = $null
        $present = $false

        if ($root) {
            $candidate = Join-WfPath $root ($c.Name + '.cab')
            if (Test-Path -LiteralPath $candidate) {
                $present = $true
                $cab     = $candidate
                $bytes   = (Get-Item -LiteralPath $candidate).Length

                # The language cab is a separate file under a per-language
                # folder, and Microsoft's own instructions add it immediately
                # after its neutral cab every time. Skipping it gives a component
                # whose strings are missing.
                $lc = Join-WfPath (Join-WfPath $root $Language) ('{0}_{1}.cab' -f $c.Name, $Language)
                if (Test-Path -LiteralPath $lc) {
                    $langCab = $lc
                    $bytes  += (Get-Item -LiteralPath $lc).Length
                }

                $sizeMb = [math]::Round($bytes / 1MB, 1)
            }
        }

        $out.Add([pscustomobject]@{
            Name        = $c.Name
            Present     = $present
            SizeMB      = $sizeMb
            Needs       = ($c.Needs -join ', ')
            What        = $c.What
            Cab         = $cab
            LanguageCab = $langCab
        })
    }

    $result = $out.ToArray()
    if ($Name) {
        $result = @($result | Where-Object {
            $row = $_
            @($Name | Where-Object { $row.Name -like "*$_*" }).Count -gt 0
        })
        if ($result.Count -eq 0) {
            throw ("No optional component matches: {0}. Get-WfPeOptionalComponent with no arguments lists them all." -f ($Name -join ', '))
        }
    }

    return $result
}

function Resolve-WfPeComponentOrder {
    <#
        Expands a list of components into everything they need, in install order.

        Order comes from the catalog's own order rather than from a topological
        sort, because the catalog IS the documented order and reproducing it by
        algorithm would only be a chance to disagree with Microsoft.
    #>
    param([Parameter(Mandatory)] [string[]] $Name)

    $wanted = New-Object System.Collections.Generic.List[string]

    foreach ($n in $Name) {
        $match = @($script:WfPeComponents | Where-Object { $_.Name -eq $n })
        if ($match.Count -eq 0) {
            $match = @($script:WfPeComponents | Where-Object { $_.Name -like "*$n*" })
        }
        if ($match.Count -eq 0) {
            throw ("No optional component called {0}. Get-WfPeOptionalComponent lists them." -f $n)
        }
        if ($match.Count -gt 1) {
            throw ("'{0}' matches {1}. Be more specific." -f $n, (@($match | ForEach-Object { $_.Name }) -join ', '))
        }

        foreach ($dep in @($match[0].Needs)) {
            if (-not $wanted.Contains($dep)) { $wanted.Add($dep) }
        }
        if (-not $wanted.Contains($match[0].Name)) { $wanted.Add($match[0].Name) }
    }

    # Back into catalog order, which is the install order.
    return @($script:WfPeComponents | Where-Object { $wanted.Contains($_.Name) } | ForEach-Object { $_.Name })
}

function Invoke-WfPeMounted {
    <#
        Mounts a boot image, runs a scriptblock against the mount, and saves --
        or discards the whole thing if anything went wrong.

        Its own mount path, with '-Pe' on the end, so it can never collide with
        an install image mount that is already open. A boot image left mounted
        because a tool threw is the thing that makes the NEXT run fail with a
        message about the mount folder, three steps away from the real problem.

        The scriptblock gets the mount path as $args[0].
    #>
    param(
        [Parameter(Mandatory)] [string] $BootImagePath,
        [int] $Index = 1,
        [Parameter(Mandatory)] [scriptblock] $Body,
        [switch] $ReadOnly
    )

    $mount = ((Get-WfConfig)['MountPath']) + '-Pe'
    New-WfDirectory $mount | Out-Null

    Write-WfLog ("Mounting {0} index {1} at {2}" -f (Split-Path $BootImagePath -Leaf), $Index, $mount) -Level STEP
    Mount-WindowsImage -ImagePath $BootImagePath -Index $Index -Path $mount -ReadOnly:$ReadOnly -ErrorAction Stop | Out-Null

    try {
        $result = & $Body $mount

        if ($ReadOnly) {
            Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null
            Write-WfLog 'Boot image closed.' -Level OK
        }
        else {
            Dismount-WindowsImage -Path $mount -Save -ErrorAction Stop | Out-Null
            Write-WfLog 'Boot image saved.' -Level OK
        }
        return $result
    }
    catch {
        Write-WfLog "Failed -- discarding the boot image mount: $($_.Exception.Message)" -Level ERROR
        try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
        catch { Write-WfLog 'The discard failed too. Run Repair-WfMount before trying again.' -Level ERROR }
        throw
    }
}

function Add-WfPeOptionalComponent {
<#
.SYNOPSIS
    Adds optional components to a boot image, with their dependencies, in order.
.DESCRIPTION
    Ask for WinPE-PowerShell and this puts WinPE-WMI, WinPE-NetFX and
    WinPE-Scripting in first, because Microsoft's chain says so and a component
    added out of order installs cleanly and then does not work.

    Each neutral cab is followed immediately by its language cab, which is how
    Microsoft's own instructions read and what stops a component coming up with
    no strings.

    Adding PowerShell and its chain costs well over a hundred megabytes, and on a
    RAM-disk boot that is a hundred megabytes of memory on every terminal. Worth
    it for a deployment console; not worth it to run one script that a .cmd could
    have done.
.PARAMETER Component
    Names, full or partial. 'PowerShell' is enough.
.PARAMETER BootImagePath
    Defaults to the configured PeImage. Modified in place -- work on a copy.
.PARAMETER Index
    On Microsoft media boot.wim, index 1 is WinPE and index 2 is Windows Setup.
    A copype-built image has one index.
.PARAMETER Language
    Which language cabs to pair. en-us by default.
.EXAMPLE
    Add-WfPeOptionalComponent -Component PowerShell -BootImagePath C:\Imaging\Pe\boot.wim
.EXAMPLE
    Add-WfPeOptionalComponent -Component WinPE-WMI, WinPE-SecureStartup
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string[]] $Component,
        [string] $BootImagePath,
        [int]    $Index = 1,
        [ValidateSet('amd64','arm64')] [string] $Architecture = 'amd64',
        [string] $Language = 'en-us'
    )

    Assert-WfElevated
    if (-not $BootImagePath) { $BootImagePath = (Get-WfConfig)['PeImage'] }
    $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'

    $root = Get-WfAdkWinPeRoot -Architecture $Architecture
    if (-not $root) {
        throw ('Optional components come out of the Windows ADK WinPE add-on, and it is not on this machine. ' +
               'Install the ADK and the "Windows PE add-on" of the same build as the image being serviced.')
    }

    $order = Resolve-WfPeComponentOrder -Name $Component
    Write-WfLog ("Install order: {0}" -f ($order -join ' > ')) -Level INFO

    $extra = @($order | Where-Object { $Component -notcontains $_ })
    if ($extra.Count -gt 0) {
        Write-WfLog ("Pulled in as dependencies: {0}" -f ($extra -join ', ')) -Level INFO
    }

    # Every cab checked before anything is mounted. Half a chain installed is
    # worse than none of it, and finding the missing file after the mount means
    # discarding the mount to get back to where you started.
    $plan = New-Object System.Collections.Generic.List[object]
    $totalBytes = 0
    foreach ($n in $order) {
        $cab = Join-WfPath $root ($n + '.cab')
        if (-not (Test-Path -LiteralPath $cab)) {
            throw ("{0}.cab is not in {1}. The ADK build may not match the image, or the WinPE add-on is a different architecture." -f $n, $root)
        }
        $totalBytes += (Get-Item -LiteralPath $cab).Length

        $lc = Join-WfPath (Join-WfPath $root $Language) ('{0}_{1}.cab' -f $n, $Language)
        if (-not (Test-Path -LiteralPath $lc)) {
            Write-WfLog ("No {0} language cab for {1} -- it goes in without its strings." -f $Language, $n) -Level WARN
            $lc = ''
        }
        else { $totalBytes += (Get-Item -LiteralPath $lc).Length }

        $plan.Add([pscustomobject]@{ Name = $n; Cab = $cab; LanguageCab = $lc })
    }

    Write-WfLog ("{0} component(s), {1} of cab before expansion" -f $plan.Count, (Format-WfSize $totalBytes)) -Level INFO
    Write-WfLog '  Expanded they are larger, and all of it is RAM on a terminal that boots this from memory.' -Level INFO

    if (-not $PSCmdlet.ShouldProcess($BootImagePath, ("Add {0} optional component(s)" -f $plan.Count))) { return }

    $results = New-Object System.Collections.Generic.List[object]

    Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -Body {
        param($peMount)

        foreach ($p in $plan) {
            Write-WfLog ("+ {0}" -f $p.Name) -Level STEP
            Add-WindowsPackage -Path $peMount -PackagePath $p.Cab -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ Component = $p.Name; Part = 'package'; Status = 'Added' })

            if ($p.LanguageCab) {
                Add-WindowsPackage -Path $peMount -PackagePath $p.LanguageCab -ErrorAction Stop | Out-Null
                $results.Add([pscustomobject]@{ Component = $p.Name; Part = $Language; Status = 'Added' })
            }
            Write-WfLog '  added' -Level OK
        }
    } | Out-Null

    $size = (Get-Item -LiteralPath $BootImagePath).Length
    Write-WfLog ("Boot image is now {0}. Every byte of it has to fit in contiguous RAM on the terminal." -f (Format-WfSize $size)) -Level WARN

    Write-WfHistory -Action 'PE optional components' -ImagePath $BootImagePath -Detail @{
        Index = $Index; Components = ($order -join ', '); Language = $Language
        SizeAfter = $size
    } | Out-Null

    return [pscustomobject]@{
        BootImage  = $BootImagePath
        Index      = $Index
        Added      = $order
        Applied    = $results.ToArray()
        SizeBytes  = $size
    }
}

function Set-WfPeScratchSpace {
<#
.SYNOPSIS
    Sets the writeable space WinPE gives itself on X:.
.DESCRIPTION
    WinPE's boot volume is a RAM disk, and the writeable part of it is fixed at
    boot. Anything your tools write -- logs, temp files, an extracted archive --
    comes out of that. Run out and the symptom is a tool failing on a disk-full
    error against a drive nobody thought of as a drive.

    Microsoft's default: "512MB for PCs with more than 1GB of RAM, otherwise the
    default is 32MB."

    Only five values exist. It is not a number, it is a choice from a list, and
    DISM rejects anything else -- which is worth catching here rather than
    twenty minutes into a build.
.PARAMETER SizeMB
    32, 64, 128, 256 or 512.
.EXAMPLE
    Set-WfPeScratchSpace -SizeMB 512 -BootImagePath C:\Imaging\Pe\boot.wim
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidateSet(32, 64, 128, 256, 512)] [int] $SizeMB,
        [string] $BootImagePath,
        [int]    $Index = 1
    )

    Assert-WfElevated
    if (-not $BootImagePath) { $BootImagePath = (Get-WfConfig)['PeImage'] }
    $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'

    if (-not $PSCmdlet.ShouldProcess($BootImagePath, "Set scratch space to ${SizeMB}MB")) { return }

    # Returned rather than assigned into an outer variable. A scriptblock reads
    # from the scope that called it but WRITES to its own, so `$before = ...`
    # inside the block would set a local that vanishes and leave this one empty
    # -- with nothing failing to say so.
    $before = Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -Body {
        param($peMount)

        $was = ''
        try {
            $out = Invoke-WfDism @("/Image:$peMount", '/Get-ScratchSpace') -PassThruOutput
            $m = [regex]::Match(($out -join "`n"), '(?im)scratch\s*space\s*:?\s*(\d+)')
            if ($m.Success) { $was = $m.Groups[1].Value }
        }
        catch { }

        Write-WfLog ("Setting scratch space to {0}MB" -f $SizeMB) -Level STEP
        Invoke-WfDism @("/Image:$peMount", "/Set-ScratchSpace:$SizeMB") | Out-Null

        return $was
    }

    if ($before) { Write-WfLog ("Was {0}MB, now {1}MB" -f $before, $SizeMB) -Level OK }
    else         { Write-WfLog ("Now {0}MB" -f $SizeMB) -Level OK }

    Write-WfHistory -Action 'PE scratch space' -ImagePath $BootImagePath -Detail @{
        Index = $Index; Was = $before; Now = $SizeMB
    } | Out-Null

    return [pscustomobject]@{ BootImage = $BootImagePath; Index = $Index; Was = $before; SizeMB = $SizeMB }
}

function Enable-WfPeLegacyJScript {
<#
.SYNOPSIS
    Makes HTAs work again in a modern boot image.
.DESCRIPTION
    The trap that costs a day, and it is not yours -- it is a change Microsoft
    made to the script engine.

    From the ADK for Windows 11 22H2 onwards, an HTA that worked for years comes
    up with "An error has occurred in the script on this page." Microsoft
    documents it in the MDT known issues: the JScript engine was replaced, and
    the replacement does not run what the old one ran. MDT's own answer is two
    registry values in the boot image, and this writes the same two:

      Internet Explorer\Main\JscriptReplacement                    = 0
      ...Main\FeatureControl\FEATURE_USE_LEGACY_JSCRIPT\mshta.exe  = 1

    Add-WfPeTool does this for you when the tool it is adding is an HTA, so most
    people never call this directly. It is here for the boot image that already
    has an HTA in it and started failing after an ADK upgrade -- which is exactly
    how anyone meets this problem.

    Note the shape of the failure, because it is what makes this worth
    automating: nothing about the image is wrong, nothing logs, and the symptom
    appears on the terminal in a dialog box that names neither the ADK nor the
    engine.
.PARAMETER Remove
    Put it back to the modern engine.
.EXAMPLE
    Enable-WfPeLegacyJScript -BootImagePath C:\Imaging\Pe\boot.wim
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $BootImagePath,
        [int]    $Index = 1,
        [switch] $Remove
    )

    Assert-WfElevated
    if (-not $BootImagePath) { $BootImagePath = (Get-WfConfig)['PeImage'] }
    $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'

    $what = 'Use the legacy JScript engine for mshta'
    if ($Remove) { $what = 'Go back to the modern JScript engine' }
    if (-not $PSCmdlet.ShouldProcess($BootImagePath, $what)) { return }

    $undo = [bool]$Remove

    Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -Body {
        param($peMount)

        Invoke-WfRegistryEdit -MountPath $peMount -Action {
            param($keys)

            if (-not $keys.ContainsKey('Software')) {
                throw 'The SOFTWARE hive did not load, so the script engine cannot be set.'
            }

            $main = Join-WfPath $keys.Software 'Microsoft\Internet Explorer\Main'
            $feat = Join-WfPath $main 'FeatureControl\FEATURE_USE_LEGACY_JSCRIPT'

            if ($undo) {
                foreach ($p in @(@{ Path = $main; Name = 'JscriptReplacement' },
                                 @{ Path = $feat; Name = 'mshta.exe' })) {
                    if (Test-Path -LiteralPath $p.Path) {
                        Remove-ItemProperty -LiteralPath $p.Path -Name $p.Name -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-WfLog '  the legacy engine settings are gone' -Level OK
                return
            }

            foreach ($p in @($main, $feat)) {
                if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
            }

            New-ItemProperty -LiteralPath $main -Name 'JscriptReplacement' -Value 0 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -LiteralPath $feat -Name 'mshta.exe'          -Value 1 -PropertyType DWord -Force | Out-Null
            Write-WfLog '  mshta will use the legacy JScript engine' -Level OK
        }
    } | Out-Null

    if ($undo) {
        Write-WfLog 'This boot image is back on the modern JScript engine. An HTA written for the old one may stop working.' -Level WARN
    }
    else {
        Write-WfLog 'HTAs in this boot image will run on the engine they were written for.' -Level OK
        Write-WfLog '  Microsoft changed the engine in the ADK for Windows 11 22H2, and the symptom is "An error has occurred in the script on this page" with nothing else to go on.' -Level INFO
    }

    Write-WfHistory -Action 'PE JScript engine' -ImagePath $BootImagePath -Detail @{
        Index = $Index; Legacy = (-not $undo)
    } | Out-Null

    return [pscustomobject]@{ BootImage = $BootImagePath; Index = $Index; Legacy = (-not $undo) }
}

function Add-WfPeTool {
<#
.SYNOPSIS
    Puts your own software inside a boot image, and checks it can actually run.
.DESCRIPTION
    Copies a folder into \Windows\Tools\<Name> in the image, so the terminal sees
    it at %SystemRoot%\Tools\<Name> whatever letter WinPE gives itself.

    Three things are checked before anything is copied, because all three fail
    silently on the terminal rather than loudly here:

      .msi        Windows PE does not support ".MSI installation files" -- there
                  is no Windows Installer service to run one. An installer in the
                  folder is refused rather than copied to no purpose.

      architecture Every binary's machine type is read out of its PE header and
                  compared with the image. Microsoft: PE does not support
                  "running 32-bit apps on the 64-bit version of Windows PE", and
                  there is no WoW64 component to change that. A 32-bit tool in an
                  amd64 boot image produces a terminal where the command returns
                  instantly and does nothing.

      size        Reported, loudly. The image boots into RAM, so the tool's size
                  is a memory cost on every machine. Over the threshold this says
                  so and suggests carrying it on the media instead, which
                  New-WfPeStartnet -PayloadFolder is built for.

    Not everything worth putting in here is an .exe. An HTA is a few kilobytes of
    HTML and gives a deployment console a real front end; a .cmd is the most
    portable thing there is. Those are started differently -- an HTA through
    mshta.exe, a .cmd through call -- and each needs something in the image
    before it can run at all. Get-WfPeLaunchCommand works out which, the
    optional component it depends on is checked while the image is open, and an
    HTA additionally gets the registry fix that stops modern boot images
    answering it with "An error has occurred in the script on this page".

    A small manifest goes in beside the tools, and New-WfPeStartnet reads it --
    so the thing that launches your software gets its path from what is actually
    in the image rather than from something typed twice.
.PARAMETER Source
    A folder to copy, or a single file.
.PARAMETER Name
    What it is called inside the image. Defaults to the source folder's name.
.PARAMETER Command
    What to run, relative to the tool's folder -- 'Diag.exe', 'bin\tool.exe',
    'menu.hta', 'run.cmd'. Recorded in the manifest so New-WfPeStartnet can
    launch it the right way. Optional: a tool that is only ever run by hand at
    the PE prompt does not need one.
.PARAMETER Arguments
    Arguments for that command, recorded with it.
.PARAMETER WarnAboveMB
    The size that earns a warning. 64MB by default -- the point at which it is
    worth asking whether this belongs on the media instead.
.PARAMETER AllowMismatch
    Copy binaries of the wrong architecture anyway. There is no supported way to
    make them run; this exists only for a folder whose stray 32-bit helper is
    genuinely never invoked.
.PARAMETER SkipJScriptFix
    Do not apply the legacy JScript registry fix when the entry point is an HTA.
    Only for an HTA written against the new engine.
.PARAMETER Force
    Replace a tool of the same name already in the image.
.EXAMPLE
    Add-WfPeTool -Source D:\Tools\HardwareDiag -Command Diag.exe -BootImagePath C:\Imaging\Pe\boot.wim
.EXAMPLE
    Add-WfPeTool -Source D:\Tools\DeployMenu -Command menu.hta -Name Menu
.EXAMPLE
    Add-WfPeTool -Source D:\Tools\vendor-flash.exe -Name Flash -Command vendor-flash.exe -Arguments '/silent'
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [string] $Name,
        [string] $Command,
        [string] $Arguments,
        [string] $BootImagePath,
        [int]    $Index = 1,
        [int]    $WarnAboveMB = 64,
        [switch] $AllowMismatch,
        [switch] $SkipJScriptFix,
        [switch] $Force
    )

    Assert-WfElevated
    if (-not $BootImagePath) { $BootImagePath = (Get-WfConfig)['PeImage'] }
    $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'
    $Source        = Assert-WfPath -Path $Source -Label 'Tool source'

    $sourceItem = Get-Item -LiteralPath $Source
    $isFile     = -not $sourceItem.PSIsContainer
    if (-not $Name) {
        $Name = $sourceItem.BaseName
        if (-not $isFile) { $Name = $sourceItem.Name }
    }
    $Name = Get-WfSafeName $Name

    # What architecture is this image, so the binaries can be judged against it.
    $imageArch = ''
    try {
        $info = @(Get-WindowsImage -ImagePath $BootImagePath -Index $Index -ErrorAction Stop)[0]
        $imageArch = ConvertFrom-WfImageArchitecture $info.Architecture
    }
    catch {
        Write-WfLog "Could not read the boot image's architecture, so the binaries are not checked against it: $($_.Exception.Message)" -Level WARN
    }

    $files = @()
    if ($isFile) { $files = @($sourceItem) }
    else         { $files = @(Get-ChildItem -LiteralPath $Source -File -Recurse) }

    if ($files.Count -eq 0) { throw "$Source has no files in it." }

    # ------------------------------------------------------------------ .msi
    $installers = @($files | Where-Object { $_.Extension -match '(?i)^\.(msi|msp|msix|appx)$' })
    if ($installers.Count -gt 0 -and -not $Force) {
        throw (("{0} contains {1} installer package(s), starting with {2}. Windows PE does not support .MSI installation files -- " +
                "there is no Windows Installer service in it, so nothing would ever install them. Software goes into PE as files: " +
                "extract the installer's payload, or use the portable build. -Force copies them anyway if you have a reason.") -f `
                $Source, $installers.Count, $installers[0].Name)
    }

    # ---------------------------------------------------------- architecture
    $binaries = @($files | Where-Object { $_.Extension -match '(?i)^\.(exe|dll|sys|com|ocx|cpl|scr)$' })
    $arches   = New-Object System.Collections.Generic.List[object]
    foreach ($b in $binaries) {
        $a = Get-WfPeBinaryArchitecture -Path $b.FullName
        if ($a) { $arches.Add([pscustomobject]@{ File = $b.Name; Architecture = $a }) }
    }

    $wrong = @()
    if ($imageArch) { $wrong = @($arches | Where-Object { $_.Architecture -ne $imageArch }) }

    if ($wrong.Count -gt 0) {
        $summary = (@($wrong | Select-Object -First 4 | ForEach-Object { "{0} ({1})" -f $_.File, $_.Architecture }) -join ', ')
        if (-not $AllowMismatch) {
            throw (("{0} binary(ies) here are not {1}: {2}. Windows PE cannot run apps compiled for a different architecture -- " +
                    "there is no WoW64 in it, and a 32-bit tool in an {1} boot image returns instantly and does nothing. " +
                    "Use the {1} build of this tool, or -AllowMismatch if the offending files are genuinely never invoked.") -f `
                    $wrong.Count, $imageArch, $summary)
        }
        Write-WfLog ("{0} binary(ies) are not {1} and cannot run in this PE: {2}" -f $wrong.Count, $imageArch, $summary) -Level WARN
    }

    # ------------------------------------------------------------------ size
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    $mb = [math]::Round($bytes / 1MB, 1)

    Write-WfLog ("{0}: {1} file(s), {2}" -f $Name, $files.Count, (Format-WfSize $bytes)) -Level INFO
    if ($mb -gt $WarnAboveMB) {
        Write-WfLog ("That is {0}MB going INTO the boot image, and a PE booted from memory needs all of it in contiguous RAM on every terminal." -f $mb) -Level WARN
        Write-WfLog '  For anything this size, carrying it on the media is usually better: New-WfPeStartnet -PayloadFolder finds a folder at run time and costs the boot image nothing.' -Level WARN
    }

    # --------------------------------------------------------------- command
    $launch = $null
    if ($Command) {
        $probe = $Command -replace '^[\\/]+', ''
        $hit = @($files | Where-Object {
            $rel = $_.FullName
            if (-not $isFile) { $rel = $_.FullName.Substring($Source.Length).TrimStart('\', '/') }
            else              { $rel = $_.Name }
            $rel -eq $probe -or $_.Name -eq $probe
        })
        if ($hit.Count -eq 0) {
            throw ("-Command '{0}' is not in {1}. It is a path relative to the tool folder, e.g. 'Diag.exe', 'menu.hta' or 'bin\Diag.exe'." -f $Command, $Source)
        }

        # How this actually gets started, and what has to be in the image for it
        # to start at all.
        $launch = Get-WfPeLaunchCommand -Command $Command `
                      -Path ('%SystemRoot%\Tools\{0}\{1}' -f $Name, $Command) -Arguments $Arguments

        if ($launch.Kind -eq 'Unsupported') {
            throw ("-Command '{0}' is not something WinPE can start. {1}" -f $Command, $launch.Note)
        }

        Write-WfLog ("Entry point: {0}, started as  {1}" -f $launch.Kind, $launch.Line) -Level INFO
        if ($launch.Note) { Write-WfLog ("  {0}" -f $launch.Note) -Level INFO }
    }

    if (-not $PSCmdlet.ShouldProcess($BootImagePath, ("Add the tool {0}" -f $Name))) { return }

    $manifestEntry = [pscustomobject]@{
        Name      = $Name
        Command   = $Command
        Arguments = $Arguments
        Kind      = $(if ($launch) { $launch.Kind } else { '' })
        Requires  = $(if ($launch) { $launch.Requires } else { '' })
        Files     = $files.Count
        SizeBytes = $bytes
        AddedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }

    # Filled while the image is open, checked after it closes -- a warning
    # printed in the middle of a mount is a warning scrolled past.
    $missingOc = ''

    Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -Body {
        param($peMount)

        $toolsDir = Join-WfPath $peMount 'Windows\Tools'
        $dest     = Join-WfPath $toolsDir $Name

        if (Test-Path -LiteralPath $dest) {
            if (-not $Force) {
                throw ("{0} is already in this boot image. Use -Force to replace it." -f $Name)
            }
            Write-WfLog "Replacing the $Name already in the image" -Level WARN
            Remove-Item -LiteralPath $dest -Recurse -Force
        }

        New-WfDirectory $dest | Out-Null

        if ($isFile) {
            Copy-Item -LiteralPath $Source -Destination (Join-WfPath $dest $sourceItem.Name) -Force
        }
        else {
            Copy-Item -LiteralPath (Join-WfPath $Source '*') -Destination $dest -Recurse -Force
        }
        Write-WfLog ("Copied to Windows\Tools\{0}" -f $Name) -Level OK

        # The manifest, merged rather than replaced -- a second tool must not
        # erase the first one's entry.
        $mfPath = Join-WfPath $toolsDir '_tools.json'
        $all = @()
        if (Test-Path -LiteralPath $mfPath) {
            try { $all = @(Get-Content -LiteralPath $mfPath -Raw | ConvertFrom-Json) } catch { $all = @() }
        }
        $all = @($all | Where-Object { $_ -and $_.Name -ne $Name })
        $all += $manifestEntry

        ,$all | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $mfPath -Encoding UTF8
        Write-WfLog ("{0} tool(s) in this boot image" -f $all.Count) -Level INFO

        # Asked while the image is already open, because the answer is free here
        # and costs a second mount anywhere else. An HTA in an image with no
        # WinPE-HTA is a few kilobytes of HTML that can never run, and nothing
        # about the image looks wrong.
        if ($launch -and $launch.Requires) {
            $has = $false
            try {
                $has = @(Get-WindowsPackage -Path $peMount -ErrorAction Stop |
                         Where-Object { "$($_.PackageName)" -match [regex]::Escape($launch.Requires) }).Count -gt 0
            }
            catch {
                Write-WfLog ("Could not list this image's packages, so {0} is not checked for: {1}" -f $launch.Requires, $_.Exception.Message) -Level WARN
            }
            if (-not $has) { $script:WfPeMissingOc = $launch.Requires }
            else           { $script:WfPeMissingOc = '' }
        }
        else { $script:WfPeMissingOc = '' }
    } | Out-Null

    # A scriptblock writes to its own scope, so the check above reports back
    # through a module variable rather than by assigning $missingOc directly --
    # that assignment would set a local that vanishes with the block.
    $missingOc = "$script:WfPeMissingOc"

    $size = (Get-Item -LiteralPath $BootImagePath).Length
    Write-WfLog ("Boot image is now {0}" -f (Format-WfSize $size)) -Level INFO

    # ------------------------------------------------------------ the HTA fix
    #
    # Done here rather than left to the operator, because the failure it prevents
    # names neither the ADK nor the script engine: an HTA that worked for years
    # comes up with "An error has occurred in the script on this page" and there
    # is nothing else to go on.
    $jscriptFixed = $false
    if ($launch -and $launch.Kind -eq 'Hta' -and -not $SkipJScriptFix) {
        Write-WfLog 'This is an HTA, so the legacy JScript engine is turned on for mshta' -Level STEP
        Write-WfLog '  Microsoft replaced the engine in the ADK for Windows 11 22H2, and HTAs written for the old one stop working with a message that explains nothing.' -Level INFO
        try {
            Enable-WfPeLegacyJScript -BootImagePath $BootImagePath -Index $Index -Confirm:$false | Out-Null
            $jscriptFixed = $true
        }
        catch {
            Write-WfLog ("The JScript fix failed: {0}" -f $_.Exception.Message) -Level ERROR
            Write-WfLog '  Enable-WfPeLegacyJScript on its own will do it. Without it the HTA may open and immediately report a script error.' -Level WARN
        }
    }

    if ($missingOc) {
        Write-WfLog ("{0} needs {1}, and this boot image does not have it -- the tool is in there and cannot start." -f $Command, $missingOc) -Level WARN
        Write-WfLog ("  Add-WfPeOptionalComponent -Component {0} -BootImagePath '{1}' puts it in, with its dependencies." -f $missingOc, $BootImagePath) -Level WARN
    }

    if ($Command) {
        Write-WfLog ("New-WfPeStartnet will launch it as:  {0}" -f $launch.Line) -Level INFO
    }
    else {
        Write-WfLog 'No -Command given, so nothing launches it -- it is there to run by hand from the PE prompt.' -Level INFO
    }

    Write-WfHistory -Action 'PE tool' -ImagePath $BootImagePath -Detail @{
        Index = $Index; Name = $Name; Source = $Source; Files = $files.Count
        SizeBytes = $bytes; Command = $Command; SizeAfter = $size
        Kind = $(if ($launch) { $launch.Kind } else { '' }); MissingComponent = $missingOc
        JScriptFix = $jscriptFixed
    } | Out-Null

    return [pscustomobject]@{
        BootImage    = $BootImagePath
        Name         = $Name
        Files        = $files.Count
        SizeMB       = $mb
        Command      = $Command
        Kind         = $(if ($launch) { $launch.Kind } else { '' })
        LaunchLine   = $(if ($launch) { $launch.Line } else { '' })
        Requires     = $(if ($launch) { $launch.Requires } else { '' })
        MissingComponent = $missingOc
        JScriptFix   = $jscriptFixed
        Architecture = $imageArch
        Mismatched   = @($wrong | ForEach-Object { $_.File })
        ImageSize    = $size
    }
}

function Get-WfPeTool {
<#
.SYNOPSIS
    What your own software looks like inside a boot image.
.DESCRIPTION
    Reads the manifest Add-WfPeTool leaves behind. Mounts read-only, so it is
    safe to run against an image somebody else built.
.EXAMPLE
    Get-WfPeTool -BootImagePath C:\Imaging\Pe\boot.wim
#>
    [CmdletBinding()]
    param(
        [string] $BootImagePath,
        [int]    $Index = 1
    )

    Assert-WfElevated
    if (-not $BootImagePath) { $BootImagePath = (Get-WfConfig)['PeImage'] }
    $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'

    $tools = Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -ReadOnly -Body {
        param($peMount)

        $mfPath = Join-WfPath $peMount 'Windows\Tools\_tools.json'
        if (-not (Test-Path -LiteralPath $mfPath)) { return @() }
        try   { return @(Get-Content -LiteralPath $mfPath -Raw | ConvertFrom-Json) }
        catch { return @() }
    }

    $tools = @($tools | Where-Object { $_ })
    if ($tools.Count -eq 0) {
        Write-WfLog 'No WimForge tools in this boot image.' -Level INFO
    }
    else {
        Write-WfLog ("{0} tool(s)" -f $tools.Count) -Level OK
    }

    return @($tools | ForEach-Object {
        # Kind and Requires are re-derived rather than trusted from the manifest.
        # An image written by an older build has neither field, and a tool whose
        # launch rule silently came back empty is a tool that does not start.
        $k = $null
        if ($_.Command) {
            $k = Get-WfPeLaunchCommand -Command $_.Command `
                     -Path ('%SystemRoot%\Tools\{0}\{1}' -f $_.Name, $_.Command) -Arguments $_.Arguments
        }

        [pscustomobject]@{
            Name      = $_.Name
            Command   = $_.Command
            Arguments = $_.Arguments
            Kind      = $(if ($k) { $k.Kind } else { '' })
            Requires  = $(if ($k) { $k.Requires } else { '' })
            Launch    = $(if ($k) { $k.Line } else { '' })
            Files     = $_.Files
            SizeMB    = [math]::Round(([double]$_.SizeBytes) / 1MB, 1)
            Path      = ('%SystemRoot%\Tools\{0}' -f $_.Name)
        }
    })
}

function New-WfPeStartnet {
<#
.SYNOPSIS
    Builds the startnet.cmd that runs when WinPE starts.
.DESCRIPTION
    One place that assembles the boot script, instead of three that each write
    their own and quietly disagree.

    wpeinit always comes first and cannot be moved. Microsoft: "Startnet.cmd
    starts Wpeinit.exe. Wpeinit.exe installs Plug and Play devices, processes
    Unattend.xml settings, and loads network resources." Anything above that line
    runs on a machine with no drivers bound and no network -- which looks exactly
    like a broken script rather than a script run too early.

    After that, in order: the tools inside the image, the payload on the media,
    the region question, and whatever raw lines you supply.

    Batch, not PowerShell. PowerShell is in WinPE only if somebody added the
    optional component, and a boot script that needs one is a boot script that
    fails on the boot.wim nobody prepared. Add-WfPeOptionalComponent can put
    PowerShell in if you want it, but startnet itself does not assume it.
.PARAMETER BootImagePath
    Write the script into this boot image. Omit to only return the lines.
.PARAMETER Tool
    Names of tools to launch, from Add-WfPeTool. Omit with -AllTools to launch
    every tool in the image that recorded a command.
.PARAMETER AllTools
    Launch every tool in the image's manifest that has a command.
.PARAMETER PayloadFolder
    A folder to look for on every volume at run time -- 'Tools\Diagnostics'. This
    is how large software should travel: it lives on the USB stick or the
    deployment share and costs the boot image nothing, which matters because the
    boot image has to fit in RAM. Found by searching, not assumed, since WinPE
    drive letters "change each time you boot".
.PARAMETER PayloadCommand
    What to run inside that folder once it is found.
.PARAMETER RegionScript
    A region fragment from New-WfRegionPeScript to call, by file name. It is
    looked for beside the payload and on every volume.
.PARAMETER Line
    Raw batch lines, appended last.
.PARAMETER Prompt
    Leave a command prompt open at the end. On by default: a deployment console
    that closes and reboots the moment a tool exits gives nobody a chance to read
    what it said.
.PARAMETER Title
    What the script prints at the top. The estate's name is usually right.
.EXAMPLE
    New-WfPeStartnet -BootImagePath C:\Imaging\Pe\boot.wim -AllTools
.EXAMPLE
    New-WfPeStartnet -PayloadFolder 'WimForge\Tools' -PayloadCommand 'menu.cmd' -Path C:\Imaging\Pe\startnet.cmd
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]   $BootImagePath,
        [int]      $Index = 1,
        [string[]] $Tool,
        [switch]   $AllTools,
        [string]   $PayloadFolder,
        [string]   $PayloadCommand,
        [string]   $RegionScript,
        [string[]] $Line,
        [string]   $Title = 'WimForge',
        [string]   $Path,
        [switch]   $NoPrompt
    )

    # The tools come out of the image when there is one, so what gets launched is
    # what is actually in there.
    $manifest = @()
    if ($BootImagePath -and ($AllTools -or $Tool)) {
        $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'
        $manifest = @(Get-WfPeTool -BootImagePath $BootImagePath -Index $Index)
    }

    $launch = @()
    if ($AllTools) {
        $launch = @($manifest | Where-Object { $_.Command })
        $silent = @($manifest | Where-Object { -not $_.Command })
        if ($silent.Count -gt 0) {
            Write-WfLog ("Not launched, because they recorded no command: {0}" -f (@($silent | ForEach-Object { $_.Name }) -join ', ')) -Level INFO
        }
    }
    elseif ($Tool) {
        foreach ($t in $Tool) {
            $hit = @($manifest | Where-Object { $_.Name -eq $t })
            if ($hit.Count -eq 0) {
                throw ("There is no tool called {0} in this boot image. It has: {1}." -f `
                       $t, (@($manifest | ForEach-Object { $_.Name }) -join ', '))
            }
            if (-not $hit[0].Command) {
                throw ("{0} recorded no command when it was added, so there is nothing to launch. Re-add it with -Command." -f $t)
            }
            $launch += $hit[0]
        }
    }

    $cmd = New-Object System.Collections.Generic.List[string]
    $cmd.Add('@echo off')
    $cmd.Add('rem WimForge startnet.cmd. Generated -- rebuild it, do not edit it here.')
    $cmd.Add('')
    # Not negotiable and not reorderable. Everything below this line has drivers
    # and a network; everything above it has neither.
    $cmd.Add('rem wpeinit installs Plug and Play devices, processes Unattend.xml and')
    $cmd.Add('rem brings up the network. Nothing useful happens before it.')
    $cmd.Add('wpeinit')
    $cmd.Add('')
    $cmd.Add('cls')
    $cmd.Add('echo.')
    $cmd.Add(('echo   {0}' -f ($Title -replace '[<>|&^()]', ' ')))
    $cmd.Add(('echo   {0}' -f ('=' * [math]::Min(60, ("$Title").Length))))
    $cmd.Add('echo.')

    foreach ($t in $launch) {
        $exe = ('%SystemRoot%\Tools\{0}\{1}' -f $t.Name, $t.Command)

        # How it is started depends on what it is. An .exe runs; a .cmd is
        # called; an HTA goes through mshta.exe rather than through a file
        # association that no Microsoft documentation promises exists.
        $how = Get-WfPeLaunchCommand -Command $t.Command -Path $exe -Arguments $t.Arguments
        if ($how.Kind -eq 'Unsupported') {
            Write-WfLog ("{0} is not something WinPE can start, so it is left out of startnet.cmd. {1}" -f $t.Name, $how.Note) -Level WARN
            continue
        }
        if ($how.Requires) {
            Write-WfLog ("{0} is {1} and needs {2} in the boot image. Get-WfPeReport says whether it is there." -f $t.Name, $how.Kind, $how.Requires) -Level INFO
        }

        $cmd.Add('')
        $cmd.Add(('rem --- {0} ({1}), from inside the boot image' -f $t.Name, $how.Kind))
        $cmd.Add(('if not exist "{0}" (' -f $exe))
        $cmd.Add(('    echo   {0} is not in this boot image after all -- skipped.' -f $t.Name))
        $cmd.Add(') else (')
        $cmd.Add(('    echo   Running {0}' -f $t.Name))
        $cmd.Add(('    {0}' -f $how.Line))
        $cmd.Add(')')
    }

    if ($PayloadFolder) {
        $cmd.Add('')
        $cmd.Add(('rem --- {0} on the media, rather than inside the image' -f $PayloadFolder))
        # Letters are found, never assumed: "WinPE drive letter assignments
        # change each time you boot, and can change depending on which hardware
        # is detected". X: is skipped -- that is the RAM disk this is running on.
        $cmd.Add('set WF_PAYLOAD=')
        $cmd.Add('for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (')
        $cmd.Add(('    if exist %%d:\{0}\ set WF_PAYLOAD=%%d:\{0}' -f $PayloadFolder))
        $cmd.Add(')')
        $cmd.Add('if "%WF_PAYLOAD%"=="" (')
        $cmd.Add(('    echo   \{0} was not found on any volume.' -f $PayloadFolder))
        $cmd.Add('    echo   Is the stick still plugged in, and did wpeinit find its controller?')
        $cmd.Add(') else (')
        $cmd.Add('    echo   Found the payload at %WF_PAYLOAD%')
        if ($PayloadCommand) {
            $cmd.Add(('    if exist "%WF_PAYLOAD%\{0}" (' -f $PayloadCommand))
            $cmd.Add(('        call "%WF_PAYLOAD%\{0}"' -f $PayloadCommand))
            $cmd.Add('    ) else (')
            $cmd.Add(('        echo   but {0} is not in it.' -f $PayloadCommand))
            $cmd.Add('    )')
        }
        $cmd.Add(')')
    }

    if ($RegionScript) {
        $cmd.Add('')
        $cmd.Add('rem --- which country is this machine for')
        $cmd.Add('set WF_REGIONCMD=')
        $cmd.Add('if not "%WF_PAYLOAD%"=="" (')
        $cmd.Add(('    if exist "%WF_PAYLOAD%\{0}" set WF_REGIONCMD=%WF_PAYLOAD%\{0}' -f $RegionScript))
        $cmd.Add(')')
        $cmd.Add('for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (')
        $cmd.Add(('    if exist %%d:\{0} if "%WF_REGIONCMD%"=="" set WF_REGIONCMD=%%d:\{0}' -f $RegionScript))
        $cmd.Add(')')
        $cmd.Add('if "%WF_REGIONCMD%"=="" (')
        $cmd.Add(('    echo   {0} was not found, so the image default region stands.' -f $RegionScript))
        $cmd.Add(') else (')
        $cmd.Add('    call "%WF_REGIONCMD%"')
        $cmd.Add(')')
    }

    foreach ($l in @($Line)) {
        if (-not $l) { continue }
        $cmd.Add('')
        $cmd.Add($l)
    }

    $cmd.Add('')
    if ($NoPrompt) {
        $cmd.Add('rem No prompt: this boot does its work and stops. Whatever it printed is gone')
        $cmd.Add('rem the moment the machine restarts, so log to the media, not to the screen.')
        $cmd.Add('goto :eof')
    }
    else {
        $cmd.Add('echo.')
        $cmd.Add('echo   Type exit to restart.')
        $cmd.Add('cmd /k')
    }

    $written = ''

    if ($Path) {
        if ($PSCmdlet.ShouldProcess($Path, 'Write startnet.cmd')) {
            New-WfDirectory (Split-Path $Path -Parent) | Out-Null
            # ASCII, no BOM. The command processor reads this before any code
            # page is set, and a BOM on line one stops @echo off working.
            Set-Content -LiteralPath $Path -Value $cmd -Encoding Ascii -Force
            Write-WfLog ("startnet.cmd written to {0}, {1} line(s)" -f $Path, $cmd.Count) -Level OK
            $written = $Path
        }
    }

    if ($BootImagePath) {
        $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'
        if ($PSCmdlet.ShouldProcess($BootImagePath, 'Write startnet.cmd into the boot image')) {
            Assert-WfElevated
            Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -Body {
                param($peMount)
                $target = Join-WfPath $peMount 'Windows\System32\startnet.cmd'
                Set-Content -LiteralPath $target -Value $cmd -Encoding Ascii -Force
                Write-WfLog ("startnet.cmd written into the image, {0} line(s)" -f $cmd.Count) -Level OK
            } | Out-Null
            $written = $BootImagePath

            Write-WfHistory -Action 'PE startnet' -ImagePath $BootImagePath -Detail @{
                Index = $Index
                Tools = (@($launch | ForEach-Object { $_.Name }) -join ', ')
                PayloadFolder = $PayloadFolder; RegionScript = $RegionScript
                Lines = $cmd.Count
            } | Out-Null
        }
    }

    if (-not $Path -and -not $BootImagePath) {
        Write-WfLog ("{0} line(s) built. Nothing was written -- give -Path or -BootImagePath." -f $cmd.Count) -Level INFO
    }

    return [pscustomobject]@{
        Lines         = $cmd.ToArray()
        Written       = $written
        Tools         = @($launch | ForEach-Object { $_.Name })
        PayloadFolder = $PayloadFolder
        RegionScript  = $RegionScript
    }
}

function Set-WfPeShell {
<#
.SYNOPSIS
    Replaces the WinPE command prompt with your own application.
.DESCRIPTION
    For a deployment console that should look like a product rather than like a
    command window. winpeshl.ini is Microsoft's mechanism: "Use the Winpeshl.ini
    file in Windows Preinstallation Environment (Windows PE) to replace the
    default command prompt with a shell application or other app."

    There is a trap in it that Microsoft does not document, and this works around
    it rather than repeating it. Replacing the shell means startnet.cmd is out of
    the picture -- and startnet.cmd is what runs wpeinit, which is what installs
    Plug and Play devices and brings up the network. An application launched
    straight from winpeshl.ini therefore starts on a machine with no drivers
    bound and no network, which presents as the application being broken.

    So this does not point winpeshl.ini at your application. It points it at a
    small generated wrapper that runs wpeinit first and then your application.
    The behaviour is the same and the machine actually works.

    Two details of the file format that Microsoft DOES document, and that decide
    how this is written:

      "[LaunchApp] ... You can't specifiy any command-line options with
      LaunchApp." (their typo). So [LaunchApps] is used instead, which is the
      section that takes arguments: "To add command-line options to an app: add
      a comma (,) after the app name".

      That matters more than it looks, because the wrapper is a .cmd and a .cmd
      is not an executable -- it is input to one. So the entry is cmd.exe with
      the wrapper as its argument, rather than the wrapper on its own and a hope
      that something expands it.

    Worth knowing before choosing this: when the app exits there is no prompt to
    fall back to, and Microsoft's own guidance is that "Windows PE will reboot
    when that command prompt exits". The apps listed "run in order of appearance,
    and don't start until the previous app has terminated"; nothing is documented
    about what happens after the last one. So the wrapper ends with a prompt
    unless you ask it not to.

    An HTA works here as well as an .exe -- it is started through mshta.exe, and
    Add-WfPeTool will have put WinPE-HTA's registry fix in already.
.PARAMETER Command
    The application to run, as the terminal will see it, e.g.
    '%SystemRoot%\Tools\Console\Console.exe' or
    '%SystemRoot%\Tools\Menu\menu.hta'.
.PARAMETER Arguments
    Arguments for it.
.PARAMETER FallBackToPrompt
    Leave a command prompt when the application exits, instead of nothing. On by
    default -- a deployment console that vanishes leaves a technician with a
    blank screen and no way to find out why.
.PARAMETER Remove
    Take winpeshl.ini out again and go back to the normal startnet.cmd prompt.
.EXAMPLE
    Set-WfPeShell -Command '%SystemRoot%\Tools\Console\Console.exe' -BootImagePath C:\Imaging\Pe\boot.wim
.EXAMPLE
    Set-WfPeShell -Remove
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Command,
        [string] $Arguments,
        [string] $BootImagePath,
        [int]    $Index = 1,
        [switch] $NoFallBackToPrompt,
        [switch] $Remove
    )

    Assert-WfElevated
    if (-not $BootImagePath) { $BootImagePath = (Get-WfConfig)['PeImage'] }
    $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'

    if (-not $Remove -and -not $Command) { throw 'Supply -Command, or -Remove to put the normal prompt back.' }

    if ($Remove) {
        if (-not $PSCmdlet.ShouldProcess($BootImagePath, 'Remove winpeshl.ini')) { return }

        Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -Body {
            param($peMount)
            foreach ($leaf in @('winpeshl.ini', 'wfshell.cmd')) {
                $p = Join-WfPath $peMount ('Windows\System32\' + $leaf)
                if (Test-Path -LiteralPath $p) {
                    Remove-Item -LiteralPath $p -Force
                    Write-WfLog "Removed $leaf" -Level OK
                }
            }
        } | Out-Null

        Write-WfLog 'This PE goes back to startnet.cmd and the command prompt.' -Level OK
        return [pscustomobject]@{ BootImage = $BootImagePath; Shell = ''; Removed = $true }
    }

    # Started the way its own file type requires. An HTA here is the common case
    # and the one that would silently do nothing if it were run as if it were an
    # executable.
    $how = Get-WfPeLaunchCommand -Command $Command -Path $Command -Arguments $Arguments
    if ($how.Kind -eq 'Unsupported') {
        throw ("{0} is not something WinPE can start as a shell. {1}" -f $Command, $how.Note)
    }
    if ($how.Requires) {
        Write-WfLog ("This shell is {0} and needs {1} in the boot image, or it will not start." -f $how.Kind, $how.Requires) -Level WARN
        Write-WfLog ("  Add-WfPeOptionalComponent -Component {0} puts it in. Get-WfPeReport says whether it is already there." -f $how.Requires) -Level INFO
    }

    # The wrapper. This is the whole point of the function.
    $wrapper = New-Object System.Collections.Generic.List[string]
    $wrapper.Add('@echo off')
    $wrapper.Add('rem WimForge shell wrapper. Generated.')
    $wrapper.Add('rem')
    $wrapper.Add('rem winpeshl.ini replaces the command prompt, which means startnet.cmd')
    $wrapper.Add('rem does not run -- and startnet.cmd is what calls wpeinit. Without this')
    $wrapper.Add('rem line the application below starts with no Plug and Play devices')
    $wrapper.Add('rem installed and no network, and looks broken for reasons that have')
    $wrapper.Add('rem nothing to do with the application.')
    $wrapper.Add('wpeinit')
    $wrapper.Add('')
    $wrapper.Add(('rem started as {0}' -f $how.Kind))
    $wrapper.Add($how.Line)
    $wrapper.Add('')
    if ($NoFallBackToPrompt) {
        $wrapper.Add('rem No fallback. Microsoft: "Windows PE will reboot when that command')
        $wrapper.Add('rem prompt exits" -- so this machine restarts the moment the app closes.')
        $wrapper.Add('goto :eof')
    }
    else {
        $wrapper.Add('echo.')
        $wrapper.Add('echo   The application has exited. Type exit to restart.')
        $wrapper.Add('cmd /k')
    }

    # [LaunchApps], not [LaunchApp]: the wrapper is a .cmd, which is not an
    # executable but input to one, so the entry has to be cmd.exe with the
    # wrapper as an argument -- and Microsoft is explicit that "you can't
    # specifiy any command-line options with LaunchApp".
    $ini = @(
        '[LaunchApps]'
        '%SystemRoot%\System32\cmd.exe, /c %SystemRoot%\System32\wfshell.cmd'
    )

    if (-not $PSCmdlet.ShouldProcess($BootImagePath, "Make $Command the shell")) { return }

    Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -Body {
        param($peMount)
        $sys = Join-WfPath $peMount 'Windows\System32'
        Set-Content -LiteralPath (Join-WfPath $sys 'wfshell.cmd')  -Value $wrapper -Encoding Ascii -Force
        Set-Content -LiteralPath (Join-WfPath $sys 'winpeshl.ini') -Value $ini     -Encoding Ascii -Force
        Write-WfLog 'winpeshl.ini and its wrapper written' -Level OK
    } | Out-Null

    Write-WfLog ("This PE now starts {0} instead of a command prompt." -f $Command) -Level OK
    Write-WfLog '  wpeinit runs first, from the wrapper, so drivers and network are up before it launches.' -Level INFO

    Write-WfHistory -Action 'PE shell' -ImagePath $BootImagePath -Detail @{
        Index = $Index; Command = $Command; Arguments = $Arguments
        Kind = $how.Kind; Requires = $how.Requires
        FallBack = (-not $NoFallBackToPrompt)
    } | Out-Null

    return [pscustomobject]@{
        BootImage = $BootImagePath
        Shell     = $Command
        Kind      = $how.Kind
        Requires  = $how.Requires
        Wrapper   = 'Windows\System32\wfshell.cmd'
        Ini       = $ini
        Lines     = $wrapper.ToArray()
    }
}

function New-WfPeMenuHta {
<#
.SYNOPSIS
    Generates a working WinPE menu as an HTA, for a deployment console with
    buttons instead of a command prompt.
.DESCRIPTION
    A starting point that is known to run, which matters more here than it
    normally would: an HTA in WinPE has two documented ways to fail before your
    own HTML is even in question, and debugging your first one against an
    untested pipeline means not knowing which of the three things is wrong.

    So this produces something small and complete. Put it in with Add-WfPeTool,
    point startnet.cmd or the shell at it, boot it once, and from then on you are
    editing HTML against a path you know works.

    Written in VBScript rather than JScript, deliberately. Microsoft replaced the
    JScript engine in the ADK for Windows 11 22H2, and HTAs written for the old
    one answer with "An error has occurred in the script on this page" and
    nothing else. Add-WfPeTool puts the registry fix in for that -- but a sample
    whose whole job is to work on the first boot should not need the fix to be
    right. VBScript sidesteps the question entirely.

    (VBScript is on Microsoft's deprecation list for Windows itself. In a boot
    image, with WinPE-Scripting present, it works today and is what MDT's own
    wizard was written in. Worth knowing, not worth avoiding here.)

    The buttons run commands through WScript.Shell, which comes with
    WinPE-Scripting -- and WinPE-HTA depends on WinPE-Scripting anyway, so an
    image that can show this can also run what it launches.
.PARAMETER Title
    The window title and the heading.
.PARAMETER Item
    The buttons. Each is a hashtable with Label, Command, and optionally Hint:

        @{ Label = 'Deploy -- Netherlands'; Command = 'X:\deploy.cmd NL'; Hint = 'Applies the image and records the region.' }

    The command runs synchronously in a visible window, so whoever is standing
    there can see it work and see it fail.
.PARAMETER Width
    Window width in pixels. 640 by default -- WinPE screens are frequently
    1024x768 and a window wider than the screen cannot be moved back.
.PARAMETER Height
    Window height. 480 by default.
.PARAMETER Path
    Where to write it. Omit to return the lines.
.PARAMETER NoQuit
    Leave out the Quit button. Right when this HTA is the SHELL: Microsoft's
    guidance is that "Windows PE will reboot when that command prompt exits", so
    a Quit button on a shell HTA is a reboot button wearing the wrong label.
.EXAMPLE
    New-WfPeMenuHta -Title 'Plus POS' -Path C:\Imaging\Pe\Menu\menu.hta -Item @(
        @{ Label = 'Deploy'; Command = 'X:\deploy.cmd' }
        @{ Label = 'Command prompt'; Command = 'cmd.exe' }
    )
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]   $Title = 'WimForge',
        [object[]] $Item  = @(),
        [int]      $Width  = 640,
        [int]      $Height = 480,
        [string]   $Path,
        [switch]   $NoQuit
    )

    # Normalised first, so a missing Label or Command is a message here rather
    # than a button that does nothing on a terminal.
    $buttons = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($i in @($Item)) {
        $n++
        $label = ''
        $command = ''
        $hint = ''
        if ($i -is [hashtable]) {
            $label = "$($i['Label'])"; $command = "$($i['Command'])"; $hint = "$($i['Hint'])"
        }
        else {
            $label = "$($i.Label)"; $command = "$($i.Command)"; $hint = "$($i.Hint)"
        }
        if (-not $label)   { throw ("Item {0} has no Label." -f $n) }
        if (-not $command) { throw ("Item {0} ({1}) has no Command -- a button that runs nothing is worse than no button." -f $n, $label) }
        $buttons.Add([pscustomobject]@{ Index = $n; Label = $label; Command = $command; Hint = $hint })
    }

    if ($buttons.Count -eq 0) {
        Write-WfLog 'No items given, so this menu has nothing on it but the heading.' -Level WARN
    }

    # HTML escaping for anything that lands in markup, and VBScript escaping --
    # doubling the quote -- for anything that lands in a string literal. A
    # command with a quoted path in it is the normal case, not the exotic one.
    $html = { param([string] $t) ($t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;') }
    $vbs  = { param([string] $t) ($t -replace '"', '""') }

    # The onclick attribute is quoted with an APOSTROPHE, so the double quotes
    # VBScript needs can stay as they are. Escaping them to &quot; also works --
    # the parser decodes entities in attribute values before the script engine
    # sees them -- but it turns every handler into a wall of &quot; that nobody
    # can read, and this file is meant to be edited by hand afterwards.
    $attr = { param([string] $t) ($t -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace "'", '&#39;') }

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('<!DOCTYPE html>')
    $L.Add('<html>')
    $L.Add('<head>')
    $L.Add(('<title>{0}</title>' -f (& $html $Title)))
    # SCROLL=no and MAXIMIZEBUTTON=no because a WinPE screen is often 1024x768
    # and a window that can be dragged off it cannot be dragged back -- there is
    # no taskbar to recover it from.
    $L.Add(('<HTA:APPLICATION ID="wfMenu" APPLICATIONNAME="{0}" BORDER="thin" ' -f (& $html $Title)) +
           'CAPTION="yes" SHOWINTASKBAR="no" SINGLEINSTANCE="yes" SYSMENU="yes" ' +
           'SCROLL="no" MAXIMIZEBUTTON="no" MINIMIZEBUTTON="no" CONTEXTMENU="no" SELECTION="no" />')
    $L.Add('<style>')
    $L.Add('  body   { background:#1b1b1b; color:#e8e8e8; font-family:Segoe UI,Tahoma,sans-serif; font-size:11pt; margin:0; padding:18px; }')
    $L.Add('  h1     { font-size:15pt; font-weight:600; color:#4ec3e0; margin:0 0 4px 0; }')
    $L.Add('  .sub   { color:#9a9a9a; font-size:9pt; margin:0 0 16px 0; }')
    $L.Add('  button { display:block; width:100%; text-align:left; padding:9px 12px; margin:0 0 7px 0;')
    $L.Add('           background:#2d2d2d; color:#e8e8e8; border:1px solid #454545; font-family:inherit; font-size:11pt; cursor:hand; }')
    $L.Add('  button:hover { background:#3a3a3a; border-color:#4ec3e0; }')
    $L.Add('  .hint  { color:#9a9a9a; font-size:8.5pt; }')
    $L.Add('  #status{ margin-top:14px; padding-top:10px; border-top:1px solid #383838; color:#9a9a9a; font-size:9pt; }')
    $L.Add('</style>')
    $L.Add('')
    $L.Add('<script language="VBScript">')
    $L.Add('  '' VBScript, not JScript: Microsoft replaced the JScript engine in the ADK')
    $L.Add('  '' for Windows 11 22H2, and an HTA written for the old one comes up with')
    $L.Add('  '' "An error has occurred in the script on this page" and nothing else to')
    $L.Add('  '' go on. This sample has to work on the first boot without depending on')
    $L.Add('  '' the registry fix that puts the old engine back.')
    $L.Add('')
    $L.Add(('  Sub WindowSetup()'))
    $L.Add('    Dim x, y')
    $L.Add(('    window.resizeTo {0}, {1}' -f $Width, $Height))
    $L.Add('    '' Centred by hand -- WinPE has no window manager to do it. The')
    $L.Add('    '' coordinates go into variables first: VBScript misreads a call whose')
    $L.Add('    '' first argument starts with a bracket, and this one would.')
    $L.Add(('    x = (screen.availWidth - {0}) \ 2' -f $Width))
    $L.Add(('    y = (screen.availHeight - {0}) \ 2' -f $Height))
    $L.Add('    If x < 0 Then x = 0')
    $L.Add('    If y < 0 Then y = 0')
    $L.Add('    window.moveTo x, y')
    $L.Add('  End Sub')
    $L.Add('')
    $L.Add('  Sub RunIt(cmd, label)')
    $L.Add('    Dim sh')
    $L.Add('    document.getElementById("status").innerText = "Running " & label & " ..."')
    $L.Add('    On Error Resume Next')
    $L.Add('    Set sh = CreateObject("WScript.Shell")')
    $L.Add('    If Err.Number <> 0 Then')
    $L.Add('      '' WScript.Shell comes with WinPE-Scripting, which WinPE-HTA depends on --')
    $L.Add('      '' so this only fires on an image assembled by hand in an unusual order.')
    $L.Add('      document.getElementById("status").innerText = "WScript.Shell is not available -- this boot image is missing WinPE-Scripting."')
    $L.Add('      Exit Sub')
    $L.Add('    End If')
    $L.Add('    '' 1 = visible, True = wait. Visible and blocking on purpose: somebody is')
    $L.Add('    '' standing in front of this, and a command that fails silently behind a')
    $L.Add('    '' menu is worse than no menu.')
    $L.Add('    Dim rc')
    $L.Add('    rc = sh.Run(cmd, 1, True)')
    $L.Add('    If Err.Number <> 0 Then')
    $L.Add('      document.getElementById("status").innerText = label & " could not start: " & Err.Description')
    $L.Add('    ElseIf rc = 0 Then')
    $L.Add('      document.getElementById("status").innerText = label & " finished."')
    $L.Add('    Else')
    $L.Add('      document.getElementById("status").innerText = label & " exited with code " & rc & "."')
    $L.Add('    End If')
    $L.Add('    On Error Goto 0')
    $L.Add('  End Sub')
    $L.Add('</script>')
    $L.Add('</head>')
    $L.Add('')
    $L.Add('<body onload="WindowSetup()">')
    $L.Add(('<h1>{0}</h1>' -f (& $html $Title)))
    $L.Add('<p class="sub">Windows PE deployment menu</p>')

    foreach ($b in $buttons) {
        $onclick = ('RunIt "{0}", "{1}"' -f (& $vbs $b.Command), (& $vbs $b.Label))
        $text = (& $html $b.Label)
        if ($b.Hint) { $text = $text + ('<br><span class="hint">{0}</span>' -f (& $html $b.Hint)) }
        $L.Add(('<button onclick=''{0}''>{1}</button>' -f (& $attr $onclick), $text))
    }

    if (-not $NoQuit) {
        $L.Add('<button onclick=''window.close''>Close this menu<br><span class="hint">If this menu is the shell, closing it restarts the machine.</span></button>')
    }

    $L.Add('<div id="status">Ready.</div>')
    $L.Add('</body>')
    $L.Add('</html>')

    $written = ''
    if ($Path) {
        if ($PSCmdlet.ShouldProcess($Path, 'Write the menu HTA')) {
            New-WfDirectory (Split-Path $Path -Parent) | Out-Null
            # UTF8 with a BOM is fine here and helps: mshta reads this as HTML,
            # and a BOM removes any question about the encoding of a label with
            # an accent in it.
            Set-Content -LiteralPath $Path -Value $L.ToArray() -Encoding UTF8 -Force
            Write-WfLog ("Menu HTA written to {0}, {1} button(s)" -f $Path, $buttons.Count) -Level OK
            Write-WfLog '  Add-WfPeTool -Source <its folder> -Command <its file name> puts it in a boot image and turns the JScript fix on.' -Level INFO
            Write-WfLog '  It needs WinPE-HTA in the image. Get-WfPeReport says whether that is there.' -Level INFO
            $written = $Path
        }
    }
    else {
        Write-WfLog ("{0} line(s) built, {1} button(s). Nothing was written -- give -Path." -f $L.Count, $buttons.Count) -Level INFO
    }

    return [pscustomobject]@{
        Lines   = $L.ToArray()
        Path    = $written
        Buttons = @($buttons | ForEach-Object { $_.Label })
    }
}

function Get-WfPeReport {
<#
.SYNOPSIS
    What is actually inside a boot image, and whether it will boot on a thin machine.
.DESCRIPTION
    One read-only mount, and everything worth knowing before that image goes onto
    a stick: its size and what that means for RAM, the scratch space, the
    optional components in it, your own tools, and whether startnet.cmd or
    winpeshl.ini has been customised.

    The size line is the one to read. WinPE boots into memory and needs the whole
    image in a CONTIGUOUS block of physical RAM, plus scratch space on top. The
    base needs 512MB; an image that has grown past that needs a machine with room
    for it, and a POS terminal is not usually generous.
.EXAMPLE
    Get-WfPeReport -BootImagePath C:\Imaging\Pe\boot.wim
#>
    [CmdletBinding()]
    param(
        [string] $BootImagePath,
        [int]    $Index = 1
    )

    Assert-WfElevated
    if (-not $BootImagePath) { $BootImagePath = (Get-WfConfig)['PeImage'] }
    $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'

    $file = Get-Item -LiteralPath $BootImagePath
    Write-WfLog ("{0} -- {1}" -f $file.Name, (Format-WfSize $file.Length)) -Level STEP

    foreach ($i in Get-WindowsImage -ImagePath $BootImagePath) {
        Write-WfLog ("  index {0}: {1}" -f $i.ImageIndex, $i.ImageName) -Level INFO
    }

    $arch = ''
    try {
        $info = @(Get-WindowsImage -ImagePath $BootImagePath -Index $Index -ErrorAction Stop)[0]
        $arch = ConvertFrom-WfImageArchitecture $info.Architecture
    }
    catch { }

    $found = Invoke-WfPeMounted -BootImagePath $BootImagePath -Index $Index -ReadOnly -Body {
        param($peMount)

        $scratch = ''
        try {
            $out = Invoke-WfDism @("/Image:$peMount", '/Get-ScratchSpace') -PassThruOutput
            $m = [regex]::Match(($out -join "`n"), '(?im)scratch\s*space\s*:?\s*(\d+)')
            if ($m.Success) { $scratch = $m.Groups[1].Value }
        }
        catch { }

        $packages = @()
        try {
            $packages = @(Get-WindowsPackage -Path $peMount -ErrorAction Stop |
                          Where-Object { "$($_.PackageName)" -match '(?i)WinPE-' } |
                          ForEach-Object {
                              $m = [regex]::Match("$($_.PackageName)", '(?i)(WinPE-[A-Za-z0-9]+)')
                              if ($m.Success) { $m.Groups[1].Value }
                          } | Where-Object { $_ } | Sort-Object -Unique)
        }
        catch { }

        $tools = @()
        $mfPath = Join-WfPath $peMount 'Windows\Tools\_tools.json'
        if (Test-Path -LiteralPath $mfPath) {
            try { $tools = @(Get-Content -LiteralPath $mfPath -Raw | ConvertFrom-Json | Where-Object { $_ }) } catch { }
        }

        $startnet = Join-WfPath $peMount 'Windows\System32\startnet.cmd'
        $startnetLines = 0
        $startnetIsWimForge = $false
        if (Test-Path -LiteralPath $startnet) {
            $text = Get-Content -LiteralPath $startnet -Raw
            $startnetLines = @($text -split "`r?`n").Count
            $startnetIsWimForge = $text -match 'WimForge'
        }

        $shell = ''
        $shellIni = Join-WfPath $peMount 'Windows\System32\winpeshl.ini'
        if (Test-Path -LiteralPath $shellIni) {
            $shell = (Get-Content -LiteralPath $shellIni -Raw).Trim()
        }

        $drivers = 0
        try { $drivers = @(Get-WindowsDriver -Path $peMount -ErrorAction Stop).Count } catch { }

        return [pscustomobject]@{
            ScratchMB = $scratch; Packages = $packages; Tools = $tools
            StartnetLines = $startnetLines; StartnetIsWimForge = $startnetIsWimForge
            Shell = $shell; Drivers = $drivers
        }
    }

    $toolBytes = 0
    foreach ($t in @($found.Tools)) { $toolBytes += [double]$t.SizeBytes }

    Write-WfLog ("scratch space  {0}MB" -f $(if ($found.ScratchMB) { $found.ScratchMB } else { 'unknown' })) -Level INFO
    Write-WfLog ("components     {0}" -f $(if (@($found.Packages).Count) { (@($found.Packages) -join ', ') } else { 'none beyond the base' })) -Level INFO
    Write-WfLog ("drivers        {0}" -f $found.Drivers) -Level INFO
    Write-WfLog ("tools          {0}" -f $(if (@($found.Tools).Count) { (@($found.Tools | ForEach-Object { $_.Name }) -join ', ') } else { 'none' })) -Level INFO

    # The check this report exists for. Both halves of the question are in hand
    # here and nowhere else: what is in the image, and what each tool needs to
    # start. An HTA in a boot image with no WinPE-HTA is a few kilobytes of HTML
    # that can never run, and nothing about the image looks wrong -- so it is
    # said here, once, in front of whoever is about to write the stick.
    $cannotStart = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($found.Tools)) {
        if (-not $t.Command) { continue }
        $how = Get-WfPeLaunchCommand -Command $t.Command
        if ($how.Kind -eq 'Unsupported') {
            $cannotStart.Add([pscustomobject]@{ Tool = $t.Name; Needs = ''; Why = $how.Note })
            continue
        }
        if ($how.Requires -and (@($found.Packages) -notcontains $how.Requires)) {
            $cannotStart.Add([pscustomobject]@{
                Tool = $t.Name; Needs = $how.Requires
                Why  = ("{0} is {1} and nothing in this image can start it." -f $t.Command, $how.Kind) })
        }
    }

    foreach ($c in $cannotStart) {
        Write-WfLog ("  {0}: {1}" -f $c.Tool, $c.Why) -Level ERROR
        if ($c.Needs) {
            Write-WfLog ("     Add-WfPeOptionalComponent -Component {0} -BootImagePath '{1}'" -f $c.Needs, $BootImagePath) -Level WARN
        }
    }

    if ($found.Shell) {
        Write-WfLog 'shell          replaced by winpeshl.ini -- startnet.cmd does NOT run.' -Level WARN
        if ($found.Shell -notmatch 'wfshell') {
            Write-WfLog '  and it does not go through a wrapper, so nothing calls wpeinit: no Plug and Play, no network.' -Level ERROR
        }
    }
    elseif ($found.StartnetIsWimForge) {
        Write-WfLog ("startnet.cmd   built by WimForge, {0} line(s)" -f $found.StartnetLines) -Level INFO
    }
    else {
        Write-WfLog ("startnet.cmd   stock or hand-edited, {0} line(s)" -f $found.StartnetLines) -Level INFO
    }

    # The line that decides whether this boots on a thin terminal.
    $imageMB   = [math]::Round($file.Length / 1MB)
    $scratchMB = 0
    if ($found.ScratchMB) { $scratchMB = [int]$found.ScratchMB }
    $needMB = $imageMB + $scratchMB

    Write-WfLog ("A RAM-disk boot needs about {0}MB of CONTIGUOUS physical memory: {1}MB of image plus {2}MB of scratch." -f $needMB, $imageMB, $scratchMB) -Level WARN
    if ($needMB -gt 1024) {
        Write-WfLog '  That is a lot for a terminal. Consider moving the large tools onto the media -- New-WfPeStartnet -PayloadFolder finds them at run time and costs the image nothing.' -Level WARN
    }

    return [pscustomobject]@{
        BootImage      = $BootImagePath
        Index          = $Index
        Architecture   = $arch
        SizeMB         = $imageMB
        ScratchMB      = $scratchMB
        EstimatedRamMB = $needMB
        Components     = @($found.Packages)
        Drivers        = $found.Drivers
        Tools          = @($found.Tools | ForEach-Object { $_.Name })
        ToolsMB        = [math]::Round($toolBytes / 1MB, 1)
        CannotStart    = $cannotStart.ToArray()
        Shell          = $found.Shell
        StartnetLines  = $found.StartnetLines
    }
}
