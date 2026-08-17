# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The Updates flow end to end, and what it says when a step goes wrong.
#
# Search -> download -> inject -> commit is four steps with three places to lose
# something quietly, and all three have been wrong in real tools:
#
#   a download that failed is still on the injection list
#   a package that "did not apply" is reported as a failure
#   a package that genuinely failed is reported as a hex code
#
# The middle one is the expensive mistake. Pointing an Updates folder that covers
# several builds at one image is normal practice, and every package for a
# different build comes back 0x800f081e. Calling that a failure makes a run that
# worked perfectly look broken, and the operator goes hunting for a problem that
# is not there.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

. (Join-Path $root 'WimForge\Public\DismErrors.ps1')

Write-Host 'DISM codes become something to act on' -ForegroundColor Cyan

# The one everybody meets, and the one that must not read as a failure.
$na = Get-WfDismError -Message 'Add-WindowsPackage : The specified package is not applicable to this image. Error: 0x800f081e'
Test-Case 'the code is picked out'      '0x800f081e' $na.Code
Test-Case 'it is recognised'            $true  $na.Recognised
Test-Case 'and it is NOT fatal'         $false $na.Fatal
Test-Case 'it names the three causes'   $true  ($na.WhatToDo -match 'already in the image')
Test-Case 'and the 22H2 trap'           $true  ($na.WhatToDo -match '22H2')
Test-Case 'the original is kept'        $true  ($na.Original -match '0x800f081e')

# Everything else with a code is a real failure.
foreach ($code in @('0x800f0831', '0x800f0922', '0x80070005', '0x80070570', '0xc1420127')) {
    $e = Get-WfDismError -Message "Something went wrong. Error: $code"
    Test-Case "$code is recognised"  $true $e.Recognised
    Test-Case "$code is fatal"       $true $e.Fatal
    Test-Case "$code says what to do" $true ($e.WhatToDo.Length -gt 30)
}

# An unfamiliar code must not be guessed at, and must not be swallowed either.
$unknown = Get-WfDismError -Message 'It broke. Error: 0x8badf00d'
Test-Case 'an unknown code is not claimed as recognised' $false $unknown.Recognised
Test-Case 'it is treated as fatal'                       $true  $unknown.Fatal
Test-Case 'the code still comes back'                    '0x8badf00d' $unknown.Code
Test-Case 'and it points at the DISM log'                $true ($unknown.WhatToDo -match 'dism\.log')

# Not everything DISM says carries a code.
$plain = Get-WfDismError -Message 'The mount directory is not empty.'
Test-Case 'a message with no code passes through' 'The mount directory is not empty.' $plain.Summary
Test-Case 'and is still fatal'                    $true $plain.Fatal

Test-Case 'no message at all does not throw' $true ($null -ne (Get-WfDismError -Message ''))

Write-Host 'The formatted version leads with the answer' -ForegroundColor Cyan

$text  = Format-WfDismError -Message 'Error: 0x80070005' -Context 'Applying kb5094127.msu failed.'
$lines = @($text -split "`r?`n" | Where-Object { $_ })

Test-Case 'the context is first'   'Applying kb5094127.msu failed.' $lines[0]
Test-Case 'then what happened'     'Access denied.' $lines[1]

# The raw message goes last but must never be dropped: when the translation is
# wrong, it is the only real evidence there is.
Test-Case 'the original is still in there' $true ($text -match '0x80070005')
Test-Case 'and is labelled as DISM''s own words' $true ($text -match 'What DISM said')

Write-Host 'Product choices' -ForegroundColor Cyan

$products = @(Get-WfUpdateProductChoice)
Test-Case 'there are some'        $true ($products.Count -ge 6)
Test-Case 'each has a product'    0 @($products | Where-Object { -not $_.Product }).Count

# The trap, written into the list itself rather than left to be discovered.
$h22 = @($products | Where-Object { $_.Product -eq 'Windows 10 Version 22H2' })
Test-Case '22H2 is offered'       1 $h22.Count
Test-Case 'and says it is the LTSC 2021 answer' $true ($h22[0].Note -match 'LTSC 2021')

$h21 = @($products | Where-Object { $_.Product -eq 'Windows 10 Version 21H2' })
Test-Case '21H2 is offered too'   1 $h21.Count
Test-Case 'but points at 22H2'    $true ($h21[0].Note -match '22H2')

