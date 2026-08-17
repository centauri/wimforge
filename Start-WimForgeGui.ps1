# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
.SYNOPSIS
    Windows Forms front-end for the WimForge.

.DESCRIPTION
    The same WimForge module the console menu uses, behind a window. Every
    button calls exactly one module function -- there is no logic here that is not
    also reachable from a script or a scheduled task.

    Long operations run in a background runspace so the window stays responsive
    and the log pane fills in live. While a job runs the action buttons are
    disabled: two concurrent DISM mounts against the same folder is not a thing.

    IMPORTANT for anyone extending this: control values are read on the UI thread
    and captured as plain strings before the job is dispatched. A background
    runspace must never touch a WinForms control -- that is a cross-thread access
    and it will either throw or, worse, work intermittently.

    Requires Windows PowerShell 5.1 (STA by default, which WinForms needs).
    Run elevated.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Start-WimForgeGui.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,

    # Relaunch elevated immediately without asking. Handy for a shortcut.
    [switch] $Elevate
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Warning 'Run this under Windows PowerShell 5.1. PowerShell 7 is MTA by default and the DISM module runs through a compatibility shim.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic   # InputBox, for the odd one-line prompt
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ModulePath = Join-Path $PSScriptRoot 'WimForge\WimForge.psd1'
if (-not (Test-Path -LiteralPath $script:ModulePath)) {
    [void][System.Windows.Forms.MessageBox]::Show(
        "WimForge not found next to this script:`n$script:ModulePath",
        'WimForge', 'OK', 'Error')
    return
}

Import-Module $script:ModulePath -Force -ErrorAction Stop
$script:Config     = Get-WfConfig -Path $ConfigPath
$script:ConfigFile = Get-WfConfigPath

# ------------------------------------------------------------------ elevation
# Windows only grants administrator rights at process creation, so "elevate"
# always means: start a new elevated instance and close this one.

function Get-WfGuiRelaunchArguments {
    $a = @()
    if ($ConfigPath) { $a += @('-ConfigPath', "`"$ConfigPath`"") }
    # `return $a` on an empty array unrolls to $null, which would put a stray
    # empty argument on the relaunch command line. The comma keeps it an array.
    return ,$a
}

function Invoke-WfGuiElevate {
    <# Returns $true when an elevated instance started and this one should close. #>
    if (Start-WfElevated -ScriptPath $PSCommandPath -Arguments (Get-WfGuiRelaunchArguments)) {
        return $true
    }
    [void][System.Windows.Forms.MessageBox]::Show(
        "Elevation was cancelled.`n`nRead-only actions still work, but anything that mounts an image will fail.",
        'Not elevated', 'OK', 'Warning')
    return $false
}

# =============================================================== job plumbing

$script:Sync = [hashtable]::Synchronized(@{
    Queue   = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    Running = $false
    Result  = $null
    Error   = $null
    Title   = ''
    # When the current job began. Elapsed time is the one progress signal that is
    # always available, including for the operations DISM reports nothing for.
    Started = $null
})

$script:Runspace   = $null
$script:PowerShell = $null
$script:Handle     = $null

# Every button that must be disabled while a job runs. Created here, with the
# other script state, because the controls above the tabs register themselves
# into it as they are built -- and a list that does not exist yet is a null
# whose .Add() takes the whole script down before the window ever appears.
$script:ActionButtons = New-Object System.Collections.Generic.List[object]

# What the timer last set the window to, so it can stop setting it again.
#
# The tick runs four times a second for the life of the window. Anything it does
# unconditionally, it does unconditionally forever -- and three things it used to
# do that way are why the cursor flickered, the buttons flickered, and clicks
# went missing:
#
#   the enable state of every action button was rewritten every tick, and
#   Update-WfMountLabel then disagreed about two of them, so Close went
#   enabled/disabled/enabled/disabled eight times a second and repainted on
#   every change;
#
#   $form.Cursor was assigned every tick, and Control.Cursor forces a
#   WM_SETCURSOR whether or not the value changed -- so the I-beam over a text
#   box was pushed back to an arrow four times a second;
#
#   Update-WfMountLabel called Get-WindowsImage -Mounted, a DISM call, on the UI
#   thread. Four times a second, forever, whether or not anything had happened.
#   That is the one that made menus hard to click: the window was not pumping
#   messages while it waited.
#
# So the tick now acts on CHANGE rather than on schedule. $null means "not known
# yet", which is deliberately not $false -- the first tick has to set the state
# once.
$script:LastRunning   = $null
$script:MountCheckAt  = [datetime]::MinValue
$script:MountSignature = $null

# Set by Start-WfJob -OnComplete, run once on the UI thread when a job finishes.
$script:JobOnComplete = $null

# Re-entrancy guard for the completion drain. A modal dialog pumps the message
# loop, so the timer fires again on this same thread while one is open -- see the
# long note at the drain itself for what that used to do.
$script:Draining = $false

# The mount as the UI last saw it, refreshed by Update-WfMountLabel. Read by
# Confirm-WfMountNeeded so an already-open image is never asked about again.
$script:MountOpen = $null

# What was last read off an image, for the Updates tab. Session-only: it
# describes one image at one moment.
$script:UpdateTarget  = $null

function Start-WfJob {
    <#
        Runs work against the module in a background runspace, streaming the
        module's log lines back through the synchronized queue.

        The body is marshalled as TEXT, not as a scriptblock object, and its
        inputs are passed in $Arguments. That is not a style choice: a scriptblock
        created in the UI runspace stays bound to the UI runspace's session state
        even when it is handed to a child runspace, so `& $block` would resolve
        module commands -- and the log sink -- against the wrong runspace. The
        symptom is subtle and nasty: the job appears to run, but the log pane
        stays empty for forty minutes and all the DISM work executes against the
        UI thread's session state. Rebuilding the scriptblock inside the child
        with [scriptblock]::Create binds it where it actually runs.

        So: never reference a WinForms control in $Body. Read controls on the UI
        thread and pass plain values through $Arguments; each key becomes a
        variable of that name inside the job.
    #>
    param(
        [Parameter(Mandatory)] [string]      $Title,
        [Parameter(Mandatory)] [scriptblock] $Body,
        [hashtable]   $Arguments = @{},
        [scriptblock] $OnComplete
    )

    if ($script:Sync.Running) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Another operation is still running. Wait for it to finish.',
            'Busy', 'OK', 'Warning')
        return
    }

    $script:Sync.Running = $true
    $script:Sync.Started = Get-Date
    $script:Sync.Result  = $null
    $script:Sync.Error   = $null
    $script:Sync.Title   = $Title
    $script:Sync.Queue.Enqueue("=== $Title ===")

    # Kept on this side of the fence on purpose. The callback runs on the UI
    # thread when the job finishes, so it may touch controls -- which is exactly
    # why it must never be put in $script:Sync, where the child runspace could
    # reach it.
    $script:JobOnComplete = $OnComplete

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('WfSync',       $script:Sync)
    $rs.SessionStateProxy.SetVariable('WfModulePath', $script:ModulePath)
    $rs.SessionStateProxy.SetVariable('WfBodyText',   $Body.ToString())
    $rs.SessionStateProxy.SetVariable('WfArgs',       $Arguments)
    $rs.SessionStateProxy.SetVariable('WfConfigPath', $ConfigPath)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try {
            $ErrorActionPreference = 'Stop'
            Import-Module $WfModulePath -Force -ErrorAction Stop

            if ($WfConfigPath) { Get-WfConfig -Path $WfConfigPath | Out-Null }
            else                { Get-WfConfig | Out-Null }

            # Built here so it is bound to THIS runspace's session state.
            Register-WfLogSink -Sink ([scriptblock]::Create(
                'param($Line, $Level); $WfSync.Queue.Enqueue($Line)'))

            foreach ($k in $WfArgs.Keys) {
                Set-Variable -Name $k -Value $WfArgs[$k] -Scope Global
            }

            $WfSync.Result = & ([scriptblock]::Create($WfBodyText))
        }
        catch {
            $WfSync.Error = $_.Exception.Message
            $WfSync.Queue.Enqueue("ERROR: $($_.Exception.Message)")
        }
        finally {
            $WfSync.Running = $false
        }
    })

    $script:Runspace   = $rs
    $script:PowerShell = $ps
    $script:Handle     = $ps.BeginInvoke()
}

# ==================================================================== the form

$form               = New-Object System.Windows.Forms.Form
$script:About       = Get-WfAbout
$form.Text          = "$($script:About.Name) $($script:About.Version)  --  $($script:About.Tagline)"
# The tallest tab spends about 360px on its controls before the results grid even
# starts, so the window has to be tall enough for what is left to be worth
# looking at -- but not so tall it opens off the bottom of a 1366x768 laptop.
# Ask for a generous size, then take whatever the screen actually has.
$wfWantW = 1060
$wfWantH = 920
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($wfWantH -gt ($wa.Height - 40)) { $wfWantH = $wa.Height - 40 }
    if ($wfWantW -gt ($wa.Width  - 40)) { $wfWantW = $wa.Width  - 40 }
}
catch { }
if ($wfWantH -lt 640) { $wfWantH = 640 }
if ($wfWantW -lt 880) { $wfWantW = 880 }

$form.Size          = New-Object System.Drawing.Size($wfWantW, $wfWantH)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(880, 640)
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

$statusStrip      = New-Object System.Windows.Forms.StatusStrip
$statusLabel      = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "$((Get-WfAbout).Name) $((Get-WfAbout).Version) -- ready"
[void]$statusStrip.Items.Add($statusLabel)

# Whether the image is open belongs in the footer, not in the layout. It changes
# what every click costs, so it has to be visible at all times -- but it is state
# rather than content, and state that pushes controls around is state in the way.
# Spring on the left label pins this to the right-hand end.
$statusLabel.Spring    = $true
$statusLabel.TextAlign = 'MiddleLeft'

# Mounting a 10 GB image is minutes of nothing happening. The DISM cmdlets DO
# report progress -- they write ProgressRecords, which is what draws the bar in a
# console -- but a runspace collects those in $ps.Streams.Progress and nobody was
# reading them. So the work was measurable all along and simply was not shown.
$wfProgress          = New-Object System.Windows.Forms.ToolStripProgressBar
$wfProgress.Size     = New-Object System.Drawing.Size(160, 16)
$wfProgress.Minimum  = 0
$wfProgress.Maximum  = 100
$wfProgress.Visible  = $false
[void]$statusStrip.Items.Add($wfProgress)

$wfMountState              = New-Object System.Windows.Forms.ToolStripStatusLabel
$wfMountState.Text         = ''
$wfMountState.BorderSides  = 'Left'
$wfMountState.BorderStyle  = 'Etched'
$wfMountState.Font         = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
[void]$statusStrip.Items.Add($wfMountState)
$form.Controls.Add($statusStrip)

$split                  = New-Object System.Windows.Forms.SplitContainer
$split.Dock             = 'Fill'
$split.Orientation      = 'Horizontal'
# Every tab lays its controls out to roughly 580px. Below that the action
# buttons sit under the fold of a scrolling tab page, which reads as "the button
# is not there" rather than "scroll down" -- so the log pane is not allowed to
# take the whole window.
$split.Panel1MinSize    = 380
$split.Panel2MinSize    = 90
$form.Controls.Add($split)
$split.BringToFront()

# ------------------------------------------------------- the working image
# One image, chosen once, used by Servicing, Customise and Updates. It sits
# above the tabs rather than on any of them, because it is not a property of a
# tab -- it is what the session is about. The Boot and WDS tab keeps its own,
# since a boot.wim is a different file rather than a different opinion.
$imageBar          = New-Object System.Windows.Forms.Panel
$imageBar.Dock     = 'Top'
$imageBar.Height   = 84
$imageBar.Padding  = New-Object System.Windows.Forms.Padding(12, 8, 12, 4)

# The width MUST be set before any child is added, and it must be the width the
# panel will really have. An anchored control remembers its distance from the
# edge as it was when it was added: add a right-anchored button at x=868 to a
# panel that is still its default 200px wide, and the "distance from the right"
# is recorded as -730. When the panel then grows to 990, the button obediently
# moves to x=1662 -- off screen, unclickable, and completely invisible. Which is
# exactly how the Pick buttons disappeared.
$imageBar.Width    = 990

$wfImageLbl          = New-Object System.Windows.Forms.Label
$wfImageLbl.Text     = 'Working image'
$wfImageLbl.Location = New-Object System.Drawing.Point(14, 10)
$wfImageLbl.Size     = New-Object System.Drawing.Size(110, 20)
$imageBar.Controls.Add($wfImageLbl)

$wfImage          = New-Object System.Windows.Forms.TextBox
$wfImage.Text     = $script:Config['BaseImage']
$wfImage.Location = New-Object System.Drawing.Point(128, 6)
$wfImage.Size     = New-Object System.Drawing.Size(560, 22)
$wfImage.Anchor   = 'Top,Left,Right'
$imageBar.Controls.Add($wfImage)

$wfImagePick          = New-Object System.Windows.Forms.Button
$wfImagePick.Text     = 'Pick...'
$wfImagePick.Location = New-Object System.Drawing.Point(696, 5)
$wfImagePick.Size     = New-Object System.Drawing.Size(62, 24)
$wfImagePick.Anchor   = 'Top,Right'
$imageBar.Controls.Add($wfImagePick)
$script:ActionButtons.Add($wfImagePick)

$wfIndexLbl          = New-Object System.Windows.Forms.Label
$wfIndexLbl.Text     = 'Index'
$wfIndexLbl.Location = New-Object System.Drawing.Point(768, 10)
$wfIndexLbl.Size     = New-Object System.Drawing.Size(40, 20)
$wfIndexLbl.Anchor   = 'Top,Right'
$imageBar.Controls.Add($wfIndexLbl)

$wfIndex          = New-Object System.Windows.Forms.TextBox
$wfIndex.Text     = '1'
$wfIndex.Location = New-Object System.Drawing.Point(810, 6)
$wfIndex.Size     = New-Object System.Drawing.Size(50, 22)
$wfIndex.Anchor   = 'Top,Right'
$imageBar.Controls.Add($wfIndex)

$wfIndexPick          = New-Object System.Windows.Forms.Button
$wfIndexPick.Text     = 'Pick...'
$wfIndexPick.Location = New-Object System.Drawing.Point(868, 5)
$wfIndexPick.Size     = New-Object System.Drawing.Size(62, 24)
$wfIndexPick.Anchor   = 'Top,Right'
$imageBar.Controls.Add($wfIndexPick)
$script:ActionButtons.Add($wfIndexPick)

# What the image is, and whether it is open. Both change what the next click
# costs, so both are on screen rather than in the log.
$wfIdentity           = New-Object System.Windows.Forms.Label
$wfIdentity.Text      = 'Not read yet -- Pick an image, or use "Read this image" on the Updates tab.'
$wfIdentity.Location  = New-Object System.Drawing.Point(128, 34)
$wfIdentity.Size      = New-Object System.Drawing.Size(800, 18)
$wfIdentity.Anchor    = 'Top,Left,Right'
$wfIdentity.ForeColor = [System.Drawing.Color]::DimGray
$imageBar.Controls.Add($wfIdentity)

# Mounting is the expensive thing this tool does -- minutes, every time -- and it
# was previously buried on the Servicing tab, which made it look like an
# implementation detail rather than the decision it is. Up here, next to the
# image it applies to, with its own state line: open it once, work, close it once.
$wfMountBtn          = New-Object System.Windows.Forms.Button
$wfMountBtn.Text     = 'Open image'
$wfMountBtn.Location = New-Object System.Drawing.Point(756, 52)
$wfMountBtn.Size     = New-Object System.Drawing.Size(96, 24)
$wfMountBtn.Anchor   = 'Top,Right'
$wfMountTip = New-Object System.Windows.Forms.ToolTip
$wfMountTip.SetToolTip($wfMountBtn,
    "Open (mount) this image and keep it open. Takes a few minutes; everything afterwards is instant until you press Close.")
$imageBar.Controls.Add($wfMountBtn)
$script:ActionButtons.Add($wfMountBtn)

$wfCloseBtn          = New-Object System.Windows.Forms.Button
$wfCloseBtn.Text     = 'Close'
$wfCloseBtn.Location = New-Object System.Drawing.Point(858, 52)
$wfCloseBtn.Size     = New-Object System.Drawing.Size(72, 24)
$wfCloseBtn.Anchor   = 'Top,Right'
$wfCloseBtn.Enabled  = $false
$wfMountTip.SetToolTip($wfCloseBtn,
    "Close (dismount) the open image. A read/write mount asks whether to commit the changes or discard them.")
$imageBar.Controls.Add($wfCloseBtn)
$script:ActionButtons.Add($wfCloseBtn)

$tabs      = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$split.Panel1.Controls.Add($tabs)
$split.Panel1.Controls.Add($imageBar)
$imageBar.SendToBack()
$tabs.BringToFront()

$logBox            = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock       = 'Fill'
$logBox.ReadOnly   = $true
$logBox.BackColor  = [System.Drawing.Color]::FromArgb(24, 24, 24)
$logBox.ForeColor  = [System.Drawing.Color]::Gainsboro
$logBox.Font       = New-Object System.Drawing.Font('Consolas', 9)
$logBox.DetectUrls = $false
$split.Panel2.Controls.Add($logBox)

# ------------------------------------------------------------ layout helpers


function New-WfTab {
    param([string] $Text)
    $page            = New-Object System.Windows.Forms.TabPage
    $page.Text       = $Text
    $page.AutoScroll = $true
    $page.Padding    = New-Object System.Windows.Forms.Padding(12)
    [void]$tabs.TabPages.Add($page)
    return $page
}

function Add-WfLabel {
    param($Page, [string] $Text, [int] $Y, [switch] $Heading)
    $l          = New-Object System.Windows.Forms.Label
    $l.Text     = $Text
    $l.Location = New-Object System.Drawing.Point(14, $Y)
    $l.AutoSize = $true
    if ($Heading) {
        $l.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
        $l.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 130)
    }
    else {
        $l.ForeColor   = [System.Drawing.Color]::DimGray
        $l.MaximumSize = New-Object System.Drawing.Size(920, 0)
    }
    $Page.Controls.Add($l)
    return $l
}

function Show-WfImagePicker {
    <#
        A picker over Get-WfImageInventory: shows what is actually in the image
        folder with size, age and the index table, so the operator is choosing an
        image rather than remembering a path. Falls through to the normal file
        browser for anything outside the folder.
    #>
    param([string] $Folder, [string] $Title = 'Select an image')

    if (-not $Folder) { $Folder = $script:Config['ImageRoot'] }

    # Reading each image's index table is a metadata read per file -- fast
    # locally, noticeable on a slow share. Show the operator something is
    # happening rather than appearing to hang.
    $rows = @()
    $previousCursor = [System.Windows.Forms.Cursor]::Current
    try {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $rows = @(Get-WfImageInventory -Path $Folder -IncludePeImage)
    }
    catch { }
    finally { [System.Windows.Forms.Cursor]::Current = $previousCursor }

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = $Title
    $dlg.Size          = New-Object System.Drawing.Size(940, 460)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Images in $Folder"
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.AutoSize = $true
    $dlg.Controls.Add($lbl)

    $grid                     = New-Object System.Windows.Forms.DataGridView
    $grid.Location            = New-Object System.Drawing.Point(12, 38)
    $grid.Size                = New-Object System.Drawing.Size(898, 330)
    $grid.Anchor              = 'Top,Left,Right,Bottom'
    $grid.ReadOnly            = $true
    $grid.AllowUserToAddRows  = $false
    $grid.RowHeadersVisible   = $false
    $grid.SelectionMode       = 'FullRowSelect'
    $grid.MultiSelect         = $false
    $grid.AutoSizeColumnsMode = 'AllCells'
    $dlg.Controls.Add($grid)

    if ($rows.Count -gt 0) {
        Set-WfGrid $grid ($rows | Select-Object Name, SizeGB, Modified, AgeDays, Indexes, ImageNames, Notes, Path)
        if ($grid.Columns.Contains('Path')) { $grid.Columns['Path'].Visible = $false }
    }
    else {
        $lbl.Text = "No .wim files found in $Folder"
    }

    $script:PickedImage = $null

    $btnOk          = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Use selected'
    $btnOk.Location = New-Object System.Drawing.Point(12, 382)
    $btnOk.Size     = New-Object System.Drawing.Size(140, 30)
    $btnOk.Anchor   = 'Bottom,Left'
    $btnOk.Add_Click({
        if ($grid.SelectedRows.Count -gt 0) {
            $script:PickedImage = [string]$grid.SelectedRows[0].Cells['Path'].Value
            $dlg.DialogResult = 'OK'; $dlg.Close()
        }
    })
    $dlg.Controls.Add($btnOk)

    $btnBrowse          = New-Object System.Windows.Forms.Button
    $btnBrowse.Text     = 'Browse elsewhere...'
    $btnBrowse.Location = New-Object System.Drawing.Point(162, 382)
    $btnBrowse.Size     = New-Object System.Drawing.Size(160, 30)
    $btnBrowse.Anchor   = 'Bottom,Left'
    $btnBrowse.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Windows images (*.wim)|*.wim|All files (*.*)|*.*'
        if (Test-Path -LiteralPath $Folder) { $ofd.InitialDirectory = $Folder }
        if ($ofd.ShowDialog() -eq 'OK') {
            $script:PickedImage = $ofd.FileName
            $dlg.DialogResult = 'OK'; $dlg.Close()
        }
    })
    $dlg.Controls.Add($btnBrowse)

    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.Location     = New-Object System.Drawing.Point(770, 382)
    $btnCancel.Size         = New-Object System.Drawing.Size(140, 30)
    $btnCancel.Anchor       = 'Bottom,Right'
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    $grid.Add_CellDoubleClick({ $btnOk.PerformClick() })

    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    return $script:PickedImage
}

function Show-WfModelPicker {
    <#
        Which driver model folders to inject, picked from the library rather than
        typed into a box.

        This was an InputBox -- "Driver model folders, comma separated" -- in four
        places, which asks the operator to remember what the folders are called
        and spell them the same way the harvest did. Get a character wrong and
        Add-WfDriver throws "Model folder(s) not found", twenty minutes after the
        mount if it was a servicing run. The console menu has listed the library
        since the beginning (Select-WfModel); the window, which is the one people
        actually use, did not.

        The list is what is on disk, with the counts that decide whether a folder
        is worth injecting: INFs, how many of them WinPE would care about, size,
        and how long ago the machine it came from was harvested.

        Returns an object rather than an array, deliberately. "Cancel", "all of
        them" and "these three" are three different answers, and an array cannot
        carry the first two -- an empty array returned from a PowerShell function
        arrives at the caller as $null, indistinguishable from a cancel.
    #>
    param([string] $Title = 'Driver model folders', [string] $DriverRoot)

    $result = [pscustomobject]@{ Cancelled = $true; All = $false; Models = @() }

    # The caller passes the folder the Drivers tab is pointing at, which is not
    # necessarily the configured one. Listing one library and injecting from
    # another is the kind of mismatch nothing downstream would report.
    $root = $DriverRoot
    if (-not $root) { $root = $script:Config['DriverRoot'] }

    $library = @()
    $previousCursor = [System.Windows.Forms.Cursor]::Current
    try {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $library = @(Get-WfDriverLibrary -DriverRoot $root)
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("The driver library could not be read." + [Environment]::NewLine + [Environment]::NewLine +
             "$root" + [Environment]::NewLine + [Environment]::NewLine +
             $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine +
             'Pick a different one with the "Driver library folder" box on the Drivers tab.'),
            'Driver library', 'OK', 'Warning')
        return $result
    }
    finally { [System.Windows.Forms.Cursor]::Current = $previousCursor }

    if ($library.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("There are no model folders in the driver library yet." + [Environment]::NewLine + [Environment]::NewLine +
             "$root" + [Environment]::NewLine + [Environment]::NewLine +
             'Harvest a reference machine on the Drivers tab, or point the "Driver library folder" box there at an existing library.'),
            'Driver library', 'OK', 'Information')
        return $result
    }

    $pick = Show-WfListPicker -Title $Title `
                -Prompt "Models in $root -- tick the ones to inject, or take the whole library." `
                -Hint 'The whole library is the usual answer. A subset is for a targeted rebuild after adding one model -- everything left out simply is not in the image.' `
                -AllLabel 'Whole library' `
                -Items @($library | ForEach-Object {
                    $age = '     ?'
                    if ($null -ne $_.AgeDays) { $age = '{0,4}d' -f $_.AgeDays }
                    [pscustomobject]@{
                        Value = $_.Model
                        Label = ('{0,-34} {1,4} INFs  {2,3} boot  {3,7} MB  harvested {4} ago' -f `
                                    $_.Model, $_.InfCount, $_.BootRelevant, $_.SizeMB, $age)
                    } })

    if ($pick.Cancelled) { return $result }
    if ($pick.All)       { return [pscustomobject]@{ Cancelled = $false; All = $true;  Models = @() } }
    return [pscustomobject]@{ Cancelled = $false; All = $false; Models = @($pick.Values) }
}

function Read-WfSeconds {
    <#
        A number of seconds, from a box, checked before it is used.

        The console front-end asks for countdown lengths as plain text and parses
        them; without the same question here the two front-ends would take
        different parameters for the same job, which is the thing the parity
        check exists to catch.

        Blank comes back as the default rather than as zero. InputBox cannot tell
        Cancel from an empty OK -- both return an empty string -- so treating
        blank as "no countdown" would turn a cancelled dialog into a deployment
        script that waits forever for somebody to type at it.

        Anything that is not a number returns $null, and the caller stops. A
        typo silently becoming 60 seconds is the kind of thing found out from a
        till that rebooted while a technician was still reading the screen.
    #>
    param([string] $Prompt, [string] $Title = 'How long', [string] $Default = '60')

    $text = [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $Default)
    if (-not "$text".Trim()) { $text = $Default }

    $value = 0
    if (-not [int]::TryParse("$text".Trim(), [ref]$value) -or $value -lt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("'{0}' is not a number of seconds." -f $text), 'Not a number', 'OK', 'Information')
        return $null
    }
    return $value
}

