# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Updates.ps1 -- find and download updates from the Microsoft Update Catalog.

    A word on what this is, because it matters for how it fails.

    There is no official API. Microsoft publishes the catalog as a web
    application and nothing else; every tool that automates it -- WIMWitch,
    MSCatalog, MSCatalogLTS and this one -- scrapes the same two pages:

        Search.aspx          the results table
        DownloadDialog.aspx  an undocumented POST that returns the real file URLs

    That is reverse-engineered, not supported, and Microsoft changes it without
    notice. MSCatalogLTS exists as a fork precisely because the original broke.
    So every parser here is written to fail LOUDLY and specifically -- "the
    catalog page layout has changed" -- rather than dereferencing a null match and
    leaving you wondering why the list is empty. When it does break, the fix is
    always in one of the two parse functions below.

    The fallback is never worse than where you started: download the .msu by hand
    from the catalog and drop it in the Updates folder.
#>

# --------------------------------------------------------------------- private

function Initialize-WfWebRequest {
    <#
        Windows PowerShell 5.1 defaults can leave TLS at 1.0, which the catalog
        refuses, and Invoke-WebRequest's progress bar makes large downloads
        absurdly slow. Both are set once here.
    #>
    try {
        $current = [Net.ServicePointManager]::SecurityProtocol
        if (-not ($current -band [Net.SecurityProtocolType]::Tls12)) {
            [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
        }
    }
    catch {
        Write-WfLog "Could not raise TLS version: $($_.Exception.Message)" -Level WARN
    }
}

function Convert-WfHtmlText {
    <# Strips tags and decodes entities from one table cell. #>
    param([AllowEmptyString()] [string] $Html)

    if (-not $Html) { return '' }
    $t = $Html -replace '(?s)<[^>]+>', ''
    $t = $t -replace '&nbsp;', ' '
    $t = $t -replace '&amp;', '&'
    $t = $t -replace '&lt;', '<'
    $t = $t -replace '&gt;', '>'
    $t = $t -replace '&quot;', '"'
    $t = $t -replace '&#39;', "'"
    return $t.Trim()
}

function Get-WfUpdateCategory {
    <# Best-effort classification, used for filtering and for display. #>
    param([string] $Title, [string] $Classification)

    $t = "$Title $Classification"
    if ($t -match 'Defender|Antimalware|Security Intelligence') { return 'Defender' }
    if ($t -match '\.NET Framework')                            { return 'DotNet' }
    if ($t -match 'Servicing Stack')                            { return 'ServicingStack' }
    if ($t -match 'Cumulative Update')                          { return 'Cumulative' }
    if ($t -match 'Dynamic Update')                             { return 'Dynamic' }
    return 'Other'
}

function Get-WfCategoryQuery {
    <# The search text each category maps to. #>
    param([string] $Category, [string] $Product, [string] $Architecture)

    switch ($Category) {
        'Cumulative' { return "Cumulative Update for $Product $Architecture" }
        'DotNet'     { return ".NET Framework Cumulative Update $Product $Architecture" }
        'Defender'   { return 'Update for Microsoft Defender Antivirus antimalware platform' }
        default      { return "$Product $Architecture" }
    }
}

# --------------------------------------------------- reading an image's release

function Get-WfServicingFamily {
    <#
        Builds that share one cumulative update package, oldest release first.

        This grouping is the whole reason the update side needs to know about
        builds at all. Windows 10 19041-19045 is one family: a 19044 image
        (LTSC 2021) and a 19045 image (22H2) take the same LCU, and Microsoft
        titles that LCU with the newest release still being serviced. So an image
        that is honestly 21H2 needs a search for "Windows 10 Version 22H2" to
        find its own update -- which is exactly the sort of thing nobody works
        out at 5pm on patch Tuesday.
    #>
    return @(
        @{ Builds = @(19041,19042,19043,19044,19045); Releases = @('2004','20H2','21H1','21H2','22H2') }
        @{ Builds = @(22621,22631);                   Releases = @('22H2','23H2') }
        @{ Builds = @(26100,26200);                   Releases = @('24H2','25H2') }
    )
}

function Get-WfWindowsRelease {
    <#
        Build number to release name. Only a fallback: when the image can be read
        properly its own DisplayVersion is authoritative and this is not used.
    #>
    param([int] $Build)

    $map = @{
        10240 = '1507'; 10586 = '1511'; 14393 = '1607'; 15063 = '1703'
        16299 = '1709'; 17134 = '1803'; 17763 = '1809'; 18362 = '1903'
        18363 = '1909'; 19041 = '2004'; 19042 = '20H2'; 19043 = '21H1'
        19044 = '21H2'; 19045 = '22H2'
        22000 = '21H2'; 22621 = '22H2'; 22631 = '23H2'
        26100 = '24H2'; 26200 = '25H2'
    }
    if ($map.ContainsKey($Build)) { return $map[$Build] }
    return $null
}

function Get-WfLaterRelease {
    <#
        The releases after this one within the same servicing family, newest
        first. These are the alternative product strings a search falls back to.
    #>
    param([int] $Build, [string] $Release)

    foreach ($family in (Get-WfServicingFamily)) {
        if ($family.Builds -notcontains $Build) { continue }

        $releases = @($family.Releases)
        $at = [array]::IndexOf($releases, $Release)
        if ($at -lt 0 -or $at -ge ($releases.Count - 1)) { return @() }

        $later = @($releases[($at + 1)..($releases.Count - 1)])
        [array]::Reverse($later)
        return $later
    }
    return @()
}

function ConvertTo-WfArchitectureName {
    <#
        Get-WindowsImage reports architecture as the raw DISM numeric value
        (0 x86, 9 x64, 12 ARM64) in some versions and as text in others. The
        catalog only understands the text.
    #>
    param($Value)

    if ($null -eq $Value) { return '' }
    $s = ([string]$Value).Trim()
    if ($s -eq '') { return '' }

    switch -Regex ($s) {
        '^(?i)(x64|amd64)$' { return 'x64' }
        '^(?i)x86$'         { return 'x86' }
        '^(?i)arm64$'       { return 'arm64' }
        '^(?i)arm$'         { return 'arm' }
    }

    $n = -1
    if ([int]::TryParse($s, [ref]$n)) {
        switch ($n) {
            0  { return 'x86' }
            5  { return 'arm' }
            9  { return 'x64' }
            12 { return 'arm64' }
        }
    }
    return $s
}

function Get-WfImageUpdateTarget {
<#
.SYNOPSIS
    Reads an image and works out which updates it is asking for.
.DESCRIPTION
    Answers the question the catalog search needs answered -- which Windows,
    which release, which architecture -- from the image itself rather than from
    a product string somebody typed once and never revisited.

    The answer only exists in the image's registry: DISM reports Version
    10.0.19041 for every image in the 19041 family, so 2004 and 21H2 look
    identical in the WIM header. Getting at that registry has three routes, and
    this takes the cheapest one available:

    * Already mounted, anywhere -- that mount is used as it stands and nothing
      is mounted or dismounted. Free.

    * Not mounted -- the SOFTWARE hive is pulled straight out of the .wim
      through wimgapi, no mount involved. Seconds rather than minutes, and
      nothing is left behind if it is interrupted. The result is cached against
      the image's size and timestamp, so asking twice costs nothing and an image
      that has been serviced since is read again.

    * Only if that fails, or if -IncludePackage asks for the installed package
      list, is the image mounted read-only and dismounted with -Discard.

    -NoMount refuses the mount entirely. The extraction still runs, so this is
    usually just as good; if that fails too you get the header reading, which is
    right about architecture and edition, guesses the release as the newest one
    in the image's servicing family, and says so.
.PARAMETER ImagePath
    The image to read. Empty means: whatever is mounted, or failing that the
    configured base image.
.PARAMETER Index
    Image index. Ignored when reading an already-mounted image.
.PARAMETER MountPath
    Read this already-mounted folder rather than working it out.
.PARAMETER IncludePackage
    Also list the packages installed in the image, so a search can flag updates
    that are already in there. This is the one thing that cannot be had without
    mounting, so it costs a mount. Cumulative updates land as a RollupFix
    package that does not carry its KB number and so will not be flagged
    anyway -- the build and UBR reported here are the reliable way to read how
    current an image is.
.PARAMETER NoMount
    Never mount, whatever else is asked for.
.EXAMPLE
    Get-WfImageUpdateTarget
.EXAMPLE
    Get-WfImageUpdateTarget -ImagePath D:\Imaging\Images\LTSC2021-Base.wim
.EXAMPLE
    $t = Get-WfImageUpdateTarget
    Find-WfUpdate -Category Cumulative -Product $t.Product -ProductAlternative $t.ProductAlternative -Architecture $t.Architecture -KnownKB $t.InstalledKB
#>
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $ImagePath,
        [int]    $Index = 1,
        [AllowEmptyString()] [string] $MountPath,
        [switch] $IncludePackage,
        [switch] $NoMount
    )

    $cfg = Get-WfConfig

    function Compare-WfSamePath {
        param([string] $A, [string] $B)
        if (-not $A -or -not $B) { return $false }
        return ($A.TrimEnd('\', '/') -eq $B.TrimEnd('\', '/'))
    }

    # What is mounted right now. Unelevated this throws rather than returning
    # nothing, so a failure here is not evidence that nothing is mounted.
    $mountedList = @()
    try { $mountedList = @(Get-WindowsImage -Mounted -ErrorAction Stop) }
    catch { $mountedList = @() }

    $notes       = New-Object System.Collections.Generic.List[string]
    $mountedByUs = $false
    $source      = 'image header'

    # ------------------------------------------------------ what are we reading
    if (-not $MountPath -and -not $ImagePath) {
        $pick = $mountedList | Where-Object { Compare-WfSamePath $_.Path $cfg['MountPath'] } | Select-Object -First 1
        if (-not $pick) { $pick = $mountedList | Select-Object -First 1 }

        if ($pick) {
            $MountPath = $pick.Path
            $ImagePath = $pick.ImagePath
            $Index     = $pick.ImageIndex
        }
        elseif ($cfg['BaseImage'] -and (Test-Path -LiteralPath $cfg['BaseImage'])) {
            $ImagePath = $cfg['BaseImage']
            $notes.Add("Nothing was mounted, so the configured base image was read: $ImagePath")
        }
        else {
            throw 'Nothing to read: no image is mounted and the configured base image was not found. Pass -ImagePath, or mount an image first.'
        }
    }
    elseif ($ImagePath -and -not $MountPath) {
        $already = $mountedList |
                   Where-Object { (Compare-WfSamePath $_.ImagePath $ImagePath) -and $_.ImageIndex -eq $Index } |
                   Select-Object -First 1
        if ($already) { $MountPath = $already.Path }
    }

    # ------------------------------------------------- the registry, cheaply
    # Tried before any mount. Reading one file out of the .wim answers the same
    # question in seconds that a mount answers in minutes, and leaves nothing to
    # clean up if it is interrupted.
    # Skipped only when a mount is going to happen anyway -- that mount can
    # answer the same question, so extracting first would be work for nothing.
    # -NoMount means no mount is coming, so the extraction is still worth trying
    # even when the package list was asked for.
    $mountIsComing = $IncludePackage -and -not $NoMount

    $extracted = @{}
    if (-not $MountPath -and $ImagePath -and -not $mountIsComing) {
        if (Test-WfElevated) {
            $extracted = Get-WfImageCurrentVersion -ImagePath $ImagePath -Index $Index
        }
        else {
            # reg load needs SeRestorePrivilege, so the hive cannot be read at
            # all without elevation -- extracted or mounted.
            $notes.Add('Not elevated, so the image registry could not be read and the release could not be worked out exactly.')
        }
    }

    # ------------------------------------------- an open mount is the one to use
    #
    # This used to look at the mount FOLDER, find it non-empty, and refuse --
    # which is exactly backwards. A non-empty mount folder usually means this
    # image is already open, and opening it is the expensive part: a two-minute
    # mount to read something the open mount already has, followed by a dismount
    # that throws the work away, was the single most wasteful thing this tool did.
    #
    # An image already mounted is reused and, critically, LEFT OPEN: this
    # function did not open it and has no business closing it.
    $reused = $false
    if (-not $MountPath) {
        $open = $null
        try { $open = Get-WfCurrentMount } catch { }

        if ($open -and $open.ImagePath -and
            ($open.ImagePath.TrimEnd('\') -eq "$ImagePath".TrimEnd('\'))) {

            if ($open.Index -ne $Index) {
                $notes.Add("Index $($open.Index) of this image is mounted, not index $Index. Reading the mounted one.")
            }
            $MountPath = $open.MountPath
            $reused    = $true
            Write-WfLog "Using the image already mounted at $MountPath -- no second mount, and it stays open." -Level OK
        }
        elseif ($open -and $open.ImagePath) {
            $notes.Add("A different image is mounted at $($open.MountPath): $(Split-Path $open.ImagePath -Leaf). Dismount it before this one can be mounted.")
        }
    }

    # ---------------------------------------------- mount, only if still needed
    $wantMount = (-not $MountPath) -and ($extracted.Count -eq 0 -or $IncludePackage)

    if ($wantMount -and -not $NoMount) {
        if (-not (Test-WfElevated)) {
            if ($IncludePackage) { $notes.Add('Not elevated, so the installed package list could not be read.') }
        }
        elseif (-not (Test-Path -LiteralPath $ImagePath)) {
            $notes.Add("Image not found: $ImagePath")
        }
        else {
            $target = New-WfDirectory $cfg['MountPath']
            if (@(Get-ChildItem -LiteralPath $target -Force).Count -gt 0) {
                $notes.Add("The mount folder is not empty ($target), so the image was not mounted. Run Repair-WfMount.")
            }
            else {
                $why = 'to read its release'
                if ($IncludePackage) { $why = 'to list the packages installed in it' }
                Write-WfLog "Mounting $(Split-Path $ImagePath -Leaf) read-only $why" -Level STEP
                Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $target -ReadOnly -ErrorAction Stop | Out-Null
                $MountPath   = $target
                $mountedByUs = $true
            }
        }
    }
    elseif ($wantMount -and $NoMount) {
        if ($IncludePackage) { $notes.Add('-NoMount: the installed package list was skipped, since that needs a mount.') }
        else                 { $notes.Add('-NoMount: read from the WIM header only.') }
    }

    try {
        # --------------------------------------------------------- header first
        $imageName   = ''
        $arch        = ''
        $edition     = ''
        $build       = 0
        $ubr         = $null
        $installType = ''
        $productName = ''

        if ($ImagePath -and (Test-Path -LiteralPath $ImagePath)) {
            try {
                $header = Get-WindowsImage -ImagePath $ImagePath -Index $Index -ErrorAction Stop
                $imageName = [string]$header.ImageName
                $arch      = ConvertTo-WfArchitectureName $header.Architecture
                $edition   = [string]$header.EditionId

                $bm = [regex]::Match([string]$header.Version, '^\d+\.\d+\.(\d+)')
                if ($bm.Success) { [void][int]::TryParse($bm.Groups[1].Value, [ref]$build) }

                # SPBuild is the UBR, not a service pack. Only a starting point:
                # the hive below overrides it when we have one.
                if ($header.SPBuild) { $ubr = $header.SPBuild }

                # Present on install.wim, absent on some custom captures.
                if ($header.InstallationType) { $installType = [string]$header.InstallationType }
            }
            catch {
                $notes.Add("Could not read the image header: $($_.Exception.Message)")
            }
        }

        # ------------------------------------------------------- then the hive
        $release   = $null
        $osFamily  = ''
        $precise   = $false
        $hiveRead  = $false
        $installed = @()

        # Whichever route produced values, they are processed identically from
        # here. The extraction ran before any mount, so prefer it when both.
        $cv = $extracted
        $cvSource = 'image file'
        if ($cv.Count -eq 0 -and $MountPath) {
            $cv = Get-WfOfflineCurrentVersion -MountPath $MountPath
            $cvSource = 'mounted image'
        }

        if ($cv.Count -gt 0 -or $MountPath) {
            if ($cv.Count -gt 0) {
                $source   = $cvSource
                $hiveRead = $true

                if ($cv.ContainsKey('InstallationType')) { $installType = [string]$cv['InstallationType'] }
                if ($cv.ContainsKey('ProductName'))      { $productName = [string]$cv['ProductName'] }

                $hiveBuild = 0
                foreach ($name in @('CurrentBuildNumber', 'CurrentBuild')) {
                    if ($hiveBuild -eq 0 -and $cv.ContainsKey($name)) {
                        [void][int]::TryParse([string]$cv[$name], [ref]$hiveBuild)
                    }
                }
                if ($hiveBuild -gt 0) { $build = $hiveBuild }

                if ($cv.ContainsKey('UBR'))       { $ubr     = $cv['UBR'] }
                if ($cv.ContainsKey('EditionID')) { $edition = [string]$cv['EditionID'] }

                # DisplayVersion from 20H2 onward, ReleaseId before it. Neither is
                # present on every image, hence the table as a last resort.
                foreach ($name in @('DisplayVersion', 'ReleaseId')) {
                    if (-not $release -and $cv.ContainsKey($name)) { $release = [string]$cv[$name] }
                }
                if (-not $release -and $build -gt 0) { $release = Get-WfWindowsRelease -Build $build }
            }
            else {
                $notes.Add('The image registry could not be read; falling back to the header.')
            }

            # Only a mount can answer this one.
            if ($MountPath) {
                try {
                    $installed = @(Get-WindowsPackage -Path $MountPath -ErrorAction Stop |
                                   Where-Object { $_.PackageState -eq 'Installed' })
                }
                catch {
                    $notes.Add("Could not enumerate installed packages: $($_.Exception.Message)")
                }
            }
        }

        # ------------------------------------------------------------- compose
        # Precise means the release was actually established, not merely that the
        # hive opened. A build past the end of the table reads fine and still
        # yields no release, and reporting that as "read from the image" would
        # present a stale configured product as if it came off the image.
        $precise = ($hiveRead -and $release)

        # Server is never derived the way a client release is. The build number
        # alone would make Server 2025 look like Windows 11 24H2 -- they ARE the
        # same build -- and the catalog does not title server updates with the
        # words anyone would guess.
        #
        # It titles them like this, which is worth reading twice:
        #
        #   2025-07 Cumulative Update for Microsoft server operating system
        #   version 24H2 for x64-based Systems (KB5062553)
        #
        # No "Windows", no "Server 2025". Searching for the name on the box
        # returns nothing, exactly like searching an LTSC 2021 image for "21H2".
        # So the product is mapped from the build instead, which is exact.
        $serverProducts = @{
            26100 = 'Microsoft server operating system version 24H2'   # Server 2025
            20348 = 'Microsoft server operating system version 21H2'   # Server 2022
            17763 = 'Windows Server 2019'
            14393 = 'Windows Server 2016'
        }
        # The name the operator would search for, kept as a second attempt: some
        # entries for the same release ARE titled this way, and it costs nothing.
        $serverAlso = @{ 26100 = 'Windows Server 2025'; 20348 = 'Windows Server 2022' }

        $serverAlternatives = @()
        $isServer = ($installType -match 'Server') -or ($productName -match 'Windows Server')
        if ($isServer) {
            $osFamily = 'Windows Server'
            if ($productName -match '(Windows Server\s+\d{4}(?:\s+R2)?)') { $osFamily = $Matches[1] }
            $release = $null

            $serverProduct = ''
            if ($serverProducts.ContainsKey($build)) { $serverProduct = $serverProducts[$build] }

            if ($serverProduct) {
                $precise = $hiveRead
                $notes.Add("This is a server image ($productName). The catalog does not title its updates 'Windows Server' -- build $build is sold as '$serverProduct' there, which is what the search uses.")
                if ($serverAlso.ContainsKey($build)) { $serverAlternatives = @($serverAlso[$build]) }
            }
            else {
                $precise = $false
                $notes.Add("This is a server image ($productName), and build $build is not one this toolkit has a catalog name for. The catalog names server updates differently from the box, so nothing was derived -- set the product yourself under Search settings.")
            }
        }
        elseif ($build -ge 22000) { $osFamily = 'Windows 11' }
        elseif ($build -gt 0)     { $osFamily = 'Windows 10' }

        if (-not $precise -and -not $isServer -and $build -gt 0) {
            # The header build is the family's base build, so the release it maps
            # to is the family's OLDEST member -- which is the wrong end. Take the
            # newest instead: that is the one the current cumulative is titled
            # with, and within a family it is the same package anyway.
            $base   = Get-WfWindowsRelease -Build $build
            $newest = @(Get-WfLaterRelease -Build $build -Release $base)
            if ($newest.Count -gt 0) {
                $release = $newest[0]
                $notes.Add("The WIM header cannot tell one release in the $build family from another -- it reports the same version for all of them. Guessed the newest ($release). Mount the image, or run elevated without -NoMount, to read it exactly.")
            }
            else { $release = $base }
        }

        $alternatives = @()
        if ($build -gt 0 -and $release) { $alternatives = @(Get-WfLaterRelease -Build $build -Release $release) }

        $product = ''
        if ($osFamily -and $release -and -not $isServer) { $product = "$osFamily Version $release" }
        elseif ($isServer -and $serverProduct)           { $product = $serverProduct }
        else {
            $product = $cfg['UpdateProduct']
            # The server case already explained itself; do not say it twice.
            if (-not $isServer) {
                $notes.Add("The release could not be worked out, so the configured product was kept: $product")
            }
        }

        $altProducts = @()
        if ($isServer)      { $altProducts = @($serverAlternatives) }
        elseif ($osFamily)  { $altProducts = @($alternatives | ForEach-Object { "$osFamily Version $_" }) }

        if (-not $arch) {
            $arch = $cfg['UpdateArchitecture']
            $notes.Add("Architecture could not be read, so the configured one was kept: $arch")
        }

        $kbs = @()
        if ($installed.Count -gt 0) {
            $kbs = @($installed |
                     ForEach-Object { [regex]::Match([string]$_.PackageName, 'KB(\d{6,})') } |
                     Where-Object { $_.Success } |
                     ForEach-Object { 'KB' + $_.Groups[1].Value } |
                     Sort-Object -Unique)

            # The packages were listed and none of them carries a KB. That is not
            # a failure and it is not an empty image -- a modern cumulative is
            # installed as 'Package_for_RollupFix~...~26100.7623.1.10', with the
            # build in the name and no KB anywhere. So KB matching cannot answer
            # "is this update already in here" for the one kind of update that
            # matters most, and the build number has to do it instead.
            if ($kbs.Count -eq 0) {
                $notes.Add(("The {0} packages in this image carry no KB numbers -- cumulative updates are named for their build, not their KB. Search results are compared on build instead." -f $installed.Count))
            }
        }

        $fullBuild = ''
        if ($build -gt 0) {
            $fullBuild = "$build"
            if ($ubr) { $fullBuild = "$build.$ubr" }
        }

        $result = [pscustomobject]@{
            ImagePath          = $ImagePath
            Index              = $Index
            MountPath          = $MountPath
            ImageName          = $imageName
            EditionId          = $edition
            IsLtsc             = [bool]($edition -match '^(IoT)?Enterprise(S|SN)$')
            Architecture       = $arch
            InstallationType   = $installType
            ProductName        = $productName
            Build              = $build
            Ubr                = $ubr
            FullBuild          = $fullBuild
            Release            = $release
            OsFamily           = $osFamily
            Product            = $product
            ProductAlternative = $altProducts
            InstalledKB        = $kbs
            PackageCount       = $installed.Count
            Source             = $source
            Precise            = $precise
            Notes              = @($notes)
        }

        $shown = $product
        if ($fullBuild) { $shown = "$product ($fullBuild)" }
        Write-WfLog ("Image target: {0} {1} -- read from the {2}" -f $shown, $arch, $source) -Level OK
        foreach ($n in $notes) { Write-WfLog $n -Level WARN }

        return $result
    }
    finally {
        if ($reused) {
            Write-WfLog 'Leaving the mount open -- it was already there before this read.' -Level INFO
        }
        if ($mountedByUs) {
            try {
                Write-WfLog 'Dismounting (discard) after reading the image' -Level STEP
                Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop | Out-Null
            }
            catch {
                Write-WfLog "Dismount failed after reading the image: $($_.Exception.Message)" -Level ERROR
                Write-WfLog 'The image is still mounted. Run Repair-WfMount before the next operation.' -Level ERROR
            }
        }
    }
}

# ---------------------------------------------------------------------- search

function Find-WfUpdate {
<#
.SYNOPSIS
    Searches the Microsoft Update Catalog.
.DESCRIPTION
    Returns one object per catalog result, newest first. Nothing is downloaded --
    pipe what you want into Save-WfUpdate.

    Preview and Dynamic Update entries are filtered out by default. Dynamic
    Updates are for Setup rather than for offline servicing, and previews are
    rarely what you want in a production image.
.PARAMETER Query
    Free-text search, exactly as typed into the catalog. Overrides -Category.
.PARAMETER Category
    Cumulative, DotNet, Defender or Any. Builds the query from the configured
    product and architecture.
.PARAMETER Product
    Defaults to the configured UpdateProduct, e.g. 'Windows 10 Version 21H2'.
    Get-WfImageUpdateTarget reads this off an image instead.
.PARAMETER ProductAlternative
    Other product names to try if the first one finds nothing. Within a servicing
    family the cumulative update is one package titled with the newest release,
    so a 21H2 image finds its own update under 22H2.
.PARAMETER KnownKB
    KBs already installed in the image. Matching results come back with InImage
    set, so you do not download what is already in there.
.PARAMETER First
    Return at most this many results.
.EXAMPLE
    Find-WfUpdate -Category Cumulative
.EXAMPLE
    Find-WfUpdate -Query 'KB5094127' | Save-WfUpdate
.EXAMPLE
    $t = Get-WfImageUpdateTarget
    Find-WfUpdate -Product $t.Product -ProductAlternative $t.ProductAlternative -Architecture $t.Architecture -KnownKB $t.InstalledKB
#>
    [CmdletBinding()]
    param(
        [string]   $Query,
        [ValidateSet('Cumulative','DotNet','Defender','Any')] [string] $Category = 'Cumulative',
        [string]   $Product,
        [string[]] $ProductAlternative,
        [string]   $Architecture,
        [string[]] $KnownKB,
        [string]   $ImageBuild,
        [switch]   $IncludePreview,
        [switch]   $IncludeDynamic,
        [int]      $First = 25
    )

    $cfg = Get-WfConfig
    if (-not $Product)      { $Product      = $cfg['UpdateProduct'] }
    if (-not $Architecture) { $Architecture = $cfg['UpdateArchitecture'] }

    # A free-text query says exactly what to search for, so the product -- and
    # with it the whole idea of an alternative product -- does not apply.
    $products = @($Product)
    if (-not $Query -and $ProductAlternative) {
        $products += @($ProductAlternative | Where-Object { $_ -and $_ -ne $Product })
    }

    $results = @()
    foreach ($candidate in $products) {
        $thisQuery = $Query
        if (-not $thisQuery) {
            $thisQuery = Get-WfCategoryQuery -Category $Category -Product $candidate -Architecture $Architecture
        }

        $results = @(Search-WfCatalog -Query $thisQuery -Architecture $Architecture `
                                      -HasExplicitQuery:([bool]$Query) `
                                      -IncludePreview:$IncludePreview -IncludeDynamic:$IncludeDynamic)

        if ($results.Count -gt 0) {
            if ($candidate -ne $Product) {
                Write-WfLog "Nothing under '$Product'; these are the results for '$candidate', which ships the same package." -Level WARN
            }
            break
        }
    }

    $results = @($results | Sort-Object LastUpdated -Descending)
    if ($First -gt 0) { $results = @($results | Select-Object -First $First) }

    # Build comparison first, because it is the one that works for cumulative
    # updates -- and cumulative updates are what anybody is actually here for.
    # An LCU's title says which build it takes the image to, so an image at
    # 26100.7623 and a result reading 26100.8894 is a definite "you do not have
    # this", with no KB matching involved and no mount needed.
    if ($ImageBuild -and $ImageBuild -match '^\d+\.\d+$') {
        $imgParts = @($ImageBuild -split '\.' | ForEach-Object { [int]$_ })
        foreach ($r in $results) {

            # Parsed HERE rather than only in the catalog parser. The parser is
            # one of several ways a result can arrive, and a comparison that only
            # works for results that came through one particular code path is a
            # comparison that silently does nothing the first time it meets any
            # of the others.
            if (-not $r.PSObject.Properties['TargetBuild']) {
                $r | Add-Member -NotePropertyName TargetBuild -NotePropertyValue '' -Force
            }
            if (-not $r.PSObject.Properties['VsImage']) {
                $r | Add-Member -NotePropertyName VsImage -NotePropertyValue '?' -Force
            }
            if (-not $r.TargetBuild -and $r.Title) {
                $bm = [regex]::Matches([string]$r.Title, '\((\d{5,6}\.\d+)\)')
                if ($bm.Count -gt 0) { $r.TargetBuild = $bm[$bm.Count - 1].Groups[1].Value }
            }
        }

        # A server title does not carry the build, so it has to be fetched.
        #
        # Client:  ... for x64-based Systems (KB5101650) (26100.8875)
        # Server:  ... for x64-based Systems (KB5087545)
        #
        # The build is not missing from the world, only from that title -- and
        # the place it exists is the SAME KB's client entry, because Server 2025
        # and Windows 11 24H2 ship as one KB. One catalog search per unresolved
        # KB turns "?" back into an answer, which is the entire point of the
        # column: an operator looking at a server image at 26100.1742 needs to
        # know whether this row moves it forward, and "cannot tell" is a poor
        # substitute for "yes, to 26100.8875".
        #
        # Bounded, because each one is an HTTP round trip. Whatever is left over
        # keeps the honest '?' rather than a guess.
        # Restricted to SERVER rows, on the row's own title rather than on what
        # was searched for. Plenty of other things carry no build -- a .NET
        # rollup never has one and never will -- and spending a round trip to
        # rediscover that on every row would be a cost with no answer at the end
        # of it. A server cumulative is the one case where the build exists and
        # is merely written down elsewhere.
        $needBuild = @($results | Where-Object {
            -not $_.TargetBuild -and $_.KB -and
            ([string]$_.Title -match '(?i)server operating system|Windows Server')
        })
        if ($needBuild.Count -gt 0) {
            $cap     = 10
            $looked  = @($needBuild | Select-Object -First $cap)
            $skipped = $needBuild.Count - $looked.Count
            Write-WfLog ("{0} result(s) do not say which build they install -- server titles never do. Asking the catalog what the same KB looks like elsewhere." -f $needBuild.Count) -Level INFO

            foreach ($r in $looked) {
                $sibling = @()
                try {
                    $sibling = @(Search-WfCatalog -Query $r.KB -Architecture $Architecture -HasExplicitQuery `
                                                  -IncludePreview:$IncludePreview -IncludeDynamic:$IncludeDynamic)
                }
                catch {
                    # A failed lookup is not a failed search. The row keeps '?'.
                    Write-WfLog ("  could not look up $($r.KB): $($_.Exception.Message)") -Level WARN -NoConsole
                }

                # The same KB covers more than one release -- 26200.8875 for
                # 25H2 and 26100.8875 for 24H2 come out of one update. Only a
                # sibling in the IMAGE's build family answers the question that
                # was asked, so the others are ignored rather than averaged.
                $found = ''
                foreach ($sib in $sibling) {
                    $sm = [regex]::Matches([string]$sib.Title, '\((\d{5,6}\.\d+)\)')
                    if ($sm.Count -eq 0) { continue }
                    $cand = $sm[$sm.Count - 1].Groups[1].Value
                    if ([int]($cand -split '\.')[0] -eq $imgParts[0]) { $found = $cand; break }
                }

                if ($found) {
                    $r.TargetBuild = $found
                    Write-WfLog ("  $($r.KB) installs build $found (from the client entry for the same KB).") -Level INFO -NoConsole
                }
            }

            if ($skipped -gt 0) {
                Write-WfLog ("Only the newest $cap were looked up; $skipped older result(s) keep '?' rather than costing a round trip each.") -Level INFO
            }
        }

        foreach ($r in $results) {
            if (-not $r.TargetBuild) { continue }
            $rParts = @($r.TargetBuild -split '\.' | ForEach-Object { [int]$_ })

            # Different major build means a different release entirely, and
            # comparing the revisions of two different releases is meaningless.
            if ($rParts[0] -ne $imgParts[0]) { $r.VsImage = 'other release'; continue }

            if     ($rParts[1] -gt $imgParts[1]) { $r.VsImage = 'newer' }
            elseif ($rParts[1] -eq $imgParts[1]) { $r.VsImage = 'same' }
            else                                 { $r.VsImage = 'older' }
        }

        $newer   = @($results | Where-Object { $_.VsImage -eq 'newer' })
        $have    = @($results | Where-Object { $_.VsImage -eq 'same' -or $_.VsImage -eq 'older' })
        $noBuild = @($results | Where-Object { -not $_.TargetBuild })

        # Not every title carries the build it installs, and SERVER titles never
        # do. A client cumulative ends '... (KB5101650) (26100.8875)'; the server
        # one for the same month ends '... for x64-based Systems (KB5087545)' and
        # stops there. Reporting "0 would move it forward" for a list nothing
        # could be compared against reads as "you are up to date", which is the
        # most expensive wrong answer this column could give.
        if ($results.Count -gt 0 -and $noBuild.Count -eq $results.Count) {
            Write-WfLog ("The image is at {0}, but none of these titles says which build it installs -- server cumulative titles end at the KB number, where client ones end with the build. Nothing here could be compared to the image; go by the date and the KB." -f `
                $ImageBuild) -Level WARN
        }
        else {
            $tail = ''
            if ($noBuild.Count -gt 0) { $tail = " {0} carry no build in their title and could not be compared." -f $noBuild.Count }
            Write-WfLog ("The image is at {0}. {1} of these would move it forward; {2} are at or below it.{3}" -f `
                $ImageBuild, $newer.Count, $have.Count, $tail) -Level OK
        }
    }

    # Then KB matching, which is exact when it works -- but a modern cumulative
    # is installed under a name with no KB in it, so for those it never can.
    # Only meaningful when the image's packages were actually listed, which
    # needs a mount. Without that the column stays '?' rather than quietly
    # reading as 'no' for everything.
    if ($KnownKB -and @($KnownKB).Count -gt 0) {
        foreach ($r in $results) {
            if ($r.KB -and ($KnownKB -contains $r.KB)) { $r.InImage = 'yes' }
            else                                       { $r.InImage = 'no' }
        }
        $already = @($results | Where-Object { $_.InImage -eq 'yes' })
        if ($already.Count -gt 0) {
            Write-WfLog ("{0} of these are already in the image: {1}" -f `
                $already.Count, (($already | ForEach-Object { $_.KB }) -join ', ')) -Level OK
        }
    }
    elseif (-not $ImageBuild) {
        Write-WfLog "Neither column can be filled in: use Read this image so the build and the installed packages are known." -Level INFO
    }
    else {
        Write-WfLog "The 'InImage' column reads '?' -- either the image's packages were not listed, or they carry no KB numbers, which is normal for cumulative updates. Use the VsImage column instead: it compares builds." -Level INFO
    }

    Write-WfLog ("{0} result(s)" -f $results.Count) -Level OK
    return $results
}

function Search-WfCatalog {
    <#
        One search, parsed. Split out from Find-WfUpdate so a fallback product
        can be tried without duplicating the parser -- and so there is one place
        to fix when the catalog page changes, which it does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [string] $Architecture,
        [switch] $HasExplicitQuery,
        [switch] $IncludePreview,
        [switch] $IncludeDynamic
    )

    Initialize-WfWebRequest

    $url = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($Query)
    Write-WfLog "Searching the catalog: $Query" -Level STEP

    $html = $null
    try {
        $progress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            $html = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content
        }
        finally { $ProgressPreference = $progress }
    }
    catch {
        throw "Could not reach the Microsoft Update Catalog: $($_.Exception.Message)"
    }

    if ($html -match 'We did not find any results|did not match any') {
        Write-WfLog 'The catalog returned no results for that search.' -Level WARN
        return @()
    }

    # Each result row carries the update's GUID in its id attribute. That GUID is
    # the only thing DownloadDialog.aspx needs later.
    $rowMatches = [regex]::Matches($html, '(?s)<tr[^>]*id="([0-9A-Fa-f\-]{36})_R\d+"[^>]*>(.*?)</tr>')

    if ($rowMatches.Count -eq 0) {
        throw 'The catalog responded but no result rows could be parsed. This usually means the page layout has changed -- see the parser in Find-WfUpdate. Downloading the .msu by hand and dropping it in the Updates folder still works.'
    }

    $out = New-Object System.Collections.Generic.List[object]

    foreach ($row in $rowMatches) {
        $guid    = $row.Groups[1].Value
        $rowHtml = $row.Groups[2].Value

        $cells = @([regex]::Matches($rowHtml, '(?s)<td[^>]*>(.*?)</td>') |
                   ForEach-Object { Convert-WfHtmlText $_.Groups[1].Value } |
                   Where-Object { $_ -ne '' })

        # The title is safer to take from its own anchor than by cell position.
        $title = ''
        $tm = [regex]::Match($rowHtml, '(?s)<a[^>]*id="' + [regex]::Escape($guid) + '_link"[^>]*>(.*?)</a>')
        if ($tm.Success) { $title = Convert-WfHtmlText $tm.Groups[1].Value }
        elseif ($cells.Count -gt 0) { $title = $cells[0] }

        if (-not $title) { continue }

        # Remaining columns, guarded -- the catalog has changed their order before.
        $products       = ''
        $classification = ''
        $lastUpdated    = ''
        $sizeText       = ''
        if ($cells.Count -ge 2) { $products       = $cells[1] }
        if ($cells.Count -ge 3) { $classification = $cells[2] }
        if ($cells.Count -ge 4) { $lastUpdated    = $cells[3] }
        if ($cells.Count -ge 6) { $sizeText       = $cells[5] }

        # The human-readable size sits next to a hidden span holding the exact
        # byte count; take the bytes when they are there.
        # 0L, not 0. A [ref] binds to the variable's current type, and an Int32
        # variable handed to [long]::TryParse is the same overload-resolution
        # trap as the date below -- and a cumulative update is well past the
        # point where the distinction is academic.
        $sizeBytes = 0L
        $bm = [regex]::Match($rowHtml,'(?s)<span[^>]*id="' + [regex]::Escape($guid) + '_size"[^>]*>.*?</span>\s*<span[^>]*>(\d+)</span>')
        if ($bm.Success) { [void][long]::TryParse($bm.Groups[1].Value, [ref]$sizeBytes) }

        $kb = ''
        $km = [regex]::Match($title, 'KB(\d{6,})')
        if ($km.Success) { $kb = 'KB' + $km.Groups[1].Value }

        # A [ref] binds to the variable's CURRENT type, so it has to already hold
        # a DateTime. Handing [ref] a $null variable does not fail the parse --
        # it fails to find the overload at all, which is a terminating error and
        # takes the whole search down with a message about argument counts.
        $parsed = [datetime]::MinValue
        $when   = $null
        if ([datetime]::TryParse($lastUpdated, [ref]$parsed)) { $when = $parsed }

        $sizeMb = 0
        if ($sizeBytes -gt 0) { $sizeMb = [math]::Round($sizeBytes / 1MB, 1) }

        # '2026-07 Cumulative Update for Windows 11, version 24H2 ... (26100.8894)'
        # -- the trailing bracket is the build the image ends up at. Taken from
        # the END of the title so a version number earlier in it cannot win.
        $titleBuild = ''
        $bm = [regex]::Matches($title, '\((\d{5,6}\.\d+)\)')
        if ($bm.Count -gt 0) { $titleBuild = $bm[$bm.Count - 1].Groups[1].Value }

        $out.Add([pscustomobject]@{
            KB             = $kb
            Title          = $title
            Category       = (Get-WfUpdateCategory -Title $title -Classification $classification)
            # Regular / OutOfBand / Preview. Nothing in a catalog title
            # distinguishes the month's security update from an emergency fix
            # released a week later -- see Get-WfReleaseKind.
            Release        = (Get-WfReleaseKind -Title $title -LastUpdated $when)
            Classification = $classification
            Products       = $products
            LastUpdated    = $when
            LastUpdatedText= $lastUpdated
            SizeMB         = $sizeMb
            SizeBytes      = $sizeBytes
            SizeText       = $sizeText
            UpdateId       = $guid
            # Three states, not two. '$false' would mean both 'not in the image'
            # and 'nobody looked', and those are very different things to read off
            # a grid at the moment you are deciding what to download.
            InImage        = '?'
            # Cumulative titles end with the build they take the image TO --
            # '... (KB5121767) (26100.8894)'. That is the reliable comparison for
            # exactly the updates KB matching cannot handle.
            TargetBuild    = $titleBuild
            VsImage        = '?'
        })
    }

    # .ToArray() rather than leaving it a List: wrapping a List[object] in @()
    # throws "Argument types do not match" on PowerShell 7, and with both
    # -IncludePreview and -IncludeDynamic set neither filter below runs, so the
    # List would reach the @() at the end untouched.
    $results = $out.ToArray()
    if (-not $IncludePreview) { $results = @($results | Where-Object { $_.Title -notmatch 'Preview' }) }
    if (-not $IncludeDynamic) { $results = @($results | Where-Object { $_.Category -ne 'Dynamic' }) }

    # Architecture is in the title rather than a column, so filter on it here.
    # Skipped for a free-text query: the caller asked for something specific and
    # filtering it back out again would be its own kind of unhelpful.
    if ($Architecture -and -not $HasExplicitQuery) {
        $other = @('x64','x86','arm64') | Where-Object { $_ -ne $Architecture.ToLower() }
        $results = @($results | Where-Object {
            $t = $_.Title.ToLower()
            ($t -match [regex]::Escape($Architecture.ToLower())) -or
            (-not ($other | Where-Object { $t -match $_ }))
        })
    }

    return @($results)
}

# -------------------------------------------------------------------- download

function Get-WfPatchTuesday {
    <# The second Tuesday of a month -- when Microsoft ships the month's
       security updates. Everything else is either a preview or an emergency. #>
    param([int] $Year, [int] $Month)

    $d = Get-Date -Year $Year -Month $Month -Day 1 -Hour 0 -Minute 0 -Second 0
    $seen = 0
    for ($i = 0; $i -lt 21; $i++) {
        if ($d.DayOfWeek -eq [DayOfWeek]::Tuesday) {
            $seen++
            if ($seen -eq 2) { return $d.Date }
        }
        $d = $d.AddDays(1)
    }
    return $null
}

function Get-WfReleaseKind {
<#
.SYNOPSIS
    Regular, OutOfBand or Preview -- which kind of release a catalog entry is.
.DESCRIPTION
    Nothing in a catalog title separates the month's security update from an
    emergency fix shipped a week later. Both read:

        2026-07 Cumulative Update for Windows 11, version 24H2 for x64-based
        Systems (KBxxxxxxx) (26100.88xx)

    The only signal is the date. Microsoft ships security updates on the second
    Tuesday of the month; anything materially later in the same servicing month
    is out-of-band, and previews say so in the title.

    This matters because "newest build wins" is the wrong default. In one real
    search, KB5101650 (14 July, Patch Tuesday) and KB5121767 (18 July, a
    Saturday) both target 24H2 -- and picking purely on build number silently
    chose the emergency fix over the tested monthly release.

    It is a heuristic and is treated as one: it labels rather than filters, so an
    operator picking from a list still sees everything and now knows which is
    which. Only AUTOMATIC selection acts on it.
.PARAMETER Title
    The catalog title. Its 'YYYY-MM' prefix is the servicing month, which is what
    Patch Tuesday is computed from -- not the publication date, so a re-release
    in the following month is still judged against its own month.
.PARAMETER LastUpdated
    The catalog's date for the entry.
#>
    [CmdletBinding()]
    param(
        [string] $Title,
        # Nullable on purpose. A plain [datetime] parameter REFUSES $null -- it
        # fails argument transformation, which is a terminating error, and the
        # caller here is the catalog parser, whose $when is $null whenever a date
        # could not be parsed. Typing this [datetime] took the whole search down
        # for one unreadable date, which is the same trap the parser above
        # already carries a comment about.
        [Nullable[datetime]] $LastUpdated
    )

    if ($Title -match '(?i)\bpreview\b') { return 'Preview' }
    if ($null -eq $LastUpdated -or $LastUpdated -eq [datetime]::MinValue) { return 'Unknown' }

    # The servicing month from the title, falling back to the date's own month.
    $y = $LastUpdated.Year
    $m = $LastUpdated.Month
    $pm = [regex]::Match("$Title", '^\s*(\d{4})-(\d{2})\b')
    if ($pm.Success) {
        $y = [int]$pm.Groups[1].Value
        $m = [int]$pm.Groups[2].Value
    }

    $tuesday = Get-WfPatchTuesday -Year $y -Month $m
    if (-not $tuesday) { return 'Unknown' }

    # A window, not an equality test. The catalog's date can sit a day either
    # side of the release, and a same-week revision is still the monthly update.
    $days = ($LastUpdated.Date - $tuesday).TotalDays
    if ($days -ge -1 -and $days -le 3) { return 'Regular' }
    return 'OutOfBand'
}

function Get-WfUpdateDownloadInfo {
<#
.SYNOPSIS
    Resolves the files behind a catalog update: URL, name, digest and size.
.DESCRIPTION
    POSTs to DownloadDialog.aspx, which answers with a page of JavaScript
    containing the download links. Undocumented and unsupported; if it stops
    returning links this is the function to look at.

    Digest and Size come back empty and 0 when the page did not publish them,
    which callers must treat as "unknown" rather than "wrong".
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $UpdateId)

    Initialize-WfWebRequest

    # The endpoint requires HTTPS. It used to accept HTTP and silently returned
    # an empty downloadInformation array when Microsoft enforced TLS, which broke
    # a lot of scripts quietly.
    $uri  = 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'
    $body = 'updateIDs=' + [uri]::EscapeDataString(
        '[{"size":0,"languages":"","uidInfo":"' + $UpdateId + '","updateID":"' + $UpdateId + '"}]'
    ) + '&updateIDsBlockedForImport=&wsusApiPresent=&contentImport=&sku=&serverName=&ssl=&portNumber=&version='

    $content = $null
    try {
        $progress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            $content = (Invoke-WebRequest -Uri $uri -Method Post -Body $body `
                        -ContentType 'application/x-www-form-urlencoded' `
                        -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content
        }
        finally { $ProgressPreference = $progress }
    }
    catch {
        throw "Could not reach the catalog download endpoint: $($_.Exception.Message)"
    }

    # Every field the page assigns, keyed by which file it belongs to. The page
    # writes one line per property:
    #
    #   downloadInformation[0].files[0].url    = 'https://...msu';
    #   downloadInformation[0].files[0].digest = 'base64==';
    #   downloadInformation[0].files[0].size   = '533761740';
    #
    # url is the only one anything used to read. digest and size are worth far
    # more than that: size here is PER FILE, unlike the size on the search result,
    # which is the total for the whole entry -- and the digest settles whether a
    # download arrived intact rather than merely arriving at the right length.
    #
    # Both are treated as optional. This endpoint is undocumented, and a parser
    # that requires a field it has no promise of getting is a parser that breaks
    # on a page change it could have survived.
    $files = @{}
    foreach ($m in [regex]::Matches($content,
        "downloadInformation\[(\d+)\]\.files\[(\d+)\]\.(\w+)\s*=\s*'([^']*)'")) {
        $key = "$($m.Groups[1].Value)/$($m.Groups[2].Value)"
        if (-not $files.ContainsKey($key)) { $files[$key] = @{} }
        $files[$key][$m.Groups[3].Value.ToLowerInvariant()] = $m.Groups[4].Value
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($key in ($files.Keys | Sort-Object)) {
        $f = $files[$key]
        if (-not $f['url']) { continue }

        $size = 0L
        if ($f['size']) { [void][long]::TryParse($f['size'], [ref]$size) }

        $name = $f['name']
        if (-not $name) { $name = Split-Path (($f['url']) -split '\?')[0] -Leaf }

        $out.Add([pscustomobject]@{
            Url    = $f['url']
            Name   = $name
            Digest = "$($f['digest'])"
            Size   = $size
        })
    }

    # Fallback: any download-host URL on the page. No digest, no size -- but a
    # download with no integrity check still beats no download.
    if ($out.Count -eq 0) {
        foreach ($m in [regex]::Matches($content, "'(https://[^']*\.(?:msu|cab|exe|psf))'")) {
            $u = $m.Groups[1].Value
            if ($out | Where-Object { $_.Url -eq $u }) { continue }
            $out.Add([pscustomobject]@{
                Url = $u; Name = (Split-Path ($u -split '\?')[0] -Leaf); Digest = ''; Size = 0L
            })
        }
    }

    if ($out.Count -eq 0) {
        throw "The catalog returned no download links for $UpdateId. Either the update has no direct download, or the DownloadDialog response format has changed -- see Get-WfUpdateDownloadInfo."
    }

    return $out.ToArray()
}

function Get-WfUpdateDownloadUrl {
<#
.SYNOPSIS
    Resolves the real file URLs for a catalog update.
.DESCRIPTION
    The URLs only. Get-WfUpdateDownloadInfo returns the same files with the
    digest and per-file size the catalog publishes alongside them.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $UpdateId)

    return @(Get-WfUpdateDownloadInfo -UpdateId $UpdateId | ForEach-Object { $_.Url })
}

function Get-WfUrlSize {
    <#
        How big the server says a file is, for the case where the catalog page
        did not say. Best-effort: 0 means "no idea", never an exception, because
        a size hint must not be able to fail a download.
    #>
    param([Parameter(Mandatory)] [string] $Url)

    try {
        Initialize-WfWebRequest
        $progress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        }
        finally { $ProgressPreference = $progress }

        $len = $head.Headers['Content-Length']
        if ($len) {
            $n = 0L
            if ([long]::TryParse("$len", [ref]$n)) { return $n }
        }
    }
    catch { }
    return 0L
}

function Save-WfUpdate {
<#
.SYNOPSIS
    Downloads an update into the Updates folder, ready for servicing.
.DESCRIPTION
    Accepts objects from Find-WfUpdate on the pipeline, or a bare UpdateId.

    An existing file of the right size is left alone, so re-running is cheap.
    Downloads are checked for a valid container header -- cabinet (MSCF) or WIM
    (MSWIM, which is what Windows 11 24H2 and later cumulative updates use) --
    and for a plausible size, before being kept. A truncated transfer or a proxy
    login page would otherwise sit in the Updates folder and fail much later, in
    the middle of a servicing run.

    One catalog entry can be more than one file. Windows 11 24H2 servicing uses
    checkpoint updates, so the latest cumulative comes down alongside the
    checkpoint it builds on; both are needed, and both are saved.
.PARAMETER Destination
    Defaults to the configured UpdateRoot.
.EXAMPLE
    Find-WfUpdate -Category Cumulative | Select-Object -First 1 | Save-WfUpdate
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string] $UpdateId,

        [Parameter(ValueFromPipelineByPropertyName)] [string] $Title,
        [Parameter(ValueFromPipelineByPropertyName)] [string] $KB,
        [Parameter(ValueFromPipelineByPropertyName)] [long]   $SizeBytes,

        [string] $Destination,
        [switch] $Force
    )

    begin {
        $cfg = Get-WfConfig
        if (-not $Destination) { $Destination = $cfg['UpdateRoot'] }
        New-WfDirectory $Destination | Out-Null
        $saved = New-Object System.Collections.Generic.List[object]
    }

    process {
        $label = $KB
        if (-not $label) { $label = $UpdateId }

        Write-WfLog "Resolving download for $label" -Level STEP
        $urls = @(Get-WfUpdateDownloadInfo -UpdateId $UpdateId)

        # The target goes in a folder of its own. The checkpoints go BELOW it,
        # and the separation is the whole point.
        #
        # Windows 11 24H2 cumulative updates are checkpoint-based: one catalog
        # entry downloads as several .msu files, of which exactly ONE is the
        # update. The others are earlier checkpoints.
        #
        # Microsoft's documented procedure is to put the target and every prior
        # checkpoint in one folder and point DISM at the target. That procedure
        # is also what fails: with a checkpoint .msu sitting beside the target,
        # DISM hands the pair to the Windows Update Agent
        # (CDismMsuManager::ProcessWithUpdateAgent) and the apply dies -- 0x800401E3
        # here, 0x80070228 for others, both surfacing as the same misleading
        # "error applying the Unattend.xml file from the .msu package".
        #
        # Microsoft's own guidance elsewhere is that a checkpoint does not need
        # applying at all when it is already in the image, and for any image past
        # the checkpoint's build it always is. So the target is applied ALONE,
        # which is the combination that works, and the checkpoints are kept one
        # directory down: present if a retry needs them, invisible to DISM if not.
        #
        #   Updates\KB5121767\windows11.0-kb5121767-....msu   <- applied
        #   Updates\KB5121767\checkpoints\windows11.0-kb5043080-....msu
        # Downloads are filed by Windows generation before anything else.
        #
        # The Updates folder is a folder: it accumulates, and a servicing run
        # applies everything under it. Testing a Windows 10 image and a Windows 11
        # image in the same afternoon put both generations in one pile, and the
        # run handed a 24H2 package to a 19044 image. Add-WfUpdate refuses that
        # now -- but a layout where it cannot arise beats a check that catches it,
        # and "which of these files is for which image" stops being a question
        # anyone has to hold in their head.
        #
        #   Updates\Windows11\KB5121767\windows11.0-kb5121767-....msu
        #   Updates\Windows11\KB5121767\checkpoints\...
        #   Updates\Windows10\windows10.0-kb5099539-....msu
        #   Updates\Server2025\KB5062553\windows11.0-kb5062553-x64-2025-....msu
        #
        # Server 2025 gets its own folder for a sharper reason than tidiness: it
        # is build 26100, exactly like Windows 11 24H2, and the catalog issues
        # both under the SAME KB. One search, three download buttons, and the
        # only difference on disk is '-2025' in the middle of the file name.
        # Filed apart, that stops being something anyone has to notice.
        #
        # Taken from the file name, which is the same signal Add-WfUpdate checks,
        # so the two can never disagree. A name that does not carry a generation
        # stays at the root rather than being filed under a guess.
        $genRoot = $Destination
        $gen     = Get-WfPackageIdentity -Name @($urls)[0].Name
        if ($gen.Generation) {
            $genRoot = Join-WfPath $Destination $gen.Generation
            New-WfDirectory $genRoot | Out-Null
        }

        $setRoot   = $genRoot
        $checkRoot = $null
        $target    = $null

        if ($urls.Count -gt 1) {
            $folder = $KB
            if (-not $folder) { $folder = $UpdateId }
            $setRoot   = Join-WfPath $genRoot $folder
            $checkRoot = Join-WfPath $setRoot 'checkpoints'
            New-WfDirectory $setRoot   | Out-Null
            New-WfDirectory $checkRoot | Out-Null

            # Which one is the update? The one carrying the KB that was asked
            # for. Falling back to the newest KB number covers a set whose
            # filenames do not spell it out.
            if ($KB) {
                $target = @($urls | Where-Object { $_.Name -match [regex]::Escape($KB.TrimStart('K','B')) })[0]
            }
            if (-not $target) {
                $target = @($urls | Sort-Object { ConvertTo-WfNaturalKey $_.Name })[-1]
            }

            Write-WfLog ("$label is $($urls.Count) files: one update and $($urls.Count - 1) earlier checkpoint(s).") -Level INFO
            Write-WfLog ("  applying: $($target.Name)") -Level INFO
            Write-WfLog ("  the checkpoint(s) go in $checkRoot -- deliberately NOT beside the update. A checkpoint .msu sitting next to the target is what makes DISM fail with the Unattend.xml error, and an image past the checkpoint's build does not need it.") -Level INFO
        }

        foreach ($file in $urls) {
            $url  = $file.Url
            $name = $file.Name
            # One file in a set is the update; the rest are earlier checkpoints.
            # A single-file update is trivially its own target.
            $isTarget = (-not $target) -or ($target.Name -eq $name)

            # And this is where the separation actually happens.
            $dir = $setRoot
            if (-not $isTarget -and $checkRoot) { $dir = $checkRoot }
            $path = Join-WfPath $dir $name

            # How big SHOULD this file be?
            #
            # NOT $SizeBytes when the update is more than one file. The catalog
            # publishes one size per search result and that size is the TOTAL --
            # for KB5121767 it is 5,743,873,870, which is the 509 MB checkpoint
            # plus the 4.85 GB cumulative added together. Comparing each file
            # against the pair's total meant the checkpoint never matched, was
            # declared short, and was downloaded again. Every run, forever, since
            # the re-download produced exactly the same "wrong" size.
            #
            # The download dialog publishes a real per-file size. Use that, fall
            # back to asking the server, and only use the entry total when there
            # is genuinely one file for it to describe.
            $expected = [long]$file.Size
            if ($expected -le 0) { $expected = Get-WfUrlSize -Url $url }
            if ($expected -le 0 -and $urls.Count -eq 1) { $expected = $SizeBytes }

            $floor = 0
            if ($name -match '\.msu$') { $floor = 1MB }

            if ((Test-Path -LiteralPath $path) -and -not $Force) {
                $existing = (Get-Item -LiteralPath $path).Length

                # Size and header only, deliberately: no hash here.
                #
                # The digest is checked when a file LANDS. Re-hashing 5 GB on
                # every run to re-confirm something already confirmed would make
                # "it's already downloaded" the slow path, which is exactly
                # backwards -- the whole point of the check is to avoid work.
                $intact = Test-WfUpdateContainer -Path $path -MinimumBytes $floor

                if ($intact.Ok -and ($expected -le 0 -or $existing -eq $expected)) {
                    Write-WfLog "Already downloaded: $name" -Level OK
                    $saved.Add([pscustomobject]@{ KB = $KB; Title = $Title; File = $name; Path = $path; Status = 'AlreadyPresent'; SizeBytes = $existing; IsTarget = $isTarget; SetPath = $setRoot })
                    continue
                }

                if (-not $intact.Ok) {
                    Write-WfLog "$name is on disk but $($intact.Reason) -- downloading it again" -Level WARN
                }
                else {
                    Write-WfLog ("$name is {0:N0} bytes on disk but should be {1:N0} -- downloading it again" -f $existing, $expected) -Level WARN
                }
            }

            $temp = "$path.partial"
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

            Write-WfLog "Downloading $name" -Level INFO
            $started = Get-Date

            try {
                # BITS first: resumable, and it reports progress without the
                # memory behaviour Invoke-WebRequest has on large files in 5.1.
                if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
                    Start-BitsTransfer -Source $url -Destination $temp -Description $name -ErrorAction Stop
                }
                else {
                    $client = New-Object System.Net.WebClient
                    try   { $client.DownloadFile($url, $temp) }
                    finally { $client.Dispose() }
                }
            }
            catch {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                Write-WfLog "Download failed for $name -- $($_.Exception.Message)" -Level ERROR
                $saved.Add([pscustomobject]@{ KB = $KB; Title = $Title; File = $name; Path = $path; Status = 'Failed'; SizeBytes = 0; IsTarget = $isTarget; SetPath = $setRoot })
                continue
            }

            # Catch a proxy login page or a transfer cut short here, rather than
            # twenty minutes into a servicing run. See Test-WfUpdateContainer for
            # why "is it a cabinet" was the wrong question.
            $ok = $true
            if ($name -match '\.(msu|cab)$') {
                # A .cab has no size floor: some genuinely are tiny.
                $check = Test-WfUpdateContainer -Path $temp -MinimumBytes $floor
                if (-not $check.Ok) {
                    $ok = $false
                    Write-WfLog "$name was discarded -- $($check.Reason)." -Level ERROR
                }
                elseif ($check.Kind -eq 'Wim') {
                    # Worth saying out loud: it is the newer format, and a host
                    # whose servicing stack predates it cannot apply one.
                    Write-WfLog "$name is a WIM-format update package, which is normal for Windows 11 24H2 and later." -Level INFO
                }
            }

            # Length, then hash. Cheap check first: a transfer that stopped at
            # 3 GB of 5 has a valid header and clears the size floor, and there
            # is no point hashing 3 GB to learn what one Length property says.
            if ($ok -and $expected -gt 0) {
                $got = (Get-Item -LiteralPath $temp).Length
                if ($got -ne $expected) {
                    $ok = $false
                    Write-WfLog ("$name came down as {0:N0} bytes but should be {1:N0} -- discarded as incomplete." -f $got, $expected) -Level ERROR
                }
            }

            # And the real answer. Right length is not the same as right file,
            # and this is the one check that can tell the difference. Only ever
            # here, on a file that has just landed -- see the note above about
            # not re-hashing what is already on disk.
            if ($ok -and $file.Digest) {
                Write-WfLog ("Verifying $name ({0})..." -f (Format-WfSize (Get-Item -LiteralPath $temp).Length)) -Level INFO
                $hash = Test-WfFileDigest -Path $temp -Digest $file.Digest
                if (-not $hash.Ok) {
                    $ok = $false
                    Write-WfLog "$name was discarded -- $($hash.Reason)." -Level ERROR
                }
                elseif ($hash.Checked) {
                    Write-WfLog "  $($hash.Algorithm) matches the catalog." -Level OK
                }
                else {
                    # Unverifiable is not the same as bad. Say which it was.
                    Write-WfLog "  not verified: $($hash.Reason)." -Level WARN
                }
            }

            if (-not $ok) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                $saved.Add([pscustomobject]@{ KB = $KB; Title = $Title; File = $name; Path = $path; Status = 'Invalid'; SizeBytes = 0; IsTarget = $isTarget; SetPath = $setRoot })
                continue
            }

            Move-Item -LiteralPath $temp -Destination $path -Force
            $bytes   = (Get-Item -LiteralPath $path).Length
            $seconds = [math]::Round(((Get-Date) - $started).TotalSeconds)
            Write-WfLog ("Saved {0} ({1}) in {2}s" -f $name, (Format-WfSize $bytes), $seconds) -Level OK

            $saved.Add([pscustomobject]@{ KB = $KB; Title = $Title; File = $name; Path = $path; Status = 'Downloaded'; SizeBytes = $bytes; IsTarget = $isTarget; SetPath = $setRoot })

            Write-WfHistory -Action 'Update downloaded' -ImagePath $path -Detail @{
                KB = $KB; File = $name; SizeBytes = $bytes; UpdateId = $UpdateId
            } -Notes $Title | Out-Null
        }

        # A marker, so the folder is still self-describing on a later run when
        # none of the above is in memory any more. Without it, a servicing run
        # that simply scans the Updates tree would find several .msu files in one
        # directory and go back to installing each of them -- which is precisely
        # the behaviour this set exists to prevent.
        if ($target) {
            $marker = Join-WfPath $setRoot 'wimforge-set.json'
            try {
                [pscustomobject]@{
                    KB       = $KB
                    UpdateId = $UpdateId
                    Title    = $Title
                    Target   = $target.Name
                    Files       = @($urls | ForEach-Object { $_.Name })
                    Checkpoints = @($urls | Where-Object { $_.Name -ne $target.Name } | ForEach-Object { $_.Name })
                    Note        = 'Checkpoint set. Apply Target ONLY. The checkpoints live in .\checkpoints and are deliberately not beside the target -- a checkpoint .msu in the same directory makes DISM fail with "An error occurred applying the Unattend.xml file from the .msu package". They are kept in case a retry needs them.'
                } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $marker -Encoding UTF8 -Force
            }
            catch { Write-WfLog "Could not write $marker -- $($_.Exception.Message)" -Level WARN }
        }
    }

    end { return $saved }
}

