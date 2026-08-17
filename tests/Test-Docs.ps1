# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Everything the documentation names has to exist.
#
# Written because the runbook confidently showed two commands that were wrong --
# `Invoke-WfServicingRun -ImagePath` (the parameter is -SourceImage) and
# `Add-WfBootDriver -ImagePath` (it is -BootImagePath) -- and one set of switches
# with the polarity backwards. None of that fails anything. It sits in a document
# that reads as authoritative until somebody types it, at which point they are
# debugging the documentation instead of their image.
#
# Function names, parameter names and button labels are all checkable against the
# thing they describe, so they are checked rather than proof-read.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

# Discovered rather than listed. The documentation was one README until it was
# split into docs/, and a hardcoded list is exactly how a page moves out of
# scope without anyone noticing -- which would leave the newest documentation as
# the only documentation nobody checks.
$docs = @(
    @('WIM-Build-Runbook.md', 'README.md', 'CHANGELOG.md') +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'docs') -Filter '*.md' -File -ErrorAction SilentlyContinue |
        ForEach-Object { "docs/$($_.Name)" })
) | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) }

# Said out loud so a run that silently checked two files instead of six is
# visible in the output rather than only in the pass count.
Write-Host ("  documents checked: {0}" -f ($docs -join ', ')) -ForegroundColor DarkGray

# --- what actually exists ---------------------------------------------------
$defined = @{}
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'WimForge') -Filter '*.ps1' -File -Recurse)) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
    foreach ($fn in $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {

        $params = New-Object System.Collections.Generic.List[string]
        $block = $fn.Body.ParamBlock
        if ($block) {
            foreach ($p in $block.Parameters) { $params.Add($p.Name.VariablePath.UserPath) }
        }
        # Common parameters are real and are never declared.
        foreach ($c in @('Verbose','Debug','Confirm','WhatIf','ErrorAction','WarningAction',
                         'InformationAction','ErrorVariable','WarningVariable','OutVariable','OutBuffer')) {
            $params.Add($c)
        }
        $defined[$fn.Name] = $params
    }
}

# The front-ends define functions of their own -- Start-WfJob is one -- and the
# documentation is entitled to name them.
foreach ($f in @('Start-WimForgeGui.ps1', 'Start-WimForgeMenu.ps1')) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $f), [ref]$t, [ref]$e)
    foreach ($fn in $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($defined.ContainsKey($fn.Name)) { continue }
        $params = New-Object System.Collections.Generic.List[string]
        if ($fn.Body.ParamBlock) {
            foreach ($p in $fn.Body.ParamBlock.Parameters) { $params.Add($p.Name.VariablePath.UserPath) }
        }
        $defined[$fn.Name] = $params
    }
}

$buttons = @{}
$guiText = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeGui.ps1') -Raw
foreach ($m in [regex]::Matches($guiText, "Add-WfButton\s+\`$\w+\s+'((?:[^']|'')*)'")) {
    $buttons[($m.Groups[1].Value -replace "''", "'")] = $true
}

$menuLabels = @{}
$menuText = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeMenu.ps1') -Raw
foreach ($m in [regex]::Matches($menuText, "Label\s*=\s*'((?:[^']|'')*)'")) {
    $menuLabels[($m.Groups[1].Value -replace "''", "'")] = $true
}

# --- 1. every Wf function named in the docs exists ---------------------------
Write-Host 'Functions the documentation names' -ForegroundColor Cyan

