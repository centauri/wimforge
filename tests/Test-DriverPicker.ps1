# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Which driver models go into an image is a choice made from the library, not
# typed from memory.
#
# The GUI asked for it with an InputBox -- "Driver model folders, comma
# separated. Blank = the whole library." -- in four places. That asks the
# operator to remember what a folder harvested six months ago was called and to
# spell it the way the harvest did. Get one character wrong and Add-WfDriver
# throws "Model folder(s) not found", which on a servicing run happens after the
# copy and the mount, twenty minutes in.
#
# The console menu has listed the library since the beginning (Select-WfModel).
# The window, which is the one people actually use, did not -- and Test-
# FrontEndParity could never see it, because both front-ends call
# Add-WfDriver -Models and differ only in where the value came from.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

$gui  = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeGui.ps1')  -Raw
$menu = Get-Content -LiteralPath (Join-Path $root 'Start-WimForgeMenu.ps1') -Raw

# --------------------------------------------------------- nothing is typed
Write-Host 'Model folders are picked, not typed' -ForegroundColor Cyan

# The prompt text itself, in either front-end. It is quoted here in full because
# the point is that this exact question stops being asked.
Test-Case 'the GUI no longer asks for a comma-separated list' $false `
    ($gui -match "InputBox\(\s*'Driver model folders, comma separated")
Test-Case 'nor for model folder names'                        $false `
    ($gui -match "InputBox\(\s*'Model folder names, comma separated")

Test-Case 'the picker exists'          $true ($gui -match 'function Show-WfModelPicker')
Test-Case 'and reads the real library' $true ($gui -match '(?s)function Show-WfModelPicker.*?Get-WfDriverLibrary')

# The console menu's equivalent, unchanged -- this is the parity being restored.
Test-Case 'the menu still lists the library' $true ($menu -match '(?s)function Select-WfModel.*?Get-WfDriverLibrary')

# --------------------------------------------------- every site uses it
Write-Host 'Every driver-model choice goes through the picker' -ForegroundColor Cyan

# Four call sites: the servicing run, inject drivers, PE drivers, recovery
# drivers. Counted rather than spot-checked, because the failure mode is one of
# them being missed and staying an InputBox forever.
$calls = @([regex]::Matches($gui, 'Show-WfModelPicker -Title'))
Test-Case 'four places ask for models' 4 $calls.Count

# ------------------------------------------------------- cancel means cancel
Write-Host 'Cancel is a distinct answer' -ForegroundColor Cyan

# Three answers, not two: cancel, the whole library, and these ones. An array
# cannot carry the first two -- an empty array returned from a PowerShell
# function reaches the caller as $null, indistinguishable from a cancel -- so the
# picker returns an object, and every caller has to check it.
#
# Without this, shutting the dialog on a servicing run would start a three-hour
# job rather than stopping it.
$guards = @([regex]::Matches($gui, 'if \(\$pick\.Cancelled\) \{ return \}'))
Test-Case 'each site honours a cancel' 4 $guards.Count

Test-Case 'the picker reports cancelled' $true ($gui -match 'Cancelled = \$true')
Test-Case 'and the whole library'        $true ($gui -match 'Cancelled = \$false; All = \$true')
Test-Case 'and a subset'                 $true ($gui -match 'Cancelled = \$false; All = \$false; Models =')
Test-Case 'through the shared picker'    $true ($gui -match 'function Show-WfListPicker')
Test-Case 'which the model picker uses'  $true ($gui -match '(?s)function Show-WfModelPicker.*?Show-WfListPicker -Title')

# An empty library is not an error to throw at someone mid-run: it means the
# harvest has not happened yet, and the answer is on another tab.
Test-Case 'an empty library is explained' $true ($gui -match 'no model folders in the driver library yet')
Test-Case 'and the folder is named'       $true ($gui -match '(?s)function Show-WfModelPicker.*?\$root\s*=\s*\$script:Config\[.DriverRoot.\]')

# ------------------------------------------- the library folder can be overruled
Write-Host 'The driver library folder can be overruled per session' -ForegroundColor Cyan