function Get-WfUpdateSet {
<#
.SYNOPSIS
    If this folder is a checkpoint set, which file in it is the update.
.DESCRIPTION
    Returns the parsed wimforge-set.json for a folder, or $null if the folder is
    just a folder. Written by Save-WfUpdate when one catalog entry resolves to
    several files, so a later run -- which has none of that context -- can still
    tell an update apart from the checkpoints it may be rebuilt from.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not $Path) { return $null }
    $marker = Join-Path $Path 'wimforge-set.json'
    if (-not (Test-Path -LiteralPath $marker)) { return $null }

    try   { return (Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json) }
    catch { return $null }
}

function Get-WfLatestUpdate {
<#
.SYNOPSIS
    Finds and downloads the newest update for a category. For unattended runs.
.DESCRIPTION
    The scripted counterpart of the interactive picker: search, take the newest
    result, download it. Intended for a scheduled job that fetches the month's
    cumulative before a servicing run.
.PARAMETER WhatIfOnly
    Report what would be downloaded without fetching it.
.EXAMPLE
    Get-WfLatestUpdate -Category Cumulative
.EXAMPLE
    Get-WfLatestUpdate -Category Cumulative -WhatIfOnly
#>
    [CmdletBinding()]
    param(
        [ValidateSet('Cumulative','DotNet','Defender','Any')] [string] $Category = 'Cumulative',
        [string]   $Query,
        [string]   $Product,
        [string[]] $ProductAlternative,
        [string]   $Architecture,
        [string[]] $KnownKB,
        [string]   $ImageBuild,
        [switch]   $IncludePreview,
        [switch]   $PreferOutOfBand,
        [switch]   $WhatIfOnly
    )

    # @() around the call, not around $found afterwards: a function returning an
    # empty array writes nothing to the output stream, so $found would be $null
    # and @($null).Count is 1, not 0. The guard below would then never fire and
    # a search with no hits would fail inside Save-WfUpdate instead of saying so.
    $found = @(Find-WfUpdate -Category $Category -Query $Query -Product $Product `
                             -ProductAlternative $ProductAlternative -Architecture $Architecture `
                             -KnownKB $KnownKB -ImageBuild $ImageBuild `
                             -IncludePreview:$IncludePreview -First 5)

    if ($found.Count -eq 0) {
        Write-WfLog 'Nothing found -- nothing downloaded.' -Level WARN
        return @()
    }

    # "Newest build wins" is the wrong rule for an unattended job.
    #
    # An out-of-band release always has a higher build than the monthly update it
    # follows, so sorting on build silently makes an emergency fix the default
    # choice -- a narrower fix, less soak time, and not what a maintenance run
    # should pick on its own. In one real search that meant KB5121767 (18 July,
    # a Saturday) beating KB5101650 (14 July, Patch Tuesday).
    #
    # The interactive picker still shows everything and labels it. Only this
    # path, where nobody is watching, applies a preference.
    $newest  = @($found)[0]
    $regular = @($found | Where-Object { $_.Release -eq 'Regular' })

    if (-not $PreferOutOfBand -and $regular.Count -gt 0 -and $newest.Release -ne 'Regular') {
        Write-WfLog ("Skipping {0} -- it is an {1} release. Taking the monthly security update instead; pass -PreferOutOfBand to override." -f `
            $newest.KB, $newest.Release) -Level WARN
        $newest = $regular[0]
    }

    Write-WfLog ("Newest: {0}  ({1}, {2})" -f $newest.Title, $newest.LastUpdatedText, $newest.Release) -Level OK

    # Compared against the value, not truthiness: '?' is a non-empty string and
    # would read as true, so an unchecked image would claim every update was
    # already installed.
    if ($newest.InImage -eq 'yes') {
        Write-WfLog 'That KB is already installed in the image it was matched against.' -Level WARN
    }
    elseif ($newest.VsImage -eq 'same' -or $newest.VsImage -eq 'older') {
        Write-WfLog ("The image is already at {0}, and this update only takes it to {1}. Downloading it anyway." -f `
            $ImageBuild, $newest.TargetBuild) -Level WARN
    }
    elseif ($newest.VsImage -eq 'newer') {
        Write-WfLog ("This moves the image from {0} to {1}." -f $ImageBuild, $newest.TargetBuild) -Level OK
    }

    if ($WhatIfOnly) {
        Write-WfLog 'WhatIfOnly -- not downloading.' -Level WARN
        return $newest
    }

    return ($newest | Save-WfUpdate)
}

# ---------------------------------------------------------------- the folder

function Get-WfUpdateFolder {
<#
.SYNOPSIS
    Lists what is already in the Updates folder.
.DESCRIPTION
    These are the files a servicing run will apply, in the order it will apply
    them. Worth a look before starting one -- a stale update left behind from
    last month gets applied again otherwise.
#>
    [CmdletBinding()]
    param([string] $Path)

    $cfg = Get-WfConfig
    if (-not $Path) { $Path = $cfg['UpdateRoot'] }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-WfLog "Updates folder not found: $Path" -Level WARN
        return @()
    }

    $files = @(Get-ChildItem -LiteralPath $Path -Include '*.msu','*.cab' -File -Recurse | Sort-Object Name)

    if ($files.Count -eq 0) {
        # An empty grid with no message reads as "the tool did not work". It is
        # also genuinely ambiguous: a download that failed cleans its partial
        # file up after itself, so the folder looks identical whether nothing was
        # ever attempted or something was attempted and did not survive.
        Write-WfLog "Nothing staged in $Path -- no .msu or .cab there yet." -Level INFO
        Write-WfLog 'A failed download removes its partial file, so an empty folder does not distinguish "not tried" from "tried and failed" -- the log for that run is what says which.' -Level INFO

        $partial = @(Get-ChildItem -LiteralPath $Path -Filter '*.partial' -File -Recurse -ErrorAction SilentlyContinue)
        if ($partial.Count -gt 0) {
            Write-WfLog ("{0} interrupted download(s) are still here: {1}. Those are safe to delete." -f `
                $partial.Count, (($partial | ForEach-Object { $_.Name }) -join ', ')) -Level WARN
        }
        return @()
    }

    return $files | ForEach-Object {
        $kb = ''
        $m = [regex]::Match($_.Name, 'kb(\d{6,})', 'IgnoreCase')
        if ($m.Success) { $kb = 'KB' + $m.Groups[1].Value }

        [pscustomobject]@{
            File     = $_.Name
            KB       = $kb
            SizeMB   = [math]::Round($_.Length / 1MB, 1)
            Modified = $_.LastWriteTime
            AgeDays  = [math]::Round(((Get-Date) - $_.LastWriteTime).TotalDays)
            Path     = $_.FullName
        }
    }
}

