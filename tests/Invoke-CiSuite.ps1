# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.
#
# The whole suite in one command: every test file, the front-end parity check and
# the manifest load, in whichever PowerShell is running this.
#
# It exists for two reasons.
#
# The first is local. Forty-two test files is more than anyone wants to start by
# hand, and a suite that is awkward to run is a suite that gets run less often
# than it should.
#
# The second is the workflow. A step's `shell:` key is one of the few workflow
# keys that takes no expression, so a build matrix cannot hand it the shell to
# use -- GitHub rejects the file outright with "Unrecognized named-value:
# 'matrix'". Keeping the suite in a script means the workflow needs only two
# literal shell names and one line each, and neither copy can drift from the
# other because there is only one copy.
#
# Nothing here needs DISM, an image, elevation or a network. That is a property
# of the tests themselves, guarded by Test-TestHygiene.ps1.

$ErrorActionPreference = 'Continue'

# PowerShell 7 can turn a native command's non-zero exit into a terminating
# error when this is true. The tests were written for Windows PowerShell 5.1,
# where git check-ignore returning 1 just sets $LASTEXITCODE. Leave that
# behaviour in place so the suite does not abort on the pwsh job.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $PSNativeCommandUseErrorActionPreference = $false
}

$root = Split-Path $PSScriptRoot -Parent

# The tests locate everything from $PSScriptRoot, but Test-FrontEndParity.ps1 and
# anything reading a relative path deserve a known working directory rather than
# whatever the caller happened to be in.
Push-Location $root
try {
    Write-Host ''
    Write-Host ('PowerShell {0} ({1}) on {2}' -f `
        $PSVersionTable.PSVersion,
        $PSVersionTable.PSEdition,
        [Environment]::OSVersion.VersionString) -ForegroundColor Cyan

    $failed = New-Object System.Collections.Generic.List[string]

    # ------------------------------------------------------------- test files
    $tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File |
               Sort-Object Name)

    Write-Host ("Running {0} test file(s)." -f $tests.Count) -ForegroundColor Cyan

    foreach ($t in $tests) {
        Write-Host ''
        Write-Host ("=== {0} ===" -f $t.Name) -ForegroundColor Cyan

        # Reset before each run. $LASTEXITCODE is sticky: a test file that passes
        # without calling exit leaves the previous file's code in place, so one
        # real failure would otherwise name every quiet test that followed it.
        $global:LASTEXITCODE = 0

        try {
            & $t.FullName
            if ($LASTEXITCODE -ne 0) { $failed.Add($t.Name) }
        }
        catch {
            # A test that throws rather than exiting is still a failure, and the
            # remaining files are still worth running.
            Write-Host ("  FAIL {0} threw: {1}" -f $t.Name, $_.Exception.Message) -ForegroundColor Red
            $failed.Add($t.Name)
        }
    }

    # --------------------------------------------------------------- parity
    Write-Host ''
    Write-Host '=== Front-end parity ===' -ForegroundColor Cyan

    # Parameter differences are reported but do not fail the build: one front-end
    # legitimately prompts for a value the other defaults.
    $global:LASTEXITCODE = 0
    try {
        & (Join-Path $root 'Test-FrontEndParity.ps1') -AllowParameterDifferences
        if ($LASTEXITCODE -ne 0) { $failed.Add('Test-FrontEndParity.ps1') }
    }
    catch {
        Write-Host ("  FAIL parity threw: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $failed.Add('Test-FrontEndParity.ps1')
    }

    # ------------------------------------------------------------- manifest
    Write-Host ''
    Write-Host '=== Manifest ===' -ForegroundColor Cyan

    try {
        $manifest = Import-PowerShellDataFile (Join-Path $root 'WimForge\WimForge.psd1')
        $count = @($manifest.FunctionsToExport).Count
        Write-Host ("  the manifest exports {0} function(s)" -f $count) -ForegroundColor DarkGray
        if ($count -lt 1) { throw 'the manifest exports nothing' }
    }
    catch {
        Write-Host ("  FAIL manifest: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $failed.Add('WimForge.psd1')
    }

    # -------------------------------------------------------------- verdict
    Write-Host ''
    if ($failed.Count -gt 0) {
        $summary = "FAILED ({0}): {1}" -f $failed.Count, ($failed.ToArray() -join ', ')
        Write-Host $summary -ForegroundColor Red
        if ($env:GITHUB_ACTIONS) { Write-Host "::error::$summary" }
        exit 1
    }

    Write-Host ("All {0} test file(s), parity and the manifest passed." -f $tests.Count) -ForegroundColor Green
    exit 0
}
finally {
    Pop-Location
}
