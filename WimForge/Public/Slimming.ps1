# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Slimming.ps1 -- taking things out of the image, and the recovery image nobody
    remembers until they need it.

    A word on the temptation here. It is easy to strip an image until it boots
    fast and looks lean, and then spend a year finding out which removed
    component something quietly depended on. So everything in this file lists
    before it removes, removes only what was named, and keeps a record of what
    went. Nothing has a "remove everything unnecessary" switch, because nothing
    can know what is unnecessary on your estate.
#>

function Get-WfProvisionedApp {
<#
.SYNOPSIS
    Lists the AppX packages provisioned into an image.
.DESCRIPTION
    Provisioned packages install for every new user at first logon. On an LTSC
    image there are few, which is rather the point of LTSC; on a general Windows
    image there are dozens.
#>
    [CmdletBinding()]
    param([string] $MountPath)

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $apps = @()
    try { $apps = @(Get-AppxProvisionedPackage -Path $MountPath -ErrorAction Stop) }
    catch { throw "Could not read provisioned packages: $($_.Exception.Message)" }

    Write-WfLog ("{0} provisioned package(s)" -f $apps.Count) -Level OK
    if ($apps.Count -eq 0) {
        Write-WfLog 'None -- which is normal for LTSC.' -Level INFO
    }

    return @($apps | Select-Object `
        @{ n = 'Name';        e = { $_.DisplayName } },
        @{ n = 'Version';     e = { $_.Version } },
        @{ n = 'Publisher';   e = { $_.PublisherId } },
        @{ n = 'PackageName'; e = { $_.PackageName } } |
        Sort-Object Name)
}

function Remove-WfProvisionedApp {
<#
.SYNOPSIS
    Removes named AppX packages from an image.
.DESCRIPTION
    Only what is named, matched against the display name, and every match is
    listed before anything is removed.

    Some packages are load-bearing in ways their names do not suggest. Removing
    the Store takes anything that updates through it with it; removing
    VCLibs or the .NET native framework packages breaks applications that
    depend on them, including ones you install later. Those are refused unless
    -Force is given, which is the point at which you are choosing to know better.
.PARAMETER Name
    Display names, or wildcards: 'Microsoft.XboxGameOverlay', 'Microsoft.Zune*'.
.EXAMPLE
    Get-WfProvisionedApp | Format-Table
.EXAMPLE
    Remove-WfProvisionedApp -Name 'Microsoft.Zune*','Microsoft.XboxGameOverlay'
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string[]] $Name,
        [string] $MountPath,
        [switch] $Force
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    # Names whose removal breaks other things in ways that surface much later.
    $risky = @(
        'Microsoft.VCLibs*'
        'Microsoft.NET.Native*'
        'Microsoft.UI.Xaml*'
        'Microsoft.WindowsStore'
        'Microsoft.DesktopAppInstaller'
        'Microsoft.SecHealthUI'
    )

    $all     = @(Get-AppxProvisionedPackage -Path $MountPath -ErrorAction Stop)
    $matched = New-Object System.Collections.Generic.List[object]

    foreach ($pattern in $Name) {
        $hits = @($all | Where-Object { $_.DisplayName -like $pattern })
        if ($hits.Count -eq 0) {
            Write-WfLog "Nothing matches '$pattern'" -Level WARN
            continue
        }
        foreach ($h in $hits) {
            if ($matched.PackageName -contains $h.PackageName) { continue }
            $matched.Add($h)
        }
    }

    if ($matched.Count -eq 0) {
        Write-WfLog 'Nothing to remove.' -Level WARN
        return @()
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($app in $matched) {
        $isRisky = @($risky | Where-Object { $app.DisplayName -like $_ }).Count -gt 0

        if ($isRisky -and -not $Force) {
            Write-WfLog "Refusing $($app.DisplayName): other packages depend on it, and what breaks does not break today. Use -Force if you mean it." -Level WARN
            $results.Add([pscustomobject]@{ Name = $app.DisplayName; Result = 'RefusedAsRisky' })
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($app.DisplayName, 'Remove provisioned package')) { continue }

        try {
            Remove-AppxProvisionedPackage -Path $MountPath -PackageName $app.PackageName -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ Name = $app.DisplayName; Result = 'Removed' })
            Write-WfLog "Removed $($app.DisplayName)" -Level OK
        }
        catch {
            $results.Add([pscustomobject]@{ Name = $app.DisplayName; Result = "Failed: $($_.Exception.Message.Trim())" })
            Write-WfLog "Failed on $($app.DisplayName): $($_.Exception.Message.Trim())" -Level ERROR
        }
    }

    $removed = @($results | Where-Object { $_.Result -eq 'Removed' })
    Write-WfLog ("{0} removed, {1} left alone" -f $removed.Count, ($results.Count - $removed.Count)) -Level OK

    Write-WfHistory -Action 'Remove provisioned apps' -ImagePath $MountPath -Detail @{
        Removed = @($removed | ForEach-Object { $_.Name })
    } | Out-Null

    return $results.ToArray()
}

function Get-WfImageCapability {
<#
.SYNOPSIS
    Lists the optional capabilities installed in an image.
.DESCRIPTION
    Capabilities are the on-demand components: WordPad, Notepad, the various
    language and handwriting packs, Windows Media Player, the RSAT tools. On a
    terminal most are dead weight and a little attack surface.
#>
    [CmdletBinding()]
    param(
        [string] $MountPath,
        [switch] $IncludeNotPresent
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $caps = @(Get-WindowsCapability -Path $MountPath -ErrorAction Stop)
    if (-not $IncludeNotPresent) { $caps = @($caps | Where-Object { $_.State -eq 'Installed' }) }

    Write-WfLog ("{0} capabilit(y/ies)" -f $caps.Count) -Level OK
    return @($caps | Select-Object Name, State | Sort-Object Name)
}

function Remove-WfImageCapability {
<#
.SYNOPSIS
    Removes named capabilities from an image.
.DESCRIPTION
    Capabilities are not provisioned apps and are not optional features, though
    all three get called "the stuff we do not need". This removes the middle one
    -- the Features on Demand that ship installed, like handwriting or the legacy
    media player.

    List before removing. There is no undo without the FoD source, and some
    capabilities are depended on by things that do not announce it.
.PARAMETER Name
    Capability names or wildcards, as Get-WfImageCapability reports them.
.EXAMPLE
    Remove-WfImageCapability -Name 'Media.WindowsMediaPlayer*','App.Support.QuickAssist*'
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string[]] $Name,
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $installed = @(Get-WindowsCapability -Path $MountPath -ErrorAction Stop |
                   Where-Object { $_.State -eq 'Installed' })

    $matched = New-Object System.Collections.Generic.List[object]
    foreach ($pattern in $Name) {
        $hits = @($installed | Where-Object { $_.Name -like $pattern })
        if ($hits.Count -eq 0) { Write-WfLog "Nothing installed matches '$pattern'" -Level WARN; continue }
        foreach ($h in $hits) {
            if ($matched.Name -contains $h.Name) { continue }
            $matched.Add($h)
        }
    }

    if ($matched.Count -eq 0) { Write-WfLog 'Nothing to remove.' -Level WARN; return @() }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($cap in $matched) {
        if (-not $PSCmdlet.ShouldProcess($cap.Name, 'Remove capability')) { continue }
        try {
            Remove-WindowsCapability -Path $MountPath -Name $cap.Name -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ Name = $cap.Name; Result = 'Removed' })
            Write-WfLog "Removed $($cap.Name)" -Level OK
        }
        catch {
            $results.Add([pscustomobject]@{ Name = $cap.Name; Result = "Failed: $($_.Exception.Message.Trim())" })
            Write-WfLog "Failed on $($cap.Name): $($_.Exception.Message.Trim())" -Level ERROR
        }
    }

    Write-WfHistory -Action 'Remove capabilities' -ImagePath $MountPath -Detail @{
        Removed = @($results | Where-Object { $_.Result -eq 'Removed' } | ForEach-Object { $_.Name })
    } | Out-Null

    return $results.ToArray()
}

function Disable-WfImageFeature {
<#
.SYNOPSIS
    Turns optional features off in an image.
.DESCRIPTION
    Disabling leaves the payload in the component store, so it can be turned back
    on without media. -Remove takes the payload out too, which saves real space
    and means turning it back on needs a source. On an image that is about to be
    /ResetBase'd, -Remove is the one that actually shrinks anything.
.EXAMPLE
    Disable-WfImageFeature -Name 'WindowsMediaPlayer','Printing-XPSServices-Features'
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string[]] $Name,
        [string] $MountPath,
        [switch] $Remove
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $enabled = @(Get-WindowsOptionalFeature -Path $MountPath -ErrorAction Stop |
                 Where-Object { $_.State -eq 'Enabled' })

    $matched = New-Object System.Collections.Generic.List[object]
    foreach ($pattern in $Name) {
        $hits = @($enabled | Where-Object { $_.FeatureName -like $pattern })
        if ($hits.Count -eq 0) { Write-WfLog "Nothing enabled matches '$pattern'" -Level WARN; continue }
        foreach ($h in $hits) {
            if ($matched.FeatureName -contains $h.FeatureName) { continue }
            $matched.Add($h)
        }
    }

    if ($matched.Count -eq 0) { Write-WfLog 'Nothing to disable.' -Level WARN; return @() }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($f in $matched) {
        if (-not $PSCmdlet.ShouldProcess($f.FeatureName, 'Disable feature')) { continue }
        try {
            $p = @{ Path = $MountPath; FeatureName = $f.FeatureName; ErrorAction = 'Stop' }
            if ($Remove) { $p['Remove'] = $true }
            Disable-WindowsOptionalFeature @p | Out-Null

            $how = 'Disabled'
            if ($Remove) { $how = 'DisabledAndRemoved' }
            $results.Add([pscustomobject]@{ Feature = $f.FeatureName; Result = $how })
            Write-WfLog "$how $($f.FeatureName)" -Level OK
        }
        catch {
            $results.Add([pscustomobject]@{ Feature = $f.FeatureName; Result = "Failed: $($_.Exception.Message.Trim())" })
            Write-WfLog "Failed on $($f.FeatureName): $($_.Exception.Message.Trim())" -Level ERROR
        }
    }

    Write-WfHistory -Action 'Disable features' -ImagePath $MountPath -Detail @{
        Removed = [bool]$Remove
        Features = @($results | ForEach-Object { $_.Feature })
    } | Out-Null

    return $results.ToArray()
}

# ---------------------------------------------------------------- the WinRE

function Add-WfRecoveryDriver {
<#
.SYNOPSIS
    Injects drivers into the recovery image inside a Windows image.
.DESCRIPTION
    \Windows\System32\Recovery\Winre.wim is a second, complete WinPE living
    inside the installed image, and it is the thing that runs when a terminal
    fails to boot. It gets none of the drivers injected into the image around it.

    So on a machine whose storage controller or network adapter needs a
    third-party driver, recovery comes up blind: no disk to reset, no network to
    reach a share. You discover this on the day you need it, in a shop, on the
    machine that will not boot.

    The same classes the WinPE boot image gets are what matter here -- storage,
    network, chipset, USB -- so the configured BootDriverClasses list is used.

    The recovery image is copied out, serviced separately and copied back. It is
    marked hidden and system inside the image, so the attributes are cleared and
    restored around the copy; leaving it visible would be a small, permanent
    oddity on every terminal.
.PARAMETER Models
    Driver library folders to take drivers from. Omit for all of them.
.EXAMPLE
    Add-WfRecoveryDriver
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]] $Models,
        [string[]] $ClassFilter,
        [string]   $MountPath,
        # As everywhere else: the library to take the drivers from, when it is
        # not the configured one.
        [string]   $DriverRoot,
        [switch]   $ForceUnsigned
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $MountPath)   { $MountPath   = $cfg['MountPath'] }
    if (-not $ClassFilter) { $ClassFilter = $cfg['BootDriverClasses'] }

    $winre = Join-WfPath $MountPath 'Windows\System32\Recovery\Winre.wim'
    if (-not (Test-Path -LiteralPath $winre)) {
        throw "No recovery image at $winre. Some captured images have had it removed, and a few OEM images keep it on a separate partition instead."
    }

    if (-not $PSCmdlet.ShouldProcess($winre, 'Inject drivers into the recovery image')) { return }

    $scratch     = New-WfDirectory $cfg['ScratchPath']
    $working     = Join-WfPath $scratch ('winre-{0}.wim' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    $reMountPath = Join-WfPath $scratch 'WinReMount'

    # A second mount folder: the image around it is already using the configured
    # one, and DISM will not have two images in the same place.
    New-WfDirectory $reMountPath | Out-Null
    if (@(Get-ChildItem -LiteralPath $reMountPath -Force).Count -gt 0) {
        throw "The recovery mount folder is not empty: $reMountPath. Something was interrupted -- clear it and run Repair-WfMount."
    }

    $original = Get-Item -LiteralPath $winre -Force
    $attrs    = $original.Attributes

    $mounted = $false
    try {
        Write-WfLog ("Copying the recovery image out ({0})" -f (Format-WfSize $original.Length)) -Level STEP
        Copy-Item -LiteralPath $winre -Destination $working -Force
        Set-ItemProperty -LiteralPath $working -Name Attributes -Value 'Normal'

        Write-WfLog 'Mounting the recovery image' -Level STEP
        Mount-WindowsImage -ImagePath $working -Index 1 -Path $reMountPath -ErrorAction Stop | Out-Null
        $mounted = $true

        $recParams = @{
            MountPath = $reMountPath; Models = $Models; ClassFilter = $ClassFilter
            ForceUnsigned = [bool]$ForceUnsigned
        }
        if ($DriverRoot) { $recParams['DriverRoot'] = $DriverRoot }
        $added = Add-WfDriver @recParams

        Write-WfLog 'Committing the recovery image' -Level STEP
        Dismount-WindowsImage -Path $reMountPath -Save -ErrorAction Stop | Out-Null
        $mounted = $false

        # Attributes back exactly as they were: hidden and system on every stock
        # image, and a visible Winre.wim is the sort of difference that gets
        # noticed a year later and cannot be explained.
        Write-WfLog 'Putting it back' -Level STEP
        Set-ItemProperty -LiteralPath $winre -Name Attributes -Value 'Normal'
        Copy-Item -LiteralPath $working -Destination $winre -Force
        Set-ItemProperty -LiteralPath $winre -Name Attributes -Value $attrs

        $newSize = (Get-Item -LiteralPath $winre -Force).Length
        Write-WfLog ("Recovery image updated: {0} driver(s), now {1}" -f $added.Added, (Format-WfSize $newSize)) -Level OK

        Write-WfHistory -Action 'Recovery drivers' -ImagePath $MountPath -Detail @{
            Added = $added.Added; Selected = $added.Selected; Classes = ($ClassFilter -join ', ')
            Models = @($added.Models)
        } | Out-Null

        return [pscustomobject]@{
            RecoveryImage = $winre
            Added         = $added.Added
            Selected      = $added.Selected
            Failed        = $added.Failed
            SizeBytes     = $newSize
        }
    }
    catch {
        if ($mounted) {
            Write-WfLog 'Discarding the recovery mount -- the image in the WIM is untouched.' -Level WARN
            try   { Dismount-WindowsImage -Path $reMountPath -Discard -ErrorAction Stop | Out-Null }
            catch { Write-WfLog "Discard also failed: $($_.Exception.Message). Run Repair-WfMount." -Level ERROR }
        }
        throw
    }
    finally {
        # The working copy is only ever a copy: the original is not replaced
        # until the commit above has succeeded, so cleaning up here is safe
        # whatever happened.
        Remove-Item -LiteralPath $working -Force -ErrorAction SilentlyContinue
    }
}
