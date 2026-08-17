# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Controls on a hand-built panel must fit inside it, and the panel must know how
# wide it is before they are added.
#
# WinForms anchoring is the reason. An anchored control records its distance from
# the container's edge at the moment it is added. Add a right-anchored button at
# x=868 to a panel that is still its default 200px wide, and that distance is
# recorded as -730; when the panel grows to its real width the button dutifully
# moves to x=1662 -- off screen, unclickable, and invisible. There is no error,
# no warning, and nothing in the log. The controls are simply not there.
#
# That shipped once. It cannot be caught by parsing or by running the module, so
# it is checked arithmetically instead.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

function Test-WfPanelLayout {
    <#
        For every panel built by hand in a script: check that its size is set
        before children are added, and that no child extends past it.

        Only panels assembled with explicit Location and Size are examined --
        which is the pattern that can go wrong. Tab pages are built through
        Add-WfTextBox and friends against an already-sized page, so they are not
        in scope here.
    #>
    param([string] $Path)

    $source   = Get-Content -LiteralPath $Path -Raw
    $problems = @()

    foreach ($panel in [regex]::Matches($source, '\$(\w+)\s*=\s*New-Object System\.Windows\.Forms\.Panel')) {
        $name  = $panel.Groups[1].Value
        $start = $panel.Index

        # The block runs until the panel is handed to its parent, or to the end.
        $endMatch = [regex]::Match($source.Substring($start), '\.Controls\.Add\(\$' + [regex]::Escape($name) + '\)')
        $end   = if ($endMatch.Success) { $start + $endMatch.Index } else { $source.Length }
        $block = $source.Substring($start, $end - $start)

        # 1. Is the width set, and set before the first child goes in?
        $widthSet = [regex]::Match($block, '\$' + [regex]::Escape($name) + '\.Width\s*=\s*(\d+)')
        $firstAdd = [regex]::Match($block, '\$' + [regex]::Escape($name) + '\.Controls\.Add\(')

        if (-not $firstAdd.Success) { continue }   # a panel with no children cannot be wrong

        if (-not $widthSet.Success) {
            $problems += "$name : no explicit Width before its children are added"
            continue
        }
        if ($widthSet.Index -gt $firstAdd.Index) {
            $problems += "$name : Width is set after the first child is added"
            continue
        }

        $panelWidth = [int]$widthSet.Groups[1].Value

        $heightSet   = [regex]::Match($block, '\$' + [regex]::Escape($name) + '\.Height\s*=\s*(\d+)')
        $panelHeight = 0
        if ($heightSet.Success) { $panelHeight = [int]$heightSet.Groups[1].Value }

        # 2. Does every child fit?
        foreach ($loc in [regex]::Matches($block, '\$(\w+)\.Location\s*=\s*New-Object System\.Drawing\.Point\((\d+),\s*(\d+)\)')) {
            $child = $loc.Groups[1].Value
            $x     = [int]$loc.Groups[2].Value
            $y     = [int]$loc.Groups[3].Value

            $size = [regex]::Match($block, '\$' + [regex]::Escape($child) + '\.Size\s*=\s*New-Object System\.Drawing\.Size\((\d+),\s*(\d+)\)')
            if (-not $size.Success) { continue }
            $w = [int]$size.Groups[1].Value
            $h = [int]$size.Groups[2].Value

            if (($x + $w) -gt $panelWidth) {
                $problems += "$child : right edge $($x + $w) is past $name's width $panelWidth"
            }
            if ($panelHeight -gt 0 -and ($y + $h) -gt $panelHeight) {
                $problems += "$child : bottom edge $($y + $h) is past $name's height $panelHeight"
            }
        }
    }

    return $problems
}

