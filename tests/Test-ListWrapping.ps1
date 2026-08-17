# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# @() around a List[object] must not appear anywhere in the project.
#
# On PowerShell 7 it throws "Argument types do not match" -- and only for
# List[object]; List[string] and ArrayList are fine, which is what makes it so
# easy to write. There is no warning, no partial result: the whole call dies with
# a message that says nothing about lists.
#
# It has now been introduced three separate times in this project, twice in code
# that had tests passing around it because no test reached the one line that
# wrapped the list. So it is checked mechanically rather than remembered.
#
# Use .ToArray() instead. It says what it means and works on every host.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

function Find-WfWrappedList {
    <#
        Reports every @($x) where $x is assigned a List[object] in the same file.

        Same-file rather than same-function on purpose: a list built in one
        function and wrapped in another is just as broken, and the false positive
        this risks -- two different variables sharing a name, one of them a list --
        is a variable name worth changing anyway.
    #>
    param([string] $Path)

    $source = Get-Content -LiteralPath $Path -Raw
    $lists  = @([regex]::Matches($source, '\$(\w+)\s*=\s*New-Object System\.Collections\.Generic\.List\[object\]') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    $problems = @()
    foreach ($name in $lists) {
        foreach ($m in [regex]::Matches($source, '@\(\$' + [regex]::Escape($name) + '\)')) {
            $line = ($source.Substring(0, $m.Index) -split "`n").Count
            $problems += "line ${line}: @(`$$name) -- `$$name is a List[object]; use .ToArray()"
        }
    }
    return $problems
}

$files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File) +
         @(Get-ChildItem -LiteralPath (Join-Path $root 'WimForge') -Filter '*.ps1' -File -Recurse)

Write-Host 'Every module and front-end file' -ForegroundColor Cyan
$all = @()
foreach ($f in $files) {
    $found = @(Find-WfWrappedList -Path $f.FullName)
    foreach ($p in $found) { $all += "$($f.Name) $p" }
}
Test-Case "no List[object] is wrapped in @()  ($($files.Count) files)" @() $all

Write-Host 'The check can actually fail' -ForegroundColor Cyan
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'wf-list-fixture.ps1'

Set-Content -LiteralPath $tmp -Force -Value @'
$results = New-Object System.Collections.Generic.List[object]
$results.Add(1)
return @($results)
'@
$found = @(Find-WfWrappedList -Path $tmp)
Test-Case 'spots the wrap'  1 $found.Count
Test-Case 'names the line'  $true ([bool]($found[0] -match 'line 3'))

Set-Content -LiteralPath $tmp -Force -Value @'
$results = New-Object System.Collections.Generic.List[object]
$results.Add(1)
return $results.ToArray()
'@
Test-Case 'ToArray is fine' 0 @(Find-WfWrappedList -Path $tmp).Count

# Piping a list is fine -- it is only the array subexpression that breaks.
Set-Content -LiteralPath $tmp -Force -Value @'
$results = New-Object System.Collections.Generic.List[object]
return @($results | Where-Object { $_ })
'@
Test-Case 'piping is fine' 0 @(Find-WfWrappedList -Path $tmp).Count

# And a list of something else is not the broken case.
Set-Content -LiteralPath $tmp -Force -Value @'
$names = New-Object System.Collections.Generic.List[string]
return @($names)
'@
Test-Case 'List[string] is not flagged' 0 @(Find-WfWrappedList -Path $tmp).Count

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
