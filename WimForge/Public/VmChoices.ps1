# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    VmChoices.ps1 -- what the Hyper-V host already knows, so it does not have to
    be typed in.

    The reference VM tab used to be eight empty boxes, three of which had to
    match something on the host exactly. A virtual switch name is the worst of
    them: get it wrong and New-VM does not fail -- Hyper-V creates the VM with no
    network, Windows setup runs, and the first sign of trouble is an image with
    no updates and no way to reach a share.

    Everything here asks the host. That is the same host the VM is created on,
    reached through the same Invoke-WfVmHostCommand seam, so a remote host is
    answered as readily as a local one and neither is guessed at.

    The size choices are the exception -- there is no list of "valid" memory
    sizes to read. What there IS on the host is how much memory and how many
    processors it actually has, so the options are capped by that and the ones
    that would overcommit it are marked rather than hidden.
#>

function Get-WfVmHostFact {
<#
.SYNOPSIS
    What the Hyper-V host has and where it keeps things.
.DESCRIPTION
    One round trip for every default the reference VM tab needs: the host's own
    VM and virtual disk folders, how much memory and how many logical processors
    it has, and how much of each is currently spare.

    Used to fill the empty boxes in and to cap the size choices. A reference VM
    given more vCPUs than the host has logical processors will start, and will
    then run the whole build slowly enough to be worth avoiding.
.EXAMPLE
    Get-WfVmHostFact
#>
    [CmdletBinding()]
    param()

    $vmHost = (Get-WfConfig)['HyperVHost']
    if (-not $vmHost) { $vmHost = $env:COMPUTERNAME }

    try {
        $facts = Invoke-WfVmHostCommand -ScriptBlock {
            $ErrorActionPreference = 'SilentlyContinue'

            $h   = Get-VMHost
            $cs  = Get-CimInstance Win32_ComputerSystem
            $os  = Get-CimInstance Win32_OperatingSystem

            # Committed memory is what the running VMs are actually holding, which
            # is a better guide than free physical memory on a host that is doing
            # other things.
            $assigned = 0
            foreach ($vm in @(Get-VM | Where-Object { $_.State -eq 'Running' })) {
                $assigned += $vm.MemoryAssigned
            }

            [pscustomobject]@{
                Reachable        = $true
                ComputerName     = $env:COMPUTERNAME
                VirtualMachinePath = $h.VirtualMachinePath
                VirtualHardDiskPath= $h.VirtualHardDiskPath
                LogicalProcessors  = [int]$cs.NumberOfLogicalProcessors
                TotalMemoryGB      = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
                FreeMemoryGB       = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
                AssignedMemoryGB   = [math]::Round($assigned / 1GB, 1)
                RunningVms         = @(Get-VM | Where-Object { $_.State -eq 'Running' }).Count
                TotalVms           = @(Get-VM).Count
                Error              = ''
            }
        }
    }
    catch {
        Write-WfLog "Could not read the Hyper-V host: $($_.Exception.Message)" -Level WARN
        return [pscustomobject]@{
            Reachable = $false; ComputerName = $vmHost
            VirtualMachinePath = ''; VirtualHardDiskPath = ''
            LogicalProcessors = 0; TotalMemoryGB = 0; FreeMemoryGB = 0
            AssignedMemoryGB = 0; RunningVms = 0; TotalVms = 0
            Error = $_.Exception.Message
        }
    }

    Write-WfLog ("{0}: {1} logical processors, {2} GB, {3} VM(s)" -f `
        $facts.ComputerName, $facts.LogicalProcessors, $facts.TotalMemoryGB, $facts.TotalVms) -Level OK
    return $facts
}

function Get-WfVmSwitchChoice {
<#
.SYNOPSIS
    The virtual switches on the Hyper-V host, and what each one would mean.
.DESCRIPTION
    The single most valuable list here. A switch name that does not exist is
    rejected outright, which is fine -- but naming one with no route out is
    worse, because it works. The VM is created, Windows installs, and the build
    cannot reach Windows Update. Nobody notices until halfway through the day.

    Judged on what each switch can actually DO, not on its type, because those
    are different questions:

      External          internet and the LAN. The only kind a share can reach.
      Default Switch    reported as Internal, but Windows client Hyper-V gives it
                        internet through ICS. Often the only switch on a laptop.
      Internal + NAT    internet through a Get-NetNat on the host. Same story.
      Internal, bare    genuinely nothing -- host only.
      Private           VM to VM, not even the host.

    Classifying on SwitchType alone would call the middle two useless, which is
    wrong and, on a machine that only has a Default Switch, leaves an operator
    with no usable option and no explanation.

    Internet and inbound are reported separately. A build that only needs updates
    is happy on any of the first three; a build that pulls an installer off a
    share needs External.
.PARAMETER Filter
    Narrows by name or by adapter.
.EXAMPLE
    Get-WfVmSwitchChoice
#>
    [CmdletBinding()]
    param([string] $Filter)

    try {
        $switches = Invoke-WfVmHostCommand -ScriptBlock {
            $ErrorActionPreference = 'SilentlyContinue'

            # NAT is why the switch TYPE on its own is not the answer. An
            # Internal switch with a NAT behind it reaches the internet as
            # happily as an External one; the type field says nothing about it.
            $nats = @(Get-NetNat | ForEach-Object { "$($_.InternalIPInterfaceAddressPrefix)" })

            foreach ($s in @(Get-VMSwitch)) {
                # Each switch has a host-side vEthernet adapter, and its address
                # is what a NAT prefix would have to contain.
                $prefix = ''
                $ip = Get-NetIPAddress -InterfaceAlias "vEthernet ($($s.Name))" -AddressFamily IPv4 |
                      Select-Object -First 1
                if ($ip) { $prefix = "$($ip.IPAddress)/$($ip.PrefixLength)" }

                $natted = $false
                if ($ip) {
                    foreach ($n in $nats) {
                        # Compared on the network part only. A NAT declared as
                        # 172.24.0.0/16 and an adapter on 172.24.128.1/16 are the
                        # same network, and string equality would miss it.
                        $parts = $n -split '/'
                        if ($parts.Count -ne 2) { continue }
                        if ([int]$parts[1] -ne $ip.PrefixLength) { continue }

                        $a = ([ipaddress]$parts[0]).GetAddressBytes()
                        $b = ([ipaddress]$ip.IPAddress).GetAddressBytes()
                        $bits = [int]$parts[1]
                        $same = $true
                        for ($i = 0; $i -lt 4; $i++) {
                            $take = [Math]::Max(0, [Math]::Min(8, $bits - ($i * 8)))
                            if ($take -eq 0) { break }
                            $mask = [byte](0xFF -shl (8 - $take))
                            if (($a[$i] -band $mask) -ne ($b[$i] -band $mask)) { $same = $false; break }
                        }
                        if ($same) { $natted = $true; break }
                    }
                }

                [pscustomobject]@{
                    Name        = $s.Name
                    Type        = "$($s.SwitchType)"
                    NetAdapter  = "$($s.NetAdapterInterfaceDescription)"
                    Notes       = "$($s.Notes)"
                    HostPrefix  = $prefix
                    Natted      = $natted
                }
            }
        }
    }
    catch {
        Write-WfLog "Could not list the virtual switches: $($_.Exception.Message)" -Level WARN
        return @()
    }

    $out = foreach ($s in @($switches | Where-Object { $_ })) {
        # What it MEANS, not what it is called, and the two are not the same
        # thing. Classifying on SwitchType alone says every Internal switch has
        # no route out -- which is wrong for the two cases that matter most on a
        # workstation:
        #
        #   Default Switch   Windows client Hyper-V creates it, reports it as
        #                    Internal, and gives it internet through ICS. It is
        #                    frequently the ONLY switch on a laptop, so calling
        #                    it useless leaves an operator with no usable option
        #                    at all and no idea why.
        #   a NAT switch     an Internal switch with a Get-NetNat behind it, which
        #                    is the standard way to give VMs internet without
        #                    touching the host's physical adapter.
        #
        # Both reach Windows Update. Neither is reachable FROM the network, which
        # matters separately: a build that has to be pulled from a share needs
        # External, and a build that only needs updates does not.
        $isDefault = ($s.Name -eq 'Default Switch')
        $internet  = $false
        $inbound   = $false

        $what = switch ($s.Type) {
            'External' {
                $internet = $true
                $inbound  = $true
                if ($s.NetAdapter) { "internet and the LAN, through $($s.NetAdapter)" }
                else               { 'internet and the LAN' }
            }
            'Internal' {
                if ($isDefault) {
                    $internet = $true
                    'internet through the host (ICS) -- fine for updates, but nothing on the LAN can reach the VM'
                }
                elseif ($s.Natted) {
                    $internet = $true
                    "internet through a NAT on the host ($($s.HostPrefix)) -- fine for updates, but nothing on the LAN can reach the VM"
                }
                else {
                    'host only -- no NAT behind it, so no internet, no updates and no shares'
                }
            }
            'Private' { 'VM to VM only -- not even the host, let alone the internet' }
            default   { "type $($s.Type)" }
        }

        [pscustomobject]@{
            Name       = $s.Name
            Type       = $s.Type
            What       = $what
            NetAdapter = $s.NetAdapter
            Internet   = $internet
            Inbound    = $inbound
            # A reference build needs to reach Windows Update. That is the bar --
            # not the switch type, and not whether anything can reach back.
            Suitable   = $internet
        }
    }

    $out = @($out)
    if ($Filter) {
        $out = @($out | Where-Object { $_.Name -like "*$Filter*" -or $_.NetAdapter -like "*$Filter*" })
    }

    if ($out.Count -eq 0) {
        Write-WfLog 'No virtual switches on the host. A reference build with no network can still be made, but it cannot be updated.' -Level WARN
        Write-WfLog 'On Windows client Hyper-V there is normally a "Default Switch" that gives internet through ICS. If it is gone, make an External switch in Hyper-V Manager -- note that doing so briefly drops the host off the network.' -Level INFO
    }
    elseif (-not ($out | Where-Object { $_.Internet })) {
        Write-WfLog 'None of the switches on the host reach the internet, so a build on any of them cannot take updates.' -Level WARN
        Write-WfLog 'Either add a NAT to one of the Internal switches, or make an External switch in Hyper-V Manager.' -Level INFO
    }
    elseif (-not ($out | Where-Object { $_.Inbound })) {
        Write-WfLog 'The usable switches reach the internet but nothing on the LAN can reach the VM. Fine for updates; a build that pulls from a share needs an External switch.' -Level INFO
    }

    # Usable first, and among those the ones the LAN can also reach back into,
    # because that is the strictly more capable answer.
    return @($out | Sort-Object @{ E = { -not $_.Internet } }, @{ E = { -not $_.Inbound } }, Name)
}

function Get-WfVmIsoChoice {
<#
.SYNOPSIS
    Installation ISOs that are actually on the Hyper-V host.
.DESCRIPTION
    The ISO path is a path on the HOST, not on this workstation, which is the
    detail that catches people out when the host is a server somewhere. Browsing
    for it locally finds the wrong file or no file at all.

    So this looks where ISOs usually are on that host -- next to the VMs, next to
    the virtual disks, and in the obvious folders -- and reports what it finds
    with size and age, so a half-downloaded one is visible before it is used.
.PARAMETER SearchPath
    Extra folders on the host to look in.
.PARAMETER Filter
    Narrows by file name.
.EXAMPLE
    Get-WfVmIsoChoice -Filter LTSC
#>
    [CmdletBinding()]
    param(
        [string[]] $SearchPath,
        [string]   $Filter
    )

    $cfg   = Get-WfConfig
    $extra = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($SearchPath | Where-Object { $_ })) { $extra.Add($p) }

    # The configured ISO's own folder, so a working setup keeps finding what it
    # was already using.
    if ($cfg['ReferenceIsoPath']) {
        $parent = $cfg['ReferenceIsoPath'] -replace '[\\/][^\\/]+$', ''
        if ($parent -and $parent -ne $cfg['ReferenceIsoPath']) { $extra.Add($parent) }
    }
    if ($cfg['ReferenceVmPath']) { $extra.Add($cfg['ReferenceVmPath']) }

    # Only meaningful when the host IS this machine; on a remote host these are
    # simply folders that will not exist, and are skipped there.
    if (-not (Test-WfVmHostIsRemote)) {
        if ($cfg['ImageRoot'])     { $extra.Add($cfg['ImageRoot']) }
        if ($cfg['WorkspaceRoot']) { $extra.Add($cfg['WorkspaceRoot']) }
    }

    try {
        $found = Invoke-WfVmHostCommand -ArgumentList @(, $extra.ToArray()) -ScriptBlock {
            param([string[]] $Extra)
            $ErrorActionPreference = 'SilentlyContinue'

            $roots = New-Object System.Collections.Generic.List[string]
            foreach ($e in @($Extra | Where-Object { $_ })) { $roots.Add($e) }

            $h = Get-VMHost
            if ($h.VirtualMachinePath)  { $roots.Add($h.VirtualMachinePath) }
            if ($h.VirtualHardDiskPath) { $roots.Add($h.VirtualHardDiskPath) }
            foreach ($guess in @('C:\ISO', 'C:\Images', 'C:\Imaging', 'D:\ISO', 'D:\Images', 'D:\Imaging')) {
                $roots.Add($guess)
            }

            $seen = @{}
            foreach ($r in ($roots | Where-Object { $_ } | Sort-Object -Unique)) {
                if (-not (Test-Path -LiteralPath $r)) { continue }

                # Two levels only. A recursive sweep of a virtual disk folder on a
                # busy host takes long enough that it looks like a hang.
                foreach ($f in @(Get-ChildItem -LiteralPath $r -Filter '*.iso' -File -Depth 1 -ErrorAction SilentlyContinue)) {
                    if ($seen.ContainsKey($f.FullName)) { continue }
                    $seen[$f.FullName] = $true
                    [pscustomobject]@{
                        Path     = $f.FullName
                        Name     = $f.Name
                        SizeGB   = [math]::Round($f.Length / 1GB, 2)
                        Modified = $f.LastWriteTime
                    }
                }
            }
        }
    }
    catch {
        Write-WfLog "Could not search the host for ISOs: $($_.Exception.Message)" -Level WARN
        return @()
    }

    $out = @($found | Where-Object { $_ })

    if ($Filter) { $out = @($out | Where-Object { $_.Name -like "*$Filter*" -or $_.Path -like "*$Filter*" }) }

    foreach ($iso in $out) {
        # A Windows installation ISO is several GB. Anything much smaller is a
        # partial download or the wrong file, and it is better to see that here
        # than after New-VM has accepted it.
        $note = ''
        if ($iso.SizeGB -lt 1) { $note = 'suspiciously small for an installation ISO' }
        $iso | Add-Member -NotePropertyName Note -NotePropertyValue $note -Force
    }

    Write-WfLog ("{0} ISO(s) found on the host" -f $out.Count) -Level OK
    if ($out.Count -eq 0) {
        Write-WfLog 'None found in the usual places. Give the full path as the host sees it, or add a folder with -SearchPath.' -Level INFO
    }

    return @($out | Sort-Object Name)
}

function Get-WfVmSizeChoice {
<#
.SYNOPSIS
    Sensible memory, disk and processor sizes for a reference build, capped by
    what the host actually has.
.DESCRIPTION
    There is no list of valid sizes to read off a host, so these are the sizes
    worth offering for THIS job -- a machine that installs Windows, takes
    updates, gets sysprepped and is then thrown away.

    What is read from the host is how much it has, so an option that would
    overcommit it comes back marked rather than silently offered. A reference VM
    with more vCPUs than the host has logical processors starts perfectly well
    and then runs the build slowly enough to matter.

    The defaults are the ones that suit the job rather than the biggest that
    would fit. More memory does not make Windows install faster; a bigger disk
    makes the capture take longer for nothing.
.PARAMETER Kind
    Memory, Disk or Cpu.
.PARAMETER HostFact
    A Get-WfVmHostFact result, if one has already been read. Saves a round trip.
.EXAMPLE
    Get-WfVmSizeChoice -Kind Memory
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Memory', 'Disk', 'Cpu')]
        [string] $Kind,

        [object] $HostFact
    )

    if (-not $HostFact) { $HostFact = Get-WfVmHostFact }

    $rows = switch ($Kind) {
        'Memory' {
            @(
                @{ Value = 2;  Note = 'enough to install, tight once updates run' }
                @{ Value = 4;  Note = 'the sensible default -- installs and services comfortably'; Default = $true }
                @{ Value = 8;  Note = 'faster servicing if the host has it spare' }
                @{ Value = 16; Note = 'more than this build can use' }
            )
        }
        'Disk' {
            @(
                @{ Value = 60;  Note = 'enough for LTSC plus a cumulative update, with little room' }
                @{ Value = 80;  Note = 'the sensible default -- room for updates and a payload'; Default = $true }
                @{ Value = 127; Note = 'the largest a Gen 2 VM boots from without extra steps' }
                @{ Value = 256; Note = 'only if applications go into the reference build' }
            )
        }
        'Cpu' {
            @(
                @{ Value = 1; Note = 'installs, but slowly' }
                @{ Value = 2; Note = 'the sensible default'; Default = $true }
                @{ Value = 4; Note = 'noticeably quicker through servicing' }
                @{ Value = 8; Note = 'diminishing returns for this job' }
            )
        }
    }

    # What the host can actually back. Memory is judged against what is not
    # already committed to running VMs, because that is the number that decides
    # whether this one starts.
    $ceiling = 0
    $unit    = ''
    switch ($Kind) {
        'Memory' {
            $unit = 'GB'
            if ($HostFact.TotalMemoryGB) {
                # Leave the host something to run on.
                $ceiling = [math]::Floor($HostFact.TotalMemoryGB - $HostFact.AssignedMemoryGB - 4)
            }
        }
        'Cpu'  { $unit = ''; $ceiling = $HostFact.LogicalProcessors }
        'Disk' { $unit = 'GB'; $ceiling = 0 }   # thin-provisioned, so no useful ceiling
    }

    $out = foreach ($r in $rows) {
        $fits = $true
        $note = $r.Note
        if ($ceiling -gt 0 -and $r.Value -gt $ceiling) {
            $fits = $false
            $note = "$note -- more than the host has spare ($ceiling$unit)"
        }

        [pscustomobject]@{
            Value   = $r.Value
            Label   = ('{0}{1}' -f $r.Value, $unit)
            Note    = $note
            Fits    = $fits
            Default = [bool]$r.Default
        }
    }

    return @($out)
}

function Get-WfVmNameSuggestion {
<#
.SYNOPSIS
    A VM name that is not already taken on the host.
.DESCRIPTION
    New-VM refuses a duplicate name, which is correct and is also the point at
    which somebody discovers that last month's reference build is still sitting
    there. Better to see it before filling the rest of the form in.

    Returns the configured name when it is free, and the same name with a suffix
    when it is not, along with what is already there.
.EXAMPLE
    Get-WfVmNameSuggestion
#>
    [CmdletBinding()]
    param([string] $Preferred)

    $cfg = Get-WfConfig
    if (-not $Preferred) { $Preferred = $cfg['ReferenceVmName'] }
    if (-not $Preferred) { $Preferred = 'Reference' }

    $existing = @()
    try {
        $existing = @(Invoke-WfVmHostCommand -ScriptBlock {
            $ErrorActionPreference = 'SilentlyContinue'
            @(Get-VM | ForEach-Object { $_.Name })
        })
    }
    catch {
        Write-WfLog "Could not list the VMs on the host: $($_.Exception.Message)" -Level WARN
        return [pscustomobject]@{ Name = $Preferred; Taken = $false; Existing = @() }
    }

    $taken = ($existing -contains $Preferred)
    $name  = $Preferred

    if ($taken) {
        # -2, -3 and so on rather than a date: a name with a date in it stops
        # matching the configured one and every later run suggests another.
        for ($i = 2; $i -lt 50; $i++) {
            $try = "$Preferred-$i"
            if ($existing -notcontains $try) { $name = $try; break }
        }
        Write-WfLog "'$Preferred' already exists on the host -- suggesting '$name'." -Level WARN
    }

    return [pscustomobject]@{
        Name     = $name
        Taken    = $taken
        Existing = @($existing | Sort-Object)
    }
}
