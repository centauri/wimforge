# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# What the Hyper-V host is asked, and what is made of the answer.
#
# There is no Hyper-V here, so the host seam is stubbed and what gets checked is
# the judgement applied to what comes back. That is where the value is anyway:
# Get-VMSwitch returning a list is not interesting, but deciding that an Internal
# switch is the wrong answer for a reference build is.
#
# The switch case is the one worth having a test for. A name that does not exist
# is rejected by New-VM, loudly, and gets fixed in thirty seconds. An Internal or
# Private switch is ACCEPTED: the VM is created, Windows installs, and the build
# has no route off the host. Nobody finds out until updates will not install,
# which is hours later and looks like a different problem entirely.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

$script:Logged = New-Object System.Collections.Generic.List[object]
function Write-WfLog { param([string] $Message, [string] $Level = 'INFO', [switch] $NoConsole)
    $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message }) }
function Get-WfConfig { $script:Cfg }
function Test-WfVmHostIsRemote { $script:Remote }

# The seam. Everything in VmChoices.ps1 reaches the host through this one
# function, which is the whole reason a remote host needs no special handling --
# and the reason it can be replaced here with a canned answer.
$script:HostReply = { }
$script:HostThrows = $false
function Invoke-WfVmHostCommand {
    param([scriptblock] $ScriptBlock, [object[]] $ArgumentList = @())
    if ($script:HostThrows) { throw 'The RPC server is unavailable.' }
    return (& $script:HostReply @ArgumentList)
}

. (Join-Path $root 'WimForge\Public\VmChoices.ps1')

$script:Cfg    = @{ HyperVHost = ''; ReferenceVmName = 'LTSC2021-POS-Reference'
                    ReferenceIsoPath = ''; ReferenceVmPath = ''; ImageRoot = ''; WorkspaceRoot = '' }
$script:Remote = $false

Write-Host 'Virtual switches -- the one that fails quietly' -ForegroundColor Cyan

$script:HostThrows = $false
$script:HostReply = {
    @(
        [pscustomobject]@{ Name = 'LAN';            Type = 'External'; NetAdapter = 'Intel I219-LM'; Notes = ''; HostPrefix = '';               Natted = $false }
        [pscustomobject]@{ Name = 'Default Switch'; Type = 'Internal'; NetAdapter = '';              Notes = ''; HostPrefix = '172.24.128.1/16'; Natted = $false }
        [pscustomobject]@{ Name = 'NatSwitch';      Type = 'Internal'; NetAdapter = '';              Notes = ''; HostPrefix = '192.168.50.1/24'; Natted = $true  }
        [pscustomobject]@{ Name = 'HostOnly';       Type = 'Internal'; NetAdapter = '';              Notes = ''; HostPrefix = '10.0.0.1/24';     Natted = $false }
        [pscustomobject]@{ Name = 'Isolated';       Type = 'Private';  NetAdapter = '';              Notes = ''; HostPrefix = '';               Natted = $false }
    )
}

$switches = @(Get-WfVmSwitchChoice)
Test-Case 'all five come back' 5 $switches.Count

function Get-Switch { param([string] $Name) @($switches | Where-Object { $_.Name -eq $Name })[0] }

# The bar is "can the build reach Windows Update", not "what type is it". These
# three all clear it and only one of them is External.
Test-Case 'External reaches the internet'       $true (Get-Switch 'LAN').Internet
Test-Case 'the Default Switch does too (ICS)'   $true (Get-Switch 'Default Switch').Internet
Test-Case 'and so does an Internal one with NAT' $true (Get-Switch 'NatSwitch').Internet

# The ones that genuinely do not.
Test-Case 'a bare Internal switch does not' $false (Get-Switch 'HostOnly').Internet
Test-Case 'nor does a Private one'          $false (Get-Switch 'Isolated').Internet

# Inbound is the separate question, and it is the one that decides whether a
# build can pull an installer off a share. Only External answers yes.
Test-Case 'only External can be reached from the LAN' @('LAN') `
    @($switches | Where-Object { $_.Inbound } | ForEach-Object { $_.Name })

# Each says what it means, not what it is called.
Test-Case 'External names the adapter' $true ((Get-Switch 'LAN').What -match 'Intel I219-LM')
Test-Case 'the Default Switch says ICS' $true ((Get-Switch 'Default Switch').What -match 'ICS')
Test-Case 'the NAT one names the network' $true ((Get-Switch 'NatSwitch').What -match '192\.168\.50\.1/24')
Test-Case 'a bare Internal one says no internet' $true ((Get-Switch 'HostOnly').What -match 'no internet')

# Both NAT-style switches warn that nothing can reach the VM, because that is
# the thing somebody will trip over next.
Test-Case 'and both say the LAN cannot reach in' 2 `
    @($switches | Where-Object { $_.Internet -and -not $_.Inbound -and $_.What -match 'nothing on the LAN' }).Count

