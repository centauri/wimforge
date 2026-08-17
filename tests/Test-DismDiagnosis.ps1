# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# "For more information, review the log file" is where diagnosis stops.
#
# The failure that prompted this said: "An error occurred applying the
# Unattend.xml file from the .msu package." No hex code, no path, and a noun --
# Unattend.xml -- that sounds like a file the operator forgot to provide. It is
# not. Every .msu carries its own XML, and applying it is how DISM installs the
# package. The message describes DISM's own internals in the operator's
# vocabulary, which is the worst possible combination.
#
# Two things follow, and both are checked here:
#   1. that message is recognised on its TEXT, since it carries no code
#   2. the code that does exist -- in dism.log -- is fetched and used
#
# The cause turned out to be none of the three things I first listed here, and
# the tests below now pin the corrected explanation so it cannot drift back.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

function Write-WfLog { param([string]$Message, [string]$Level, [switch]$NoConsole) }
. (Join-Path $root 'WimForge\Public\DismErrors.ps1')

Write-Host 'A codeless message is still explained' -ForegroundColor Cyan

$unattend = @'
An error occurred applying the Unattend.xml file from the .msu package.
For more information, review the log file.
'@

$why = Get-WfDismError -Message $unattend
Test-Case 'it is recognised'  $true $why.Recognised
Test-Case 'and treated as fatal' $true $why.Fatal

# The single most important sentence: the file is not one of theirs. Without
# this, the next hour goes into looking for an answer file that was never wanted.
Test-Case 'it says nothing is missing from disk' $true ($why.WhatToDo -match 'Nothing is missing from your disk')
Test-Case 'and that the xml is inside the .msu'  $true ($why.WhatToDo -match 'every \.msu carries its own XML')

# All the real causes stay listed -- this message genuinely is raised for several
# different faults. The ORDER is asserted further down, where a second .msu in
# the same folder has to come first; it earned that place by being what it
# actually was, on a machine whose DISM version and services were both fine.
Test-Case 'the version rule is still named' $true ($why.WhatToDo -match 'servicing stack here is older')
Test-Case 'scratch space too'               $true ($why.WhatToDo -match 'scratch space')

# A message with a code must still go down the code path -- the text table is a
# fallback, not a replacement.
$coded = Get-WfDismError -Message 'Add-WindowsPackage failed. Error: 0x800f081e'
Test-Case 'a coded message still wins on its code' '0x800f081e' $coded.Code
Test-Case 'and keeps its own meaning'              $false       $coded.Fatal

Write-Host 'The code DISM withheld is recovered from its log' -ForegroundColor Cyan

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wf-dism-" + [guid]::NewGuid().ToString('N') + '.log')

# Shaped like the real thing: a timestamp column, a severity column, and the
# HRESULT tucked on the end of a line nobody reads.
@(
    '2026-08-05 13:57:50, Info                  DISM   DISM Package Manager: PID=6100 Opening package',
    '2026-08-05 13:58:01, Error                 DISM   DISM Package Manager: PID=6100 Failed to apply unattend - CDISMPackageManager::Internal_Finalize(hr:0x800f0823)',
    '2026-08-05 13:58:02, Info                  DISM   DISM.EXE: Image session has been closed.'
) | Set-Content -LiteralPath $tmp

$tail = @(Get-WfDismLogTail -LogPath $tmp)

# Only the error line. The two Info lines around it are the reason reading the
# raw log is unpleasant, and keeping them would just move the haystack.
Test-Case 'exactly one line kept'   1     $tail.Count
Test-Case 'and it carries the code' $true (($tail -join ' ') -match '0x800f0823')

# Filtering by time keeps the PREVIOUS run's failure out of this run's diagnosis,
# which otherwise produces a confident explanation of the wrong problem.
$after = @(Get-WfDismLogTail -LogPath $tmp -Since ([datetime]'2026-08-05 13:59:00'))
Test-Case 'older entries are dropped' 0 $after.Count

$before = @(Get-WfDismLogTail -LogPath $tmp -Since ([datetime]'2026-08-05 13:00:00'))
Test-Case 'and entries in range are kept' 1 $before.Count

