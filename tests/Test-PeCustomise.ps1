# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Your own software inside WinPE.
#
# Three of the things this file guards fail SILENTLY on the terminal, which is
# the whole reason they are checked here rather than left to the person holding
# the USB stick:
#
#   an .msi in the tool folder      -- there is no Windows Installer service in
#                                      WinPE, so nothing would ever install it
#   a 32-bit binary in an amd64 PE  -- there is no WoW64; the command returns
#                                      instantly and does nothing at all
#   startnet.cmd without wpeinit    -- no Plug and Play devices, no network, and
#                                      an application that looks broken for
#                                      reasons that have nothing to do with it
#
# The fourth is the dependency order. A component added before what it needs
# installs cleanly and then misbehaves, so the chain is pinned against
# Microsoft's documented one rather than trusted.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

. (Join-Path $root 'WimForge\Private\Core.ps1')
. (Join-Path $root 'WimForge\Public\PeCustomise.ps1')

$work = Join-Path ([IO.Path]::GetTempPath()) ('wf-pe-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $work -Force | Out-Null

Write-Host ''
Write-Host 'Reading a binary''s architecture out of its header' -ForegroundColor Cyan

function New-FakeBinary {
    <#
        A minimal but real PE header: 'MZ', e_lfanew at 0x3C pointing at a
        'PE\0\0' signature, then the machine word. That is exactly what
        Get-WfPeBinaryArchitecture reads, so a file built this way exercises the
        real code path rather than a stub of it.
    #>
    param([string] $Path, [int] $Machine)

    $bytes = New-Object byte[] 0x100
    $bytes[0] = 0x4D; $bytes[1] = 0x5A                       # MZ
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C) # e_lfanew
    $bytes[0x80] = 0x50; $bytes[0x81] = 0x45                 # PE
    $bytes[0x82] = 0x00; $bytes[0x83] = 0x00
    [BitConverter]::GetBytes([uint16]$Machine).CopyTo($bytes, 0x84)
    [IO.File]::WriteAllBytes($Path, $bytes)
    return $Path
}

$x64   = New-FakeBinary (Join-Path $work 'tool64.exe')  0x8664
$x86   = New-FakeBinary (Join-Path $work 'tool32.exe')  0x014C
$arm   = New-FakeBinary (Join-Path $work 'toolarm.exe') 0xAA64
$plain = Join-Path $work 'readme.txt'
Set-Content -LiteralPath $plain -Value 'not a binary'

Test-Case 'an amd64 binary'  'x64'   (Get-WfPeBinaryArchitecture -Path $x64)
Test-Case 'an x86 binary'    'x86'   (Get-WfPeBinaryArchitecture -Path $x86)
Test-Case 'an arm64 binary'  'arm64' (Get-WfPeBinaryArchitecture -Path $arm)

# The whole point of returning '' rather than throwing: this walks entire
# folders, and most of what is in them is not an executable.
Test-Case 'a text file is not an architecture' '' (Get-WfPeBinaryArchitecture -Path $plain)
Test-Case 'a missing file does not throw'      '' (Get-WfPeBinaryArchitecture -Path (Join-Path $work 'nope.exe'))

# Truncated after the MZ. A real folder eventually contains one of these, and
# reading past the end of it would take a build down.
$stub = Join-Path $work 'stub.exe'
[IO.File]::WriteAllBytes($stub, [byte[]]@(0x4D, 0x5A, 0x90, 0x00))
Test-Case 'a truncated binary does not throw' '' (Get-WfPeBinaryArchitecture -Path $stub)

Write-Host ''
Write-Host 'DISM''s architecture numbers' -ForegroundColor Cyan

