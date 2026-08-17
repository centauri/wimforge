# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# "Newest build wins" quietly picks emergency fixes over the monthly update.
#
# Nothing in a catalog title separates the two. Both of these are 24H2 x64
# cumulative updates and both read identically apart from the numbers:
#
#   KB5101650  2026-07 Cumulative Update ... (26100.8875)   14 July -- a Tuesday
#   KB5121767  2026-07 Cumulative Update ... (26100.8894)   18 July -- a Saturday
#
# Sorting on target build makes the Saturday one the automatic choice: a narrower
# fix with days rather than weeks of soak time, chosen by a maintenance job that
# nobody was watching. The only signal available is the date, because Microsoft
# ships security updates on the second Tuesday of the month.
#
# This is a heuristic and is treated as one -- it LABELS, so the interactive
# picker still shows everything. Only automatic selection acts on it.
#
# Every date below is real, taken from an actual search against 24H2.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

function Write-WfLog { param([string]$Message, [string]$Level, [switch]$NoConsole) }
. (Join-Path $root 'WimForge\Private\Core.ps1')
. (Join-Path $root 'WimForge\Public\Updates.ps1')

Write-Host 'Patch Tuesday is the second Tuesday, computed not guessed' -ForegroundColor Cyan

Test-Case 'March 2026'  '2026-03-10' (Get-WfPatchTuesday -Year 2026 -Month 3).ToString('yyyy-MM-dd')
Test-Case 'April 2026'  '2026-04-14' (Get-WfPatchTuesday -Year 2026 -Month 4).ToString('yyyy-MM-dd')
Test-Case 'July 2026'   '2026-07-14' (Get-WfPatchTuesday -Year 2026 -Month 7).ToString('yyyy-MM-dd')

# A month starting ON a Tuesday is the case an off-by-one gets wrong: the 1st
# counts, so the second Tuesday is the 8th and not the 15th.
$sep = Get-WfPatchTuesday -Year 2025 -Month 7
Test-Case 'a month beginning on a Tuesday' 'Tuesday' "$($sep.DayOfWeek)"
Test-Case 'and it is the second one'       $true     ($sep.Day -ge 8 -and $sep.Day -le 14)

Write-Host 'The real search, classified' -ForegroundColor Cyan

$rows = @(
    @{ T = '2026-07 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5101650) (26100.8875)'; D = '2026-07-14'; Want = 'Regular'   }
    @{ T = '2026-07 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5121767) (26100.8894)'; D = '2026-07-18'; Want = 'OutOfBand' }
    @{ T = '2026-06 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5094126) (26100.8655)'; D = '2026-06-09'; Want = 'Regular'   }
    @{ T = '2026-05 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5089549) (26100.8457)'; D = '2026-05-12'; Want = 'Regular'   }
    @{ T = '2026-04 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5083769) (26100.8246)';  D = '2026-04-14'; Want = 'Regular'   }
    @{ T = '2026-03 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5086672) (26100.8117)';  D = '2026-03-31'; Want = 'OutOfBand' }
    @{ T = '2026-03 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5085516) (26100.8039)';  D = '2026-03-21'; Want = 'OutOfBand' }
)

foreach ($r in $rows) {
    $kb = [regex]::Match($r.T, 'KB\d+').Value
    Test-Case "$kb on $($r.D)" $r.Want (Get-WfReleaseKind -Title $r.T -LastUpdated ([datetime]$r.D))
}

Write-Host 'Previews say so, and are not judged on their date' -ForegroundColor Cyan

# A preview ships late in the month by definition, so date alone would call it
# out-of-band -- true but not the useful answer.
Test-Case 'a preview is a preview' 'Preview' `
    (Get-WfReleaseKind -Title '2026-07 Cumulative Update Preview for Windows 11, version 24H2 (KB5100000)' `
                       -LastUpdated ([datetime]'2026-07-25'))

Write-Host 'The servicing month comes from the title, not the date' -ForegroundColor Cyan

# A re-release in the following month is still that month's update, and judging
# it against August's Patch Tuesday would mislabel it.
Test-Case 'a July update re-released in August' 'OutOfBand' `
    (Get-WfReleaseKind -Title '2026-07 Cumulative Update for Windows 11, version 24H2 (KB5101650)' `
                       -LastUpdated ([datetime]'2026-08-03'))

Write-Host 'Nothing here throws' -ForegroundColor Cyan

# The trap this walked into: [datetime] as a parameter type REFUSES $null. It
# fails argument transformation, which is terminating, and the caller is the
# catalog parser -- whose date is $null whenever one could not be parsed. One
# unreadable date took the entire search down.
$threw = $false
try { $k = Get-WfReleaseKind -Title 'Cumulative Update' -LastUpdated $null } catch { $threw = $true }
Test-Case 'a null date does not throw' $false $threw
Test-Case 'and reads as Unknown'       'Unknown' $k

Test-Case 'so does an empty title' 'Unknown' (Get-WfReleaseKind -Title '' -LastUpdated $null)
Test-Case 'and a dateless entry'   'Unknown' `
    (Get-WfReleaseKind -Title '2026-07 Cumulative Update' -LastUpdated ([datetime]::MinValue))

Write-Host 'Automatic selection prefers the monthly update' -ForegroundColor Cyan

$upd = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Updates.ps1') -Raw

Test-Case 'every result carries a Release' $true ($upd -match 'Release\s*=\s*\(Get-WfReleaseKind')

# Get-WfLatestUpdate is the unattended path -- the one where nobody sees the
# list. That is where the preference belongs.
Test-Case 'the latest-update path checks it'  $true ($upd -match "\`$regular = @\(\`$found \| Where-Object \{ \`$_\.Release -eq 'Regular' \}\)")
Test-Case 'and only steps in when it has to' $true ($upd -match "\`$regular\.Count -gt 0 -and \`$newest\.Release -ne 'Regular'")
Test-Case 'with an override'                 $true ($upd -match '\[switch\]\s*\$PreferOutOfBand')
Test-Case 'and it says what it skipped'      $true ($upd -match 'Skipping \{0\} -- it is an \{1\} release')

# The interactive search must NOT filter on this. Hiding an out-of-band fix from
# someone who came looking for it is a worse failure than defaulting past it.
Test-Case 'the search does not filter on Release' $false ($upd -match "Where-Object \{ \`$_\.Release -ne 'OutOfBand' \}")

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
