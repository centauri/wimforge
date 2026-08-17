# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Every named parameter at a call site must exist on the function being called.
#
# This exists because a missing one destroyed a user's work.
#
# Dismount-WfImage took -Discard, and committing was the silent default: the only
# correct way to ask for a commit was to say nothing. Four call sites -- every
# commit path in the toolkit, including the GUI's Close button and the end of an
# update injection -- said "-Save", which reads exactly right and is what the
# underlying Dismount-WindowsImage calls it.
#
# PowerShell does not catch that until the line runs. Those lines only run after
# an apply SUCCEEDS, and on Windows 11 24H2 nothing had ever got that far. The
# first time one did -- a Windows 10 cumulative, 46 minutes to apply -- the
# dismount threw on the bad parameter, the catch block around it did exactly what
# it is designed to do, and discarded the mount. Forty-six minutes of correct work
# thrown away at the moment it succeeded.
#
# The worst part is that it was already being reported. Test-FrontEndParity had
# been printing "Dismount-WfImage / gui only: MountPath, Save" for weeks, under a
# heading that says "check each one before dismissing it". I dismissed it, twice,
# as a legitimate difference. Advisory output does not stop anything -- so this
# check fails the build instead.
#
# The AST is used rather than regex: a parameter name is a syntactic thing, and
# matching it by text would produce both misses and false alarms on splatting,
# strings and comments.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

# Anything [CmdletBinding()] accepts without declaring it.
$common = @(
    'Verbose','Debug','ErrorAction','WarningAction','InformationAction','ErrorVariable',
    'WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable',
    'WhatIf','Confirm'
)

function Get-Ast {
    param([string] $Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "$Path does not parse: $($errors[0].Message)" }
    return $ast
}

# ---------------------------------------------------- what every function takes
$sources = @()
$sources += Get-ChildItem -LiteralPath (Join-Path $root 'WimForge') -Filter '*.ps1' -Recurse -File
$fronts   = @('Start-WimForgeGui.ps1', 'Start-WimForgeMenu.ps1') |
                ForEach-Object { Get-Item -LiteralPath (Join-Path $root $_) }

$params = @{}
foreach ($f in ($sources + $fronts)) {
    $ast = Get-Ast $f.FullName
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $names = @()
        if ($fn.Body.ParamBlock) {
            $names = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }
        # Front-ends redefine a few helpers; a name defined twice accepts the
        # union, which is the lenient reading and the right one for a guard.
        if ($params.ContainsKey($fn.Name)) { $params[$fn.Name] = @($params[$fn.Name] + $names | Sort-Object -Unique) }
        else                               { $params[$fn.Name] = $names }
    }
}

Write-Host "Checking calls against $($params.Count) function definition(s)" -ForegroundColor Cyan

# ------------------------------------------------------------ every call site
$problems = New-Object System.Collections.Generic.List[string]

foreach ($f in ($sources + $fronts)) {
    $ast = Get-Ast $f.FullName
    foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        if (-not $name -or -not $params.ContainsKey($name)) { continue }

        $known = @($params[$name]) + $common

        foreach ($el in $cmd.CommandElements) {
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $p = $el.ParameterName
            if (-not $p) { continue }

            # A prefix is how PowerShell actually resolves it, so -Mount for
            # -MountPath is legal and must not be reported.
            $hit = @($known | Where-Object { $_ -eq $p -or $_.StartsWith($p, [StringComparison]::OrdinalIgnoreCase) })
            if ($hit.Count -eq 0) {
                $problems.Add(("{0}:{1}  {2} -{3}  (accepts: {4})" -f `
                    $f.Name, $el.Extent.StartLineNumber, $name, $p, (@($params[$name]) -join ', ')))
            }
        }
    }
}

foreach ($p in $problems) { Write-Host "  $p" -ForegroundColor Red }
Test-Case 'no call passes a parameter its function does not have' 0 $problems.Count

Write-Host 'Committing a mount is stated, not implied' -ForegroundColor Cyan

$svc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw

# The root cause was not the typo. It was that the correct way to ask for an
# irreversible commit was to say NOTHING, so a call that said something looked
# right and failed only once an apply finally reached it.
Test-Case 'Dismount-WfImage takes -Save'    $true ($svc -match '(?s)function Dismount-WfImage.*?\[switch\]\s*\$Save')
Test-Case 'and still takes -Discard'        $true ($svc -match '(?s)function Dismount-WfImage.*?\[switch\]\s*\$Discard')

# Opposite and irreversible outcomes: guessing which was meant is not an option.
Test-Case 'both at once is refused' $true ($svc -match 'if \(\$Discard -and \$Save\)')

# And the commit paths say what they mean.
$commits = @([regex]::Matches($svc, 'Dismount-WfImage[^\r\n]*-Save')).Count
Test-Case 'the module commits explicitly' $true ($commits -ge 2)

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
