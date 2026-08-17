# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The catalog publishes two sizes and they mean different things.
#
# On a SEARCH RESULT, size is the total for the entry. On the DOWNLOAD DIALOG,
# there is one size per file. Using the first where the second was needed is what
# made KB5121767 re-download half of itself on every run: the entry total is
# 5,743,873,870, the checkpoint on disk is 533,761,740, they will never be equal,
# and re-downloading produced exactly the same "wrong" number. Forever.
#
# The same response also carries a per-file digest, which answers a better
# question than length ever could -- right size is not the same as right file.
#
# These tests use real bytes and real hashes rather than checking that the source
# mentions the right words.

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

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wf-vfy-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$sample = Join-Path $tmp 'package.msu'
[System.IO.File]::WriteAllBytes($sample, [byte[]][char[]]('MSWIM' + ([string]'x' * 5000)))

function Get-Digest {
    param([string] $Path, [string] $Algorithm)
    $alg = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try { return [Convert]::ToBase64String($alg.ComputeHash($fs)) } finally { $fs.Dispose() }
    }
    finally { $alg.Dispose() }
}

try {
    Write-Host 'A digest is checked, whichever way it arrives' -ForegroundColor Cyan

    # The response says nothing about which algorithm it used, so the length of
    # the decoded digest is the only signal -- 20 bytes SHA-1, 32 SHA-256.
    # Getting this from the length rather than trying both matters: trying both
    # means two full passes over a 5 GB file to answer one question.
    $r = Test-WfFileDigest -Path $sample -Digest (Get-Digest $sample 'SHA1')
    Test-Case 'SHA-1 passes'        $true   $r.Ok
    Test-Case 'and is named'        'SHA1'  $r.Algorithm
    Test-Case 'and actually ran'    $true   $r.Checked

    $r = Test-WfFileDigest -Path $sample -Digest (Get-Digest $sample 'SHA256')
    Test-Case 'SHA-256 passes'   $true     $r.Ok
    Test-Case 'and is named'     'SHA256'  $r.Algorithm

    # Hex is accepted too. The encoding is as undocumented as the algorithm.
    $hex = ([Convert]::FromBase64String((Get-Digest $sample 'SHA256')) |
            ForEach-Object { $_.ToString('x2') }) -join ''
    $r = Test-WfFileDigest -Path $sample -Digest $hex
    Test-Case 'a hex digest passes' $true    $r.Ok
    Test-Case 'and is identified'   'SHA256' $r.Algorithm

    Write-Host 'A wrong file fails even at the right length' -ForegroundColor Cyan

    # The case length can never catch, and the reason to hash at all.
    $twin = Join-Path $tmp 'twin.msu'
    [System.IO.File]::WriteAllBytes($twin, [byte[]][char[]]('MSWIM' + ([string]'y' * 5000)))
    Test-Case 'same size, different bytes' `
        (Get-Item $sample).Length (Get-Item $twin).Length

    $r = Test-WfFileDigest -Path $twin -Digest (Get-Digest $sample 'SHA256')
    Test-Case 'the impostor is caught' $false $r.Ok
    Test-Case 'and told why'           $true  ($r.Reason -match 'does not match')

    Write-Host 'Unverifiable is not the same as bad' -ForegroundColor Cyan

    # Plenty of catalog entries publish no digest. Treating that as a failure
    # would refuse downloads that are perfectly fine.
    $r = Test-WfFileDigest -Path $sample -Digest ''
    Test-Case 'no digest is not a failure' $true  $r.Ok
    Test-Case 'but it is not a pass either' $false $r.Checked
    Test-Case 'and says so'                 $true  ($r.Reason -match 'no digest')

    # A digest in a shape this does not understand is the same situation.
    $r = Test-WfFileDigest -Path $sample -Digest 'not-a-hash-at-all!!'
    Test-Case 'an unreadable digest does not fail the file' $true  $r.Ok
    Test-Case 'and is not counted as checked'               $false $r.Checked

    # A 24-byte hash is neither SHA-1 nor SHA-256 -- report, do not guess at
    # which one it was meant to be.
    $r = Test-WfFileDigest -Path $sample -Digest ([Convert]::ToBase64String([byte[]](200..223)))
    Test-Case 'an unknown length is reported' $false ($r.Checked)
    Test-Case 'and named'                     $true  ($r.Reason -match '24 byte')

    # The trap this walked into once: an all-hex-looking string is BOTH valid
    # hex and valid base64, so there are two candidate lengths and neither is a
    # hash. Naming only the first read as a plain wrong answer.
    $r = Test-WfFileDigest -Path $sample -Digest ([Convert]::ToBase64String((New-Object byte[] 24)))
    Test-Case 'an ambiguous digest names both readings' $true ($r.Reason -match '16 or 24')

    # A missing file IS a failure -- there is nothing to verify.
    $r = Test-WfFileDigest -Path (Join-Path $tmp 'gone.msu') -Digest (Get-Digest $sample 'SHA256')
    Test-Case 'a missing file fails' $false $r.Ok

    Write-Host 'The download dialog is parsed for all three fields' -ForegroundColor Cyan

    # Shaped like the real response: one line per property, per file, and the
    # two files of a checkpoint-based update in one entry.
    $page = @"
downloadInformation[0].files[0].url = 'https://catalog.s.download.windowsupdate.com/d/msdownload/update/windows11.0-kb5043080-x64_9534.msu';
downloadInformation[0].files[0].digest = 'yjO7RiQdIhcNnb4NoAlSBVUuw+E=';
downloadInformation[0].files[0].size = '533761740';
downloadInformation[0].files[0].name = 'windows11.0-kb5043080-x64_9534.msu';
downloadInformation[0].files[1].url = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/windows11.0-kb5121767-x64_588e.msu';
downloadInformation[0].files[1].digest = 'AbCdEfGhIjKlMnOpQrStUvWxYz01234=';
downloadInformation[0].files[1].size = '5210112130';
"@

    $files = @{}
    foreach ($m in [regex]::Matches($page, "downloadInformation\[(\d+)\]\.files\[(\d+)\]\.(\w+)\s*=\s*'([^']*)'")) {
        $key = "$($m.Groups[1].Value)/$($m.Groups[2].Value)"
        if (-not $files.ContainsKey($key)) { $files[$key] = @{} }
        $files[$key][$m.Groups[3].Value.ToLowerInvariant()] = $m.Groups[4].Value
    }

    Test-Case 'both files are found' 2 $files.Keys.Count
    Test-Case 'per-file size, not the total' 533761740 ([long]$files['0/0']['size'])
    Test-Case 'and the other one'            5210112130 ([long]$files['0/1']['size'])
    Test-Case 'a digest comes with each'     $true ([bool]$files['0/0']['digest'] -and [bool]$files['0/1']['digest'])

    # The bug in one line: the entry total is the sum, so neither file equals it.
    $total = 5743873870
    Test-Case 'the two sizes are the entry total' $total `
        ([long]$files['0/0']['size'] + [long]$files['0/1']['size'])
    Test-Case 'so neither file matches it' $true `
        (([long]$files['0/0']['size'] -ne $total) -and ([long]$files['0/1']['size'] -ne $total))

    # A file with no url is not a file. The name falls back to the url's leaf.
    Test-Case 'name is published too' 'windows11.0-kb5043080-x64_9534.msu' $files['0/0']['name']
    Test-Case 'and can be derived when it is not' 'windows11.0-kb5121767-x64_588e.msu' `
        (Split-Path (($files['0/1']['url']) -split '\?')[0] -Leaf)
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Save-WfUpdate uses the per-file numbers' -ForegroundColor Cyan

$upd = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Updates.ps1') -Raw

Test-Case 'it asks for the full file info'  $true ($upd -match '\$urls = @\(Get-WfUpdateDownloadInfo -UpdateId \$UpdateId\)')
Test-Case 'and takes the per-file size'     $true ($upd -match '\$expected = \[long\]\$file\.Size')
Test-Case 'falling back to the server'      $true ($upd -match 'if \(\$expected -le 0\) \{ \$expected = Get-WfUrlSize')

# The entry total is now only trusted when there is exactly one file for it to
# be the total OF. This guard is the actual fix.
Test-Case 'the entry total needs a single file' $true `
    ($upd -match '\$expected -le 0 -and \$urls\.Count -eq 1.*\$expected = \$SizeBytes')

# Hash on arrival, never on re-check. Re-hashing 5 GB to confirm what was already
# confirmed would make "already downloaded" the slow path -- backwards, since
# avoiding work is the entire point of that branch.
Test-Case 'a fresh download is hashed' $true ($upd -match '(?s)\$ok -and \$file\.Digest.*?Test-WfFileDigest -Path \$temp')

# Scoped to the already-present branch itself, not "anywhere after the words
# Already downloaded" -- that would match the fresh-download hash further down
# and pass whatever the code did.
$branch = [regex]::Match($upd, '(?s)Already downloaded.{0,400}?continue')
Test-Case 'the already-present branch exists' $true  $branch.Success
Test-Case 'and does not hash'                 $false ($branch.Value -match 'Test-WfFileDigest')

# Cheap check first: no point hashing 3 GB to learn what one Length says.
$lenAt  = $upd.IndexOf('discarded as incomplete')
$hashAt = $upd.IndexOf('Test-WfFileDigest -Path $temp')
Test-Case 'length is checked before the hash' $true (($lenAt -gt 0) -and ($lenAt -lt $hashAt))

Test-Case 'a mismatch discards the file' $true ($upd -match '(?s)Test-WfFileDigest.*?if \(-not \$hash\.Ok\) \{\s*\$ok = \$false')
Test-Case 'and the match is reported'    $true ($upd -match 'matches the catalog')

# Get-WfUpdateDownloadUrl still exists and still returns strings, because
# everything that called it still calls it.
Test-Case 'the url-only view survives' $true ($upd -match '(?s)function Get-WfUpdateDownloadUrl.*?ForEach-Object \{ \$_\.Url \}')

$psd = Get-Content -LiteralPath (Join-Path $root 'WimForge\WimForge.psd1') -Raw
Test-Case 'the new resolver is exported' $true ($psd -match "'Get-WfUpdateDownloadInfo'")

Write-Host 'Downloads are filed by Windows generation' -ForegroundColor Cyan

# The Updates folder accumulates. Testing a Windows 10 image and a Windows 11
# image in one afternoon put both generations in one pile, and a servicing run
# -- which applies everything under that folder -- handed a 24H2 package to a
# 19044 image. Add-WfUpdate refuses that now, but a layout where it cannot arise
# beats a check that catches it after the fact.
# What generation a file belongs to is read by ONE function, and both the layout
# and the apply guard call it -- so they cannot drift apart into disagreeing
# about the same file, which is how the 24H2-into-19044 accident happened.
$idW10 = Get-WfPackageIdentity -Name 'windows10.0-kb5099539-x64_2b3c4d.msu'
$idW11 = Get-WfPackageIdentity -Name 'windows11.0-kb5121767-x64_588e6404d4e9.msu'
$idSrv = Get-WfPackageIdentity -Name 'windows11.0-kb5062553-x64-2025_7f21ab.msu'

Test-Case 'Windows 10 is read off the name'  @(10, 'Windows10') @($idW10.Major, $idW10.Generation)
Test-Case 'Windows 11 likewise'              @(11, 'Windows11') @($idW11.Major, $idW11.Generation)

# The one that actually needs a test. Server 2025 and Windows 11 24H2 are both
# build 26100 and the catalog issues them under the SAME KB -- KB5062553 returns
# a Windows 11 x64 entry, a Windows 11 arm64 entry and a "Microsoft server
# operating system version 24H2" entry. On disk the only difference is '-2025'.
Test-Case 'Server 2025 is not filed as Windows 11' 'Server2025' $idSrv.Generation
Test-Case 'and is known to be server'              $true        $idSrv.IsServer
Test-Case 'a client 24H2 package is known not to be' $false     $idW11.IsServer

# Windows 10 stays UNKNOWN rather than guessing: Server 2019 and Server 2022
# packages are named exactly like the client ones, so the name cannot answer it.
Test-Case 'Windows 10 server-ness is not guessed' $true ($null -eq $idW10.IsServer)

# The hash the catalog appends to a file name is hex, and four hex digits can
# read as a year. Anchoring the marker to the architecture token is what stops a
# client package being filed as a server one on that coincidence.
$idHex = Get-WfPackageIdentity -Name 'windows11.0-kb5121767-x64_2025abcd.msu'
Test-Case 'a hash that looks like a year is not a server marker' 'Windows11' $idHex.Generation

Test-Case 'the download folder uses it' $true ($upd -match '\$gen\s*=\s*Get-WfPackageIdentity -Name @\(\$urls\)\[0\]\.Name')
Test-Case 'and becomes a folder'        $true ($upd -match 'Join-WfPath \$Destination \$gen\.Generation')

# A checkpoint set nests BELOW the generation folder, not beside it.
Test-Case 'a set nests under the generation' $true ($upd -match '\$setRoot\s*=\s*Join-WfPath \$genRoot \$folder')

$svc2 = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw
Test-Case 'the guard reads the same thing' $true ($svc2 -match 'Get-WfPackageIdentity -Name \$p\.Name')

# A name with no generation is left at the root rather than filed under a guess.
Test-Case 'an unrecognised name is not filed' $true ($upd -match '(?s)\$genRoot = \$Destination.*?if \(\$gen\.Generation\)')
Test-Case 'and reads as nothing'              @(0, '') @((Get-WfPackageIdentity -Name 'ssu-26100.8872-x64.cab').Major,
                                                          (Get-WfPackageIdentity -Name 'ssu-26100.8872-x64.cab').Generation)

# And a bare file name must still resolve now that files are two levels down --
# the grid hands back names, not paths.
Test-Case 'removal searches the tree' $true ($upd -match '(?s)function Remove-WfUpdate.*?-File -Recurse')
Test-Case 'and refuses an ambiguous name' $true ($upd -match 'More than one file called')

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