function Remove-WfUpdate {
<#
.SYNOPSIS
    Removes a file from the Updates folder.
.DESCRIPTION
    Everything in that folder gets applied by the next servicing run, so clearing
    out last month's cumulative is part of the routine rather than housekeeping.
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string] $File,
        [string] $Path
    )

    $cfg = Get-WfConfig
    if (-not $Path) { $Path = $cfg['UpdateRoot'] }

    $target = $File
    if (-not (Test-Path -LiteralPath $target)) { $target = Join-WfPath $Path $File }

    # Downloads are filed under Windows10\, Windows11\ and Server2025\, and a
    # checkpoint set
    # gets a KB folder below that -- so a bare file name is no longer necessarily
    # at the root. The grid hands back names, so resolving one has to search.
    if (-not (Test-Path -LiteralPath $target)) {
        $found = @(Get-ChildItem -LiteralPath $Path -Filter (Split-Path $File -Leaf) -File -Recurse -ErrorAction SilentlyContinue)
        if ($found.Count -eq 1) { $target = $found[0].FullName }
        elseif ($found.Count -gt 1) {
            throw ("More than one file called {0} under {1}: {2}. Pass the full path." -f `
                    (Split-Path $File -Leaf), $Path, (($found | ForEach-Object { $_.FullName }) -join '; '))
        }
    }
    if (-not (Test-Path -LiteralPath $target)) { throw "Not found in the Updates folder: $File" }

    if ($PSCmdlet.ShouldProcess($target, 'Remove update')) {
        $size = (Get-Item -LiteralPath $target).Length
        Remove-Item -LiteralPath $target -Force
        Write-WfLog ("Removed {0} ({1})" -f (Split-Path $target -Leaf), (Format-WfSize $size)) -Level OK
    }
}
