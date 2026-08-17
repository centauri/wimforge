# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The test suite has to be safe to run on somebody else's machine.
#
# This one guards the others. The promise made in the README is that the tests
# need no DISM, no image, no network and no administrator rights, and that they
# run in seconds anywhere. That promise is the reason a stranger will clone this
# repository and type the command in the Development section instead of reading
# the tests first to see what they touch.
#
# It is also a promise that is easy to break by accident, and expensive when it
# is: a test that writes to a real path, mounts a real image or needs elevation
# does not fail on the machine it was written on. It fails on somebody else's,
# once, and they close the tab.
#
# So the shape of every test file is checked here:
#
#   nothing is written to a literal absolute path
#   every fixture is created under the OS temp folder and cleaned up
#   no DISM cmdlet, registry hive, or network call is made for real
#   nothing needs administrator rights
#   an environment variable that is changed is changed back
#   no personal names, machine names or private paths are left in
#
# The distinction that makes this work is a real CALL versus a mention. Most of
# these files match DISM cmdlet names against source text as strings, which is
# the whole point of a mechanical guard. So this reads the AST and looks at
# command invocations, not at the characters.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Every test file except this one. This file carries deliberately-broken samples
# as fixtures -- a real DISM call, a write to a literal path, an environment
# variable never put back -- so that the checks below can be shown to fail. Left
# in scope it would report all three of them, every run, forever.
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File |
                Where-Object { $_.Name -ne (Split-Path $PSCommandPath -Leaf) } |
                Sort-Object Name)

$script:Fail = 0
function Test-Case {
    param([string] $Name, $Expected, $Actual)
    $e = ($Expected -join ', '); $a = ($Actual -join ', ')
    if ($e -eq $a) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    else { Write-Host "  FAIL $Name`n       expected [$e]`n       got      [$a]" -ForegroundColor Red; $script:Fail++ }
}

function Get-Ast {
    param([string] $Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw "$Path does not parse" }
    return $ast
}

function Get-CommandNames {
    <#
        Every command actually invoked in a file, plus the functions the file
        defines for itself. A file that defines its own Invoke-WebRequest is
        stubbing it, which is the opposite of calling the real one.
    #>
    param($Ast)

    $called = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { "$($_.GetCommandName())" } | Where-Object { $_ })

    $defined = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name })

    return [pscustomobject]@{ Called = $called; Defined = $defined }
}

Write-Host ''
Write-Host ("Every test file, {0} of them" -f $testFiles.Count) -ForegroundColor Cyan
Test-Case 'there are test files to check' 'True' ($testFiles.Count -gt 0).ToString()

Write-Host ''
Write-Host 'Nothing touches a real image, hive or network' -ForegroundColor Cyan

# Calling any of these for real means the test needs a Windows image, an elevated
# session, or the internet. All three break the promise.
$forbidden = @(
    'Get-WindowsImage', 'Mount-WindowsImage', 'Dismount-WindowsImage',
    'Add-WindowsPackage', 'Get-WindowsPackage', 'Remove-WindowsPackage',
    'Get-WindowsDriver', 'Add-WindowsDriver', 'Export-WindowsDriver',
    'Get-WindowsCapability', 'Add-WindowsCapability', 'Remove-WindowsCapability',
    'Get-WindowsOptionalFeature', 'Enable-WindowsOptionalFeature',
    'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer',
    'Get-CimInstance', 'Get-WmiObject',
    'Restart-Computer', 'Stop-Computer', 'Restart-Service', 'Stop-Service',
    'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
    'reg', 'reg.exe', 'dism', 'dism.exe', 'diskpart', 'bcdboot', 'tzutil'
)

$offenders = New-Object System.Collections.Generic.List[string]
foreach ($f in $testFiles) {
    $names = Get-CommandNames (Get-Ast $f.FullName)
    foreach ($c in ($names.Called | Sort-Object -Unique)) {
        if ($forbidden -notcontains $c) { continue }
        # A file that defines the name is stubbing it, not calling it.
        if ($names.Defined -contains $c) { continue }
        $offenders.Add("$($f.Name): $c")
    }
}
Test-Case 'no test invokes DISM, WMI, the registry or the network' '' ($offenders.ToArray() -join '; ')

# Elevation is the other thing a stranger will not have, or will not want to
# grant to a repository they just cloned.
$elevated = @()
foreach ($f in $testFiles) {
    $names = Get-CommandNames (Get-Ast $f.FullName)
    if (($names.Called -contains 'Assert-WfElevated') -and ($names.Defined -notcontains 'Assert-WfElevated')) {
        $elevated += $f.Name
    }
}
Test-Case 'no test requires administrator rights' '' ($elevated -join ', ')

Write-Host ''
Write-Host 'Nothing is written outside the temp folder' -ForegroundColor Cyan

# A literal drive letter as a write target is the failure this is really about:
# it works on the machine it was written on and lands somewhere unwanted, or
# fails outright, on anyone else's.
$writers = 'New-Item|Set-Content|Add-Content|Copy-Item|Move-Item|Out-File|Remove-Item|New-WfDirectory'

# Which files genuinely write, read from the AST rather than from the text. A
# test that asserts the MODULE cleans up after itself contains the string
# "Remove-Item" inside a regex literal, and a text scan cannot tell that from
# the command -- which is how this check first reported a file that writes
# nothing at all.
$writeCommands = @('New-Item','Set-Content','Add-Content','Copy-Item','Move-Item',
                   'Out-File','Remove-Item','New-WfDirectory','Rename-Item')