function Show-WfListPicker {
    <#
        Tick several things off a list. The dialog behind every "which of these"
        question in this window.

        Generic on purpose. It started as the driver-model picker, and the moment
        display languages needed the same question -- a short list, tick a few,
        or take all of them -- copying sixty lines of WinForms to ask it twice
        would have been two things to keep in step forever.

        Items are objects with Value (what the caller wants back) and Label (what
        the operator reads). The caller formats the label, because only the
        caller knows which columns matter.

        Returns Cancelled / All / Values, and those are three different answers.
        An empty array returned from a PowerShell function arrives at the caller
        as $null, indistinguishable from a cancel -- which is why this is an
        object and every caller checks .Cancelled first.

        -AllLabel adds the "take everything" button. Leave it out and the only
        way to say yes is to tick something, which is right when "all of them"
        is not a meaningful answer.

        -Single turns it into a pick-one: ticking a row unticks whatever was
        ticked before, and the Tick all button goes away. Same dialog rather than
        a second one, because "which of these five" and "which of these twenty"
        are the same question to the person answering it.
    #>
    param(
        [string]   $Title  = 'Choose',
        [string]   $Prompt = '',
        [string]   $Hint   = '',
        [string]   $AllLabel = '',
        [object[]] $Items  = @(),
        [switch]   $Single
    )

    $result = [pscustomobject]@{ Cancelled = $true; All = $false; Values = @() }
    $items  = @($Items | Where-Object { $_ })
    if ($items.Count -eq 0) { return $result }

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = $Title
    $dlg.Size          = New-Object System.Drawing.Size(760, 500)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = $Prompt
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size     = New-Object System.Drawing.Size(716, 20)
    $lbl.Anchor   = 'Top,Left,Right'
    $dlg.Controls.Add($lbl)

    $hint           = New-Object System.Windows.Forms.Label
    $hint.Text      = $Hint
    $hint.Location  = New-Object System.Drawing.Point(12, 34)
    $hint.Size      = New-Object System.Drawing.Size(716, 34)
    $hint.Anchor    = 'Top,Left,Right'
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($hint)

    # A fixed-pitch font so the caller's columns line up without a grid. A
    # CheckedListBox is the right control: the whole interaction is ticking
    # several of a short list, which a DataGridView makes into a chore.
    $list                = New-Object System.Windows.Forms.CheckedListBox
    $list.Location       = New-Object System.Drawing.Point(12, 74)
    $list.Size           = New-Object System.Drawing.Size(716, 320)
    $list.Anchor         = 'Top,Left,Right,Bottom'
    $list.CheckOnClick   = $true
    $list.IntegralHeight = $false
    $list.Font           = New-Object System.Drawing.Font('Consolas', 9)
    $dlg.Controls.Add($list)

    foreach ($i in $items) { [void]$list.Items.Add("$($i.Label)") }

    if ($Single) {
        # ItemCheck fires BEFORE the new state is applied, so unticking the
        # others from inside it would be undone a moment later by the check
        # that is still in flight. Posting the work back to the control does
        # it after -- which is the standard way round this and the reason
        # this is four lines instead of one.
        $list.Add_ItemCheck({
            param($sender, $e)
            if ($e.NewValue -ne [System.Windows.Forms.CheckState]::Checked) { return }
            $keep = $e.Index
            $sender.BeginInvoke([Action]{
                for ($i = 0; $i -lt $list.Items.Count; $i++) {
                    if ($i -ne $keep) { $list.SetItemChecked($i, $false) }
                }
            }) | Out-Null
        })
    }

    $btnAll          = New-Object System.Windows.Forms.Button
    $btnAll.Text     = 'Tick all'
    $btnAll.Location = New-Object System.Drawing.Point(12, 406)
    $btnAll.Size     = New-Object System.Drawing.Size(90, 30)
    $btnAll.Anchor   = 'Bottom,Left'
    $btnAll.Visible  = (-not $Single)
    $btnAll.Add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $true) } })
    $dlg.Controls.Add($btnAll)

    $btnNone          = New-Object System.Windows.Forms.Button
    $btnNone.Text     = 'Tick none'
    $btnNone.Location = New-Object System.Drawing.Point(110, 406)
    $btnNone.Size     = New-Object System.Drawing.Size(90, 30)
    $btnNone.Anchor   = 'Bottom,Left'
    $btnNone.Add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $false) } })
    $dlg.Controls.Add($btnNone)

    # Two ways to say yes, because "all of them" is a different intention from
    # "these ones" and reading it off an empty tick list would guess at which.
    if ($AllLabel) {
        $btnAllLib          = New-Object System.Windows.Forms.Button
        $btnAllLib.Text     = $AllLabel
        $btnAllLib.Location = New-Object System.Drawing.Point(380, 406)
        $btnAllLib.Size     = New-Object System.Drawing.Size(120, 30)
        $btnAllLib.Anchor   = 'Bottom,Right'
        $btnAllLib.Add_Click({
            $script:WfPickedList = [pscustomobject]@{ Cancelled = $false; All = $true; Values = @() }
            $dlg.DialogResult = 'OK'; $dlg.Close()
        })
        $dlg.Controls.Add($btnAllLib)
    }

    $btnOk          = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Use ticked'
    $btnOk.Location = New-Object System.Drawing.Point(508, 406)
    $btnOk.Size     = New-Object System.Drawing.Size(110, 30)
    $btnOk.Anchor   = 'Bottom,Right'
    $btnOk.Add_Click({
        $picked = @()
        for ($i = 0; $i -lt $list.Items.Count; $i++) {
            if ($list.GetItemChecked($i)) { $picked += $items[$i].Value }
        }
        if ($picked.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show(
                'Nothing is ticked. Tick what you want, or cancel.',
                'Nothing selected', 'OK', 'Information')
            return
        }
        $script:WfPickedList = [pscustomobject]@{ Cancelled = $false; All = $false; Values = $picked }
        $dlg.DialogResult = 'OK'; $dlg.Close()
    })
    $dlg.Controls.Add($btnOk)

    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.Location     = New-Object System.Drawing.Point(626, 406)
    $btnCancel.Size         = New-Object System.Drawing.Size(102, 30)
    $btnCancel.Anchor       = 'Bottom,Right'
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    $script:WfPickedList = $result
    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    return $script:WfPickedList
}

# Which index box belongs to which image box. Held here rather than looked up
# from the controls, because the browse button's handler is a closure and a
# closure cannot read $script: state -- it gets its own scope. A FUNCTION called
# from that closure can, because a function body is bound to the scope it was
# defined in. That indirection is the whole reason these two exist.
$script:WfIndexPairs = @{}

function Register-WfIndexPair {
    param($ImageBox, $IndexBox)
    if ($ImageBox -and $IndexBox) { $script:WfIndexPairs[$ImageBox] = $IndexBox }
}

function Sync-WfIndexBox {
    <#
        Called after an image is chosen. Fills in the matching index box: silently
        when the image has one index, and by showing the index table when it has
        several -- which is the moment the choice actually has to be made, rather
        than later when someone has already typed 1 and moved on.
    #>
    param($ImageBox)

    if (-not $ImageBox) { return }
    if (-not $script:WfIndexPairs.ContainsKey($ImageBox)) { return }

    $indexBox = $script:WfIndexPairs[$ImageBox]
    $picked   = Show-WfIndexPicker -ImagePath $ImageBox.Text -Reason 'Which index of this image do you want to work on?'

    if ($null -ne $picked) {
        $indexBox.Text = "$picked"
        Write-WfGuiLog "Index $picked selected in $(Split-Path $ImageBox.Text -Leaf)" ([System.Drawing.Color]::LightSteelBlue)
    }
    else {
        Write-WfGuiLog "Index left at $($indexBox.Text). Use Pick... beside the Index box to change it." ([System.Drawing.Color]::Khaki)
    }
}

function Show-WfIndexPicker {
    <#
        Picks an index by showing what each one actually is, rather than asking
        the operator to remember. The console has done this since the start;
        this is the same thing for the GUI, and it reads the same function.

        Nothing is mounted -- this is the WIM header -- so it is fast enough to
        run on a click even against a share.
    #>
    param([string] $ImagePath, [string] $Reason)

    if (-not $ImagePath) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Choose an image first.', 'No image', 'OK', 'Information')
        return $null
    }

    $rows = @()
    $previousCursor = [System.Windows.Forms.Cursor]::Current
    try {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $rows = @(Get-WfImageInfo -ImagePath $ImagePath)
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Could not read the indexes:`n`n$($_.Exception.Message)", 'Index list', 'OK', 'Warning')
        return $null
    }
    finally { [System.Windows.Forms.Cursor]::Current = $previousCursor }

    if ($rows.Count -eq 0) { return $null }

    # One index is the common case; asking about it would be theatre.
    if ($rows.Count -eq 1) { return [int]$rows[0].ImageIndex }

    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = "Indexes in $(Split-Path $ImagePath -Leaf)"
    $dlg.Size          = New-Object System.Drawing.Size(900, 420)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

    $intro = 'On Microsoft media, index 2 is Windows Setup -- that is the one WDS boots. A custom PE built with copype is a single index.'
    if ($Reason) { $intro = "$Reason`r`n$intro" }

    $lbl          = New-Object System.Windows.Forms.Label
    $lbl.Text     = $intro
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size     = New-Object System.Drawing.Size(858, 34)
    $dlg.Controls.Add($lbl)

    $grid                     = New-Object System.Windows.Forms.DataGridView
    $grid.Location            = New-Object System.Drawing.Point(12, 52)
    $grid.Size                = New-Object System.Drawing.Size(858, 270)
    $grid.Anchor              = 'Top,Left,Right,Bottom'
    $grid.ReadOnly            = $true
    $grid.AllowUserToAddRows  = $false
    $grid.RowHeadersVisible   = $false
    $grid.SelectionMode       = 'FullRowSelect'
    $grid.MultiSelect         = $false
    $grid.AutoSizeColumnsMode = 'AllCells'
    $dlg.Controls.Add($grid)

    Set-WfGrid $grid ($rows | Select-Object ImageIndex, ImageName, EditionId, Architecture, Languages, SizeGB, Note)
    if ($grid.Rows.Count -gt 0) { $grid.Rows[0].Selected = $true }

    $script:PickedIndex = $null

    $btnOk          = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'Use this index'
    $btnOk.Location = New-Object System.Drawing.Point(12, 336)
    $btnOk.Size     = New-Object System.Drawing.Size(150, 30)
    $btnOk.Anchor   = 'Bottom,Left'
    $btnOk.Add_Click({
        if ($grid.SelectedRows.Count -gt 0) {
            $n = 0
            if ([int]::TryParse([string]$grid.SelectedRows[0].Cells['ImageIndex'].Value, [ref]$n)) {
                $script:PickedIndex = $n
                $dlg.DialogResult = 'OK'; $dlg.Close()
            }
        }
    })
    $dlg.Controls.Add($btnOk)

    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.Location     = New-Object System.Drawing.Point(730, 336)
    $btnCancel.Size         = New-Object System.Drawing.Size(140, 30)
    $btnCancel.Anchor       = 'Bottom,Right'
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    $grid.Add_CellDoubleClick({ $btnOk.PerformClick() })

    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    return $script:PickedIndex
}

function Add-WfTextBox {
    param($Page, [string] $Label, [string] $Value, [int] $Y, [switch] $Browse,
          [switch] $PickFolder, [string] $PickFolderTitle,
          [switch] $PickFolderIsPe, [switch] $PickIndex, $IndexFor)
    $l          = New-Object System.Windows.Forms.Label
    $l.Text     = $Label
    $l.Location = New-Object System.Drawing.Point(14, ($Y + 4))
    $l.Size     = New-Object System.Drawing.Size(170, 20)
    $Page.Controls.Add($l)

    $t          = New-Object System.Windows.Forms.TextBox
    $t.Text     = $Value
    $t.Location = New-Object System.Drawing.Point(190, $Y)
    $t.Size     = New-Object System.Drawing.Size(600, 22)
    $t.Anchor   = 'Top,Left,Right'
    $Page.Controls.Add($t)

    if ($Browse) {
        $b          = New-Object System.Windows.Forms.Button
        $b.Text     = 'Pick...'
        $b.Location = New-Object System.Drawing.Point(798, ($Y - 1))
        $b.Size     = New-Object System.Drawing.Size(62, 24)
        $b.Anchor   = 'Top,Right'
        # Resolve the folder HERE, not inside the handler. GetNewClosure() binds
        # the scriptblock to a new dynamic module whose script scope contains only
        # copies of this function's locals -- so `$script:Config` inside the
        # closure is $null, and with $ErrorActionPreference = 'Stop' the indexing
        # error is terminating and the button silently does nothing at all.
        #
        # NOT named $pickFolder. This function grew a [switch] $PickFolder
        # parameter, PowerShell variable names are case-insensitive, and the
        # assignment below then tried to put a path into a SwitchParameter:
        #
        #   Cannot convert the "C:\Imaging\Images" value of type "System.String"
        #   to type "System.Management.Automation.SwitchParameter"
        #
        # which is thrown while the window is being built, so the GUI never
        # opens and the message names a type rather than a control.
        $imagePickerFolder = $script:Config['ImageRoot']
        if ($PickFolderIsPe -and $script:Config['PeImage']) {
            $peFolder = Split-Path $script:Config['PeImage'] -Parent
            if ($peFolder) { $imagePickerFolder = $peFolder }
        }

        $b.Add_Click({
            $picked = Show-WfImagePicker -Folder $imagePickerFolder
            if ($picked) {
                $t.Text = $picked
                # Choosing an image is the moment to settle which index, not
                # twenty minutes later when a servicing run picked 1 for you.
                Sync-WfIndexBox -ImageBox $t
            }
        }.GetNewClosure())

        $Page.Controls.Add($b)
        # Registered so it is disabled while a job runs -- otherwise the picker
        # can fire DISM metadata reads against images a servicing run has mounted.
        $script:ActionButtons.Add($b)
    }

    # A FOLDER, not a file. -Browse opens the image picker, which is right for a
    # .wim and useless for a directory -- and a path typed into a box by hand is
    # the one input nothing can check until it fails.
    if ($PickFolder) {
        $fb          = New-Object System.Windows.Forms.Button
        $fb.Text     = 'Pick...'
        $fb.Location = New-Object System.Drawing.Point(798, ($Y - 1))
        $fb.Size     = New-Object System.Drawing.Size(62, 24)
        $fb.Anchor   = 'Top,Right'
        $folderTitle = $PickFolderTitle
        if (-not $folderTitle) { $folderTitle = $Label }

        $fb.Add_Click({
            $d             = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = $folderTitle
            $d.ShowNewFolderButton = $true
            # Start where the box already points, so picking a sibling folder is
            # two clicks rather than a walk from This PC.
            $current = "$($t.Text)".Trim()
            if ($current -and (Test-Path -LiteralPath $current)) { $d.SelectedPath = $current }
            if ($d.ShowDialog() -eq 'OK') { $t.Text = $d.SelectedPath }
        }.GetNewClosure())

        $Page.Controls.Add($fb)
    }

    if ($PickIndex -and $IndexFor) {
        Register-WfIndexPair -ImageBox $IndexFor -IndexBox $t

        $ib          = New-Object System.Windows.Forms.Button
        $ib.Text     = 'Pick...'
        $ib.Location = New-Object System.Drawing.Point(798, ($Y - 1))
        $ib.Size     = New-Object System.Drawing.Size(62, 24)
        $ib.Anchor   = 'Top,Right'
        # $IndexFor is the image box this index belongs to; it is read at click
        # time so a change of image is picked up without any wiring between them.
        $ib.Add_Click({
            $picked = Show-WfIndexPicker -ImagePath $IndexFor.Text
            if ($null -ne $picked) { $t.Text = "$picked" }
        }.GetNewClosure())
        $Page.Controls.Add($ib)
        $script:ActionButtons.Add($ib)
    }

    return $t
}

function Add-WfChoiceBox {
    <#
        A drop-down for the settings that have a real list behind them: time
        zones, locales, keyboard layouts, UI languages.

        Plain strings go into the list, and a hashtable on the control's Tag maps
        the string back to the value. No data binding: binding a ComboBox to
        PSObjects goes through the type descriptor and is unreliable enough on
        5.1 that the failure mode is an empty drop-down with no error anywhere.

        The label leads with the value -- 'nl-NL  --  Dutch (Netherlands)' --
        because a DropDownList does prefix search on what is shown, so typing
        'nl-' has to land somewhere useful.

        The list always starts with a "leave this one alone" row, which is the
        drop-down equivalent of the blank box it replaces.
    #>
    param(
        $Page, [string] $Label, [int] $Y, $Items, [string] $Select,
        [string] $BlankLabel = '(leave this one alone)',
        [int] $Width = 600,
        [switch] $Editable
    )

    $l          = New-Object System.Windows.Forms.Label
    $l.Text     = $Label
    $l.Location = New-Object System.Drawing.Point(14, ($Y + 4))
    $l.Size     = New-Object System.Drawing.Size(170, 20)
    $Page.Controls.Add($l)

    $c                = New-Object System.Windows.Forms.ComboBox
    $c.Location       = New-Object System.Drawing.Point(190, $Y)
    $c.Size           = New-Object System.Drawing.Size($Width, 22)
    $c.Anchor         = 'Top,Left,Right'
    $c.MaxDropDownItems = 20

    # DropDownList when the list IS the set of valid answers -- a locale, a time
    # zone. DropDown when it is only what could be found: a Hyper-V host that is
    # switched off answers nothing, and a box that then cannot be typed into is
    # worse than the plain text box it replaced.
    if ($Editable) {
        $c.DropDownStyle      = 'DropDown'
        $c.AutoCompleteMode   = 'SuggestAppend'
        $c.AutoCompleteSource = 'ListItems'
    }
    else {
        $c.DropDownStyle = 'DropDownList'
    }
    $Page.Controls.Add($c)

    Set-WfChoiceItems -Combo $c -Items $Items -Select $Select -BlankLabel $BlankLabel
    return $c
}

function Set-WfChoiceItems {
    <#
        Fills or refills a choice box. Separate from creating it because the UI
        language list cannot exist until an image has been read -- offering a
        language whose pack is not in the image is offering a choice that fails.
    #>
    param($Combo, $Items, [string] $Select, [string] $BlankLabel = '(leave this one alone)')

    $map = @{}
    $map[$BlankLabel] = ''

    $Combo.BeginUpdate()
    try {
        $Combo.Items.Clear()
        [void]$Combo.Items.Add($BlankLabel)

        foreach ($row in @($Items | Where-Object { $_ })) {
            $text = $row.Label
            if (-not $text) { $text = "$($row.Value)" }
            # Two entries showing the same text would make the map ambiguous, and
            # the second one would be unreachable. Keep the first.
            if ($map.ContainsKey($text)) { continue }
            $map[$text] = $row.Value
            [void]$Combo.Items.Add($text)
        }
    }
    finally { $Combo.EndUpdate() }

    $Combo.Tag = @{ Map = $map; Blank = $BlankLabel }

    # An editable box may already hold something the operator typed, and
    # refreshing the list behind it must not throw that away.
    $editable = ($Combo.DropDownStyle -ne 'DropDownList')
    $typed    = "$($Combo.Text)"

    $Combo.SelectedIndex = 0

    $matched = $false
    if ($Select) {
        foreach ($text in $Combo.Items) {
            if ($map[$text] -eq $Select) { $Combo.SelectedItem = $text; $matched = $true; break }
        }
        # An editable box can hold a value that is not in the list at all -- a
        # path on a host this workstation cannot see, most obviously.
        if (-not $matched -and $editable) { $Combo.Text = $Select; $matched = $true }
    }

    if (-not $matched -and $editable -and $typed -and $typed -ne $BlankLabel) {
        $Combo.Text = $typed
    }
}

function Add-WfChoiceBrowse {
    <#
        A 'Browse...' button beside a choice box, for the ones that hold a path.

        Deliberately narrow about where it will and will not open. A path on the
        Hyper-V host is meaningless here when the host is a server somewhere: a
        local file browser would return a path this workstation can see and the
        host cannot, which New-VM then rejects with a message about the ISO not
        existing -- pointing at a file that plainly does exist.
    #>
    param(
        $Page, $Combo, [int] $Y,
        [string] $Title  = 'Select a file',
        [string] $Filter = 'All files (*.*)|*.*',
        [scriptblock] $IsLocal = { $true },
        [string] $RemoteNote = ''
    )

    $b          = New-Object System.Windows.Forms.Button
    $b.Text     = 'Browse...'
    $b.Location = New-Object System.Drawing.Point(798, ($Y - 1))
    $b.Size     = New-Object System.Drawing.Size(72, 24)
    $b.Anchor   = 'Top,Right'

    $b.Add_Click({
        if (-not (& $IsLocal)) {
            [void][System.Windows.Forms.MessageBox]::Show($RemoteNote, 'Not this machine', 'OK', 'Information')
            return
        }

        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title  = $Title
        $ofd.Filter = $Filter

        # Start where the current answer is, so a second visit does not begin
        # from Documents again.
        $current = Read-WfChoice $Combo
        if ($current) {
            $dir = Split-Path $current -Parent
            if ($dir -and (Test-Path -LiteralPath $dir)) { $ofd.InitialDirectory = $dir }
        }

        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $Combo.Text = $ofd.FileName
        }
    }.GetNewClosure())

    $Page.Controls.Add($b)
    $script:ActionButtons.Add($b)
    return $b
}

function Read-WfChoice {
    <# The value behind whatever is showing. Empty string for "leave it alone". #>
    param($Combo)
    if (-not $Combo -or -not $Combo.Tag) { return '' }
    $text = "$($Combo.Text)"
    if (-not $text) { return '' }

    $map = $Combo.Tag['Map']
    if ($map.ContainsKey($text)) { return "$($map[$text])" }

    # Not one of the offered answers. On a fixed list that means nothing was
    # chosen; on an editable one it means the operator typed something, and
    # what they typed IS the answer.
    if ($Combo.DropDownStyle -ne 'DropDownList') { return $text }
    return ''
}

function ConvertTo-WfChoiceItem {
    <#
        Turns what a Get-Wf*Choice function returns into the Label/Value pairs the
        drop-downs take. Same shape as the console's ConvertTo-WfPickItem, and it
        has to stay that way -- the two front-ends showing different labels for
        the same list is exactly the drift the parity check exists to catch.
    #>
    param(
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [string] $ValueProperty,
        [Parameter(Mandatory)] [string[]] $LabelProperty
    )

    $pairs = foreach ($row in @($Source | Where-Object { $_ })) {
        $extra = @($LabelProperty | ForEach-Object { $row.$_ } | Where-Object { $_ })
        [pscustomobject]@{
            Value = $row.$ValueProperty
            Label = ('{0}  --  {1}' -f $row.$ValueProperty, ($extra -join '  --  ')).TrimEnd(' -')
        }
    }
    return @($pairs)
}

function Add-WfCheckList {
    <#
        A checked list for the one place where more than one answer is right:
        which key combinations Keyboard Filter should block. Typing those names
        into a comma-separated box is how one lands slightly wrong, gets accepted,
        and blocks nothing on a shop floor.
    #>
    param($Page, [string] $Label, [int] $Y, $Items, [string[]] $Checked = @(), [int] $Height = 120)

    $l          = New-Object System.Windows.Forms.Label
    $l.Text     = $Label
    $l.Location = New-Object System.Drawing.Point(14, ($Y + 4))
    $l.Size     = New-Object System.Drawing.Size(170, 36)
    $Page.Controls.Add($l)

    $c                 = New-Object System.Windows.Forms.CheckedListBox
    $c.Location        = New-Object System.Drawing.Point(190, $Y)
    $c.Size            = New-Object System.Drawing.Size(600, $Height)
    $c.Anchor          = 'Top,Left,Right'
    $c.CheckOnClick    = $true
    $c.IntegralHeight  = $false

    $map = @{}
    foreach ($row in @($Items | Where-Object { $_ })) {
        $text = $row.Label
        if (-not $text) { $text = "$($row.Value)" }
        if ($map.ContainsKey($text)) { continue }
        $map[$text] = $row.Value
        $i = $c.Items.Add($text)
        if ($Checked -contains $row.Value) { $c.SetItemChecked($i, $true) }
    }
    $c.Tag = @{ Map = $map }

    $Page.Controls.Add($c)
    return $c
}

function Read-WfCheckList {
    <# The values of whatever is ticked, in list order. Possibly empty. #>
    param($List)
    if (-not $List -or -not $List.Tag) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($text in $List.CheckedItems) {
        $value = $List.Tag['Map']["$text"]
        if ($value) { $out.Add($value) }
    }
    return $out.ToArray()
}

function Add-WfCheckBox {
    param($Page, [string] $Text, [int] $Y, [bool] $Checked = $false)
    $c          = New-Object System.Windows.Forms.CheckBox
    $c.Text     = $Text
    $c.Location = New-Object System.Drawing.Point(190, $Y)
    $c.Size     = New-Object System.Drawing.Size(620, 22)
    $c.Checked  = $Checked
    $Page.Controls.Add($c)
    return $c
}

function Add-WfButton {
    param($Page, [string] $Text, [int] $Y, [scriptblock] $OnClick, [int] $X = 190, [int] $Width = 240)
    $b          = New-Object System.Windows.Forms.Button
    $b.Text     = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size     = New-Object System.Drawing.Size($Width, 30)
    $b.Add_Click($OnClick)
    $Page.Controls.Add($b)
    $script:ActionButtons.Add($b)
    return $b
}

# Every grid registers a "make yourself fit the page" action here. They are run
# once from Add_Shown, because a tab page's real size is not known until then,
# and again whenever the page resizes.
$script:GridFit = New-Object System.Collections.Generic.List[object]

function Add-WfGrid {
    param($Page, [int] $Y, [int] $Height = 200)
    $g                     = New-Object System.Windows.Forms.DataGridView
    $g.Location            = New-Object System.Drawing.Point(14, $Y)
    $g.Size                = New-Object System.Drawing.Size(930, $Height)

    # Top, Left and Right -- deliberately NOT Bottom.
    #
    # A Bottom anchor sounds like exactly what a results grid wants, and it is
    # the reason the Updates grid showed three rows with no way to reach the
    # rest. An anchor preserves the gap between the control's edge and the
    # parent's edge AS IT WAS when the control was added -- and when it was
    # added, that gap was negative: at Y=364 with a height of 200 the grid ended
    # 130px past the bottom of a 434px page. Anchoring faithfully preserved the
    # overflow, so the grid's own scrollbars -- which live along its bottom and
    # right edges -- were drawn outside the visible area. There was nothing wrong
    # with the scrollbars. They were simply off the end of the page.
    #
    # So the height is not anchored, it is computed from the page's real size.
    $g.Anchor              = 'Top,Left,Right'

    $g.ReadOnly            = $true
    $g.AllowUserToAddRows  = $false
    $g.AutoSizeColumnsMode = 'AllCells'
    $g.RowHeadersVisible   = $false
    $g.SelectionMode       = 'FullRowSelect'
    $g.ScrollBars          = 'Both'
    $g.ShowCellToolTips    = $true
    $Page.Controls.Add($g)

    $fit = {
        $h = $Page.ClientSize.Height - $g.Top - 12
        # A floor, not a clamp to zero. Tab pages have AutoScroll, so on a short
        # window a small grid you can scroll down to beats a grid squeezed out of
        # existence -- which is what the Recovery and Reference VM grids, sitting
        # at Y=578 and Y=710, would otherwise be.
        if ($h -lt 120) { $h = 120 }
        $w = $Page.ClientSize.Width - 28
        if ($w -lt 320) { $w = 320 }
        if ($g.Height -ne $h) { $g.Height = $h }
        if ($g.Width  -ne $w) { $g.Width  = $w }
    }.GetNewClosure()

    $Page.Add_Resize($fit)
    [void]$script:GridFit.Add($fit)
    return $g
}

function Set-WfGrid {
    <# Flattens any object list into a DataTable of strings. #>
    param($Grid, $Data)

    # Nulls are filtered, not just counted. A job that produced nothing hands
    # $null in here, and @($null).Count is 1 -- so a bare count check passes and
    # the grid is left showing the PREVIOUS result set, with its Path and
    # UpdateId columns still live for whatever button is clicked next.
    $rows = @($Data | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { $Grid.DataSource = $null; return }

    $names = @($rows[0].PSObject.Properties |
               Where-Object { $_.Value -isnot [System.Collections.IEnumerable] -or $_.Value -is [string] } |
               Select-Object -ExpandProperty Name)
    if ($names.Count -eq 0) {
        $names = @($rows[0].PSObject.Properties | Select-Object -ExpandProperty Name)
    }

    $table = New-Object System.Data.DataTable
    foreach ($n in $names) { [void]$table.Columns.Add($n) }

    foreach ($r in $rows) {
        $row = $table.NewRow()
        foreach ($n in $names) {
            $v = $r.$n
            if ($null -eq $v) { $v = '' }
            elseif ($v -is [System.Array]) { $v = ($v -join ', ') }
            $row[$n] = "$v"
        }
        [void]$table.Rows.Add($row)
    }
    $Grid.DataSource = $table

    # AutoSize to the content, then take the widths back under manual control and
    # cap them.
    #
    # "AllCells" on its own sizes a column to its widest cell, and a catalog title
    # is 100 characters -- so Title alone claimed most of the width and pushed
    # TargetBuild, VsImage and InImage off the right-hand edge. Those three
    # columns are the entire point of the search: they say whether a given update
    # is newer than the image. Nobody scrolls sideways to find out.
    #
    # Capped, everything fits at once and the full title is still available in the
    # cell tooltip.
    try {
        $Grid.AutoResizeColumns('AllCells')

        $widths = @()
        foreach ($c in $Grid.Columns) { $widths += [int]$c.Width }
        $Grid.AutoSizeColumnsMode = 'None'

        $cap = 420
        for ($i = 0; $i -lt $Grid.Columns.Count; $i++) {
            if ($widths[$i] -gt $cap) { $widths[$i] = $cap }
            $Grid.Columns[$i].Width = $widths[$i]
        }

        # Slack goes to the widest column rather than sitting as dead space --
        # on a narrow result set that is usually the one worth reading.
        $total = 0; foreach ($w in $widths) { $total += $w }
        $room  = $Grid.ClientSize.Width - 4
        if ($Grid.Columns.Count -gt 0 -and $total -lt $room) {
            $widest = 0
            for ($i = 1; $i -lt $widths.Count; $i++) { if ($widths[$i] -gt $widths[$widest]) { $widest = $i } }
            $Grid.Columns[$widest].Width = $widths[$widest] + ($room - $total)
        }
    }
    catch { }
}

# ============================================================== tab: servicing

$tabServicing = New-WfTab 'Servicing'
Add-WfLabel $tabServicing 'Monthly servicing run' 12 -Heading | Out-Null
Add-WfLabel $tabServicing 'Mounts a working copy, applies updates, injects the driver library, cleans the component store, commits and exports. The mount is discarded on any failure, so a bad run costs a re-copy rather than a re-capture.' 36 | Out-Null

# The source image and index come from the bar above the tabs. Aliased rather
# than duplicated: one control, one value, no chance of two tabs disagreeing
# about which image is being worked on.
$svcSource  = $wfImage
$svcIndex   = $wfIndex

$svcOutput  = Add-WfTextBox $tabServicing 'Output file name' ('{0}-{1}.wim' -f $script:Config['ImageNamePrefix'], (Get-Date -Format 'yyyy-MM')) 82
$svcNotes   = Add-WfTextBox $tabServicing 'Build notes'      '' 112

$svcUpdates = Add-WfCheckBox $tabServicing 'Apply updates from the Updates folder' 150 $true
$svcDrivers = Add-WfCheckBox $tabServicing 'Inject the driver library'             174 $true
$svcPayload = Add-WfCheckBox $tabServicing 'Copy the payload tree'                 198 $false
$svcCleanup = Add-WfCheckBox $tabServicing 'Component cleanup with /ResetBase'     222 $true
$svcExport  = Add-WfCheckBox $tabServicing 'Export a compressed final image'       246 $true

# Unticking cleanup is the one box here whose cost is invisible and large, and it
# lands somewhere that looks unrelated: the commit then has to compress every
# payload the update just superseded, so a dismount runs for hours and the image
# ships several GB bigger. Nothing in the run says why.
#
# So the question is asked HERE, where the decision is being made, and it offers
# the option that was missing rather than just objecting. "Skip it entirely" and
# "/ResetBase" were the only two settings, and the second is the irreversible
# one -- clean-without-ResetBase gets the size back and keeps updates
# uninstallable, which is what someone still iterating on an image wants.
$script:SvcKeepUninstall = $false
$script:SvcCleanupBusy   = $false

$svcCleanup.Add_CheckedChanged({
    # Setting .Checked inside this handler re-enters it. Without the guard the
    # 'No' branch below fires the dialog a second time.
    if ($script:SvcCleanupBusy) { return }
    if ($svcCleanup.Checked) { $script:SvcKeepUninstall = $false; return }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Turning cleanup off means the component store keeps every payload this run supersedes." +
         [Environment]::NewLine + [Environment]::NewLine +
         "The commit has to compress all of it, so the dismount takes considerably longer, and the finished image is several GB larger." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Yes    - leave cleanup off anyway." + [Environment]::NewLine +
         "No     - clean, but without /ResetBase. Reclaims the space and keeps the updates uninstallable from the deployed OS." + [Environment]::NewLine +
         "Cancel - turn cleanup back on (/ResetBase, the usual choice for an image you are about to ship)."),
        'Skip component cleanup?', 'YesNoCancel', 'Warning')

    $script:SvcCleanupBusy = $true
    try {
        if ($answer -eq 'No') {
            $svcCleanup.Checked      = $true
            $script:SvcKeepUninstall = $true
            $svcCleanup.Text         = 'Component cleanup (no /ResetBase -- updates stay uninstallable)'
        }
        elseif ($answer -eq 'Cancel') {
            $svcCleanup.Checked      = $true
            $script:SvcKeepUninstall = $false
            $svcCleanup.Text         = 'Component cleanup with /ResetBase'
        }
        else {
            $script:SvcKeepUninstall = $false
        }
    }
    finally { $script:SvcCleanupBusy = $false }
})

