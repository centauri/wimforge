# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# How a package is handed to DISM -- cmdlet or dism.exe -- and why it matters.
#
# The whole reason this file exists, in one paragraph:
#
# A Windows 11 24H2 cumulative is a UUP package in WIM-format .msu clothing, and
# DISM does not unpack those itself -- it asks the Windows Update Agent to, over
# COM. Add-WindowsPackage loads DISM in-process inside the PowerShell host, and
# on a hardened workstation that COM activation is refused: 0x800401E3,
# MK_E_UNAVAILABLE, surfacing three layers up as "An error occurred applying the
# Unattend.xml file from the .msu package". Five attempts, five failures.
#
# The same package, the same mounted image, applied with dism.exe /Add-Package:
# "The operation completed successfully."
#
# So the routing is not a preference. It is the fix, and it is invisible in the
# source unless something checks it -- which is what these cases do. Everything
# that could have been checked instead had already been eliminated by then: the
# download was SHA-verified, the host stack was newer than the image, there was
# 244 GB of scratch, wuauserv was running, and a clean vanilla image failed the
# same way.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Private\Core.ps1')
. (Join-Path $root 'WimForge\Public\DismErrors.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

function Write-WfLog { param([string]$Message, [string]$Level, [switch]$NoConsole) }

# ------------------------------------------------------------- real files
# Real bytes on disk, because the decision is made by reading the first eight of
# them. A stubbed Test-WfUpdateContainer would test the stub.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wf-pkg-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function New-HeaderFile {
    param([string] $Name, [byte[]] $Magic)
    $path  = Join-Path $tmp $Name
    $bytes = New-Object byte[] 64
    [Array]::Copy($Magic, $bytes, $Magic.Length)
    [IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

$wimMsu = New-HeaderFile 'windows11.0-kb5121767-x64.msu' ([Text.Encoding]::ASCII.GetBytes('MSWIM'))
$cabMsu = New-HeaderFile 'windows10.0-kb5074000-x64.msu' ([Text.Encoding]::ASCII.GetBytes('MSCF'))

# ---------------------------------------------------------------- stubs
$script:CmdletCalls = @()
$script:DismCalls   = @()

function Add-WindowsPackage {
    param([string]$Path, [string]$PackagePath, [string]$ErrorAction, [string]$ScratchDirectory, [string]$LogPath)
    $script:CmdletCalls += [pscustomobject]@{
        Path = $Path; PackagePath = $PackagePath
        ScratchDirectory = $ScratchDirectory; LogPath = $LogPath
    }
}
function Invoke-WfDism {
    param([string[]] $Arguments, [switch] $PassThruOutput)
    $script:DismCalls += ,$Arguments
}

# ------------------------------------------------- a cabinet keeps the cmdlet
Write-Host 'A cabinet-format package still goes through the cmdlet' -ForegroundColor Cyan

$script:CmdletCalls = @(); $script:DismCalls = @()
$how = Add-WfPackageOffline -MountPath 'C:\WimMount' -PackagePath $cabMsu -ScratchDirectory 'C:\Scratch'

Test-Case 'reported as the cmdlet'  'Cmdlet' $how
Test-Case 'the cmdlet was called'   1        $script:CmdletCalls.Count
Test-Case 'dism.exe was not'        0        $script:DismCalls.Count
Test-Case 'with the mount'          'C:\WimMount' $script:CmdletCalls[0].Path
Test-Case 'and the scratch folder'  'C:\Scratch'  $script:CmdletCalls[0].ScratchDirectory

# Nothing about the old path was broken for cabinets, and a Windows 10 image
# serviced this way applied 46 minutes' worth of updates without complaint.
# Changing it as well would have been a change made on no evidence.

# ------------------------------------------------- a WIM must not use the cmdlet
Write-Host 'A WIM-format .msu goes to dism.exe, never the cmdlet' -ForegroundColor Cyan

$script:CmdletCalls = @(); $script:DismCalls = @()
$how = Add-WfPackageOffline -MountPath 'C:\WimMount' -PackagePath $wimMsu `
                            -ScratchDirectory 'C:\Scratch' -LogPath 'C:\Logs\dism-kb.log'

Test-Case 'reported as dism.exe'      'DismExe' $how
Test-Case 'dism.exe was called once'  1         $script:DismCalls.Count

# This is the assertion that would have caught the whole evening: the cmdlet is
# the thing that fails, so the test that matters is that it was NOT reached.
Test-Case 'the cmdlet was not touched' 0 $script:CmdletCalls.Count

$a = $script:DismCalls[0]
Test-Case 'offline, against the mount' $true ($a -contains '/Image:C:\WimMount')
Test-Case 'adding a package'           $true ($a -contains '/Add-Package')
Test-Case 'naming the package'         $true ($a -contains "/PackagePath:$wimMsu")
Test-Case 'with the scratch folder'    $true ($a -contains '/ScratchDir:C:\Scratch')
Test-Case 'and its own log'            $true ($a -contains '/LogPath:C:\Logs\dism-kb.log')

# ---------------------------------------------------- trailing backslashes
Write-Host 'Trailing backslashes are trimmed before the command line' -ForegroundColor Cyan

# PowerShell quotes an argument containing a space, and a trailing \ then escapes
# the closing quote -- dism.exe receives one mangled argument and reports
# something that has nothing to do with the real problem. A scratch path typed
# with a trailing slash is entirely normal, so this cannot be left to luck.
$script:DismCalls = @()
$null = Add-WfPackageOffline -MountPath 'C:\WimMount\' -PackagePath $wimMsu -ScratchDirectory 'C:\Scratch\'
$a = $script:DismCalls[0]
Test-Case 'the mount has no trailing slash'   $true ($a -contains '/Image:C:\WimMount')
Test-Case 'the scratch has no trailing slash' $true ($a -contains '/ScratchDir:C:\Scratch')

# ------------------------------------------------------- optional arguments
Write-Host 'Nothing is passed that was not asked for' -ForegroundColor Cyan
$script:DismCalls = @()
$null = Add-WfPackageOffline -MountPath 'C:\WimMount' -PackagePath $wimMsu
$a = $script:DismCalls[0]
Test-Case 'no empty /ScratchDir' $false ([bool](@($a | Where-Object { $_ -like '/ScratchDir:*' }).Count))
Test-Case 'no empty /LogPath'    $false ([bool](@($a | Where-Object { $_ -like '/LogPath:*' }).Count))

# --------------------------------------------- nothing else calls the cmdlet
Write-Host 'The servicing paths do not call Add-WindowsPackage directly' -ForegroundColor Cyan

# A source check rather than a behavioural one, deliberately: the failure mode is
# somebody adding a second apply site later -- in a new function, or by copying
# an old line back in -- and no behavioural test covers code that does not exist
# yet. Every apply must go through the one function that knows about the split.
foreach ($f in @('WimForge\Public\Servicing.ps1', 'WimForge\Public\ReferenceImage.ps1')) {
    $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw

    # Comments may name it -- explaining why it is not used is the point of them.
    $calls = @([regex]::Matches($src, '(?m)^\s*(?!#)[^\r\n]*?(\$null\s*=\s*)?Add-WindowsPackage\s') |
               ForEach-Object { $_.Value.Trim() })

    Test-Case "$(Split-Path $f -Leaf) has no direct call" @() $calls
    Test-Case "$(Split-Path $f -Leaf) uses the helper"    $true ($src -match 'Add-WfPackageOffline')
}

# ------------------------------------------------ the exception keeps the code
Write-Host 'A dism.exe failure still carries a code the classifier can read' -ForegroundColor Cyan

# dism.exe reports the HRESULT in its OUTPUT and returns a decimal exit status
# that does not match it. Throwing "exit 2" alone would mean every failure on the
# new path came back unrecognised -- trading a wrong diagnosis for no diagnosis,
# which is not an improvement.
$core = Get-Content -LiteralPath (Join-Path $root 'WimForge\Private\Core.ps1') -Raw
Test-Case 'the failure text is collected' $true ($core.Contains('$detail = @($state.Kept | Where-Object'))
Test-Case 'and reaches the exception'     $true ($core -match 'dism\.exe failed \(exit \{0\}\)\{1\}')

# And it classifies, which is the point of carrying it.
$why = Get-WfDismError -Message 'dism.exe failed (exit 2) -- Error: 0x800f081e The specified package is not applicable. Arguments: /Image:C:\WimMount /Add-Package'
Test-Case 'the code is recovered' '0x800f081e' $why.Code
Test-Case 'and understood'        $true        $why.Recognised
Test-Case 'and not called fatal'  $false       $why.Fatal

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
