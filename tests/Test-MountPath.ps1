# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# Whether a folder is somewhere an image can actually be mounted.
#
# This exists because "put everything under one folder" is the obvious instinct
# and it is wrong for exactly one of the paths in this toolkit. A mount folder
# inside the workspace, inside a repository, or on a sync drive EXISTS perfectly
# well -- so every check that only asks "does the path exist" passes, and the
# failure arrives twenty minutes into a servicing run as a dismount that will not
# complete.
#
# The volume and free-space checks depend on a real Windows machine and cannot be
# exercised here. Everything that is pure judgement about a path can be, and that
# is the half where a rule can quietly go missing.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else {
        Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red
        if ($env:GITHUB_ACTIONS) { Write-Host "::error::Test-MountPath: $Name -- expected [$e] got [$a]" }
        $script:Fail++
    }
}

# The real one, not a Join-Path wrapper: Join-Path resolves the drive through
# the provider, so 'C:\WimMount' throws on any host without a C: drive -- which
# is exactly the reason the module has its own.
. (Join-Path $root 'WimForge\Private\Core.ps1')
. (Join-Path $root 'WimForge\Public\Configuration.ps1')

# After the module file, not before. Configuration.ps1 defines Get-WfConfig; a
# stub written first is overwritten, and the real one then writes a default
# config on a machine that has never run the toolkit -- which is every CI
# runner. Test-UpdateFlow.ps1 documents the same trap.
function Get-WfConfig { @{ MountPath = 'C:\WimMount'; WorkspaceRoot = 'D:\Imaging' } }

function Get-Finding {
    param($Result, [string] $Check)
    return @($Result.Findings | Where-Object { $_.Check -eq $Check })
}

Write-Host 'Path length -- the one that surprises people' -ForegroundColor Cyan

# The deepest paths inside a serviced image are in WinSxS and run to about 200
# characters on their own; MAX_PATH is 260, and this toolkit walks the mount
# under Windows PowerShell 5.1. So the mount root has a budget, not a free pass.
$short = Test-WfMountPath -Path 'C:\WimMount' -WorkspaceRoot 'D:\Imaging'
Test-Case 'a short root is fine' 'OK' (Get-Finding $short 'Path length').Status

# A mount folder several levels inside a project directory, which is the case
# that prompted all of this. The deepest paths inside a serviced image are in
# WinSxS and run to roughly 200 characters on their own, so a root of this length
# leaves nothing for them.
$deep = Test-WfMountPath -Path 'C:\Users\dev\source\repos\deployment-toolkit\WimForge\Mount' `
                         -WorkspaceRoot 'D:\Imaging'
Test-Case 'a project-folder path is flagged' 'WARN' (Get-Finding $deep 'Path length').Status
Test-Case 'and the arithmetic is shown'      $true `
    ([bool]((Get-Finding $deep 'Path length').Detail -match '260'))

