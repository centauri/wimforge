# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The GUI timer must not do expensive or repainting work on every tick.
#
# Written after the window was reported as unstable: the cursor flickered, the
# Close button flickered, and clicks on menus went missing. All three came out of
# one handler that runs four times a second for the life of the window, and each
# had its own mechanism:
#
#   Get-WindowsImage -Mounted -- a DISM call -- was made on the UI thread on
#   every tick. While it runs the window is not pumping messages, so a click
#   that lands during it is simply lost. Four a second, forever, whether or not
#   anything had changed.
#
#   $form.Cursor was assigned on every tick. Control.Cursor is not guarded the
#   way most WinForms setters are: it forces a WM_SETCURSOR whether or not the
#   value changed, so the I-beam over a text box was pushed back to an arrow
#   four times a second.
#
#   Every action button had its Enabled rewritten on every tick, and
#   Update-WfMountLabel then disagreed about two of them. Close was therefore
#   set true and then false within the same tick -- a real state change each
#   time, and Enabled changing raises OnEnabledChanged and invalidates. Eight
#   repaints a second on one button.
#
# None of that shows up in a parse, a parity check or a layout check, and none of
# it fails anything. It just makes the window feel broken. So the shape of the
# handler is checked mechanically instead.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

$guiPath = Join-Path $root 'Start-WimForgeGui.ps1'
$src     = Get-Content -LiteralPath $guiPath -Raw

$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$null, [ref]$errors)
Test-Case 'the GUI parses' '' (@($errors | ForEach-Object { $_.Message }) -join '; ')

# ---------------------------------------------------------------- the handler
#
# Found by AST rather than by text: the tick body is the scriptblock argument to
# Add_Tick, and reading it any other way would mean guessing where it ends.
$tick = $null
foreach ($inv in $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {

    if ("$($inv.Member)" -ne 'Add_Tick') { continue }
    foreach ($arg in @($inv.Arguments)) {
        if ($arg -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $tick = $arg }
    }
}

Test-Case 'the timer tick handler is found' 'True' ($null -ne $tick).ToString()
$tickText = ''
if ($tick) { $tickText = $tick.Extent.Text }

Write-Host ''
Write-Host 'Nothing expensive on every tick' -ForegroundColor Cyan

# The interval is what makes all of this matter. If it is ever lengthened to
# something lazy this test still holds; if it is shortened, it matters more.
$interval = 0
$m = [regex]::Match($src, '(?m)^\s*\$timer\.Interval\s*=\s*(\d+)')
if ($m.Success) { $interval = [int]$m.Groups[1].Value }
Test-Case 'the tick interval is known' 'True' ($interval -gt 0).ToString()
Write-Host ("       (it fires every {0}ms -- {1} times a second)" -f $interval, [math]::Round(1000 / [math]::Max($interval, 1), 1)) -ForegroundColor DarkGray

# Get-WfCurrentMount is Get-WindowsImage -Mounted. It must not be reachable from
# the tick without a guard in front of it.
Test-Case 'the mount table is not read directly in the tick' 'False' `
    ($tickText -match 'Get-WfCurrentMount').ToString()

# Update-WfMountLabel is the thing that reads it, and it may be called -- but
# only behind a due-time check, never unconditionally.
$mountCalls = @([regex]::Matches($tickText, 'Update-WfMountLabel'))
Test-Case 'Update-WfMountLabel is called at most once from the tick' 'True' `
    ($mountCalls.Count -le 1).ToString()

Test-Case 'and only when it is due' 'True' `
    ($tickText -match 'MountCheckAt\s*\)\s*\{\s*Update-WfMountLabel').ToString()

# A schedule that is never pushed forward is not a schedule.
Test-Case 'the due time is moved on after a read' 'True' `
    ($src -match '\$script:MountCheckAt\s*=\s*\(Get-Date\)\.AddSeconds').ToString()

Write-Host ''
Write-Host 'Nothing that repaints on every tick' -ForegroundColor Cyan

# Control.Cursor forces WM_SETCURSOR whether or not the value changed, so it is
# the one property that genuinely must not be written on a schedule.
$cursorSets = @([regex]::Matches($tickText, '\$form\.Cursor\s*='))
Test-Case 'the form cursor is set only on a change of state' 'True' `
    (($cursorSets.Count -eq 0) -or ($tickText -match 'LastRunning')).ToString()

# The blanket enable/disable of every action button is the other half of the
# Close button flicker. It is allowed, but only inside a transition guard.
foreach ($guard in @('\$script:LastRunning -ne \$true', '\$script:LastRunning -ne \$false')) {
    Test-Case ("the button sweep is guarded by  {0}" -f ($guard -replace '\\', '')) 'True' `
        ($tickText -match $guard).ToString()
}