function Test-WfTabLayout {
    <#
        Tab pages lay themselves out by hand too -- every Add-Wf* call names an
        absolute Y -- so two controls can be put on top of each other just as
        easily as a button can be put off the edge of a panel.

        It happens for one particular reason: the explanatory labels are AutoSize
        with a 920px maximum width, so their height is however many lines the text
        wraps to. Add a clause to a label and it silently grows down through the
        control underneath it. The page has AutoScroll, so nothing overflows and
        nothing errors; the two controls simply overlap, and the lower one is
        half-hidden behind text.

        Heights come from the helper that created the control. Label height is an
        estimate -- Segoe UI 9pt is roughly 128 characters to a 920px line, at 15px
        a line -- which is the only guess here, and it is deliberately a slight
        over-estimate: being told to leave more room than strictly necessary costs
        nothing, and being told nothing is how this ships.

        Controls sharing a Y are treated as a row placed side by side, which is
        what -X on Add-WfButton is for.
    #>
    param([string] $Path, [int] $Gap = 0)

    $source   = Get-Content -LiteralPath $Path -Raw
    $problems = @()

    # Add-WfLabel  $tab 'text' Y [-Heading]
    # Add-WfTextBox $tab 'label' 'value' Y
    # Add-WfChoiceBox $tab 'label' Y $items 'select'
    # Add-WfCheckList $tab 'label' Y $items ... -Height N
    # Add-WfCheckBox $tab 'text' Y
    # Add-WfButton $tab 'text' Y { ... }
    # Add-WfGrid   $tab Y [height]
    $byPage = @{}

    # X and Width matter as much as Y. A field label sits at x=14 and its box at
    # x=190, four pixels apart vertically -- side by side on screen, and a check
    # that only compared Y would call that an overlap every single time.
    $add = {
        param([string] $Page, [int] $Y, [int] $Height, [string] $What, [int] $X = 14, [int] $Width = 930)
        if (-not $byPage.ContainsKey($Page)) { $byPage[$Page] = New-Object System.Collections.ArrayList }
        [void]$byPage[$Page].Add([pscustomobject]@{
            Y = $Y; Height = $Height; What = $What; X = $X; Width = $Width })
    }

    foreach ($m in [regex]::Matches($source, "(?m)^\s*(?:\`$\w+\s*=\s*)?Add-WfLabel\s+\`$(\w+)\s+'((?:[^']|'')*)'\s+(\d+)(.*)$")) {
        $text    = $m.Groups[2].Value -replace "''", "'"
        $heading = $m.Groups[4].Value -match '-Heading'
        $height  = if ($heading) { 20 } else { [Math]::Max(1, [Math]::Ceiling($text.Length / 128.0)) * 15 }
        & $add $m.Groups[1].Value ([int]$m.Groups[3].Value) $height ("label '" + $text.Substring(0, [Math]::Min(30, $text.Length)) + "...'")
    }

    foreach ($m in [regex]::Matches($source, "(?m)^\s*\`$(\w+)\s*=\s*Add-WfTextBox\s+\`$(\w+)\s+'((?:[^']|'')*)'\s+'[^']*'\s+(\d+)")) {
        & $add $m.Groups[2].Value ([int]$m.Groups[4].Value) 22 ('textbox $' + $m.Groups[1].Value) 14 776
    }

    foreach ($m in [regex]::Matches($source, "(?m)^\s*\`$(\w+)\s*=\s*Add-WfChoiceBox\s+\`$(\w+)\s+'((?:[^']|'')*)'\s+(\d+)")) {
        & $add $m.Groups[2].Value ([int]$m.Groups[4].Value) 22 ('choicebox $' + $m.Groups[1].Value) 14 776
    }

    foreach ($m in [regex]::Matches($source, "(?s)\`$(\w+)\s*=\s*Add-WfCheckList\s+\`$(\w+)\s+'((?:[^']|'')*)'\s+(\d+)(.*?)(?:\r?\n\r?\n|\r?\n\S)")) {
        $height = 120
        $h = [regex]::Match($m.Groups[5].Value, '-Height\s+(\d+)')
        if ($h.Success) { $height = [int]$h.Groups[1].Value }
        & $add $m.Groups[2].Value ([int]$m.Groups[4].Value) $height ('checklist $' + $m.Groups[1].Value) 14 776
    }

    foreach ($m in [regex]::Matches($source, "(?m)^\s*\`$(\w+)\s*=\s*Add-WfCheckBox\s+\`$(\w+)\s+'((?:[^']|'')*)'\s+(\d+)")) {
        & $add $m.Groups[2].Value ([int]$m.Groups[4].Value) 22 ('checkbox $' + $m.Groups[1].Value) 190 620
    }

    foreach ($m in [regex]::Matches($source, "(?m)^\s*Add-WfButton\s+\`$(\w+)\s+'((?:[^']|'')*)'\s+(\d+)")) {
        # -X and -Width come AFTER the click handler, on the line with the closing
        # brace, so they are several lines below the call they belong to. Looking
        # only at the rest of the first line finds neither, and every button then
        # looks like it is at the default x=190 -- which makes a row of five
        # side-by-side buttons look like five controls stacked on one spot.
        # They live on the line that CLOSES the handler -- '} -X 14 -Width 150 |
        # Out-Null' -- so that specific line is found rather than the block
        # guessed at. Getting this wrong makes a row of five side-by-side buttons
        # look like five controls stacked on the same spot, which is a wall of
        # false positives rather than a missed one.
        $x = 190; $w = 240

        # A short button fits on one line; a real one has a handler, and then -X
        # and -Width sit on the line that CLOSES it. That closing line is matched
        # at column zero, not merely indented, because a handler containing a
        # nested block -- Start-WfJob -Body { ... } -- closes that one first and
        # its brace carries no -X at all. Getting this wrong makes a row of five
        # side-by-side buttons look like five controls on the same spot.
        $tail  = $source.Substring($m.Index)
        $eol   = $tail.IndexOf("`n")
        $first = if ($eol -ge 0) { $tail.Substring(0, $eol) } else { $tail }

        $where = $first
        if ($where -notmatch '-X\s+\d+' -and $where -notmatch '-Width\s+\d+') {
            $close = [regex]::Match($tail, "(?m)^\}[^\r\n]*")
            if ($close.Success) { $where = $close.Value }
        }

        $xm = [regex]::Match($where, '-X\s+(\d+)');     if ($xm.Success) { $x = [int]$xm.Groups[1].Value }
        $wm = [regex]::Match($where, '-Width\s+(\d+)'); if ($wm.Success) { $w = [int]$wm.Groups[1].Value }
        & $add $m.Groups[1].Value ([int]$m.Groups[3].Value) 30 ("button '" + ($m.Groups[2].Value -replace "''", "'") + "'") $x $w
    }

    foreach ($m in [regex]::Matches($source, "(?m)^\s*\`$(\w+)\s*=\s*Add-WfGrid\s+\`$(\w+)\s+(\d+)(?:\s+(\d+))?")) {
        $height = 200
        if ($m.Groups[4].Success) { $height = [int]$m.Groups[4].Value }
        & $add $m.Groups[2].Value ([int]$m.Groups[3].Value) $height ('grid $' + $m.Groups[1].Value)
    }

    # Controls built by hand rather than through a helper. There are only a few --
    # the VM status line is one -- and they are exactly the ones a shift of the
    # rows around them will silently run into, because no helper call names their
    # Y for a reader to notice.
    foreach ($m in [regex]::Matches($source, "(?m)^\s*\`$(\w+)\.Location\s*=\s*New-Object System\.Drawing\.Point\((\d+),\s*(\d+)\)")) {
        $name = $m.Groups[1].Value
        $y    = [int]$m.Groups[3].Value

        # Only if it is added to a tab page; panel children are Test-WfPanelLayout's job.
        $added = [regex]::Match($source, "\`$(\w*[Tt]ab\w*)\.Controls\.Add\(\`$" + [regex]::Escape($name) + "\)")
        if (-not $added.Success) { continue }

        $size = [regex]::Match($source, "\`$" + [regex]::Escape($name) + "\.Size\s*=\s*New-Object System\.Drawing\.Size\((\d+),\s*(\d+)\)")
        if (-not $size.Success) { continue }

        & $add $added.Groups[1].Value $y ([int]$size.Groups[2].Value) ('hand-built $' + $name) `
              ([int]$m.Groups[2].Value) ([int]$size.Groups[1].Value)
    }

    foreach ($page in ($byPage.Keys | Sort-Object)) {
        $items = @($byPage[$page] | Sort-Object Y, X)

        # Every pair, not just neighbours: a tall control -- a grid, a checked
        # list -- can reach past the thing directly under it into the one after.
        for ($i = 0; $i -lt $items.Count; $i++) {
            for ($j = $i + 1; $j -lt $items.Count; $j++) {
                $a = $items[$i]; $b = $items[$j]

                $verticallyClear = (($a.Y + $a.Height + $Gap) -le $b.Y) -or
                                   (($b.Y + $b.Height + $Gap) -le $a.Y)
                if ($verticallyClear) { continue }

                # Side by side is fine, and is what -X on a button and the
                # label-then-box pattern both rely on.
                $horizontallyClear = (($a.X + $a.Width) -le $b.X) -or (($b.X + $b.Width) -le $a.X)
                if ($horizontallyClear) { continue }

                $problems += ("`$$page : {0} runs to y={1}, but {2} starts at y={3}" -f `
                    $a.What, ($a.Y + $a.Height), $b.What, $b.Y)
            }
        }
    }

    return $problems
}