# 22H2 before 21H2, because the list is read top down and the first plausible
# answer is the one that gets taken.
$order = @($products | ForEach-Object { $_.Product })
Test-Case '22H2 is listed before 21H2' $true `
    ($order.IndexOf('Windows 10 Version 22H2') -lt $order.IndexOf('Windows 10 Version 21H2'))

# Server, where the catalog's name and the product's name are not the same words
# at all. The cumulative for Server 2025 is titled "Cumulative Update for
# Microsoft server operating system version 24H2" -- searching the catalog for
# "Windows Server 2025" returns nothing, which reads as "no updates available".
$srv = @($products | Where-Object { $_.Product -eq 'Microsoft server operating system version 24H2' })
Test-Case 'the Server 2025 catalog name is offered' 1 $srv.Count
Test-Case 'and says which release it is'  $true ($srv[0].Note -match 'Server 2025')
Test-Case 'and warns about the name'      $true ($srv[0].Note -match 'does NOT call this')

$srv22 = @($products | Where-Object { $_.Product -eq 'Microsoft server operating system version 21H2' })
Test-Case 'Server 2022 as well'           1 $srv22.Count
# "version 21H2" here is a server release. Someone scanning the list could easily
# read it as the Windows 10 entry two lines up, and they are unrelated.
Test-Case 'and is not confused with Windows 10 21H2' $true ($srv22[0].Note -match 'nothing to do with Windows 10')

# The name on the box is kept, below the one that works, because it is what
# everyone tries first and a few entries genuinely are titled that way.
$order2 = @($products | ForEach-Object { $_.Product })
Test-Case 'the working name comes before the obvious one' $true `
    ($order2.IndexOf('Microsoft server operating system version 24H2') -lt $order2.IndexOf('Windows Server 2025'))

# Anything read from an image outranks anything written down here.
$target = [pscustomobject]@{
    Product = 'Windows 10 Version 22H2'; Precise = $true
    ProductAlternative = @('Windows 10 Version 21H2')
}
$withImage = @(Get-WfUpdateProductChoice -Target $target)
Test-Case 'the image answer comes first'  'Windows 10 Version 22H2' $withImage[0].Product
Test-Case 'and is marked as such'         $true $withImage[0].FromImage
Test-Case 'it says where it came from'    $true ($withImage[0].Note -match 'read from the image')
Test-Case 'no duplicate of it further down' 1 `
    @($withImage | Where-Object { $_.Product -eq 'Windows 10 Version 22H2' }).Count

# A guess must be labelled a guess. The header cannot tell 21H2 from 22H2, and an
# operator who does not know that will trust the wrong answer.
$guessed = [pscustomobject]@{ Product = 'Windows 10 Version 22H2'; Precise = $false; ProductAlternative = @() }
Test-Case 'a guess is labelled' $true `
    (@(Get-WfUpdateProductChoice -Target $guessed)[0].Note -match 'guessed')

Write-Host 'Architecture choices' -ForegroundColor Cyan

$arch = @(Get-WfUpdateArchitectureChoice)
Test-Case 'x64 is offered'   1 @($arch | Where-Object { $_.Architecture -eq 'x64' }).Count
# 'amd64' is what the rest of Windows calls it and is NOT what the catalog does.
Test-Case 'amd64 is not'     0 @($arch | Where-Object { $_.Architecture -eq 'amd64' }).Count
Test-Case 'each explains itself' 0 @($arch | Where-Object { -not $_.Note }).Count

Write-Host 'What is already in the image' -ForegroundColor Cyan

# Three states, and the third one is the point. '$false' would mean both 'not in
# the image' and 'nobody looked', and those are different answers to give
# somebody deciding what to download. The console displayed this with a plain
# truthiness test, which marked EVERY unchecked result as already installed --
# the exact opposite of what it meant.
. (Join-Path $root 'WimForge\Private\Core.ps1')
. (Join-Path $root 'WimForge\Public\Updates.ps1')

function Get-WfConfig { @{ UpdateProduct = 'x'; UpdateArchitecture = 'x64' } }
function Assert-WfElevated { }

