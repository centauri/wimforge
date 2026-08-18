# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# What the repository would and would not carry.
#
# Two of these rules are load-bearing and both fail silently.
#
# The first is the unattend.xml negation. An answer file holds the local
# administrator password, so every unattend.xml is ignored -- except the
# documented template under ReferenceBuild, which is let back in by name. That
# negation is fragile in a way gitignore does not warn about: add ReferenceBuild/
# to the ignore list one day and the negation stops working, because a file
# cannot be re-included once its directory is excluded. The template then
# vanishes from the repo and nobody notices until somebody clones it.
#
# The second is the reverse. Rules like *.inf, *.dll and *.sys are broad on
# purpose -- they are harvested driver payloads, never source. But broad rules
# swallow things, and a file that is silently not committed looks exactly like a
# file that was never written.
#
# So both directions are checked, against real git rather than by reading the
# patterns and hoping.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Host 'git is not on PATH, so the ignore rules cannot be checked here.' -ForegroundColor Yellow
    Write-Host 'Not a failure -- but this test is the only thing guarding them, so run it somewhere with git.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Skipped' -ForegroundColor Yellow
    exit 0
}

Write-Host 'The ignore rules, against real git' -ForegroundColor Cyan

# A scratch repository seeded with the real rules. Done in a temp folder rather
# than against the project itself so this works before git init has ever been run
# here, which is exactly when the rules matter most.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wf-git-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    # git init writes hints to stderr on a runner whose global gitconfig has no
    # default branch. That is not a failure; ErrorActionPreference Stop would
    # make it one.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git -C $tmp -c init.defaultBranch=main init -q 2>&1 | Out-Null }
    finally { $ErrorActionPreference = $prevEap }
    Copy-Item -LiteralPath (Join-Path $root '.gitignore')    -Destination $tmp -Force
    Copy-Item -LiteralPath (Join-Path $root '.gitattributes') -Destination $tmp -Force

    function Test-Ignored {
        param([string] $Relative)
        $full = Join-Path $tmp $Relative
        New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
        Set-Content -LiteralPath $full -Value 'x' -Force
        # Exit 1 means "not ignored". That is the answer, not a failure, so do
        # not let ErrorActionPreference Stop (or pwsh native-command errors)
        # turn it into a throw.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & git -C $tmp check-ignore -q -- $Relative 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        finally { $ErrorActionPreference = $prevEap }
    }

    # --- must reach the repository ---------------------------------------
    $keep = @(
        'ReferenceBuild/unattend.xml'              # the template, let back in by name
        'WimForge/WimForge.config.example.json'    # named so it survives the config rules
        'WimForge/WimForge.psd1'
        'WimForge/Public/Recovery.ps1'
        'WimForge-Menu.cmd'
        'WimForge-GUI.cmd'
        'tests/Test-RepoHygiene.ps1'
        'README.md'
        'LICENSE'
        'ReferenceBuild/Reference-Build-Checklist.md'
    )
    $wrongly = @($keep | Where-Object { Test-Ignored $_ })
    Test-Case 'nothing that belongs in the repo is ignored' @() $wrongly

    # --- must never reach the repository ---------------------------------
    $drop = @{
        'unattend.xml'                      = 'an answer file holds the administrator password'
        'autounattend.xml'                  = 'same file, the other name'
        'Workspace/unattend.xml'            = 'a workspace next to the toolkit'
        'ReferenceBuild/live-unattend.xml'  = 'a second copy beside the template -- the one with the real password'
        'ReferenceBuild/old/unattend.xml'   = 'the negation must not re-include a whole subtree'
        'WimForge/WimForge.config.json'     = 'the live config, with this machine paths'
        'config.json'                       = 'the live config, other name'
        'TillApps.ppkg'                     = 'a provisioning package can carry a domain join account'
        'signing.pfx'                       = 'a private key'
        'server.key'                        = 'a private key'
        'Plus-POS.wim'                      = 'a multi-GB image'
        'boot.sdi'                          = 'recovery payload'
        'Registry.pol'                      = 'a compiled policy blob'
        'Drivers/Dell/e1d68x64.inf'         = 'harvested driver payload'
        'Drivers/Dell/e1d68x64.sys'         = 'harvested driver payload'
        'Workspace/Images/base.wim'         = 'a workspace inside the working tree'
        'WimMount/pagefile.sys'             = 'a mount point inside the working tree'
        '_to_delete/old.ps1'                = 'superseded work moved aside'
        'build-history.json'                = 'per-machine build output'
        'servicing.log'                     = 'log output'
    }
    $leaked = @($drop.Keys | Sort-Object | Where-Object { -not (Test-Ignored $_) })
    Test-Case 'nothing sensitive or generated reaches the repo' @() $leaked

    # Called out on its own because it is the one with the security consequence
    # and the one most likely to be broken by a later edit.
    Test-Case 'the ReferenceBuild template survives the unattend rule' $false (Test-Ignored 'ReferenceBuild/unattend.xml')
    Test-Case 'but a live answer file beside it does not'              $true  (Test-Ignored 'ReferenceBuild/live-unattend.xml')
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Line endings' -ForegroundColor Cyan

$attr = Get-Content -LiteralPath (Join-Path $root '.gitattributes') -Raw

# Batch is parsed line by line by cmd.exe. A .cmd checked out with bare LF can
# mis-parse a label or a parenthesised block, and the symptom is a launcher that
# does nothing rather than an error -- so the endings are pinned rather than left
# to whatever core.autocrlf the person cloning happens to have.
Test-Case 'batch is pinned to CRLF' $true ($attr -match '(?m)^\*\.cmd\s+text\s+eol=crlf')
Test-Case 'and so is PowerShell'    $true ($attr -match '(?m)^\*\.ps1\s+text\s+eol=crlf')
Test-Case 'images are marked binary' $true ($attr -match '(?m)^\*\.wim\s+binary')

# The launchers as they exist here have to already be CRLF, or the first clone on
# a machine without the attribute applied gets a file that has never worked.
foreach ($cmd in @('WimForge-Menu.cmd', 'WimForge-GUI.cmd')) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root $cmd))
    $lf    = @($bytes | Where-Object { $_ -eq 0x0A }).Count
    $crlf  = 0
    for ($i = 1; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0A -and $bytes[$i - 1] -eq 0x0D) { $crlf++ }
    }
    Test-Case "$cmd is CRLF on disk" $lf $crlf
}

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
