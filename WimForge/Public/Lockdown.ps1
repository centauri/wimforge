# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Lockdown.ps1 -- the IoT Enterprise features that turn a Windows image into a
    terminal, and the first-boot seam that configures them.

    These features exist only on Enterprise and IoT Enterprise SKUs, which is
    exactly what a POS estate is licensed for and almost never uses. A till that
    loses power nightly, in a shop, with staff who will install something they
    should not, wants a write filter. A customer-facing screen wants no Ctrl+Alt+
    Del, no Alt+Tab, no Windows key, and no Windows branding on the way up.

    What can be done offline splits cleanly, and the split shapes everything
    here:

      * ENABLING the features is a DISM operation against the mounted image, so
        it belongs in the image. Client-DeviceLockdown is the parent; the rest
        are enabled alongside it.

      * CUSTOM LOGON is plain registry values, so it is written straight into the
        offline hives. Every path below is from Microsoft's device lockdown
        documentation rather than from memory.

      * UWF, KEYBOARD FILTER and SHELL LAUNCHER are configured through uwfmgr and
        WMI, neither of which can be reached in an offline image. Those settings
        are written into a first-boot script instead. That is not a workaround --
        it is the supported shape, and the image still carries everything needed
        to arrive configured with no human at the terminal.

    A note on Shell Launcher: Set-WfShellLauncher writes the classic Winlogon
    shell replacement, which works on any Windows and is what most POS builds
    actually use. The Shell Launcher FEATURE, with its per-user shells and
    restart policies, is configured through WMI at first boot instead.
#>