# Defined AFTER the module file, not before: dot-sourcing Updates.ps1 defines the
# real Search-WfCatalog, and a stub written first is simply overwritten by it --
# at which point the test quietly goes to the internet.
function Search-WfCatalog {
    param([string] $Query, [switch] $IncludePreview, [switch] $IncludeDynamic, [string] $Architecture)
    return @(
        [pscustomobject]@{ KB='KB5094127'; Title='Cumulative A'; Category='Security Updates'
                           Classification=''; Products=''; LastUpdated=[datetime]'2026-06-10'
                           LastUpdatedText='2026-06-10'; SizeMB=700.0; SizeBytes=700MB
                           SizeText='700 MB'; UpdateId='guid-a'; InImage='?' }
        [pscustomobject]@{ KB='KB5099999'; Title='Cumulative B'; Category='Security Updates'
                           Classification=''; Products=''; LastUpdated=[datetime]'2026-07-10'
                           LastUpdatedText='2026-07-10'; SizeMB=710.0; SizeBytes=710MB
                           SizeText='710 MB'; UpdateId='guid-b'; InImage='?' }
    )
}

# Nobody looked: everything stays '?'.
$unchecked = @(Find-WfUpdate -Product 'Windows 10 Version 22H2' -Architecture x64)
Test-Case 'unchecked results read ?' @('?', '?') @($unchecked | ForEach-Object { $_.InImage })
Test-Case 'and none of them says yes' 0 @($unchecked | Where-Object { $_.InImage -eq 'yes' }).Count

# Looked, and one of them is in there.
$checked = @(Find-WfUpdate -Product 'Windows 10 Version 22H2' -Architecture x64 -KnownKB @('KB5094127'))
Test-Case 'the installed one says yes' 'yes' @($checked | Where-Object { $_.KB -eq 'KB5094127' })[0].InImage
Test-Case 'the other says no'          'no'  @($checked | Where-Object { $_.KB -eq 'KB5099999' })[0].InImage

# An empty list is 'nobody looked', not 'nothing is installed'. An image with no
# KB-numbered packages and an image that was never mounted must not read alike.
$empty = @(Find-WfUpdate -Product 'Windows 10 Version 22H2' -Architecture x64 -KnownKB @())
Test-Case 'an empty known-KB list still reads ?' @('?', '?') @($empty | ForEach-Object { $_.InImage })

