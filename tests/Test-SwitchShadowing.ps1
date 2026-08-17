# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# A function must never assign to its own [switch] parameter.
#
# This shipped, and it cost an entire afternoon of chasing the wrong thing.
#
# Add-WfTextBox already had a local called $pickFolder holding the folder its
# image picker should open in. A [switch] $PickFolder parameter was added beside
# it. PowerShell variable names are CASE-INSENSITIVE, so those are one variable,
# and the existing line
#
#     $pickFolder = $script:Config['ImageRoot']
#
# then tried to put a path into a SwitchParameter:
#
#     Cannot convert the "C:\Imaging\Images" value of type "System.String"
#     to type "System.Management.Automation.SwitchParameter".
#
# Two things made that expensive. It is thrown while the window is being built,
# so the GUI never opens at all -- it looks like the application is broken
# rather than one control. And the message names a type and a value, with the
# value being a path out of the configuration, which reads exactly like a
# command-line argument being mis-bound. Three fixes went into the launcher on
# that reading before anyone looked at the line number.
#
# Nothing behavioural can catch this: it needs the GUI to actually run. The
# syntax tree can, in milliseconds.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

function Get-WfSwitchShadowing {
    <#
        Every function in a file, and every assignment inside it whose target is
        one of that function's own switch parameters.

        Assignments to $script:X and $global:X are ignored -- those name a
        different variable. A `$sw = $true` is ignored too: assigning a boolean
        to a switch is legal and occasionally deliberate (the front-ends do it
        when reading elevation out of the environment). What this looks for is a
        value that CANNOT be a switch.
    #>
    param([string] $Path)

    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)

    $problems = @()

    $functions = @($ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true))

    foreach ($fn in $functions) {
        if (-not $fn.Body -or -not $fn.Body.ParamBlock) { continue }

        $switches = @()
        foreach ($p in $fn.Body.ParamBlock.Parameters) {
            # StaticType renders as 'switch', not 'SwitchParameter' -- the first
            # version of this matched only the long name, found nothing anywhere,
            # and reported all 24 files clean. Which is why the sample below
            # exists: a guard that cannot fail is a comment that takes longer to
            # run.
            $type = ''
            if ($p.StaticType) { $type = "$($p.StaticType)" }
            $attr = @($p.Attributes | ForEach-Object { "$($_.TypeName)" }) -join ','
            if ($type -match '^(switch|System\.Management\.Automation\.SwitchParameter)$' -or
                $attr -match '(^|,)(switch|System\.Management\.Automation\.SwitchParameter)(,|$)') {
                $switches += $p.Name.VariablePath.UserPath
            }
        }
        if ($switches.Count -eq 0) { continue }

        $assignments = @($fn.Body.FindAll({
            param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]
        }, $true))

        foreach ($a in $assignments) {
            if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }

            $target = $a.Left.VariablePath
            if ($target.IsScript -or $target.IsGlobal) { continue }

            $name = $target.UserPath
            $hit  = @($switches | Where-Object { $_ -eq $name })   # -eq is case-insensitive, which is the whole point
            if ($hit.Count -eq 0) { continue }

            # A BOOLEAN is legal: [switch]$x = $true is ordinary, and
            # New-WfReferenceVm does $CompatibleCpu = [bool]$cfg[...] on purpose
            # to apply a configured default when the switch was not passed. What
            # is not legal is a value that can never be one -- a path, a name, a
            # number out of a config file.
            $right = "$($a.Right)".Trim()
            if ($right -match '^\$(true|false)$')   { continue }
            if ($right -match '^\[bool\]')          { continue }
            if ($right -match '^\$PSBoundParameters') { continue }

            $problems += ('{0}: {1} assigns to its own [switch] ${2} at line {3} -- {4}' -f `
                (Split-Path $Path -Leaf), $fn.Name, $name, $a.Extent.StartLineNumber, $right)
        }
    }

    return $problems
}

Write-Host 'No function assigns a value to its own switch parameter' -ForegroundColor Cyan

$files = @(
    (Join-Path $root 'Start-WimForgeGui.ps1'),
    (Join-Path $root 'Start-WimForgeMenu.ps1'),
    (Join-Path $root 'Add-DriversToWim.ps1'),
    (Join-Path $root 'Export-ModelDrivers.ps1')
) + @(Get-ChildItem -LiteralPath (Join-Path $root 'WimForge') -Filter '*.ps1' -Recurse |
      ForEach-Object { $_.FullName })

$all = @()
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $all += @(Get-WfSwitchShadowing -Path $f)
}

Test-Case "checked $($files.Count) file(s)" @() $all

# And the check itself is exercised, because a guard that cannot fail is not a
# guard -- it is a comment that takes longer to run.
Write-Host 'The check would have caught the real one' -ForegroundColor Cyan

$sample = Join-Path ([IO.Path]::GetTempPath()) ('wf-shadow-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.ps1')
@'
function Add-Thing {
    param([string] $Label, [switch] $PickFolder)
    $pickFolder = 'C:\Imaging\Images'
    return $pickFolder
}
function Fine-Thing {
    param([switch] $Elevate)
    $Elevate = $true
    $other   = 'C:\somewhere'
    return $other
}
'@ | Set-Content -LiteralPath $sample -Encoding UTF8

$found = @(Get-WfSwitchShadowing -Path $sample)
Test-Case 'the collision is found'        1     $found.Count
Test-Case 'and named with its line'       $true ($found[0] -match 'Add-Thing assigns to its own \[switch\] \$pickFolder at line 3')
Test-Case 'a $true assignment is allowed' 0 @($found | Where-Object { $_ -match 'Fine-Thing' }).Count

Remove-Item -LiteralPath $sample -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
