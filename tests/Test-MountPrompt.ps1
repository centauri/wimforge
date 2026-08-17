# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Opening an image is the expensive thing this tool does, so it is a decision.
#
# The behaviour that prompted this: a read against a 10 GB image mounted it,
# read it, and dismounted it -- 1m43s -- and then the NEXT read did the same
# thing again. Five reads cost five mounts, and none of them had to.
#
# Three rules, and all three are the kind that decay quietly:
#
#   1. an image already open is used and NEVER closed by a read
#   2. when nothing is open, the operator is asked before minutes are spent
#   3. "keep it open" actually keeps it open
#
# Rule 1 is the one worth guarding hardest. Breaking it does not fail anything --
# it just makes the tool slow again, in a way nobody attributes to a regression.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

Write-Host 'Get-WfImageUpdateTarget reuses an open mount' -ForegroundColor Cyan

$upd = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Updates.ps1') -Raw

# It used to inspect the mount FOLDER, find it non-empty, and refuse -- which is
# backwards: a non-empty mount folder usually means this very image is open.
Test-Case 'it asks what is mounted'      $true ($upd -match 'Get-WfCurrentMount')
Test-Case 'and compares it to the image' $true ($upd -match '\$open\.ImagePath.*-eq.*\$ImagePath')
Test-Case 'reuse is recorded'            $true ($upd -match '\$reused\s*=\s*\$true')

# The rule that matters: a mount it did not open, it does not close.
Test-Case 'it only dismounts what it opened' $true ($upd -match 'if \(\$mountedByUs\)')
Test-Case 'and says so when it reuses one'   $true ($upd -match 'Leaving the mount open')

# A different image being open is a different situation, and must not be
# silently treated as "no mount" -- mounting a second image would fail anyway.
Test-Case 'a different image is called out' $true ($upd -match 'A different image is mounted')

Write-Host 'Both front-ends ask before spending minutes' -ForegroundColor Cyan