# 0, 9 and 12 are the SYSTEM_INFO processor architecture constants, which is why
# they look arbitrary. Getting 9 wrong would compare every binary against the
# string '9' and pass everything.
Test-Case 'DISM 0 is x86'    'x86'   (ConvertFrom-WfImageArchitecture 0)
Test-Case 'DISM 9 is x64'    'x64'   (ConvertFrom-WfImageArchitecture 9)
Test-Case 'DISM 12 is arm64' 'arm64' (ConvertFrom-WfImageArchitecture 12)
Test-Case 'the string form works too' 'x64' (ConvertFrom-WfImageArchitecture 'AMD64')

Write-Host ''
Write-Host 'Optional components and their dependencies' -ForegroundColor Cyan

# Microsoft: "Install WinPE-WMI > WinPE-NetFX > WinPE-Scripting before you
# install WinPE-PowerShell."
Test-Case 'PowerShell pulls in its chain, in order' `
    'WinPE-WMI, WinPE-NetFX, WinPE-Scripting, WinPE-PowerShell' `
    ((Resolve-WfPeComponentOrder -Name 'WinPE-PowerShell') -join ', ')

# "Install WinPE-WMI > WinPE-NetFX > WinPE-Scripting > WinPE-PowerShell before
# you install WinPE-StorageWMI."
Test-Case 'StorageWMI goes one deeper' `
    'WinPE-WMI, WinPE-NetFX, WinPE-Scripting, WinPE-PowerShell, WinPE-StorageWMI' `
    ((Resolve-WfPeComponentOrder -Name 'WinPE-StorageWMI') -join ', ')

# "Install WinPE-WMI before you install WinPE-NetFX."
Test-Case 'NetFX needs WMI' 'WinPE-WMI, WinPE-NetFX' `
    ((Resolve-WfPeComponentOrder -Name 'WinPE-NetFX') -join ', ')

# "Install WinPE-Scripting before you install WinPE-HTA."
Test-Case 'HTA needs Scripting' 'True' `
    (((Resolve-WfPeComponentOrder -Name 'WinPE-HTA') -join ',') -match 'WinPE-Scripting.*WinPE-HTA').ToString()

# Asked for twice, or asked for alongside something that already pulls it in,
# it still appears once -- a component added twice is a component that fails
# the second time and takes the run with it.
Test-Case 'nothing is added twice' `
    'WinPE-WMI, WinPE-NetFX, WinPE-Scripting, WinPE-PowerShell, WinPE-DismCmdlets' `
    ((Resolve-WfPeComponentOrder -Name 'WinPE-PowerShell', 'WinPE-DismCmdlets', 'WinPE-WMI') -join ', ')

# A partial name is how anyone would actually type it.
Test-Case 'a partial name resolves' 'True' `
    ((Resolve-WfPeComponentOrder -Name 'PowerShell') -contains 'WinPE-PowerShell').ToString()

$threw = 'no'
try { Resolve-WfPeComponentOrder -Name 'WinPE-Nonsense' | Out-Null } catch { $threw = 'yes' }
Test-Case 'an unknown component is refused' 'yes' $threw

# 'Setup' matches WinPE-Setup, WinPE-Setup-Client and WinPE-Setup-Server. Picking
# one of the three would be a guess, and the wrong guess is a boot image that
# does not do what was asked.
$threw = 'no'
try { Resolve-WfPeComponentOrder -Name 'Setup' | Out-Null } catch { $threw = 'yes' }
Test-Case 'an ambiguous name is refused rather than guessed' 'yes' $threw

# The catalog order IS the install order, so WMI has to come first in it.
Test-Case 'WMI is first in the catalog' 'WinPE-WMI' $script:WfPeComponents[0].Name

# Every dependency named has to be a component that exists, or the chain breaks
# on a name nobody would find.
$dangling = @()
$known = @($script:WfPeComponents | ForEach-Object { $_.Name })
foreach ($c in $script:WfPeComponents) {
    foreach ($d in @($c.Needs)) {
        if ($known -notcontains $d) { $dangling += "$($c.Name) needs $d" }
    }
}
Test-Case 'no dependency names a component that does not exist' '' ($dangling -join '; ')

# A dependency listed after its dependent would be installed after it, which is
# the failure the chain exists to prevent.
$outOfOrder = @()
for ($i = 0; $i -lt $script:WfPeComponents.Count; $i++) {
    foreach ($d in @($script:WfPeComponents[$i].Needs)) {
        $at = [array]::IndexOf($known, $d)
        if ($at -gt $i) { $outOfOrder += "$($script:WfPeComponents[$i].Name) needs $d, which comes later" }
    }
}
Test-Case 'every dependency comes before what needs it' '' ($outOfOrder -join '; ')

Write-Host ''
Write-Host 'startnet.cmd' -ForegroundColor Cyan

$net = New-WfPeStartnet -Title 'Plus POS' -PayloadFolder 'WimForge\Tools' -PayloadCommand 'menu.cmd' -RegionScript 'region.cmd'
$netText = ($net.Lines -join "`n")