Write-Host 'Start-WimForgeGui.ps1' -ForegroundColor Cyan
Test-Case 'every control fits its panel' @() @(Test-WfPanelLayout -Path (Join-Path $root 'Start-WimForgeGui.ps1'))
Test-Case 'no two controls overlap on a tab' @() @(Test-WfTabLayout -Path (Join-Path $root 'Start-WimForgeGui.ps1'))

Write-Host 'The check can actually fail' -ForegroundColor Cyan
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'wf-layout-fixture.ps1'

# The bug as it shipped: children added while the panel is still default-sized.
Set-Content -LiteralPath $tmp -Force -Value @'
$bar = New-Object System.Windows.Forms.Panel
$bar.Dock = 'Top'
$bar.Height = 84
$pick = New-Object System.Windows.Forms.Button
$pick.Location = New-Object System.Drawing.Point(868, 5)
$pick.Size = New-Object System.Drawing.Size(62, 24)
$bar.Controls.Add($pick)
$parent.Controls.Add($bar)
'@
$found = @(Test-WfPanelLayout -Path $tmp)
Test-Case 'spots a missing Width' 1 $found.Count
Test-Case 'and says why'          $true ([bool]($found[0] -match 'no explicit Width'))

# Width set, but after the child -- the anchor offset is already wrong by then.
Set-Content -LiteralPath $tmp -Force -Value @'
$bar = New-Object System.Windows.Forms.Panel
$pick = New-Object System.Windows.Forms.Button
$pick.Location = New-Object System.Drawing.Point(100, 5)
$pick.Size = New-Object System.Drawing.Size(62, 24)
$bar.Controls.Add($pick)
$bar.Width = 990
$parent.Controls.Add($bar)
'@
$late = @(Test-WfPanelLayout -Path $tmp)
Test-Case 'spots a late Width' $true ([bool]($late[0] -match 'after the first child'))

