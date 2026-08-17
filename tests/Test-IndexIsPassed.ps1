# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Every mount in a front-end must name an index.
#
# This bug shipped twice: the Index box sat on the Servicing tab and the console
# asked for an index in some places, while the code underneath called
# Mount-WfImage with no -Index at all and quietly worked on index 1. On a
# single-index capture that is invisible; on an install.wim it services the wrong
# edition and nobody finds out until the image is deployed.
#
# So it is checked mechanically rather than by remembering.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ','); $a = ($Actual -join ',')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]  got [$a]" -ForegroundColor Red; $script:Fail++ }
}

function Get-CommandCall {
    param([string] $Path, [string] $Name)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw "$Path does not parse" }

    return @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq $Name
    }, $true))
}

function Test-NamesIndex {
    <#
        True when the call names -Index, or splats a hashtable that has an Index
        key. The splat case is checked by looking at the whole enclosing
        function, which is where the hashtable is built.
    #>
    param($Call, [string] $Source)

    foreach ($el in $Call.CommandElements) {
        if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
            $el.ParameterName -like 'Index*') { return $true }
    }

    # A splatted call: @p or @params. Look for an Index key nearby.
    $text = $Call.Extent.Text
    if ($text -match '@\w+') {
        $start = [Math]::Max(0, $Call.Extent.StartOffset - 1200)
        $len   = $Call.Extent.StartOffset - $start
        $before = $Source.Substring($start, $len)
        # Not anchored to the line start: hashtables here are often written
        # several pairs to a line. The lookbehind stops SkipIndex or MaxIndex
        # from counting as a match.
        if ($before -match '(?<![A-Za-z])Index\s*=') { return $true }
    }

    return $false
}

foreach ($file in @('Start-WimForgeMenu.ps1', 'Start-WimForgeGui.ps1')) {
    $path   = Join-Path $root $file
    $source = Get-Content -LiteralPath $path -Raw

    Write-Host $file -ForegroundColor Cyan

    foreach ($command in @('Mount-WfImage', 'Invoke-WfWithMount', 'Invoke-WfServicingRun', 'Invoke-WfUpdateInject')) {
        $calls = @(Get-CommandCall -Path $path -Name $command)
        if ($calls.Count -eq 0) { continue }

        $bad = @()
        foreach ($c in $calls) {
            if (-not (Test-NamesIndex -Call $c -Source $source)) {
                $bad += "line $($c.Extent.StartLineNumber)"
            }
        }
        Test-Case "$command names an index in all $($calls.Count) call(s)" @() $bad
    }
}

# And the checker itself has to be able to fail, or it proves nothing.
Write-Host 'The check can actually fail' -ForegroundColor Cyan
$temp = Join-Path ([IO.Path]::GetTempPath()) 'wf-index-check-fixture.ps1'
Set-Content -LiteralPath $temp -Value 'Mount-WfImage -ImagePath $src | Out-Null' -Force
$fixture = @(Get-CommandCall -Path $temp -Name 'Mount-WfImage')
Test-Case 'spots a missing -Index' $false (Test-NamesIndex -Call $fixture[0] -Source (Get-Content -LiteralPath $temp -Raw))

Set-Content -LiteralPath $temp -Value 'Mount-WfImage -ImagePath $src -Index $idx | Out-Null' -Force
$fixture2 = @(Get-CommandCall -Path $temp -Name 'Mount-WfImage')
Test-Case 'accepts a named -Index' $true (Test-NamesIndex -Call $fixture2[0] -Source (Get-Content -LiteralPath $temp -Raw))

Set-Content -LiteralPath $temp -Value @'
$p = @{
    SourceImage = $src
    Index       = $idx
}
Invoke-WfServicingRun @p
'@ -Force
$fixture3 = @(Get-CommandCall -Path $temp -Name 'Invoke-WfServicingRun')
Test-Case 'accepts a splatted Index' $true (Test-NamesIndex -Call $fixture3[0] -Source (Get-Content -LiteralPath $temp -Raw))

Set-Content -LiteralPath $temp -Value @'
$p = @{
    SourceImage = $src
}
Invoke-WfServicingRun @p
'@ -Force
$fixture4 = @(Get-CommandCall -Path $temp -Name 'Invoke-WfServicingRun')
Test-Case 'spots a splat without Index' $false (Test-NamesIndex -Call $fixture4[0] -Source (Get-Content -LiteralPath $temp -Raw))

Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