# Microsoft: "Startnet.cmd starts Wpeinit.exe. Wpeinit.exe installs Plug and Play
# devices, processes Unattend.xml settings, and loads network resources."
# Everything above that line runs on a machine with neither.
$wpeAt = [array]::IndexOf($net.Lines, 'wpeinit')
Test-Case 'wpeinit is there' 'True' ($wpeAt -ge 0).ToString()

$doing = @()
for ($i = 0; $i -lt $net.Lines.Count; $i++) {
    $l = "$($net.Lines[$i])".Trim()
    if ($l -eq '' -or $l -like 'rem *' -or $l -eq '@echo off' -or $l -eq 'wpeinit') { continue }
    if ($i -lt $wpeAt) { $doing += ("line {0}: {1}" -f $i, $l) }
}
Test-Case 'and nothing at all happens before it' '' ($doing -join '; ')

# Letters are found, never assumed: "WinPE drive letter assignments change each
# time you boot, and can change depending on which hardware is detected."
Test-Case 'the payload is searched for' 'True' ($netText -match 'for %%d in \(C D E').ToString()

# X: is the RAM disk this script is running from, so searching it for the payload
# would be searching the boot image for the thing that was kept out of it.
$loops = @($net.Lines | Where-Object { $_ -match '^for %%d in \(' })
Test-Case 'and X: is left out of the search' '' `
    (@($loops | Where-Object { $_ -match '\bX\b' }) -join '; ')

Test-Case 'the payload command is called' 'True' ($netText -match 'call "%WF_PAYLOAD%\\menu\.cmd"').ToString()
Test-Case 'the region script is called'   'True' ($netText -match 'call "%WF_REGIONCMD%"').ToString()

# A prompt at the end by default: a console that reboots the moment a tool exits
# gives nobody a chance to read what it said.
Test-Case 'it leaves a prompt by default' 'True' ($netText -match 'cmd /k').ToString()
$quiet = (New-WfPeStartnet -Title 'Plus POS' -NoPrompt).Lines -join "`n"
Test-Case 'and -NoPrompt does not' 'False' ($quiet -match 'cmd /k').ToString()

# Batch, not PowerShell: PowerShell is in WinPE only if somebody added the
# optional component, and a boot script that needs one fails on the boot.wim
# nobody prepared.
Test-Case 'nothing invokes powershell' 'False' ($netText -match '(?i)powershell').ToString()

# The title goes through an echo, so the characters the command processor eats
# have to be gone before they get there.
$titled = (New-WfPeStartnet -Title 'A & B (test) | more').Lines -join "`n"
Test-Case 'the title cannot break the echo' '' `
    (@(($titled -split "`n") | Where-Object { $_ -match '^echo\s' -and $_ -match '[&|()<>^]' }) -join '; ')

Write-Host ''
Write-Host 'Replacing the shell' -ForegroundColor Cyan