# Width set first, but a control still hangs off the right edge.
Set-Content -LiteralPath $tmp -Force -Value @'
$bar = New-Object System.Windows.Forms.Panel
$bar.Width = 400
$bar.Height = 84
$pick = New-Object System.Windows.Forms.Button
$pick.Location = New-Object System.Drawing.Point(380, 5)
$pick.Size = New-Object System.Drawing.Size(62, 24)
$bar.Controls.Add($pick)
$parent.Controls.Add($bar)
'@
$over = @(Test-WfPanelLayout -Path $tmp)
Test-Case 'spots an overhang'   1 $over.Count
Test-Case 'names the edge'      $true ([bool]($over[0] -match 'right edge 442 is past'))

# And too tall.
Set-Content -LiteralPath $tmp -Force -Value @'
$bar = New-Object System.Windows.Forms.Panel
$bar.Width = 400
$bar.Height = 40
$pick = New-Object System.Windows.Forms.Button
$pick.Location = New-Object System.Drawing.Point(10, 20)
$pick.Size = New-Object System.Drawing.Size(62, 30)
$bar.Controls.Add($pick)
$parent.Controls.Add($bar)
'@
Test-Case 'spots an overflow downwards' $true ([bool](@(Test-WfPanelLayout -Path $tmp)[0] -match 'bottom edge 50 is past'))