$silly = Test-WfMountPath -Path ('C:\' + ('a' * 240)) -WorkspaceRoot 'D:\Imaging'
Test-Case 'a genuinely long one fails' 'FAIL' (Get-Finding $silly 'Path length').Status

Write-Host 'Places a mount must not go' -ForegroundColor Cyan

$unc = Test-WfMountPath -Path '\\server\share\Mount' -WorkspaceRoot 'D:\Imaging'
Test-Case 'a UNC path is refused'  'FAIL' (Get-Finding $unc 'Volume').Status
Test-Case 'and it says why'        $true ([bool]((Get-Finding $unc 'Volume').Detail -match 'local disk'))
Test-Case 'the whole verdict fails' 'FAIL' $unc.Verdict

# Microsoft's guidance is explicit about this one, so it is a refusal rather
# than a shrug.
$profileWas = $env:USERPROFILE
$env:USERPROFILE = 'C:\Users\dev'
$inProfile = Test-WfMountPath -Path 'C:\Users\dev\Documents\Mount' -WorkspaceRoot 'D:\Imaging'
Test-Case 'inside the user profile is refused' 'FAIL' (Get-Finding $inProfile 'Profile folder').Status
Test-Case 'and quotes the guidance'            $true `
    ([bool]((Get-Finding $inProfile 'Profile folder').Detail -match "Don't mount images to protected folders"))

$elsewhere = Test-WfMountPath -Path 'C:\WimMount' -WorkspaceRoot 'D:\Imaging'
Test-Case 'somewhere else is not' 0 (Get-Finding $elsewhere 'Profile folder').Count
$env:USERPROFILE = $profileWas

# A sync client uploading a mounted Windows installation, and holding files open
# while it does, is a dismount that never completes.
foreach ($sync in @('OneDrive', 'Dropbox', 'Google Drive')) {
    $r = Test-WfMountPath -Path "C:\Users\dev\$sync\Imaging\Mount" -WorkspaceRoot 'D:\Imaging'
    Test-Case "$sync is refused" 'FAIL' (Get-Finding $r 'Sync folder').Status
}
Test-Case 'a plain path is not mistaken for one' 0 `
    (Get-Finding (Test-WfMountPath -Path 'C:\WimMount' -WorkspaceRoot 'D:\Imaging') 'Sync folder').Count

$atRoot = Test-WfMountPath -Path 'C:\' -WorkspaceRoot 'D:\Imaging'
Test-Case 'the root of a drive is refused' 'FAIL' (Get-Finding $atRoot 'Location').Status

Write-Host 'Inside the workspace -- the question that started this' -ForegroundColor Cyan

# Not a refusal. It works; it is just that everything which scans, backs up or
# measures the workspace is then also doing it to a live mount.
$inside = Test-WfMountPath -Path 'D:\Imaging\Mount' -WorkspaceRoot 'D:\Imaging'
Test-Case 'a mount inside the workspace is flagged' 'WARN' (Get-Finding $inside 'Workspace').Status
Test-Case 'but not refused outright' 0 `
    @($inside.Findings | Where-Object { $_.Check -eq 'Workspace' -and $_.Status -eq 'FAIL' }).Count

$outside = Test-WfMountPath -Path 'C:\WimMount' -WorkspaceRoot 'D:\Imaging'
Test-Case 'the default is not flagged' 0 (Get-Finding $outside 'Workspace').Count

# A workspace path that is a prefix of another folder must not count as
# containing it: D:\Imaging is not the parent of D:\ImagingOld.
$neighbour = Test-WfMountPath -Path 'D:\ImagingOld\Mount' -WorkspaceRoot 'D:\Imaging'
Test-Case 'a neighbouring folder is not "inside"' 0 (Get-Finding $neighbour 'Workspace').Count

# And a trailing separator on the workspace must not change the answer.
$trailing = Test-WfMountPath -Path 'D:\Imaging\Mount' -WorkspaceRoot 'D:\Imaging\'
Test-Case 'a trailing slash is ignored' 'WARN' (Get-Finding $trailing 'Workspace').Status

Write-Host 'Source control' -ForegroundColor Cyan

# The reason a workspace next to a checked-out toolkit is a bad idea, and the
# reason a MOUNT there is a worse one.
$repo  = Join-Path ([IO.Path]::GetTempPath()) ('wf-repo-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$mount = Join-Path $repo 'work\Mount'
New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
New-Item -ItemType Directory -Path $mount -Force | Out-Null

$inRepo = Test-WfMountPath -Path $mount -WorkspaceRoot 'D:\Imaging'
Test-Case 'a mount inside a git tree is flagged' 'WARN' (Get-Finding $inRepo 'Source control').Status
Test-Case 'and the repository is named'          $true `
    ([bool]((Get-Finding $inRepo 'Source control').Detail -match [regex]::Escape($repo)))

$plain = Join-Path ([IO.Path]::GetTempPath()) ('wf-plain-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $plain -Force | Out-Null
Test-Case 'a folder with no repository above it is not' 0 `
    (Get-Finding (Test-WfMountPath -Path $plain -WorkspaceRoot 'D:\Imaging') 'Source control').Count

Remove-Item -LiteralPath $repo  -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $plain -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'The verdict is the worst of the findings' -ForegroundColor Cyan

# The volume, file system and free-space checks need a real Windows machine. Off
# one, they come back as "could not query" -- which is itself a warning, so the
# exact verdicts can only be asserted where the query works. The ordering can be
# asserted anywhere, and it is the part that would actually break.
$clean = Test-WfMountPath -Path 'C:\WimMount' -WorkspaceRoot 'D:\Imaging'
$haveVolumes = ((Get-Finding $clean 'Volume').Status -eq 'OK')
$spaceOk     = ((Get-Finding $clean 'Free space').Status -eq 'OK')
$fsStatus    = (Get-Finding $clean 'File system').Status
$fsOk        = ($fsStatus -eq 'OK') -or [string]::IsNullOrEmpty($fsStatus)

Test-Case 'a UNC path still fails outright' 'FAIL' `
    (Test-WfMountPath -Path '\\server\share\Mount' -WorkspaceRoot 'D:\Imaging').Verdict

# Host disk space and the volume's file system are not the product. GitHub-hosted
# Windows runners often have a small C:, and the image disk is not always NTFS.
$hostFail = @($clean.Findings | Where-Object {
    $_.Check -notin @('Free space', 'File system') -and $_.Status -eq 'FAIL'
})
Test-Case 'a clean path never reads FAIL' $true ($hostFail.Count -eq 0)

if ($haveVolumes -and $spaceOk -and $fsOk) {
    Test-Case 'a clean path reads OK'  'OK'   $clean.Verdict
    # Same volume as $clean. D:\Imaging\Mount used to be the fixture, but the
    # overall verdict is FAIL when that drive does not exist -- which is the
    # usual case on a CI runner -- even though the workspace finding is only a
    # warning. The thing under test is WARN beating OK, not a missing volume.
    Test-Case 'one warning reads WARN' 'WARN' (Test-WfMountPath -Path 'C:\WimMount\Inside' -WorkspaceRoot 'C:\WimMount').Verdict
}
elseif ($haveVolumes) {
    Write-Host '  --   free space or file system on this host is not OK, so the exact OK/WARN verdicts are untested' -ForegroundColor DarkGray
}
else {
    Write-Host '  --   no volume information on this host, so the exact verdicts are untested' -ForegroundColor DarkGray

    # But the thing that would be wrong is still checkable: a host that cannot
    # answer the question must say so, not claim the drive is missing.
    Test-Case 'says the query failed rather than blaming the drive' $true `
        ([bool]((Get-Finding $clean 'Volume').Detail -match 'Could not query'))
}

# It reports, it does not refuse. Every non-OK finding has to say what would go
# wrong, or an operator who knows their machine has nothing to overrule it with.
# OK lines are allowed to be short ("D: is NTFS.") -- that is the whole answer.
$all = Test-WfMountPath -Path 'D:\Imaging\Mount' -WorkspaceRoot 'D:\Imaging'
Test-Case 'every warning or failure explains itself' 0 @(
    $all.Findings | Where-Object { $_.Status -ne 'OK' -and $_.Detail.Length -lt 20 }
).Count
Test-Case 'and nothing throws'            $true ($null -ne $all)

Write-Host 'It falls back to the configuration' -ForegroundColor Cyan
Test-Case 'no path given uses the configured one' 'C:\WimMount' (Test-WfMountPath).Path

Write-Host 'The workspace options' -ForegroundColor Cyan

$options = @(Get-WfWorkspaceOption)
Test-Case 'there is at least one'    $true ($options.Count -ge 1)
Test-Case 'each has a path'          0 @($options | Where-Object { -not $_.Path }).Count
Test-Case 'each says what it is'     0 @($options | Where-Object { -not $_.Why }).Count
Test-Case 'no duplicates'            $options.Count @($options | Select-Object -ExpandProperty Path | Sort-Object -Unique).Count

# "Next to the toolkit" is the whole point of offering a list rather than one
# answer -- it has to actually be in there.
Test-Case 'next to the toolkit is offered' 1 @($options | Where-Object { $_.Why -eq 'next to the toolkit' }).Count

# And when it is a bad idea, it says so instead of quietly recommending it. This
# repo is checked out, so the .git above it should be caught.
$beside = @($options | Where-Object { $_.Why -eq 'next to the toolkit' })[0]
if ($beside.Note -like 'not advised*') {
    Test-Case 'a bad location is not recommended' $false $beside.Recommended
    Test-Case 'and the reason is given'           $true ($beside.Note.Length -gt 20)
}
else {
    Write-Host '  --   the toolkit is not in a repository or sync folder here, so that path is untested' -ForegroundColor DarkGray
}

# ------------------------------------------------- where the working copy goes
Write-Host 'The working copy is named once, not once per run' -ForegroundColor Cyan

# A servicing run mounts a COPY so the file you named is never the one at risk.
# The copy used to be named with ChangeExtension($path, 'working.wim'), which
# stacks: service something that is already a working copy and the log fills with
# Win11IoTLTSC2024_FEC_XPOSH.working.working.wim -- at exactly the moment anyone
# is trying to work out which of three similar names holds the real image.
Test-Case 'an ordinary image' 'C:\Imaging\Images\Base.working.wim' `
    (Get-WfWorkingCopyPath -ImagePath 'C:\Imaging\Images\Base.wim')

# The suffix is stripped before it is added back, so it cannot stack...
$again = Get-WfWorkingCopyPath -ImagePath 'C:\Imaging\Images\Base.working.wim'
Test-Case 'does not stack'    $false ($again -match 'working\.working')

# ...but the result must not BE the source. Copying a file over itself empties
# it, and the file being emptied would be the one holding the work.
Test-Case 'and never the source itself' $true ($again -ne 'C:\Imaging\Images\Base.working.wim')
Test-Case 'named predictably'  'C:\Imaging\Images\Base.working-2.wim' $again

# A numbered copy strips back to the same stem rather than growing a second one.
Test-Case 'a numbered copy does not grow' 'C:\Imaging\Images\Base.working.wim' `
    (Get-WfWorkingCopyPath -ImagePath 'C:\Imaging\Images\Base.working-2.wim')

# Dots in the name itself are left alone -- only the .working suffix is special.
Test-Case 'a dotted name survives' 'C:\Imaging\Images\Win11.IoT.LTSC2024.working.wim' `
    (Get-WfWorkingCopyPath -ImagePath 'C:\Imaging\Images\Win11.IoT.LTSC2024.wim')

# ------------------------------------- and the standalone script agrees with it
Write-Host 'The standalone driver script names its copy the same way' -ForegroundColor Cyan

# Add-DriversToWim.ps1 is standalone on purpose -- it is the one that runs from a
# scheduled task on a reference machine, with no module to import -- so it has
# its own copy of this rule. Two copies of a rule is one copy too many unless
# something checks they still say the same thing, and the module fix would
# otherwise have left the script stacking .working.working forever.
#
# Lifted out by parsing rather than by dot-sourcing: the script runs when loaded,
# and it wants a WIM and a driver library to do it.
$standalone = Get-Content -LiteralPath (Join-Path $root 'Add-DriversToWim.ps1') -Raw
$tok = $null; $perr = $null
$sAst = [System.Management.Automation.Language.Parser]::ParseInput($standalone, [ref]$tok, [ref]$perr)
$fn = @($sAst.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WorkingCopyPath'
}, $true))

Test-Case 'the script has the helper' 1 $fn.Count
# Asked of the syntax tree, not of the text: the replacement's own comment says
# what it replaced, and a text search cannot tell an explanation from a call.
$stillCalls = @($sAst.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    "$($n.Member)" -eq 'ChangeExtension'
}, $true))
Test-Case 'and no longer stacks by hand' 0 $stillCalls.Count

if ($fn.Count -eq 1) {
    . ([scriptblock]::Create($fn[0].Extent.Text))

    foreach ($case in @(
        'C:\Imaging\Images\Base.wim',
        'C:\Imaging\Images\Base.working.wim',
        'C:\Imaging\Images\Base.working-2.wim',
        'C:\Imaging\Images\Win11.IoT.LTSC2024.wim',
        'Base.wim'
    )) {
        Test-Case "same answer for $case" `
            (Get-WfWorkingCopyPath -ImagePath $case) (Get-WorkingCopyPath -Path $case)
    }
}

Write-Host ''
if ($script:Fail -gt 0) { Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
