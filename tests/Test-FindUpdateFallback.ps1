# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Find-WfUpdate's product fallback and known-KB flagging, with the catalog
# itself stubbed out. No network.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'WimForge\Public\Updates.ps1')

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

# ------------------------------------------------------------------- the stubs
function Get-WfConfig { @{ UpdateProduct = 'Configured Product'; UpdateArchitecture = 'x64' } }
function Write-WfLog  { param([string]$Message, [string]$Level) $script:Logged += @("$Level|$Message") }

$script:Queries = @()
$script:Answers = @{}
function Search-WfCatalog {
    param([string]$Query, [string]$Architecture, [switch]$HasExplicitQuery,
          [switch]$IncludePreview, [switch]$IncludeDynamic)
    $script:Queries += $Query
    if ($script:Answers.ContainsKey($Query)) { return @($script:Answers[$Query]) }
    return @()
}

function New-Row {
    param([string]$Kb, [string]$Title, [datetime]$When)
    [pscustomobject]@{ KB=$Kb; Title=$Title; Category='Cumulative'; LastUpdated=$When
                       LastUpdatedText=$When.ToString('yyyy-MM-dd'); SizeMB=650; SizeBytes=680000000
                       UpdateId=[guid]::NewGuid().ToString(); InImage='?' }
}

# --------------------------------------------------------------------- the tests
Write-Host 'Product fallback' -ForegroundColor Cyan

$script:Queries = @(); $script:Logged = @()
$script:Answers = @{
    'Cumulative Update for Windows 10 Version 22H2 x64' = @(New-Row 'KB5094127' '2026-06 CU for Windows 10 Version 22H2 x64' ([datetime]'2026-06-09'))
}
$r = Find-WfUpdate -Category Cumulative -Product 'Windows 10 Version 21H2' `
                   -ProductAlternative @('Windows 10 Version 22H2') -Architecture 'x64'

Test-Case 'tried the primary product first' 'Cumulative Update for Windows 10 Version 21H2 x64' $script:Queries[0]
Test-Case 'fell back to the alternative'    2          $script:Queries.Count
Test-Case 'returned the fallback result'    'KB5094127' $r[0].KB
Test-Case 'said which product answered'     $true      ([bool]($script:Logged -match "these are the results for 'Windows 10 Version 22H2'"))

Write-Host 'No fallback when the primary answers' -ForegroundColor Cyan
$script:Queries = @()
$script:Answers = @{
    'Cumulative Update for Windows 10 Version 21H2 x64' = @(New-Row 'KB5000001' 'CU 21H2' ([datetime]'2026-06-09'))
    'Cumulative Update for Windows 10 Version 22H2 x64' = @(New-Row 'KB5094127' 'CU 22H2' ([datetime]'2026-06-09'))
}
$r = Find-WfUpdate -Category Cumulative -Product 'Windows 10 Version 21H2' `
                   -ProductAlternative @('Windows 10 Version 22H2') -Architecture 'x64'
Test-Case 'only one search'      1           $script:Queries.Count
Test-Case 'primary result kept'  'KB5000001' $r[0].KB

Write-Host 'A free-text query ignores products entirely' -ForegroundColor Cyan
$script:Queries = @()
$script:Answers = @{ 'KB5094127' = @(New-Row 'KB5094127' 'CU' ([datetime]'2026-06-09')) }
$r = Find-WfUpdate -Query 'KB5094127' -Product 'Windows 10 Version 21H2' `
                   -ProductAlternative @('Windows 10 Version 22H2')
Test-Case 'searched the query verbatim' @('KB5094127') $script:Queries
Test-Case 'one result'                  1             @($r).Count

Write-Host 'Known KBs are flagged' -ForegroundColor Cyan
$script:Queries = @()
$script:Answers = @{
    'Cumulative Update for Windows 10 Version 22H2 x64' = @(
        (New-Row 'KB5094127' 'newest CU'   ([datetime]'2026-06-09')),
        (New-Row 'KB5090000' 'last month'  ([datetime]'2026-05-12'))
    )
}
$r = Find-WfUpdate -Category Cumulative -Product 'Windows 10 Version 22H2' `
                   -Architecture 'x64' -KnownKB @('KB5090000')