# Usable first, and the strictly more capable one at the very top.
Test-Case 'External is listed first' 'LAN' $switches[0].Name
Test-Case 'and the useless ones last' @('HostOnly', 'Isolated') `
    @($switches | Select-Object -Last 2 | ForEach-Object { $_.Name })

Write-Host 'When the host has nothing usable, it says so' -ForegroundColor Cyan

$script:Logged.Clear()
$script:HostReply = { @([pscustomobject]@{ Name = 'HostOnly'; Type = 'Internal'; NetAdapter = ''; Notes = ''; HostPrefix = '10.0.0.1/24'; Natted = $false }) }
$none = @(Get-WfVmSwitchChoice)
Test-Case 'still returns it'   1 $none.Count
Test-Case 'and warns'          $true (@($script:Logged | Where-Object { $_.Level -eq 'WARN' -and $_.Message -match 'reach the internet' }).Count -ge 1)
Test-Case 'and says how to fix it' $true (@($script:Logged | Where-Object { $_.Message -match 'NAT|External switch' }).Count -ge 1)

# A host whose only usable switch is NAT-backed is fine for updates, and saying
# nothing would be wrong -- but so would warning as if it were broken.
$script:Logged.Clear()
$script:HostReply = { @([pscustomobject]@{ Name = 'Default Switch'; Type = 'Internal'; NetAdapter = ''; Notes = ''; HostPrefix = '172.24.128.1/16'; Natted = $false }) }
$onlyDefault = @(Get-WfVmSwitchChoice)
Test-Case 'a lone Default Switch is usable' $true $onlyDefault[0].Suitable
Test-Case 'and is not warned about'         0 @($script:Logged | Where-Object { $_.Level -eq 'WARN' }).Count
Test-Case 'but the share caveat is noted'   $true (@($script:Logged | Where-Object { $_.Message -match 'needs an External switch' }).Count -ge 1)

$script:Logged.Clear()
$script:HostReply = { @() }
Test-Case 'no switches at all is an empty list' 0 @(Get-WfVmSwitchChoice).Count
Test-Case 'and says what that costs' $true (@($script:Logged | Where-Object { $_.Message -match 'cannot be updated' }).Count -ge 1)

Write-Host 'A host that cannot be reached is not an exception' -ForegroundColor Cyan

# These are called while a form is being filled in. A throw here takes the tab
# with it, and the operator is left unable to type the answer they already knew.
$script:HostThrows = $true
Test-Case 'switches come back empty'  0 @(Get-WfVmSwitchChoice).Count
Test-Case 'ISOs come back empty'      0 @(Get-WfVmIsoChoice).Count

$facts = Get-WfVmHostFact
Test-Case 'the facts say unreachable' $false $facts.Reachable
Test-Case 'and carry the reason'      $true ($facts.Error -match 'RPC server')

# Sizes must still be offered: they are the one list that does not depend on the
# host, and a host that is switched off should not stop the form being filled in.
$sizes = @(Get-WfVmSizeChoice -Kind Memory -HostFact $facts)
Test-Case 'sizes are still offered'   $true ($sizes.Count -ge 3)
Test-Case 'and none is marked as not fitting' 0 @($sizes | Where-Object { -not $_.Fits }).Count

$suggest = Get-WfVmNameSuggestion -Preferred 'Ref'
Test-Case 'the name falls back to what was asked for' 'Ref' $suggest.Name
$script:HostThrows = $false

Write-Host 'Sizes are capped by what the host actually has' -ForegroundColor Cyan

$big   = [pscustomobject]@{ LogicalProcessors = 16; TotalMemoryGB = 64; AssignedMemoryGB = 0 }
$small = [pscustomobject]@{ LogicalProcessors = 2;  TotalMemoryGB = 8;  AssignedMemoryGB = 0 }

Test-Case 'everything fits on a big host' 0 `
    @(Get-WfVmSizeChoice -Kind Memory -HostFact $big | Where-Object { -not $_.Fits }).Count

# 8 GB total, 4 held back for the host, so 4 is the ceiling: 8 and 16 do not fit.
$tight = @(Get-WfVmSizeChoice -Kind Memory -HostFact $small)
Test-Case 'the big ones are marked on a small host' @(8, 16) `
    @($tight | Where-Object { -not $_.Fits } | ForEach-Object { $_.Value })
Test-Case 'and the default still fits' $true `
    (@($tight | Where-Object { $_.Default })[0].Fits)