foreach ($f in @('Start-WimForgeGui.ps1', 'Start-WimForgeMenu.ps1')) {
    $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw

    Test-Case "$f has the prompt"  $true ($src -match 'function Confirm-WfMountNeeded')

    # An open image is never asked about. Asking would invite "no", and "no" on
    # an already-open image is a question with no useful answer.
    Test-Case "$f skips the question when it is already open" $true `
        ($src -match '(?s)function Confirm-WfMountNeeded.*?return ''keep''')

    # Three answers, not two. Two would force "open and close every time" or
    # "open forever", and the whole complaint was about the first of those.
    foreach ($answer in @("'keep'", "'once'", "'no'")) {
        Test-Case "$f offers $answer" $true ($src -match "return $answer")
    }

    # Every read that needs contents goes through it.
    $asks = @([regex]::Matches($src, "Confirm-WfMountNeeded '")).Count
    Test-Case "$f routes its reads through it ($asks)" $true ($asks -ge 5)

    # And 'keep' has to do something. Without this it is a label on a button
    # that behaves identically to 'once'.
    Test-Case "$f acts on keep" $true ($src -match "mountChoice -eq 'keep'")
}

Write-Host 'The mount is visible, not buried' -ForegroundColor Cyan

$gui = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeGui.ps1') -Raw

# In the image bar, next to the image it applies to -- not on one tab among ten.
Test-Case 'there is an open button'  $true ($gui -match '\$wfMountBtn.*=.*New-Object System\.Windows\.Forms\.Button')
Test-Case 'and a close button'       $true ($gui -match '\$wfCloseBtn.*=.*New-Object System\.Windows\.Forms\.Button')
Test-Case 'both live on the image bar' 2 `
    @([regex]::Matches($gui, '\$imageBar\.Controls\.Add\(\$wf(Mount|Close)Btn\)')).Count

# In the footer, not the layout. A status label that lives in the image bar
# takes a row from every tab whether or not anything is open; on the status strip
# it costs nothing and is still on screen at all times.
Test-Case 'the state lives on the status strip' $true `
    ($gui -match '\$wfMountState\s*=\s*New-Object System\.Windows\.Forms\.ToolStripStatusLabel')
Test-Case 'and is not in the image bar'  $false ($gui -match '\$imageBar\.Controls\.Add\(\$wfMountState\)')
Test-Case 'pinned to the right'          $true ($gui -match '\$statusLabel\.Spring\s*=\s*\$true')

# Terse and colour-coded, because a footer is glanced at. The long version lives
# in the tooltip, where it is available without occupying the window.
Test-Case 'closed is named'   $true ($gui -match 'IMAGE CLOSED')
Test-Case 'open is named'     $true ($gui -match 'IMAGE OPEN')
Test-Case 'and wrong-image'   $true ($gui -match 'WRONG IMAGE OPEN')
# Checked against the function rather than the whole file, and by colour rather
# than by the assignment that carries it. The state is worked out first and
# written to ForeColor once at the end -- because writing it from each branch is
# how the label and the timer came to disagree and flicker -- so an assertion
# tied to 'ForeColor = <colour>' would be testing the old shape, not the intent.
$mountFnText = ''
$mountAst = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $root 'Start-WimForgeGui.ps1'), [ref]$null, [ref]$null)
foreach ($f in $mountAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Update-WfMountLabel' }, $true)) { $mountFnText = $f.Extent.Text }

Test-Case 'each state picks its own colour' $true (
    ($mountFnText -match '\[System\.Drawing\.Color\]::SeaGreen')  -and
    ($mountFnText -match '\[System\.Drawing\.Color\]::Firebrick') -and
    ($mountFnText -match '\[System\.Drawing\.Color\]::DimGray'))
Test-Case 'and the colour reaches the label' $true `
    ($mountFnText -match '\$wfMountState\.ForeColor\s*=')
Test-Case 'the detail is in a tooltip' $true ($gui -match '\$wfMountState\.ToolTipText')
Test-Case 'and on the buttons'         $true ($gui -match '\$wfMountTip\.SetToolTip')

# Close is the only irreversible thing on that bar, so it must ask which way.
Test-Case 'closing a writable mount asks commit or discard' $true ($gui -match 'Commit or discard\?')
Test-Case 'and says neither can be undone'                  $true ($gui -match 'Neither can be undone')

$menu = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeMenu.ps1') -Raw

# The console header already had a "Working on" row. The badge goes on the END of
# it -- same information, no extra row, and next to the image it is a property of.
Test-Case 'there is a badge'  $true ($menu -match 'function Get-WfMountBadge')
Test-Case 'it is coloured'    $true ($menu -match "Colour = 'Green'")
Test-Case 'closed is named'   $true ($menu -match "\[CLOSED\]")
Test-Case 'open is named'     $true ($menu -match "\[OPEN \{0\}\]")
Test-Case 'and wrong-image'   $true ($menu -match 'WRONG IMAGE OPEN')

# On the same line: the image is written with -NoNewline and the badge follows.
Test-Case 'it shares the working-image line' $true `
    ($menu -match "(?s)Working on : .*?-NoNewline -ForegroundColor Cyan.*?Get-WfMountBadge")

# And the function that printed it on a row of its own is gone entirely. Two
# descriptions of the same state is one more than can stay in agreement.
Test-Case 'the old standalone printer is gone' $false ($menu -match 'Show-WfMountState')

Write-Host 'A read never pre-opens read-only for a write' -ForegroundColor Cyan

# The pre-open exists so 'keep' works, and it opens READ-ONLY. Doing that ahead
# of an operation that needs to write would leave the write refusing a mount the
# tool itself had just made -- so only read paths may pre-open.
$preOpens = @([regex]::Matches($gui, "keep -and -not \(Get-WfCurrentMount\)")).Count
$asks     = @([regex]::Matches($gui, "Confirm-WfMountNeeded '")).Count
Test-Case 'every pre-open belongs to a read that asked' $true ($preOpens -le $asks)
Test-Case 'and there is at least one'                   $true ($preOpens -ge 1)

Write-Host 'Writing to an image you already opened works' -ForegroundColor Cyan

# This is the third time the same mistake has shipped, in three different places:
# "the mount folder is not empty, so refuse". It is backwards. A non-empty mount
# folder almost always means the image is open ON PURPOSE -- opening a 10 GB WIM
# takes two minutes, nobody does it by accident -- and refusing made the obvious
# order of work (open the image, then inject) the one order that could not work.
#
# Worse, the message said "run Repair-WfMount", which tears down the mount. The
# advice was to destroy the thing that was working correctly.
#
# Read paths were fixed first. This covers the write path, where the stakes are
# higher: it must not close, commit, or discard a mount it did not open.

$svc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw

Test-Case 'inject looks for an open mount' $true ($svc -match '(?s)function Invoke-WfUpdateInject.*?Get-WfCurrentMount')
Test-Case 'and records that it reused one' $true ($svc -match '\$reused\s*=\s*\$true')

# The rule, and the whole reason this is delicate: it did not open this mount, so
# it does not close it -- not on success, and above all not on failure, where a
# discard would take the operator's own work down with it.
Test-Case 'a reused mount is not committed' $true `
    ($svc -match '(?s)if \(\$reused\) \{.*?else \{\s*Dismount-WfImage -MountPath \$mounted\.MountPath -Save')
Test-Case 'and not discarded on failure'    $true ($svc -match '\$mounted -and -not \$reused')

# Leaving it uncommitted is only safe if that is said clearly. The failure mode
# otherwise is someone pressing Close, choosing discard, and losing a 5 GB
# download's worth of servicing without ever knowing it was at risk.
Test-Case 'the operator is told it is unsaved' $true ($svc -match 'NOT saved yet')
Test-Case 'and what discard would cost'        $true ($svc -match 'discard throws them away')
Test-Case 'the history records it too'         $true ($svc -match 'Committed\s*=\s*\(-not \$reused\)')

# Wrong image, wrong index, read-only, and -WorkingCopy are each a real conflict
# rather than something to paper over -- silently updating whatever happened to
# be open is the one outcome worse than refusing.
Test-Case 'a different image is refused' $true ($svc -match '(?s)Invoke-WfUpdateInject.*?A different image is open')
Test-Case 'a different index is refused' $true ($svc -match 'but index \$Index was asked for')
Test-Case 'a read-only mount is refused' $true ($svc -match 'open READ-ONLY')
Test-Case 'and -WorkingCopy is refused'  $true ($svc -match '-WorkingCopy would mount a second image')

# And when the folder really is dirty with nothing mounted, the old advice is
# still right -- so the two cases have to be told apart before advising anything.
Test-Case 'Mount-WfImage separates the two cases' $true `
    ($svc -match '(?s)Mount folder is not empty.*?leftover files from an interrupted run')
Test-Case 'an open image says so instead' $true ($svc -match 'is already open at \$mount')

# Both front-ends have to stop offering a working copy against an open mount,
# and stop promising a mount that has already happened.
foreach ($f in @('Start-WimForgeGui.ps1', 'Start-WimForgeMenu.ps1')) {
    $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw
    Test-Case "$f notices the open image" $true ($src -match '\$sameOpen\s*=\s*\$openNow')
    Test-Case "$f drops the copy option"  $true ($src -match '(?s)\$sameOpen.*?\$copy\s*=\s*\$false')
    Test-Case "$f warns it is unsaved"    $true ($src -match '(?s)\$sameOpen.*?[Cc]ommit')
}

Write-Host 'Both front-ends inject only the update, never a checkpoint' -ForegroundColor Cyan

# Download+inject builds its own -File list from what Save-WfUpdate returned, and
# that list has a row per FILE -- so a checkpoint set put a checkpoint in it. The
# module refuses one now, but the list should never have contained it: a front-end
# that asks for the wrong work and relies on the module to decline is one refactor
# away from asking again somewhere that does not check.
foreach ($f in @('Start-WimForgeGui.ps1', 'Start-WimForgeMenu.ps1')) {
    $src = Get-Content -LiteralPath (Join-Path $root $f) -Raw
    Test-Case "$f filters on IsTarget" $true ($src -match '\$_\.IsTarget')

    # Absent is not false. Rows written by an older run have no IsTarget at all,
    # and treating that as "not the target" would silently inject nothing.
    Test-Case "$f treats a missing value as true" $true ($src -match '\$null -eq \$_\.IsTarget -or \$_\.IsTarget')
}

Write-Host 'Opening an image reports progress, not just its name' -ForegroundColor Cyan

# Mounting a 10 GB image is minutes of nothing. "Running: Open the image..." with
# no other movement is indistinguishable from a hang, and the operator's only
# recourse is to kill the window -- on a mount, that leaves a half-mounted
# directory behind that then needs /Cleanup-Mountpoints.
#
# The cmdlets DO report: Mount-WindowsImage writes ProgressRecords, and a
# runspace collects them in $ps.Streams.Progress. Nothing had to be plumbed into
# the module for this -- the GUI simply was not reading a stream it already had.

Test-Case 'there is a progress bar'   $true ($gui -match '\$wfProgress\s*=\s*New-Object System\.Windows\.Forms\.ToolStripProgressBar')
Test-Case 'it lives on the status strip' $true ($gui -match '\$statusStrip\.Items\.Add\(\$wfProgress\)')
Test-Case 'and is hidden when idle'   $true ($gui -match '\$wfProgress\.Visible\s*=\s*\$false')

# Read the LAST record, not the first: the first is whatever step the job began
# with, and on a multi-step job it never updates again.
Test-Case 'it reads the progress stream' $true ($gui -match '\$script:PowerShell\.Streams\.Progress')
Test-Case 'and takes the newest record'  $true ($gui -match 'Streams\.Progress\[\$script:PowerShell\.Streams\.Progress\.Count - 1\]')

# A Completed record is the PREVIOUS step signing off. Honouring it would pin the
# bar at 100% for the whole of the next step.
Test-Case 'a completed record is ignored' $true ($gui -match "RecordType -ne 'Completed'")

# Two states, and the second is the one that matters. Plenty of long operations
# report no percentage at all; a Continuous bar sitting at 0 for four minutes is
# a worse lie than no bar. Marquee says "busy, no estimate", which is true.
Test-Case 'a percentage drives a real bar' $true ($gui -match "\`$wfProgress\.Style = 'Continuous'")
Test-Case 'and no percentage marquees'     $true ($gui -match "\`$wfProgress\.Style = 'Marquee'")

# Elapsed time is the floor: it is available for every job, needs nothing from
# the cmdlet, and a number that keeps climbing is the whole difference between
# "working" and "hung".
Test-Case 'the job records when it started' $true ($gui -match '\$script:Sync\.Started\s*=\s*Get-Date')
Test-Case 'and elapsed time is shown'       $true ($gui -match '(?s)\$script:Sync\.Started\).*?TotalMinutes')

# And it must go away. A bar left visible after the job ends -- especially a
# marquee, which keeps animating -- claims work is still running.
Test-Case 'it is cleared when the job ends' $true `
    ($gui -match '(?s)# Finished, one way or another\..*?\$wfProgress\.Visible\s*=\s*\$false')

# The catalog scrape silences $ProgressPreference so Invoke-WebRequest does not
# spam the console. That must stay scoped: leaking it would silence the mount and
# the .msu download too, which are the two things worth watching.
$updSrc = $upd
$setCount     = @([regex]::Matches($updSrc, "\`$ProgressPreference = 'SilentlyContinue'")).Count
$restoreCount = @([regex]::Matches($updSrc, 'finally \{ \$ProgressPreference = \$progress \}')).Count
Test-Case 'every progress suppression is restored' $setCount $restoreCount

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