Test-Case 'newest first'          'KB5094127' $r[0].KB
# 'no' and 'yes' rather than $false and $true: once a known-KB list has been
# supplied, every row has a real answer. '?' would mean the list was never given.
Test-Case 'newest not in image'   'no'        $r[0].InImage
Test-Case 'older one flagged'     'yes'       $r[1].InImage

Write-Host 'Empty everywhere' -ForegroundColor Cyan
$script:Queries = @(); $script:Answers = @{}
$r = @(Find-WfUpdate -Category Cumulative -Product 'Windows 10 Version 21H2' `
                     -ProductAlternative @('Windows 10 Version 22H2') -Architecture 'x64')
Test-Case 'tried both, returned nothing' 2 $script:Queries.Count
Test-Case 'empty array, not null'        0 $r.Count

Write-Host 'Falls back to the configured product when none is given' -ForegroundColor Cyan
$script:Queries = @()
$r = Find-WfUpdate -Category Cumulative
Test-Case 'used the config' 'Cumulative Update for Configured Product x64' $script:Queries[0]

Write-Host 'Get-WfLatestUpdate with nothing to find' -ForegroundColor Cyan
# A function returning @() writes nothing, so the caller sees $null -- and
# @($null).Count is 1. Getting this wrong means the "nothing found" guard never
# fires and $null reaches Save-WfUpdate as a mandatory string parameter.
$script:Saved = 0
function Save-WfUpdate { param([Parameter(ValueFromPipeline)] $InputObject) process { $script:Saved++ } }

$script:Queries = @(); $script:Answers = @{}; $script:Logged = @()
$r = @(Get-WfLatestUpdate -Category Cumulative -Product 'Windows 10 Version 21H2' -Architecture 'x64')
Test-Case 'returned empty'        0     $r.Count
Test-Case 'downloaded nothing'    0     $script:Saved
Test-Case 'said nothing was found' $true ([bool]($script:Logged -match 'Nothing found'))

Write-Host 'Get-WfLatestUpdate takes the newest and downloads it' -ForegroundColor Cyan
$script:Saved = 0
$script:Answers = @{
    'Cumulative Update for Windows 10 Version 21H2 x64' = @(
        (New-Row 'KB5090000' 'older' ([datetime]'2026-05-12')),
        (New-Row 'KB5094127' 'newer' ([datetime]'2026-06-09'))
    )
}
$r = Get-WfLatestUpdate -Category Cumulative -Product 'Windows 10 Version 21H2' -Architecture 'x64'
Test-Case 'downloaded one' 1 $script:Saved

$script:Saved = 0
$r = Get-WfLatestUpdate -Category Cumulative -Product 'Windows 10 Version 21H2' -Architecture 'x64' -WhatIfOnly
Test-Case 'WhatIfOnly downloads nothing' 0 $script:Saved
Test-Case 'WhatIfOnly still reports the newest' 'KB5094127' $r.KB

Write-Host 'A server result gets its build from the same KB elsewhere' -ForegroundColor Cyan

# Client titles end with the build they install -- '(26100.8875)'. Server titles
# do not: the same update reads '... for x64-based Systems (KB5087545)' and stops
# there. That is not a build that does not exist; it is a build that is written
# down somewhere else, because Server 2025 and Windows 11 24H2 ship as ONE KB.
# So the KB is looked up and the client entry answers for it.
$script:Logged  = @()
$script:Answers = @{
    'Cumulative Update for Microsoft server operating system version 24H2 x64' = @(
        (New-Row 'KB5101650' '2026-07 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5101650)' ([datetime]'2026-07-14'))
    )
    # The same KB, as the catalog also lists it: two client entries, two builds.
    # 26200 is 25H2 and 26100 is 24H2 -- picking whichever came first would
    # compare a 24H2 image against a 25H2 build and call it 'other release'.
    'KB5101650' = @(
        (New-Row 'KB5101650' '2026-07 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5101650) (26200.8875)' ([datetime]'2026-07-14')),
        (New-Row 'KB5101650' '2026-07 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5101650) (26100.8875)' ([datetime]'2026-07-14'))
    )
}
$r = Find-WfUpdate -Category Cumulative -Product 'Microsoft server operating system version 24H2' `
                   -Architecture 'x64' -ImageBuild '26100.1742'

Test-Case 'the KB was looked up'      $true ($script:Queries -contains 'KB5101650')
Test-Case 'the build was recovered'   '26100.8875' $r[0].TargetBuild
Test-Case 'and it compares'           'newer'      $r[0].VsImage
Test-Case 'the count is reported'     $true ([bool]($script:Logged -match 'would move it forward'))

Write-Host 'And the image family decides which sibling answers' -ForegroundColor Cyan
# An image in the OTHER family: the 26200 sibling is the one that applies now,
# and the 26100 one must not be taken just because it exists.
#
# The fixture is rebuilt rather than reused. Find-WfUpdate writes TargetBuild
# onto the result objects it is handed -- they are the catalog's rows, and it
# annotates them in place -- so a second search against the same objects would
# read back the first search's answer and pass on it.
$script:Answers = @{
    'Cumulative Update for Microsoft server operating system version 24H2 x64' = @(
        (New-Row 'KB5101650' '2026-07 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5101650)' ([datetime]'2026-07-14'))
    )
    'KB5101650' = @(
        (New-Row 'KB5101650' '2026-07 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5101650) (26200.8875)' ([datetime]'2026-07-14')),
        (New-Row 'KB5101650' '2026-07 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5101650) (26100.8875)' ([datetime]'2026-07-14'))
    )
}
$r = Find-WfUpdate -Category Cumulative -Product 'Microsoft server operating system version 24H2' `
                   -Architecture 'x64' -ImageBuild '26200.1000'
Test-Case 'the matching family wins' '26200.8875' $r[0].TargetBuild

Write-Host 'A build that cannot be recovered stays honest' -ForegroundColor Cyan

# Client cumulative titles end with the build they install -- '(26100.8875)' --
# and that is what the "vs image" column reads. Server titles do not: the same
# month's server update ends at '... for x64-based Systems (KB5087545)'. With
# nothing to compare, the old line reported "0 of these would move it forward",
# which reads as "you are already up to date" on a list that simply could not be
# measured. That is the most expensive wrong answer this column could give.
# Nothing answers for KB5087545 -- an older Server 2022 update, whose KB has no
# client counterpart at all. There is no build to be had, and inventing one
# would be worse than saying so.
$script:Logged  = @()
$script:Answers = @{
    'Cumulative Update for Microsoft server operating system version 24H2 x64' = @(
        (New-Row 'KB5087545' '2026-05 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5087545)' ([datetime]'2026-05-12'))
    )
}
$r = Find-WfUpdate -Category Cumulative -Product 'Microsoft server operating system version 24H2' `
                   -Architecture 'x64' -ImageBuild '26100.1742'

Test-Case 'the result is still returned'   'KB5087545' $r[0].KB
Test-Case 'and not claimed to be compared' '?'         $r[0].VsImage
Test-Case 'it says nothing could be compared' $true ([bool]($script:Logged -match 'none of these titles says which build it installs'))
Test-Case 'and it is a warning, not an OK'    $true ([bool]($script:Logged -match '^WARN\|.*could be compared|^WARN\|.*build it installs'))

# The client case must be unaffected: a title carrying a build still compares.
$script:Logged  = @()
$script:Answers = @{
    'Cumulative Update for Windows 11 Version 24H2 x64' = @(
        (New-Row 'KB5101650' '2026-07 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5101650) (26100.8875)' ([datetime]'2026-07-14'))
    )
}
$r = Find-WfUpdate -Category Cumulative -Product 'Windows 11 Version 24H2' `
                   -Architecture 'x64' -ImageBuild '26100.1742'
Test-Case 'a client title still compares' 'newer' $r[0].VsImage
Test-Case 'and reports the count'         $true ([bool]($script:Logged -match 'would move it forward'))

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