$writingFiles = @()
foreach ($f in $testFiles) {
    $names = Get-CommandNames (Get-Ast $f.FullName)
    if (@($names.Called | Where-Object { $writeCommands -contains $_ }).Count -gt 0) {
        $writingFiles += $f
    }
}
Write-Host ("       ({0} of {1} files write anything at all)" -f $writingFiles.Count, $testFiles.Count) -ForegroundColor DarkGray

$absolute = @()
foreach ($f in $writingFiles) {
    foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
        if ($line -notmatch $writers) { continue }
        if ($line -match "-(?:Literal)?Path\s+'[A-Za-z]:" -or $line -match '-Destination\s+''[A-Za-z]:') {
            $absolute += ("{0}: {1}" -f $f.Name, $line.Trim())
        }
    }
}
Test-Case 'no write names a literal absolute path' '' ($absolute -join ' | ')

# Every fixture root has to come from the OS temp folder, so it lands wherever
# the machine puts temporary files rather than wherever this repository sits.
$badRoots = @()
foreach ($f in $writingFiles) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    if ($text -notmatch 'GetTempPath') {
        # A file that writes but never mentions temp is either writing somewhere
        # else or writing to a path handed in from elsewhere. Worth a look.
        $badRoots += $f.Name
    }
}
Test-Case 'every file that writes uses GetTempPath' '' ($badRoots -join ', ')

# Fixtures are removed. A suite that leaves a directory behind on every run is a
# suite nobody wants to run twice.
$noCleanup = @()
foreach ($f in $writingFiles) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    if ($text -notmatch 'New-Item -ItemType Directory') { continue }
    if ($text -notmatch 'Remove-Item') { $noCleanup += $f.Name }
}
Test-Case 'every file that creates a directory removes it' '' ($noCleanup -join ', ')

Write-Host ''
Write-Host 'The session is left as it was found' -ForegroundColor Cyan

# Changing an environment variable is legitimate: it is how a test makes a
# machine-dependent code path deterministic. Leaving it changed is not.
$envLeaks = @()
foreach ($f in $testFiles) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    foreach ($m in [regex]::Matches($text, '\$env:(\w+)\s*=')) {
        $name = $m.Groups[1].Value
        # Restored means assigned back from a saved variable at least once more
        # than it is set to a literal.
        $sets     = @([regex]::Matches($text, '\$env:' + $name + '\s*=\s*[''"]')).Count
        $restores = @([regex]::Matches($text, '\$env:' + $name + '\s*=\s*\$')).Count
        if ($restores -lt 1 -and $sets -gt 0) { $envLeaks += "$($f.Name): `$env:$name" }
    }
}
Test-Case 'an environment variable that is changed is changed back' '' (($envLeaks | Sort-Object -Unique) -join ', ')

Write-Host ''
Write-Host 'Nothing personal is left in' -ForegroundColor Cyan

# This is a public repository. A developer's own name, machine or folder layout
# in a test fixture is not a defect, but it is not something to publish either,
# and it is exactly what survives a rename of the project folder.
$personal = @()
foreach ($f in $testFiles) {
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
        $n++
        if ($line -match '(?i)copyright') { continue }
        if ($line -match '(?i)\b(paul|admiraal|ictadmiraal)\b' -or
            $line -match '(?i)C:\\Development' -or
            $line -match '(?i)plus-wim-image') {
            $personal += ("{0}:{1}" -f $f.Name, $n)
        }
    }
}
Test-Case 'no personal names, paths or machine names' '' ($personal -join ', ')

Write-Host ''
Write-Host 'The check can actually fail' -ForegroundColor Cyan

# Written into a fixture rather than trusted, because a guard that reports
# everything clean because its detection is wrong is worse than no guard --
# that has happened in this repository before.
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('wf-hyg-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
Set-Content -LiteralPath $fixture -Encoding UTF8 -Value @'
$img = Get-WindowsImage -ImagePath 'C:\real.wim'
Set-Content -LiteralPath 'C:\somewhere\out.txt' -Value 'x'
$env:USERPROFILE = 'C:\Users\someone'
'@

$badAst   = Get-Ast $fixture
$badNames = Get-CommandNames $badAst
Test-Case 'a real DISM call is seen' 'True' `
    (($badNames.Called -contains 'Get-WindowsImage') -and ($badNames.Defined -notcontains 'Get-WindowsImage')).ToString()

$badLines = Get-Content -LiteralPath $fixture
$caught = @($badLines | Where-Object { $_ -match $writers -and $_ -match "-(?:Literal)?Path\s+'[A-Za-z]:" })
Test-Case 'a literal absolute write is seen' 1 $caught.Count

$badText  = Get-Content -LiteralPath $fixture -Raw
$badSets  = @([regex]::Matches($badText, '\$env:USERPROFILE\s*=\s*[''"]')).Count
$badRests = @([regex]::Matches($badText, '\$env:USERPROFILE\s*=\s*\$')).Count
Test-Case 'an unrestored environment variable is seen' 'True' (($badSets -gt 0) -and ($badRests -lt 1)).ToString()

# And the stub exemption really does exempt, or Test-CatalogParser would be
# reported forever for a function it defines itself.
Set-Content -LiteralPath $fixture -Encoding UTF8 -Value @'
function Invoke-WebRequest { param($Uri) return @{ Content = 'stub' } }
$r = Invoke-WebRequest -Uri 'https://example.invalid'
'@
$stubNames = Get-CommandNames (Get-Ast $fixture)
Test-Case 'a stubbed command is not counted as a real call' 'True' `
    (($stubNames.Called -contains 'Invoke-WebRequest') -and ($stubNames.Defined -contains 'Invoke-WebRequest')).ToString()

Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) {
    Write-Host "$($script:Fail) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'The test suite is safe to run on any machine.' -ForegroundColor Green
