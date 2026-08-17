# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    BootAndPublish.ps1 -- the WinPE boot image and getting finished images onto
    the WDS share.

    The boot image is where a multi-model rollout usually breaks. A terminal whose
    NIC driver is missing from PE never PXE-boots; one whose storage controller is
    missing boots but finds no disk. Either way the model silently drops out of the
    deployment path and nobody notices until a store calls.
#>

function Add-WfBootDriver {
<#
.SYNOPSIS
    Injects network, storage, chipset and USB controller drivers into a WinPE image.
.DESCRIPTION
    Mounts the boot image, filters the driver library to the classes PE actually
    needs, injects, commits and optionally exports. Audio and graphics stay out --
    a boot image has to fit in RAM and travel over TFTP.

    USB is in the class list deliberately: newer platforms need the xHCI host
    controller driver in PE or the keyboard is dead at the PE prompt.
.PARAMETER Index
    On Microsoft media boot.wim, index 1 is the base WinPE and index 2 is Windows
    Setup -- index 2 is the one WDS boots. A copype-built custom PE is index 1.
    The function prints the index table before it mounts anything.
#>
    [CmdletBinding()]
    param(
        [string]   $BootImagePath,
        [int]      $Index = 1,
        [string]   $DriverRoot,
        [string[]] $Models,
        [string[]] $ClassFilter,
        [switch]   $ForceUnsigned,
        [string]   $ExportPath,
        [switch]   $WorkingCopy
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $BootImagePath) { $BootImagePath = $cfg['PeImage'] }
    if (-not $ClassFilter)   { $ClassFilter   = $cfg['BootDriverClasses'] }

    $BootImagePath = Assert-WfPath -Path $BootImagePath -Label 'Boot image'

    Write-WfLog "Boot image contents -- confirm the index before servicing" -Level STEP
    foreach ($i in Get-WindowsImage -ImagePath $BootImagePath) {
        Write-WfLog ("  index {0}: {1}" -f $i.ImageIndex, $i.ImageName) -Level INFO
    }
    Write-WfLog "Servicing index $Index" -Level WARN

    $mountInfo = Mount-WfImage -ImagePath $BootImagePath -Index $Index -WorkingCopy:$WorkingCopy
    $working   = $mountInfo.ImagePath

    $result = $null
    try {
        $result = Add-WfDriver -DriverRoot $DriverRoot -Models $Models `
                                -ClassFilter $ClassFilter -ForceUnsigned:$ForceUnsigned
        Dismount-WfImage
    }
    catch {
        Write-WfLog "Boot image servicing failed -- discarding the mount." -Level ERROR
        try { Dismount-WfImage -Discard } catch {
            Write-WfLog 'Discard also failed. Run Repair-WfMount.' -Level ERROR
        }
        throw
    }

    $final = $working
    if ($ExportPath) {
        $export = Export-WfImage -SourcePath $working -DestinationPath $ExportPath -Index $Index -Force
        $final  = $export.Destination
        if ($WorkingCopy) { Remove-Item -LiteralPath $working -Force -ErrorAction SilentlyContinue }
    }

    Write-WfHistory -Action 'Boot image serviced' -ImagePath $final -Detail @{
        Index        = $Index
        ClassFilter  = ($ClassFilter -join ',')
        DriversAdded = $result.Added
        DriversFailed= $result.Failed
        Models       = ($result.Models -join ', ')
    } | Out-Null

    return [pscustomobject]@{
        BootImage    = $final
        Index        = $Index
        DriversAdded = $result.Added
        DriversFailed= $result.Failed
        Selected     = $result.Selected
        Candidates   = $result.Candidate
    }
}

function Publish-WfImage {
<#
.SYNOPSIS
    Copies a finished image to the WDS share with hash verification and retention.
.DESCRIPTION
    Copy, verify by SHA256, write a sidecar .json describing the build, then prune
    older published copies down to the configured retention count. The sidecar is
    what makes a published WIM self-describing -- anyone can see what is in it
    without mounting it.
.PARAMETER BootImage
    Publish to the WDS boot share instead of the install image share.
.PARAMETER SkipHashCheck
    Skip the post-copy SHA256 verification. Faster over a slow link, but you lose
    the guarantee that what landed on the share is what left the workstation.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [string] $Destination,
        [switch] $BootImage,
        [switch] $SkipHashCheck,
        [string] $Notes
    )

    $cfg       = Get-WfConfig
    $ImagePath = Assert-WfPath -Path $ImagePath -Label 'Image'

    if (-not $Destination) {
        if ($BootImage) { $Destination = $cfg['WdsBootShare'] } else { $Destination = $cfg['WdsShare'] }
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Publish target not reachable: $Destination"
    }

    $leaf   = Split-Path $ImagePath -Leaf
    $target = Join-WfPath $Destination $leaf

    if (-not $PSCmdlet.ShouldProcess($target, 'Publish image')) { return }

    Write-WfLog "Hashing source $leaf" -Level STEP
    $sourceHash = (Get-FileHash -LiteralPath $ImagePath -Algorithm SHA256).Hash

    Write-WfLog "Copying to $Destination" -Level STEP
    Copy-Item -LiteralPath $ImagePath -Destination $target -Force

    if (-not $SkipHashCheck) {
        Write-WfLog 'Verifying copy' -Level STEP
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($targetHash -ne $sourceHash) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            throw "Hash mismatch after copy -- the published file was removed. Source $sourceHash, target $targetHash"
        }
        Write-WfLog 'Hash verified' -Level OK
    }

    # Sidecar so the published file describes itself
    $indexes = @(Get-WindowsImage -ImagePath $ImagePath | Select-Object ImageIndex, ImageName)
    $sidecar = [ordered]@{
        File          = $leaf
        Sha256        = $sourceHash
        SizeBytes     = (Get-Item -LiteralPath $ImagePath).Length
        Indexes       = $indexes
        PublishedUtc  = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        PublishedBy   = "$env:USERDOMAIN\$env:USERNAME"
        Workstation   = $env:COMPUTERNAME
        Notes         = $Notes
    }
    ([pscustomobject]$sidecar | ConvertTo-Json -Depth 5) |
        Set-Content -LiteralPath ([IO.Path]::ChangeExtension($target, 'json')) -Encoding UTF8

    # Retention: keep the newest N, remove the rest along with their sidecars
    $keep = $cfg['KeepPublishedVersions']
    if ($keep -and $keep -gt 0) {
        $prefix   = $cfg['ImageNamePrefix']
        $existing = @(Get-ChildItem -LiteralPath $Destination -Filter "$prefix*.wim" -File |
                      Sort-Object LastWriteTime -Descending)
        if ($existing.Count -gt $keep) {
            foreach ($old in $existing | Select-Object -Skip $keep) {
                Write-WfLog "Retention: removing $($old.Name)" -Level WARN
                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
                $oldJson = [IO.Path]::ChangeExtension($old.FullName, 'json')
                if (Test-Path -LiteralPath $oldJson) { Remove-Item -LiteralPath $oldJson -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Write-WfLog "Published $leaf to $Destination" -Level OK

    Write-WfHistory -Action 'Published' -ImagePath $target -Detail @{
        Sha256 = $sourceHash; Destination = $Destination; BootImage = [bool]$BootImage
    } -Notes $Notes | Out-Null

    # WDS itself still needs to be told about a new or replaced image. Doing it
    # here would need the WDS module and admin rights on the server, which is a
    # different permission story -- so this is a reminder rather than an action.
    if ($BootImage) {
        Write-WfLog 'Reminder: replace (do not add alongside) the boot image in the WDS console, then confirm your TFTP server is serving the new file.' -Level WARN
    }
    else {
        Write-WfLog 'Reminder: refresh the install image in the WDS console so the new WIM is offered.' -Level WARN
    }

    return [pscustomobject]$sidecar
}