foreach ($doc in $docs) {
    $text = Get-Content -LiteralPath (Join-Path $root $doc) -Raw

    $named = @([regex]::Matches($text, '\b((?:Get|Set|New|Add|Remove|Test|Invoke|Export|Import|Mount|Dismount|Repair|Publish|Save|Copy|Start|Stop|Restore|Initialize|Enable|Disable|Write|Read|Compare|Select|Find|Format|Register|ConvertFrom|ConvertTo)-Wf\w+)') |
              ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    $missing = @($named | Where-Object { -not $defined.ContainsKey($_) })
    Test-Case "$doc names only functions that exist ($($named.Count) named)" @() $missing
}

# --- 2. every parameter shown against one of them is real --------------------
Write-Host 'Parameters shown in the examples' -ForegroundColor Cyan

foreach ($doc in $docs) {
    $text  = Get-Content -LiteralPath (Join-Path $root $doc)
    $bad   = @()
    $fn    = $null

    foreach ($line in $text) {
        # A line that names a Wf function starts a call; continuation lines with
        # a leading backtick belong to it. Anything else ends it.
        $call = [regex]::Match($line, '\b((?:[A-Z]\w+)-Wf\w+)\b')
        if ($call.Success -and $defined.ContainsKey($call.Groups[1].Value)) {
            $fn = $call.Groups[1].Value
        }
        elseif ($line -notmatch '^\s+-' -and $line -notmatch '^\s*$') {
            if ($line -notmatch '`\s*$') { $fn = $null }
        }
        if (-not $fn) { continue }

        foreach ($p in [regex]::Matches($line, '(?<![\w`])-([A-Z]\w+)')) {
            $name = $p.Groups[1].Value
            if ($defined[$fn] -notcontains $name) {
                $bad += "$fn has no -$name"
            }
        }

        if ($line -notmatch '`\s*$') { $fn = $null }
    }

    Test-Case "$doc shows only real parameters" @() @($bad | Sort-Object -Unique)
}

# --- 3. every button and menu item the docs point at exists ------------------
Write-Host 'Buttons and menu items the documentation points at' -ForegroundColor Cyan

foreach ($doc in $docs) {
    $text = Get-Content -LiteralPath (Join-Path $root $doc) -Raw

    # Fenced code is examples, and a comment inside one -- '# Servicing tab ->
    # Run servicing, or:' -- is not a reference to check. Stripped first.
    $text = [regex]::Replace($text, '(?s)```.*?```', '')

    # Two forms, and no third. A looser pattern reads flowing prose as a button
    # name -- 'Housekeeping -> Environment check reports which DISM is on PATH'
    # becomes a demand for a button called 'Environment check reports which DISM
    # is o' -- so a reference only counts when it is unambiguously marked as one:
    #
    #   emphasised   -> **Run servicing**  or  -> *Run servicing*
    #   in a table   | ... -> Environment check |
    #
    # Which also makes the documentation better: a UI element that is visually
    # distinct from the sentence around it is easier to follow anyway.
    $named = New-Object System.Collections.Generic.List[string]

    # Emphasised references first, and the emphasis may sit either side of the
    # arrow -- '-> **Run servicing**' and '**Housekeeping -> Repair stale
    # mounts**' are both used. Newlines are allowed inside, because a reference
    # near the right margin wraps and 'Repair\nstale mounts' is one name.
    $emphasised = @(
        # -> **Run servicing**
        '(?:->|→|(?<=\s)>)\s*\*{1,2}([A-Z][^*]{2,40}?)\*{1,2}'
        # **Housekeeping -> Repair stale mounts**
        '\*{1,2}[^*]{0,80}?(?:->|→|>)\s*([A-Z][^*]{2,40}?)\*{1,2}'
    )
    foreach ($pattern in $emphasised) {
        foreach ($m in [regex]::Matches($text, $pattern)) {
            $named.Add(($m.Groups[1].Value -replace '\s+', ' ').Trim())
        }
    }

    # Then the plain ones, on what is left once the emphasised spans are out of
    # the way -- otherwise a wrapped reference is read a second time as the half
    # of itself that happens to end at the line break.
    $plain = [regex]::Replace($text, '\*{1,2}[^*]{0,120}?\*{1,2}', ' ')
    foreach ($m in [regex]::Matches($plain, '(?:->|→|(?<=\s)>)\s*([A-Z][^*\n\r|,.;]{2,40}?)\s*(?=\||\r|\n|,|\.|;|$)')) {
        $named.Add($m.Groups[1].Value.Trim())
    }

    $named = @($named | Where-Object { $_ } | Sort-Object -Unique)

    $missing = @($named | Where-Object {
        -not $buttons.ContainsKey($_) -and -not $menuLabels.ContainsKey($_)
    })

    Test-Case "$doc points only at things that exist ($($named.Count) named)" @() $missing
}

# --- 4. the check can actually fail ------------------------------------------
Write-Host 'The check can actually fail' -ForegroundColor Cyan

$tmp = Join-Path ([IO.Path]::GetTempPath()) 'wf-doc-fixture.md'

Set-Content -LiteralPath $tmp -Force -Value 'Run `Get-WfNotARealFunction` to do the thing.'
$named = @([regex]::Matches((Get-Content -LiteralPath $tmp -Raw), '\b((?:Get|Set)-Wf\w+)') |
          ForEach-Object { $_.Groups[1].Value })
Test-Case 'spots an invented function' $true (@($named | Where-Object { -not $defined.ContainsKey($_) }).Count -eq 1)

# The real defect this was written for: a function that exists, with a parameter
# that does not.
Test-Case 'Invoke-WfServicingRun really has no -ImagePath' $false ($defined['Invoke-WfServicingRun'] -contains 'ImagePath')
Test-Case 'it is -SourceImage'                             $true  ($defined['Invoke-WfServicingRun'] -contains 'SourceImage')
Test-Case 'Add-WfBootDriver really has no -ImagePath'      $false ($defined['Add-WfBootDriver'] -contains 'ImagePath')
Test-Case 'it is -BootImagePath'                           $true  ($defined['Add-WfBootDriver'] -contains 'BootImagePath')

# A button that does not exist, in each of the three forms the docs use. Without
# this the button check could pass by matching nothing at all.
Set-Content -LiteralPath $tmp -Force -Value @'
Housekeeping -> **Nonexistent button**
**Servicing -> Also not a button**

| Step | Where |
|---|---|
| 1 | Updates -> Definitely not a button |
'@
$fixture = Get-Content -LiteralPath $tmp -Raw
$found = New-Object System.Collections.Generic.List[string]
foreach ($pattern in @(
    '(?:->|→|(?<=\s)>)\s*\*{1,2}([A-Z][^*]{2,40}?)\*{1,2}',
    '\*{1,2}[^*]{0,80}?(?:->|→|>)\s*([A-Z][^*]{2,40}?)\*{1,2}')) {
    foreach ($m in [regex]::Matches($fixture, $pattern)) { $found.Add(($m.Groups[1].Value -replace '\s+',' ').Trim()) }
}
$plain = [regex]::Replace($fixture, '\*{1,2}[^*]{0,120}?\*{1,2}', ' ')
foreach ($m in [regex]::Matches($plain, '(?:->|→|(?<=\s)>)\s*([A-Z][^*\n\r|,.;]{2,40}?)\s*(?=\||\r|\n|,|\.|;|$)')) {
    $found.Add($m.Groups[1].Value.Trim())
}
Test-Case 'all three reference forms are found' `
    @('Also not a button', 'Definitely not a button', 'Nonexistent button') `
    @($found | Sort-Object -Unique)
Test-Case 'and none of them exists' 3 `
    @($found | Sort-Object -Unique | Where-Object { -not $buttons.ContainsKey($_) -and -not $menuLabels.ContainsKey($_) }).Count

# And that the button index is not silently empty, which would make check 3 pass
# by finding nothing rather than by everything being right.
Test-Case 'the button index is populated' $true ($buttons.Count -gt 30)
Test-Case 'the menu index is populated'   $true ($menuLabels.Count -gt 30)

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Release readiness' -ForegroundColor Cyan

# The release workflow refuses to publish when the tag, the manifest and the
# CHANGELOG disagree. That is the right place for the gate, but the wrong place
# to find out: by then the tag exists and has to be deleted and re-pushed. So the
# same agreement is checked here, where it costs a second.
$manifestVersion = (Import-PowerShellDataFile (Join-Path $root 'WimForge\WimForge.psd1')).ModuleVersion
$changelogText   = Get-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') -Raw

Test-Case 'the CHANGELOG has a section for the manifest version' $true `
    ($changelogText -match [regex]::Escape("## [$manifestVersion]"))

# Every released version needs its link definition at the foot of the file, or
# the heading renders as literal brackets on GitHub.
$versionHeadings = @([regex]::Matches($changelogText, '(?m)^##\s+\[([^\]]+)\]') |
                     ForEach-Object { $_.Groups[1].Value } |
                     Where-Object { $_ -ne 'Unreleased' })
$noLink = @($versionHeadings | Where-Object {
    $changelogText -notmatch ('(?m)^\[' + [regex]::Escape($_) + '\]:\s*http') })
Test-Case 'every released version has its link definition' '' ($noLink -join ', ')

# The workflow builds WimForge-<version>.zip from the manifest version. If the
# name in the documentation drifts from that, a link in somebody's runbook 404s.
$readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw
if ($readme -match 'WimForge-(\d+\.\d+\.\d+)\.zip') {
    Test-Case 'the archive name in the README matches the manifest' $manifestVersion $Matches[1]
}
else {
    Write-Host '  --   the README does not name a release archive, so nothing to compare' -ForegroundColor DarkGray
}

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