# winpeshl.ini replaces the command prompt, which means startnet.cmd never runs
# -- and startnet.cmd is what calls wpeinit. Microsoft documents neither half of
# that, so the wrapper exists to make the question moot rather than to be right
# about it.
$shellSrc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\PeCustomise.ps1') -Raw
$wrapStart = $shellSrc.IndexOf('$wrapper = New-Object')
$wrapEnd   = $shellSrc.IndexOf('$ini = @(', $wrapStart)
$wrapBlock = ''
if ($wrapStart -ge 0 -and $wrapEnd -gt $wrapStart) { $wrapBlock = $shellSrc.Substring($wrapStart, $wrapEnd - $wrapStart) }

Test-Case 'the wrapper exists' 'True' ($wrapBlock.Length -gt 0).ToString()
Test-Case 'and it calls wpeinit' 'True' ($wrapBlock -match "Add\('wpeinit'\)").ToString()

# winpeshl.ini must point at the wrapper, not at the application -- pointing it
# straight at the application is exactly the bug the wrapper prevents.
# .Contains, not -match: the path is full of backslashes, and a regex written
# for it is a regex that passes because it was escaped wrong rather than because
# the line is right.
Test-Case 'winpeshl.ini points at the wrapper' 'True' `
    ($shellSrc.Contains('wfshell.cmd')).ToString()

# [LaunchApp] would be wrong twice over: Microsoft says "you can't specifiy any
# command-line options with LaunchApp" (their typo), and the wrapper is a .cmd,
# which is not an executable but input to one. Both are checked properly in the
# HTA section below; here it is enough that the singular section is NOT used.
Test-Case 'the singular [LaunchApp] section is not used' 'False' `
    ($shellSrc.Contains("'[LaunchApp]'")).ToString()

Write-Host ''
Write-Host 'How each kind of thing gets started' -ForegroundColor Cyan

# The rule that made this function necessary: writing the bare path of an HTA
# into startnet.cmd relies on the .hta file association being registered in
# WinPE. It usually is -- a Microsoft forum thread shows a bare path launching
# one -- but no Microsoft documentation says so, and MDT's own LiteTouch.wsf
# builds `MSHTA.exe "...\Wizard.hta"` rather than trusting it.
$hta = Get-WfPeLaunchCommand -Command 'menu.hta' -Path '%SystemRoot%\Tools\Menu\menu.hta'
Test-Case 'an HTA is Hta'                 'Hta' $hta.Kind
Test-Case 'and goes through mshta.exe'    'True' ($hta.Line -match '^mshta\.exe ').ToString()
Test-Case 'and needs WinPE-HTA'           'WinPE-HTA' $hta.Requires