Add-WfButton $tabServicing 'Run servicing' 284 {
    # Read the UI here, on the UI thread. The job only ever sees plain values.
    $src      = $svcSource.Text
    $out      = $svcOutput.Text
    $notes    = $svcNotes.Text
    $idx      = 0
    if (-not [int]::TryParse($svcIndex.Text, [ref]$idx)) { $idx = 1 }
    $noUpd    = -not $svcUpdates.Checked
    $noDrv    = -not $svcDrivers.Checked
    $noClean  = -not $svcCleanup.Checked
    $noExport = -not $svcExport.Checked
    $payload  = $svcPayload.Checked

    # Which models to inject. The whole library is the usual answer -- but a
    # targeted rebuild after adding one model wants a subset, and either way it
    # is picked from what is on disk rather than typed from memory.
    $list    = @()
    $drvFrom = ''
    if (-not $noDrv) {
        $drvFrom = Get-WfGuiDriverRoot
        $pick = Show-WfModelPicker -Title 'Servicing run -- driver models' -DriverRoot $drvFrom
        # Cancel means cancel. Starting a three-hour run because someone shut a
        # dialog would be the wrong reading of it.
        if ($pick.Cancelled) { return }
        $list = @($pick.Models)
    }

    $keepUninst = [bool]$script:SvcKeepUninstall

    Start-WfJob -Title 'Servicing run' -Arguments @{
        src = $src; idx = $idx; out = $out; notes = $notes; models = $list; root = $drvFrom
        noUpd = $noUpd; noDrv = $noDrv; noClean = $noClean; noExport = $noExport; payload = $payload
        keepUninst = $keepUninst
    } -Body {
        $p = @{
            SourceImage = $src; Index = $idx; OutputName = $out; Notes = $notes
            SkipUpdates = $noUpd; SkipDrivers = $noDrv; SkipCleanup = $noClean
            SkipExport = $noExport; ApplyPayload = $payload; KeepUninstall = $keepUninst
        }
        if ($models -and $models.Count -gt 0) { $p['Models'] = $models }
        if ($root) { $p['DriverRoot'] = $root }
        Invoke-WfServicingRun @p
    }
} | Out-Null

Add-WfButton $tabServicing 'Inventory report' 284 {
    $idx = 1
    if (-not [int]::TryParse($svcIndex.Text, [ref]$idx)) { $idx = 1 }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Include the driver, update and feature lists?" +
         [Environment]::NewLine + [Environment]::NewLine +
         "Yes - the full report. Those lists need the image mounted, so it takes minutes." +
         [Environment]::NewLine +
         "No  - identity, edition, build and UBR only. Seconds, nothing mounted."),
        'Image inventory', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }
    $quick = ($answer -eq 'No')

    Start-WfJob -Title 'Image inventory' -Arguments @{
        src = $svcSource.Text; idx = $idx; quick = $quick; features = ($answer -eq 'Yes')
    } -Body {
        Get-WfImageReport -ImagePath $src -Index $idx -Quick:$quick -IncludeFeatures:$features
    }
} -X 444 | Out-Null

Add-WfLabel $tabServicing 'Mount control -- mount once, then every operation below reuses that mount until you dismount.' 330 -Heading | Out-Null

Add-WfButton $tabServicing 'Mount (read-only)' 360 {
    $idx = 1
    if (-not [int]::TryParse($svcIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Mount read-only' -Arguments @{ src = $svcSource.Text; idx = $idx } -Body {
        Mount-WfImage -ImagePath $src -Index $idx -ReadOnly
    }
} -Width 180 | Out-Null

Add-WfButton $tabServicing 'Dismount and commit' 360 {
    Start-WfJob -Title 'Dismount (commit)' -Body { Dismount-WfImage -Save }
} -X 380 -Width 180 | Out-Null

Add-WfButton $tabServicing 'Dismount and discard' 360 {
    Start-WfJob -Title 'Dismount (discard)' -Body { Dismount-WfImage -Discard }
} -X 570 -Width 180 | Out-Null

Add-WfLabel $tabServicing 'Individual operations -- each reuses an open mount if there is one, otherwise mounts, applies one change and commits.' 406 -Heading | Out-Null

Add-WfButton $tabServicing 'Apply updates only' 442 {
    # The Index box is not decoration: an install.wim holds an edition per index,
    # and mounting 1 regardless is a silent wrong answer.
    $idx = 0
    if (-not [int]::TryParse($svcIndex.Text, [ref]$idx)) { $idx = 1 }

    Start-WfJob -Title 'Apply updates' -Arguments @{ src = $svcSource.Text; idx = $idx } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body { Add-WfUpdate -ContinueOnError }
    }
} -X 190 -Width 175 | Out-Null

Add-WfButton $tabServicing 'Inject drivers only' 442 {
    $drvFrom = Get-WfGuiDriverRoot
    $pick = Show-WfModelPicker -Title 'Inject drivers -- driver models' -DriverRoot $drvFrom
    if ($pick.Cancelled) { return }
    $list = @($pick.Models)

    $idx = 0
    if (-not [int]::TryParse($svcIndex.Text, [ref]$idx)) { $idx = 1 }

    # Reuses the Drivers tab's tick box: the same question, and having it in two
    # places with two answers would be worse than having it in one.
    $noMs = $drvNoMs.Checked

    Start-WfJob -Title 'Inject drivers' -Arguments @{
        src = $svcSource.Text; idx = $idx; models = $list; noMs = $noMs; root = $drvFrom
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            if ($models -and $models.Count -gt 0) { Add-WfDriver -Models $models -DriverRoot $root -ExcludeMicrosoft:$noMs }
            else                                  { Add-WfDriver -DriverRoot $root -ExcludeMicrosoft:$noMs }
        }
    }
} -X 375 -Width 175 | Out-Null

Add-WfButton $tabServicing 'Component cleanup' 442 {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Run /ResetBase as well?" + [Environment]::NewLine + [Environment]::NewLine +
         "Yes gives the large size saving but is a one-way door: the applied updates can no longer be uninstalled from the deployed OS." +
         [Environment]::NewLine + [Environment]::NewLine + "No analyses and cleans without ResetBase."),
        'Component cleanup', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }
    $reset = ($answer -eq 'Yes')

    $idx = 0
    if (-not [int]::TryParse($svcIndex.Text, [ref]$idx)) { $idx = 1 }

    Start-WfJob -Title 'Component cleanup' -Arguments @{ src = $svcSource.Text; idx = $idx; reset = $reset } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body { Invoke-WfCleanup -ResetBase:$reset }
    }
} -X 560 -Width 175 | Out-Null

Add-WfButton $tabServicing 'Export / recompress' 480 {
    $default = Join-Path $script:Config['ImageRoot'] 'export.wim'
    $dest = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Destination WIM', 'Export image', $default)
    if (-not $dest) { return }
    Start-WfJob -Title 'Export image' -Arguments @{ src = $svcSource.Text; dest = $dest } -Body {
        Export-WfImage -SourcePath $src -DestinationPath $dest -Force
    }
} -X 190 -Width 175 | Out-Null

# ================================================================ tab: drivers

$tabDrivers = New-WfTab 'Drivers'
Add-WfLabel $tabDrivers 'Driver library' 12 -Heading | Out-Null
Add-WfLabel $tabDrivers 'One folder per hardware model, harvested from a known-good reference machine of that model rather than assembled from vendor driver packs.' 36 | Out-Null

# The library this tab -- and every driver operation in the window -- works
# against. Prefilled from the configuration, and overridable here.
#
# Why here rather than only in Settings: a workstation has one configured
# DriverRoot and an engineer regularly has more than one library. Last quarter's,
# a colleague's, one on a share for a particular customer's fleet. Editing the
# setting to service one image and remembering to put it back afterwards is
# exactly how the wrong drivers get into an image, and nothing downstream would
# ever tell you.
#
# Clearing the box falls back to the configured folder, so there is always a
# defined answer and it is visible without opening another tab.
$drvRoot  = Add-WfTextBox  $tabDrivers 'Driver library folder' $script:Config['DriverRoot'] 78 `
                -PickFolder -PickFolderTitle 'Driver library folder -- one subfolder per hardware model'
$drvModel = Add-WfTextBox  $tabDrivers 'Model folder name' '' 108

function Get-WfGuiDriverRoot {
    <#
        The driver library every operation in this window uses: whatever is in
        the box on the Drivers tab, falling back to the configured folder when it
        is empty.

        Read on the UI thread and passed into jobs as a plain string -- a job
        body runs in its own runspace and cannot see a WinForms control, and a
        job that quietly used the configured folder instead of the one on screen
        would be the worst possible way to get this wrong.
    #>
    $v = ''
    if ($drvRoot) { $v = "$($drvRoot.Text)".Trim() }
    if (-not $v)  { $v = [string]$script:Config['DriverRoot'] }
    return $v
}

$drvForce = Add-WfCheckBox $tabDrivers 'Replace the folder if it already exists' 138 $false

# The ones Windows Update handed this machine rather than the ones the vendor
# shipped. An image at the same patch level already has them; a terminal that
# never reaches Windows Update may not. Off by default -- nothing is dropped
# from a harvest without being asked for.
$drvNoMs  = Add-WfCheckBox $tabDrivers 'Leave out Microsoft-provided drivers' 166 $false

# The driver store keeps every version it has ever staged and Export-WindowsDriver
# exports all of them -- nine copies of one Bluetooth driver is normal on a
# year-old machine. Ticked by default: shipping all of them is precisely what
# harvesting from a known-good machine was supposed to avoid.
$drvNewest = Add-WfCheckBox $tabDrivers 'Keep only the newest version of each driver' 194 $true

Add-WfButton $tabDrivers 'Harvest this machine' 230 {
    Start-WfJob -Title 'Harvest drivers' -Arguments @{
        name = $drvModel.Text; force = $drvForce.Checked; root = (Get-WfGuiDriverRoot)
        noMs = $drvNoMs.Checked; keepAll = (-not $drvNewest.Checked)
    } -Body {
        $n = $name
        if (-not $n) {
            $cs = Get-CimInstance Win32_ComputerSystem
            $n  = (('{0}_{1}' -f $cs.Manufacturer, $cs.Model) -replace '[^A-Za-z0-9\.\-]+','_').Trim('_')
        }
        # -Destination IS the library root for a harvest: this is the folder the
        # model subfolder is created in.
        Export-WfModelDriver -ModelName $n -Destination $root -KeepAllVersions:$keepAll `
                             -ExcludeMicrosoft:$noMs -Force:$force
    }
} | Out-Null

Add-WfButton $tabDrivers 'Refresh library view' 230 {
    $root = Get-WfGuiDriverRoot
    $lib  = Get-WfDriverLibrary -DriverRoot $root
    Set-WfGrid $drvGrid $lib
    $statusLabel.Text = "Library: $(@($lib).Count) model(s)"
    # Which folder these rows came from, said once rather than assumed -- the box
    # above can point somewhere other than the configured library.
    Write-WfGuiLog "Driver library read from $root" ([System.Drawing.Color]::LightSteelBlue)
} -X 444 | Out-Null

$drvGrid = Add-WfGrid $tabDrivers 272 162

Add-WfButton $tabDrivers 'Remove selected model' 436 {
    if ($drvGrid.SelectedRows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a model row first.', 'Nothing selected', 'OK', 'Information')
        return
    }
    # The grid also receives Compare-WfDriver results, which have no Model column
    if (-not $drvGrid.Columns.Contains('Model')) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'The grid is not showing the driver library. Click "Refresh library view" first.',
            'Wrong view', 'OK', 'Information')
        return
    }
    $model = [string]$drvGrid.SelectedRows[0].Cells['Model'].Value
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Remove '$model' from the driver library?`n`nExisting WIMs are not touched -- the image only shrinks on the next servicing run.",
        'Confirm', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        Start-WfJob -Title "Remove $model" -Arguments @{ model = $model; root = (Get-WfGuiDriverRoot) } -Body {
            Remove-WfModelDriver -Model $model -DriverRoot $root -Confirm:$false
        }
    }
} -X 14 -Width 190 | Out-Null

Add-WfButton $tabDrivers 'Remove superseded duplicates' 436 {
    if ($drvGrid.SelectedRows.Count -gt 0 -and $drvGrid.Columns.Contains('Model')) {
        $model = @([string]$drvGrid.SelectedRows[0].Cells['Model'].Value)
        $scope = $model[0]
    }
    else {
        $model = @()
        $scope = 'the whole library'
    }

    # Listed before anything is deleted. -WhatIf is the only way to be sure the
    # tool agrees with you while that is still a cheap thing to find out.
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("The driver store keeps every version of a package it has ever staged, and a harvest exports all of them. This keeps the newest of each and removes the rest, from $scope." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Packages with different inf names are never compared, so nothing that is genuinely a different driver can be removed." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Yes - remove them." + [Environment]::NewLine +
         "No  - just list what would go."),
        'Superseded duplicates', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }
    $dryRun = ($answer -eq 'No')

    Start-WfJob -Title 'Superseded duplicates' -Arguments @{
        model = $model; dry = $dryRun; root = (Get-WfGuiDriverRoot)
    } -Body {
        if ($dry) { Remove-WfDuplicateDriver -Model $model -DriverRoot $root -WhatIf }
        else      { Remove-WfDuplicateDriver -Model $model -DriverRoot $root -Confirm:$false }
    } -OnComplete {
        param($rows)
        Set-WfGrid $drvGrid $rows
    }
} -X 214 -Width 220 | Out-Null

Add-WfButton $tabDrivers 'Compare image to library' 436 {
    $idx = 0
    if (-not [int]::TryParse($svcIndex.Text, [ref]$idx)) { $idx = 1 }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Mount the image to read its drivers?" +
         [Environment]::NewLine + [Environment]::NewLine +
         "Yes - mount it. Minutes, and the versions come straight from DISM." +
         [Environment]::NewLine +
         "No  - read the driver list out of the image's registry instead. Seconds, but some versions may read as unknown, because Windows stores them there in an undocumented form." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Uses the image and index on the Servicing tab."),
        'Compare drivers', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }
    $quick = ($answer -eq 'No')

    Start-WfJob -Title 'Compare drivers' -Arguments @{
        src = $svcSource.Text; idx = $idx; quick = $quick; root = (Get-WfGuiDriverRoot)
    } -Body {
        Compare-WfDriver -ImagePath $src -Index $idx -DriverRoot $root -Quick:$quick |
            Where-Object { $_.Status -ne 'Match' } |
            Select-Object Inf, LibraryVersion, ImageVersion, Status, Models, ReadFrom
    }
} -X 444 | Out-Null

# =========================================================== tab: boot and WDS

$tabBoot = New-WfTab 'Boot and WDS'
Add-WfLabel $tabBoot 'WinPE boot image' 12 -Heading | Out-Null
Add-WfLabel $tabBoot 'A model whose NIC driver is missing here never PXE-boots; one missing its storage driver boots but finds no disk. Either way it silently drops out of the rollout. Check the index first: a copype-built custom PE is index 1, a Microsoft media boot.wim boots index 2.' 36 | Out-Null

$bootPath  = Add-WfTextBox $tabBoot 'Boot image' $script:Config['PeImage'] 98 -Browse -PickFolderIsPe
$bootIndex = Add-WfTextBox $tabBoot 'Index'      '1' 128 -PickIndex -IndexFor $bootPath
$bootOut   = Add-WfTextBox $tabBoot 'Export to'  (Join-Path $script:Config['ImageRoot'] ('WinPE-POS-{0}.wim' -f (Get-Date -Format 'yyyy-MM'))) 158

Add-WfButton $tabBoot 'Show indexes' 196 {
    # Not a background job: this is a header read, so it is fast enough to run on
    # the click, and the answer belongs in front of the operator rather than
    # scrolled past in the log pane.
    $picked = Show-WfIndexPicker -ImagePath $bootPath.Text -Reason 'Which index are you injecting drivers into?'
    if ($null -ne $picked) {
        $bootIndex.Text = "$picked"
        Write-WfGuiLog "Boot image index set to $picked" ([System.Drawing.Color]::LightSteelBlue)
    }
} -Width 180 | Out-Null

Add-WfButton $tabBoot 'Inject PE drivers' 196 {
    $idx = 0
    # TryParse writes 0 into the ref on failure, so the default has to be applied
    # after the test, not before it -- otherwise a blank box passes -Index 0.
    if (-not [int]::TryParse($bootIndex.Text, [ref]$idx)) { $idx = 1 }

    $drvFrom = Get-WfGuiDriverRoot
    $pick = Show-WfModelPicker -Title 'Inject PE drivers -- driver models' -DriverRoot $drvFrom
    if ($pick.Cancelled) { return }
    $list = @($pick.Models)

    Start-WfJob -Title 'Inject PE drivers' -Arguments @{
        p = $bootPath.Text; idx = $idx; out = $bootOut.Text; models = $list; root = $drvFrom
    } -Body {
        $prm = @{ BootImagePath = $p; Index = $idx; ExportPath = $out; WorkingCopy = $true }
        if ($models -and $models.Count -gt 0) { $prm['Models'] = $models }
        if ($root) { $prm['DriverRoot'] = $root }
        Add-WfBootDriver @prm
    }
} -X 380 -Width 180 | Out-Null

Add-WfLabel $tabBoot 'Publish to WDS' 250 -Heading | Out-Null
Add-WfLabel $tabBoot 'Copies, verifies by SHA256, writes a sidecar describing the build, and prunes older published copies to the retention count.' 274 | Out-Null

$pubPath  = Add-WfTextBox  $tabBoot 'Image to publish' $script:Config['BaseImage'] 310 -Browse
$pubNotes = Add-WfTextBox  $tabBoot 'Notes'            '' 340
$pubBoot  = Add-WfCheckBox $tabBoot 'This is a boot image (publish to the WDS boot share)' 370 $false

Add-WfButton $tabBoot 'Publish' 406 {
    $p       = $pubPath.Text
    $notes   = $pubNotes.Text
    $isBoot  = $pubBoot.Checked
    $share   = $script:Config['WdsShare']
    if ($isBoot) { $share = $script:Config['WdsBootShare'] }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Publish $(Split-Path $p -Leaf) to`n$share ?", 'Confirm publish', 'YesNo', 'Question')
    if ($answer -eq 'Yes') {
        Start-WfJob -Title 'Publish image' -Arguments @{
            p = $p; isBoot = $isBoot; notes = $notes
        } -Body {
            Publish-WfImage -ImagePath $p -BootImage:$isBoot -Notes $notes -Confirm:$false
        }
    }
} | Out-Null

# --------------------------------------------- your own software inside WinPE
Add-WfLabel $tabBoot 'Your own software in WinPE' 460 -Heading | Out-Null
Add-WfLabel $tabBoot 'WinPE boots into memory, and the whole image has to fit in a contiguous block of physical RAM plus its scratch space -- so every megabyte put INTO the boot image is a megabyte every terminal has to find. Small tools go in; anything large should live on the media and be found at run time, which is what the payload folder below does. Two things WinPE will not do whatever you try: run an .msi (there is no Windows Installer service in it) and run a 32-bit binary in a 64-bit PE (there is no WoW64). Both are checked before anything is copied.' 484 | Out-Null

$peToolSrc  = Add-WfTextBox $tabBoot 'Tool folder or file' '' 570 `
                  -PickFolder -PickFolderTitle 'The folder holding your tool'
$peToolCmd  = Add-WfTextBox $tabBoot 'What to run inside it (blank for none)' '' 600
$pePayload  = Add-WfTextBox $tabBoot 'Payload folder on the media (e.g. WimForge\Tools)' '' 630
$pePayCmd   = Add-WfTextBox $tabBoot 'What to run inside the payload' '' 660
$peRegion   = Add-WfTextBox $tabBoot 'Region script to call (from the Region section)' '' 690

Add-WfButton $tabBoot 'What is in this boot image?' 728 {
    $idx = 0
    if (-not [int]::TryParse($bootIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Boot image report' -Arguments @{ p = $bootPath.Text; idx = $idx } -Body {
        Get-WfPeReport -BootImagePath $p -Index $idx
    }
} -X 14 -Width 200 | Out-Null

Add-WfButton $tabBoot 'Optional components...' 728 {
    $idx = 0
    if (-not [int]::TryParse($bootIndex.Text, [ref]$idx)) { $idx = 1 }

    $available = @()
    try { $available = @(Get-WfPeOptionalComponent | Where-Object { $_.Present }) } catch { }
    if ($available.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("No optional components are available on this machine." + [Environment]::NewLine + [Environment]::NewLine +
             "They come from the Windows ADK's WinPE add-on, which is a separate download from the ADK itself. Drivers, tools and startnet.cmd all still work without it."),
            'No ADK WinPE add-on', 'OK', 'Information')
        return
    }

    $pick = Show-WfListPicker -Title 'WinPE optional components' `
                -Prompt 'Tick what this boot image needs. Dependencies are added for you, in Microsoft''s documented order -- and PowerShell costs over a hundred megabytes of RAM on every terminal that boots this.' `
                -Items ($available | ForEach-Object {
                    [pscustomobject]@{ Value = $_.Name
                                       Label = ('{0,-26} {1,6} MB  {2}' -f $_.Name, $_.SizeMB, $_.What) } })
    if ($pick.Cancelled -or $pick.Values.Count -eq 0) { return }

    Start-WfJob -Title 'PE optional components' -Arguments @{
        p = $bootPath.Text; idx = $idx; comps = $pick.Values
    } -Body {
        Add-WfPeOptionalComponent -Component $comps -BootImagePath $p -Index $idx -Confirm:$false
    }
} -X 224 -Width 200 | Out-Null

Add-WfButton $tabBoot 'Add the tool to the image' 728 {
    if (-not $peToolSrc.Text) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Point the tool box above at a folder or a file first.', 'Nothing to add', 'OK', 'Information')
        return
    }
    $idx = 0
    if (-not [int]::TryParse($bootIndex.Text, [ref]$idx)) { $idx = 1 }

    Start-WfJob -Title 'PE tool' -Arguments @{
        p = $bootPath.Text; idx = $idx; src = $peToolSrc.Text; cmd = $peToolCmd.Text
    } -Body {
        $toolArgs = @{ Source = $src; BootImagePath = $p; Index = $idx; Force = $true; Confirm = $false }
        if ($cmd) { $toolArgs['Command'] = $cmd }
        Add-WfPeTool @toolArgs
    }
} -X 434 -Width 200 | Out-Null

Add-WfButton $tabBoot 'Tools in this image' 728 {
    $idx = 0
    if (-not [int]::TryParse($bootIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'PE tools' -Arguments @{ p = $bootPath.Text; idx = $idx } -Body {
        Get-WfPeTool -BootImagePath $p -Index $idx
    }
} -X 644 -Width 200 | Out-Null

Add-WfButton $tabBoot 'Build startnet.cmd' 764 {
    $idx = 0
    if (-not [int]::TryParse($bootIndex.Text, [ref]$idx)) { $idx = 1 }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Launch every tool in this boot image that recorded a command?" + [Environment]::NewLine + [Environment]::NewLine +
         "wpeinit always goes first whatever you choose -- it installs the Plug and Play devices and brings up the network, so anything above it runs on a machine with no drivers and looks broken for reasons that have nothing to do with it." + [Environment]::NewLine + [Environment]::NewLine +
         "Yes - launch the tools." + [Environment]::NewLine +
         "No  - just wpeinit and the payload folder."),
        'startnet.cmd', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }

    Start-WfJob -Title 'PE startnet' -Arguments @{
        p = $bootPath.Text; idx = $idx; all = ($answer -eq 'Yes')
        payload = $pePayload.Text; paycmd = $pePayCmd.Text; region = $peRegion.Text
    } -Body {
        $netArgs = @{ BootImagePath = $p; Index = $idx; Confirm = $false }
        if ($all)     { $netArgs['AllTools']       = $true }
        if ($payload) { $netArgs['PayloadFolder']  = $payload }
        if ($paycmd)  { $netArgs['PayloadCommand'] = $paycmd }
        if ($region)  { $netArgs['RegionScript']   = $region }
        New-WfPeStartnet @netArgs
    }
} -X 14 -Width 200 | Out-Null

Add-WfButton $tabBoot 'Scratch space...' 764 {
    $idx = 0
    if (-not [int]::TryParse($bootIndex.Text, [ref]$idx)) { $idx = 1 }

    $pick = Show-WfListPicker -Title 'WinPE scratch space' -Single `
                -Prompt 'The writeable part of the RAM disk. Anything your tools write comes out of this, and running out shows up as a disk-full error on a drive nobody thinks of as a drive. Only these five values exist.' `
                -Items (@(32, 64, 128, 256, 512) | ForEach-Object {
                    $note = ''
                    if ($_ -eq 512) { $note = '   the default on a machine with more than 1GB of RAM' }
                    if ($_ -eq 32)  { $note = '   the default below that' }
                    [pscustomobject]@{ Value = "$_"; Label = ('{0,4} MB{1}' -f $_, $note) } })
    if ($pick.Cancelled -or $pick.Values.Count -eq 0) { return }

    $size = 0
    if (-not [int]::TryParse(@($pick.Values)[0], [ref]$size)) { return }

    Start-WfJob -Title 'PE scratch space' -Arguments @{ p = $bootPath.Text; idx = $idx; size = $size } -Body {
        Set-WfPeScratchSpace -SizeMB $size -BootImagePath $p -Index $idx -Confirm:$false
    }
} -X 224 -Width 200 | Out-Null

Add-WfButton $tabBoot 'Replace the PE shell...' 764 {
    $idx = 0
    if (-not [int]::TryParse($bootIndex.Text, [ref]$idx)) { $idx = 1 }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Run an application instead of the WinPE command prompt?" + [Environment]::NewLine + [Environment]::NewLine +
         "Yes    - name the application. It goes through a generated wrapper that calls wpeinit first, because replacing the shell means startnet.cmd never runs -- and startnet.cmd is what brings up the drivers and the network." + [Environment]::NewLine +
         "No     - put the normal command prompt back." + [Environment]::NewLine +
         "Cancel - leave it alone."),
        'PE shell', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }

    if ($answer -eq 'No') {
        Start-WfJob -Title 'PE shell' -Arguments @{ p = $bootPath.Text; idx = $idx } -Body {
            Set-WfPeShell -Remove -BootImagePath $p -Index $idx -Confirm:$false
        }
        return
    }

    $cmd = [Microsoft.VisualBasic.Interaction]::InputBox(
        ("The application, as the terminal will see it." + [Environment]::NewLine +
         "A tool added above lives at %SystemRoot%\Tools\<name>\<command>."),
        'PE shell', '%SystemRoot%\Tools\')
    if (-not "$cmd".Trim()) { return }

    Start-WfJob -Title 'PE shell' -Arguments @{ p = $bootPath.Text; idx = $idx; cmd = $cmd } -Body {
        Set-WfPeShell -Command $cmd -BootImagePath $p -Index $idx -Confirm:$false
    }
} -X 434 -Width 200 | Out-Null

