# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The Setup refresh a serviced boot.wim owes the media.
#
# Windows Setup exists twice: on the media at \sources\setup.exe, and inside
# boot.wim. Servicing boot.wim moves its copy forward and leaves the media's
# behind, and Microsoft is blunt about the result -- "if these binaries aren't
# identical, Windows Setup will fail during installation."
#
# Nothing about the media looks wrong without this step, which is exactly why it
# is the one that gets left out. What is checked here is the part that can be
# checked without a Windows machine: that the code does the right things in the
# right order, and says the right things about why.
#
# The ordering rule is the one worth pinning. Microsoft's own step table runs
# 26 Setup Dynamic Update, 27 setup.exe and setuphost.exe, 28 boot manager --
# and that order is load-bearing rather than cosmetic. The Dynamic Update package
# can carry its own setup.exe, so expanding it AFTER the copy would put the older
# binary straight back and undo the whole thing.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

$mediaFile = Join-Path $root 'WimForge\Public\Media.ps1'
$src = Get-Content -LiteralPath $mediaFile -Raw

$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mediaFile, [ref]$null, [ref]$errors)
Test-Case 'Media.ps1 parses' '' (@($errors | ForEach-Object { $_.Message }) -join '; ')

$functions = @($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { $_.Name })

Write-Host ''
Write-Host 'What it copies' -ForegroundColor Cyan

Test-Case 'the functions are there' 'Get-WfMediaSetupIndex, Update-WfMediaSetupFile' ($functions -join ', ')

# setup.exe is required and its absence is a failure; everything else is
# optional and its absence is normal.
Test-Case 'setup.exe is copied'     'True' ($src.Contains('sources\setup.exe')).ToString()
Test-Case 'setuphost.exe is copied' 'True' ($src.Contains('sources\setuphost.exe')).ToString()
# The row is found first and the flag read off it, rather than matching both in
# one regex across a line full of backslashes -- that pattern would be as likely
# to pass because the escaping was wrong as because the code is right.
$rowFor = {
    param([string] $Leaf)
    @(($src -split "`r?`n") | Where-Object { $_ -match [regex]::Escape("To = '$Leaf'") })
}

# @() at the CALL, not just inside the block: a scriptblock returning a
# one-element array hands back the bare string, whose .Count is still 1 and
# whose [0] is its first CHARACTER. Both assertions below then compare a space
# against a regex and fail for a reason that has nothing to do with the code
# being checked -- which is how this comment came to be written.
$setupRow = @(& $rowFor 'setup.exe')
Test-Case 'setup.exe has exactly one row' 1 $setupRow.Count
Test-Case 'and setup.exe is the required one' 'True' `
    ($setupRow.Count -eq 1 -and $setupRow[0] -match 'Required = \$true').ToString()

$hostRow = @(& $rowFor 'setuphost.exe')
Test-Case 'while setuphost.exe is not' 'True' `
    ($hostRow.Count -eq 1 -and $hostRow[0] -match 'Required = \$false').ToString()

# setuphost.exe arrived with Windows 11 24H2. Microsoft's script gates it on
# exactly this version, and copying it unconditionally would fail every build
# on older media for a file that is correctly absent.
Test-Case 'setuphost.exe is gated on 26100' 'True' ($src.Contains('10.0.26100')).ToString()

# The boot manager comes out of \Windows\boot\efi in the mounted image.
Test-Case 'the boot manager sources are right' 'True' `
    (($src.Contains('Windows\boot\efi\bootmgfw.efi')) -and ($src.Contains('Windows\boot\efi\bootmgr.efi'))).ToString()

# Microsoft's script scans the media for b*.efi and overwrites by FILE NAME --
# bootmgfw.efi goes over all four names the firmware might look for. Media laid
# out differently still gets serviced, and nothing is written to a path that does
# not already hold a boot manager.
foreach ($n in @('bootmgfw.efi', 'bootx64.efi', 'bootia32.efi', 'bootaa64.efi')) {
    Test-Case "$n is a boot manager target" 'True' ($src.Contains("'$n'")).ToString()
}
Test-Case 'the media is searched for b*.efi' 'True' ($src.Contains("Filter 'b*.efi'")).ToString()

Write-Host ''
Write-Host 'The ordering rule' -ForegroundColor Cyan

# The Dynamic Update expansion has to come BEFORE the copy out of the boot
# image. Checked by position in the file, because that is what decides it at run
# time: both live in one function, in order.
$duAt   = $src.IndexOf('expand.exe')
$copyAt = $src.IndexOf('out of the boot image')
Test-Case 'the Dynamic Update expands first' 'True' (($duAt -ge 0) -and ($duAt -lt $copyAt)).ToString()

# And the reason is written down, because a future edit that reorders them would
# otherwise look harmless.
Test-Case 'and the file says why' 'True' `
    ($src.Contains('can carry its own setup.exe')).ToString()

Write-Host ''
Write-Host 'Which index carries Setup' -ForegroundColor Cyan

# Microsoft's script tests for index 2. That mapping is not documented anywhere
# -- it is inferred from a script -- and a copype-built boot image has one index.
# So the Setup index is the one that actually has sources\setup.exe in it.
$idxFn = ($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Get-WfMediaSetupIndex' }, $true))[0].Extent.Text

Test-Case 'the index is found by probing, not assumed' 'True' `
    ($idxFn.Contains('sources\setup.exe')).ToString()
Test-Case 'it mounts read-only to look' 'True' ($idxFn.Contains('-ReadOnly')).ToString()

# Index 2 first is an optimisation, not an assumption: on Microsoft media it is
# the answer, so trying it first costs one mount instead of two.
Test-Case 'index 2 is tried first as an optimisation' 'True' `
    ($idxFn -match 'Sort-Object \{ if \(\$_ -eq 2\)').ToString()

# A plain WinPE has no Setup in it at all. That is the honest answer, not an
# error -- and the caller turns it into a message naming the likely mistake.
Test-Case 'no Setup anywhere returns 0' 'True' ($idxFn -match 'return 0').ToString()
Test-Case 'and the caller explains that' 'True' `
    ($src.Contains('That is a plain WinPE rather than installation media')).ToString()

Write-Host ''
Write-Host 'What it says about why' -ForegroundColor Cyan

# The one sentence that justifies the whole function. If a future edit drops it,
# somebody will decide this step looks optional.
Test-Case 'Microsoft''s warning is quoted' 'True' `
    ($src.Contains('Windows Setup will fail during installation')).ToString()

# Honesty about the boot manager: Microsoft's script copies it and their
# documentation never says why. Claiming a reason would be inventing one.
Test-Case 'the boot manager''s missing rationale is admitted' 'True' `
    ($src.Contains('their documentation never says why')).ToString()

Write-Host ''
Write-Host 'Scratch is cleaned up' -ForegroundColor Cyan

# The binaries are staged to a temp folder between the image and the media. A
# run that throws in the middle must not leave it behind on a workstation that
# does this monthly.
$updFn = ($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Update-WfMediaSetupFile' }, $true))[0].Extent.Text

Test-Case 'the staging folder is removed in a finally' 'True' `
    (($updFn -match 'finally\s*\{[^}]*Remove-Item')).ToString()

Write-Host ''
if ($script:Fail -gt 0) {
    Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'All media Setup checks passed.' -ForegroundColor Green
