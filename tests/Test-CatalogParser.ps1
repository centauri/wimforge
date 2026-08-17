# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Search-WfCatalog against a fixture page, with Invoke-WebRequest stubbed.
#
# This exists because the parser was shipped untested behind a mocked
# Search-WfCatalog, and a [ref] bound to a $null variable took the whole search
# down on the first real search anyone ran. Every line of the parser now runs
# here, offline.

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

function Get-WfConfig { @{ UpdateProduct = 'Windows 11 Version 24H2'; UpdateArchitecture = 'x64' } }
function Write-WfLog  { param([string]$Message, [string]$Level) $script:Logged += @("$Level|$Message") }

# --------------------------------------------------------------- the fixture
function New-Row {
    param([string]$Guid, [string]$Title, [string]$Class, [string]$Date, [string]$SizeText, [string]$Bytes)
    @"
<tr id="${Guid}_R1">
  <td></td>
  <td><a id="${Guid}_link" href="#">
      $Title
  </a></td>
  <td>Windows 11</td>
  <td>$Class</td>
  <td>$Date</td>
  <td>n/a</td>
  <td><span id="${Guid}_size">$SizeText</span><span>$Bytes</span></td>
  <td><input type="button" value="Download" /></td>
</tr>
"@
}

$g1 = '11111111-2222-3333-4444-555555555555'
$g2 = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$g3 = '99999999-8888-7777-6666-555555555555'

$script:Page = @"
<html><body><table id="ctl00_catalogBody_updateMatches">
$(New-Row $g1 '2026-07 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5099539)' 'Security Updates' '7/15/2026' '4.1 GB' '4402341888')
$(New-Row $g2 '2026-06 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5094127)' 'Security Updates' '6/9/2026'  '4.0 GB' '4295000000')
$(New-Row $g3 '2026-07 Cumulative Update Preview for Windows 11 Version 24H2 for arm64-based Systems (KB5099540)' 'Updates' '7/22/2026' '4.2 GB' '4500000000')
</table></body></html>
"@

function Invoke-WebRequest {
    param([string]$Uri, [switch]$UseBasicParsing, [int]$TimeoutSec, [string]$ErrorAction)
    $script:LastUri = $Uri
    return [pscustomobject]@{ Content = $script:Page }
}

# ----------------------------------------------------------------- the tests
Write-Host 'Parsing a results page' -ForegroundColor Cyan
$script:Logged = @()
$r = @(Search-WfCatalog -Query 'Cumulative Update for Windows 11 Version 24H2 x64' -Architecture 'x64')

Test-Case 'two results (preview dropped)' 2 $r.Count
Test-Case 'KB extracted'   @('KB5099539','KB5094127') @($r | ForEach-Object { $_.KB })
Test-Case 'title trimmed'  '2026-07 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5099539)' $r[0].Title
Test-Case 'update id'      $g1 $r[0].UpdateId
Test-Case 'classification' 'Security Updates' $r[0].Classification
Test-Case 'products'       'Windows 11' $r[0].Products
Test-Case 'size in bytes'  4402341888 $r[0].SizeBytes
Test-Case 'size in MB'     ([math]::Round(4402341888/1MB,1)) $r[0].SizeMB
Test-Case 'category'       'Cumulative' $r[0].Category
# Three-state, not boolean. The parser has not been told what is in any image,
# so '?' is the honest answer -- 'no' would be a claim nobody checked.
Test-Case 'InImage starts unknown' '?' $r[0].InImage

Write-Host 'Dates -- the parse that took the whole search down' -ForegroundColor Cyan
Test-Case 'parsed to a DateTime' $true ($r[0].LastUpdated -is [datetime])
Test-Case 'the right date'       '2026-07-15' $r[0].LastUpdated.ToString('yyyy-MM-dd')
Test-Case 'text kept as shown'   '7/15/2026'  $r[0].LastUpdatedText