Add-WfButton $tabBoot 'Where is the ADK?' 764 {
    Start-WfJob -Title 'ADK WinPE components' -Body {
        $root = Get-WfAdkWinPeRoot
        if ($root) { Write-WfLog "Optional components: $root" -Level OK }
        Get-WfPeOptionalComponent | Select-Object Name, Present, SizeMB, Needs, What
    }
} -X 644 -Width 200 | Out-Null

Add-WfButton $tabBoot 'Make a menu HTA...' 800 {
    # A known-good starting point. An HTA in WinPE has two documented ways to
    # fail before anyone's own HTML is in question, so debugging a first one
    # against an untested pipeline means not knowing which of three things is
    # wrong.
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter   = 'HTML applications (*.hta)|*.hta|All files (*.*)|*.*'
    $sfd.FileName = 'menu.hta'
    if ($sfd.ShowDialog() -ne 'OK') { return }

    $title = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Heading and window title for the menu.', 'Menu HTA', 'Deployment')
    if (-not "$title".Trim()) { return }

    $raw = [Microsoft.VisualBasic.Interaction]::InputBox(
        ('Buttons, one per line, as  Label = command' + [Environment]::NewLine +
         'For example:   Deploy = X:\deploy.cmd' + [Environment]::NewLine +
         '               Command prompt = cmd.exe'),
        'Menu buttons', 'Command prompt = cmd.exe')
    if (-not "$raw".Trim()) { return }

    $items = @()
    foreach ($line in @($raw -split '[\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $at = $line.IndexOf('=')
        if ($at -lt 1) { continue }
        $items += @{ Label = $line.Substring(0, $at).Trim(); Command = $line.Substring($at + 1).Trim() }
    }
    if ($items.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'No usable lines. Each one is  Label = command.', 'Nothing to build', 'OK', 'Information')
        return
    }

    Start-WfJob -Title 'Menu HTA' -Arguments @{ path = $sfd.FileName; title = $title; items = $items } -Body {
        New-WfPeMenuHta -Title $title -Item $items -Path $path -Confirm:$false
    }
} -X 14 -Width 200 | Out-Null

Add-WfButton $tabBoot 'How would this start?' 800 {
    # The question behind every tool that goes in and then does nothing.
    $what = [Microsoft.VisualBasic.Interaction]::InputBox(
        ('A file name -- menu.hta, run.cmd, Diag.exe, deploy.ps1.' + [Environment]::NewLine +
         'Says how WinPE would start it and what has to be in the image first.'),
        'How would this start?', $peToolCmd.Text)
    if (-not "$what".Trim()) { return }

    Start-WfJob -Title 'Launch rule' -Arguments @{ what = $what } -Body {
        $how = Get-WfPeLaunchCommand -Command $what -Path ('%SystemRoot%\Tools\<tool>\' + $what)
        Write-WfLog ("{0}: {1}" -f $what, $how.Kind) -Level OK
        if ($how.Line)     { Write-WfLog ("  startnet would say:  {0}" -f $how.Line) -Level INFO }
        if ($how.Requires) { Write-WfLog ("  needs {0} in the boot image" -f $how.Requires) -Level WARN }
        if ($how.Note)     { Write-WfLog ("  {0}" -f $how.Note) -Level INFO }
        $how
    }
} -X 224 -Width 200 | Out-Null

Add-WfButton $tabBoot 'Fix HTAs (legacy JScript)' 800 {
    $idx = 0
    if (-not [int]::TryParse($bootIndex.Text, [ref]$idx)) { $idx = 1 }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Turn the legacy JScript engine back on for mshta in this boot image?" + [Environment]::NewLine + [Environment]::NewLine +
         "Microsoft replaced the engine in the ADK for Windows 11 22H2. An HTA written for the old one comes up with ""An error has occurred in the script on this page"" and nothing else to go on." + [Environment]::NewLine + [Environment]::NewLine +
         "Adding an HTA with the tool button above does this for you -- this is for an image that already has one and started failing after an ADK upgrade." + [Environment]::NewLine + [Environment]::NewLine +
         "No puts it back on the modern engine."),
        'HTAs and the JScript engine', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }

    Start-WfJob -Title 'PE JScript engine' -Arguments @{
        p = $bootPath.Text; idx = $idx; undo = ($answer -eq 'No')
    } -Body {
        $jsArgs = @{ BootImagePath = $p; Index = $idx; Confirm = $false }
        if ($undo) { $jsArgs['Remove'] = $true }
        Enable-WfPeLegacyJScript @jsArgs
    }
} -X 434 -Width 200 | Out-Null

# ============================================================== tab: customise

$tabCust = New-WfTab 'Customise'
Add-WfLabel $tabCust 'Offline customisation' 12 -Heading | Out-Null
Add-WfLabel $tabCust 'Each button applies one change to the working image shown above. If it is already mounted the change goes straight in and the mount stays open; otherwise the image is mounted, changed and committed. A failure always discards.' 36 | Out-Null

# Same image and index as everywhere else -- see the bar above the tabs.
$custImage    = $wfImage
$custIndex    = $wfIndex

$custReg      = Add-WfTextBox $tabCust '.reg file'      '' 76
$custCert     = Add-WfTextBox $tabCust 'Certificate'    '' 106

$custStoreLbl          = New-Object System.Windows.Forms.Label
$custStoreLbl.Text     = 'Certificate store'
$custStoreLbl.Location = New-Object System.Drawing.Point(14, 140)
$custStoreLbl.Size     = New-Object System.Drawing.Size(170, 20)
$tabCust.Controls.Add($custStoreLbl)

$custStore              = New-Object System.Windows.Forms.ComboBox
$custStore.Location     = New-Object System.Drawing.Point(190, 136)
$custStore.Size         = New-Object System.Drawing.Size(200, 22)
$custStore.DropDownStyle = 'DropDownList'
[void]$custStore.Items.AddRange(@('Root','CA','TrustedPublisher'))
$custStore.SelectedIndex = 0
$tabCust.Controls.Add($custStore)
$custUnattend = Add-WfTextBox $tabCust 'unattend.xml'   $script:Config['UnattendPath'] 170
$custFeature  = Add-WfTextBox $tabCust 'Feature name'   'NetFx3' 200
$custSource   = Add-WfTextBox $tabCust 'Feature source' '' 230

Add-WfLabel $tabCust 'In a .reg file, target HKEY_LOCAL_MACHINE\WF_SOFTWARE, WF_SYSTEM or WF_DEFAULT -- those are the temporary keys the offline hives are loaded under.' 262 | Out-Null

Add-WfButton $tabCust 'Apply .reg file' 296 {
    $idx = 0
    if (-not [int]::TryParse($custIndex.Text, [ref]$idx)) { $idx = 1 }

    Start-WfJob -Title 'Apply .reg file' -Arguments @{
        img = $custImage.Text; idx = $idx; reg = $custReg.Text
    } -Body {
        Invoke-WfWithMount -ImagePath $img -Index $idx -Body { Invoke-WfRegistryEdit -RegFile $reg }
    }
} -Width 180 | Out-Null

Add-WfButton $tabCust 'Copy payload tree' 296 {
    $idx = 0
    if (-not [int]::TryParse($custIndex.Text, [ref]$idx)) { $idx = 1 }

    Start-WfJob -Title 'Copy payload' -Arguments @{ img = $custImage.Text; idx = $idx } -Body {
        Invoke-WfWithMount -ImagePath $img -Index $idx -Body { Copy-WfPayload }
    }
} -X 380 -Width 180 | Out-Null

Add-WfButton $tabCust 'Import certificate' 296 {
    $idx = 0
    if (-not [int]::TryParse($custIndex.Text, [ref]$idx)) { $idx = 1 }

    Start-WfJob -Title 'Import certificate' -Arguments @{
        img = $custImage.Text; idx = $idx; cert = $custCert.Text; store = "$($custStore.SelectedItem)"
    } -Body {
        Invoke-WfWithMount -ImagePath $img -Index $idx -Body { Import-WfCertificate -CertificatePath $cert -Store $store }
    }
} -X 570 -Width 180 | Out-Null

Add-WfButton $tabCust 'Check unattend.xml' 336 {
    Start-WfJob -Title 'Check unattend' -Arguments @{ path = $custUnattend.Text } -Body {
        Test-WfUnattend -Path $path
    }
} -Width 180 | Out-Null

Add-WfButton $tabCust 'Place unattend.xml' 336 {
    $idx = 0
    if (-not [int]::TryParse($custIndex.Text, [ref]$idx)) { $idx = 1 }

    Start-WfJob -Title 'Place unattend' -Arguments @{
        img = $custImage.Text; idx = $idx; path = $custUnattend.Text
    } -Body {
        Invoke-WfWithMount -ImagePath $img -Index $idx -Body { Set-WfUnattend -Path $path }
    }
} -X 380 -Width 180 | Out-Null

Add-WfButton $tabCust 'Enable feature' 336 {
    $idx = 0
    if (-not [int]::TryParse($custIndex.Text, [ref]$idx)) { $idx = 1 }

    Start-WfJob -Title 'Enable feature' -Arguments @{
        img = $custImage.Text; idx = $idx; feature = $custFeature.Text; src = $custSource.Text
    } -Body {
        Invoke-WfWithMount -ImagePath $img -Index $idx -Body { Add-WfCapability -Feature $feature -Source $src }
    }
} -X 570 -Width 180 | Out-Null

# ================================================================== tab: build

$tabBuild = New-WfTab 'Build'
Add-WfLabel $tabBuild 'Capture a new base image' 12 -Heading | Out-Null
Add-WfLabel $tabBuild 'Sysprep the reference VM with /generalize /oobe /shutdown, leave it powered off, then point this at its VHDX. The disk is mounted read-only, so the VM is never modified and no WinPE boot is needed.' 36 | Out-Null

$capVhdx  = Add-WfTextBox $tabBuild 'Reference VHDX' '' 92
$capNotes = Add-WfTextBox $tabBuild 'Notes'          '' 122

Add-WfButton $tabBuild 'Capture from VHDX' 158 {
    Start-WfJob -Title 'Capture base image' -Arguments @{
        vhdx = $capVhdx.Text; notes = $capNotes.Text
    } -Body { New-WfCapture -VhdxPath $vhdx -Notes $notes }
} -Width 180 | Out-Null

Add-WfButton $tabBuild 'Capture from a drive letter' 158 {
    # For when you really are sitting in WinPE in front of a physical reference
    # machine rather than capturing a powered-off VM.
    $drive = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Drive letter of the sysprepped volume to capture', 'Capture from drive', 'C:')
    if (-not $drive) { return }
    Start-WfJob -Title 'Capture base image' -Arguments @{
        drive = $drive; notes = $capNotes.Text
    } -Body { New-WfCapture -SourceDrive $drive -Notes $notes }
} -X 380 -Width 200 | Out-Null

Add-WfLabel $tabBuild 'USB deployment media' 210 -Heading | Out-Null
Add-WfLabel $tabBuild 'For third-party sites with no WDS. FAT32 boot partition because UEFI firmware can only read FAT32, NTFS image partition because the WIM is larger than FAT32 allows. This ERASES the target disk.' 234 | Out-Null

$usbDisk  = Add-WfTextBox $tabBuild 'USB disk number'    '' 290
$usbPe    = Add-WfTextBox $tabBuild 'WinPE media folder' 'C:\WinPE_amd64' 320
$usbImage = Add-WfTextBox $tabBuild 'Image'              $script:Config['BaseImage'] 350 -Browse

Add-WfButton $tabBuild 'List USB disks' 388 {
    Start-WfJob -Title 'USB disks' -Body {
        Get-Disk | Where-Object { $_.BusType -eq 'USB' } |
            Select-Object Number, FriendlyName, @{n='GB';e={[math]::Round($_.Size/1GB,1)}}, BusType
    }
} -Width 180 | Out-Null

Add-WfButton $tabBuild 'Build USB media' 388 {
    $num = 0
    if (-not [int]::TryParse($usbDisk.Text, [ref]$num)) {
        [void][System.Windows.Forms.MessageBox]::Show('Enter the USB disk number first.', 'Missing disk number', 'OK', 'Warning')
        return
    }
    $pe  = $usbPe.Text
    $img = $usbImage.Text

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "This ERASES disk $num completely.`n`nEverything on it will be lost. Continue?",
        'Erase disk', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        Start-WfJob -Title 'Build USB media' -Arguments @{
            num = $num; pe = $pe; img = $img
        } -Body {
            New-WfUsbMedia -DiskNumber $num -PeMediaPath $pe -ImagePath $img -Confirm:$false
        }
    }
} -X 380 -Width 180 | Out-Null

Add-WfLabel $tabBuild 'Validate a deployed machine' 440 -Heading | Out-Null
Add-WfLabel $tabBuild 'Run this on the freshly imaged terminal itself: device health, generic-driver fallback, activation, domain trust, hostname, free space, pending reboot, time source.' 464 | Out-Null

$valPattern = Add-WfTextBox $tabBuild 'Hostname pattern' '' 510
$valReport  = Add-WfTextBox $tabBuild 'Report file'      '' 540

Add-WfButton $tabBuild 'Validate this machine' 578 {
    Start-WfJob -Title 'Validate machine' -Arguments @{
        pattern = $valPattern.Text; report = $valReport.Text
    } -Body { Test-WfDeployedMachine -ExpectedHostnamePattern $pattern -ReportPath $report }
} | Out-Null

# ------------------------------------------- a reference image from clean media
Add-WfLabel $tabBuild 'Reference image from clean media' 620 -Heading | Out-Null
Add-WfLabel $tabBuild 'The alternative to re-servicing last month''s output. Re-servicing accumulates state: every language pack and feature stays at whatever level it went in, and eventually a cumulative arrives that cannot reconcile them. Building from clean media has no such history. Servicing stack, then languages, then features, then the cumulative update LAST -- across winre.wim, boot.wim and install.wim, in Microsoft''s order. Nothing is committed if any step fails; every mount is discarded on the way out, so a failed run leaves the media as it found it. This takes hours.' 644 | Out-Null

$refMedia  = Add-WfTextBox $tabBuild 'Extracted media (holds \sources)' '' 730 `
                 -PickFolder -PickFolderTitle 'The extracted installation media'
$refLcu    = Add-WfTextBox $tabBuild 'Cumulative update .msu' '' 760 -Browse
$refFod    = Add-WfTextBox $tabBuild 'Features on Demand ISO'  '' 790 `
                 -PickFolder -PickFolderTitle 'The mounted Features on Demand ISO'
$refCaps   = Add-WfTextBox $tabBuild 'Capabilities (comma separated, blank for none)' '' 820
$refIndex  = Add-WfTextBox $tabBuild 'install.wim indexes (blank for all)' '' 850
$refOut    = Add-WfTextBox $tabBuild 'Output .wim (blank for the default)' '' 880 -Browse
$refKeep   = Add-WfCheckBox $tabBuild 'Leave the updates uninstallable (skip /ResetBase)' 910 $false

Add-WfButton $tabBuild 'Build the reference image' 944 {
    if (-not $refMedia.Text -or -not $refLcu.Text) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'The extracted media and the cumulative update are both required.',
            'Not enough to start', 'OK', 'Information')
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("This services winre.wim, boot.wim and every chosen index of install.wim in one run." + [Environment]::NewLine + [Environment]::NewLine +
         "It takes hours, and it writes to the media folder. Work on a copy of the extracted media, not on the only one you have." + [Environment]::NewLine + [Environment]::NewLine +
         "Start it?"),
        'Reference image', 'OKCancel', 'Warning')
    if ($answer -ne 'OK') { return }

    $caps = @($refCaps.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $idx  = @()
    foreach ($part in @($refIndex.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $n = 0
        if ([int]::TryParse($part, [ref]$n)) { $idx += $n }
    }

    Start-WfJob -Title 'Reference image' -Arguments @{
        media = $refMedia.Text; lcu = $refLcu.Text; fod = $refFod.Text
        caps = $caps; idx = $idx; out = $refOut.Text; keep = $refKeep.Checked
        notes = $capNotes.Text
    } -Body {
        $refArgs = @{ MediaPath = $media; LcuPath = $lcu }
        if ($fod)            { $refArgs['FodSource']     = $fod }
        if ($caps.Count)     { $refArgs['Capability']    = $caps }
        if ($idx.Count)      { $refArgs['Index']         = $idx }
        if ($out)            { $refArgs['OutputPath']    = $out }
        if ($keep)           { $refArgs['KeepUninstall'] = $true }
        if ($notes)          { $refArgs['Notes']         = $notes }
        New-WfReferenceImage @refArgs
    }
} -X 14 -Width 220 | Out-Null

Add-WfButton $tabBuild 'Refresh Setup on the media' 944 {
    # The step that gets left out, because nothing about the media looks wrong
    # without it -- right up until Setup refuses to install.
    if (-not $refMedia.Text) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Point the media box above at the extracted media first.', 'No media', 'OK', 'Information')
        return
    }

    $du = ''
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Is there a Setup Dynamic Update to expand first?" + [Environment]::NewLine + [Environment]::NewLine +
         "It has to go in BEFORE the copy, not after: the update package can carry its own setup.exe, and expanding it afterwards would put the older binary straight back and undo the whole step." + [Environment]::NewLine + [Environment]::NewLine +
         "Yes - pick the .cab." + [Environment]::NewLine +
         "No  - just copy Setup out of the boot image."),
        'Setup Dynamic Update', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }

    if ($answer -eq 'Yes') {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Update packages (*.cab;*.msu)|*.cab;*.msu|All files (*.*)|*.*'
        if (Test-Path -LiteralPath $script:Config['UpdateRoot']) { $ofd.InitialDirectory = $script:Config['UpdateRoot'] }
        if ($ofd.ShowDialog() -ne 'OK') { return }
        $du = $ofd.FileName
    }

    Start-WfJob -Title 'Media Setup refresh' -Arguments @{ media = $refMedia.Text; du = $du } -Body {
        $mediaArgs = @{ MediaPath = $media; Confirm = $false }
        if ($du) { $mediaArgs['SetupDynamicUpdate'] = $du }
        Update-WfMediaSetupFile @mediaArgs
    }
} -X 244 -Width 220 | Out-Null

Add-WfButton $tabBuild 'Which index holds Setup?' 944 {
    if (-not $refMedia.Text) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Point the media box above at the extracted media first.', 'No media', 'OK', 'Information')
        return
    }
    Start-WfJob -Title 'Setup index' -Arguments @{ media = $refMedia.Text } -Body {
        $boot = Join-Path $media 'sources\boot.wim'
        Get-WfMediaSetupIndex -BootImagePath $boot
    }
} -X 474 -Width 220 | Out-Null

# =========================================================== tab: housekeeping

$tabHouse = New-WfTab 'Housekeeping'
Add-WfLabel $tabHouse 'Environment and mounts' 12 -Heading | Out-Null
Add-WfLabel $tabHouse 'Most failed image jobs are one of five things: not elevated, the wrong DISM on PATH, a missing path, a stale mount, or no disk space. Check before you start rather than twenty minutes in.' 36 | Out-Null

Add-WfButton $tabHouse 'Environment check' 84 {
    $checks = Test-WfEnvironment
    Set-WfGrid $houseGrid $checks
    $bad = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
    $statusLabel.Text = "Environment: $bad failure(s)"
} -Width 180 | Out-Null

Add-WfButton $tabHouse 'Repair stale mounts' 84 {
    # -Force recursively deletes the mount folder. That runs precisely when a
    # dismount has just failed, so it must be a deliberate choice, not a default.
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Discard any mounted images and run dism /Cleanup-Mountpoints.`n`n" +
        "Also force-delete leftover files in $($script:Config['MountPath'])?`n`n" +
        "Yes = clean up the folder too    No = mounts only    Cancel = do nothing",
        'Repair stale mounts', 'YesNoCancel', 'Warning')
    if ($answer -eq 'Cancel') { return }
    $force = ($answer -eq 'Yes')
    Start-WfJob -Title 'Repair stale mounts' -Arguments @{ force = $force } -Body {
        Repair-WfMount -Force:$force
    }
} -X 380 -Width 180 | Out-Null

Add-WfButton $tabHouse 'Build history' 84 {
    Set-WfGrid $houseGrid (Get-WfHistory -Last 50 |
        Select-Object TimestampUtc, Action, ImageFile, Operator, Notes)
    $statusLabel.Text = 'Build history'
} -X 570 -Width 180 | Out-Null

Add-WfButton $tabHouse 'Restart elevated' 122 {
    if (Test-WfElevated) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Already running as administrator.', 'Elevation', 'OK', 'Information')
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "This opens a new elevated window and closes the current one.`n`n" +
        "Make sure nothing is currently mounted before continuing.`n`nContinue?",
        'Restart elevated', 'YesNo', 'Warning')
    if ($answer -eq 'Yes' -and (Invoke-WfGuiElevate)) { $form.Close() }
} -Width 180 | Out-Null

Add-WfButton $tabHouse 'List images' 122 {
    Set-WfGrid $houseGrid (Get-WfImageInventory -IncludePeImage |
        Select-Object Name, SizeGB, Modified, AgeDays, Indexes, ImageNames, Notes)
    $statusLabel.Text = 'Image folder'
} -X 380 -Width 180 | Out-Null

$houseGrid = Add-WfGrid $tabHouse 166 224

Add-WfLabel $tabHouse 'Configuration and logs' 392 -Heading | Out-Null

Add-WfButton $tabHouse 'Show configuration' 422 {
    $rows = $script:Config.GetEnumerator() | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Setting = $_.Key; Value = "$($_.Value)" }
    }
    Set-WfGrid $houseGrid $rows
    $statusLabel.Text = "Config: $script:ConfigFile"
} -Width 180 | Out-Null

Add-WfButton $tabHouse 'Edit config file' 422 {
    if ($script:ConfigFile -and (Test-Path -LiteralPath $script:ConfigFile)) {
        Start-Process notepad.exe $script:ConfigFile
    }
    else {
        [void][System.Windows.Forms.MessageBox]::Show('Config file not found.', 'Config', 'OK', 'Information')
    }
} -X 380 -Width 180 | Out-Null

Add-WfButton $tabHouse 'About WimForge' 460 {
    $a = Get-WfAbout
    [void][System.Windows.Forms.MessageBox]::Show(
        ("$($a.Name) $($a.Version)" + [Environment]::NewLine + $a.Tagline + [Environment]::NewLine + [Environment]::NewLine +
         $a.Description + [Environment]::NewLine + [Environment]::NewLine +
         "Author     : $($a.Author)" + [Environment]::NewLine +
         "Licence    : $($a.License)" + [Environment]::NewLine +
         "Repository : $($a.Repository)" + [Environment]::NewLine +
         "Config     : $(Get-WfConfigPath)" + [Environment]::NewLine +
         "PowerShell : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"),
        'About', 'OK', 'Information')
} -X 14 -Width 180 | Out-Null

Add-WfButton $tabHouse 'Open the repository' 460 {
    Start-Process (Get-WfAbout).Repository
} -X 204 -Width 180 | Out-Null

Add-WfButton $tabHouse 'Open today''s log' 422 {
    $log = Join-Path $script:Config['LogRoot'] ('WimForge-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    if (Test-Path -LiteralPath $log) { Start-Process notepad.exe $log }
    else { [void][System.Windows.Forms.MessageBox]::Show("No log for today at`n$log", 'Log', 'OK', 'Information') }
} -X 570 -Width 180 | Out-Null

# ================================================================ tab: updates

$tabUpd = New-WfTab 'Updates'
Add-WfLabel $tabUpd 'Microsoft Update Catalog' 12 -Heading | Out-Null
Add-WfLabel $tabUpd 'There is no official catalog API, so this scrapes the same two pages every tool does. It works, and it will occasionally break when Microsoft changes the page -- in which case it says so plainly and you can still download the .msu by hand into the Updates folder.' 36 | Out-Null

# Both are lists, and both stay typeable -- the catalog gains product names as
# Microsoft ships releases, and a list that cannot be overridden would age badly.
$updProduct = Add-WfChoiceBox $tabUpd 'Product' 96 (
                  ConvertTo-WfChoiceItem -Source (Get-WfUpdateProductChoice) `
                                         -ValueProperty Product -LabelProperty Note) `
                  $script:Config['UpdateProduct'] -Editable -BlankLabel '(type a product)'

$updArch    = Add-WfChoiceBox $tabUpd 'Architecture' 126 (
                  ConvertTo-WfChoiceItem -Source (Get-WfUpdateArchitectureChoice) `
                                         -ValueProperty Architecture -LabelProperty Note) `
                  $script:Config['UpdateArchitecture'] -Editable -BlankLabel '(type an architecture)'
# Reads and injects against the working image from the bar above the tabs.
$updImage   = $wfImage
$updIndex   = $wfIndex

$updQuery   = Add-WfTextBox $tabUpd 'Free-text query (optional)' '' 156

$updCatLbl          = New-Object System.Windows.Forms.Label
$updCatLbl.Text     = 'Category'
$updCatLbl.Location = New-Object System.Drawing.Point(14, 190)
$updCatLbl.Size     = New-Object System.Drawing.Size(170, 20)
$tabUpd.Controls.Add($updCatLbl)

$updCategory               = New-Object System.Windows.Forms.ComboBox
$updCategory.Location      = New-Object System.Drawing.Point(190, 186)
$updCategory.Size          = New-Object System.Drawing.Size(240, 22)
$updCategory.DropDownStyle = 'DropDownList'
[void]$updCategory.Items.AddRange(@('Cumulative','DotNet','Defender','Any'))
$updCategory.SelectedIndex = 0
$tabUpd.Controls.Add($updCategory)

$updPreview = Add-WfCheckBox $tabUpd 'Include Preview updates' 216 $false

# Buttons ABOVE the grid on this tab. The tab page scrolls when the log pane is
# dragged up, and a button row under a tall grid is the first thing to go below
# the fold -- where it looks like the feature does not exist.

Add-WfButton $tabUpd 'Read this image' 250 {
    # Which Windows an image is cannot be read from the WIM header: DISM reports
    # 10.0.19041 for the whole family, so 2004 and 21H2 are indistinguishable
    # there. The release lives in the image's registry, which is pulled straight
    # out of the .wim -- no mount.
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Read the product, release and architecture from the image?" +
         [Environment]::NewLine + [Environment]::NewLine +
         "That takes seconds: the registry is read out of the .wim directly." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Listing the updates already IN the image is the one thing that needs a mount, so it costs a minute or two. It lets search results be marked as already applied." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Yes - read it and list what is installed (mounts)." + [Environment]::NewLine +
         "No  - just read it (no mount)."),
        'Read the target from an image', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }

    $idx = 0
    if (-not [int]::TryParse($updIndex.Text, [ref]$idx)) { $idx = 1 }

    Start-WfJob -Title 'Read the target from an image' -Arguments @{
        p = $updImage.Text; i = $idx; pkg = ($answer -eq 'Yes'); nm = $false
    } -Body {
        Get-WfImageUpdateTarget -ImagePath $p -Index $i -IncludePackage:$pkg -NoMount:$nm
    } -OnComplete {
        param($found)
        if (-not $found) { return }

        $script:UpdateTarget = $found
        # The image's answer goes to the top of the list, marked as having come
        # from evidence rather than from a written-down default.
        Set-WfChoiceItems -Combo $updProduct -Select $found.Product -BlankLabel '(type a product)' `
            -Items (ConvertTo-WfChoiceItem -Source (Get-WfUpdateProductChoice -Target $found) `
                                           -ValueProperty Product -LabelProperty Note)
        Set-WfChoiceItems -Combo $updArch -Select $found.Architecture -BlankLabel '(type an architecture)' `
            -Items (ConvertTo-WfChoiceItem -Source (Get-WfUpdateArchitectureChoice) `
                                           -ValueProperty Architecture -LabelProperty Note)

        $summary = "$($found.Product) $($found.Architecture)"
        if ($found.FullBuild) { $summary = "$summary`nImage build: $($found.FullBuild)" }
        if ($found.EditionId) { $summary = "$summary`nEdition: $($found.EditionId)" }
        if (@($found.ProductAlternative).Count -gt 0) {
            $summary = "$summary`nAlso tries: $(@($found.ProductAlternative) -join ', ')"
        }

        # What is already in there, which is the whole reason the mount was
        # worth a minute. Counted AND listed: a count on its own sends somebody
        # off to a mounted image to find out what the tool already knew.
        $kbs = @($found.InstalledKB | Where-Object { $_ } | Sort-Object -Unique)
        if ($found.PackageCount) {
            $summary = "$summary`n`nAlready in the image: $($found.PackageCount) packages, $($kbs.Count) with a KB number."
            if ($kbs.Count -gt 0) {
                $summary = "$summary`n$(($kbs | Select-Object -First 12) -join ', ')"
                if ($kbs.Count -gt 12) { $summary = "$summary and $($kbs.Count - 12) more" }
                $summary = "$summary`n`nSearch results will now show yes/no in the 'InImage' column instead of '?'."
            }

            Set-WfGrid $updGrid @($kbs | ForEach-Object {
                [pscustomobject]@{ KB = $_; Title = 'already installed in this image'; InImage = 'yes' } })
        }
        else {
            $summary = "$summary`n`nWhat is already installed was not listed -- that needs a mount. Search results will show '?' in the 'InImage' column rather than whether they are already applied."
        }
        if (-not $found.Precise) {
            $summary = "$summary`n`nThis is a guess: the image was not mounted, and the WIM header cannot tell one release in a servicing family from another."
        }
        $statusLabel.Text = "Target: $($found.Product) $($found.Architecture)"
        [void][System.Windows.Forms.MessageBox]::Show($summary, 'Read from the image', 'OK', 'Information')
    }
} -X 14 -Width 150 | Out-Null