# A diagnostic must never be the thing that fails.
Test-Case 'a missing log is not an error' 0 (@(Get-WfDismLogTail -LogPath (Join-Path $tmp 'nope.log'))).Count

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

Write-Host 'The failure path actually uses it' -ForegroundColor Cyan

$svc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw

# Only when the message had no code of its own -- reading the log for a failure
# that already identified itself would risk attributing an unrelated line to it.
Test-Case 'the log is read when there is no code' $true ($svc -match '(?s)if \(-not \$why\.Code\) \{.{0,600}?Get-WfDismLogTail')

# The package's own log first. Sifting the machine-wide dism.log means reading
# every servicing operation this workstation has ever run to find the eleven
# lines belonging to this package.
Test-Case 'a per-package log is set'   $true ($svc -match "\`$params\['LogPath'\] = \`$dismLog")
Test-Case 'and read before the shared one' $true ($svc -match '(?s)Get-WfDismLogTail -Since \$attempted -LogPath \$dismLog.*?Get-WfDismLogTail -Since \$attempted\)')
Test-Case 'scoped to this attempt'                $true ($svc -match 'Get-WfDismLogTail -Since \$attempted')
Test-Case 'and the attempt is timed'              $true ($svc -match '\$attempted = Get-Date')

# A recovered code re-classifies, but only if it means something -- an unknown
# code would otherwise replace a good text-matched explanation with raw hex.
Test-Case 'only a known code re-classifies' $true ($svc -match 'if \(\$better\.Recognised\)')
Test-Case 'an unknown one is still reported' $true ($svc -match '\$why\.Code = \$hex\.Value')

# And the lines are printed, not referred to.
Test-Case 'the log lines are shown' $true ($svc -match 'from dism\.log')

Write-Host 'The pre-flight check predicts it' -ForegroundColor Cyan

$cfgSrc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Configuration.ps1') -Raw

# The rule was already written down in a comment. A comment does not fail a
# check, so it never told anyone their machine could not do the job.
Test-Case 'the host build is read'  $true ($cfgSrc -match 'CurrentBuildNumber')
Test-Case 'the image build is read' $true ($cfgSrc -match 'Get-WindowsImage -ImagePath \$base -Index 1')
Test-Case 'without mounting'        $true ($cfgSrc -match 'no mount, so this stays a pre-flight')
Test-Case 'newer image fails the check' $true ($cfgSrc -match '(?s)if \(\$imgBuild -gt \$hostBuild\) \{.*?''FAIL''')
Test-Case 'and names the ADK fix'       $true ($cfgSrc -match 'Install the Windows ADK matching build')

# Exported, or the front-ends cannot reach it.
$psd = Get-Content -LiteralPath (Join-Path $root 'WimForge\WimForge.psd1') -Raw
Test-Case 'Get-WfDismLogTail is exported' $true ($psd -match "'Get-WfDismLogTail'")

Write-Host 'The code behind the Unattend.xml message' -ForegroundColor Cyan

# The real one, recovered from dism.log on a live run:
#
#   ReportEventDownloadRequestEnd: hr = [0x800401E3]
#   MsuManager: Failed getting the download request.
#               CDismMsuManager::ProcessWithUpdateAgent(hr:0x800401e3)
#   MsuManager: Failed to install UUP package.
#
# This entry has been wrong twice, so both corrections are pinned here.
#
#   Guess 1: "the Windows Update Agent is unreachable because wuauserv is
#            disabled."  Disproven -- it fails with wuauserv Manual/Running.
#   Guess 2: "a checkpoint .msu is sitting beside the target."  Disproven -- it
#            fails with the target alone in its own folder, and on a clean
#            vanilla 24H2 image that nothing had touched.
#
# What settled it: the SAME package, the SAME mounted image, applied with
# dism.exe /Add-Package -- "The operation completed successfully", after five
# straight failures from Add-WindowsPackage. The cmdlet loads DismApi in-process
# inside the PowerShell host and cannot activate the update agent from there;
# dism.exe asks from its own process and is answered.
$why = Get-WfDismError -Message 'Add-WindowsPackage failed (hr:0x800401e3)'

Test-Case 'it is recognised'  $true   $why.Recognised
Test-Case 'and identified'    '0x800401e3' $why.Code
Test-Case 'as an update-agent reach problem' $true ($why.Summary -match 'could not reach the Windows Update Agent')