function Get-WfLockdownFeature {
<#
.SYNOPSIS
    Which device lockdown features the image has, and which are turned on.
.DESCRIPTION
    Run this before anything else: on an edition that does not carry these
    features they simply are not listed, and knowing that now is better than
    finding out from an enablement that half succeeds.
#>
    [CmdletBinding()]
    param([string] $MountPath)

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $wanted = @(
        @{ Name = 'Client-DeviceLockdown';       What = 'parent feature -- required by all the others' }
        @{ Name = 'Client-UnifiedWriteFilter';   What = 'UWF: makes the disk immutable, discards writes on reboot' }
        @{ Name = 'Client-EmbeddedShellLauncher';What = 'Shell Launcher: run your application instead of Explorer' }
        @{ Name = 'Client-KeyboardFilter';       What = 'block Ctrl+Alt+Del, Alt+Tab, the Windows key' }
        @{ Name = 'Client-EmbeddedLogon';        What = 'Custom Logon: suppress the logon UI and branding' }
        @{ Name = 'Client-EmbeddedBootExp';      What = 'Unbranded Boot: no Windows logo or spinner' }
    )

    $present = @{}
    try {
        foreach ($f in (Get-WindowsOptionalFeature -Path $MountPath -ErrorAction Stop)) {
            $present[$f.FeatureName.ToLower()] = $f.State
        }
    }
    catch {
        throw "Could not read the image's optional features: $($_.Exception.Message)"
    }

    $out = foreach ($w in $wanted) {
        $state = 'NotInThisEdition'
        if ($present.ContainsKey($w.Name.ToLower())) { $state = [string]$present[$w.Name.ToLower()] }

        [pscustomobject]@{
            Feature = $w.Name
            State   = $state
            Purpose = $w.What
        }
    }

    $available = @($out | Where-Object { $_.State -ne 'NotInThisEdition' })
    if ($available.Count -eq 0) {
        Write-WfLog 'This image carries none of the device lockdown features. They are Enterprise and IoT Enterprise only.' -Level WARN
    }
    else {
        Write-WfLog ("{0} of {1} lockdown feature(s) available, {2} already enabled" -f `
            $available.Count, $wanted.Count, @($available | Where-Object { $_.State -eq 'Enabled' }).Count) -Level OK
    }

    return @($out)
}

function Enable-WfLockdownFeature {
<#
.SYNOPSIS
    Enables device lockdown features in a mounted image.
.DESCRIPTION
    Client-DeviceLockdown is enabled first whatever else is asked for: it is the
    parent, and the rest fail without it.

    Enabling costs nothing at runtime -- an enabled but unconfigured write filter
    filters nothing. So enabling in the image and configuring at first boot is
    both safe and the only order that works.
.PARAMETER Feature
    Which to enable. Names are the short ones: Uwf, ShellLauncher, KeyboardFilter,
    CustomLogon, UnbrandedBoot. Omit for all of them.
.EXAMPLE
    Enable-WfLockdownFeature -Feature Uwf, KeyboardFilter
#>
    [CmdletBinding()]
    param(
        [ValidateSet('Uwf','ShellLauncher','KeyboardFilter','CustomLogon','UnbrandedBoot','All')]
        [string[]] $Feature = @('All'),
        [string]   $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $map = @{
        Uwf             = 'Client-UnifiedWriteFilter'
        ShellLauncher   = 'Client-EmbeddedShellLauncher'
        KeyboardFilter  = 'Client-KeyboardFilter'
        CustomLogon     = 'Client-EmbeddedLogon'
        UnbrandedBoot   = 'Client-EmbeddedBootExp'
    }

    $names = @()
    if ($Feature -contains 'All') { $names = @($map.Values) }
    else { $names = @($Feature | ForEach-Object { $map[$_] }) }

    # The parent goes first, always.
    $ordered = @('Client-DeviceLockdown') + @($names | Sort-Object)

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($name in $ordered) {
        try {
            $state = (Get-WindowsOptionalFeature -Path $MountPath -FeatureName $name -ErrorAction Stop).State
        }
        catch {
            Write-WfLog "$name is not in this image -- skipped. These features are Enterprise and IoT Enterprise only." -Level WARN
            $results.Add([pscustomobject]@{ Feature = $name; Result = 'NotInThisEdition' })
            continue
        }

        if ($state -eq 'Enabled') {
            Write-WfLog "$name already enabled" -Level INFO
            $results.Add([pscustomobject]@{ Feature = $name; Result = 'AlreadyEnabled' })
            continue
        }

        Write-WfLog "Enabling $name" -Level STEP
        try {
            Enable-WindowsOptionalFeature -Path $MountPath -FeatureName $name -All -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ Feature = $name; Result = 'Enabled' })
            Write-WfLog "  enabled" -Level OK
        }
        catch {
            $results.Add([pscustomobject]@{ Feature = $name; Result = "Failed: $($_.Exception.Message.Trim())" })
            Write-WfLog "  failed: $($_.Exception.Message.Trim())" -Level ERROR
        }
    }

    $enabled = @($results | Where-Object { $_.Result -eq 'Enabled' }).Count
    Write-WfLog ("{0} feature(s) newly enabled. They do nothing until configured -- see New-WfLockdownFirstBoot." -f $enabled) -Level OK
    return $results.ToArray()
}

function Set-WfCustomLogon {
<#
.SYNOPSIS
    Suppresses the Windows logon UI and branding, offline.
.DESCRIPTION
    The one lockdown feature that is pure registry, so it can be baked into the
    image completely rather than applied at first boot. Every path here comes
    from Microsoft's device lockdown documentation.

    What each does:
      BrandingNeutral         hides the Windows branding on the logon screen
      HideAutoLogonUI         no logon UI at all when autologon is configured
      HideFirstLogonAnimation skips the "Hi, we're getting things ready" screens
      AnimationDisabled       no logon animation
      NoLockScreen            no lock screen -- a till has nobody to lock it
      UIVerbosityLevel        suppresses the startup and shutdown status messages

    Enable Client-EmbeddedLogon as well: these values are read by that feature.
.PARAMETER Revert
    Removes the values instead, putting the ordinary Windows logon experience
    back.
.EXAMPLE
    Set-WfCustomLogon
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $MountPath,
        [switch] $Revert
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    # path relative to the SOFTWARE hive, value name, value
    $settings = @(
        @{ Key = 'Microsoft\Windows Embedded\EmbeddedLogon';               Name = 'BrandingNeutral';         Value = 1 }
        @{ Key = 'Microsoft\Windows Embedded\EmbeddedLogon';               Name = 'HideAutoLogonUI';         Value = 1 }
        @{ Key = 'Microsoft\Windows Embedded\EmbeddedLogon';               Name = 'HideFirstLogonAnimation'; Value = 1 }
        @{ Key = 'Microsoft\Windows\CurrentVersion\Authentication\LogonUI';Name = 'AnimationDisabled';       Value = 1 }
        @{ Key = 'Policies\Microsoft\Windows\Personalization';             Name = 'NoLockScreen';            Value = 1 }
        @{ Key = 'Microsoft\Windows NT\CurrentVersion\Winlogon';           Name = 'UIVerbosityLevel';        Value = 1 }
    )

    $what = 'Suppress the logon UI and branding'
    if ($Revert) { $what = 'Restore the ordinary logon experience' }
    if (-not $PSCmdlet.ShouldProcess($MountPath, $what)) { return }

    Write-WfLog $what -Level STEP

    Invoke-WfRegistryEdit -MountPath $MountPath -Action {
        param($keys)
        foreach ($s in $settings) {
            $path = Join-WfPath $keys.Software $s.Key
            if ($Revert) {
                Remove-ItemProperty -LiteralPath $path -Name $s.Name -ErrorAction SilentlyContinue
                continue
            }
            if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
            New-ItemProperty -LiteralPath $path -Name $s.Name -Value $s.Value -PropertyType DWord -Force | Out-Null
        }
    }

    Write-WfLog ("{0} value(s) {1}" -f $settings.Count, $(if ($Revert) { 'removed' } else { 'written' })) -Level OK

    Write-WfHistory -Action 'Custom logon' -ImagePath $MountPath -Detail @{
        Reverted = [bool]$Revert; Values = $settings.Count
    } | Out-Null
}

function Set-WfShellLauncher {
<#
.SYNOPSIS
    Replaces the Windows shell with your application, offline.
.DESCRIPTION
    This writes the classic Winlogon shell replacement -- the machine-wide
    HKLM Winlogon\Shell value. It works on every Windows edition, it is the
    thing most POS builds actually use, and unlike the Shell Launcher feature it
    can be set completely offline.

    The difference worth knowing: the Shell Launcher FEATURE supports a different
    shell per user and a restart policy for when the shell exits, and is
    configured through WMI, which an offline image cannot reach. If you need
    those, enable Client-EmbeddedShellLauncher and let
    New-WfLockdownFirstBoot configure it at first boot instead.

    There is no way back from inside the shell you set. Have a plan for support
    access -- an administrator account with Explorer as its shell, or a keyboard
    shortcut your application honours -- before deploying this.
.PARAMETER Shell
    The command line to run as the shell, e.g. 'C:\POS\Till.exe'. Use 'explorer.exe'
    to put the normal desktop back.
.EXAMPLE
    Set-WfShellLauncher -Shell 'C:\POS\Till.exe'
.EXAMPLE
    Set-WfShellLauncher -Shell 'explorer.exe'
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $Shell,
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    # A shell that is not there is a machine that boots to a black screen, so an
    # obvious typo is worth catching here rather than in a shop.
    $exe = ($Shell -split '\s+')[0].Trim('"')
    if ($exe -match '^[A-Za-z]:\\' ) {
        $inImage = Join-WfPath $MountPath ($exe -replace '^[A-Za-z]:\\', '')
        if (-not (Test-Path -LiteralPath $inImage)) {
            Write-WfLog "$exe is not in the image. It must exist by the time the machine boots, or you get a black screen with no shell." -Level WARN
        }
    }

    if (-not $PSCmdlet.ShouldProcess($MountPath, "Set the shell to $Shell")) { return }

    Write-WfLog "Setting the machine shell to $Shell" -Level STEP

    Invoke-WfRegistryEdit -MountPath $MountPath -Action {
        param($keys)
        $path = Join-WfPath $keys.Software 'Microsoft\Windows NT\CurrentVersion\Winlogon'
        New-ItemProperty -LiteralPath $path -Name 'Shell' -Value $Shell -PropertyType String -Force | Out-Null
    }

    Write-WfLog 'Shell set. Nothing in the image can undo this from the terminal -- make sure support access exists.' -Level WARN

    Write-WfHistory -Action 'Shell replacement' -ImagePath $MountPath -Detail @{ Shell = $Shell } | Out-Null
}

# ------------------------------------------------------------ the first boot

function Set-WfFirstBootScript {
<#
.SYNOPSIS
    Places the script Windows runs once, after setup, before anyone logs on.
.DESCRIPTION
    \Windows\Setup\Scripts\SetupComplete.cmd is the supported seam between
    imaging and provisioning, and the rules around it are easy to get wrong:

      * It runs as SYSTEM, once, after setup completes and before the first
        logon screen. Not as a user, so anything expecting a profile fails.
      * It has no interactive desktop. A prompt, a message box or a
        Read-Host hangs the machine forever with nothing on screen.
      * Windows deletes it after it runs. Do not put anything in it you will
        want to read afterwards -- log elsewhere.
      * A non-zero exit code is ignored, so failure is silent unless you log it.

    So this wraps whatever you supply: output is redirected to a log outside the
    Scripts folder, which survives the file being deleted.

    ErrorHandler.cmd, in the same folder, runs if Setup hits a fatal error. It is
    written alongside so a failed deployment leaves something behind to read.
.PARAMETER Command
    Lines to run. Simplest for a couple of commands.
.PARAMETER ScriptFile
    A .cmd or .ps1 to copy into the image and run. Copied to
    \Windows\Setup\Scripts\ alongside SetupComplete.cmd.
.PARAMETER LogPath
    Where the wrapper writes its log, as the terminal will see it.
.EXAMPLE
    Set-WfFirstBootScript -Command 'powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Provision.ps1'
.EXAMPLE
    Set-WfFirstBootScript -ScriptFile D:\Imaging\Payload\Provision.ps1
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]] $Command,
        [string]   $ScriptFile,
        [string]   $LogPath = 'C:\Windows\Temp\WimForge-FirstBoot.log',
        [string]   $MountPath,
        [switch]   $Append
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }
    if (-not $Command -and -not $ScriptFile) { throw 'Supply -Command, -ScriptFile, or both.' }

    $scriptsDir = Join-WfPath $MountPath 'Windows\Setup\Scripts'
    $setupCmd   = Join-WfPath $scriptsDir 'SetupComplete.cmd'

    if (-not $PSCmdlet.ShouldProcess($setupCmd, 'Write the first-boot script')) { return }

    New-WfDirectory $scriptsDir | Out-Null

    $lines = New-Object System.Collections.Generic.List[string]

    # Only when starting fresh: appending a second header would re-open the log
    # in truncate mode and throw away what the first half wrote.
    $existing = @()
    if ($Append -and (Test-Path -LiteralPath $setupCmd)) {
        $existing = @(Get-Content -LiteralPath $setupCmd)
        Write-WfLog "Appending to the SetupComplete.cmd already in the image ($($existing.Count) lines)" -Level INFO
    }

    if ($existing.Count -gt 0) {
        foreach ($l in $existing) {
            # Drop a previous end marker so the appended part is not stranded
            # after the script has already logged that it finished.
            if ($l -match '^rem WimForge end$') { continue }
            $lines.Add($l)
        }
        $lines.Add('')
        $lines.Add('rem --- appended ---')
    }
    else {
        $lines.Add('@echo off')
        $lines.Add('rem WimForge first-boot script.')
        $lines.Add('rem Runs once as SYSTEM after setup, before the first logon. No desktop:')
        $lines.Add('rem anything that waits for input hangs the machine with nothing on screen.')
        $lines.Add("set WF_LOG=$LogPath")
        $lines.Add('echo [%DATE% %TIME%] WimForge first boot starting > "%WF_LOG%"')
    }

    if ($ScriptFile) {
        $resolved = Assert-WfPath -Path $ScriptFile -Label 'Script file'
        $leaf     = Split-Path $resolved -Leaf
        Copy-Item -LiteralPath $resolved -Destination (Join-WfPath $scriptsDir $leaf) -Force
        Write-WfLog "Copied $leaf into the image" -Level OK

        if ($leaf -match '\.ps1$') {
            # -NonInteractive matters: without it a stray Read-Host waits forever
            # on a machine with no desktop to type into.
            $lines.Add("echo [%DATE% %TIME%] running $leaf >> `"%WF_LOG%`"")
            $lines.Add("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"%SystemRoot%\Setup\Scripts\$leaf`" >> `"%WF_LOG%`" 2>&1")
        }
        else {
            $lines.Add("echo [%DATE% %TIME%] running $leaf >> `"%WF_LOG%`"")
            $lines.Add("call `"%SystemRoot%\Setup\Scripts\$leaf`" >> `"%WF_LOG%`" 2>&1")
        }
        $lines.Add("echo [%DATE% %TIME%] $leaf exited with %ERRORLEVEL% >> `"%WF_LOG%`"")
    }

    foreach ($c in @($Command)) {
        if (-not $c) { continue }
        $lines.Add("echo [%DATE% %TIME%] $($c -replace '[<>|&^]', '?') >> `"%WF_LOG%`"")
        $lines.Add("$c >> `"%WF_LOG%`" 2>&1")
        $lines.Add("echo [%DATE% %TIME%] exited with %ERRORLEVEL% >> `"%WF_LOG%`"")
    }

    $lines.Add('echo [%DATE% %TIME%] WimForge first boot finished >> "%WF_LOG%"')
    $lines.Add('exit /b 0')
    $lines.Add('rem WimForge end')

    # ASCII: SetupComplete.cmd is read by the command processor before any
    # locale is configured, and a BOM on the first line stops @echo off working.
    Set-Content -LiteralPath $setupCmd -Value $lines -Encoding Ascii -Force

    # Runs only if Setup fails outright, which is exactly when nobody can see
    # what happened.
    $errorHandler = Join-WfPath $scriptsDir 'ErrorHandler.cmd'
    if (-not (Test-Path -LiteralPath $errorHandler)) {
        Set-Content -LiteralPath $errorHandler -Encoding Ascii -Force -Value @(
            '@echo off'
            'rem WimForge -- runs if Windows Setup hits a fatal error.'
            "echo [%DATE% %TIME%] Setup failed. See setupact.log and setuperr.log. > $LogPath.setup-error.log"
            'exit /b 0'
        )
    }

    Write-WfLog ("SetupComplete.cmd written, {0} line(s). Its log lands at {1} on the terminal." -f $lines.Count, $LogPath) -Level OK
    Write-WfLog 'Windows deletes SetupComplete.cmd after it runs, so read the log, not the script.' -Level INFO

    Write-WfHistory -Action 'First-boot script' -ImagePath $MountPath -Detail @{
        Commands = @($Command).Count; ScriptFile = $ScriptFile; LogPath = $LogPath; Appended = [bool]$Append
    } | Out-Null

    return [pscustomobject]@{
        Path     = $setupCmd
        Lines    = $lines.Count
        LogPath  = $LogPath
        Appended = ($existing.Count -gt 0)
    }
}

function New-WfLockdownFirstBoot {
<#
.SYNOPSIS
    Generates the first-boot script that configures UWF, Keyboard Filter and
    Shell Launcher.
.DESCRIPTION
    These three are configured through uwfmgr and WMI, neither of which exists
    in an offline image. So the image carries a script that applies them on the
    terminal, once, with nobody present.

    Order matters and is not obvious: UWF is turned on LAST, after everything
    else has been written, because once the filter is enabled and the machine
    reboots, nothing written afterwards survives. Enabling it first would discard
    the rest of the configuration on the next power cycle -- and it would look
    like the settings simply never applied.
.PARAMETER ProtectVolume
    Volumes for UWF to protect. C: is the normal answer.
.PARAMETER Exclusion
    Paths UWF should let through -- log folders, a data directory, anything the
    application must keep across reboots. Get these right: a till that discards
    its own transaction log every night is worse than no write filter at all.
.PARAMETER BlockKey
    Predefined keys for Keyboard Filter to swallow, e.g. 'Ctrl+Alt+Del',
    'Alt+Tab', 'Windows'. Names are Microsoft's WEKF_PredefinedKey ids.
.PARAMETER ShellLauncherShell
    Application to run as the shell through the Shell Launcher FEATURE, as
    opposed to the classic Winlogon replacement Set-WfShellLauncher writes.
.PARAMETER DefaultShellUser
    Which account the Shell Launcher shell applies to. Leave empty for the
    default rule, which covers everyone without one of their own.
.EXAMPLE
    New-WfLockdownFirstBoot -ProtectVolume C: -Exclusion 'C:\POS\Logs','C:\POS\Data' -BlockKey 'Ctrl+Alt+Del','Alt+Tab','Windows'
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]] $ProtectVolume,
        [string[]] $Exclusion,
        [string[]] $BlockKey,
        [string]   $ShellLauncherShell,
        [string]   $DefaultShellUser,
        [string]   $MountPath,
        [switch]   $Append
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    if (-not $ProtectVolume -and -not $BlockKey -and -not $ShellLauncherShell) {
        throw 'Nothing to configure. Supply -ProtectVolume, -BlockKey or -ShellLauncherShell.'
    }

    $ps = New-Object System.Collections.Generic.List[string]
    $ps.Add('# WimForge lockdown configuration, applied once at first boot.')
    $ps.Add('# Generated -- edit the image, not this file.')
    $ps.Add('$ErrorActionPreference = ''Continue''')
    $ps.Add('function Say { param($m) Write-Output ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }')
    $ps.Add('')

    if ($BlockKey) {
        $ps.Add('Say "Keyboard Filter: blocking $($args.Count) key combinations"')
        $ps.Add('foreach ($k in @(' + (($BlockKey | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ', ') + ')) {')
        $ps.Add('    try {')
        $ps.Add('        $e = Get-WmiObject -Namespace root\standardcimv2\embedded -Class WEKF_PredefinedKey |')
        $ps.Add('             Where-Object { $_.Id -eq $k }')
        $ps.Add('        if ($e) { $e.Enabled = $true; $null = $e.Put(); Say "  blocked $k" }')
        $ps.Add('        else    { Say "  $k is not a predefined key on this build" }')
        $ps.Add('    }')
        $ps.Add('    catch { Say "  failed on ${k}: $($_.Exception.Message)" }')
        $ps.Add('}')
        $ps.Add('')
    }

    if ($ShellLauncherShell) {
        $ps.Add("Say 'Shell Launcher: setting the shell'")
        $ps.Add('try {')
        $ps.Add('    $class = Get-WmiObject -Namespace root\standardcimv2\embedded -List -Class WESL_UserSetting')
        if ($DefaultShellUser) {
            $ps.Add("    `$sid = (New-Object System.Security.Principal.NTAccount('$DefaultShellUser')).Translate([System.Security.Principal.SecurityIdentifier]).Value")
            $ps.Add("    `$null = `$class.SetCustomShell(`$sid, '$ShellLauncherShell', `$null, `$null, 0)")
        }
        else {
            $ps.Add("    `$null = `$class.SetDefaultShell('$ShellLauncherShell', 0)")
        }
        $ps.Add('    $null = $class.SetEnabled($true)')
        $ps.Add('    Say "  shell set"')
        $ps.Add('}')
        $ps.Add('catch { Say "  Shell Launcher failed: $($_.Exception.Message)" }')
        $ps.Add('')
    }

    if ($ProtectVolume) {
        # Exclusions before the filter is switched on -- see the note in the help.
        foreach ($x in @($Exclusion)) {
            if (-not $x) { continue }
            $vol = 'C:'
            if ($x -match '^([A-Za-z]:)') { $vol = $Matches[1] }
            $rest = $x -replace '^[A-Za-z]:', ''
            $ps.Add("Say 'UWF: excluding $x'")
            $ps.Add("& uwfmgr.exe file add-exclusion `"$x`" 2>&1 | Out-String | Write-Output")
        }

        foreach ($v in @($ProtectVolume)) {
            if (-not $v) { continue }
            $ps.Add("Say 'UWF: protecting $v'")
            $ps.Add("& uwfmgr.exe volume protect $v 2>&1 | Out-String | Write-Output")
        }

        $ps.Add('')
        $ps.Add('# Last, deliberately. Once the filter is on, anything written after')
        $ps.Add('# this point is discarded at the next reboot -- including the rest of')
        $ps.Add('# this script, if it were ordered any other way.')
        $ps.Add("Say 'UWF: enabling the filter (takes effect after the next restart)'")
        $ps.Add('& uwfmgr.exe filter enable 2>&1 | Out-String | Write-Output')
        $ps.Add('& uwfmgr.exe get-config 2>&1 | Out-String | Write-Output')
        $ps.Add('')
    }

    $ps.Add('Say "lockdown configuration complete"')

    if (-not $PSCmdlet.ShouldProcess($MountPath, 'Write the lockdown first-boot script')) { return }

    $scriptsDir = New-WfDirectory (Join-WfPath $MountPath 'Windows\Setup\Scripts')
    $psPath     = Join-WfPath $scriptsDir 'WimForge-Lockdown.ps1'
    Set-Content -LiteralPath $psPath -Value $ps -Encoding UTF8 -Force

    Write-WfLog ("Lockdown script written, {0} line(s)" -f $ps.Count) -Level OK

    $result = Set-WfFirstBootScript -MountPath $MountPath -Append:$Append -Confirm:$false `
        -Command 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\WimForge-Lockdown.ps1"'

    if ($ProtectVolume) {
        Write-WfLog 'UWF is enabled by this script but only takes effect after the terminal restarts once.' -Level WARN
        if (-not $Exclusion) {
            Write-WfLog 'No UWF exclusions were given. Every write to the protected volume will be discarded on reboot, including application logs and data.' -Level WARN
        }
    }

    return [pscustomobject]@{
        ScriptPath   = $psPath
        Lines        = $ps.Count
        SetupComplete= $result.Path
        LogPath      = $result.LogPath
        Volumes      = @($ProtectVolume)
        Exclusions   = @($Exclusion)
        BlockedKeys  = @($BlockKey)
        Shell        = $ShellLauncherShell
    }
}
