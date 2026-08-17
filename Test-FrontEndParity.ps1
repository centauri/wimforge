# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
.SYNOPSIS
    Reports where the console menu and the GUI expose different capabilities.

.DESCRIPTION
    The design of this toolkit is one module with two thin front-ends, so anything
    you can do in one you should be able to do in the other. That is easy to say
    and easy to lose: a function gets added to one front-end and not the other,
    and nobody notices until someone asks which one is more capable.

    This compares three things:

      * which exported module functions each front-end calls
      * which module functions neither front-end reaches at all
      * whether the manifest exports anything that does not exist

    Run it after touching either front-end. Exit code 1 means a mismatch, so it
    works as a pre-commit check.

.PARAMETER Detailed
    Also list the module functions no front-end calls. Some of those are fine --
    plumbing meant for scripting rather than for a button -- so this is
    informational, not a failure.

.EXAMPLE
    .\Test-FrontEndParity.ps1
#>
[CmdletBinding()]
param(
    [switch] $Detailed,

    # Downgrade parameter differences to a warning instead of a failure. For the
    # case where one front-end genuinely defaults a value the other prompts for.
    [switch] $AllowParameterDifferences
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'WimForge\WimForge.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Module not found at $modulePath" }

$manifest = Import-PowerShellDataFile $modulePath
$exported = $manifest.FunctionsToExport

function Get-DefinedFunction {
    param([string] $Path)
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
    if ($e) { throw "Parse errors in $Path" }
    return $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Name
}

function Get-CalledModuleFunction {
    param([string] $Path, [string[]] $Exported)
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
    if ($e) { throw "Parse errors in $Path" }
    return @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ -and $_ -in $Exported } |
        Sort-Object -Unique)
}

function Get-CalledParameter {
    <#
        Which named parameters each front-end actually passes, per function.

        This is the check that matters most in practice. Calling the same function
        from both front-ends is not parity: one can call Stop-WfReferenceVm and
        offer -TurnOff while the other does not, and that gap is invisible at the
        function level. It has already happened twice.
    #>
    param([string] $Path, [string[]] $Exported)

    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
    if ($e) { throw "Parse errors in $Path" }

    # Splatted hashtables hide their keys from a naive scan of command elements,
    # which is precisely where a parameter gap can sit unnoticed. So first build a
    # map of every hashtable variable in the file to the keys it is given, both
    # from a literal assignment and from later $p['Key'] = ... additions.
    $splatKeys = @{}

    function Add-SplatKey {
        param($Bag, [string] $Var, [string] $Key)
        if (-not $Var -or -not $Key) { return }
        if (-not $Bag.ContainsKey($Var)) { $Bag[$Var] = New-Object System.Collections.Generic.HashSet[string] }
        [void]$Bag[$Var].Add($Key)
    }

    foreach ($assign in $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {

        # $p = @{ Key = value; ... }
        if ($assign.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $ht = $assign.Right.Find({ param($n)
                $n -is [System.Management.Automation.Language.HashtableAst] }, $false)
            if ($ht) {
                foreach ($pair in $ht.KeyValuePairs) {
                    Add-SplatKey $splatKeys $assign.Left.VariablePath.UserPath $pair.Item1.Extent.Text.Trim("'", '"')
                }
            }
        }

        # $p['Key'] = value
        if ($assign.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and
            $assign.Left.Target -is [System.Management.Automation.Language.VariableExpressionAst]) {
            Add-SplatKey $splatKeys $assign.Left.Target.VariablePath.UserPath $assign.Left.Index.Extent.Text.Trim("'", '"')
        }
    }

    $map     = @{}
    $splatted = New-Object System.Collections.Generic.HashSet[string]

    foreach ($cmd in $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {

        $name = $cmd.GetCommandName()
        if (-not $name -or $name -notin $Exported) { continue }
        if (-not $map.ContainsKey($name)) { $map[$name] = New-Object System.Collections.Generic.HashSet[string] }

        foreach ($el in $cmd.CommandElements) {
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                [void]$map[$name].Add($el.ParameterName)
            }
            elseif ($el -is [System.Management.Automation.Language.VariableExpressionAst] -and $el.Splatted) {
                $var = $el.VariablePath.UserPath
                if ($splatKeys.ContainsKey($var)) {
                    # Keys resolved from the hashtable, so this call can be
                    # compared like any other.
                    foreach ($k in $splatKeys[$var]) { [void]$map[$name].Add($k) }
                }
                else {
                    # Built somewhere this cannot follow. Say so rather than
                    # reporting a difference that may not be one -- a checker that
                    # cries wolf gets ignored.
                    [void]$splatted.Add($name)
                }
            }
        }
    }
    return [pscustomobject]@{ Parameters = $map; Splatted = $splatted }
}

# --- module functions that exist -------------------------------------------
$defined = @()
foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot 'WimForge') -Filter '*.ps1' -Recurse) {
    $defined += Get-DefinedFunction $f.FullName
}

$menuPath = Join-Path $PSScriptRoot 'Start-WimForgeMenu.ps1'
$guiPath  = Join-Path $PSScriptRoot 'Start-WimForgeGui.ps1'

# Infrastructure, not capability. The GUI mirrors the module's log stream into
# its own pane and paints the banner into it line by line; the console writes the
# banner straight out. Different primitives for the same thing, so comparing them
# is noise.
$plumbing = @('Register-WfLogSink', 'Write-WfLog', 'Show-WfBanner', 'Get-WfBannerArt')

# Unfiltered: used for the reachability report, which cares whether a function is
# called at all -- not whether the two front-ends call it symmetrically.
$menuAll = @(Get-CalledModuleFunction -Path $menuPath -Exported $exported)
$guiAll  = @(Get-CalledModuleFunction -Path $guiPath  -Exported $exported)