# WinPE-HTA depends on WinPE-Scripting, so requiring the HTA component is enough
# -- but only if the catalog still says so. That link is what makes WScript.Shell
# available to the HTA's own buttons.
Test-Case 'and WinPE-HTA still pulls in Scripting' 'True' `
    ((Resolve-WfPeComponentOrder -Name 'WinPE-HTA') -contains 'WinPE-Scripting').ToString()

$bat = Get-WfPeLaunchCommand -Command 'run.cmd' -Path 'X:\run.cmd'
Test-Case 'a .cmd is Batch' 'Batch' $bat.Kind
# call, not a bare invocation: without it startnet.cmd ENDS at the nested script
# rather than carrying on, and everything after it silently never happens.
Test-Case 'and is called'   'True' ($bat.Line -match '^call ').ToString()
Test-Case 'and needs nothing extra' '' $bat.Requires

$exe = Get-WfPeLaunchCommand -Command 'Diag.exe' -Path 'X:\Diag.exe'
Test-Case 'an .exe is Executable'   'Executable' $exe.Kind
Test-Case 'and is run directly'     '"X:\Diag.exe"' $exe.Line
Test-Case 'and needs nothing extra' '' $exe.Requires

$ps = Get-WfPeLaunchCommand -Command 'deploy.ps1' -Path 'X:\deploy.ps1'
Test-Case 'a .ps1 is PowerShell'   'PowerShell' $ps.Kind
Test-Case 'and needs the component' 'WinPE-PowerShell' $ps.Requires
Test-Case 'and bypasses execution policy' 'True' ($ps.Line -match 'ExecutionPolicy Bypass').ToString()

$vbs = Get-WfPeLaunchCommand -Command 'x.vbs' -Path 'X:\x.vbs'
Test-Case 'a .vbs is VBScript'    'VBScript' $vbs.Kind
Test-Case 'and needs Scripting'   'WinPE-Scripting' $vbs.Requires
# cscript, not wscript: wscript answers with message boxes, and on a deployment
# console nobody is watching that is a machine parked on an OK button.
Test-Case 'and uses cscript'      'True' ($vbs.Line -match '^cscript\.exe').ToString()

# An installer can never work in PE, so it is not a launch rule with a caveat --
# it is not a launch rule.
$msi = Get-WfPeLaunchCommand -Command 'setup.msi'
Test-Case 'an .msi is unsupported'   'Unsupported' $msi.Kind
Test-Case 'and produces no line'     '' $msi.Line
Test-Case 'and says why'             'True' ($msi.Note -match 'Windows Installer').ToString()

Test-Case 'so is a text file' 'Unsupported' (Get-WfPeLaunchCommand -Command 'notes.txt').Kind
Test-Case 'and something with no extension at all' 'Unsupported' (Get-WfPeLaunchCommand -Command 'thing').Kind

# Extensions arrive however the operator typed them.
Test-Case 'the extension is case-insensitive' 'Hta' (Get-WfPeLaunchCommand -Command 'MENU.HTA').Kind

Test-Case 'arguments are appended' 'True' `
    ((Get-WfPeLaunchCommand -Command 'a.exe' -Path 'X:\a.exe' -Arguments '/silent').Line -eq '"X:\a.exe" /silent').ToString()

Write-Host ''
Write-Host 'startnet.cmd starts things the right way' -ForegroundColor Cyan

# The whole point of the resolver is that startnet uses it rather than writing
# the bare path of everything and hoping.
$peSrc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\PeCustomise.ps1') -Raw
$netFn = ($peSrc -split 'function New-WfPeStartnet')[1]
Test-Case 'startnet asks how to start each tool' 'True' `
    ($netFn -match 'Get-WfPeLaunchCommand').ToString()
Test-Case 'and leaves out what cannot be started' 'True' `
    ($netFn -match "Kind -eq 'Unsupported'").ToString()

Write-Host ''
Write-Host 'The HTA traps' -ForegroundColor Cyan

# Microsoft changed the JScript engine in the ADK for Windows 11 22H2, and MDT's
# known issues give exactly these two values as the fix. An HTA written for the
# old engine otherwise answers with "An error has occurred in the script on this
# page" and nothing that names the ADK or the engine.
Test-Case 'JscriptReplacement is set to 0' 'True' `
    ($peSrc -match "JscriptReplacement' -Value 0").ToString()
Test-Case 'and mshta is put on the legacy engine' 'True' `
    ($peSrc.Contains('FeatureControl\FEATURE_USE_LEGACY_JSCRIPT')).ToString()
Test-Case 'and adding an HTA applies it automatically' 'True' `
    ($peSrc -match "Kind -eq 'Hta' -and -not \`$SkipJScriptFix").ToString()

# winpeshl.ini: Microsoft is explicit that "you can't specifiy any command-line
# options with LaunchApp" (their typo). The wrapper is a .cmd, which is not an
# executable but input to one -- so the entry has to be cmd.exe with the wrapper
# as an argument, which only [LaunchApps] allows.
Test-Case 'the shell uses [LaunchApps], not [LaunchApp]' 'True' `
    ($peSrc.Contains("'[LaunchApps]'")).ToString()
