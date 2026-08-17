# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The native WIM reader: does the C# compile, and does it fail softly?
#
# The extraction itself cannot be tested without Windows and a real image. What
# CAN be tested anywhere is the part that would break the toolkit rather than
# just slow it down: a P/Invoke surface that does not compile, or a failure that
# throws instead of returning $null and so takes out the caller that was meant
# to fall back to mounting.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

$script:Logged = @()
function Write-WfLog { param([string]$Message, [string]$Level) $script:Logged += @("$Level|$Message") }
function Join-WfPath { param([string]$Path, [string]$ChildPath) return (Join-Path $Path $ChildPath) }

. (Join-Path $root 'WimForge\Private\NativeWim.ps1')

Write-Host 'The P/Invoke surface compiles' -ForegroundColor Cyan
Test-Case 'initialised'  $true (Initialize-WfNativeWim)
$type = 'WimForge.NativeWim' -as [type]
Test-Case 'type exists'  $true ($null -ne $type)

$names = @($type.GetMethods() | Where-Object { $_.IsStatic -and $_.DeclaringType -eq $type } |
           ForEach-Object { $_.Name } | Sort-Object)
Test-Case 'every import present' `
    @('ExtractPath','WIMCloseHandle','WIMCreateFile','WIMExtractImagePath','WIMGetImageCount','WIMLoadImage','WIMSetTemporaryPath') `
    $names

# Add-Type on an already-defined type throws, which would turn a second read
# into a hard failure.
Test-Case 'safe to call twice' $true (Initialize-WfNativeWim)

Write-Host 'Failures come back as $null, never as an exception' -ForegroundColor Cyan
# The caller falls back to mounting on $null. If this threw instead, the whole
# detection would die on a machine where wimgapi behaved unexpectedly.
$script:Logged = @()
$missing = Join-Path ([IO.Path]::GetTempPath()) 'wf-does-not-exist.wim'
$r = Export-WfImageFile -ImagePath $missing -SourcePath '\Windows\System32\config\SOFTWARE' `
                        -Destination (Join-Path ([IO.Path]::GetTempPath()) 'out.bin')
Test-Case 'null for a missing image' $true ($null -eq $r)
Test-Case 'and it said so'           $true ([bool]($script:Logged -match 'Image not found'))

# A file that exists but is not a WIM, on a machine that may not even have
# wimgapi: either way this must return $null quietly.
$notAWim = Join-Path ([IO.Path]::GetTempPath()) 'wf-not-a.wim'
Set-Content -LiteralPath $notAWim -Value 'definitely not a wim' -Force
$script:Logged = @()
$threw = $false
$r2 = $null
try {
    $r2 = Export-WfImageFile -ImagePath $notAWim -SourcePath 'Windows\System32\config\SOFTWARE' `
                             -Destination (Join-Path ([IO.Path]::GetTempPath()) 'out.bin')
}
catch { $threw = $true }
Test-Case 'did not throw'   $false $threw
Test-Case 'returned null'   $true  ($null -eq $r2)
Test-Case 'logged a reason' $true  ($script:Logged.Count -gt 0)

Remove-Item -LiteralPath $notAWim -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
