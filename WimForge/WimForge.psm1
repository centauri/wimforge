# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    WimForge module loader.

    Private\*.ps1 loads first (helpers the public functions depend on), then
    Public\*.ps1. The manifest's FunctionsToExport list is the single source of
    truth for the public surface -- a new function is not callable until it is
    listed there. That is deliberate: it stops half-finished helpers leaking into
    the menu and the GUI.

    Windows PowerShell 5.1, Desktop edition. See the manifest for why.
#>

$privateFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$publicFiles  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($privateFiles + $publicFiles)) {
    try {
        . $file.FullName
    }
    catch {
        throw "WimForge: failed to load $($file.Name) -- $($_.Exception.Message)"
    }
}

# Module-scope state. Kept here rather than in globals so that Remove-Module
# genuinely resets everything -- a stale mount path surviving a reload is the
# kind of thing that costs an afternoon.
$script:WfConfig     = $null
$script:WfConfigPath = $null
$script:WfLogPath    = $null

# The manifest does the filtering; this just makes every dot-sourced function
# visible to it.
Export-ModuleMember -Function '*'
