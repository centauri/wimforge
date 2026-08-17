# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Branding.ps1 -- product identity, in one place.

    Both front-ends read their name, version and banner from here rather than
    hard-coding strings. Same reason the rest of the toolkit works that way: two
    copies of a version number is one copy too many, and it is always the one you
    forget that ends up on screen.
#>

function Get-WfAbout {
<#
.SYNOPSIS
    Product name, version, author and repository.
.DESCRIPTION
    The version comes from the module manifest, so there is exactly one place to
    bump it.
#>
    [CmdletBinding()]
    param()

    $version = '0.0.0'
    try {
        $manifestPath = Join-WfPath (Split-Path $PSScriptRoot -Parent) 'WimForge.psd1'
        if (Test-Path -LiteralPath $manifestPath) {
            $version = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
        }
    }
    catch { }

    return [pscustomobject]@{
        Name        = 'WimForge'
        Version     = $version
        Tagline     = 'Windows image build and maintenance'
        Author      = 'Paul Admiraal'
        Repository  = 'https://github.com/centauri/wimforge'
        License     = 'MIT'
        Description = 'Build, service, publish and validate a single Windows image that covers many hardware models.'
    }
}

function Get-WfBannerArt {
<#
.SYNOPSIS
    The WimForge wordmark as lines of plain ASCII.
.DESCRIPTION
    Deliberately ASCII only -- no box-drawing or Unicode. This has to render the
    same in a raw console, over RDP, inside WinPE and in whatever code page a
    given machine happens to be using.
#>
    [CmdletBinding()]
    param()

    $art = @'
 __      ___       ___
 \ \    / (_)_ __ | __|__ _ _ __ _ ___
  \ \/\/ /| | |  \| _/ _ \ |_/ _` / -_)
   \_/\_/ |_|_|_|_|_|\___/_| \__, \___|
                             |___/
'@
    return ($art -split "`r?`n")
}

function Show-WfBanner {
<#
.SYNOPSIS
    Writes the banner to the console.
.DESCRIPTION
    The name, the version and the licence, once, at the top of a session. Both
    front-ends call it on startup so a screenshot in a bug report always says
    which build it came from.
.PARAMETER Compact
    One line instead of the wordmark. Used on sub-screens, where the full banner
    would push the actual content off the top.
#>
    [CmdletBinding()]
    param([switch] $Compact)

    $about = Get-WfAbout

    if ($Compact) {
        Write-Host ''
        Write-Host ("  {0} {1}" -f $about.Name, $about.Version) -ForegroundColor Cyan -NoNewline
        Write-Host ("   {0}" -f $about.Tagline) -ForegroundColor DarkGray
        return
    }

    Write-Host ''
    foreach ($line in Get-WfBannerArt) {
        Write-Host $line -ForegroundColor Cyan
    }
    Write-Host ("   {0}  v{1}" -f $about.Tagline, $about.Version) -ForegroundColor Gray
    Write-Host ("   {0}   {1}" -f $about.Author, $about.Repository) -ForegroundColor DarkGray
    Write-Host ''
}