Test-Case 'and goes through cmd.exe, since a .cmd is not executable' 'True' `
    ($peSrc.Contains('cmd.exe, /c %SystemRoot%\System32\wfshell.cmd')).ToString()

Write-Host ''
Write-Host 'The generated menu HTA' -ForegroundColor Cyan

$menu = New-WfPeMenuHta -Title 'Plus POS' -Item @(
    @{ Label = 'Deploy "NL"'; Command = 'X:\deploy.cmd NL'; Hint = 'Applies the image & records the region' }
    @{ Label = 'Command prompt'; Command = 'cmd.exe' }
)
$menuText = ($menu.Lines -join "`n")

Test-Case 'it is an HTA' 'True' ($menuText -match '<HTA:APPLICATION').ToString()

# VBScript on purpose. The sample whose whole job is to work on the first boot
# must not depend on the registry fix being applied first.
Test-Case 'written in VBScript, not JScript' 'True' `
    (($menuText -match 'language="VBScript"') -and -not ($menuText -match 'language="JScript"')).ToString()

Test-Case 'every button is there' 'True' `
    ((@(($menuText -split "`n") | Where-Object { $_ -match '^<button' }).Count) -ge 3).ToString()

# A label with a quote in it has to survive into a VBScript string literal, where
# the escape is a DOUBLED quote and nothing else.
Test-Case 'a quote in a label is doubled for VBScript' 'True' `
    ($menuText.Contains('"Deploy ""NL"""')).ToString()

# And the handler has to stay readable, because this file is meant to be edited
# afterwards. Escaping the quotes to &quot; also works -- attribute values are
# entity-decoded before the script engine sees them -- but it produces a wall of
# &quot; nobody can maintain.
Test-Case 'and the handler is not a wall of entities' 'False' `
    ($menuText -match "onclick='RunIt &quot;").ToString()

# An ampersand in a hint is markup if it is not escaped.
Test-Case 'an ampersand in a hint is escaped' 'True' ($menuText.Contains('image &amp; records')).ToString()

# VBScript misreads a call whose first argument starts with a bracket, so the
# centring coordinates go into variables first.
Test-Case 'moveTo takes variables, not bracketed expressions' 'True' `
    ($menuText -match 'window\.moveTo x, y').ToString()

# A button that runs nothing is worse than no button, and a label-less one cannot
# be pressed on purpose.
$threw = 'no'
try { New-WfPeMenuHta -Title 'x' -Item @(@{ Label = 'No command' }) | Out-Null } catch { $threw = 'yes' }
Test-Case 'an item with no command is refused' 'yes' $threw

$threw = 'no'
try { New-WfPeMenuHta -Title 'x' -Item @(@{ Command = 'cmd.exe' }) | Out-Null } catch { $threw = 'yes' }
Test-Case 'an item with no label is refused' 'yes' $threw

# On a shell HTA the close button is a reboot button wearing the wrong label:
# "Windows PE will reboot when that command prompt exits".
$noQuit = (New-WfPeMenuHta -Title 'x' -Item @(@{ Label = 'Go'; Command = 'cmd.exe' }) -NoQuit).Lines -join "`n"
Test-Case '-NoQuit leaves the close button out' 'False' ($noQuit -match 'window\.close').ToString()

Write-Host ''
Write-Host 'The catalog itself' -ForegroundColor Cyan

# Every component needs a line saying what it is for, or the picker in both
# front-ends shows a list of names nobody can choose between.
$noWhat = @($script:WfPeComponents | Where-Object { -not $_.What } | ForEach-Object { $_.Name })
Test-Case 'every component says what it is for' '' ($noWhat -join ', ')

$dupes = @($script:WfPeComponents | Group-Object Name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Test-Case 'no component is listed twice' '' ($dupes -join ', ')

# There is no WoW64 optional component for WinPE. If one ever appears in this
# list it is because somebody invented it, and a build would then depend on a
# cab that does not exist.
$invented = @($script:WfPeComponents | Where-Object { $_.Name -match '(?i)wow' } | ForEach-Object { $_.Name })
Test-Case 'no WoW64 component is claimed to exist' '' ($invented -join ', ')

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) {
    Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'All WinPE customisation checks passed.' -ForegroundColor Green
