# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Telling Microsoft-provided driver packages apart from vendor ones.
#
# The consequence of getting this wrong is asymmetric. Keeping a Microsoft
# package that could have been dropped costs disk. Dropping a vendor package
# because its provider string happened to contain the word Microsoft costs a
# terminal its touchscreen, and nobody finds out until it is in a store.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Private\Core.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

Write-Host 'What counts as Microsoft' -ForegroundColor Cyan
foreach ($case in @(
    @{ In = 'Microsoft';              Out = $true },
    @{ In = 'Microsoft Corporation';  Out = $true },
    @{ In = ' Microsoft ';            Out = $true },   # INFs are not tidy
    @{ In = 'microsoft';              Out = $true },   # nor consistent about case
    @{ In = 'Microsoft Windows';      Out = $true }
)) {
    Test-Case "'$($case.In)'" $case.Out (Test-WfMicrosoftProvider $case.In)
}

Write-Host 'What does not' -ForegroundColor Cyan
# These are the ones that must survive. A substring match would eat all of them.
foreach ($case in @(
    @{ In = 'Intel';                        Out = $false },
    @{ In = 'Realtek Semiconductor Corp.';  Out = $false },
    @{ In = 'Microsoft Partner Ltd';        Out = $false },
    @{ In = 'Not Microsoft';                Out = $false },
    @{ In = 'MicrosoftPOS Systems';         Out = $false },
    @{ In = '';                             Out = $false },
    @{ In = $null;                          Out = $false }
)) {
    $label = "'$($case.In)'"
    if ($null -eq $case.In) { $label = 'null' }
    Test-Case $label $case.Out (Test-WfMicrosoftProvider $case.In)
}

Write-Host 'Reading Provider out of an INF' -ForegroundColor Cyan
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wf-inf-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function New-Inf {
    param([string] $Name, [string] $Body, [string] $Encoding = 'ascii')
    $path = Join-Path $tmp $Name
    Set-Content -LiteralPath $path -Value $Body -Encoding $Encoding -Force
    return $path
}

# The usual shape: a token in [Version], resolved down in [Strings].
$a = New-Inf 'tokened.inf' @'
[Version]
Signature = "$WINDOWS NT$"
Class     = Net
Provider  = %MSFT%

[Strings]
MSFT = "Microsoft"
'@
Test-Case 'token resolved' 'Microsoft' (Get-WfInfProvider $a)

$b = New-Inf 'literal.inf' @'
[Version]
Class    = Display
Provider = Intel
'@
Test-Case 'literal value' 'Intel' (Get-WfInfProvider $b)

$c = New-Inf 'quoted.inf' @'
[Version]
Provider = "Realtek Semiconductor Corp."
'@
Test-Case 'quotes stripped' 'Realtek Semiconductor Corp.' (Get-WfInfProvider $c)

$d = New-Inf 'comment.inf' @'
[Version]
Provider = %VENDOR%   ; the OEM, not us

[Strings]
VENDOR = "Elo Touch Solutions"   ; trailing comment here too
'@
Test-Case 'comments ignored' 'Elo Touch Solutions' (Get-WfInfProvider $d)

$e = New-Inf 'unresolved.inf' @'
[Version]
Provider = %NOSUCHTOKEN%
'@
Test-Case 'unresolvable token kept as-is' '%NOSUCHTOKEN%' (Get-WfInfProvider $e)
# And it must not then be mistaken for Microsoft.
Test-Case 'and is not Microsoft' $false (Test-WfMicrosoftProvider (Get-WfInfProvider $e))

$f = New-Inf 'none.inf' @'
[Version]
Class = System
'@
Test-Case 'no Provider line' $true ($null -eq (Get-WfInfProvider $f))

Test-Case 'missing file' $true ($null -eq (Get-WfInfProvider (Join-Path $tmp 'nope.inf')))

# Vendor packages ship UTF-16 INFs; read as ANSI they silently match nothing.
$g = New-Inf 'wide.inf' @'
[Version]
Provider = %MSFT%

[Strings]
MSFT = "Microsoft"
'@ 'unicode'
Test-Case 'UTF-16 INF' 'Microsoft' (Get-WfInfProvider $g)

Write-Host 'End to end: which INFs a filter would drop' -ForegroundColor Cyan
$all = @($a, $b, $c, $d, $e, $f, $g)
$dropped = @($all | Where-Object { Test-WfMicrosoftProvider (Get-WfInfProvider $_) } | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object)
Test-Case 'only the Microsoft ones' @('tokened.inf','wide.inf') $dropped

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