Add-WfButton $tabUpd 'Search catalog' 250 {
    $script:Config = Set-WfConfig -Confirm:$false -Settings @{
        UpdateProduct = (Read-WfChoice $updProduct); UpdateArchitecture = (Read-WfChoice $updArch)
    }

    # Only carry the alternatives and the installed-KB list while the boxes still
    # say what the image said. Edit either one and it is a manual search again.
    $alts = @(); $kbs = @(); $imgBuild = ''
    if ($script:UpdateTarget -and
        $script:UpdateTarget.Product -eq (Read-WfChoice $updProduct) -and
        $script:UpdateTarget.Architecture -eq (Read-WfChoice $updArch)) {
        $alts     = @($script:UpdateTarget.ProductAlternative)
        $kbs      = @($script:UpdateTarget.InstalledKB)
        $imgBuild = "$($script:UpdateTarget.FullBuild)"
    }

    Start-WfJob -Title 'Search the catalog' -Arguments @{
        cat = "$($updCategory.SelectedItem)"; q = $updQuery.Text
        prod = (Read-WfChoice $updProduct); arch = (Read-WfChoice $updArch); prev = $updPreview.Checked
        alts = $alts; kbs = $kbs; build = $imgBuild
    } -Body {
        # VsImage before InImage in the column order: it is the one that has an
        # answer for a cumulative update, which is what the search is nearly
        # always for.
        Find-WfUpdate -Category $cat -Query $q -Product $prod -ProductAlternative $alts `
                      -Architecture $arch -KnownKB $kbs -ImageBuild $build -IncludePreview:$prev -First 25 |
            Select-Object KB, Title, Category, Release, TargetBuild, VsImage, InImage, SizeMB, SizeBytes, LastUpdatedText, UpdateId
    } -OnComplete {
        param($rows)
        Set-WfGrid $updGrid $rows
    }
} -X 170 -Width 140 | Out-Null

function Get-WfPickedUpdate {
    <#
        Reads the selected search rows off the grid, on the UI thread, as plain
        values. Two buttons need exactly this, and a WinForms control must never
        be touched from a job.

        KB, Title and SizeBytes travel with the UpdateId: Save-WfUpdate uses the
        size to decide whether an existing file can be left alone, and the title
        ends up in the build history.
    #>
    if ($updGrid.SelectedRows.Count -eq 0 -or -not $updGrid.Columns.Contains('UpdateId')) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Search the catalog first, then select one or more result rows.',
            'Nothing selected', 'OK', 'Information')
        return $null
    }

    $picked = @()
    foreach ($row in $updGrid.SelectedRows) {
        $bytes = 0L
        if ($updGrid.Columns.Contains('SizeBytes')) { [void][long]::TryParse([string]$row.Cells['SizeBytes'].Value, [ref]$bytes) }
        $v = 0.0
        if ($updGrid.Columns.Contains('SizeMB')) { [void][double]::TryParse([string]$row.Cells['SizeMB'].Value, [ref]$v) }

        $kb = ''
        if ($updGrid.Columns.Contains('KB')) { $kb = [string]$row.Cells['KB'].Value }
        $ttl = ''
        if ($updGrid.Columns.Contains('Title')) { $ttl = [string]$row.Cells['Title'].Value }

        $picked += [pscustomobject]@{
            UpdateId = [string]$row.Cells['UpdateId'].Value
            KB = $kb; Title = $ttl; SizeBytes = $bytes; SizeMB = $v
        }
    }

    # A single object would unroll out of this function; the comma keeps it an
    # array so the callers' .Count is always meaningful.
    return ,$picked
}

Add-WfButton $tabUpd 'Download selected' 250 {
    $picked = Get-WfPickedUpdate
    if (-not $picked) { return }
    $mb = ($picked | Measure-Object SizeMB -Sum).Sum

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Download $($picked.Count) update(s), about $([math]::Round($mb)) MB, into the Updates folder?" +
         [Environment]::NewLine + [Environment]::NewLine +
         "Everything in that folder is applied by the next servicing run."),
        'Download updates', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    Start-WfJob -Title 'Download updates' -Arguments @{ picked = $picked } -Body {
        $picked | Save-WfUpdate
    }
} -X 316 -Width 150 | Out-Null

Add-WfButton $tabUpd 'Download + inject' 250 {
    $picked = Get-WfPickedUpdate
    if (-not $picked) { return }
    $mb = ($picked | Measure-Object SizeMB -Sum).Sum

    $img = $updImage.Text
    if (-not $img) { $img = $script:Config['BaseImage'] }
    if (-not $img) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'No image to inject into. Put one in the "Read from image" box, or set a base image in Settings.',
            'No image', 'OK', 'Warning')
        return
    }

    $idx = 0
    if (-not [int]::TryParse($updIndex.Text, [ref]$idx)) { $idx = 1 }

    # An image that is already open changes what this operation is, so it changes
    # what the question says. Offering "work on a copy" against an open mount
    # would be offering something that cannot happen, and promising "this mounts
    # the image, so it takes a while" is wrong when the mounting is already done.
    $openNow = $null
    try { $openNow = Get-WfCurrentMount } catch { }
    $sameOpen = $openNow -and ("$($openNow.ImagePath)".TrimEnd('\') -eq "$img".TrimEnd('\')) -and (-not $openNow.ReadOnly)

    if ($sameOpen) {
        $idx = [int]$openNow.Index
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Download $($picked.Count) update(s), about $([math]::Round($mb)) MB, and apply them to the image you already have open:" +
             [Environment]::NewLine + [Environment]::NewLine + "$img  (index $idx)" +
             [Environment]::NewLine + [Environment]::NewLine +
             "It stays open afterwards. The changes are NOT written to the .wim until you press Close and choose commit -- choosing discard throws them away." +
             [Environment]::NewLine + [Environment]::NewLine +
             "Only the updates picked here are applied, not the rest of the Updates folder."),
            'Download and inject', 'OKCancel', 'Question')
        if ($answer -ne 'OK') { return }
        $copy = $false
    }
    else {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Download $($picked.Count) update(s), about $([math]::Round($mb)) MB, and apply them to:" +
             [Environment]::NewLine + [Environment]::NewLine + "$img  (index $idx)" +
             [Environment]::NewLine + [Environment]::NewLine +
             "Yes - apply to that file directly." + [Environment]::NewLine +
             "No  - work on a copy and leave the master untouched." + [Environment]::NewLine + [Environment]::NewLine +
             "This mounts the image, so it takes a while. Only the updates picked here are applied, not the rest of the Updates folder."),
            'Download and inject', 'YesNoCancel', 'Question')
        if ($answer -eq 'Cancel') { return }
        $copy = ($answer -eq 'No')
    }

    Start-WfJob -Title 'Download and inject' -Arguments @{
        picked = $picked; img = $img; idx = $idx; copy = $copy
    } -Body {
        $got = @($picked | Save-WfUpdate)

        # Only what is actually on disk gets applied. A failed or rejected
        # download must not be silently dropped from the injection list.
        # Downloaded, present, AND the update itself. A checkpoint set downloads
        # as several files and only one of them is ever applied -- handing the
        # whole list to the injector is what put a checkpoint in front of DISM
        # and failed with the Unattend.xml error. IsTarget is absent on rows from
        # an older run, so a missing value counts as true rather than dropping
        # the file silently.
        $files = @($got | Where-Object {
                      ($_.Status -eq 'Downloaded' -or $_.Status -eq 'AlreadyPresent') -and
                      ($null -eq $_.IsTarget -or $_.IsTarget)
                  } | ForEach-Object { $_.Path })
        $bad   = @($got | Where-Object { $_.Status -ne 'Downloaded' -and $_.Status -ne 'AlreadyPresent' })

        if ($bad.Count -gt 0) {
            throw ("{0} download(s) failed, so nothing was injected: {1}" -f $bad.Count, (($bad | ForEach-Object { $_.File }) -join ', '))
        }
        if ($files.Count -eq 0) { throw 'Nothing was downloaded, so there is nothing to inject.' }

        Invoke-WfUpdateInject -ImagePath $img -Index $idx -File $files -WorkingCopy:$copy `
                              -Notes 'Injected from the Updates tab'
    } -OnComplete {
        param($rows)

        # The per-package outcome was previously only in the log, which meant a
        # run that applied two updates and skipped one looked exactly like a run
        # that applied three.
        $rows = @($rows | Where-Object { $_ -and $_.Status })
        if ($rows.Count -eq 0) { return }
        Set-WfGrid $updGrid $rows

        $ok      = @($rows | Where-Object { $_.Status -eq 'Applied' })
        $skipped = @($rows | Where-Object { $_.Status -eq 'NotApplicable' })
        $failed  = @($rows | Where-Object { $_.Status -eq 'Failed' })

        $statusLabel.Text = "Injected: $($ok.Count) applied, $($skipped.Count) not applicable, $($failed.Count) failed"

        if ($failed.Count -gt 0) {
            $detail = ($failed | ForEach-Object {
                "$($_.Package)$([Environment]::NewLine)  $($_.Reason)$([Environment]::NewLine)  $($_.WhatToDo)"
            }) -join ([Environment]::NewLine + [Environment]::NewLine)

            [void][System.Windows.Forms.MessageBox]::Show(
                ("$($failed.Count) update(s) failed to apply." + [Environment]::NewLine + [Environment]::NewLine + $detail),
                'Some updates failed', 'OK', 'Warning')
        }
        elseif ($skipped.Count -gt 0) {
            # Said plainly, because 'not applicable' reads like a failure and is
            # not one -- it is what happens when the Updates folder covers more
            # than one build.
            [void][System.Windows.Forms.MessageBox]::Show(
                ("$($ok.Count) update(s) applied and committed to the image." + [Environment]::NewLine + [Environment]::NewLine +
                 "$($skipped.Count) did not apply to this image. That is normal -- it means they were already in it, or they are for a different edition or build. Nothing went wrong and nothing was left half-done."),
                'Updates injected', 'OK', 'Information')
        }
    }
} -X 472 -Width 170 | Out-Null

Add-WfButton $tabUpd 'Get latest cumulative' 286 {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Find the newest cumulative for $(Read-WfChoice $updProduct) $(Read-WfChoice $updArch) and download it?" +
         [Environment]::NewLine + [Environment]::NewLine +
         "Choose No to only see what would be downloaded."),
        'Latest cumulative', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }
    $dry = ($answer -eq 'No')

    $alts = @(); $kbs = @(); $imgBuild = ''
    if ($script:UpdateTarget -and
        $script:UpdateTarget.Product -eq (Read-WfChoice $updProduct) -and
        $script:UpdateTarget.Architecture -eq (Read-WfChoice $updArch)) {
        $alts     = @($script:UpdateTarget.ProductAlternative)
        $kbs      = @($script:UpdateTarget.InstalledKB)
        $imgBuild = "$($script:UpdateTarget.FullBuild)"
    }

    Start-WfJob -Title 'Latest cumulative' -Arguments @{
        prod = (Read-WfChoice $updProduct); arch = (Read-WfChoice $updArch); dry = $dry
        alts = $alts; kbs = $kbs; build = $imgBuild
    } -Body {
        Get-WfLatestUpdate -Category Cumulative -Product $prod -ProductAlternative $alts `
                           -Architecture $arch -KnownKB $kbs -ImageBuild $build -WhatIfOnly:$dry
    }
} -X 14 -Width 170 | Out-Null

Add-WfButton $tabUpd 'Show Updates folder' 286 {
    Set-WfGrid $updGrid (Get-WfUpdateFolder | Select-Object KB, File, SizeMB, Modified, AgeDays, Path)
    $statusLabel.Text = 'Updates folder'
} -X 190 -Width 170 | Out-Null

Add-WfButton $tabUpd 'Remove selected file' 286 {
    if ($updGrid.SelectedRows.Count -eq 0 -or -not $updGrid.Columns.Contains('File')) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Click "Show Updates folder", then select a row.', 'Wrong view', 'OK', 'Information')
        return
    }
    $file = [string]$updGrid.SelectedRows[0].Cells['File'].Value
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete $file from the Updates folder?", 'Remove update', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        Start-WfJob -Title "Remove $file" -Arguments @{ file = $file } -Body {
            Remove-WfUpdate -File $file -Confirm:$false
        }
    }
} -X 366 -Width 170 | Out-Null

Add-WfLabel $tabUpd 'Search, tick the rows you want, then Download (into the Updates folder, applied by the next servicing run) or Download + inject (straight into the working image). "Show Updates folder" switches the grid to what is already staged locally.' 324 | Out-Null

$updGrid = Add-WfGrid $tabUpd 364 200

# ================================================================= tab: image

$tabImage = New-WfTab 'Image identity'
Add-WfLabel $tabImage 'Regional settings, identity and policy' 12 -Heading | Out-Null
Add-WfLabel $tabImage 'These usually live only in unattend.xml, which makes them right only when the answer file is used. In the image they are the default, and the answer file becomes a way to override them. Anything left on "leave this one alone" is not touched.' 36 | Out-Null

# Every one of these is a list rather than a box. The lists come from the machine
# itself -- the time zone database, .NET's cultures, the keyboard layout registry
# -- so they cannot drift out of date, and none of these values gets typed from
# memory. The UI language list is the exception: it can only come from the image,
# so it stays empty until "Read the current settings" has run.
$wfLocaleChoice = ConvertTo-WfChoiceItem -Source (Get-WfLocaleChoice) `
                                         -ValueProperty Name -LabelProperty EnglishName
$wfLayoutChoice = ConvertTo-WfChoiceItem -Source (Get-WfKeyboardChoice) `
                                         -ValueProperty LayoutId -LabelProperty Layout
$wfZoneChoice   = ConvertTo-WfChoiceItem -Source (Get-WfTimeZoneChoice) `
                                         -ValueProperty Id -LabelProperty Name

$imgUiLang    = Add-WfChoiceBox $tabImage 'UI language (menus)' 96 @() '' `
                    -BlankLabel '(read the image to see what it has)'
$imgSysLocale = Add-WfChoiceBox $tabImage 'System locale'               126 $wfLocaleChoice 'nl-NL'
$imgUsrLocale = Add-WfChoiceBox $tabImage 'User locale (date, numbers)' 156 $wfLocaleChoice 'nl-NL'
$imgKeyLayout = Add-WfChoiceBox $tabImage 'Keyboard layout'             186 $wfLayoutChoice '00020409'
$imgTimeZone  = Add-WfChoiceBox $tabImage 'Time zone'                   216 $wfZoneChoice 'W. Europe Standard Time'

Add-WfLabel $tabImage 'A UI language can only be set to one already in the image -- DISM cannot invent it, so that list fills in once the image has been read. The user locale is the one that makes 04/08 mean the fourth of August. The keyboard is a language and a layout together: the language comes from the user locale, falling back to the system locale.' 248 | Out-Null

$imgManufacturer = Add-WfTextBox $tabImage 'Manufacturer'  '' 320
$imgModel        = Add-WfTextBox $tabImage 'Model'         '' 350
$imgSupportPhone = Add-WfTextBox $tabImage 'Support phone' '' 380
$imgSupportUrl   = Add-WfTextBox $tabImage 'Support URL'   '' 410
$imgMachinePol   = Add-WfTextBox $tabImage 'Computer Registry.pol' '' 440
$imgUserPol      = Add-WfTextBox $tabImage 'User Registry.pol'     '' 470

Add-WfButton $tabImage 'Read the current settings' 512 {
    # Uses the open image when there is one and never closes it; asks first when
    # there is not, because opening costs minutes and that is the operator's
    # decision rather than a side effect of pressing a read button.
    $mountChoice = Confirm-WfMountNeeded 'Reading the regional settings'
    if ($mountChoice -eq 'no') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Image regional settings' -Arguments @{ src = $wfImage.Text; idx = $idx }; keep = ($mountChoice -eq 'keep') -Body {

        # 'keep' opens it here so the call below finds it already open and
        # therefore leaves it open. 'once' skips this and lets the call do its
        # own open-and-close, which is what "just for this read" means.
        if ($keep -and -not (Get-WfCurrentMount)) {
            Mount-WfImage -ImagePath $src -Index $idx -ReadOnly | Out-Null
        }
        Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfImageLocale }
    } -OnComplete {
        param($result)
        # This read is the only source there is for the UI language list, so it
        # fills the drop-down rather than only printing to the log.
        $now = @($result | Where-Object { $_ })[0]
        if (-not $now) { return }

        # Handed the reading rather than left to take it again -- the mount is
        # already gone by the time this runs, so a second dism call would fail.
        $items = ConvertTo-WfChoiceItem -Source (Get-WfUiLanguageChoice -Locale $now) `
                                        -ValueProperty Language -LabelProperty Name
        Set-WfChoiceItems -Combo $imgUiLang -Items $items -BlankLabel '(leave this one alone)'
    }
} -X 14 -Width 190 | Out-Null

Add-WfButton $tabImage 'Apply regional settings' 512 {
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }

    # The keyboard is a language and a layout together. The language is whichever
    # locale was chosen -- user first, because the keyboard belongs with the
    # formats the person at the till sees.
    $kbd    = ''
    $layout = Read-WfChoice $imgKeyLayout
    if ($layout) {
        $kbLang = Read-WfChoice $imgUsrLocale
        if (-not $kbLang) { $kbLang = Read-WfChoice $imgSysLocale }
        if (-not $kbLang) { $kbLang = Read-WfChoice $imgUiLang }
        if ($kbLang) {
            $kbd = Get-WfInputLocaleValue -Language $kbLang -LayoutId $layout
        }
        else {
            [void][System.Windows.Forms.MessageBox]::Show(
                ("A keyboard layout is chosen but no locale is." + [Environment]::NewLine + [Environment]::NewLine +
                 "The keyboard is set as a language and a layout together, so there is no language to pair the layout with. Choose a user or system locale, or set the layout back to leave-alone."),
                'No language for the keyboard', 'OK', 'Information')
            return
        }
    }

    $ui  = Read-WfChoice $imgUiLang
    $sys = Read-WfChoice $imgSysLocale
    $usr = Read-WfChoice $imgUsrLocale
    $tz  = Read-WfChoice $imgTimeZone

    if (-not ($ui -or $sys -or $usr -or $kbd -or $tz)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Everything is on "leave this one alone", so there is nothing to apply.',
            'Nothing chosen', 'OK', 'Information')
        return
    }

    Start-WfJob -Title 'Regional settings' -Arguments @{
        src = $wfImage.Text; idx = $idx; ui = $ui; sys = $sys
        usr = $usr; kbd = $kbd; tz = $tz
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Set-WfImageLocale -UILanguage $ui -SystemLocale $sys -UserLocale $usr `
                              -InputLocale $kbd -TimeZone $tz -Confirm:$false
        }
    }
} -X 214 -Width 180 | Out-Null

Add-WfButton $tabImage 'Write OEM information' 512 {
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'OEM information' -Arguments @{
        src = $wfImage.Text; idx = $idx; man = $imgManufacturer.Text; mod = $imgModel.Text
        phone = $imgSupportPhone.Text; url = $imgSupportUrl.Text; hours = ''; logo = ''
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Set-WfOemInformation -Manufacturer $man -Model $mod -SupportPhone $phone `
                                 -SupportUrl $url -SupportHours $hours -Logo $logo -Confirm:$false
        }
    }
} -X 404 -Width 170 | Out-Null

Add-WfButton $tabImage 'Apply local policy' 512 {
    if (-not $imgMachinePol.Text -and -not $imgUserPol.Text) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Give a computer or user Registry.pol first.', 'Nothing to apply', 'OK', 'Information')
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Local policy is replaced, not merged. Whatever policy is in the image now is gone." +
         [Environment]::NewLine + [Environment]::NewLine +
         "A .pol is one binary blob, so pretending to merge two by copying one over the other would silently discard the settings underneath."),
        'Local group policy', 'OKCancel', 'Warning')
    if ($answer -ne 'OK') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Local group policy' -Arguments @{
        src = $wfImage.Text; idx = $idx; mpol = $imgMachinePol.Text; upol = $imgUserPol.Text
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Set-WfLocalPolicy -MachinePolicy $mpol -UserPolicy $upol -Confirm:$false
        }
    }
} -X 584 -Width 160 | Out-Null

# ------------------------------------------------------- display languages
Add-WfLabel $tabImage 'Display languages' 556 -Heading | Out-Null
Add-WfLabel $tabImage 'A region is a setting; a display language is a package. The menus can only be set to a language whose pack is IN the image, so a fleet spanning several countries carries the languages it might need and picks the region per site. Imported once from the "Languages and Optional Features" ISO for this build -- a 24H2 pack does not belong in a 22H2 image.' 580 | Out-Null

$imgLangSource = Add-WfTextBox $tabImage 'Languages ISO or folder' '' 632 `
                    -PickFolder -PickFolderTitle 'The mounted Languages and Optional Features ISO'

Add-WfButton $tabImage 'Show the language library' 668 {
    Start-WfJob -Title 'Language library' -Body { Get-WfLanguageLibrary }
} -X 14 -Width 200 | Out-Null

Add-WfButton $tabImage 'Import from the ISO...' 668 {
    $src = $imgLangSource.Text
    if (-not $src) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Point the box above at the mounted Languages ISO first.', 'Nothing to import', 'OK', 'Information')
        return
    }

    # Which languages are on that ISO is a question only the ISO can answer, so
    # the list is read before anything is asked -- typing "nl-NL" from memory is
    # exactly what the driver library taught us not to do.
    $langs = [Microsoft.VisualBasic.Interaction]::InputBox(
        ("Language tags to import, comma separated -- nl-NL, de-DE, sv-SE." + [Environment]::NewLine +
         "Leave blank to import every language on the source, which is a lot of disk."),
        'Import languages', '')
    if ($null -eq $langs) { return }

    $list = @($langs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    Start-WfJob -Title 'Import languages' -Arguments @{ src = $src; list = $list } -Body {
        $p = @{ Source = $src; Confirm = $false }
        if ($list -and $list.Count -gt 0) { $p['Language'] = $list }
        Import-WfLanguagePack @p
    }
} -X 224 -Width 200 | Out-Null

Add-WfButton $tabImage 'Languages in this image' 668 {
    $mountChoice = Confirm-WfMountNeeded 'Reading the image languages'
    if ($mountChoice -eq 'no') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Image languages' -Arguments @{
        src = $wfImage.Text; idx = $idx; keep = ($mountChoice -eq 'keep')
    } -Body {
        if ($keep -and -not (Get-WfCurrentMount)) {
            Mount-WfImage -ImagePath $src -Index $idx -ReadOnly | Out-Null
        }
        Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfImageLanguage }
    }
} -X 448 -Width 200 | Out-Null

Add-WfButton $tabImage 'Add a language to the image' 668 {
    $lib = @()
    try { $lib = @(Get-WfLanguageLibrary) } catch { }
    if ($lib.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("The language library is empty." + [Environment]::NewLine + [Environment]::NewLine +
             "Import from the Languages ISO first -- the box above takes the mounted ISO."),
            'No languages', 'OK', 'Information')
        return
    }

    $pick = Show-WfListPicker -Title 'Add languages to the image' `
                -Prompt 'Tick the display languages to put into this image.' `
                -Items ($lib | ForEach-Object {
                    $lp = 'no language pack'
                    if ($_.HasLanguagePack) { $lp = $_.Features }
                    [pscustomobject]@{ Value = $_.Language; Label = ('{0,-8} {1,-28} {2}' -f $_.Language, $_.Name, $lp) } })
    if ($pick.Cancelled -or $pick.Values.Count -eq 0) { return }

    # The cumulative update, because of the rule that catches everyone: a
    # language added after an update has resources only up to the build its pack
    # shipped with, unless that update goes in again afterwards.
    $lcu = ''
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Re-apply the cumulative update afterwards?" + [Environment]::NewLine + [Environment]::NewLine +
         "Microsoft requires it: a language added to an already-updated image carries resources only up to the build its pack shipped with. Nothing fails -- the symptom is English strings in a translated menu, on a terminal that is already in a shop." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Yes - pick the .msu to re-apply." + [Environment]::NewLine +
         "No  - add the languages only. The run will say what is still owed."),
        'Cumulative update', 'YesNoCancel', 'Warning')
    if ($answer -eq 'Cancel') { return }

    if ($answer -eq 'Yes') {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Update packages (*.msu;*.cab)|*.msu;*.cab|All files (*.*)|*.*'
        if (Test-Path -LiteralPath $script:Config['UpdateRoot']) { $ofd.InitialDirectory = $script:Config['UpdateRoot'] }
        if ($ofd.ShowDialog() -ne 'OK') { return }
        $lcu = $ofd.FileName
    }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Add languages' -Arguments @{
        src = $wfImage.Text; idx = $idx; langs = $pick.Values; lcu = $lcu
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            $p = @{ Language = $langs; Confirm = $false }
            if ($lcu) { $p['CumulativeUpdate'] = $lcu }
            Add-WfLanguage @p
        }
    }
} -X 672 -Width 200 | Out-Null

# ---------------------------------------------------------------- the region
Add-WfLabel $tabImage 'Region -- one image, many countries' 712 -Heading | Out-Null
Add-WfLabel $tabImage 'A country is five settings that have to agree with each other: formats, keyboard, home location, time zone and menus. Picked together here so they cannot drift apart. The home location is the one nothing else can set -- there is no GeoID in unattend.xml, so an image configured only from an answer file has Dutch terminals reporting themselves as American. Set a default here; let WinPE override it per site; let the first boot apply whichever won.' 736 | Out-Null

$wfRegionChoice = ConvertTo-WfChoiceItem -Source (Get-WfRegionPreset) `
                                         -ValueProperty Id -LabelProperty Country

$imgRegion   = Add-WfChoiceBox $tabImage 'Country' 816 $wfRegionChoice '' `
                    -BlankLabel '(leave the region alone)'
$imgRegionEn = Add-WfCheckBox $tabImage 'Keep the menus in English (en-US). The formats, keyboard and home location are still local.' 846 $false

Add-WfButton $tabImage 'Apply the region' 884 {
    $id = Read-WfChoice $imgRegion
    if (-not $id) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Pick a country first.', 'No region chosen', 'OK', 'Information')
        return
    }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Region' -Arguments @{
        src = $wfImage.Text; idx = $idx; id = $id; en = $imgRegionEn.Checked
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            $regionArgs = @{ Id = $id; Confirm = $false }
            if ($en) { $regionArgs['UILanguage'] = 'en-US' }
            Set-WfImageRegion @regionArgs
        }
    }
} -X 14 -Width 200 | Out-Null

Add-WfButton $tabImage 'Region in this image' 884 {
    $mountChoice = Confirm-WfMountNeeded 'Reading the region'
    if ($mountChoice -eq 'no') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Image region' -Arguments @{
        src = $wfImage.Text; idx = $idx; keep = ($mountChoice -eq 'keep')
    } -Body {
        if ($keep -and -not (Get-WfCurrentMount)) {
            Mount-WfImage -ImagePath $src -Index $idx -ReadOnly | Out-Null
        }
        Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body {
            Get-WfImageLocale | Out-Null
            Get-WfRegionAnswer
        }
    }
} -X 224 -Width 200 | Out-Null

Add-WfButton $tabImage 'WinPE picker script...' 884 {
    # Which countries go on the menu is the decision worth making carefully: a
    # menu with a country the estate does not have is a machine deployed wrong.
    $pick = Show-WfListPicker -Title 'Countries the WinPE menu offers' `
                -Prompt 'Tick the countries a technician can pick from when the image is applied.' `
                -Items (Get-WfRegionPreset | ForEach-Object {
                    [pscustomobject]@{ Value = $_.Id; Label = ('{0,-6} {1,-20} {2}' -f $_.Id, $_.Country, $_.UserLocale) } })
    if ($pick.Cancelled -or $pick.Values.Count -eq 0) { return }

    $default = Read-WfChoice $imgRegion
    $wait    = 0

    if ($default -and ($pick.Values -contains $default)) {
        $seconds = Read-WfSeconds -Prompt (
            ("Seconds to wait before taking {0}." + [Environment]::NewLine +
             "Blank or 0 means no countdown: the script waits for an answer, which is wrong for a machine nobody is standing in front of.") -f $default) `
            -Title 'Countdown' -Default '60'
        if ($null -eq $seconds) { return }
        $wait = $seconds
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter   = 'Batch scripts (*.cmd)|*.cmd|All files (*.*)|*.*'
    $sfd.FileName = 'region.cmd'
    if ($sfd.ShowDialog() -ne 'OK') { return }

    Start-WfJob -Title 'WinPE region script' -Arguments @{
        offer = $pick.Values; path = $sfd.FileName; def = $default; wait = $wait
    } -Body {
        $peArgs = @{ Offer = $offer; Path = $path; Confirm = $false }
        # Only when the default is one of the offered ones -- a countdown that
        # would take a country not on the menu is refused by the module, and
        # dropping it here gives a script that waits instead of a run that fails.
        if ($def -and ($offer -contains $def)) { $peArgs['DefaultId'] = $def }
        if ($wait -gt 0) { $peArgs['TimeoutSeconds'] = $wait }
        New-WfRegionPeScript @peArgs
    }
} -X 448 -Width 200 | Out-Null