# One configured DriverRoot, and an engineer with more than one library: last
# quarter's, a colleague's, one on a share for a customer's fleet. Editing the
# setting to service one image and remembering to put it back is how the wrong
# drivers end up in an image -- and nothing downstream would ever report it.
Test-Case 'the GUI has a folder box'   $true ($gui -match "Add-WfTextBox\s+\`$tabDrivers 'Driver library folder'")
Test-Case 'and it browses'             $true ($gui -match '-PickFolder -PickFolderTitle')
Test-Case 'with a real folder dialog'  $true ($gui -match '(?s)if \(\$PickFolder\).*?New-Object System\.Windows\.Forms\.FolderBrowserDialog')

# Empty box = the configured folder. There is always a defined answer, and it is
# on screen rather than on another tab.
Test-Case 'empty falls back to the config' $true `
    ($gui -match '(?s)function Get-WfGuiDriverRoot.*?if \(-not \$v\)\s*\{ \$v = \[string\]\$script:Config\[.DriverRoot.\] \}')

# Every driver operation in the window, not just the ones on that tab. A harvest
# writing to one library while an injection reads another would be a silent
# split, and the harvest one is -Destination rather than -DriverRoot.
Test-Case 'the harvest writes there'      $true ($gui -match 'Export-WfModelDriver -ModelName \$n -Destination \$root')
Test-Case 'the library view reads there'  $true ($gui -match 'Get-WfDriverLibrary -DriverRoot \$root')
Test-Case 'injection takes it'            $true ($gui -match 'Add-WfDriver -Models \$models -DriverRoot \$root')
Test-Case 'the whole-library case too'    $true ($gui -match 'Add-WfDriver -DriverRoot \$root -ExcludeMicrosoft')
Test-Case 'the servicing run takes it'    $true ($gui.Contains("if (`$root) { `$p['DriverRoot'] = `$root }"))
Test-Case 'PE drivers take it'            $true ($gui.Contains("if (`$root) { `$prm['DriverRoot'] = `$root }"))
Test-Case 'recovery drivers take it'      $true ($gui -match 'Add-WfRecoveryDriver -Models \$models -DriverRoot \$root')
Test-Case 'compare takes it'              $true ($gui -match 'Compare-WfDriver -ImagePath \$src -Index \$idx -DriverRoot \$root')
Test-Case 'removal takes it'              $true ($gui -match 'Remove-WfModelDriver -Model \$model -DriverRoot \$root')
Test-Case 'de-duplication takes it'       $true ($gui -match 'Remove-WfDuplicateDriver -Model \$model -DriverRoot \$root')

# The picker must list the SAME library the injection will read from. Listing one
# and injecting from another is a mismatch nothing downstream would report.
Test-Case 'the picker is told which library' 4 `
    @([regex]::Matches($gui, 'Show-WfModelPicker -Title [^\r\n]*-DriverRoot \$drvFrom')).Count

# A job body runs in its own runspace and cannot see a WinForms control, so the
# path has to be read on the UI thread and passed in as a plain string. A job
# that quietly used the configured folder instead of the one on screen is the
# worst possible version of this bug.
Test-Case 'the path is passed into jobs, not read inside them' $false `
    ($gui -match '(?s)-Body \{[^}]*\$drvRoot\.Text')

Write-Host 'And the console menu can do the same' -ForegroundColor Cyan

