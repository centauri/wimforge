# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    BuildOps.ps1 -- capturing a new base image, building USB deployment media,
    and validating a machine after it has been imaged.
#>

function New-WfCapture {
<#
.SYNOPSIS
    Captures a sysprepped reference build into a new base WIM.
.DESCRIPTION
    Two ways in.

    -VhdxPath is the good one: sysprep the audit-mode VM with /generalize /shutdown,
    leave it powered off, then point this at its VHDX. The disk is mounted
    read-only on the build workstation via Mount-DiskImage -- no Hyper-V role
    needed, no booting a WinPE stick, and the VM is never modified. This is what
    makes rebuilding the base a ten-minute job rather than an afternoon.

    -SourceDrive captures from a drive letter instead, for when you really are
    sitting in WinPE in front of a physical reference machine.

    Either way, verify the source was generalized: capturing a machine that was
    not sysprepped gives you an image that deploys with the reference machine's
    SID and computer name, which is the duplicate-hostname incident waiting to
    happen.
.EXAMPLE
    New-WfCapture -VhdxPath 'D:\VMs\LTSC-Reference\Virtual Hard Disks\ref.vhdx' `
        -Name 'Windows 10 LTSC Base' -Notes 'Rebuild 2026-08'
#>
    [CmdletBinding(DefaultParameterSetName = 'Vhdx')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Vhdx')]  [string] $VhdxPath,
        [Parameter(Mandatory, ParameterSetName = 'Drive')] [string] $SourceDrive,

        [string] $DestinationPath,
        [string] $Name        = 'Windows 10 LTSC Base',
        [string] $Description,
        [switch] $SkipGeneralizeCheck,
        [string] $Notes
    )

    Assert-WfElevated
    $cfg = Get-WfConfig

    if (-not $DestinationPath) {
        $DestinationPath = Join-WfPath $cfg['ImageRoot'] ('{0}-Base-{1}.wim' -f $cfg['ImageNamePrefix'], (Get-Date -Format 'yyyy-MM-dd'))
    }
    if (-not $Description) {
        $Description = 'Captured {0} by {1}\{2}' -f (Get-Date -Format 'yyyy-MM-dd'), $env:USERDOMAIN, $env:USERNAME
    }
    New-WfDirectory (Split-Path $DestinationPath -Parent) | Out-Null

    if (Test-Path -LiteralPath $DestinationPath) {
        throw "Destination already exists: $DestinationPath"
    }

    $diskImage  = $null
    $captureDir = $null

    try {
        if ($PSCmdlet.ParameterSetName -eq 'Vhdx') {
            $VhdxPath = Assert-WfPath -Path $VhdxPath -Label 'VHDX'

            Write-WfLog "Mounting $(Split-Path $VhdxPath -Leaf) read-only" -Level STEP
            $diskImage = Mount-DiskImage -ImagePath $VhdxPath -Access ReadOnly -PassThru -ErrorAction Stop

            # Give the volume arrival a moment; freshly attached VHDX volumes are
            # not always enumerable on the very next call.
            Start-Sleep -Seconds 2

            $letters = @(Get-DiskImage -ImagePath $VhdxPath |
                         Get-Disk | Get-Partition |
                         Where-Object { $_.DriveLetter } |
                         Select-Object -ExpandProperty DriveLetter)

            foreach ($l in $letters) {
                if (Test-Path -LiteralPath "${l}:\Windows\System32\config\SOFTWARE") {
                    $captureDir = "${l}:\"
                    break
                }
            }
            if (-not $captureDir) {
                throw "No Windows volume found in $VhdxPath (checked drive letters: $($letters -join ', '))"
            }
            Write-WfLog "Windows volume: $captureDir" -Level OK
        }
        else {
            $captureDir = $SourceDrive
            if ($captureDir -notmatch '\\$') { $captureDir = "$captureDir\" }
            if (-not (Test-Path -LiteralPath (Join-WfPath $captureDir 'Windows\System32\config\SOFTWARE'))) {
                throw "$captureDir does not look like a Windows volume."
            }
        }

        # Generalize check. Sysprep leaves state behind in the Panther folder and
        # in the SYSTEM hive; the cheap reliable signal is the sysprep succeeded
        # tag plus the absence of a live unattend in Panther.
        if (-not $SkipGeneralizeCheck) {
            $tag = Join-WfPath $captureDir 'Windows\System32\Sysprep\Sysprep_succeeded.tag'
            if (Test-Path -LiteralPath $tag) {
                $when = (Get-Item -LiteralPath $tag).LastWriteTime
                Write-WfLog "Sysprep tag found, last run $when" -Level OK
            }
            else {
                throw 'No Sysprep_succeeded.tag on the source volume -- this build was probably not generalized. Re-run sysprep /generalize /oobe /shutdown, or pass -SkipGeneralizeCheck if you are certain.'
            }
        }

        Write-WfLog "Capturing to $DestinationPath (this takes a while)" -Level STEP
        New-WindowsImage -CapturePath $captureDir -ImagePath $DestinationPath `
            -Name $Name -Description $Description -CompressionType Max -Verify -ErrorAction Stop | Out-Null

        $size = (Get-Item -LiteralPath $DestinationPath).Length
        Write-WfLog ("Captured {0}" -f (Format-WfSize $size)) -Level OK

        Write-WfHistory -Action 'Base image captured' -ImagePath $DestinationPath -Detail @{
            Source = $captureDir; SizeBytes = $size; ImageName = $Name
        } -Notes $Notes | Out-Null

        return [pscustomobject]@{
            ImagePath = $DestinationPath
            Source    = $captureDir
            SizeBytes = $size
            Name      = $Name
        }
    }
    finally {
        if ($diskImage) {
            Write-WfLog 'Dismounting the reference VHDX' -Level INFO
            Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function New-WfUsbMedia {
<#
.SYNOPSIS
    Builds a bootable USB deployment stick for sites with no WDS to PXE from.
.DESCRIPTION
    Wipes the target disk and lays down two partitions:

      1. FAT32, 1 GB, active  -- the WinPE media (UEFI firmware can only read FAT32)
      2. NTFS, the remainder  -- the images (a WIM over 4 GB cannot live on FAT32)

    That split is the whole reason this is not a straight copy: UEFI needs FAT32,
    and your image is bigger than FAT32's file size limit.

    -PeMediaPath must point at a WinPE media folder produced by copype, i.e. the
    folder containing Media\ with bootmgr and the Boot\ tree.

    This is destructive and refuses to touch anything that is not a removable USB
    disk, so it cannot eat the workstation's data drive by a mistyped number.
.EXAMPLE
    Get-Disk | Where-Object BusType -eq 'USB'
    New-WfUsbMedia -DiskNumber 3 -PeMediaPath C:\WinPE_amd64 -ImagePath D:\Imaging\Images\REFERENCE-2026-08.wim
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [int]    $DiskNumber,
        [Parameter(Mandatory)] [string] $PeMediaPath,
        [string]   $ImagePath,
        [string[]] $ExtraContent,
        [string]   $VolumeLabel = 'DEPLOY',
        [switch]   $Force
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $ImagePath) { $ImagePath = $cfg['BaseImage'] }

    $PeMediaPath = Assert-WfPath -Path $PeMediaPath -Label 'WinPE media path'
    $ImagePath   = Assert-WfPath -Path $ImagePath   -Label 'Image'

    # copype produces <root>\media; accept either the root or the media folder.
    $mediaSource = $PeMediaPath
    if (Test-Path -LiteralPath (Join-WfPath $PeMediaPath 'media\bootmgr')) {
        $mediaSource = Join-WfPath $PeMediaPath 'media'
    }
    if (-not (Test-Path -LiteralPath (Join-WfPath $mediaSource 'bootmgr'))) {
        throw "No bootmgr under $mediaSource -- that is not a WinPE media folder. Build one with copype amd64 C:\WinPE_amd64."
    }

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop

    if ($disk.BusType -ne 'USB' -and -not $Force) {
        throw "Disk $DiskNumber is $($disk.BusType), not USB. Refusing. Use -Force only if you are certain."
    }
    if ($disk.IsBoot -or $disk.IsSystem) {
        throw "Disk $DiskNumber is the boot/system disk. Refusing outright."
    }

    $sizeGb = [math]::Round($disk.Size / 1GB, 1)
    $target = "Disk $DiskNumber : $($disk.FriendlyName), $sizeGb GB, $($disk.BusType)"

    if (-not $PSCmdlet.ShouldProcess($target, 'ERASE and rebuild as deployment media')) { return }

    Write-WfLog "Erasing $target" -Level STEP
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop

    # New-Partition -IsActive is MBR-only. If Clear-Disk left the disk still
    # initialized as GPT, Initialize-Disk fails -- swallowing that just moves the
    # error to New-Partition, which points at the wrong thing.
    $style = (Get-Disk -Number $DiskNumber).PartitionStyle
    if ($style -eq 'RAW') {
        Initialize-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop
    }
    elseif ($style -ne 'MBR') {
        Write-WfLog "Disk is $style; converting to MBR" -Level WARN
        Set-Disk -Number $DiskNumber -PartitionStyle MBR -ErrorAction Stop
    }

    Write-WfLog 'Creating FAT32 boot partition (1 GB)' -Level STEP
    $bootPart = New-Partition -DiskNumber $DiskNumber -Size 1GB -AssignDriveLetter -IsActive
    Format-Volume -Partition $bootPart -FileSystem FAT32 -NewFileSystemLabel 'PE' -Confirm:$false | Out-Null

    Write-WfLog 'Creating NTFS data partition' -Level STEP
    $dataPart = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $dataPart -FileSystem NTFS -NewFileSystemLabel $VolumeLabel -Confirm:$false | Out-Null

    # Re-query. The objects New-Partition returned were captured before the mount
    # manager finished assigning letters, so reading DriveLetter off them yields
    # an empty value often enough to matter -- and by then the disk is erased.
    Start-Sleep -Seconds 2
    $bootPart = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $bootPart.PartitionNumber
    $dataPart = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $dataPart.PartitionNumber

    if (-not $bootPart.DriveLetter -or -not $dataPart.DriveLetter) {
        throw "Windows did not assign drive letters to the new partitions on disk $DiskNumber. Assign them in Disk Management and re-run, or check for a policy blocking automount."
    }

    $bootDrive = "$($bootPart.DriveLetter):"
    $dataDrive = "$($dataPart.DriveLetter):"

    Write-WfLog "Copying WinPE media to $bootDrive" -Level STEP
    Copy-Item -Path (Join-WfPath $mediaSource '*') -Destination "$bootDrive\" -Recurse -Force

    Write-WfLog "Copying image to $dataDrive\Images" -Level STEP
    New-WfDirectory "$dataDrive\Images" | Out-Null
    Copy-Item -LiteralPath $ImagePath -Destination "$dataDrive\Images\" -Force

    # Sidecar travels with the image so the engineer on site can see what it is
    $sidecarSource = [IO.Path]::ChangeExtension($ImagePath, 'json')
    if (Test-Path -LiteralPath $sidecarSource) {
        Copy-Item -LiteralPath $sidecarSource -Destination "$dataDrive\Images\" -Force
    }

    foreach ($extra in @($ExtraContent)) {
        if (-not $extra) { continue }
        Write-WfLog "Copying extra content: $extra" -Level INFO
        Copy-Item -Path $extra -Destination "$dataDrive\" -Recurse -Force
    }

    # Drop a readme so whoever picks the stick up knows what it is and how old
    $readme = @"
WimForge deployment media
Built    : $(Get-Date -Format 'yyyy-MM-dd HH:mm') by $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME
Image    : $(Split-Path $ImagePath -Leaf)
PE source: $mediaSource

Boot this stick, then apply the image from $dataDrive\Images with your
deployment script. The images partition is NTFS because the WIM is larger than
FAT32 allows; the boot partition must stay FAT32 for UEFI firmware to read it.
"@
    $readme | Set-Content -LiteralPath "$dataDrive\README.txt" -Encoding UTF8

    Write-WfLog "USB media ready: boot=$bootDrive images=$dataDrive" -Level OK

    Write-WfHistory -Action 'USB media built' -ImagePath $ImagePath -Detail @{
        DiskNumber = $DiskNumber; Disk = $disk.FriendlyName; BootDrive = $bootDrive; DataDrive = $dataDrive
    } | Out-Null

    return [pscustomobject]@{
        DiskNumber = $DiskNumber
        BootDrive  = $bootDrive
        DataDrive  = $dataDrive
        Image      = Split-Path $ImagePath -Leaf
    }
}

function Test-WfDeployedMachine {
<#
.SYNOPSIS
    Post-deployment validation of a freshly imaged target machine.
.DESCRIPTION
    Run this on the machine after first boot. It checks the things that actually
    go wrong: unhealthy devices, drivers that fell back to a generic Microsoft
    package, activation, domain trust, hostname, disk space, pending reboots and
    time sync.

    Returns one row per check with PASS / WARN / FAIL, and can write a report file
    to attach to the hardware validation document for the model.
.PARAMETER ReportPath
    Write the result to this path as well. .csv, .json or .txt by extension.
.PARAMETER ExpectedHostnamePattern
    Regex the computer name must match, so an un-renamed machine still carrying
    the image's name is caught here rather than in production.
#>
    [CmdletBinding()]
    param(
        [string] $ReportPath,
        [string] $ExpectedHostnamePattern,
        [string] $ExpectedDomain
    )

    $results = New-Object System.Collections.Generic.List[object]
    function Add-Check {
        param([string] $Area, [string] $Check, [string] $Status, [string] $Detail)
        $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail })
    }

    $cs   = Get-CimInstance Win32_ComputerSystem
    $os   = Get-CimInstance Win32_OperatingSystem
    $bios = Get-CimInstance Win32_BIOS

    # --- identity -----------------------------------------------------------
    Add-Check 'Identity' 'Model' 'INFO' ("{0} {1} (SKU {2}, BIOS {3})" -f $cs.Manufacturer, $cs.Model, $cs.SystemSKUNumber, $bios.SMBIOSBIOSVersion)

    $ubr = Get-WfLocalUbr
    $build = $os.Version
    if ($ubr) { $build = "$($os.Version).$ubr" }
    Add-Check 'Identity' 'OS build' 'INFO' "$($os.Caption) $build"

    if ($ExpectedHostnamePattern) {
        if ($env:COMPUTERNAME -match $ExpectedHostnamePattern) {
            Add-Check 'Identity' 'Hostname' 'PASS' $env:COMPUTERNAME
        }
        else {
            Add-Check 'Identity' 'Hostname' 'FAIL' "$env:COMPUTERNAME does not match /$ExpectedHostnamePattern/ -- the rename automation may not have run."
        }
    }
    else {
        Add-Check 'Identity' 'Hostname' 'INFO' $env:COMPUTERNAME
    }

    # --- devices ------------------------------------------------------------
    $bad = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
             Where-Object { $_.Status -ne 'OK' -and $_.Status -ne 'Unknown' })
    if ($bad.Count -eq 0) {
        Add-Check 'Devices' 'Device health' 'PASS' 'No devices in an error state'
    }
    else {
        foreach ($d in $bad) {
            Add-Check 'Devices' 'Device health' 'FAIL' ("{0} [{1}] {2} -- {3}" -f $d.FriendlyName, $d.Class, $d.Status, $d.InstanceId)
        }
    }

    # Devices running a Microsoft generic driver where a vendor one was expected.
    # This is the quiet failure of an all-in-one image: it works, but badly.
    try {
        $generic = @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.Class -in 'Net','Display','System','SCSIAdapter','HDC' } |
            ForEach-Object {
                $p = Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction SilentlyContinue
                if ($p -and $p.Data -eq 'Microsoft') {
                    [pscustomobject]@{ Name = $_.FriendlyName; Class = $_.Class }
                }
            })
        if ($generic.Count -eq 0) {
            Add-Check 'Devices' 'Vendor drivers' 'PASS' 'No core devices fell back to a Microsoft generic driver'
        }
        else {
            foreach ($g in $generic) {
                Add-Check 'Devices' 'Vendor drivers' 'WARN' ("{0} [{1}] is on a Microsoft generic driver -- vendor package may be missing from the library" -f $g.Name, $g.Class)
            }
        }
    }
    catch {
        Add-Check 'Devices' 'Vendor drivers' 'WARN' "Could not evaluate: $($_.Exception.Message)"
    }

    # --- licensing ----------------------------------------------------------
    try {
        $lic = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop |
               Where-Object { $_.PartialProductKey -and $_.Name -like 'Windows*' } |
               Select-Object -First 1
        if ($lic) {
            $statusText = switch ($lic.LicenseStatus) {
                0 { 'Unlicensed' }; 1 { 'Licensed' }; 2 { 'OOB grace' }; 3 { 'OOT grace' }
                4 { 'Non-genuine grace' }; 5 { 'Notification' }; 6 { 'Extended grace' }
                default { "Unknown ($($lic.LicenseStatus))" }
            }
            $s = 'FAIL'
            if ($lic.LicenseStatus -eq 1) { $s = 'PASS' }
            elseif ($lic.LicenseStatus -in 2,3,6) { $s = 'WARN' }
            Add-Check 'Licensing' 'Activation' $s "$statusText -- $($lic.Name)"
        }
        else {
            Add-Check 'Licensing' 'Activation' 'WARN' 'No licensed Windows SKU reported'
        }
    }
    catch {
        Add-Check 'Licensing' 'Activation' 'WARN' "Could not query: $($_.Exception.Message)"
    }

    # --- domain -------------------------------------------------------------
    if ($cs.PartOfDomain) {
        Add-Check 'Domain' 'Membership' 'PASS' $cs.Domain
        if ($ExpectedDomain -and $cs.Domain -ne $ExpectedDomain) {
            Add-Check 'Domain' 'Expected domain' 'FAIL' "Joined to $($cs.Domain), expected $ExpectedDomain"
        }
        try {
            $trust = Test-ComputerSecureChannel -ErrorAction Stop
            $s = 'FAIL'
            if ($trust) { $s = 'PASS' }
            $detail = 'Secure channel broken -- check for a duplicate computer object'
            if ($trust) { $detail = 'Secure channel healthy' }
            Add-Check 'Domain' 'Trust relationship' $s $detail
        }
        catch {
            Add-Check 'Domain' 'Trust relationship' 'WARN' "Could not test: $($_.Exception.Message)"
        }
    }
    else {
        Add-Check 'Domain' 'Membership' 'WARN' 'Workgroup -- not domain joined'
    }

    # --- housekeeping -------------------------------------------------------
    $sysDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($sysDrive) {
        $freeGb = [math]::Round($sysDrive.Free / 1GB, 1)
        $s = 'PASS'
        if ($freeGb -lt 10) { $s = 'FAIL' } elseif ($freeGb -lt 20) { $s = 'WARN' }
        Add-Check 'System' 'Free space' $s "$freeGb GB free on $env:SystemDrive"
    }

    $pendingKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    $pending = @($pendingKeys | Where-Object { Test-Path -LiteralPath $_ })
    if ($pending.Count -eq 0) {
        Add-Check 'System' 'Pending reboot' 'PASS' 'None'
    }
    else {
        Add-Check 'System' 'Pending reboot' 'WARN' "Reboot pending ($($pending.Count) indicator(s))"
    }

    try {
        $w32 = w32tm /query /status 2>&1 | Out-String
        if ($w32 -match 'Source:\s*(.+)') {
            Add-Check 'System' 'Time source' 'PASS' $Matches[1].Trim()
        }
        else {
            Add-Check 'System' 'Time source' 'WARN' 'Time service did not report a source'
        }
    }
    catch {
        Add-Check 'System' 'Time source' 'WARN' 'Could not query w32tm'
    }

    # --- summary ------------------------------------------------------------
    $fail = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warn = @($results | Where-Object { $_.Status -eq 'WARN' }).Count

    foreach ($r in $results) {
        $level = 'INFO'
        if ($r.Status -eq 'FAIL') { $level = 'ERROR' }
        elseif ($r.Status -eq 'WARN') { $level = 'WARN' }
        elseif ($r.Status -eq 'PASS') { $level = 'OK' }
        Write-WfLog ("[{0}] {1} / {2}: {3}" -f $r.Status, $r.Area, $r.Check, $r.Detail) -Level $level
    }

    $verdict = 'PASS'
    if ($fail -gt 0) { $verdict = 'FAIL' } elseif ($warn -gt 0) { $verdict = 'PASS WITH WARNINGS' }
    Write-WfLog "Validation verdict: $verdict ($fail failures, $warn warnings)" -Level STEP

    if ($ReportPath) {
        New-WfDirectory (Split-Path $ReportPath -Parent) | Out-Null
        switch ([IO.Path]::GetExtension($ReportPath).ToLower()) {
            '.csv'  { $results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8 }
            '.json' { ($results | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $ReportPath -Encoding UTF8 }
            default {
                $header = @(
                    "POS deployment validation"
                    "Machine : $env:COMPUTERNAME"
                    "Model   : $($cs.Manufacturer) $($cs.Model)"
                    "Date    : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
                    "Verdict : $verdict"
                    ''
                ) -join [Environment]::NewLine
                $body = $results | Format-Table -AutoSize | Out-String
                ($header + $body) | Set-Content -LiteralPath $ReportPath -Encoding UTF8
            }
        }
        Write-WfLog "Report written to $ReportPath" -Level OK
    }

    return $results
}
