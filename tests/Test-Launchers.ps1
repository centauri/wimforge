# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The Explorer launchers.
#
# These are three lines of batch each and would normally not be worth a test,
# except that every one of the things they get right is invisible when it goes
# wrong:
#
#   * calling pwsh instead of powershell.exe does not fail. It starts, imports
#     the module, and then services images through a compatibility shim, which
#     is the difference between "works" and "works until it does not".
#   * a renamed front-end leaves a launcher that opens a window, flashes, and
#     closes, with nothing on screen to say why.
#   * dropping the pause turns every startup failure into exactly that flash.
#
# None of it can be caught by running them here, so it is read instead.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

$launchers = @(
    @{ File = 'WimForge-Menu.cmd'; Target = 'Start-WimForgeMenu.ps1' }
    @{ File = 'WimForge-GUI.cmd';  Target = 'Start-WimForgeGui.ps1'  }
)

foreach ($l in $launchers) {
    Write-Host $l.File -ForegroundColor Cyan

    $path = Join-Path $root $l.File
    Test-Case 'exists' $true (Test-Path -LiteralPath $path)
    if (-not (Test-Path -LiteralPath $path)) { continue }

    $text = Get-Content -LiteralPath $path -Raw

    # The commands only. A rem line may quote the broken form -- explaining what
    # was wrong is the point of it -- and a plain text search cannot tell an
    # explanation from an instruction. Same trap as the one in Test-MountPath.
    $cmds = (@(Get-Content -LiteralPath $path | Where-Object { $_ -notmatch '^\s*rem\b' }) -join "`n")

    # The comments explain why pwsh is NOT used, which a naive search reads as
    # using it. Checks about what runs are made against the lines that run.
    $code = (@(Get-Content -LiteralPath $path | Where-Object { $_ -notmatch '^\s*rem\b' }) -join "`n")

    # The front-end it points at has to be there. A rename that misses the
    # launcher is silent until somebody double-clicks it.
    Test-Case 'the script it starts exists' $true (Test-Path -LiteralPath (Join-Path $root $l.Target))
    Test-Case 'and is the one it names'     $true ($text -match [regex]::Escape($l.Target))

    # Windows PowerShell 5.1, not whatever is registered for .ps1. This is the
    # whole reason the launcher exists rather than a shortcut to the .ps1.
    Test-Case 'runs Windows PowerShell by full path' $true `
        ($text -match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe')
    Test-Case 'never calls pwsh' $false ($code -match '(?<![\w-])pwsh')

    Test-Case 'bypasses execution policy for this process' $true ($text -match '-ExecutionPolicy Bypass')

    Test-Case 'asks for elevation up front' $true ($cmds -match '-Elevate')

    # WinForms needs STA, and it is passed on both so the two launchers cannot
    # drift into behaving differently.
    Test-Case 'runs single-threaded apartment' $true ($text -match '-STA')

    # -File, not -Command: -Command would re-parse the path and a folder with a
    # space or an apostrophe in it would take a different route through the
    # parser than the one that was tested.
    Test-Case 'uses -File' $true ($text -match '-File "%WF_SCRIPT%"')

    # Paths relative to the launcher, so it works from a stick or a share.
    Test-Case 'finds itself rather than trusting the current directory' $true ($text -match '%~dp0')

    # A double-clicked window that closes on failure shows nothing at all.
    Test-Case 'holds the window open on a bad exit' $true ($text -match '(?s)WF_RC%"=="0".*?pause')

    # And says something useful if it has been moved away from the module.
    Test-Case 'checks the script is next to it' $true ($text -match 'if not exist "%WF_SCRIPT%"')

    # A launcher that swallows arguments cannot be used for -ConfigPath, which
    # is how a second estate with a second config would run it.
    #
    # %* goes BEFORE the switch. powershell.exe -File hands the remaining tokens
    # to the script's parameter binder, and under 5.1 a switch followed by a
    # value takes that value as its argument -- so "-Elevate %*" turns a dropped
    # folder into a cast error before the script runs a line. One token's
    # difference, and nothing else about this file needs to know.
    Test-Case 'passes extra arguments through' $true  ($cmds -match '%\* -Elevate')
    Test-Case 'and not after the switch'       $false ($cmds -match '-Elevate %\*')
}

Write-Host 'The two are consistent with each other' -ForegroundColor Cyan

$menu = Get-Content -LiteralPath (Join-Path $root 'WimForge-Menu.cmd') -Raw
$gui  = Get-Content -LiteralPath (Join-Path $root 'WimForge-GUI.cmd')  -Raw

# The PowerShell invocation itself should be identical apart from the script it
# runs -- one launcher quietly gaining a flag the other lacks is how the two
# front-ends start behaving differently for reasons nobody can find.
$strip = {
    param([string] $Text)
    ($Text -split "`n" | Where-Object { $_ -match '^\s*"%WF_PS%"' }) -join "`n"
}
Test-Case 'the same command line, bar the script' `
    ((& $strip $menu) -replace 'Start-WimForgeMenu', 'X') `
    ((& $strip $gui)  -replace 'Start-WimForgeGui',  'X')

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