# Both dead ends are ruled out by name. Someone who read either version of this
# advice will otherwise go and re-check a service that is already running, or
# reshuffle a folder that is already correct.
Test-Case 'it rules out the service'    $true ($why.WhatToDo -match 'NOT about the Windows Update service')
Test-Case 'and says it fails anyway'    $true ($why.WhatToDo -match 'wuauserv Manual/Running')
Test-Case 'it rules out the checkpoint' $true ($why.WhatToDo -match 'not about a checkpoint sitting beside the target')
Test-Case 'and the clean image proves it' $true ($why.WhatToDo -match 'clean untouched image')

# The fix, and the fact that the toolkit already does it -- so meeting this code
# again is itself information: something went round the dism.exe path.
Test-Case 'it names the cmdlet as the cause' $true ($why.WhatToDo -match 'Add-WindowsPackage loads DISM in-process')
Test-Case 'and dism.exe as the fix'          $true ($why.WhatToDo -match 'dism\.exe /Add-Package')
Test-Case 'and says WimForge already does it' $true ($why.WhatToDo -match 'WimForge now applies WIM-format packages')
Test-Case 'with a command to run by hand'     $true ($why.WhatToDo -match '/Image:<mount>')

# The codeless text must lead with the same thing.
$un = Get-WfDismError -Message 'An error occurred applying the Unattend.xml file from the .msu package.'
$uupAt    = $un.WhatToDo.IndexOf('cannot reach the Windows Update Agent from inside PowerShell')
$folderAt = $un.WhatToDo.IndexOf('same folder as the one being applied')
$dismAt   = $un.WhatToDo.IndexOf('servicing stack here is older')
Test-Case 'the hosting cause is listed first' $true (($uupAt -gt 0) -and ($uupAt -lt $folderAt))
Test-Case 'the folder cause still comes before the stack' $true (($folderAt -gt 0) -and ($folderAt -lt $dismAt))
Test-Case 'and the log is what decides'      $true ($un.WhatToDo -match 'read the dism.log lines below')

Write-Host 'And it is caught before the seven minutes, not after' -ForegroundColor Cyan

$cfgSrc = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Configuration.ps1') -Raw

Test-Case 'there is a pre-flight' $true ($cfgSrc -match 'function Test-WfUpdateAgent')
Test-Case 'it reads the service'  $true ($cfgSrc -match 'Win32_Service -Filter .+wuauserv')

# Disabled is the state that breaks servicing. Stopped is fine -- DISM starts it
# on demand, which is the entire point of Manual.
Test-Case 'Disabled fails'  $true ($cfgSrc -match "StartMode -eq 'Disabled'")
Test-Case 'Stopped does not' $false ($cfgSrc -match "State -eq 'Stopped'.*\\$result\.Ok = \\$false")

# A machine where the query itself fails must not be refused work that would
# have succeeded.
Test-Case 'an unqueryable service still proceeds' $true ($cfgSrc -match '(?s)if \(-not \$svc\) \{.{0,200}?return \$result')

Test-Case 'the environment check reports it' $true ($cfgSrc -match "Add-Result 'Windows Update Agent'")

$svc2 = Get-Content -LiteralPath (Join-Path $root 'WimForge\Public\Servicing.ps1') -Raw

# Only for packages that need it. A cabinet .msu is unpacked by DISM itself and
# does not care whether wuauserv exists -- demanding it there would refuse work
# that would have worked.
Test-Case 'only UUP packages need the agent' $true ($svc2 -match "(?s)needsAgent = @\(.{0,200}?-eq 'Wim'")
Test-Case 'and it fails before applying'     $true ($svc2 -match '(?s)needsAgent\.Count -gt 0.{0,200}?if \(-not \$agent\.Ok\) \{\s*throw')

# The reason to do it at all: expanding 4.85 GB before finding out is the cost.
Test-Case 'the cost is named' $true ($svc2 -match 'rather than spending several minutes expanding')

Write-Host 'Antivirus over the mount is reported, not fixed' -ForegroundColor Cyan