# Filtered: used for the parity comparison only.
$menuCalls = @($menuAll | Where-Object { $_ -notin $plumbing })
$guiCalls  = @($guiAll  | Where-Object { $_ -notin $plumbing })

# --- manifest sanity --------------------------------------------------------
$phantom = @($exported | Where-Object { $_ -notin $defined })
if ($phantom.Count -gt 0) {
    Write-Host ''
    Write-Host 'Exported but not defined -- Import-Module will fail:' -ForegroundColor Red
    $phantom | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}

# --- parity -----------------------------------------------------------------
$onlyMenu = @($menuCalls | Where-Object { $_ -notin $guiCalls })
$onlyGui  = @($guiCalls  | Where-Object { $_ -notin $menuCalls })

Write-Host ''
Write-Host '  Front-end parity' -ForegroundColor Cyan
Write-Host '  ----------------'
Write-Host ("  console calls : {0} module function(s)" -f $menuCalls.Count)
Write-Host ("  gui calls     : {0} module function(s)" -f $guiCalls.Count)
Write-Host ''

if ($onlyMenu.Count -eq 0 -and $onlyGui.Count -eq 0) {
    Write-Host '  Both front-ends reach the same set.' -ForegroundColor Green
}
else {
    if ($onlyMenu.Count -gt 0) {
        Write-Host '  Console only:' -ForegroundColor Yellow
        $onlyMenu | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    }
    if ($onlyGui.Count -gt 0) {
        Write-Host '  GUI only:' -ForegroundColor Yellow
        $onlyGui | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    }
}

# --- parameter coverage -----------------------------------------------------
# Common-to-both switches that are about HOW a front-end calls, not WHAT it can
# do: -Confirm suppression, and the GUI's habit of naming Title/Body/Arguments.
$ignoredParams = @('Confirm', 'WhatIf', 'ErrorAction', 'Title', 'Body', 'Arguments')

$menuInfo = Get-CalledParameter -Path $menuPath -Exported $exported
$guiInfo  = Get-CalledParameter -Path $guiPath  -Exported $exported
$menuParams = $menuInfo.Parameters
$guiParams  = $guiInfo.Parameters

$paramGaps = New-Object System.Collections.Generic.List[object]
$splatNote = New-Object System.Collections.Generic.List[string]

foreach ($fn in ($menuCalls | Where-Object { $_ -in $guiCalls })) {
    if ($menuInfo.Splatted.Contains($fn) -or $guiInfo.Splatted.Contains($fn)) {
        $splatNote.Add($fn)
        continue
    }
    $m = @()
    $g = @()
    if ($menuParams.ContainsKey($fn)) { $m = @($menuParams[$fn]) }
    if ($guiParams.ContainsKey($fn))  { $g = @($guiParams[$fn]) }
    $m = @($m | Where-Object { $_ -notin $ignoredParams })
    $g = @($g | Where-Object { $_ -notin $ignoredParams })

    $onlyM = @($m | Where-Object { $_ -notin $g })
    $onlyG = @($g | Where-Object { $_ -notin $m })
    if ($onlyM.Count -gt 0 -or $onlyG.Count -gt 0) {
        $paramGaps.Add([pscustomobject]@{
            Function    = $fn
            ConsoleOnly = ($onlyM -join ', ')
            GuiOnly     = ($onlyG -join ', ')
        })
    }
}

Write-Host ''
if ($paramGaps.Count -eq 0) {
    Write-Host '  Parameter coverage matches on every shared function.' -ForegroundColor Green
}
else {
    Write-Host '  Parameter differences on shared functions:' -ForegroundColor Yellow
    Write-Host ''
    foreach ($gap in $paramGaps) {
        Write-Host ("    {0}" -f $gap.Function) -ForegroundColor Yellow
        if ($gap.ConsoleOnly) { Write-Host ("      console only : {0}" -f $gap.ConsoleOnly) }
        if ($gap.GuiOnly)     { Write-Host ("      gui only     : {0}" -f $gap.GuiOnly) }
    }
    Write-Host ''
    Write-Host '  Not always a defect -- one front-end may legitimately default a value.' -ForegroundColor DarkGray
    Write-Host '  But check each one before dismissing it.' -ForegroundColor DarkGray
}

if ($splatNote.Count -gt 0) {
    Write-Host ("  Splatted, so parameters could not be compared: {0}" -f (($splatNote | Sort-Object -Unique) -join ', ')) -ForegroundColor DarkGray
}

# --- reachability -----------------------------------------------------------
$unreached = @($exported | Where-Object { $_ -notin $menuAll -and $_ -notin $guiAll })
Write-Host ''
Write-Host ("  Exported but not reachable from either front-end: {0}" -f $unreached.Count) -ForegroundColor DarkGray
if ($Detailed -and $unreached.Count -gt 0) {
    $unreached | Sort-Object | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  Some of these are deliberate: plumbing meant for scripting and' -ForegroundColor DarkGray
    Write-Host '  scheduled tasks rather than for a button.' -ForegroundColor DarkGray
}

Write-Host ''

# Parameter gaps fail too. They were the whole reason this script exists: calling
# the same function from both front-ends is not parity if one of them cannot
# reach half the options. Letting those exit 0 would make the check worse than
# useless in CI -- it would look green while the gap it was written to catch
# walked straight past.
$failed = ($phantom.Count -gt 0 -or $onlyMenu.Count -gt 0 -or $onlyGui.Count -gt 0)
if ($paramGaps.Count -gt 0 -and -not $AllowParameterDifferences) { $failed = $true }

if ($failed) { exit 1 }
exit 0