# Marked, not hidden. An operator who knows the host is about to have memory
# freed up should still be able to pick it.
Test-Case 'nothing is hidden' 4 $tight.Count
Test-Case 'the note says why'  $true `
    ((@($tight | Where-Object { $_.Value -eq 16 })[0].Note) -match 'more than the host has spare')

$cpu = @(Get-WfVmSizeChoice -Kind Cpu -HostFact $small)
Test-Case 'more vCPU than the host has cores is marked' @(4, 8) `
    @($cpu | Where-Object { -not $_.Fits } | ForEach-Object { $_.Value })

# A thin-provisioned VHDX does not commit the space, so there is no honest
# ceiling to apply and none is invented.
Test-Case 'disk sizes are never marked' 0 `
    @(Get-WfVmSizeChoice -Kind Disk -HostFact $small | Where-Object { -not $_.Fits }).Count

Write-Host 'Exactly one default per kind' -ForegroundColor Cyan
foreach ($kind in @('Memory', 'Disk', 'Cpu')) {
    Test-Case "$kind has one default" 1 `
        @(Get-WfVmSizeChoice -Kind $kind -HostFact $big | Where-Object { $_.Default }).Count
}

Write-Host 'VM names are checked against the host before the form is filled in' -ForegroundColor Cyan

$script:HostReply = { @('LTSC2021-POS-Reference', 'LTSC2021-POS-Reference-2', 'Something else') }

$taken = Get-WfVmNameSuggestion -Preferred 'LTSC2021-POS-Reference'
Test-Case 'a taken name is spotted'    $true  $taken.Taken
Test-Case 'and -3 is suggested'        'LTSC2021-POS-Reference-3' $taken.Name

$free = Get-WfVmNameSuggestion -Preferred 'Brand-New'
Test-Case 'a free name is left alone'  'Brand-New' $free.Name
Test-Case 'and not flagged'            $false      $free.Taken

Write-Host 'ISOs' -ForegroundColor Cyan

$script:HostReply = {
    param($Extra)
    @(
        [pscustomobject]@{ Path = 'D:\ISO\LTSC2021.iso'; Name = 'LTSC2021.iso'; SizeGB = 4.7; Modified = [datetime]'2026-01-04' }
        [pscustomobject]@{ Path = 'D:\ISO\partial.iso';  Name = 'partial.iso';  SizeGB = 0.2; Modified = [datetime]'2026-02-01' }
    )
}

$isos = @(Get-WfVmIsoChoice)
Test-Case 'both are listed' 2 $isos.Count

# A half-downloaded ISO is accepted by New-VM and fails at boot, hours later.
Test-Case 'a full-size one has no note' '' (@($isos | Where-Object { $_.Name -eq 'LTSC2021.iso' })[0].Note)
Test-Case 'a tiny one is called out'    $true `
    ((@($isos | Where-Object { $_.Name -eq 'partial.iso' })[0].Note) -match 'suspiciously small')

Test-Case 'filtering works' 1 @(Get-WfVmIsoChoice -Filter 'LTSC').Count

Write-Host 'Host facts' -ForegroundColor Cyan

$script:HostReply = {
    [pscustomobject]@{
        Reachable = $true; ComputerName = 'HV01'
        VirtualMachinePath = 'D:\VMs'; VirtualHardDiskPath = 'D:\VHDs'
        LogicalProcessors = 8; TotalMemoryGB = 32; FreeMemoryGB = 14
        AssignedMemoryGB = 16; RunningVms = 2; TotalVms = 5; Error = ''
    }
}
$f = Get-WfVmHostFact
Test-Case 'the host folders come back' @('D:\VMs', 'D:\VHDs') @($f.VirtualMachinePath, $f.VirtualHardDiskPath)

# Judged against what is not already committed to running VMs, not against total
# memory -- that is the number that decides whether this VM starts. 32 GB total
# with 16 already handed to running VMs and 4 held back for the host leaves 12,
# so 16 does not fit even though the host has 32.
$m = @(Get-WfVmSizeChoice -Kind Memory -HostFact $f)
Test-Case 'memory is judged against what is spare, not the total' @(16) `
    @($m | Where-Object { -not $_.Fits } | ForEach-Object { $_.Value })
Test-Case 'and 8 still fits inside the 12 that are left' $true `
    (@($m | Where-Object { $_.Value -eq 8 })[0].Fits)

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