# Not a correctness problem, which is exactly why it goes unnoticed for hours: a
# WIM commit writes hundreds of thousands of small files and reads them all back
# to recompress, real-time protection scans every one, and DISM reports honest
# progress the whole time against work that is genuinely happening -- just an
# order of magnitude slower than it needs to.
Test-Case 'there is a check'        $true ($cfgSrc -match 'function Test-WfDefenderExclusion')
Test-Case 'it reads the exclusions' $true ($cfgSrc -match 'Get-MpPreference')
Test-Case 'and real-time state'     $true ($cfgSrc -match 'RealTimeProtectionEnabled')

# A parent exclusion covers its children. Comparing literally would report
# C:\Imaging\Updates as unprotected on a machine where C:\Imaging is excluded.
Test-Case 'a parent exclusion counts' $true ($cfgSrc -match 'norm\.StartsWith\(\$e')

# It reports and stops. Exclusions on a managed laptop are policy, and a tool
# that quietly rewrote antivirus configuration would deserve what it got.
Test-Case 'nothing is changed' $false ($cfgSrc -match 'Add-MpPreference -ExclusionPath \$')
Test-Case 'the command is only suggested' $true ($cfgSrc -match "Add-MpPreference -ExclusionPath '")
Test-Case 'and policy is acknowledged'    $true ($cfgSrc -match 'blocked by policy on a managed machine')

# Real-time off is not a finding, and an unqueryable Defender is not a failure --
# third-party AV is normal and "I could not tell" is a different answer from
# "you are unprotected".
Test-Case 'real-time off passes'     $true ($cfgSrc -match "RealTime -ne 'On'")
Test-Case 'unqueryable is only info' $true ($cfgSrc -match "(?s)if \(-not \`$av\.Known\) \{.{0,80}?'Antivirus exclusions' 'INFO'")

Write-Host "DISM's progress bar does not flood the log" -ForegroundColor Cyan

# dism.exe redraws ONE progress line using carriage returns. On a live console
# that is a moving bar; captured, every redraw becomes its own line, so a single
# /ResetBase writes several hundred near-identical bars into the log and fills
# the screen with them.
$core = Get-Content -LiteralPath (Join-Path $root 'WimForge\Private\Core.ps1') -Raw

Test-Case 'bars are recognised' $true ($core -match "Bar\s*=\s*'\^\\\[")
Test-Case 'and split on CR too' $true ($core -match '-split')

# The pattern has to catch every bar and no real output. Checked against the
# actual shapes rather than trusted.
$bar = '^\[[=\s]*\d+[.,]?\d*%[=\s]*\]$'
$bars = @(
    '[                           0.0%                          ]',
    '[==============95.9%===                                   ]',
    '[==========================100.0%=========================]',
    '[====================       40,0%                      ]'
)
$real = @(
    'Deployment Image Servicing and Management tool',
    'Version: 10.0.26100.8737',
    'The operation completed successfully.',
    'Error: 0x800f0922'
)
Test-Case 'every bar shape matches'   4 (@($bars | Where-Object { $_ -match $bar }).Count)
Test-Case 'and no real line matches'  0 (@($real | Where-Object { $_ -match $bar }).Count)

# --------------------------------------------------------- and it is exercised
# The folding used to live inside Invoke-WfDism, whose first act is to launch
# dism.exe, so nothing here could do better than match the source for words. It
# is three functions now and can simply be run.
. (Join-Path $root 'WimForge\Private\Core.ps1')

$script:Written = New-Object System.Collections.Generic.List[string]
function Write-WfLog {
    param([string]$Message, [string]$Level, [switch]$NoConsole)
    $script:Written.Add(('{0}|{1}|{2}' -f $Level, $(if ($NoConsole) { 'quiet' } else { 'shown' }), $Message))
}

$t0 = [datetime]'2026-08-10T00:46:43'
$st = New-WfDismOutputState -HeartbeatSeconds 60 -Now $t0

Add-WfDismOutputLine -State $st -Raw 'Deployment Image Servicing and Management tool' -Now $t0
Add-WfDismOutputLine -State $st -Raw 'Image Version: 10.0.26100.7623'                  -Now $t0