# Every sweep over ActionButtons in the tick has to sit inside one of those
# guards. Counted rather than eyeballed: a third sweep added later outside a
# guard would put the flicker straight back.
$sweeps = @([regex]::Matches($tickText, 'foreach \(\$b in \$script:ActionButtons\)'))
$guards = @([regex]::Matches($tickText, '\$script:LastRunning -ne \$(true|false)'))
Test-Case 'every button sweep has a guard' 'True' `
    (($sweeps.Count -gt 0) -and ($sweeps.Count -le $guards.Count)).ToString()

# The transition flag starts as $null, not $false. $false would mean the idle
# branch never runs on the first tick, and the buttons would keep whatever state
# they were built with.
Test-Case 'the transition flag starts unknown, not false' 'True' `
    ($src -match '\$script:LastRunning\s*=\s*\$null').ToString()

Write-Host ''
Write-Host 'The log pane scrolls once, not once per line' -ForegroundColor Cyan

# A servicing run hands over hundreds of lines in one tick. ScrollToCaret
# repaints and re-scrolls the whole control, so per line it is hundreds of
# repaints for one visible result -- which is what made the window fight back
# while a job was running.
Test-Case 'the drain does not scroll per line' 'True' `
    ($tickText -match 'Write-WfGuiLog \$line \$color -NoScroll').ToString()
Test-Case 'and scrolls once when it drained something' 'True' `
    ($tickText -match '\$drained -gt 0\s*\)\s*\{\s*\$logBox\.ScrollToCaret').ToString()

# The switch has to exist and default to the old behaviour, or every other
# caller silently stops scrolling.
$logFn = ($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Write-WfGuiLog' }, $true))[0]
Test-Case 'Write-WfGuiLog takes -NoScroll' 'True' `
    (@($logFn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -contains 'NoScroll').ToString()
Test-Case 'and still scrolls by default' 'True' `
    ($logFn.Extent.Text -match 'if \(-not \$NoScroll\) \{ \$logBox\.ScrollToCaret').ToString()

Write-Host ''
Write-Host 'The mount label writes only what changed' -ForegroundColor Cyan

$mountFn = ($ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Update-WfMountLabel' }, $true))[0]
$mountText = $mountFn.Extent.Text

Test-Case 'it compares against what is already on screen' 'True' `
    ($mountText -match '\$signature -eq \$script:MountSignature').ToString()
Test-Case 'and returns early when nothing differs' 'True' `
    ($mountText -match 'MountSignature\s*\)\s*\{\s*return').ToString()

# -Force exists so the caller that has just changed the mount can insist, rather
# than being told nothing changed by a stale signature.
Test-Case 'and -Force can override the comparison' 'True' `
    (@($mountFn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -contains 'Force').ToString()

# The controls must be touched in one place, after the decision -- not scattered
# through the branches, which is how the two halves came to disagree.
$closeWrites = @([regex]::Matches($mountText, '\$wfCloseBtn\.Enabled\s*='))
Test-Case 'the Close button is written in exactly one place' 1 $closeWrites.Count
$openWrites = @([regex]::Matches($mountText, '\$wfMountBtn\.Enabled\s*='))
Test-Case 'and so is Open' 1 $openWrites.Count

# $script:MountOpen is read by other parts of the window to decide whether an
# operation will take seconds or minutes, so it has to be set even on the ticks
# where nothing is repainted.
$sigAt  = $mountText.IndexOf('$signature =')
$openAt = $mountText.IndexOf('$script:MountOpen = $mount')
Test-Case 'the cached mount is set before the early return' 'True' `
    (($openAt -ge 0) -and ($openAt -lt $sigAt)).ToString()

Write-Host ''
Write-Host 'The refresh hook' -ForegroundColor Cyan

Test-Case 'Request-WfMountRefresh exists' 'True' `
    (@($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name }) -contains 'Request-WfMountRefresh').ToString()

# The blanket enable turns Open and Close on regardless of the mount, so the
# mount state has to get the last word in the same tick -- otherwise there is a
# visible window where Close is wrongly enabled.
Test-Case 'the idle transition asks for a mount refresh' 'True' `
    ($tickText -match 'LastRunning -ne \$false[\s\S]{0,900}Request-WfMountRefresh').ToString()

Write-Host ''
if ($script:Fail -gt 0) {
    Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'All GUI timer checks passed.' -ForegroundColor Green