Write-Host 'An unparseable date leaves LastUpdated null, and nothing throws' -ForegroundColor Cyan
$script:Page = @"
<html><body><table>
$(New-Row $g1 'Cumulative Update for Windows 11 Version 24H2 x64 (KB5099539)' 'Security Updates' 'not a date' '4.1 GB' '4402341888')
</table></body></html>
"@
$r2 = @(Search-WfCatalog -Query 'x' -Architecture 'x64')
Test-Case 'still one result' 1     $r2.Count
Test-Case 'null date'        $true ($null -eq $r2[0].LastUpdated)
Test-Case 'text preserved'   'not a date' $r2[0].LastUpdatedText

Write-Host 'Architecture filtering' -ForegroundColor Cyan
$script:Page = @"
<html><body><table>
$(New-Row $g1 'Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5099539)'   'Security Updates' '7/15/2026' '4.1 GB' '4402341888')
$(New-Row $g2 'Cumulative Update for Windows 11 Version 24H2 for arm64-based Systems (KB5099539)' 'Security Updates' '7/15/2026' '4.1 GB' '4402341888')
$(New-Row $g3 'Servicing Stack Update for Windows 11 Version 24H2 (KB5099541)'                    'Security Updates' '7/15/2026' '12.0 MB' '12582912')
</table></body></html>
"@
$r3 = @(Search-WfCatalog -Query 'x' -Architecture 'x64')
Test-Case 'arm64 dropped, untyped kept' 2 $r3.Count
Test-Case 'ssu classified'              'ServicingStack' ($r3 | Where-Object { $_.KB -eq 'KB5099541' }).Category

$r4 = @(Search-WfCatalog -Query 'x' -Architecture 'x64' -HasExplicitQuery)
Test-Case 'explicit query keeps everything' 3 $r4.Count

Write-Host 'Previews' -ForegroundColor Cyan
$script:Page = @"
<html><body><table>
$(New-Row $g1 'Cumulative Update Preview for Windows 11 Version 24H2 for x64-based Systems (KB5099540)' 'Updates' '7/22/2026' '4.2 GB' '4500000000')
</table></body></html>
"@
Test-Case 'dropped by default'   0 @(Search-WfCatalog -Query 'x' -Architecture 'x64').Count
Test-Case 'kept when asked for'  1 @(Search-WfCatalog -Query 'x' -Architecture 'x64' -IncludePreview).Count

Write-Host 'Both switches together -- the path where no filter runs' -ForegroundColor Cyan
# With -IncludePreview and -IncludeDynamic set, neither filter rewrites the
# result list, so whatever the parser built reaches the end untouched. That is
# the one path where a List[object] would have escaped as-is.
$script:Page = @"
<html><body><table>
$(New-Row $g1 'Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5099539)' 'Security Updates' '7/15/2026' '4.1 GB' '4402341888')
$(New-Row $g2 'Cumulative Update Preview for Windows 11 Version 24H2 for x64-based Systems (KB5099540)' 'Updates' '7/22/2026' '4.2 GB' '4500000000')
</table></body></html>
"@
$both = @(Search-WfCatalog -Query 'x' -HasExplicitQuery -IncludePreview -IncludeDynamic)
Test-Case 'returned both rows' 2 $both.Count
Test-Case 'and they are objects, not a list' $true ($both[0].KB -eq 'KB5099539')

Write-Host 'No results, and a page that no longer parses' -ForegroundColor Cyan
$script:Page = '<html><body>We did not find any results for that search.</body></html>'
Test-Case 'empty, not an error' 0 @(Search-WfCatalog -Query 'x').Count

$script:Page = '<html><body><table><tr><td>the layout changed</td></tr></table></body></html>'
$msg = ''
try { Search-WfCatalog -Query 'x' } catch { $msg = $_.Exception.Message }
Test-Case 'says the layout changed' $true ([bool]($msg -match 'layout has changed'))

Write-Host 'The query reaches the URL escaped' -ForegroundColor Cyan
$script:Page = '<html><body>We did not find any results</body></html>'
$null = Search-WfCatalog -Query 'Cumulative Update for Windows 11 Version 24H2 x64'
Test-Case 'escaped query' $true ([bool]($script:LastUri -match 'Windows%2011%20Version%2024H2'))
Test-Case 'https'         $true ([bool]($script:LastUri -match '^https://'))

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