# 400 redraws over ten seconds -- far too fast to be worth a heartbeat.
for ($i = 0; $i -lt 400; $i++) {
    Add-WfDismOutputLine -State $st -Raw ('[{0,26}{1:0.0}%{2,26}]' -f '', ($i / 4), '') -Now $t0.AddSeconds($i / 40)
}
Add-WfDismOutputLine -State $st -Raw 'The operation completed successfully.' -Now $t0.AddSeconds(10)
Complete-WfDismOutput -State $st

$shown = @($script:Written | Where-Object { $_ -match '\|shown\|' })
Test-Case 'a fast run gets no heartbeat' 0 $st.Beats
Test-Case 'and nothing on the console'   0 $shown.Count

# The last bar of the run survives -- it is the evidence the operation reached
# the end rather than stopping at 43%, and it must come BEFORE the line that
# followed it.
$log    = @($script:Written | ForEach-Object { ($_ -split '\|', 3)[2] })
$barRe  = '^\[[=\s]*\d+[.,]?\d*%[=\s]*\]$'
$barIx  = [array]::FindIndex([string[]]$log, [Predicate[string]]{ param($x) $x -match '^\[[=\s]*\d+[.,]?\d*%[=\s]*\]$' })
$doneIx = [array]::FindIndex([string[]]$log, [Predicate[string]]{ param($x) $x -eq 'The operation completed successfully.' })
Test-Case 'exactly one bar survives' 1     @($log | Where-Object { $_ -match $barRe }).Count
Test-Case 'and emitted in order'     $true ($barIx -ge 0 -and $barIx -lt $doneIx)

# 400 bars in, 1 out.
Test-Case 'the collapse is disclosed' $true ([bool](@($log) -match '399 progress-bar redraws collapsed'))

# ------------------------------------------------------------- the heartbeat
Write-Host 'A long operation says it is still alive' -ForegroundColor Cyan

# The 24H2 apply ran for 17 minutes 49 seconds and printed nothing at all,
# because the output was collected first and written when it finished. On the
# longest step of a three-hour run the only sign of life was a marquee.
$script:Written.Clear()
$st = New-WfDismOutputState -HeartbeatSeconds 60 -Now $t0
for ($sec = 0; $sec -le 1069; $sec += 5) {
    Add-WfDismOutputLine -State $st -Raw ('[{0,26}{1:0.0}%{2,26}]' -f '', (100 * $sec / 1069), '') -Now $t0.AddSeconds($sec)
}
Complete-WfDismOutput -State $st

$beats = @($script:Written | Where-Object { $_ -match 'still working' })
Test-Case 'roughly one a minute over 17m49s' 17 $beats.Count
Test-Case 'and they reach the console'       $true ([bool]($beats[0] -match '\|shown\|'))
Test-Case 'each carrying the percentage'     $true ([bool]($beats[0] -match '\d+[.,]\d%'))

# A heartbeat is a bar that WAS written, so it must not also be counted as
# collapsed -- the disclosed number has to match what actually went missing.
$collapsed = [regex]::Match(($script:Written -join ' '), '\((\d+) progress-bar redraws collapsed\)')
# collapsed + written heartbeats + the one final bar = every bar DISM printed.
Test-Case 'the collapsed count excludes them' $true `
    ($collapsed.Success -and ([int]$collapsed.Groups[1].Value + $beats.Count + 1) -eq $st.All.Count)

# ------------------------------------------------------------ streamed, not held
Write-Host 'The output is streamed rather than collected' -ForegroundColor Cyan

# The heartbeat is worth nothing if the lines still only arrive once dism.exe has
# exited, so the shape of the call matters: a pipeline into the folder, not an
# assignment.
Test-Case 'dism.exe is piped, not assigned' $true `
    ($core -match '& dism\.exe @Arguments 2>&1 \| ForEach-Object \{ Add-WfDismOutputLine')
Test-Case 'and nothing collects it first'   $false ($core -match '\$output = & dism\.exe')

# Streaming a native command's stderr under -ErrorActionPreference Stop turns it
# into a terminating NativeCommandError. Assignment never had that problem.
Test-Case 'the preference is neutralised' $true `
    ($core -match "(?s)ErrorActionPreference = 'Continue'.*& dism\.exe @Arguments")

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