# Parity, and the kind Test-FrontEndParity CAN see: it compares the parameters
# each front-end passes, so a -DriverRoot the GUI passes and the menu does not
# shows up as a parameter-only mismatch.
Test-Case 'the menu has an override'      $true ($menu -match 'function Set-WfMenuDriverRoot')
Test-Case 'reachable from the menu'       $true ($menu -match "Key = 'root'")
Test-Case 'it browses for the folder'     $true ($menu -match '(?s)function Set-WfMenuDriverRoot.*?Show-WfFolderDialog')
Test-Case 'and can be cleared again'      $true `
    ($menu -match '(?s)function Set-WfMenuDriverRoot.*?\$answer -eq ''reset''')
Test-Case 'it is a session override'      $true ($menu -match '\$script:DriverRootOverride = ')

# Not written to the configuration: the whole point is not having to edit a
# setting and remember to put it back.
Test-Case 'nothing is saved to the config' $false ($menu -match "Set-WfConfig[^\r\n]*DriverRoot")

foreach ($call in @(
    'Get-WfDriverLibrary -DriverRoot \$root',
    'Export-WfModelDriver -ModelName \$name -Destination \$root',
    'Add-WfDriver -Models \$models -DriverRoot \(Get-WfMenuDriverRoot\)',
    'Add-WfBootDriver[^\r\n]*-DriverRoot \(Get-WfMenuDriverRoot\)',
    'Add-WfRecoveryDriver -Models \$models -DriverRoot \(Get-WfMenuDriverRoot\)',
    'Compare-WfDriver[^\r\n]*-DriverRoot \(Get-WfMenuDriverRoot\)',
    'Remove-WfModelDriver -Model \$m -DriverRoot \(Get-WfMenuDriverRoot\)',
    'Remove-WfDuplicateDriver -Model \$models -DriverRoot \(Get-WfMenuDriverRoot\)'
)) {
    Test-Case "the menu passes it to $(($call -split ' ')[0] -replace '\\','')" $true ($menu -match $call)
}

# And the module has somewhere to put it. These two had no -DriverRoot at all, so
# an override would have been accepted by the front-end and silently dropped.
$svc  = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw
$slim = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Slimming.ps1')  -Raw
Test-Case 'Invoke-WfServicingRun accepts one' $true ($svc -match '(?s)function Invoke-WfServicingRun.*?\[string\]\s*\$DriverRoot')
Test-Case 'and hands it to Add-WfDriver'      $true ($svc.Contains("if (`$DriverRoot) { `$drvParams['DriverRoot'] = `$DriverRoot }"))
Test-Case 'Add-WfRecoveryDriver accepts one'  $true ($slim -match '(?s)function Add-WfRecoveryDriver.*?\[string\]\s*\$DriverRoot')
Test-Case 'and hands it on too'               $true ($slim.Contains("if (`$DriverRoot) { `$recParams['DriverRoot'] = `$DriverRoot }"))

# ------------------------------------------------------------ it fits on screen
Write-Host 'Dialog controls fit inside their dialog' -ForegroundColor Cyan

# The same arithmetic Test-GuiLayout does for panels, for the dialogs -- which it
# does not cover. A control placed past the edge of a form is not an error and
# not a warning: it is simply not visible, and on a picker the control that goes
# missing is usually the OK button.
#
# Client area, not window: Windows spends roughly 16px on the borders and 39 on
# the title bar, and a button whose bottom edge lands in the title bar of the
# window below is just as unreachable as one off the screen.
$problems = @()
foreach ($form in [regex]::Matches($gui, '\$(\w+)\s*=\s*New-Object System\.Windows\.Forms\.Form')) {
    $name  = $form.Groups[1].Value
    $start = $form.Index

    $endMatch = [regex]::Match($gui.Substring($start), '\$' + [regex]::Escape($name) + '\.ShowDialog\(\)')
    $end   = if ($endMatch.Success) { $start + $endMatch.Index } else { $gui.Length }
    $block = $gui.Substring($start, $end - $start)

    $sizeSet = [regex]::Match($block, '\$' + [regex]::Escape($name) + '\.Size\s*=\s*New-Object System\.Drawing\.Size\((\d+),\s*(\d+)\)')
    if (-not $sizeSet.Success) { continue }      # a form that sizes itself cannot be measured

    $clientW = [int]$sizeSet.Groups[1].Value - 16
    $clientH = [int]$sizeSet.Groups[2].Value - 39

    foreach ($loc in [regex]::Matches($block, '\$(\w+)\.Location\s*=\s*New-Object System\.Drawing\.Point\((\d+),\s*(\d+)\)')) {
        $child = $loc.Groups[1].Value
        if ($child -eq $name) { continue }
        $x = [int]$loc.Groups[2].Value
        $y = [int]$loc.Groups[3].Value

        $size = [regex]::Match($block, '\$' + [regex]::Escape($child) + '\.Size\s*=\s*New-Object System\.Drawing\.Size\((\d+),\s*(\d+)\)')
        if (-not $size.Success) { continue }
        $w = [int]$size.Groups[1].Value
        $h = [int]$size.Groups[2].Value

        if (($x + $w) -gt $clientW) { $problems += "$name/$child : right edge $($x + $w) past $clientW" }
        if (($y + $h) -gt $clientH) { $problems += "$name/$child : bottom edge $($y + $h) past $clientH" }
    }
}
Test-Case 'nothing hangs off a dialog' @() $problems

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
