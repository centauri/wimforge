# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    ReferenceVm.ps1 -- the reference build VM, end to end.

    Two things shape everything in here.

    1. The Hyper-V host may be this workstation or a separate server. Every
       Hyper-V call therefore goes through Invoke-WfVmHostCommand, which runs the
       scriptblock locally or over WinRM depending on the HyperVHost setting.
       There is exactly one place that decides, rather than a -ComputerName
       sprinkled through twenty cmdlets.

    2. Work inside the guest goes over PowerShell Direct (Invoke-Command -VMName).
       That runs over VMBus, not the network -- so it needs no network adapter, no
       firewall rule and no name resolution, which is exactly right for a machine
       sitting in audit mode that has never been on a domain. It does need guest
       credentials, and in audit mode the built-in Administrator starts with a
       blank password. Windows will not accept a blank password over PowerShell
       Direct, so one command inside the VM is unavoidable:

           net user Administrator <password>

       Set-WfGuestCredential then holds it for the session, in memory only.
#>

# ------------------------------------------------------------------ plumbing

function Invoke-WfVmHostCommand {
<#
.SYNOPSIS
    Runs a scriptblock on whichever machine is the Hyper-V host.
.DESCRIPTION
    The single seam between "Hyper-V is here" and "Hyper-V is over there". Every
    reference VM function goes through it, so none of them has to care which is
    the case -- and the day the host moves to another machine, one configuration
    value changes and nothing else does.

    A local host runs the block directly rather than through a loopback remoting
    session. That is not only faster: PowerShell remoting to localhost needs
    WinRM configured, and requiring it to manage a VM on the machine you are
    already sitting at would be a needless dependency.
.PARAMETER ScriptBlock
    Run on the host. It cannot see this session's variables when the host is
    remote, so pass anything it needs through -ArgumentList.
.PARAMETER ArgumentList
    Positional arguments for the block.
.EXAMPLE
    Invoke-WfVmHostCommand -ArgumentList @($Name) -ScriptBlock { param($Name) Get-VM -Name $Name }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList = @()
    )

    $cfg     = Get-WfConfig
    $vmHost  = $cfg['HyperVHost']

    if (-not $vmHost -or $vmHost -in '.', 'localhost', '127.0.0.1', $env:COMPUTERNAME) {
        return (& $ScriptBlock @ArgumentList)
    }

    $params = @{
        ComputerName = $vmHost
        ScriptBlock  = $ScriptBlock
        ErrorAction  = 'Stop'
    }
    if ($ArgumentList.Count -gt 0) { $params['ArgumentList'] = $ArgumentList }
    if ($script:WfHostCredential)  { $params['Credential']   = $script:WfHostCredential }

    return (Invoke-Command @params)
}

function Test-WfVmHostIsRemote {
<#
.SYNOPSIS
    Is the Hyper-V host another machine?
.DESCRIPTION
    Worth asking before an operation that behaves differently across the wire --
    copying a file into the guest, or reaching for the VM's VHDX by path. Both
    front-ends use it to say so on screen rather than letting a path that only
    exists on the host look like a missing file.

    An empty HyperVHost means this machine, which is the default and the common
    case.
.EXAMPLE
    if (Test-WfVmHostIsRemote) { Write-WfLog 'The VHDX path is on the host, not here.' -Level INFO }
#>
    [CmdletBinding()]
    param()

    $vmHost = (Get-WfConfig)['HyperVHost']
    if (-not $vmHost) { return $false }
    return ($vmHost -notin '.', 'localhost', '127.0.0.1', $env:COMPUTERNAME)
}