Add-WfButton $tabImage 'First-boot applier...' 884 {
    $pick = Show-WfListPicker -Title 'Countries the image can become' `
                -Prompt 'Tick every country this image may be deployed to. Their settings are baked into the first-boot script, so a till never has to be told what a country means.' `
                -Items (Get-WfRegionPreset | ForEach-Object {
                    [pscustomobject]@{ Value = $_.Id; Label = ('{0,-6} {1,-20} {2}' -f $_.Id, $_.Country, $_.UserLocale) } })
    if ($pick.Cancelled -or $pick.Values.Count -eq 0) { return }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Ask at the first logon when the deployment did not record a country?" + [Environment]::NewLine + [Environment]::NewLine +
         "Yes - one question, with the image's own region pre-selected and a countdown. It appears at the first logon, not during setup: SetupComplete runs as SYSTEM with no desktop, and anything that waits for input there hangs the machine with a blank screen." + [Environment]::NewLine + [Environment]::NewLine +
         "No  - the region baked into the image stands and nobody is asked. Right for an estate that images per country."),
        'Ask at first boot', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }

    $wait = 0
    if ($answer -eq 'Yes') {
        $seconds = Read-WfSeconds -Prompt (
            'Seconds the question waits before taking the pre-selected country.' + [Environment]::NewLine +
            'A machine put on a shelf and forgotten should still end up configured rather than sitting on a dialog nobody will click.') `
            -Title 'Countdown' -Default '60'
        if ($null -eq $seconds) { return }
        $wait = $seconds
    }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'First-boot region' -Arguments @{
        src = $wfImage.Text; idx = $idx; offer = $pick.Values
        ask = ($answer -eq 'Yes'); def = (Read-WfChoice $imgRegion); wait = $wait
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            $fbArgs = @{ Offer = $offer; Confirm = $false }
            if ($ask) { $fbArgs['Ask'] = $true }
            if ($def -and ($offer -contains $def)) { $fbArgs['DefaultId'] = $def }
            if ($wait -gt 0) { $fbArgs['TimeoutSeconds'] = $wait }
            New-WfRegionFirstBoot @fbArgs
        }
    }
} -X 672 -Width 200 | Out-Null

Add-WfButton $tabImage 'Answer file for one till...' 920 {
    # For the terminal that is already in a shop with the wrong region on it.
    # Reimaging it is hours; running one command on it is seconds.
    $id = Read-WfChoice $imgRegion
    if (-not $id) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Pick a country first.', 'No region chosen', 'OK', 'Information')
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter   = 'Settings answer files (*.xml)|*.xml|All files (*.*)|*.*'
    $sfd.FileName = ('region-{0}.xml' -f $id)
    if ($sfd.ShowDialog() -ne 'OK') { return }

    $en = $imgRegionEn.Checked
    Start-WfJob -Title 'Region answer file' -Arguments @{
        id = $id; path = $sfd.FileName; en = $en
    } -Body {
        $xmlArgs = @{ Id = $id }
        if ($en) { $xmlArgs['UILanguage'] = 'en-US' }
        $xml = Get-WfRegionAnswerXml @xmlArgs
        Set-Content -LiteralPath $path -Value $xml -Encoding UTF8
        Write-WfLog "Written to $path" -Level OK
        Write-WfLog ('On the terminal, as an administrator: control.exe intl.cpl,,/f:"{0}"' -f $path) -Level INFO
        Write-WfLog '  Then set the time zone with tzutil, and restart -- the system locale and the logon screen only follow after a reboot.' -Level INFO
        [pscustomobject]@{ Id = $id; Path = $path }
    }
} -X 14 -Width 200 | Out-Null

# ================================================================= tab: slim

$tabSlim = New-WfTab 'Slim and recover'
Add-WfLabel $tabSlim 'Taking things out' 12 -Heading | Out-Null
Add-WfLabel $tabSlim 'Nothing here has a "remove everything unnecessary" button, because nothing can know what is unnecessary on your estate. List first, then name what goes. Everything removed is recorded in the build history.' 36 | Out-Null

$slimNames = Add-WfTextBox $tabSlim 'Names or wildcards (comma separated)' '' 92
$slimForce = Add-WfCheckBox $tabSlim 'Also remove packages other things depend on (VCLibs, Store, .NET native)' 124 $false
$slimStrip = Add-WfCheckBox $tabSlim 'When disabling a feature, remove its payload too' 148 $false

$slimGrid = Add-WfGrid $tabSlim 186 210

Add-WfButton $tabSlim 'List provisioned apps' 412 {
    # Uses the open image when there is one and never closes it; asks first when
    # there is not, because opening costs minutes and that is the operator's
    # decision rather than a side effect of pressing a read button.
    $mountChoice = Confirm-WfMountNeeded 'Listing the provisioned apps'
    if ($mountChoice -eq 'no') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Provisioned apps' -Arguments @{ src = $wfImage.Text; idx = $idx }; keep = ($mountChoice -eq 'keep') -Body {

        # 'keep' opens it here so the call below finds it already open and
        # therefore leaves it open. 'once' skips this and lets the call do its
        # own open-and-close, which is what "just for this read" means.
        if ($keep -and -not (Get-WfCurrentMount)) {
            Mount-WfImage -ImagePath $src -Index $idx -ReadOnly | Out-Null
        }
        Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfProvisionedApp }
    } -OnComplete { param($rows) Set-WfGrid $slimGrid $rows }
} -X 14 -Width 170 | Out-Null

Add-WfButton $tabSlim 'List capabilities' 412 {
    # Uses the open image when there is one and never closes it; asks first when
    # there is not, because opening costs minutes and that is the operator's
    # decision rather than a side effect of pressing a read button.
    $mountChoice = Confirm-WfMountNeeded 'Listing the capabilities'
    if ($mountChoice -eq 'no') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Capabilities' -Arguments @{ src = $wfImage.Text; idx = $idx }; keep = ($mountChoice -eq 'keep') -Body {

        # 'keep' opens it here so the call below finds it already open and
        # therefore leaves it open. 'once' skips this and lets the call do its
        # own open-and-close, which is what "just for this read" means.
        if ($keep -and -not (Get-WfCurrentMount)) {
            Mount-WfImage -ImagePath $src -Index $idx -ReadOnly | Out-Null
        }
        Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfImageCapability }
    } -OnComplete { param($rows) Set-WfGrid $slimGrid $rows }
} -X 194 -Width 150 | Out-Null

Add-WfButton $tabSlim 'Remove apps' 412 {
    $list = @($slimNames.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($list.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Name what should go first.', 'Nothing named', 'OK', 'Information')
        return
    }
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Remove provisioned apps' -Arguments @{
        src = $wfImage.Text; idx = $idx; list = $list; force = $slimForce.Checked
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Remove-WfProvisionedApp -Name $list -Force:$force -Confirm:$false
        }
    } -OnComplete { param($rows) Set-WfGrid $slimGrid $rows }
} -X 354 -Width 140 | Out-Null

Add-WfButton $tabSlim 'Remove capabilities' 412 {
    $list = @($slimNames.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($list.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Name what should go first.', 'Nothing named', 'OK', 'Information')
        return
    }
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Remove capabilities' -Arguments @{ src = $wfImage.Text; idx = $idx; list = $list } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Remove-WfImageCapability -Name $list -Confirm:$false
        }
    } -OnComplete { param($rows) Set-WfGrid $slimGrid $rows }
} -X 504 -Width 160 | Out-Null

Add-WfButton $tabSlim 'Disable features' 412 {
    $list = @($slimNames.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($list.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Name what should go first.', 'Nothing named', 'OK', 'Information')
        return
    }
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Disable features' -Arguments @{
        src = $wfImage.Text; idx = $idx; list = $list; strip = $slimStrip.Checked
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Disable-WfImageFeature -Name $list -Remove:$strip -Confirm:$false
        }
    } -OnComplete { param($rows) Set-WfGrid $slimGrid $rows }
} -X 674 -Width 150 | Out-Null

Add-WfLabel $tabSlim 'The recovery image inside this one gets none of the drivers injected around it, so on a terminal whose storage controller needs one, recovery comes up with no disk to reset and no network to reach a share. You find that out on the day you need it.' 452 | Out-Null

Add-WfButton $tabSlim 'Drivers into the recovery image' 500 {
    $drvFrom = Get-WfGuiDriverRoot
    $pick = Show-WfModelPicker -Title 'Recovery image -- driver models' -DriverRoot $drvFrom
    if ($pick.Cancelled) { return }
    $list = @($pick.Models)

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Recovery drivers' -Arguments @{
        src = $wfImage.Text; idx = $idx; models = $list; root = $drvFrom
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Add-WfRecoveryDriver -Models $models -DriverRoot $root -Confirm:$false
        }
    }
} -X 14 -Width 230 | Out-Null

# =============================================================== tab: recovery

$tabRec = New-WfTab 'Recovery'
Add-WfLabel $tabRec 'Getting a terminal back to the image it shipped with' 12 -Heading | Out-Null
Add-WfLabel $tabRec 'reagentc /setosimage -- the command that registers a custom OS image for Reset this PC -- is documented as "not used in Windows 10 or later". It still exists and still appears to succeed. It does nothing. So there are two honest routes here, and they answer different questions.' 36 | Out-Null
Add-WfLabel $tabRec 'Reset this PC rebuilds Windows from the machine, then re-applies your provisioning packages and runs your scripts. That is built into the image and costs no disk. The boot menu route puts the WIM itself on a partition with an entry that boots WinPE and applies it, which gives back exactly the image that left the workshop -- but it needs a partition sized for the image, made when the disk is laid out.' 84 | Out-Null

$recRePath   = Add-WfTextBox $tabRec 'winre.wim folder on the terminal' 'R:\Recovery\WindowsRE' 148
$recPpkg     = Add-WfTextBox $tabRec 'Provisioning packages (.ppkg, comma sep)' '' 178
$recOemDir   = Add-WfTextBox $tabRec 'Reset script folder (into \Recovery\OEM)' '' 208
$recOemFile  = Add-WfTextBox $tabRec 'Script for FactoryReset_AfterImageApply' '' 238

$recPeFile   = Add-WfTextBox $tabRec 'WinPE boot.wim to prepare' '' 278
$recImageName= Add-WfTextBox $tabRec 'Factory image file name' 'Plus-POS.wim' 308
$recPeName   = Add-WfTextBox $tabRec 'Prepared WinPE file name' 'boot.wim' 338
$recFolder   = Add-WfTextBox $tabRec 'Payload folder on media and partition' 'Recovery\WimForge' 368
$recStageLbl = Add-WfTextBox $tabRec 'Label of the partition to stage onto' 'WFRECOVERY' 398
$recRestLbl  = Add-WfTextBox $tabRec 'Label of the partition it restores onto' 'OSDisk' 428
$recDescr    = Add-WfTextBox $tabRec 'What the boot menu entry is called' 'Restore the factory image' 458

$recUnattend = Add-WfCheckBox $tabRec 'Recovery WinPE restores without asking (an accidental boot wipes the till)' 490 $false

Add-WfLabel $tabRec 'The payload cannot live on the volume it restores: a restore that formats C: destroys the WIM it is applying halfway through, and leaves a terminal with no operating system and nothing to fix it with. The generated script refuses the system volume, refuses a partition too small, and adds the entry last in the menu so it is never what a till boots by default.' 522 | Out-Null

$recGrid = Add-WfGrid $tabRec 578 110

Add-WfButton $tabRec 'What is configured now?' 692 {
    # Uses the open image when there is one and never closes it; asks first when
    # there is not, because opening costs minutes and that is the operator's
    # decision rather than a side effect of pressing a read button.
    $mountChoice = Confirm-WfMountNeeded 'Reading the recovery configuration'
    if ($mountChoice -eq 'no') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Recovery configuration' -Arguments @{ src = $wfImage.Text; idx = $idx }; keep = ($mountChoice -eq 'keep') -Body {

        # 'keep' opens it here so the call below finds it already open and
        # therefore leaves it open. 'once' skips this and lets the call do its
        # own open-and-close, which is what "just for this read" means.
        if ($keep -and -not (Get-WfCurrentMount)) {
            Mount-WfImage -ImagePath $src -Index $idx -ReadOnly | Out-Null
        }
        Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfRecoveryStatus }
    } -OnComplete { param($rows) Set-WfGrid $recGrid $rows }
} -X 14 -Width 190 | Out-Null

Add-WfButton $tabRec 'Register the recovery image' 692 {
    $path = $recRePath.Text
    if (-not $path) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Give the folder holding winre.wim, as the terminal will see it.', 'No path', 'OK', 'Information')
        return
    }
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Register recovery image' -Arguments @{ src = $wfImage.Text; idx = $idx; path = $path } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body { Set-WfRecoveryImage -Path $path -Confirm:$false }
    }
} -X 214 -Width 190 | Out-Null

Add-WfButton $tabRec 'Reset scripts' 692 {
    $folder = $recOemDir.Text
    $rel    = $recOemFile.Text
    if (-not $folder -or -not $rel) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("Both boxes are needed: the folder of scripts to copy into \Recovery\OEM, and the one to run after a full reset has laid Windows back down." +
             [Environment]::NewLine + [Environment]::NewLine +
             "The script path is relative to that folder."),
            'Nothing to configure', 'OK', 'Information')
        return
    }
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    # One phase from the GUI, deliberately: FactoryReset_AfterImageApply is the
    # one that matters on an estate, and four boxes for four phases would be
    # four boxes left empty.
    $list = @(@{ Phase = 'FactoryReset_AfterImageApply'; Path = $rel; Duration = 5 })
    Start-WfJob -Title 'Reset configuration' -Arguments @{
        src = $wfImage.Text; idx = $idx; folder = $folder; list = $list
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Set-WfResetConfig -Script $list -ScriptSource $folder -Confirm:$false
        }
    }
} -X 414 -Width 150 | Out-Null

Add-WfButton $tabRec 'Reset packages' 692 {
    $raw = $recPpkg.Text
    if (-not $raw) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Name the .ppkg files to put in \Recovery\Customizations.', 'Nothing to copy', 'OK', 'Information')
        return
    }
    $pkgs = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Reset customizations' -Arguments @{ src = $wfImage.Text; idx = $idx; pkgs = $pkgs } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Add-WfResetCustomization -Package $pkgs -Confirm:$false
        }
    } -OnComplete { param($rows) Set-WfGrid $recGrid $rows }
} -X 574 -Width 150 | Out-Null

Add-WfButton $tabRec 'Prepare the recovery WinPE' 730 {
    $pe = $recPeFile.Text
    if (-not $pe) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Point at a WinPE boot.wim first. It is modified in place, so work on a copy.',
            'No boot image', 'OK', 'Information')
        return
    }
    $un = $recUnattend.Checked

    $extra = ''
    if ($un) {
        $extra = [Environment]::NewLine + [Environment]::NewLine +
                 "UNATTENDED IS TICKED. This WinPE will format and restore ten seconds after it boots, with nobody asked. Anything that boots that entry by accident loses the till."
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Write the recovery startnet.cmd into:" + [Environment]::NewLine + [Environment]::NewLine + $pe +
         [Environment]::NewLine + [Environment]::NewLine +
         "The file is modified in place. Put the storage and network drivers in first, on the Boot and publish tab -- a recovery environment that cannot see the disk does nothing, and that is found out on the day it is needed." + $extra),
        'Prepare the recovery WinPE', 'OKCancel', 'Warning')
    if ($answer -ne 'OK') { return }

    Start-WfJob -Title 'Recovery WinPE' -Arguments @{
        pe = $pe; wim = $recImageName.Text; lbl = $recRestLbl.Text; un = $un
    } -Body {
        New-WfRecoveryBootImage -BootImage $pe -ImageFile $wim -ApplyIndex 1 `
                                -TargetLabel $lbl -Unattended:$un -Confirm:$false
    }
} -X 14 -Width 220 | Out-Null

Add-WfButton $tabRec 'Add the boot menu entry' 730 {
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("This writes a first-boot script into the image. On the terminal it stages the payload onto the partition labelled '" + $recStageLbl.Text + "' and adds a boot menu entry that restores '" + $recRestLbl.Text + "'." +
         [Environment]::NewLine + [Environment]::NewLine +
         "That partition has to exist, be labelled, and be big enough for the image. A stock 500MB Windows recovery partition is not -- this needs a partition made for it when the disk is laid out." +
         [Environment]::NewLine + [Environment]::NewLine +
         "If it is not there at first boot the script says so in its log and changes nothing else."),
        'Recovery boot entry', 'OKCancel', 'Question')
    if ($answer -ne 'OK') { return }

    Start-WfJob -Title 'Recovery first boot' -Arguments @{
        src = $wfImage.Text; idx = $idx; tgt = $recStageLbl.Text; rst = $recRestLbl.Text
        wim = $recImageName.Text; pe = $recPeName.Text; fld = $recFolder.Text; dsc = $recDescr.Text
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            New-WfRecoveryFirstBoot -TargetLabel $tgt -RestoreLabel $rst -ImageFile $wim `
                                    -BootImageFile $pe -PayloadFolder $fld -Description $dsc `
                                    -Timeout 10 -Append -Confirm:$false
        }
    }
} -X 244 -Width 200 | Out-Null

# =============================================================== tab: lockdown

$tabLock = New-WfTab 'Lockdown'
Add-WfLabel $tabLock 'Device lockdown' 12 -Heading | Out-Null
Add-WfLabel $tabLock 'The features that turn a Windows image into a terminal. Enterprise and IoT Enterprise only. Enabling them happens in the image; UWF, Keyboard Filter and Shell Launcher are configured through uwfmgr and WMI, which an offline image cannot reach, so those go into a first-boot script that applies them on the terminal.' 36 | Out-Null

$lockShell    = Add-WfTextBox $tabLock 'Shell (blank = leave alone)'  '' 100
$lockVolumes  = Add-WfTextBox $tabLock 'UWF volumes'                  'C:' 130
$lockExclude  = Add-WfTextBox $tabLock 'UWF exclusions (comma sep)'   '' 160
# Ticked, not typed. These names are fixed by the Keyboard Filter feature, and
# one spelled slightly wrong is accepted without complaint and then blocks
# nothing -- which is only discovered when somebody presses it on a shop floor.
$lockKeys     = Add-WfCheckList $tabLock 'Keys to block' 190 (
                    ConvertTo-WfChoiceItem -Source (Get-WfKeyboardFilterChoice) `
                                           -ValueProperty Key -LabelProperty What) `
                    -Checked @('Ctrl+Alt+Del', 'Alt+Tab', 'Windows') -Height 130

$lockScript   = Add-WfTextBox $tabLock 'First-boot script (.ps1/.cmd)' '' 332
$lockCommand  = Add-WfTextBox $tabLock 'or a single command line'      '' 362
$lockLog      = Add-WfTextBox $tabLock 'First-boot log on the terminal' 'C:\Windows\Temp\WimForge-FirstBoot.log' 392

Add-WfLabel $tabLock 'UWF exclusions matter more than the filter does: a till that discards its own transaction log every night is worse than no write filter at all. Everything not excluded goes back to its imaged state on every reboot.' 424 | Out-Null

$lockGrid = Add-WfGrid $tabLock 472 110

Add-WfButton $tabLock 'What does this image have?' 598 {
    # Uses the open image when there is one and never closes it; asks first when
    # there is not, because opening costs minutes and that is the operator's
    # decision rather than a side effect of pressing a read button.
    $mountChoice = Confirm-WfMountNeeded 'Listing the lockdown features'
    if ($mountChoice -eq 'no') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Lockdown features' -Arguments @{ src = $wfImage.Text; idx = $idx }; keep = ($mountChoice -eq 'keep') -Body {

        # 'keep' opens it here so the call below finds it already open and
        # therefore leaves it open. 'once' skips this and lets the call do its
        # own open-and-close, which is what "just for this read" means.
        if ($keep -and -not (Get-WfCurrentMount)) {
            Mount-WfImage -ImagePath $src -Index $idx -ReadOnly | Out-Null
        }
        Invoke-WfWithMount -ImagePath $src -Index $idx -ReadOnly -Body { Get-WfLockdownFeature }
    } -OnComplete { param($rows) Set-WfGrid $lockGrid $rows }
} -X 14 -Width 190 | Out-Null

Add-WfButton $tabLock 'Enable the features' 598 {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Enable the device lockdown features in this image?" +
         [Environment]::NewLine + [Environment]::NewLine +
         "Enabling costs nothing at runtime -- an enabled but unconfigured write filter filters nothing. Configuration comes next."),
        'Enable lockdown features', 'OKCancel', 'Question')
    if ($answer -ne 'OK') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Enable lockdown features' -Arguments @{ src = $wfImage.Text; idx = $idx } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body { Enable-WfLockdownFeature -Feature All }
    } -OnComplete { param($rows) Set-WfGrid $lockGrid $rows }
} -X 214 -Width 170 | Out-Null

Add-WfButton $tabLock 'Suppress the logon UI' 598 {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Suppress the Windows logon UI, branding, lock screen and startup messages?" +
         [Environment]::NewLine + [Environment]::NewLine +
         "This one is pure registry, so it goes fully into the image." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Choose No to put the ordinary logon experience back."),
        'Custom logon', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }
    $undo = ($answer -eq 'No')

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Custom logon' -Arguments @{ src = $wfImage.Text; idx = $idx; undo = $undo } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body { Set-WfCustomLogon -Revert:$undo -Confirm:$false }
    }
} -X 394 -Width 170 | Out-Null

Add-WfButton $tabLock 'Replace the shell' 598 {
    $shell = $lockShell.Text
    if (-not $shell) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Put the shell command line in the Shell box first. "explorer.exe" puts the desktop back.',
            'No shell given', 'OK', 'Information')
        return
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Set the machine shell to:" + [Environment]::NewLine + [Environment]::NewLine + "$shell" +
         [Environment]::NewLine + [Environment]::NewLine +
         "There is no way out of this from the terminal itself. Make sure support access exists -- an administrator account with Explorer as its shell, or a shortcut your application honours -- before this reaches a shop."),
        'Replace the shell', 'OKCancel', 'Warning')
    if ($answer -ne 'OK') { return }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'Replace the shell' -Arguments @{ src = $wfImage.Text; idx = $idx; shell = $shell } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body { Set-WfShellLauncher -Shell $shell -Confirm:$false }
    }
} -X 574 -Width 160 | Out-Null