# The bug the third state exposed: '?' is a non-empty string and is therefore
# truthy, so every plain `if ($r.InImage)` had to become a comparison.
foreach ($f in @('Start-WimForgeMenu.ps1', 'Start-WimForgeGui.ps1')) {
    $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw
    Test-Case "$f does not test InImage for truthiness" $false `
        ($src -match '\(\$\w+\.InImage\)')
}

$upd = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Updates.ps1') -Raw
Test-Case 'Get-WfLatestUpdate compares the value' $true ($upd -match "\`$newest\.InImage -eq 'yes'")

# And both front-ends show the KBs, not just how many there are.
foreach ($f in @('Start-WimForgeMenu.ps1', 'Start-WimForgeGui.ps1')) {
    $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw
    Test-Case "$f lists the installed KBs" $true ($src -match 'InstalledKB \| .*Sort-Object -Unique')
    Test-Case "$f explains an unlisted image" $true ($src -match "needs a mount")
}

Write-Host 'Build comparison -- real titles from a real 24H2 LTSC image' -ForegroundColor Cyan

# Verbatim from a search against Win11IoTLTSC2024, whose image is at 26100.7623.
# KB matching cannot answer any of these: a cumulative is installed in the image
# as 'Package_for_RollupFix~...' with no KB in the name at all, so InstalledKB
# comes back empty and every row would read '?' forever. The build in the title
# is the answer that is actually available.
function Search-WfCatalog {
    param([string] $Query, [switch] $IncludePreview, [switch] $IncludeDynamic, [string] $Architecture)
    $titles = @(
        @{ KB='KB5121767'; T='2026-07 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5121767) (26100.8894)' }
        @{ KB='KB5101650'; T='2026-07 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5101650) (26100.8875)' }
        @{ KB='KB5094126'; T='2026-06 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5094126) (26100.8655)' }
        @{ KB='KB5085516'; T='2026-03 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5085516) (26100.8039)' }
        # The image's own build, and one below it.
        @{ KB='KB5000001'; T='2026-01 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5000001) (26100.7623)' }
        @{ KB='KB5000000'; T='2025-12 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5000000) (26100.7500)' }
        # A .NET rollup, which carries no build at all.
        @{ KB='KB5101001'; T='2026-07 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 24H2 for x64 (KB5101001)' }
        # And a different release entirely, which must not be compared on revision.
        @{ KB='KB5099998'; T='2026-07 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5099998) (26200.1200)' }
    )
    $i = 0
    return @($titles | ForEach-Object {
        $i++
        [pscustomobject]@{ KB=$_.KB; Title=$_.T; Category='Security Updates'
                           Classification=''; Products=''; LastUpdated=([datetime]'2026-07-18').AddDays(-$i)
                           LastUpdatedText='2026-07-18'; SizeMB=5000.0; SizeBytes=5GB
                           SizeText='5 GB'; UpdateId="guid-$i"; InImage='?'; TargetBuild=''; VsImage='?' }
    })
}

$r = @(Find-WfUpdate -Product 'Windows 11 Version 24H2' -Architecture x64 -ImageBuild '26100.7623')
function Row { param([string] $KB) @($r | Where-Object { $_.KB -eq $KB })[0] }

Test-Case 'the build is parsed out of the title' '26100.8894' (Row 'KB5121767').TargetBuild
Test-Case 'and off a differently-worded title'   '26100.8039' (Row 'KB5085516').TargetBuild

# The four newer ones are the answer to "what do I still need".
Test-Case 'newer builds read newer' @('KB5085516','KB5094126','KB5101650','KB5121767') `
    @($r | Where-Object { $_.VsImage -eq 'newer' } | ForEach-Object { $_.KB } | Sort-Object)

Test-Case 'the image''s own build reads same'  'same'  (Row 'KB5000001').VsImage
Test-Case 'and one below it reads older'       'older' (Row 'KB5000000').VsImage

# A .NET rollup has no build in its title, and inventing one would be worse than
# admitting it cannot be compared this way.
Test-Case 'a title with no build stays unknown' '?' (Row 'KB5101001').VsImage
Test-Case 'and carries no build'                ''  (Row 'KB5101001').TargetBuild

# 26200 vs 26100 are different releases. Comparing their revisions would say
# 26200.1200 is OLDER than 26100.7623, which is nonsense.
Test-Case 'a different release is not compared on revision' 'other release' (Row 'KB5099998').VsImage

# KB matching stays '?' throughout, which is the honest answer for an image whose
# packages carry no KB numbers.
Test-Case 'InImage is untouched by the build comparison' 8 @($r | Where-Object { $_.InImage -eq '?' }).Count

Write-Host 'The download-to-inject handoff' -ForegroundColor Cyan

# Both front-ends do the same filter before injecting. Checked as source rather
# than run, because running it needs a catalog and a mounted image.
foreach ($f in @('Start-WimForgeGui.ps1', 'Start-WimForgeMenu.ps1')) {
    $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw

    # Only what is on disk is injected.
    Test-Case "$f injects only what downloaded" $true `
        ($src -match "Status -eq 'Downloaded' -or \`$_\.Status -eq 'AlreadyPresent'")

    # And a failed download stops the run rather than silently shortening it.
    Test-Case "$f stops when a download failed" $true `
        ($src -match 'download\(s\) failed, so nothing was injected')

    Test-Case "$f refuses an empty injection list" $true `
        ($src -match 'nothing to inject')
}

Write-Host 'Both front-ends explain a failure rather than showing the code' -ForegroundColor Cyan

foreach ($f in @('Start-WimForgeGui.ps1', 'Start-WimForgeMenu.ps1')) {
    $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw
    Test-Case "$f runs failures through the translator" $true ($src -match 'Get-WfDismError')
    Test-Case "$f offers the product list"              $true ($src -match 'Get-WfUpdateProductChoice')
    Test-Case "$f offers the architecture list"         $true ($src -match 'Get-WfUpdateArchitectureChoice')
}

# The GUI has a grid, so the per-package outcome belongs in it -- otherwise a run
# that applied two and skipped one looks exactly like one that applied three.
$gui = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeGui.ps1') -Raw
Test-Case 'the GUI shows the injection result' $true ($gui -match 'not applicable, \$\(\$failed\.Count\) failed')
Test-Case 'and says a skip is normal'          $true ($gui -match 'That is normal')

Write-Host 'Add-WfUpdate classifies rather than lumps together' -ForegroundColor Cyan

$svc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw
Test-Case 'there is a NotApplicable status'      $true ($svc -match "'NotApplicable'")
Test-Case 'set from the classification'          $true ($svc -match "if \(-not \`$why\.Fatal\) \{ \`$status = 'NotApplicable' \}")
Test-Case 'and it only throws on a fatal one'    $true ($svc -match 'if \(-not \$ContinueOnError -and \$why\.Fatal\)')

# Every result row needs the same properties or the grid drops columns: a
# DataTable is built from the first row's shape.
Test-Case 'applied rows carry the same fields' $true `
    ($svc -match "Package = \`$p\.Name; Status = 'Applied'; Reason = ''")

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