# A correct panel raises nothing.
Set-Content -LiteralPath $tmp -Force -Value @'
$bar = New-Object System.Windows.Forms.Panel
$bar.Width = 990
$bar.Height = 84
$pick = New-Object System.Windows.Forms.Button
$pick.Location = New-Object System.Drawing.Point(868, 5)
$pick.Size = New-Object System.Drawing.Size(62, 24)
$bar.Controls.Add($pick)
$parent.Controls.Add($bar)
'@
Test-Case 'a correct panel passes' 0 @(Test-WfPanelLayout -Path $tmp).Count

Write-Host 'The tab overlap check can actually fail' -ForegroundColor Cyan

# The real failure: a label long enough to wrap onto four lines, with a text box
# 30px below it. Nothing errors; the box just ends up behind the text.
Set-Content -LiteralPath $tmp -Force -Value (@'
Add-WfLabel $tabX 'PLACEHOLDER' 100 | Out-Null
$xBox = Add-WfTextBox $tabX 'Something' '' 130
'@ -replace 'PLACEHOLDER', ('x' * 400))
$grew = @(Test-WfTabLayout -Path $tmp)
Test-Case 'spots a label growing into the control below' 1 $grew.Count
Test-Case 'and names both'  $true ([bool]($grew[0] -match 'runs to y=160.*xBox.*y=130'))

# The same label, with room left for it.
Set-Content -LiteralPath $tmp -Force -Value (@'
Add-WfLabel $tabX 'PLACEHOLDER' 100 | Out-Null
$xBox = Add-WfTextBox $tabX 'Something' '' 180
'@ -replace 'PLACEHOLDER', ('x' * 400))
Test-Case 'and passes once there is room' 0 @(Test-WfTabLayout -Path $tmp).Count

# A grid running into the buttons underneath it -- the other way this goes wrong.
Set-Content -LiteralPath $tmp -Force -Value @'
$xGrid = Add-WfGrid $tabX 200 200
Add-WfButton $tabX 'Do the thing' 380 { } -X 14 -Width 190 | Out-Null
'@
Test-Case 'spots a grid under a button' $true ([bool](@(Test-WfTabLayout -Path $tmp)[0] -match 'grid \$xGrid runs to y=400'))

# Buttons sharing a Y are a row, not an overlap.
Set-Content -LiteralPath $tmp -Force -Value @'
Add-WfButton $tabX 'Left' 300 { } -X 14 -Width 190 | Out-Null
Add-WfButton $tabX 'Right' 300 { } -X 214 -Width 190 | Out-Null
'@
Test-Case 'a side-by-side row is fine' 0 @(Test-WfTabLayout -Path $tmp).Count

# Different tabs cannot collide with each other.
Set-Content -LiteralPath $tmp -Force -Value @'
$aBox = Add-WfTextBox $tabA 'One' '' 100
$bBox = Add-WfTextBox $tabB 'Two' '' 100
'@
Test-Case 'tabs are judged separately' 0 @(Test-WfTabLayout -Path $tmp).Count

# A hand-built control is the one a row shift runs into without anybody noticing,
# because no Add-Wf* call names its Y for a reader to see.
Set-Content -LiteralPath $tmp -Force -Value @'
$xStatus = New-Object System.Windows.Forms.Label
$xStatus.Location = New-Object System.Drawing.Point(14, 300)
$xStatus.Size = New-Object System.Drawing.Size(930, 40)
$tabX.Controls.Add($xStatus)
Add-WfButton $tabX 'Do the thing' 320 { } -X 14 -Width 190 | Out-Null
'@
Test-Case 'spots a hand-built control being run into' $true `
    ([bool](@(Test-WfTabLayout -Path $tmp)[0] -match 'hand-built \$xStatus runs to y=340'))

Set-Content -LiteralPath $tmp -Force -Value @'
$xStatus = New-Object System.Windows.Forms.Label
$xStatus.Location = New-Object System.Drawing.Point(14, 300)
$xStatus.Size = New-Object System.Drawing.Size(930, 40)
$tabX.Controls.Add($xStatus)
Add-WfButton $tabX 'Do the thing' 344 { } -X 14 -Width 190 | Out-Null
'@
Test-Case 'and passes with room' 0 @(Test-WfTabLayout -Path $tmp).Count

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

Write-Host 'The job drain cannot run twice' -ForegroundColor Cyan

# MessageBox.Show pumps the Windows message loop. The WinForms timer therefore
# keeps firing WHILE a dialog is open, on the same thread, and re-enters the tick
# handler -- so a completion drain that has not yet cleared its state runs a
# second time and logs the job's result twice. One dialog, two result tables.
#
# It shipped, it survived being blamed on the module returning two objects, and
# it is invisible except on jobs whose callback happens to show a dialog. So the
# three things that make it impossible are checked rather than remembered.
$gui = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeGui.ps1') -Raw

Test-Case 'there is a re-entrancy guard'  $true ($gui -match '\$script:Draining\s*=\s*\$false')
Test-Case 'the drain takes it'            $true ($gui -match 'if \(\$script:Draining\) \{ return \}')
Test-Case 'and releases it'               $true ($gui -match '(?s)Draining\) \{ return \}.*\$script:Draining = \$false')

# Order matters as much as the guard. The result has to be taken and cleared
# before anything that can pump the loop, or a re-entrant tick still finds it.
$takeAt  = $gui.IndexOf('$script:Sync.Result = $null')
$dialogAt = $gui.IndexOf('$callback $result')
Test-Case 'the result is cleared before the callback runs' $true (($takeAt -gt 0) -and ($takeAt -lt $dialogAt))

# And the flag must be released outside any try/catch that could skip it,
# otherwise one throw makes the whole window deaf to every job after it.
$release = [regex]::Match($gui, '(?m)^\s*\$script:Draining = \$false\s*$')
Test-Case 'the release is at the top level' $true ($release.Success -and $release.Value -notmatch '^\s{8,}')

Write-Host 'A results grid ends inside the page it is on' -ForegroundColor Cyan

# The same anchoring trap as the panel check above, one level down, and it shipped
# for exactly the same reason: an anchor preserves the gap to the parent's edge as
# it was WHEN THE CONTROL WAS ADDED. The Updates grid was added at Y=364 with a
# height of 200 to a page roughly 470px tall, so that gap started at about -94.
# Anchoring then preserved the 94px of overflow forever.
#
# Nothing looked broken. The grid drew, the rows were there, the columns were
# there. But a DataGridView draws its own scrollbars along its bottom and right
# edges, and those edges were below the page -- so ten search results showed as
# three, with no scrollbar and no way to reach the rest.
#
# The fix is to compute the height from the page's real size instead of anchoring
# to it, which is only knowable after the form is shown. These check that the
# machinery to do that exists and is actually run.

Test-Case 'the grid is not bottom-anchored' $false `
    ($gui -match "(?s)function Add-WfGrid.*?\`$g\.Anchor\s*=\s*'Top,Left,Right,Bottom'")
Test-Case 'it anchors the three that are safe' $true `
    ($gui -match "(?s)function Add-WfGrid.*?\`$g\.Anchor\s*=\s*'Top,Left,Right'")

# The height comes from the page, and from ClientSize rather than Height, so the
# page's own scrollbar is not counted as usable space.
Test-Case 'the height is computed from the page' $true `
    ($gui -match '\$Page\.ClientSize\.Height - \$g\.Top')

# GetNewClosure, because the handler outlives the function that built it. Without
# it $g and $Page are gone by the time a resize arrives and every grid silently
# stops fitting.
Test-Case 'the fitter captures its grid' $true ($gui -match '\}\.GetNewClosure\(\)')

# Two triggers, and both are needed. Resize alone never fires for a window that
# opens at its final size; Shown alone leaves the grid wrong after any resize --
# including dragging the splitter, which is how you make the grid bigger.
Test-Case 'it runs on page resize'  $true ($gui -match '\$Page\.Add_Resize\(\$fit\)')
Test-Case 'and once when shown'     $true ($gui -match '(?s)Add_Shown.*foreach \(\$fit in \$script:GridFit\)')
Test-Case 'every grid registers'    $true ($gui -match '\$script:GridFit\.Add\(\$fit\)')

# A floor rather than a clamp to zero. Two grids sit at Y=578 and Y=710, past the
# bottom of any realistic page; without a floor they compute to a negative height
# and vanish. With one, the page's AutoScroll makes them reachable.
Test-Case 'a minimum height is enforced' $true ($gui -match '(?s)\$h = \$Page\.ClientSize\.Height.*?if \(\$h -lt 120\)')

# Grids not built by Add-WfGrid are unmanaged, so they have to fit on their own.
# This finds them by construction and checks the arithmetic.
$pageHeight = 470   # conservative: the tallest tab page at the minimum window size
foreach ($m in [regex]::Matches($gui, '(?s)\$(\w+)\s*=\s*New-Object System\.Windows\.Forms\.DataGridView(.{0,400}?)\.Controls\.Add')) {
    $name  = $m.Groups[1].Value
    $block = $m.Groups[2].Value

    # Dialog grids live on their own sized form and are out of scope here.
    if ($block -notmatch '\$tab\w+\.Controls\.Add' -and $m.Value -notmatch '\$tab\w+\.Controls\.Add') { continue }

    $loc = [regex]::Match($block, 'Location\s*=\s*New-Object System\.Drawing\.Point\((\d+),\s*(\d+)\)')
    $sz  = [regex]::Match($block, 'Size\s*=\s*New-Object System\.Drawing\.Size\((\d+),\s*(\d+)\)')
    if (-not ($loc.Success -and $sz.Success)) { continue }

    $bottom = [int]$loc.Groups[2].Value + [int]$sz.Groups[1 + 1].Value
    Test-Case "$name fits without a fitter ($bottom <= $pageHeight)" $true ($bottom -le $pageHeight)
}

Write-Host 'Columns cannot crowd each other off the edge' -ForegroundColor Cyan

# AutoSizeColumnsMode 'AllCells' sizes a column to its widest cell, and a catalog
# title is 100 characters. Title took most of the width and pushed TargetBuild,
# VsImage and InImage past the right edge -- the three columns that answer the
# question the search was run to answer.
Test-Case 'widths are measured then capped' $true ($gui -match "(?s)AutoResizeColumns\('AllCells'\).*?AutoSizeColumnsMode = 'None'")
Test-Case 'there is a cap'                  $true ($gui -match '\$cap = \d+')
Test-Case 'and the full text stays reachable' $true ($gui -match '\$g\.ShowCellToolTips\s*=\s*\$true')

Write-Host 'The log does not grow at the grid''s expense' -ForegroundColor Cyan

# The splitter used to give the tabs a fixed 580px, so every pixel the window
# gained went to the log -- which tops out in usefulness at about nine lines --
# and none of it to the grid, which is the part that scales with the result set.
Test-Case 'the log gets a fixed share' $true ($gui -match '\$wanted = \$split\.Height - \d+ - \$split\.SplitterWidth')
Test-Case 'not the tabs'               $false ($gui -match '\$wanted = 580')

# And the window has to be tall enough to be worth splitting, without opening off
# the bottom of a small laptop screen.
Test-Case 'the window asks for height' $true ($gui -match 'PrimaryScreen\.WorkingArea')
Test-Case 'and yields to the screen'   $true ($gui -match '\$wa\.Height - 40')

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
