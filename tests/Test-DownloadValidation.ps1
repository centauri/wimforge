# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# A download check that rejects good files is worse than no check at all.
#
# This one did exactly that. It asked "does the file start with MSCF?", which was
# true of every .msu Microsoft shipped for about fifteen years -- and stopped
# being true with Windows 11 24H2, where cumulative updates are WIM containers
# with the same .msu extension. The result was a 5.4 GB download of KB5121767
# arriving intact and then being deleted by the tool that asked for it, with an
# error message confidently blaming the file.
#
# The check was untestable before this, because it lived inline in the middle of
# Save-WfUpdate's download loop, where reaching it meant downloading something.
# So the first fix is that it is a function; these tests feed it real bytes.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

. (Join-Path $root 'WimForge\Private\Core.ps1')

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wf-dl-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function New-Fake {
    param([string] $Name, [byte[]] $Header, [int] $Pad = 0)
    $p = Join-Path $tmp $Name
    $fs = [System.IO.File]::Create($p)
    try {
        $fs.Write($Header, 0, $Header.Length)
        if ($Pad -gt 0) { $fs.Write((New-Object byte[] $Pad), 0, $Pad) }
    }
    finally { $fs.Dispose() }
    return $p
}

$cab  = [byte[]][char[]]'MSCF' + [byte[]](0,0,0,0)
$wim  = [byte[]][char[]]'MSWIM' + [byte[]](0,0,0)
$html = [byte[]][char[]]'<!DOCTYPE'

try {
    Write-Host 'Both container formats are accepted' -ForegroundColor Cyan

    # The old world. Still shipping, still valid.
    $r = Test-WfUpdateContainer -Path (New-Fake 'old.msu' $cab (2MB))
    Test-Case 'a cabinet passes' $true  $r.Ok
    Test-Case 'and is named Cab' 'Cab'  $r.Kind

    # The case that caused the bug. This is the one that matters.
    $r = Test-WfUpdateContainer -Path (New-Fake 'new.msu' $wim (2MB))
    Test-Case 'a WIM passes'     $true  $r.Ok
    Test-Case 'and is named Wim' 'Wim'  $r.Kind

    Write-Host 'What it is actually there to catch still fails' -ForegroundColor Cyan

    # A captive-portal or SSO login page served with a 200. The original reason
    # this check exists, and the reason it stays an allow-list.
    $r = Test-WfUpdateContainer -Path (New-Fake 'portal.msu' $html (2MB))
    Test-Case 'an HTML page is rejected'    $false $r.Ok
    # Quoted in the message, so the operator can tell a login page from a
    # truncated file without going and looking at the bytes themselves.
    Test-Case 'and the signature is quoted' $true  ($r.Reason -match '<!DOCTYP')

    # A valid header proves the first eight bytes and nothing else. A cumulative
    # that arrives at 40 KB is a truncated transfer wearing the right hat.
    $r = Test-WfUpdateContainer -Path (New-Fake 'tiny.msu' $wim 40000)
    Test-Case 'a truncated .msu is rejected' $false $r.Ok
    Test-Case 'for being too small'          $true  ($r.Reason -match 'too small')

    # But .cab has no floor: some genuinely are a few KB, and applying that floor
    # to them would swap one wrongly-rejected-good-file bug for another.
    $r = Test-WfUpdateContainer -Path (New-Fake 'small.cab' $cab 4000) -MinimumBytes 0
    Test-Case 'a small .cab is fine' $true $r.Ok

    Write-Host 'Nothing here throws' -ForegroundColor Cyan

    # The caller is mid-loop over several URLs and wants to discard one and carry
    # on. Throwing would abandon the rest of the download list.
    $r = Test-WfUpdateContainer -Path (Join-Path $tmp 'does-not-exist.msu')
    Test-Case 'a missing file returns instead of throwing' $false $r.Ok
    Test-Case 'and says so'                                $true  ($r.Reason -match 'not there')

    $r = Test-WfUpdateContainer -Path (New-Fake 'empty.msu' ([byte[]]@()))
    Test-Case 'an empty file returns instead of throwing'  $false $r.Ok

    Write-Host 'Packages are applied oldest first' -ForegroundColor Cyan

    # 24H2 servicing is checkpoint-based: the newest cumulative comes down with
    # the checkpoint it builds on, and the checkpoint has to go in first. Age is
    # encoded only as the KB number, so the sort has to get numbers right.
    $names = @(
        'windows11.0-kb5121767-x64_588e.msu',   # the cumulative
        'windows11.0-kb5043080-x64_9534.msu'    # the checkpoint it needs
    )
    $sorted = @($names | Sort-Object { ConvertTo-WfNaturalKey $_ })
    Test-Case 'the checkpoint goes first' 'windows11.0-kb5043080-x64_9534.msu' $sorted[0]

    # Plain string sort gets that right by luck -- every current KB is seven
    # digits starting with 5. It breaks the moment one isn't.
    $mixed  = @('kb999999.msu', 'kb5043080.msu')
    $nat    = @($mixed | Sort-Object { ConvertTo-WfNaturalKey $_ })
    Test-Case 'a shorter KB still sorts as older' 'kb999999.msu' $nat[0]
    Test-Case 'which plain sort gets wrong'       'kb5043080.msu' (@($mixed | Sort-Object)[0])

    # Same trap on the documented manual override.
    $steps = @('10-last.cab', '2-first.cab')
    Test-Case '02 before 10 on manual prefixes' '2-first.cab' `
        (@($steps | Sort-Object { ConvertTo-WfNaturalKey $_ })[0])

    Write-Host 'And the caller uses all of it' -ForegroundColor Cyan

    $upd = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Updates.ps1') -Raw
    $svc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw

    Test-Case 'Save-WfUpdate checks the container' $true ($upd -match 'Test-WfUpdateContainer -Path \$temp')
    Test-Case 'and the inline MSCF test is gone'   $false ($upd -match "-ne 'MSCF'")

    # .msu gets the size floor, .cab does not -- it defaults to none and is
    # raised only inside the .msu test.
    Test-Case 'the floor starts at none' $true ($upd -match '\$floor\s*=\s*0')
    Test-Case 'and is raised for .msu'   $true ($upd -match '\.msu\$.*\$floor = 1MB')

    # Multiple files for one KB is normal, not a duplicate -- and saying nothing
    # about it is how someone decides to "clean up" the checkpoint.
    Test-Case 'two files for one update are explained' $true ($upd -match 'checkpoint it builds on')

    Test-Case 'Add-WfUpdate sorts naturally' $true ($svc -match 'Sort-Object \{ ConvertTo-WfNaturalKey')
    Test-Case 'and nothing sorts on raw Name any more' $false ($svc -match "Sort-Object Name\)")
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