function Set-WfGuestCredential {
<#
.SYNOPSIS
    Stores the reference VM's guest credentials for this session, in memory only.
.DESCRIPTION
    Used for PowerShell Direct into the guest. Never written to disk and never put
    in the configuration file -- it lives for as long as the PowerShell session and
    no longer.

    In audit mode the built-in Administrator has a blank password, and Windows
    refuses a blank password over PowerShell Direct. Set one inside the VM first:

        net user Administrator <password>
.PARAMETER Credential
    Omit to be prompted.
#>
    [CmdletBinding()]
    param([System.Management.Automation.PSCredential] $Credential)

    if (-not $Credential) {
        $Credential = Get-Credential -UserName 'Administrator' `
            -Message 'Reference VM guest credentials (for PowerShell Direct)'
    }
    if (-not $Credential) { return $null }

    $script:WfGuestCredential = $Credential
    Write-WfLog "Guest credentials stored for this session ($($Credential.UserName))" -Level OK
    return $Credential.UserName
}

function Set-WfHostCredential {
<#
.SYNOPSIS
    Stores credentials for a remote Hyper-V host, for this session only.
.DESCRIPTION
    In memory, for this session, and never written to disk or into the
    configuration file. A credential in a JSON file next to a build script is a
    credential in everybody's backup.

    Only needed when the Hyper-V host is another machine. Locally the reference
    VM functions run in this session and there is nothing to authenticate.
.PARAMETER Credential
    Pass nothing to clear it.
.EXAMPLE
    Set-WfHostCredential -Credential (Get-Credential)
#>
    [CmdletBinding()]
    param([System.Management.Automation.PSCredential] $Credential)

    if (-not $Credential) {
        $Credential = Get-Credential -Message 'Credentials for the remote Hyper-V host'
    }
    if (-not $Credential) { return $null }

    $script:WfHostCredential = $Credential
    Write-WfLog "Hyper-V host credentials stored for this session ($($Credential.UserName))" -Level OK
    return $Credential.UserName
}

function Test-WfHyperV {
<#
.SYNOPSIS
    Checks the Hyper-V host is reachable and usable before anything is attempted.
.DESCRIPTION
    Asked before anything is attempted, because the failures otherwise arrive one
    at a time and each looks like a different problem: the module missing, the
    service stopped, the host unreachable, the credentials wrong.

    Reports rather than throws, so a front-end can show what is wrong and what
    would fix it.
.EXAMPLE
    Test-WfHyperV | Format-Table Check, Status, Detail
#>
    [CmdletBinding()]
    param()

    $cfg     = Get-WfConfig
    $results = New-Object System.Collections.Generic.List[object]
    $vmHost  = $cfg['HyperVHost']
    if (-not $vmHost) { $vmHost = $env:COMPUTERNAME }

    $remote = Test-WfVmHostIsRemote
    $mode = 'local'
    if ($remote) { $mode = 'remote' }
    $results.Add([pscustomobject]@{ Check = 'Host'; Status = 'INFO'; Detail = "$vmHost ($mode)" })

    if ($remote) {
        try {
            Test-WSMan -ComputerName $vmHost -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ Check = 'WinRM'; Status = 'OK'; Detail = "Reachable on $vmHost" })
        }
        catch {
            $results.Add([pscustomobject]@{ Check = 'WinRM'; Status = 'FAIL'; Detail = $_.Exception.Message })
            return $results
        }
    }

    try {
        $info = Invoke-WfVmHostCommand -ScriptBlock {
            $m = Get-Module -ListAvailable -Name Hyper-V | Select-Object -First 1
            [pscustomobject]@{
                ModulePresent = ($null -ne $m)
                ModuleVersion = "$($m.Version)"
                VmPath        = (Get-VMHost -ErrorAction SilentlyContinue).VirtualMachinePath
                VmCount       = @(Get-VM -ErrorAction SilentlyContinue).Count
            }
        }

        if ($info.ModulePresent) {
            $results.Add([pscustomobject]@{ Check = 'Hyper-V module'; Status = 'OK'; Detail = $info.ModuleVersion })
        }
        else {
            $results.Add([pscustomobject]@{ Check = 'Hyper-V module'; Status = 'FAIL'; Detail = 'Not installed on the host' })
        }
        $results.Add([pscustomobject]@{ Check = 'Default VM path'; Status = 'INFO'; Detail = "$($info.VmPath)" })
        $results.Add([pscustomobject]@{ Check = 'VMs on host';     Status = 'INFO'; Detail = "$($info.VmCount)" })
    }
    catch {
        $results.Add([pscustomobject]@{ Check = 'Hyper-V'; Status = 'FAIL'; Detail = $_.Exception.Message })
    }

    $credState = 'not set'
    if ($script:WfGuestCredential) { $credState = "set ($($script:WfGuestCredential.UserName))" }
    $credStatus = 'WARN'
    if ($script:WfGuestCredential) { $credStatus = 'OK' }
    $results.Add([pscustomobject]@{
        Check = 'Guest credentials'; Status = $credStatus
        Detail = "$credState -- needed for anything that runs inside the VM"
    })

    return $results
}

# ------------------------------------------------------------- VM lifecycle

function New-WfReferenceVm {
<#
.SYNOPSIS
    Creates the reference build VM, configured for imaging.
.DESCRIPTION
    Generation 2, fixed memory, Secure Boot with the Microsoft Windows template,
    standard checkpoints, and automatic checkpoints OFF.

    That last setting is the one that matters. Hyper-V enables automatic
    checkpoints on new VMs; they fire on every start, and one taken during sysprep
    leaves a reference build that is quietly wrong and only shows up at capture.

    The Guest Service Interface is enabled so files can be copied into the VM
    without credentials or a network.
.PARAMETER CompatibleCpu
    Hides the newer instruction sets from the guest, so the VM can be moved to a
    host with an older processor.

    Off by default, and that is the right default here. The captured WIM does not
    carry processor features -- what is installed into it is the same either way,
    and the terminals it deploys to have their own CPUs. The setting only matters
    for the LIFE OF THE VM: turn it on if this reference build will be moved or
    live-migrated to a different Hyper-V host, and leave it off otherwise, since
    off is measurably faster for the servicing runs that happen inside it.
#>
    [CmdletBinding()]
    param(
        [string] $Name,
        [string] $IsoPath,
        [string] $Path,
        [string] $SwitchName,
        [int]    $MemoryGB,
        [int]    $VhdSizeGB,
        [int]    $CpuCount,
        [switch] $CompatibleCpu
    )

    $cfg = Get-WfConfig
    if (-not $Name)      { $Name      = $cfg['ReferenceVmName'] }
    if (-not $IsoPath)   { $IsoPath   = $cfg['ReferenceIsoPath'] }
    if (-not $Path)      { $Path      = $cfg['ReferenceVmPath'] }
    if (-not $SwitchName){ $SwitchName= $cfg['ReferenceVmSwitch'] }
    if (-not $MemoryGB)  { $MemoryGB  = $cfg['ReferenceVmMemoryGB'] }
    if (-not $VhdSizeGB) { $VhdSizeGB = $cfg['ReferenceVmVhdSizeGB'] }
    if (-not $CpuCount)  { $CpuCount  = $cfg['ReferenceVmCpuCount'] }
    if (-not $PSBoundParameters.ContainsKey('CompatibleCpu')) {
        $CompatibleCpu = [bool]$cfg['ReferenceVmCompatibleCpu']
    }

    if (-not $IsoPath) { throw 'No ISO configured. Set ReferenceIsoPath in Settings, or pass -IsoPath.' }

    Write-WfLog "Creating reference VM '$Name' on $(if (Test-WfVmHostIsRemote) { $cfg['HyperVHost'] } else { 'this machine' })" -Level STEP

    $result = Invoke-WfVmHostCommand -ArgumentList @($Name, $IsoPath, $Path, $SwitchName, $MemoryGB, $VhdSizeGB, $CpuCount, [bool]$CompatibleCpu) -ScriptBlock {
        param($Name, $IsoPath, $Path, $SwitchName, $MemoryGB, $VhdSizeGB, $CpuCount, $CompatibleCpu)
        $ErrorActionPreference = 'Stop'

        if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
            throw "A VM named '$Name' already exists on this host."
        }
        if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found on the host: $IsoPath" }

        if (-not $Path) { $Path = (Get-VMHost).VirtualMachinePath }
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }

        $vhdPath = [System.IO.Path]::Combine($Path, "$Name.vhdx")
        if (Test-Path -LiteralPath $vhdPath) { throw "Disk already exists on the host: $vhdPath" }

        $args = @{
            Name               = $Name
            Generation         = 2
            MemoryStartupBytes = ($MemoryGB * 1GB)
            NewVHDPath         = $vhdPath
            NewVHDSizeBytes    = ($VhdSizeGB * 1GB)
            Path               = $Path
        }
        if ($SwitchName) { $args['SwitchName'] = $SwitchName }
        New-VM @args | Out-Null

        Set-VMMemory    -VMName $Name -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB * 1GB)
        Set-VMProcessor -VMName $Name -Count $CpuCount

        # Only touched when asked for. Setting it to $false explicitly is the
        # same as the default, but it would still show as a deliberate choice in
        # the VM's settings, and this VM has enough deliberate choices already.
        if ($CompatibleCpu) {
            Set-VMProcessor -VMName $Name -CompatibilityForMigrationEnabled $true
        }
        Set-VM          -VMName $Name -AutomaticCheckpointsEnabled $false -CheckpointType Standard
        Set-VM          -VMName $Name -AutomaticStartAction Nothing -AutomaticStopAction ShutDown

        Add-VMDvdDrive  -VMName $Name -Path $IsoPath
        $dvd = Get-VMDvdDrive -VMName $Name
        Set-VMFirmware  -VMName $Name -FirstBootDevice $dvd
        Set-VMFirmware  -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'

        # Lets Copy-VMFile put scripts into the guest with no network and no
        # credentials. Off by default on a new VM.
        try { Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface' } catch { }

        [pscustomobject]@{
            Name = $Name; VhdPath = $vhdPath; Path = $Path
            MemoryGB = $MemoryGB; VhdSizeGB = $VhdSizeGB; CpuCount = $CpuCount; Switch = $SwitchName
            CompatibleCpu = [bool]$CompatibleCpu
        }
    }

    Write-WfLog "Created $($result.Name) -- $($result.VhdPath)" -Level OK
    Write-WfLog 'Next: start it, install Windows, and press Ctrl+Shift+F3 at the first OOBE screen.' -Level INFO

    Write-WfHistory -Action 'Reference VM created' -ImagePath $result.VhdPath -Detail @{
        VmName = $result.Name; MemoryGB = $result.MemoryGB; VhdSizeGB = $result.VhdSizeGB
    } | Out-Null

    return $result
}

function Get-WfReferenceVm {
<#
.SYNOPSIS
    State of the reference VM: power state, disk, checkpoints, integration services.
.DESCRIPTION
    One call for everything worth knowing before doing anything to the VM: is it
    running, what is its disk, which checkpoints exist, are the integration
    services up.

    That last one decides whether PowerShell Direct will work, which is how the
    rest of the reference build talks to the guest -- so a VM that is running but
    not answering is worth spotting here rather than three steps later.
.PARAMETER Name
    Defaults to the configured reference VM.
.EXAMPLE
    Get-WfReferenceVm | Format-List
#>
    [CmdletBinding()]
    param([string] $Name)

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    return Invoke-WfVmHostCommand -ArgumentList @($Name) -ScriptBlock {
        param($Name)
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if (-not $vm) {
            return [pscustomobject]@{ Name = $Name; Exists = $false }
        }

        $disk = Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        $snaps = @(Get-VMSnapshot -VMName $Name -ErrorAction SilentlyContinue)
        $gsi = Get-VMIntegrationService -VMName $Name -Name 'Guest Service Interface' -ErrorAction SilentlyContinue

        [pscustomobject]@{
            Name             = $Name
            Exists           = $true
            State            = "$($vm.State)"
            Status           = $vm.Status
            Uptime           = "$($vm.Uptime)"
            MemoryGB         = [math]::Round($vm.MemoryStartup / 1GB, 1)
            CpuCount         = $vm.ProcessorCount
            Generation       = $vm.Generation
            VhdPath          = $disk.Path
            AutomaticCheckpoints = $vm.AutomaticCheckpointsEnabled
            CheckpointType   = "$($vm.CheckpointType)"
            CheckpointCount  = $snaps.Count
            Checkpoints      = @($snaps | Sort-Object CreationTime | ForEach-Object { $_.Name })
            GuestServices    = [bool]$gsi.Enabled
        }
    }
}

function Start-WfReferenceVm {
<#
.SYNOPSIS
    Starts the reference VM, and optionally opens a console window on it.
.DESCRIPTION
    Most of the reference build happens inside the guest with a person watching,
    so starting it and connecting to it are one action often enough to be worth
    one switch.
.PARAMETER Name
    Defaults to the configured reference VM.
.PARAMETER Connect
    Also launch vmconnect against it. Only useful from a machine with a desktop:
    on a remote host it opens the console locally and connects across, which is
    what you want, but from a scheduled task it is noise.
.EXAMPLE
    Start-WfReferenceVm -Connect
#>
    [CmdletBinding()]
    param([string] $Name, [switch] $Connect)

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    Write-WfLog "Starting $Name" -Level STEP
    Invoke-WfVmHostCommand -ArgumentList @($Name) -ScriptBlock {
        param($Name)
        Start-VM -Name $Name -ErrorAction Stop
    }
    Write-WfLog 'Started' -Level OK

    if ($Connect) {
        # vmconnect only makes sense from a machine with the console available.
        $target = $cfg['HyperVHost']
        if (-not $target) { $target = 'localhost' }
        try { Start-Process 'vmconnect.exe' -ArgumentList @($target, $Name) }
        catch { Write-WfLog "Could not launch vmconnect: $($_.Exception.Message)" -Level WARN }
    }
}

function Stop-WfReferenceVm {
<#
.SYNOPSIS
    Shuts the reference VM down cleanly, or pulls the power if you mean to.
.DESCRIPTION
    A clean shutdown by default, because the VM being stopped is usually one
    about to be captured or checkpointed, and a dirty stop leaves a machine whose
    disk state nobody can vouch for.

    -TurnOff is the equivalent of holding the power button. It is instant, it
    risks the file system, and it is occasionally the only thing that works on a
    guest that has stopped responding to the integration services -- so it is
    here, behind a switch, logged as a warning.
.PARAMETER Name
    Defaults to the configured reference VM.
.PARAMETER TurnOff
    Cut the power instead of asking the guest to shut down.
.PARAMETER TimeoutSeconds
    How long to wait for a clean shutdown before giving up and saying so.
.EXAMPLE
    Stop-WfReferenceVm
.EXAMPLE
    Stop-WfReferenceVm -TurnOff
#>
    [CmdletBinding()]
    param(
        [string] $Name,
        [switch] $TurnOff,
        [int]    $TimeoutSeconds = 300
    )

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    if ($TurnOff) {
        Write-WfLog "Turning off $Name (no guest shutdown)" -Level WARN
        Invoke-WfVmHostCommand -ArgumentList @($Name) -ScriptBlock {
            param($Name) Stop-VM -Name $Name -TurnOff -Force -ErrorAction Stop
        }
    }
    else {
        Write-WfLog "Shutting down $Name" -Level STEP
        Invoke-WfVmHostCommand -ArgumentList @($Name, $TimeoutSeconds) -ScriptBlock {
            param($Name, $TimeoutSeconds)
            Stop-VM -Name $Name -Force -ErrorAction Stop
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Get-VM -Name $Name).State -ne 'Off' -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
            }
        }
    }
    Write-WfLog 'Stopped' -Level OK
}

# ------------------------------------------------------------- checkpoints

function New-WfReferenceCheckpoint {
<#
.SYNOPSIS
    Takes a checkpoint of the reference VM.
.DESCRIPTION
    The audit-mode checkpoint taken before sysprep is the real master of this
    whole process: every later rebuild restores it, applies the current update and
    re-seals, instead of starting from the ISO again.
#>
    [CmdletBinding()]
    param(
        [string] $Name,
        [string] $CheckpointName = 'audit-mode pre-sysprep'
    )

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    Write-WfLog "Checkpointing $Name as '$CheckpointName'" -Level STEP
    Invoke-WfVmHostCommand -ArgumentList @($Name, $CheckpointName) -ScriptBlock {
        param($Name, $CheckpointName)
        Checkpoint-VM -Name $Name -SnapshotName $CheckpointName -ErrorAction Stop
    }
    Write-WfLog 'Checkpoint created' -Level OK

    Write-WfHistory -Action 'Reference VM checkpoint' -ImagePath $Name -Detail @{
        VmName = $Name; Checkpoint = $CheckpointName
    } | Out-Null
}

function Get-WfReferenceCheckpoint {
<#
.SYNOPSIS
    The checkpoints on the reference VM, oldest first.
.DESCRIPTION
    Oldest first on purpose: checkpoints form a chain, and reading them in the
    order they were taken is reading the history of the build. The parent column
    is what makes a branched tree legible.

    The one to keep is the pre-sysprep checkpoint. Sealing is one-way, so that
    checkpoint is where next quarter's rebuild starts from -- and losing it means
    building the reference machine again from media.
.PARAMETER Name
    Defaults to the configured reference VM.
.EXAMPLE
    Get-WfReferenceCheckpoint | Format-Table Name, Created, Parent, Type
#>
    [CmdletBinding()]
    param([string] $Name)

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    return Invoke-WfVmHostCommand -ArgumentList @($Name) -ScriptBlock {
        param($Name)
        Get-VMSnapshot -VMName $Name -ErrorAction SilentlyContinue |
            Sort-Object CreationTime |
            Select-Object Name, @{ n = 'Created'; e = { $_.CreationTime } },
                          @{ n = 'Parent'; e = { $_.ParentSnapshotName } },
                          @{ n = 'Type'; e = { "$($_.SnapshotType)" } }
    }
}

function Restore-WfReferenceCheckpoint {
<#
.SYNOPSIS
    Restores the reference VM to a checkpoint. This is how a rebuild starts.
.DESCRIPTION
    High impact and confirmed by default: everything the VM has done since that
    checkpoint is discarded, and Hyper-V does not ask twice.

    The pre-sysprep checkpoint is the one a quarterly rebuild starts from --
    restore it, apply the current cumulative, re-seal, re-capture. Sealing is
    one-way, which is why that checkpoint exists at all.
.PARAMETER CheckpointName
    Exactly as Get-WfReferenceCheckpoint reports it.
.PARAMETER Name
    Defaults to the configured reference VM.
.EXAMPLE
    Restore-WfReferenceCheckpoint -CheckpointName 'pre-sysprep'
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $CheckpointName,
        [string] $Name
    )

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    if (-not $PSCmdlet.ShouldProcess("$Name -> $CheckpointName", 'Restore checkpoint')) { return }

    Write-WfLog "Restoring $Name to '$CheckpointName' -- everything since is discarded" -Level WARN
    Invoke-WfVmHostCommand -ArgumentList @($Name, $CheckpointName) -ScriptBlock {
        param($Name, $CheckpointName)
        $snap = Get-VMSnapshot -VMName $Name -Name $CheckpointName -ErrorAction Stop
        Restore-VMSnapshot -VMSnapshot $snap -Confirm:$false -ErrorAction Stop
    }
    Write-WfLog 'Restored' -Level OK
}

function Remove-WfReferenceCheckpoint {
<#
.SYNOPSIS
    Deletes a checkpoint from the reference VM. There is no undo.
.DESCRIPTION
    High impact, so it confirms unless you say otherwise. Deleting a checkpoint
    merges its differencing disk into the parent -- which can take a while on a
    large VM and cannot be interrupted safely.

    Think twice about the pre-sysprep one. Sealing is one-way, so that checkpoint
    is the only thing standing between a rebuild and starting again from clean
    media.
.PARAMETER CheckpointName
    Exactly as Get-WfReferenceCheckpoint reports it.
.PARAMETER Name
    Defaults to the configured reference VM.
.EXAMPLE
    Remove-WfReferenceCheckpoint -CheckpointName 'before-updates-2026-03'
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $CheckpointName,
        [string] $Name
    )

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    if (-not $PSCmdlet.ShouldProcess("$Name -> $CheckpointName", 'Remove checkpoint')) { return }

    Invoke-WfVmHostCommand -ArgumentList @($Name, $CheckpointName) -ScriptBlock {
        param($Name, $CheckpointName)
        Remove-VMSnapshot -VMName $Name -Name $CheckpointName -Confirm:$false -ErrorAction Stop
    }
    Write-WfLog "Removed checkpoint '$CheckpointName'" -Level OK
}

# ----------------------------------------------------------- inside the VM

function Copy-WfToReferenceVm {
<#
.SYNOPSIS
    Copies a file into the running guest using the Guest Service Interface.
.DESCRIPTION
    Copy-VMFile goes over VMBus, so it needs no network and no credentials --
    handy for getting the preparation scripts and the answer file into an
    audit-mode VM that has never been on a network.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [string] $Name
    )

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }
    $SourcePath = Assert-WfPath -Path $SourcePath -Label 'Source file'

    # For a remote host the file has to reach the host first; Copy-VMFile reads
    # from the host's filesystem, not this workstation's.
    if (Test-WfVmHostIsRemote) {
        Write-WfLog 'Remote host: staging the file to the host first' -Level INFO
        $bytes = [IO.File]::ReadAllBytes($SourcePath)
        $leaf  = Split-Path $SourcePath -Leaf
        Invoke-WfVmHostCommand -ArgumentList @($Name, $leaf, $bytes, $DestinationPath) -ScriptBlock {
            param($Name, $Leaf, $Bytes, $DestinationPath)
            $tmp = [System.IO.Path]::Combine($env:TEMP, $Leaf)
            [IO.File]::WriteAllBytes($tmp, $Bytes)
            Copy-VMFile -Name $Name -SourcePath $tmp -DestinationPath $DestinationPath `
                        -CreateFullPath -FileSource Host -Force -ErrorAction Stop
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Copy-VMFile -Name $Name -SourcePath $SourcePath -DestinationPath $DestinationPath `
                    -CreateFullPath -FileSource Host -Force -ErrorAction Stop
    }

    Write-WfLog "Copied $(Split-Path $SourcePath -Leaf) -> $DestinationPath" -Level OK
    return $DestinationPath
}

function Invoke-WfReferenceCommand {
<#
.SYNOPSIS
    Runs a scriptblock inside the reference VM over PowerShell Direct.
.DESCRIPTION
    PowerShell Direct runs over VMBus rather than the network, so it works on an
    audit-mode VM with no adapter, no firewall rule and no name resolution.

    It does need guest credentials, and the audit-mode Administrator starts with a
    blank password, which Windows will not accept here. Inside the VM, once:

        net user Administrator <password>

    then Set-WfGuestCredential.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList = @(),
        [string]   $Name
    )

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    if (-not $script:WfGuestCredential) {
        throw 'No guest credentials set. Run Set-WfGuestCredential first (and give the audit-mode Administrator a password inside the VM if it still has none).'
    }

    $state = (Get-WfReferenceVm -Name $Name).State
    if ($state -ne 'Running') {
        throw "$Name is $state. Start it before running anything inside it."
    }

    if (Test-WfVmHostIsRemote) {
        # Two hops: WinRM to the host, then PowerShell Direct over VMBus. The
        # second hop is not network authentication, so there is no double-hop
        # credential problem to work around.
        return Invoke-WfVmHostCommand -ArgumentList @($Name, $script:WfGuestCredential, $ScriptBlock.ToString(), $ArgumentList) -ScriptBlock {
            param($Name, $Credential, $BodyText, $Args)
            $sb = [scriptblock]::Create($BodyText)
            $p = @{ VMName = $Name; Credential = $Credential; ScriptBlock = $sb; ErrorAction = 'Stop' }
            if ($Args -and $Args.Count -gt 0) { $p['ArgumentList'] = $Args }
            Invoke-Command @p
        }
    }

    $params = @{
        VMName      = $Name
        Credential  = $script:WfGuestCredential
        ScriptBlock = $ScriptBlock
        ErrorAction = 'Stop'
    }
    if ($ArgumentList.Count -gt 0) { $params['ArgumentList'] = $ArgumentList }
    return Invoke-Command @params
}

function Initialize-WfReferenceBuild {
<#
.SYNOPSIS
    Runs the audit-mode preparation inside the reference VM.
.DESCRIPTION
    The part of the reference build that has to happen inside the guest: the
    audit-mode preparation a captured image should carry, done the same way every
    time instead of from memory at the end of a long afternoon.

    Run against a VM already sitting in audit mode. It talks to the guest over
    PowerShell Direct, so the integration services have to be up --
    Get-WfReferenceVm says whether they are.
.PARAMETER Stage
    Start applies the imaging policies at the beginning of audit mode.
    PreSeal cleans up immediately before sysprep.
.PARAMETER Sysprep
    PreSeal only. Seals the build and shuts the VM down.
.PARAMETER ScriptPath
    Prepare-ReferenceBuild.ps1 on this workstation. It is copied into the guest.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Start','PreSeal')] [string] $Stage,
        [switch] $Sysprep,
        [string] $ScriptPath,
        [string] $UnattendPath,
        [string] $Name
    )

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    if (-not $ScriptPath) {
        $ScriptPath = Join-WfPath (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'ReferenceBuild\Prepare-ReferenceBuild.ps1'
    }
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Prepare-ReferenceBuild.ps1 not found at $ScriptPath. Pass -ScriptPath."
    }

    $guestDir = 'C:\WimForgeBuild'
    Write-WfLog "Copying the preparation script into $Name" -Level STEP
    Copy-WfToReferenceVm -Name $Name -SourcePath $ScriptPath -DestinationPath "$guestDir\Prepare-ReferenceBuild.ps1" | Out-Null

    if ($Sysprep) {
        if (-not $UnattendPath) { $UnattendPath = $cfg['UnattendPath'] }
        if (-not (Test-Path -LiteralPath $UnattendPath)) {
            throw "Answer file not found at $UnattendPath. Set UnattendPath in Settings or pass -UnattendPath."
        }
        Copy-WfToReferenceVm -Name $Name -SourcePath $UnattendPath -DestinationPath "$guestDir\unattend.xml" | Out-Null
    }

    Write-WfLog "Running stage '$Stage' inside $Name" -Level STEP

    $output = Invoke-WfReferenceCommand -Name $Name -ArgumentList @($Stage, [bool]$Sysprep, $guestDir) -ScriptBlock {
        param($Stage, $DoSysprep, $GuestDir)

        $script = Join-Path $GuestDir 'Prepare-ReferenceBuild.ps1'
        $args   = @('-Stage', $Stage)

        if ($DoSysprep) {
            # The interactive SEAL confirmation cannot be answered over
            # PowerShell Direct, so the cleanup runs through the script and the
            # seal is issued directly afterwards. The confirmation has already
            # been given in the front-end.
            & $script -Stage $Stage *>&1 | Out-String
            $unattend = Join-Path $GuestDir 'unattend.xml'
            Start-Process -FilePath 'C:\Windows\System32\Sysprep\sysprep.exe' `
                -ArgumentList @('/generalize', '/oobe', '/shutdown', "/unattend:`"$unattend`"")
            'SYSPREP STARTED -- the VM will shut down. Do not boot it again.'
        }
        else {
            & $script @args *>&1 | Out-String
        }
    }

    foreach ($line in ("$output" -split "`r?`n")) {
        if ($line.Trim()) { Write-WfLog $line -Level INFO }
    }

    if ($Sysprep) {
        Write-WfLog 'Sysprep is running inside the VM. Wait for it to power off, then capture.' -Level WARN
    }
    return $output
}

# ---------------------------------------------------------------- capture

function Get-WfReferenceVhdPath {
<#
.SYNOPSIS
    Where the reference VM's disk is, and how to reach it from here.
.DESCRIPTION
    For a remote host the local path on that server is translated to its
    administrative share (D:\VMs\x.vhdx -> \\server\D$\VMs\x.vhdx) so this
    workstation can copy it. That needs administrative access to the share; if
    the shares are disabled, put the VM files somewhere you share explicitly.
#>
    [CmdletBinding()]
    param([string] $Name)

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    $vm = Get-WfReferenceVm -Name $Name
    if (-not $vm.Exists) { throw "VM '$Name' not found on the host." }
    if (-not $vm.VhdPath) { throw "VM '$Name' has no hard disk attached." }

    $remote = Test-WfVmHostIsRemote
    $access = $vm.VhdPath

    if ($remote) {
        $qualifier = $vm.VhdPath.Substring(0, 1)
        $rest      = $vm.VhdPath.Substring(2).TrimStart('\')
        $access    = "\\$($cfg['HyperVHost'])\$qualifier`$\$rest"
    }

    return [pscustomobject]@{
        VmName     = $Name
        HostPath   = $vm.VhdPath
        AccessPath = $access
        IsRemote   = $remote
        State      = $vm.State
    }
}

function Invoke-WfReferenceCapture {
<#
.SYNOPSIS
    Captures the sealed reference VM into a new base image.
.DESCRIPTION
    Resolves the VM's disk, refuses if the VM is not powered off, and calls
    New-WfCapture.

    For a remote host the VHDX is copied to the local scratch folder first.
    Mount-DiskImage cannot reliably mount a VHDX over a UNC path, and capturing
    across the network would be slower and more fragile than one straight copy.
    Expect the copy to take a while and to need as much scratch space as the disk
    has actually grown to.
#>
    [CmdletBinding()]
    param(
        [string] $Name,
        [string] $DestinationPath,
        [string] $ImageName = 'Windows 10 LTSC Base',
        [string] $Notes,
        [switch] $KeepLocalCopy
    )

    $cfg = Get-WfConfig
    if (-not $Name) { $Name = $cfg['ReferenceVmName'] }

    $info = Get-WfReferenceVhdPath -Name $Name
    if ($info.State -ne 'Off') {
        throw "$Name is $($info.State). A sealed VM must be powered off before capture -- and must not be booted again after sysprep."
    }

    $localVhd = $info.AccessPath
    $copied   = $false

    if ($info.IsRemote) {
        if (-not (Test-Path -LiteralPath $info.AccessPath)) {
            throw "Cannot reach the VM disk at $($info.AccessPath). Administrative shares may be disabled on the host."
        }
        $scratch = New-WfDirectory $cfg['ScratchPath']
        $localVhd = Join-WfPath $scratch (Split-Path $info.HostPath -Leaf)

        $sizeGb = [math]::Round((Get-Item -LiteralPath $info.AccessPath).Length / 1GB, 1)
        Write-WfLog "Copying $sizeGb GB from the remote host to $localVhd -- this takes a while" -Level STEP
        Copy-Item -LiteralPath $info.AccessPath -Destination $localVhd -Force
        $copied = $true
        Write-WfLog 'Copy complete' -Level OK
    }

    try {
        $capture = New-WfCapture -VhdxPath $localVhd -DestinationPath $DestinationPath `
                                  -Name $ImageName -Notes $Notes
    }
    finally {
        if ($copied -and -not $KeepLocalCopy) {
            Write-WfLog 'Removing the local VHDX copy' -Level INFO
            Remove-Item -LiteralPath $localVhd -Force -ErrorAction SilentlyContinue
        }
    }

    return $capture
}
