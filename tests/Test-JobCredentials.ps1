# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Credentials set in the GUI have to reach the jobs the GUI starts.
#
# Set-WfGuestCredential and Set-WfHostCredential keep the credential in the
# module's script scope. The GUI calls them on the UI thread, but every button
# that does work runs in a fresh runspace that imports the module again -- a
# different script scope, where the credential was never set. The symptom was
# "Guest credentials set for Administrator" followed on the very next line by
# "No guest credentials set" from Run in guest.
#
# This runs the GUI's real Start-WfJob, lifted out of the script by its AST, with
# the Hyper-V cmdlets stubbed inside the job. No Hyper-V, no elevation.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wf-jobcred-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$ConfigPath = Join-Path $tmp 'config.json'
@{ HyperVHost = ''; ReferenceVmName = 'RefVM'; LogRoot = (Join-Path $tmp 'logs') } |
    ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

try {
    $script:ModulePath = Join-Path $root 'WimForge\WimForge.psd1'
    Import-Module $script:ModulePath -Force
    Get-WfConfig -Path $ConfigPath | Out-Null
    Register-WfLogSink -Sink { param($Line, $Level) }

    # The launcher, exactly as the GUI defines it.
    $gui = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'Start-WimForgeGui.ps1'), [ref]$null, [ref]$null)
    $def = $gui.Find({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-WfJob' }, $true)
    . ([scriptblock]::Create($def.Extent.Text))

    $script:Sync = [hashtable]::Synchronized(@{
        Queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        Running = $false; Result = $null; Error = $null })

    function Invoke-Job {
        param([scriptblock] $Body)
        Start-WfJob -Title 'test' -Body $Body
        $deadline = (Get-Date).AddSeconds(60)
        while ($script:Sync.Running -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        $script:PowerShell.Dispose(); $script:Runspace.Close()
        return $script:Sync
    }

    # Everything the reference VM functions ask the host, answered in the job.
    $stubs = {
        function global:Get-VM { param($Name) [pscustomobject]@{ State = 'Running'; Status = 'OK'; Uptime = 0; MemoryStartup = 4GB; ProcessorCount = 2; Generation = 2; AutomaticCheckpointsEnabled = $false; CheckpointType = 'Production' } }
        function global:Get-VMHardDiskDrive { param($VMName) [pscustomobject]@{ Path = 'D:\VM\ref.vhdx' } }
        function global:Get-VMSnapshot { param($VMName) }
        function global:Get-VMIntegrationService { param($VMName, $Name) [pscustomobject]@{ Enabled = $false } }
        function global:Invoke-Command { param($VMName, $Credential, $ScriptBlock, $ArgumentList) "direct:$VMName as $($Credential.UserName)" }
    }.ToString()

    $pw = ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force

    Write-Host 'With nothing set, a job has nothing' -ForegroundColor Cyan
    $r = Invoke-Job { & (Get-Module WimForge) { "$($script:WfGuestCredential.UserName)|$($script:WfHostCredential.UserName)" } }
    Test-Case 'no guest and no host credential' '|' $r.Result

    Write-Host 'Credentials set on the UI thread reach the job' -ForegroundColor Cyan
    Set-WfGuestCredential -Credential ([pscredential]::new('Administrator', $pw)) | Out-Null
    Set-WfHostCredential  -Credential ([pscredential]::new('HV01\builder', $pw)) | Out-Null

    $r = Invoke-Job { & (Get-Module WimForge) { "$($script:WfGuestCredential.UserName)|$($script:WfHostCredential.UserName)" } }
    Test-Case 'both arrive' 'Administrator|HV01\builder' $r.Result
    Test-Case 'without an error' '' "$($r.Error)"

    # Handed over quietly: the "stored" line belongs to the click that set them,
    # not to the top of every job afterwards.
    $lines = @(); $l = $null
    while ($r.Queue.TryDequeue([ref]$l)) { $lines += $l }
    Test-Case 'and the job does not announce them again' 0 @($lines | Where-Object { $_ -match 'credentials stored' }).Count

    Write-Host 'Run in guest gets past the credential check' -ForegroundColor Cyan
    $r = Invoke-Job ([scriptblock]::Create($stubs + "`n" + 'Invoke-WfReferenceCommand -ScriptBlock { hostname }'))
    Test-Case 'PowerShell Direct is called with the guest credential' 'direct:RefVM as Administrator' $r.Result
    Test-Case 'and nothing is thrown' '' "$($r.Error)"

    Write-Host 'Copy into the VM says how to turn guest services on' -ForegroundColor Cyan
    $src = Join-Path $tmp 'payload.txt'; Set-Content -LiteralPath $src -Value 'x'
    $r = Invoke-Job ([scriptblock]::Create($stubs + "`n" + "Copy-WfToReferenceVm -SourcePath '$src' -DestinationPath 'C:\Temp\payload.txt'"))
    Test-Case 'the copy is refused' $true ([bool]$r.Error)
    Test-Case 'naming the cause' $true ("$($r.Error)" -match 'Guest Service Interface is off on RefVM')
    Test-Case 'and giving the command' $true `
        ("$($r.Error)".Contains("Enable-VMIntegrationService -VMName 'RefVM' -Name 'Guest Service Interface'"))
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