Add-WfButton $tabLock 'Write the first-boot config' 636 {
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }

    $vols = @($lockVolumes.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $exc  = @($lockExclude.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $keys = @(Read-WfCheckList $lockKeys)

    if ($vols.Count -gt 0 -and $exc.Count -eq 0) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("UWF is set to protect $($vols -join ', ') with no exclusions." +
             [Environment]::NewLine + [Environment]::NewLine +
             "Every write to that volume will be discarded on reboot -- application logs, transaction data, everything. That is almost never what is wanted." +
             [Environment]::NewLine + [Environment]::NewLine + "Carry on anyway?"),
            'No exclusions', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }

    Start-WfJob -Title 'Lockdown first-boot config' -Arguments @{
        src = $wfImage.Text; idx = $idx; vols = $vols; exc = $exc; keys = $keys; shell = $lockShell.Text
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            New-WfLockdownFirstBoot -ProtectVolume $vols -Exclusion $exc -BlockKey $keys `
                                    -ShellLauncherShell $shell -Append -Confirm:$false
        }
    }
} -X 14 -Width 190 | Out-Null

Add-WfButton $tabLock 'Place first-boot script' 636 {
    $file = $lockScript.Text
    $cmd  = $lockCommand.Text
    if (-not $file -and -not $cmd) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Give a .ps1 or .cmd to run, a single command line, or both.',
            'Nothing to place', 'OK', 'Information')
        return
    }

    $cmdList = @()
    if ($cmd) { $cmdList = @($cmd) }

    $log = $lockLog.Text
    if (-not $log) { $log = 'C:\Windows\Temp\WimForge-FirstBoot.log' }

    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }
    Start-WfJob -Title 'First-boot script' -Arguments @{
        src = $wfImage.Text; idx = $idx; file = $file; cmdList = $cmdList; log = $log
    } -Body {
        Invoke-WfWithMount -ImagePath $src -Index $idx -Body {
            Set-WfFirstBootScript -ScriptFile $file -Command $cmdList -LogPath $log -Append -Confirm:$false
        }
    }
} -X 214 -Width 170 | Out-Null

Add-WfLabel $tabLock 'SetupComplete.cmd runs once, as SYSTEM, after setup and before the first logon. It has no desktop, so anything that waits for input hangs the machine with nothing on screen. Windows deletes it afterwards -- the log it writes is the only record.' 674 | Out-Null

# ============================================================ tab: reference VM

$tabVm = New-WfTab 'Reference VM'
Add-WfLabel $tabVm 'Reference build VM' 12 -Heading | Out-Null
Add-WfLabel $tabVm 'The base image is built in a VM, not on a terminal: an image captured on physical hardware already has that model''s drivers staged and ranked, and they then compete with the drivers you inject. Work down this tab in order. Paths here are as the HOST sees them, not this workstation.' 36 | Out-Null

$vmHostBox   = Add-WfTextBox $tabVm 'Hyper-V host (blank = local)' $script:Config['HyperVHost'] 96
$vmNameBox   = Add-WfTextBox $tabVm 'VM name'                     $script:Config['ReferenceVmName'] 126
# Everything below this line is a list rather than a box, and every list except
# the sizes is read from the Hyper-V host itself -- because these are paths and
# names on the HOST, which is the detail that catches people out when the host is
# a server somewhere. All of them stay typeable: a host that is switched off
# answers nothing, and a box that cannot then be typed into is worse than the
# plain text box it replaced. "Read the host" fills them in.
$vmIsoBox    = Add-WfChoiceBox $tabVm 'LTSC ISO (on the host)'  156 @() $script:Config['ReferenceIsoPath'] `
                    -Editable -BlankLabel '(click Read the host)'
$vmPathBox   = Add-WfChoiceBox $tabVm 'VM folder (on the host)' 186 @() $script:Config['ReferenceVmPath'] `
                    -Editable -BlankLabel '(blank = the host default)'
Add-WfChoiceBrowse $tabVm $vmIsoBox 156 -Title 'Select the Windows installation ISO' `
    -Filter 'Disc images (*.iso)|*.iso|All files (*.*)|*.*' `
    -IsLocal { -not (Test-WfVmHostIsRemote) } `
    -RemoteNote ("The Hyper-V host is another machine, so this path has to be one THAT machine can see." +
                 [Environment]::NewLine + [Environment]::NewLine +
                 "Browsing from here would return a path this workstation can see and the host cannot, and New-VM would then say the ISO does not exist while pointing at a file that plainly does." +
                 [Environment]::NewLine + [Environment]::NewLine +
                 "Use 'Read the host and fill these in' to list the ISOs that are actually on it, or type the path as the host sees it.") | Out-Null

$vmSwBox     = Add-WfChoiceBox $tabVm 'Virtual switch'          216 @() $script:Config['ReferenceVmSwitch'] `
                    -Editable -BlankLabel '(blank = no network)'
$vmMemBox    = Add-WfChoiceBox $tabVm 'Memory GB'               246 @() "$($script:Config['ReferenceVmMemoryGB'])" `
                    -Editable -BlankLabel '(click Read the host)'
$vmDiskBox   = Add-WfChoiceBox $tabVm 'Disk GB'                 276 @() "$($script:Config['ReferenceVmVhdSizeGB'])" `
                    -Editable -BlankLabel '(click Read the host)'
$vmCpuBox    = Add-WfChoiceBox $tabVm 'vCPU'                    306 @() "$($script:Config['ReferenceVmCpuCount'])" `
                    -Editable -BlankLabel '(click Read the host)'
$vmCpNameBox = Add-WfTextBox $tabVm 'Checkpoint name'            'audit-mode pre-sysprep' 336

# The answer file is read HERE and copied into the guest, so this one is a plain
# local browse with none of the host caveats that apply to the ISO.
$vmUnattBox  = Add-WfChoiceBox $tabVm 'Answer file (for sealing)' 366 @() $script:Config['UnattendPath'] `
                    -Editable -BlankLabel '(none -- sysprep will not be unattended)'
Add-WfChoiceBrowse $tabVm $vmUnattBox 366 -Title 'Select the answer file used to seal the reference build' `
    -Filter 'Answer files (*.xml)|*.xml|All files (*.*)|*.*' | Out-Null

$vmCapBox    = Add-WfTextBox $tabVm 'Capture to (blank = auto)'  '' 396

# Off by default, and that is right: the captured WIM carries no processor
# features either way, so this only matters for the life of the VM itself.
$vmCompatCpu = Add-WfCheckBox $tabVm 'Hide newer CPU instructions, so this VM can move to an older host' 426 $false

# Held so the Create VM handler can tell an External switch from an Internal one
# without going back to the host at click time.
$script:VmSwitches = @()

Add-WfButton $tabVm 'Read the host and fill these in' 462 {
    $vmHostBox.Text = $vmHostBox.Text.Trim()

    # Saved first: every lookup below goes through Invoke-WfVmHostCommand, which
    # reads HyperVHost from the config. Without this the operator types a host
    # name and the tool cheerfully interrogates the previous one.
    $script:Config = Set-WfConfig -Confirm:$false -Settings @{ HyperVHost = $vmHostBox.Text }

    $where = $vmHostBox.Text
    if (-not $where) { $where = 'this machine' }
    Write-WfGuiLog "Reading $where..." ([System.Drawing.Color]::Gainsboro)

    $facts = Get-WfVmHostFact
    if (-not $facts.Reachable) {
        $vmStatus.Text      = "Cannot reach $where -- $($facts.Error)"
        $vmStatus.ForeColor = [System.Drawing.Color]::Firebrick
        [void][System.Windows.Forms.MessageBox]::Show(
            ("Could not read $where." + [Environment]::NewLine + [Environment]::NewLine + $facts.Error +
             [Environment]::NewLine + [Environment]::NewLine +
             "Everything on this tab can still be typed in by hand -- the boxes are lists, not locks."),
            'Host not reachable', 'OK', 'Warning')
        return
    }

    Write-WfGuiLog ("Host {0}: {1} logical processors, {2} GB total, {3} GB assigned to {4} running VM(s)" -f `
        $facts.ComputerName, $facts.LogicalProcessors, $facts.TotalMemoryGB,
        $facts.AssignedMemoryGB, $facts.RunningVms) ([System.Drawing.Color]::LightGreen)

    # --- the VM name, before the rest of the form is filled in ------------
    $suggest = Get-WfVmNameSuggestion -Preferred $vmNameBox.Text
    if ($suggest.Taken) {
        Write-WfGuiLog "A VM called '$($vmNameBox.Text)' is already on the host -- suggesting '$($suggest.Name)'" ([System.Drawing.Color]::Khaki)
        $vmNameBox.Text = $suggest.Name
    }

    # --- switches ---------------------------------------------------------
    $script:VmSwitches = @(Get-WfVmSwitchChoice)
    Set-WfChoiceItems -Combo $vmSwBox -BlankLabel '(blank = no network)' `
        -Select (Read-WfChoice $vmSwBox) -Items @($script:VmSwitches | ForEach-Object {
            [pscustomobject]@{ Value = $_.Name; Label = ('{0}  --  {1}: {2}' -f $_.Name, $_.Type, $_.What) } })

    if ($script:VmSwitches.Count -eq 0) {
        Write-WfGuiLog 'No virtual switches on the host. A build with no network cannot take updates.' ([System.Drawing.Color]::Khaki)
    }
    elseif (-not (Read-WfChoice $vmSwBox)) {
        # Preselect an External one. It is the only type that reaches Windows
        # Update, and picking it is what somebody would have done anyway.
        $best = @($script:VmSwitches | Where-Object { $_.Suitable }) | Select-Object -First 1
        if ($best) {
            Set-WfChoiceItems -Combo $vmSwBox -BlankLabel '(blank = no network)' -Select $best.Name `
                -Items @($script:VmSwitches | ForEach-Object {
                    [pscustomobject]@{ Value = $_.Name; Label = ('{0}  --  {1}: {2}' -f $_.Name, $_.Type, $_.What) } })
            Write-WfGuiLog "Switch set to '$($best.Name)' -- the External one, so the build can reach updates" ([System.Drawing.Color]::LightGreen)
        }
    }

    # --- ISOs -------------------------------------------------------------
    $isos = @(Get-WfVmIsoChoice)
    Set-WfChoiceItems -Combo $vmIsoBox -BlankLabel '(none found -- type the path as the host sees it)' `
        -Select (Read-WfChoice $vmIsoBox) -Items @($isos | ForEach-Object {
            $tail = '{0:N2} GB, {1:yyyy-MM-dd}' -f $_.SizeGB, $_.Modified
            if ($_.Note) { $tail = "$tail -- $($_.Note)" }
            [pscustomobject]@{ Value = $_.Path; Label = ('{0}  --  {1}' -f $_.Path, $tail) } })
    Write-WfGuiLog ("{0} ISO(s) on the host" -f $isos.Count) ([System.Drawing.Color]::Gainsboro)

    # --- the VM folder ----------------------------------------------------
    $folders = @(
        [pscustomobject]@{ Value = $facts.VirtualMachinePath;   Label = "$($facts.VirtualMachinePath)  --  the host's own VM folder" }
        [pscustomobject]@{ Value = $facts.VirtualHardDiskPath;  Label = "$($facts.VirtualHardDiskPath)  --  the host's virtual disk folder" }
    ) | Where-Object { $_.Value }
    Set-WfChoiceItems -Combo $vmPathBox -Items @($folders) -Select (Read-WfChoice $vmPathBox) `
        -BlankLabel '(blank = the host default)'

    # --- sizes, capped by what the host actually has ----------------------
    foreach ($pair in @(
        @{ Box = $vmMemBox;  Kind = 'Memory' }
        @{ Box = $vmDiskBox; Kind = 'Disk'   }
        @{ Box = $vmCpuBox;  Kind = 'Cpu'    })) {

        $sizes   = @(Get-WfVmSizeChoice -Kind $pair.Kind -HostFact $facts)
        $current = Read-WfChoice $pair.Box
        if (-not $current) {
            $d = @($sizes | Where-Object { $_.Default }) | Select-Object -First 1
            if ($d) { $current = "$($d.Value)" }
        }

        Set-WfChoiceItems -Combo $pair.Box -Select $current -BlankLabel '(type a value)' `
            -Items @($sizes | ForEach-Object {
                $mark = ''
                if (-not $_.Fits) { $mark = '  [!]' }
                [pscustomobject]@{ Value = "$($_.Value)"; Label = ('{0}  --  {1}{2}' -f $_.Label, $_.Note, $mark) } })
    }

    $vmStatus.Text      = "$($facts.ComputerName): $($facts.LogicalProcessors) vCPU, $($facts.TotalMemoryGB) GB, $($facts.TotalVms) VM(s). Lists filled in."
    $vmStatus.ForeColor = [System.Drawing.Color]::ForestGreen
    $statusLabel.Text   = "Read $($facts.ComputerName)"
} -X 14 -Width 260 | Out-Null

$vmStatus            = New-Object System.Windows.Forms.Label
$vmStatus.Location   = New-Object System.Drawing.Point(14, 506)
$vmStatus.Size       = New-Object System.Drawing.Size(930, 40)
$vmStatus.Anchor     = 'Top,Left,Right'
$vmStatus.Text       = 'State unknown -- click Refresh state.'
$vmStatus.Font       = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$tabVm.Controls.Add($vmStatus)

function Save-WfVmSettings {
    <# Persist whatever is on screen so the next build does not ask again. #>
    # Read-WfChoice, not .Text: a chosen row shows '4 GB -- the sensible default'
    # and a bare int parse of that fails silently back to whatever was in the
    # config, which looks exactly like the choice not being saved.
    $mem = 0; $disk = 0; $cpu = 0
    if (-not [int]::TryParse((Read-WfChoice $vmMemBox),  [ref]$mem))  { $mem  = $script:Config['ReferenceVmMemoryGB'] }
    if (-not [int]::TryParse((Read-WfChoice $vmDiskBox), [ref]$disk)) { $disk = $script:Config['ReferenceVmVhdSizeGB'] }
    if (-not [int]::TryParse((Read-WfChoice $vmCpuBox),  [ref]$cpu))  { $cpu  = $script:Config['ReferenceVmCpuCount'] }

    $script:Config = Set-WfConfig -Confirm:$false -Settings @{
        HyperVHost           = $vmHostBox.Text
        ReferenceVmName      = $vmNameBox.Text
        ReferenceIsoPath     = (Read-WfChoice $vmIsoBox)
        ReferenceVmPath      = (Read-WfChoice $vmPathBox)
        ReferenceVmSwitch    = (Read-WfChoice $vmSwBox)
        ReferenceVmMemoryGB  = $mem
        ReferenceVmVhdSizeGB = $disk
        ReferenceVmCpuCount  = $cpu
        ReferenceVmCompatibleCpu = $vmCompatCpu.Checked
    }
}

function Update-WfVmStatus {
    try {
        $vm = Get-WfReferenceVm
        if (-not $vm.Exists) {
            $vmStatus.Text = "$($vm.Name): does not exist on the host yet."
            $vmStatus.ForeColor = [System.Drawing.Color]::DarkGoldenrod
            return
        }
        $cps = ''
        if ($vm.Checkpoints) { $cps = "  |  checkpoints: $($vm.Checkpoints -join ', ')" }
        $vmStatus.Text = "$($vm.Name): $($vm.State)   $($vm.MemoryGB) GB / $($vm.CpuCount) vCPU$cps"
        if ($vm.State -eq 'Running')  { $vmStatus.ForeColor = [System.Drawing.Color]::ForestGreen }
        elseif ($vm.State -eq 'Off')  { $vmStatus.ForeColor = [System.Drawing.Color]::DimGray }
        else                          { $vmStatus.ForeColor = [System.Drawing.Color]::DarkGoldenrod }

        if (-not $vm.GuestServices) {
            $vmStatus.Text += '   [Guest Service Interface off -- file copy into the VM will fail]'
            $vmStatus.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        }
    }
    catch {
        $vmStatus.Text = "Cannot reach the Hyper-V host: $($_.Exception.Message)"
        $vmStatus.ForeColor = [System.Drawing.Color]::Firebrick
    }
}

# --- row 1: host and lifecycle
Add-WfButton $tabVm 'Host check' 554 {
    Save-WfVmSettings
    Set-WfGrid $vmGrid (Test-WfHyperV)
    Update-WfVmStatus
    $statusLabel.Text = 'Hyper-V host checked'
} -X 14 -Width 150 | Out-Null

Add-WfButton $tabVm 'Refresh state' 554 {
    Save-WfVmSettings
    Update-WfVmStatus
    try { Set-WfGrid $vmGrid (Get-WfReferenceCheckpoint) } catch { }
} -X 174 -Width 150 | Out-Null

Add-WfButton $tabVm 'Create VM' 554 {
    Save-WfVmSettings
    $iso = Read-WfChoice $vmIsoBox
    if (-not $iso) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Set the ISO path first, as the Hyper-V host sees it. "Read the host" lists the ones it can find.',
            'ISO required','OK','Warning')
        return
    }

    # An Internal or Private switch is the one that fails quietly: the VM is
    # created, Windows installs, and the build simply has no route off the host.
    $sw = Read-WfChoice $vmSwBox
    if ($sw) {
        $chosen = @($script:VmSwitches | Where-Object { $_.Name -eq $sw })
        if ($chosen.Count -eq 1 -and -not $chosen[0].Suitable) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                ("'$sw' is a $($chosen[0].Type) switch: $($chosen[0].What)." + [Environment]::NewLine + [Environment]::NewLine +
                 "A reference build needs Windows Update and usually a share, so this one would leave it stranded. Nothing fails at creation -- the VM comes up fine and the problem shows up hours later." + [Environment]::NewLine + [Environment]::NewLine +
                 "Use it anyway?"),
                'Switch has no network', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }
    }

    # Passed explicitly rather than left to the config the line above just wrote.
    # Same result either way, but calling it the same way the console does keeps
    # the two front-ends genuinely comparable instead of only apparently so.
    $mem = 0; $disk = 0; $cpu = 0
    [void][int]::TryParse((Read-WfChoice $vmMemBox),  [ref]$mem)
    [void][int]::TryParse((Read-WfChoice $vmDiskBox), [ref]$disk)
    [void][int]::TryParse((Read-WfChoice $vmCpuBox),  [ref]$cpu)

    Start-WfJob -Title 'Create reference VM' -Arguments @{
        name = $vmNameBox.Text; iso = $iso; path = (Read-WfChoice $vmPathBox)
        sw = $sw; mem = $mem; disk = $disk; cpu = $cpu; compat = $vmCompatCpu.Checked
    } -Body {
        New-WfReferenceVm -Name $name -IsoPath $iso -Path $path -SwitchName $sw `
                          -MemoryGB $mem -VhdSizeGB $disk -CpuCount $cpu `
                          -CompatibleCpu:$compat
    }
} -X 334 -Width 150 | Out-Null

Add-WfButton $tabVm 'Start + connect' 554 {
    Save-WfVmSettings
    Start-WfJob -Title 'Start reference VM' -Body { Start-WfReferenceVm -Connect }
} -X 494 -Width 150 | Out-Null

Add-WfButton $tabVm 'Where is the disk?' 554 {
    Save-WfVmSettings
    Start-WfJob -Title 'Reference VHDX' -Body { Get-WfReferenceVhdPath }
} -X 654 -Width 150 | Out-Null

# --- row 2: inside the VM
Add-WfButton $tabVm 'Guest credentials...' 592 {
    [void][System.Windows.Forms.MessageBox]::Show(
        ("PowerShell Direct needs an account inside the VM." + [Environment]::NewLine + [Environment]::NewLine +
         "Windows will not accept the blank password the audit-mode Administrator starts with, so run this once inside the VM:" +
         [Environment]::NewLine + [Environment]::NewLine + "    net user Administrator <password>" + [Environment]::NewLine + [Environment]::NewLine +
         "The credential is held in memory for this session only."),
        'Guest credentials', 'OK', 'Information')
    $u = Set-WfGuestCredential
    if ($u) {
        Write-WfGuiLog "Guest credentials set for $u" ([System.Drawing.Color]::LightGreen)
        $statusLabel.Text = "Guest credentials: $u"
    }
} -X 14 -Width 150 | Out-Null

Add-WfButton $tabVm 'Prepare audit mode' 592 {
    Save-WfVmSettings
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Apply the imaging policies inside the VM: no drivers from Windows Update, hibernation off, reserved storage off, no sleep." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Do this BEFORE installing the application stack. Continue?"),
        'Prepare audit mode', 'YesNo', 'Question')
    if ($answer -eq 'Yes') {
        Start-WfJob -Title 'Prepare audit mode' -Body { Initialize-WfReferenceBuild -Stage Start }
    }
} -X 174 -Width 150 | Out-Null

Add-WfButton $tabVm 'Checkpoint' 592 {
    Save-WfVmSettings
    $cp = $vmCpNameBox.Text
    if (-not $cp) { $cp = 'audit-mode pre-sysprep' }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Take a checkpoint named '$cp'." + [Environment]::NewLine + [Environment]::NewLine +
         "Do this once the stack is installed and BEFORE sealing. It is the master every later rebuild restores from." +
         [Environment]::NewLine + [Environment]::NewLine + "Continue?"),
        'Checkpoint', 'YesNo', 'Question')
    if ($answer -eq 'Yes') {
        Start-WfJob -Title 'Checkpoint' -Arguments @{ cp = $cp } -Body {
            New-WfReferenceCheckpoint -CheckpointName $cp
        }
    }
} -X 334 -Width 150 | Out-Null

Add-WfButton $tabVm 'Restore selected' 592 {
    if ($vmGrid.SelectedRows.Count -eq 0 -or -not $vmGrid.Columns.Contains('Name')) {
        [void][System.Windows.Forms.MessageBox]::Show('Click Refresh state, then select a checkpoint row.','Nothing selected','OK','Information')
        return
    }
    $cp = [string]$vmGrid.SelectedRows[0].Cells['Name'].Value
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Restore the VM to '$cp'?" + [Environment]::NewLine + [Environment]::NewLine +
         "Everything done since that checkpoint is discarded."),
        'Restore checkpoint', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        Start-WfJob -Title "Restore $cp" -Arguments @{ cp = $cp } -Body {
            Restore-WfReferenceCheckpoint -CheckpointName $cp -Confirm:$false
        }
    }
} -X 494 -Width 150 | Out-Null

Add-WfButton $tabVm 'Run in guest...' 592 {
    Save-WfVmSettings
    $cmd = [Microsoft.VisualBasic.Interaction]::InputBox(
        'PowerShell to run inside the VM over PowerShell Direct', 'Run in guest',
        'Get-ComputerInfo | Select-Object OsName, OsVersion, CsName')
    if (-not $cmd) { return }
    Start-WfJob -Title 'Run in guest' -Arguments @{ cmd = $cmd } -Body {
        Invoke-WfReferenceCommand -ScriptBlock ([scriptblock]::Create($cmd))
    }
} -X 654 -Width 150 | Out-Null

# --- row 3: sealing, capture, power
Add-WfButton $tabVm 'Clean up and SEAL' 630 {
    Save-WfVmSettings

    $warn = ''
    try {
        $vm = Get-WfReferenceVm
        if ($vm.Exists -and $vm.CheckpointCount -eq 0) {
            $warn = "This VM has NO checkpoints. Without one, a bad seal means rebuilding from the ISO." + [Environment]::NewLine + [Environment]::NewLine
        }
    } catch { }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ($warn + "Run the pre-seal cleanup inside the VM and then sysprep /generalize /oobe /shutdown." +
         [Environment]::NewLine + [Environment]::NewLine +
         "This is NOT reversible, and the VM must not be booted again afterwards." +
         [Environment]::NewLine + [Environment]::NewLine + "Seal the reference build?"),
        'Seal the build', 'YesNo', 'Warning')

    if ($answer -eq 'Yes') {
        Start-WfJob -Title 'Clean up and seal' -Arguments @{ unattend = (Read-WfChoice $vmUnattBox) } -Body {
            Initialize-WfReferenceBuild -Stage PreSeal -Sysprep -UnattendPath $unattend
        }
    }
} -X 14 -Width 150 | Out-Null

Add-WfButton $tabVm 'Capture base image' 630 {
    Save-WfVmSettings
    $notes = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Notes for the build history (optional)', 'Capture', '')
    Start-WfJob -Title 'Capture base image' -Arguments @{ notes = $notes; dest = $vmCapBox.Text } -Body {
        Invoke-WfReferenceCapture -DestinationPath $dest -Notes $notes
    }
} -X 174 -Width 150 | Out-Null

Add-WfButton $tabVm 'Shut down' 630 {
    Save-WfVmSettings
    Start-WfJob -Title 'Stop reference VM' -Body { Stop-WfReferenceVm }
} -X 334 -Width 150 | Out-Null

Add-WfButton $tabVm 'Force power off' 630 {
    Save-WfVmSettings
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Pull the power on the VM with no guest shutdown." + [Environment]::NewLine + [Environment]::NewLine +
         "Only do this if the guest is genuinely stuck -- it can corrupt a build mid-install. Continue?"),
        'Force power off', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        Start-WfJob -Title 'Turn off reference VM' -Body { Stop-WfReferenceVm -TurnOff }
    }
} -X 494 -Width 150 | Out-Null

Add-WfButton $tabVm 'Remove selected checkpoint' 668 {
    if ($vmGrid.SelectedRows.Count -eq 0 -or -not $vmGrid.Columns.Contains('Name')) {
        [void][System.Windows.Forms.MessageBox]::Show('Click Refresh state, then select a checkpoint row.','Nothing selected','OK','Information')
        return
    }
    $cp = [string]$vmGrid.SelectedRows[0].Cells['Name'].Value
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Delete the checkpoint '$cp'?" + [Environment]::NewLine + [Environment]::NewLine +
         "The VM keeps its current state; only the ability to go back to this point is lost."),
        'Remove checkpoint', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        Start-WfJob -Title "Remove $cp" -Arguments @{ cp = $cp } -Body {
            Remove-WfReferenceCheckpoint -CheckpointName $cp -Confirm:$false
        }
    }
} -X 14 -Width 190 | Out-Null

Add-WfButton $tabVm 'Host credentials...' 668 {
    if (-not (Test-WfVmHostIsRemote)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Hyper-V is local, so no host credentials are needed.', 'Local host', 'OK', 'Information')
        return
    }
    $u = Set-WfHostCredential
    if ($u) {
        Write-WfGuiLog "Hyper-V host credentials set for $u" ([System.Drawing.Color]::LightGreen)
        $statusLabel.Text = "Host credentials: $u"
    }
} -X 214 -Width 150 | Out-Null

Add-WfButton $tabVm 'Copy a file into the VM' 668 {
    Save-WfVmSettings
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title  = 'File to copy into the reference VM'
    $ofd.Filter = 'All files (*.*)|*.*'
    if ($ofd.ShowDialog() -ne 'OK') { return }

    $dest = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Destination path inside the guest', 'Copy into VM',
        "C:\WimForgeBuild\$([IO.Path]::GetFileName($ofd.FileName))")
    if (-not $dest) { return }

    Start-WfJob -Title 'Copy into the VM' -Arguments @{ src = $ofd.FileName; dest = $dest } -Body {
        Copy-WfToReferenceVm -SourcePath $src -DestinationPath $dest
    }
} -X 374 -Width 180 | Out-Null

$vmGrid = Add-WfGrid $tabVm 710 160

# =============================================================== tab: settings

$tabSettings = New-WfTab 'Settings'
Add-WfLabel $tabSettings 'Configuration' 12 -Heading | Out-Null
Add-WfLabel $tabSettings 'Edit any setting here -- double-click a value to change it, or select a row and use Browse. Nothing needs editing by hand in a JSON file. Green means the path exists, yellow means the folder is missing but the drive is there, red means the drive itself does not exist on this machine.' 36 | Out-Null

$settingsPathKeys = @('WorkspaceRoot','ImageRoot','DriverRoot','UpdateRoot','PayloadRoot','LogRoot','MountPath','ScratchPath','WdsShare','WdsBootShare')
$settingsFileKeys = @('BaseImage','PeImage','UnattendPath','HistoryFile')

$setGrid                     = New-Object System.Windows.Forms.DataGridView
$setGrid.Location            = New-Object System.Drawing.Point(14, 96)
$setGrid.Size                = New-Object System.Drawing.Size(930, 300)
$setGrid.Anchor              = 'Top,Left,Right,Bottom'
$setGrid.AllowUserToAddRows  = $false
$setGrid.RowHeadersVisible   = $false
$setGrid.SelectionMode       = 'FullRowSelect'
$setGrid.AutoSizeColumnsMode = 'Fill'
$tabSettings.Controls.Add($setGrid)

