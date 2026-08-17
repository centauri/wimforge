# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Nothing at script level may be used before it is created.
#
# Both front-ends are long scripts that run top to bottom, and a variable used
# thirty lines above where it is assigned is $null at that point. If the use is
# a method call -- $script:Something.Add(...) -- the script dies on load with
# "You cannot call a method on a null-valued expression" and no window ever
# appears. That happened when a control was moved above the list it registers
# itself into, so it is checked mechanically now.
#
# Only script level is examined. Inside a function, order does not matter --
# the function does not run until it is called.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

function Find-WfUseBeforeAssign {
    <#
        Returns a description of every script-level member access on a variable
        whose first script-level assignment comes later in the file.

        Member access specifically, not any reference: reading a $null variable
        is often harmless and sometimes deliberate, but calling a method on one
        is always a crash.
    #>
    param([string] $Path)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw "$Path does not parse" }

    # Everything inside a function or a scriptblock runs later, so only
    # statements at the top level of the file are in scope here.
    $inDeferred = {
        param($node)
        $p = $node.Parent
        while ($p) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                $p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $true }
            $p = $p.Parent
        }
        return $false
    }

    $key = { param($v) "$($v.VariablePath.UserPath)".ToLower() -replace '^script:', '' }

    # First top-level assignment of each variable.
    $assignedAt = @{}
    foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if (& $inDeferred $a) { continue }
        $left = $a.Left
        if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }

        $k = & $key $left
        if (-not $assignedAt.ContainsKey($k) -or $a.Extent.StartOffset -lt $assignedAt[$k]) {
            $assignedAt[$k] = $a.Extent.StartOffset
        }
    }

    $problems = @()
    foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if (& $inDeferred $m) { continue }
        if ($m.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }

        $k = & $key $m.Expression
        if (-not $assignedAt.ContainsKey($k)) { continue }          # never assigned here; not ours to judge
        if ($m.Extent.StartOffset -lt $assignedAt[$k]) {
            $line   = $m.Extent.StartLineNumber
            $member = $m.Member.Value
            $problems += "line ${line}: `$$k.$member() called before `$$k is assigned"
        }
    }
    # Plain return, and every caller wraps in @(). The comma trick would work
    # too, but not BOTH: a returned-as-one-object array wrapped in @() becomes a
    # one-element array containing an array. One convention, applied at the call
    # sites, is the one this project already uses.
    return $problems
}

foreach ($file in @('Start-WimForgeMenu.ps1', 'Start-WimForgeGui.ps1')) {
    Write-Host $file -ForegroundColor Cyan
    Test-Case 'nothing used before it exists' @() @(Find-WfUseBeforeAssign -Path (Join-Path $root $file))
}

Write-Host 'The check can actually fail' -ForegroundColor Cyan
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'wf-order-fixture.ps1'

# Exactly the shape of the bug: the list is created below where it is used.
Set-Content -LiteralPath $tmp -Force -Value @'
$button = 'x'
$script:Buttons.Add($button)
$script:Buttons = New-Object System.Collections.Generic.List[object]
'@
$found = @(Find-WfUseBeforeAssign -Path $tmp)
Test-Case 'spots the bug' 1 $found.Count
Test-Case 'names the line' $true ([bool]($found[0] -match 'line 2'))

Set-Content -LiteralPath $tmp -Force -Value @'
$script:Buttons = New-Object System.Collections.Generic.List[object]
$script:Buttons.Add('x')
'@
Test-Case 'right way round is fine' 0 @(Find-WfUseBeforeAssign -Path $tmp).Count

# Inside a function the order does not matter, because it runs later.
Set-Content -LiteralPath $tmp -Force -Value @'
function Add-One { $script:Buttons.Add('x') }
$script:Buttons = New-Object System.Collections.Generic.List[object]
Add-One
'@
Test-Case 'a function body is not judged' 0 @(Find-WfUseBeforeAssign -Path $tmp).Count

# Nor is a scriptblock: an event handler runs when the event fires.
Set-Content -LiteralPath $tmp -Force -Value @'
$handler = { $script:Buttons.Add('x') }
$script:Buttons = New-Object System.Collections.Generic.List[object]
'@
Test-Case 'a scriptblock is not judged' 0 @(Find-WfUseBeforeAssign -Path $tmp).Count

# $script: and the bare name are the same variable at script level.
Set-Content -LiteralPath $tmp -Force -Value @'
$script:Thing.Add('x')
$Thing = New-Object System.Collections.Generic.List[object]
'@
Test-Case 'scope prefix does not hide it' 1 @(Find-WfUseBeforeAssign -Path $tmp).Count

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