function Get-WfSettingStatus {
    param([string] $Key, $Value)

    if ($Key -notin $settingsPathKeys -and $Key -notin $settingsFileKeys) { return '' }
    if ([string]::IsNullOrWhiteSpace("$Value")) { return 'not set' }

    $q = $null
    try { $q = Split-Path -Qualifier "$Value" -ErrorAction Stop } catch { }
    if ($q -and -not (Test-Path -LiteralPath "$q\")) { return "drive $q missing" }
    if (Test-Path -LiteralPath "$Value") { return 'ok' }
    return 'missing'
}

function Update-WfSettingsGrid {
    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add('Setting')
    [void]$table.Columns.Add('Value')
    [void]$table.Columns.Add('Status')

    foreach ($key in @($script:Config.Keys | Sort-Object)) {
        $value = $script:Config[$key]
        if ($value -is [array]) { $value = $value -join ', ' }
        $row = $table.NewRow()
        $row['Setting'] = $key
        $row['Value']   = "$value"
        $row['Status']  = Get-WfSettingStatus $key $value
        [void]$table.Rows.Add($row)
    }

    $setGrid.DataSource = $table
    $setGrid.Columns['Setting'].ReadOnly = $true
    $setGrid.Columns['Status'].ReadOnly  = $true
    $setGrid.Columns['Setting'].FillWeight = 26
    $setGrid.Columns['Value'].FillWeight   = 56
    $setGrid.Columns['Status'].FillWeight  = 18

    foreach ($row in $setGrid.Rows) {
        switch ("$($row.Cells['Status'].Value)") {
            'ok'      { $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::ForestGreen }
            'missing' { $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::DarkGoldenrod }
            'not set' { $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::Gray }
            default   {
                if ("$($row.Cells['Status'].Value)" -like 'drive*') {
                    $row.Cells['Status'].Style.ForeColor = [System.Drawing.Color]::Firebrick
                }
            }
        }
    }
}

Add-WfButton $tabSettings 'Browse for selected...' 410 {
    if ($setGrid.SelectedRows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select a setting row first.', 'Nothing selected', 'OK', 'Information')
        return
    }
    $key     = [string]$setGrid.SelectedRows[0].Cells['Setting'].Value
    $current = [string]$setGrid.SelectedRows[0].Cells['Value'].Value

    $picked = $null
    if ($key -in $settingsPathKeys) {
        $fb             = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = $key
        $fb.ShowNewFolderButton = $true
        if ($current -and (Test-Path -LiteralPath $current)) { $fb.SelectedPath = $current }
        if ($fb.ShowDialog() -eq 'OK') { $picked = $fb.SelectedPath }
    }
    elseif ($key -in $settingsFileKeys) {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'All files (*.*)|*.*'
        if ($key -in 'BaseImage','PeImage') { $ofd.Filter = 'Windows images (*.wim)|*.wim|All files (*.*)|*.*' }
        elseif ($key -eq 'UnattendPath')    { $ofd.Filter = 'Answer files (*.xml)|*.xml|All files (*.*)|*.*' }
        $ofd.CheckFileExists = $false
        try { $parent = Split-Path $current -Parent; if ($parent -and (Test-Path -LiteralPath $parent)) { $ofd.InitialDirectory = $parent } } catch { }
        if ($ofd.ShowDialog() -eq 'OK') { $picked = $ofd.FileName }
    }
    else {
        [void][System.Windows.Forms.MessageBox]::Show(
            "$key is not a path -- edit it directly in the Value column.", 'Not a path', 'OK', 'Information')
        return
    }

    if ($picked) { $setGrid.SelectedRows[0].Cells['Value'].Value = $picked }
} -X 14 -Width 190 | Out-Null

Add-WfButton $tabSettings 'Save changes' 410 {
    # Commit the grid's in-progress edit first, or the cell being typed into is
    # silently dropped.
    [void]$setGrid.EndEdit()

    $changes = @{}
    foreach ($row in $setGrid.Rows) {
        $key = [string]$row.Cells['Setting'].Value
        $new = [string]$row.Cells['Value'].Value
        $old = $script:Config[$key]

        if ($old -is [array]) {
            $parsed = @($new -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if (($parsed -join ',') -ne ($old -join ',')) { $changes[$key] = $parsed }
        }
        elseif ($old -is [bool]) {
            $parsed = ($new -match '^(1|t|true|y|yes)$')
            if ($parsed -ne $old) { $changes[$key] = $parsed }
        }
        elseif ($old -is [int]) {
            $parsed = 0
            if ([int]::TryParse($new, [ref]$parsed)) { if ($parsed -ne $old) { $changes[$key] = $parsed } }
        }
        elseif ($new -ne "$old") {
            $changes[$key] = $new
        }
    }

    if ($changes.Count -eq 0) {
        $statusLabel.Text = 'No changes'
        return
    }

    $script:Config = Set-WfConfig -Settings $changes -Confirm:$false
    Update-WfSettingsGrid
    try { Update-WfVmStatus } catch { }
    $statusLabel.Text = "Saved $($changes.Count) setting(s) to $script:ConfigFile"
    Write-WfGuiLog "Saved $($changes.Count) setting(s): $(($changes.Keys | Sort-Object) -join ', ')" ([System.Drawing.Color]::LightGreen)
} -X 214 -Width 150 | Out-Null

Add-WfButton $tabSettings 'Reload' 410 {
    $script:Config = Get-WfConfig -Refresh
    Update-WfSettingsGrid
    $statusLabel.Text = 'Reloaded from disk'
} -X 374 -Width 110 | Out-Null

Add-WfButton $tabSettings 'Move workspace...' 410 {
    $fb             = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Choose the imaging workspace folder'
    $fb.ShowNewFolderButton = $true
    $current = $script:Config['WorkspaceRoot']
    if ($current -and (Test-Path -LiteralPath $current)) { $fb.SelectedPath = $current }

    if ($fb.ShowDialog() -eq 'OK') {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Repoint the workspace to:`n$($fb.SelectedPath)`n`n" +
            "Images, drivers, updates, payload, logs and the build history all follow." +
            "`n`nExisting files are NOT moved. Continue?",
            'Move workspace', 'YesNo', 'Warning')
        if ($answer -eq 'Yes') {
            $script:Config = Set-WfWorkspaceRoot -Path $fb.SelectedPath -CreateFolders -Confirm:$false
            Update-WfSettingsGrid
            $statusLabel.Text = "Workspace: $($fb.SelectedPath)"
        }
    }
} -X 494 -Width 170 | Out-Null

Add-WfButton $tabSettings 'Create missing folders' 410 {
    $made = Initialize-WfWorkspace -IncludeMountPath
    Update-WfSettingsGrid
    foreach ($m in $made) {
        $colour = [System.Drawing.Color]::Gainsboro
        if ($m.Status -eq 'Created') { $colour = [System.Drawing.Color]::LightGreen }
        elseif ($m.Status -eq 'Failed') { $colour = [System.Drawing.Color]::Salmon }
        Write-WfGuiLog ("{0,-14} {1,-8} {2}" -f $m.Setting, $m.Status, $m.Path) $colour
    }
    $statusLabel.Text = 'Folder check complete'
} -X 674 -Width 180 | Out-Null

Add-WfButton $tabSettings 'Check the mount folder' 448 {
    # Whether the mount folder EXISTS is already in the grid. This is the other
    # question: whether an image can actually be mounted there. A mount folder on
    # a sync drive, or deep inside a repository, exists perfectly well and then
    # fails halfway through a servicing run.
    $verdict = Test-WfMountPath -Path $script:Config['MountPath'] -WorkspaceRoot $script:Config['WorkspaceRoot']

    foreach ($f in $verdict.Findings) {
        $colour = [System.Drawing.Color]::LightGreen
        if ($f.Status -eq 'WARN') { $colour = [System.Drawing.Color]::Khaki }
        if ($f.Status -eq 'FAIL') { $colour = [System.Drawing.Color]::Salmon }
        Write-WfGuiLog ("{0,-16} {1,-5} {2}" -f $f.Check, $f.Status, $f.Detail) $colour
    }

    $statusLabel.Text = "Mount folder: $($verdict.Verdict)"

    if ($verdict.Verdict -ne 'OK') {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("The mount folder is:" + [Environment]::NewLine + [Environment]::NewLine + $verdict.Path +
             [Environment]::NewLine + [Environment]::NewLine +
             (($verdict.Findings | Where-Object { $_.Status -ne 'OK' } |
               ForEach-Object { "$($_.Status): $($_.Detail)" }) -join ([Environment]::NewLine + [Environment]::NewLine)) +
             [Environment]::NewLine + [Environment]::NewLine +
             "A mounted image is a live NTFS projection of a whole Windows installation, not a folder of files -- which is why the mount folder does not follow the workspace. A short path at the root of a local disk, like C:\WimMount, is what it wants."),
            "Mount folder: $($verdict.Verdict)", 'OK', 'Information')
    }
} -X 14 -Width 190 | Out-Null

Add-WfLabel $tabSettings 'The mount folder deliberately does not follow the workspace. A mounted image is a live NTFS projection of a whole Windows installation held open by a filter driver, so it wants a short path on a local disk, away from anything that scans, syncs or version-controls the workspace. The live configuration file is created on first run; this repo only ships an example. Use Housekeeping > Edit config file if you would rather see the raw JSON.' 490 | Out-Null


# =============================================================== the log pump

function Write-WfGuiLog {
    <#
        One line into the log pane.

        -NoScroll exists because a servicing run can hand over hundreds of lines
        in a single timer tick, and ScrollToCaret repaints and re-scrolls the
        whole control every time it is called. Done per line that is hundreds of
        scrolls for one visible result, which is what makes the window feel like
        it is fighting you while a job runs. The drain scrolls once, at the end.
    #>
    param([string] $Text, $Color, [switch] $NoScroll)

    if (-not $Color) { $Color = [System.Drawing.Color]::Gainsboro }
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor  = $Color
    $logBox.AppendText($Text + [Environment]::NewLine)
    $logBox.SelectionColor  = $logBox.ForeColor
    if (-not $NoScroll) { $logBox.ScrollToCaret() }
}

# ------------------------------------------------- the working-image bar
# Wired here rather than where the controls are built, because these need
# Show-WfImagePicker and Show-WfIndexPicker, which are defined further up but
# read $script:Config -- and a handler that runs before setup has finished is a
# handler that reads a config that does not exist yet.

function Request-WfMountRefresh {
    <#
        Say that the mount may have changed, so the next tick goes and looks.

        Called from the places that can actually change it -- opening, closing,
        a job finishing, the working image being repointed. Everything else
        leaves the mount table alone, which is the point: reading it is a DISM
        call and it was being made four times a second.
    #>
    $script:MountCheckAt = [datetime]::MinValue
}

function Update-WfMountLabel {
    <#
        One line saying whether the working image is open, because that changes
        what the next click costs: with a mount open an operation is seconds, and
        the mount stays open afterwards.

        Two things this must not do, both learned from a window that flickered:

        It must not be called on a schedule. Get-WfCurrentMount is
        Get-WindowsImage -Mounted, which is a DISM call on the UI thread --
        cheap when it is cheap and not always cheap, and while it runs the
        window is not pumping messages. Request-WfMountRefresh marks it worth
        doing; the timer honours that and otherwise looks at most every few
        seconds as a safety net, because a mount can also be changed by
        something outside this window.

        And it must not write to the controls when nothing has changed. Setting
        Enabled to a value it already holds is free, but this function and the
        timer used to disagree about the same two buttons, and a button whose
        state is set true then false four times a second repaints eight times a
        second. So the whole desired state is worked out first, compared with
        what was last applied, and written only if it differs.
    #>
    param([switch] $Force)

    # ------------------------------------------------------ work out the state
    #
    # Nothing below this block touches a control. The desired appearance is
    # decided first so it can be compared with what is already on screen.
    $state = $null
    $mount = $null

    if (-not (Test-WfElevated)) {
        $state = @{
            Text    = '  NOT ELEVATED  '
            Colour  = [System.Drawing.Color]::Firebrick
            Tip     = 'Images cannot be opened and most reads will fail. Housekeeping > Restart elevated.'
            OpenOn  = $false
            CloseOn = $false
        }
    }
    else {
        try { $mount = Get-WfCurrentMount }
        catch { $mount = $null }

        if (-not $mount) {
            # Closed is a state worth naming, with the cost of changing it, so
            # the next click is not a surprise.
            $state = @{
                Text    = '  IMAGE CLOSED  '
                Colour  = [System.Drawing.Color]::DimGray
                Tip     = 'Nothing is open. A read that needs the image contents will offer to open it first, which takes a few minutes.'
                OpenOn  = [bool]$wfImage.Text
                CloseOn = $false
            }
        }
        else {
            $mode = 'read/write'
            if ($mount.ReadOnly) { $mode = 'read-only' }

            # A mount of something else is worth spotting before an operation
            # refuses: it means the image on screen is not the image that is open.
            if ("$($mount.ImagePath)".TrimEnd('\') -ne "$($wfImage.Text)".TrimEnd('\')) {
                $state = @{
                    Text    = ("  WRONG IMAGE OPEN: {0} [{1}]  " -f (Split-Path $mount.ImagePath -Leaf), $mount.Index)
                    Colour  = [System.Drawing.Color]::Firebrick
                    Tip     = ("{0} index {1} is open, which is not the working image selected above. Close it before working on the other one." -f $mount.ImagePath, $mount.Index)
                    OpenOn  = $false
                    CloseOn = $true
                }
            }
            else {
                $state = @{
                    Text    = ("  IMAGE OPEN: {0} [{1}] {2}  " -f (Split-Path $mount.ImagePath -Leaf), $mount.Index, $mode)
                    Colour  = [System.Drawing.Color]::SeaGreen
                    Tip     = ("{0} index {1} is open {2}. Reads are instant and nothing closes it until you press Close." -f $mount.ImagePath, $mount.Index, $mode)
                    OpenOn  = $false
                    CloseOn = $true
                }
            }
        }
    }

    # Read by everything that wants to know whether an operation will be seconds
    # or minutes, so it is set whether or not the controls need repainting.
    $script:MountOpen = $mount

    # ------------------------------------------------------------- apply it
    #
    # Only if it differs. WinForms guards most property setters against being
    # given what they already hold -- but this function and the timer used to
    # disagree about Open and Close, so those two really did change value twice
    # a tick and really did repaint. One comparison removes the whole class.
    # However this call was reached -- the timer being due, or a button that
    # just changed the mount -- the clock restarts here. So an explicit refresh
    # is not followed by a redundant scheduled one a moment later.
    $script:MountCheckAt = (Get-Date).AddSeconds(5)

    $signature = ('{0}|{1}|{2}|{3}' -f $state.Text, $state.Colour.Name, $state.OpenOn, $state.CloseOn)
    if (-not $Force -and $signature -eq $script:MountSignature) { return }
    $script:MountSignature = $signature

    $wfMountState.Text        = $state.Text
    $wfMountState.ForeColor   = $state.Colour
    $wfMountState.ToolTipText = $state.Tip
    $wfMountBtn.Text          = 'Open image'
    $wfMountBtn.Enabled       = $state.OpenOn
    $wfCloseBtn.Enabled       = $state.CloseOn
}

function Confirm-WfMountNeeded {
    <#
        Asked before anything spends minutes opening an image.

        Three answers, because there are genuinely three things somebody wants:
        keep it open (they are about to do several things), open just for this
        (one look, then leave the disk tidy), or stop. The first is the right
        default for real work and was previously not offered at all -- every read
        opened and closed its own mount, so five reads cost five mounts.

        Returns 'keep', 'once' or 'no'. When the image is ALREADY open this does
        not ask at all: it is already paid for, and closing it would be the
        expensive mistake.
    #>
    param([string] $What = 'This')

    if ($script:MountOpen) { return 'keep' }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("$What needs the image opened, which takes a few minutes." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Yes  - open it and LEAVE IT OPEN. Everything after this is then instant, until you press Close." +
         [Environment]::NewLine +
         "No   - open it just for this one read and close it again." +
         [Environment]::NewLine + [Environment]::NewLine +
         "If you have more than one thing to do with this image, Yes is the one that saves the time."),
        'Open the image?', 'YesNoCancel', 'Question')

    switch ($answer) {
        'Yes' { return 'keep' }
        'No'  { return 'once' }
        default { return 'no' }
    }
}

$wfMountBtn.Add_Click({
    if (-not $wfImage.Text) {
        [void][System.Windows.Forms.MessageBox]::Show('Pick an image first.', 'No image', 'OK', 'Information')
        return
    }
    $idx = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$idx)) { $idx = 1 }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Open this image and keep it open?" + [Environment]::NewLine + [Environment]::NewLine +
         "$($wfImage.Text)  (index $idx)" + [Environment]::NewLine + [Environment]::NewLine +
         "Opening takes a few minutes. Everything afterwards is instant, and nothing closes it until you press Close." +
         [Environment]::NewLine + [Environment]::NewLine +
         "Yes - open read/write, so changes can be committed." + [Environment]::NewLine +
         "No  - open read-only, for looking only. Safer, and cannot commit anything."),
        'Open the image', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }
    $ro = ($answer -eq 'No')

    Start-WfJob -Title 'Open the image' -Arguments @{ p = $wfImage.Text; i = $idx; ro = $ro } -Body {
        Mount-WfImage -ImagePath $p -Index $i -ReadOnly:$ro
    } -OnComplete { param($r) Update-WfMountLabel }
})

$wfCloseBtn.Add_Click({
    $m = $script:MountOpen
    if (-not $m) { Update-WfMountLabel; return }

    $save = $false
    if (-not $m.ReadOnly) {
        # The one question that cannot be got wrong quietly. A read/write mount
        # closed with Discard throws away everything done to it, and closed with
        # Save commits it -- and neither is recoverable afterwards.
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Close $(Split-Path $m.ImagePath -Leaf), index $($m.Index)." + [Environment]::NewLine + [Environment]::NewLine +
             "It is open read/write, so there may be changes in it." + [Environment]::NewLine + [Environment]::NewLine +
             "Yes - COMMIT the changes into the image file." + [Environment]::NewLine +
             "No  - DISCARD them and leave the image as it was." + [Environment]::NewLine + [Environment]::NewLine +
             "Committing takes a while; discarding is quick. Neither can be undone."),
            'Commit or discard?', 'YesNoCancel', 'Warning')
        if ($answer -eq 'Cancel') { return }
        $save = ($answer -eq 'Yes')
    }

    Start-WfJob -Title 'Close the image' -Arguments @{ mp = $m.MountPath; save = $save } -Body {
        if ($save) { Dismount-WfImage -MountPath $mp -Save }
        else       { Dismount-WfImage -MountPath $mp -Discard }
    } -OnComplete { param($r) Update-WfMountLabel }
})

$wfImagePick.Add_Click({
    $picked = Show-WfImagePicker -Folder $script:Config['ImageRoot']
    if (-not $picked) { return }

    $wfImage.Text     = $picked
    $wfIdentity.Text  = 'Not read yet.'
    $script:UpdateTarget = $null

    # Straight on to the index, since that is the other half of the choice.
    $idx = Show-WfIndexPicker -ImagePath $picked -Reason 'Which index do you want to work on?'
    if ($null -ne $idx) { $wfIndex.Text = "$idx" }

    # And read it. Seconds, no mount, and it means the release and build are on
    # screen before anything is done to the image.
    $i = 0
    if (-not [int]::TryParse($wfIndex.Text, [ref]$i)) { $i = 1 }
    Start-WfJob -Title 'Read the working image' -Arguments @{ p = $picked; i = $i; pkg = $false; nm = $false } -Body {
        Get-WfImageUpdateTarget -ImagePath $p -Index $i -IncludePackage:$pkg -NoMount:$nm
    } -OnComplete {
        param($found)
        if (-not $found) { return }
        $script:UpdateTarget = $found
        # The image's answer goes to the top of the list, marked as having come
        # from evidence rather than from a written-down default.
        Set-WfChoiceItems -Combo $updProduct -Select $found.Product -BlankLabel '(type a product)' `
            -Items (ConvertTo-WfChoiceItem -Source (Get-WfUpdateProductChoice -Target $found) `
                                           -ValueProperty Product -LabelProperty Note)
        Set-WfChoiceItems -Combo $updArch -Select $found.Architecture -BlankLabel '(type an architecture)' `
            -Items (ConvertTo-WfChoiceItem -Source (Get-WfUpdateArchitectureChoice) `
                                           -ValueProperty Architecture -LabelProperty Note)

        $text = "$($found.Product)  $($found.Architecture)"
        if ($found.FullBuild) { $text = "$text   build $($found.FullBuild)" }
        if ($found.EditionId) { $text = "$text   $($found.EditionId)" }
        if (-not $found.Precise) { $text = "$text   (release is a guess -- see the log)" }
        $wfIdentity.Text = $text
    }
})

$wfIndexPick.Add_Click({
    $idx = Show-WfIndexPicker -ImagePath $wfImage.Text -Reason 'Which index do you want to work on?'
    if ($null -ne $idx) {
        $wfIndex.Text    = "$idx"
        $wfIdentity.Text = 'Index changed -- use "Read this image" on the Updates tab to read it again.'
    }
})

$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    # ---------------------------------------------------------------- the log
    #
    # Drained in one go and scrolled once at the end. A servicing run can hand
    # over hundreds of lines in a single tick, and scrolling per line is
    # hundreds of repaints for one visible result.
    $drained = 0
    while ($script:Sync.Queue.Count -gt 0) {
        $line  = [string]$script:Sync.Queue.Dequeue()
        $color = [System.Drawing.Color]::Gainsboro
        if     ($line -match '\[ERROR\]|^ERROR:') { $color = [System.Drawing.Color]::Salmon }
        elseif ($line -match '\[WARN')            { $color = [System.Drawing.Color]::Khaki }
        elseif ($line -match '\[OK')              { $color = [System.Drawing.Color]::LightGreen }
        elseif ($line -match '\[STEP')            { $color = [System.Drawing.Color]::SkyBlue }
        elseif ($line -match '^===')              { $color = [System.Drawing.Color]::White }
        Write-WfGuiLog $line $color -NoScroll
        $drained++
    }
    if ($drained -gt 0) { $logBox.ScrollToCaret() }

    if ($script:Sync.Running) {
        # Only when it CHANGES. This used to rewrite every action button and the
        # form cursor on every tick -- and Control.Cursor forces a WM_SETCURSOR
        # whether the value changed or not, which is what pushed the I-beam back
        # to an arrow four times a second.
        if ($script:LastRunning -ne $true) {
            foreach ($b in $script:ActionButtons) { $b.Enabled = $false }
            $form.Cursor = [System.Windows.Forms.Cursors]::AppStarting
            $script:LastRunning = $true
        }

        # Elapsed time is available for everything and is the honest minimum:
        # even with no percentage, a number that keeps climbing is the difference
        # between "working" and "hung".
        $elapsed = ''
        if ($script:Sync.Started) {
            $t = (Get-Date) - $script:Sync.Started
            if ($t.TotalMinutes -ge 1) { $elapsed = ('  {0}m{1:00}s' -f [int]$t.TotalMinutes, $t.Seconds) }
            else                       { $elapsed = ('  {0}s' -f [int]$t.TotalSeconds) }
        }

        # The percentage, if the cmdlet running in the runspace is reporting one.
        $pct  = -1
        $what = ''
        try {
            if ($script:PowerShell -and $script:PowerShell.Streams.Progress.Count -gt 0) {
                $rec = $script:PowerShell.Streams.Progress[$script:PowerShell.Streams.Progress.Count - 1]
                if ($rec) {
                    # A completed record is stale -- it is the previous step
                    # signing off, not the current one standing still.
                    if ($rec.RecordType -ne 'Completed') {
                        $pct  = [int]$rec.PercentComplete
                        $what = "$($rec.StatusDescription)"
                        if (-not $what) { $what = "$($rec.Activity)" }
                    }
                }
            }
        }
        catch { }

        if ($pct -ge 0 -and $pct -le 100) {
            if ($wfProgress.Style -ne 'Continuous') { $wfProgress.Style = 'Continuous' }
            $wfProgress.Value   = $pct
            $wfProgress.Visible = $true

            $detail = ''
            if ($what) { $detail = " -- $what" }
            $statusLabel.Text = "Running: $($script:Sync.Title)  $pct%$detail$elapsed"
        }
        else {
            # No percentage on offer. A marquee says "busy, no estimate", which is
            # true, rather than a bar frozen at 0% which reads as stuck.
            if ($wfProgress.Style -ne 'Marquee') { $wfProgress.Style = 'Marquee' }
            $wfProgress.Visible = $true
            $statusLabel.Text   = "Running: $($script:Sync.Title) ...$elapsed"
        }
        return
    }

    # Finished, one way or another.
    if ($wfProgress.Visible) {
        $wfProgress.Visible = $false
        $wfProgress.Style   = 'Continuous'
        $wfProgress.Value   = 0
    }

    if ($script:LastRunning -ne $false) {
        foreach ($b in $script:ActionButtons) { $b.Enabled = $true }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $script:LastRunning = $false

        # The blanket enable above just turned Open and Close on regardless of
        # whether an image is open, so the mount state has to have the last word
        # -- immediately, and forced past the no-change check.
        Request-WfMountRefresh
    }

    # The mount table is a DISM call, so it is read when something might have
    # changed it and otherwise at a walking pace. Not on every tick: four DISM
    # calls a second on the UI thread is why clicks went missing. The call
    # restarts its own clock, so this is the only place the schedule is read.
    if ((Get-Date) -ge $script:MountCheckAt) { Update-WfMountLabel }

    # Drain a finished job exactly once.
    #
    # "Exactly once" needs a real guard, not just a null check, because of one
    # WinForms behaviour that is easy to forget: MessageBox.Show pumps the
    # message loop while it is open. The timer therefore keeps firing WHILE a
    # dialog is up, on this same thread, and re-enters this handler -- at which
    # point $script:PowerShell is still non-null (it is not cleaned up until the
    # bottom of this block) and $script:Sync.Result is still set, so the whole
    # drain runs a second time.
    #
    # The symptom was a job's result table appearing twice in the log with one
    # dialog, and only for jobs whose completion callback shows a dialog -- which
    # is exactly the set of jobs that pump the loop. It looked like the module
    # returning two objects, and it was not.
    if (-not $script:PowerShell) { return }
    if ($script:Draining) { return }
    $script:Draining = $true

    $result = $script:Sync.Result
    $err    = $script:Sync.Error

    # Taken and cleared before anything that can pump the loop, so a re-entrant
    # tick that somehow got past the flag still finds nothing to report twice.
    $script:Sync.Result = $null
    $script:Sync.Error  = $null

    if ($err) {
        $statusLabel.Text = "Failed: $($script:Sync.Title)"
        Write-WfGuiLog "FAILED: $err" ([System.Drawing.Color]::Salmon)

        # A DISM hex code on its own tells an operator nothing. If the message
        # carries one this toolkit recognises, what it means and what to do about
        # it go into the log directly under it.
        try {
            $why = Get-WfDismError -Message $err
            if ($why.Recognised) {
                Write-WfGuiLog "  $($why.Summary)" ([System.Drawing.Color]::Khaki)
                Write-WfGuiLog "  $($why.WhatToDo)" ([System.Drawing.Color]::Gainsboro)
            }
        }
        catch { }

        # Assert-WfElevated tags its message, so the one action that actually
        # fixes this can be offered instead of a dead end.
        if ($err -match 'NEEDS ELEVATION') {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "That operation needs administrator rights.`n`nRestart elevated now?",
                'Administrator rights needed', 'YesNo', 'Warning')
            if ($answer -eq 'Yes' -and (Invoke-WfGuiElevate)) { $form.Close(); return }
        }
        else {
            Write-WfGuiLog 'If a mount was left behind, use Housekeeping > Repair stale mounts.' ([System.Drawing.Color]::Khaki)
        }
    }
    else {
        $statusLabel.Text = "Finished: $($script:Sync.Title)"
        if ($null -ne $result) {
            $text = $result | Format-Table -AutoSize | Out-String -Width 200
            foreach ($l in ($text -split "`r?`n")) {
                if ($l.Trim()) { Write-WfGuiLog $l ([System.Drawing.Color]::LightSteelBlue) }
            }
            if     ($tabs.SelectedTab -eq $tabDrivers) { Set-WfGrid $drvGrid   $result }
            elseif ($tabs.SelectedTab -eq $tabHouse)   { Set-WfGrid $houseGrid $result }
        }
    }

    # Whatever the outcome, the callback fires at most once. Cleared before it
    # runs, so a callback that throws cannot leave itself armed for the next job.
    if ($script:JobOnComplete) {
        $callback = $script:JobOnComplete
        $script:JobOnComplete = $null
        if (-not $err) {
            try { & $callback $result }
            catch { Write-WfGuiLog "Follow-up failed: $($_.Exception.Message)" ([System.Drawing.Color]::Salmon) }
        }
    }

    # EndInvoke, and surface anything the job's own try/catch never saw --
    # otherwise a terminating error outside that block vanishes and the UI
    # cheerfully reports "Finished".
    try { if ($script:Handle) { [void]$script:PowerShell.EndInvoke($script:Handle) } } catch {
        Write-WfGuiLog "Job ended with: $($_.Exception.Message)" ([System.Drawing.Color]::Salmon)
    }
    foreach ($e in $script:PowerShell.Streams.Error) {
        Write-WfGuiLog "STREAM ERROR: $e" ([System.Drawing.Color]::Salmon)
    }

    try { $script:PowerShell.Dispose() } catch { }
    try { $script:Runspace.Close(); $script:Runspace.Dispose() } catch { }
    $script:PowerShell  = $null
    $script:Runspace    = $null
    $script:Handle      = $null

    # Last, and outside any try: if this is not reset the tab goes deaf to every
    # job that follows.
    $script:Draining = $false
})

$form.Add_Shown({
    # Set here rather than at construction: SplitterDistance is clamped against
    # the container's real height, which is not known until the form is shown.
    #
    # Expressed as "the log gets 190px" rather than "the tabs get 580px". The log
    # is a fixed-value thing -- eight or nine lines is as useful as it gets, and
    # every pixel beyond that was coming out of the results grid above it, which
    # is the part that scales with how much there is to show.
    $wanted = $split.Height - 190 - $split.SplitterWidth
    $limit  = $split.Height - $split.Panel2MinSize - $split.SplitterWidth
    if ($wanted -gt $limit)  { $wanted = $limit }
    if ($wanted -ge $split.Panel1MinSize) {
        try { $split.SplitterDistance = $wanted } catch { }
    }

    # Now that the pages have their real size, let every grid claim what is left
    # of its page. Until this runs they are all still at their construction
    # height, which on most tabs runs off the bottom.
    foreach ($fit in $script:GridFit) { try { & $fit } catch { } }

    $timer.Start()
    foreach ($line in (Get-WfBannerArt)) { Write-WfGuiLog $line ([System.Drawing.Color]::SkyBlue) }
    Write-WfGuiLog ("{0} {1}   {2}" -f $script:About.Name, $script:About.Version, $script:About.Tagline) ([System.Drawing.Color]::White)
    Write-WfGuiLog ("{0}   {1}" -f $script:About.Author, $script:About.Repository) ([System.Drawing.Color]::Gray)
    Write-WfGuiLog ''
    Write-WfGuiLog "Config file : $script:ConfigFile"
    Write-WfGuiLog "Base image  : $($script:Config['BaseImage'])"
    Write-WfGuiLog "Driver root : $($script:Config['DriverRoot'])"

    if (-not (Test-WfElevated)) {
        Write-WfGuiLog 'NOT ELEVATED -- anything that mounts an image will fail.' ([System.Drawing.Color]::Salmon)

        $wantElevate = $Elevate
        if (-not $Elevate) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "This is not running as administrator, and DISM cannot mount an image without it.`n`n" +
                "A process cannot grant itself rights, so this will open a new elevated window and close this one.`n`n" +
                "Restart elevated now?",
                'Administrator rights needed', 'YesNo', 'Warning')
            $wantElevate = ($answer -eq 'Yes')
        }
        if ($wantElevate -and (Invoke-WfGuiElevate)) { $form.Close(); return }
    }
    Write-WfGuiLog 'Start with Housekeeping > Environment check.' ([System.Drawing.Color]::SkyBlue)

    Update-WfSettingsGrid

    try { Set-WfGrid $drvGrid (Get-WfDriverLibrary) } catch {
        Write-WfGuiLog "Driver library not readable yet: $($_.Exception.Message)" ([System.Drawing.Color]::Khaki)
    }

    # A first run, or a config pointing at drives this machine does not have,
    # lands on Settings rather than letting every action fail one at a time.
    $setup = Test-WfSetupRequired
    if ($setup.Required) {
        foreach ($r in $setup.Reasons) { Write-WfGuiLog "SETUP: $r" ([System.Drawing.Color]::Khaki) }

        $suggested = Get-WfSuggestedRoot

        # The alternatives are shown rather than just the winner, because "put it
        # next to the toolkit" is the obvious instinct and whether it is a good
        # one depends entirely on where the toolkit ended up.
        $options = @(Get-WfWorkspaceOption)
        foreach ($o in $options) {
            $colour = [System.Drawing.Color]::Gainsboro
            if ($o.Note -like 'not advised*') { $colour = [System.Drawing.Color]::Khaki }
            Write-WfGuiLog ("OPTION: {0}  ({1}{2}){3}" -f $o.Path, $o.Why,
                $(if ($o.FreeGb -gt 0) { ', {0:N1} GB free' -f $o.FreeGb } else { '' }),
                $(if ($o.Note) { " -- $($o.Note)" } else { '' })) $colour
        }

        $others = ''
        $rest = @($options | Where-Object { $_.Path -ne $suggested } | Select-Object -First 2)
        if ($rest.Count -gt 0) {
            $others = [Environment]::NewLine + [Environment]::NewLine + "The alternatives are in the log, including putting it next to the toolkit -- Settings can move it later."
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("This machine is not set up yet:" + [Environment]::NewLine + [Environment]::NewLine +
             (($setup.Reasons | Select-Object -First 4) -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine +
             "Set the imaging workspace to" + [Environment]::NewLine + "$suggested" + [Environment]::NewLine + [Environment]::NewLine +
             "and create the folders now?" + $others + [Environment]::NewLine + [Environment]::NewLine +
             "Choose No to pick a different folder on the Settings tab."),
            'Setup needed', 'YesNo', 'Question')

        if ($answer -eq 'Yes') {
            $script:Config = Set-WfWorkspaceRoot -Path $suggested -CreateFolders -Confirm:$false
            $script:Config = Set-WfConfig -Settings @{ SetupComplete = $true } -Confirm:$false
            Update-WfSettingsGrid
            Write-WfGuiLog "Workspace set to $suggested" ([System.Drawing.Color]::LightGreen)

            # The mount folder does not follow the workspace, so it is judged on
            # its own -- here, rather than at the first failed mount.
            try {
                $mv = Test-WfMountPath -Path $script:Config['MountPath'] -WorkspaceRoot $suggested
                foreach ($f in $mv.Findings) {
                    if ($f.Status -eq 'OK') { continue }
                    $c = [System.Drawing.Color]::Khaki
                    if ($f.Status -eq 'FAIL') { $c = [System.Drawing.Color]::Salmon }
                    Write-WfGuiLog ("MOUNT: {0} -- {1}" -f $f.Check, $f.Detail) $c
                }
            }
            catch { Write-WfGuiLog "Could not check the mount folder: $($_.Exception.Message)" ([System.Drawing.Color]::Khaki) }
        }
        $tabs.SelectedTab = $tabSettings
    }
})

$form.Add_FormClosing({
    param($eventSender, $eventArgs)
    if ($script:Sync.Running) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "An operation is still running. Closing now could leave a mounted image behind.`n`nClose anyway?",
            'Still running', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $eventArgs.Cancel = $true; return }
    }
    $timer.Stop()
    try { if ($script:PowerShell) { $script:PowerShell.Dispose() } } catch { }
    try { if ($script:Runspace)   { $script:Runspace.Dispose() } }  catch { }
})

[void]$form.ShowDialog()
