# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Customise.ps1 -- offline changes to a mounted image: registry, payload files,
    certificates, unattend.xml and Features on Demand.

    Everything here assumes the image is already mounted read/write at the
    configured mount path.
#>

function Invoke-WfRegistryEdit {
<#
.SYNOPSIS
    Applies .reg files or a scriptblock to a mounted image's registry hives.
.DESCRIPTION
    Loads the offline SOFTWARE, SYSTEM and DEFAULT hives under temporary keys,
    applies the changes, then unloads cleanly.

    The unload is the part that bites: the PowerShell registry provider keeps
    handles open, so without forcing a garbage collection first the unload fails
    with Access Denied -- and a hive still loaded from a mount makes the later
    dismount fail too, which looks like a completely unrelated problem.

    In a .reg file, target the temporary keys directly:
        [HKEY_LOCAL_MACHINE\WF_SOFTWARE\Microsoft\Windows\CurrentVersion\...]
        [HKEY_LOCAL_MACHINE\WF_SYSTEM\ControlSet001\Services\...]
        [HKEY_LOCAL_MACHINE\WF_DEFAULT\Software\...]      (the default user profile)
.PARAMETER RegFile
    One or more .reg files to import, in order.
.PARAMETER Action
    Scriptblock run while the hives are loaded. Receives a hashtable of the mounted
    key paths, e.g. $keys.Software -> 'HKLM:\WF_SOFTWARE'.
.EXAMPLE
    Invoke-WfRegistryEdit -RegFile D:\Imaging\Payload\pos-policy.reg
.EXAMPLE
    Invoke-WfRegistryEdit -Action {
        param($keys)
        Set-ItemProperty "$($keys.Software)\Microsoft\Windows\CurrentVersion\Policies\System" `
            -Name EnableLUA -Value 1 -Type DWord
    }
#>
    [CmdletBinding()]
    param(
        [string[]]    $RegFile,
        [scriptblock] $Action,
        [string]      $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    if (-not $RegFile -and -not $Action) {
        throw 'Supply -RegFile, -Action, or both.'
    }

    $hives = @(
        @{ Key = 'WF_SOFTWARE'; File = 'Windows\System32\config\SOFTWARE'; Name = 'Software' }
        @{ Key = 'WF_SYSTEM';   File = 'Windows\System32\config\SYSTEM';   Name = 'System'   }
        @{ Key = 'WF_DEFAULT';  File = 'Users\Default\NTUSER.DAT';         Name = 'Default'  }
    )

    $loaded = New-Object System.Collections.Generic.List[string]
    $keys   = @{}

    try {
        foreach ($h in $hives) {
            $hivePath = Join-WfPath $MountPath $h.File
            if (-not (Test-Path -LiteralPath $hivePath)) {
                Write-WfLog "Hive not present, skipping: $($h.File)" -Level WARN
                continue
            }
            & reg.exe load "HKLM\$($h.Key)" $hivePath 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "reg load failed for $($h.File) (exit $LASTEXITCODE). Is the image mounted read/write?"
            }
            $loaded.Add($h.Key)
            $keys[$h.Name] = "HKLM:\$($h.Key)"
            Write-WfLog "Loaded $($h.Name) hive as HKLM\$($h.Key)" -Level INFO
        }

        foreach ($f in @($RegFile)) {
            if (-not $f) { continue }
            $resolved = Assert-WfPath -Path $f -Label 'Reg file'
            Write-WfLog "Importing $(Split-Path $resolved -Leaf)" -Level STEP
            & reg.exe import $resolved 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "reg import failed for $resolved (exit $LASTEXITCODE)"
            }
            Write-WfLog 'Imported' -Level OK
        }

        if ($Action) {
            Write-WfLog 'Running registry action block' -Level STEP
            & $Action $keys
            Write-WfLog 'Action complete' -Level OK
        }
    }
    finally {
        # Drop provider handles before unloading, or the unload fails and takes
        # the dismount down with it.
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        foreach ($key in $loaded) {
            & reg.exe unload "HKLM\$key" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-WfLog "reg unload failed for HKLM\$key -- the dismount will likely fail too." -Level ERROR
            }
            else {
                Write-WfLog "Unloaded HKLM\$key" -Level INFO
            }
        }
    }
}

function Copy-WfPayload {
<#
.SYNOPSIS
    Copies the payload tree into the mounted image.
.DESCRIPTION
    The payload folder mirrors the target drive, so
        <PayloadRoot>\Windows\Setup\Scripts\SetupComplete.cmd
    lands at
        C:\Windows\Setup\Scripts\SetupComplete.cmd
    on the deployed machine. Use it for provisioning scripts, agent installers,
    branding and anything else that must exist before first logon.
#>
    [CmdletBinding()]
    param(
        [string] $PayloadRoot,
        [string] $MountPath,
        [switch] $WhatIfOnly
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $PayloadRoot) { $PayloadRoot = $cfg['PayloadRoot'] }
    if (-not $MountPath)   { $MountPath   = $cfg['MountPath'] }

    if (-not (Test-Path -LiteralPath $PayloadRoot)) {
        Write-WfLog "No payload folder at $PayloadRoot -- skipping" -Level WARN
        return [pscustomobject]@{ FileCount = 0; Files = @() }
    }

    $files = @(Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File)
    Write-WfLog ("Copying {0} payload file(s) from {1}" -f $files.Count, $PayloadRoot) -Level STEP

    $copied = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $relative = $f.FullName.Substring($PayloadRoot.TrimEnd('\').Length).TrimStart('\')
        $dest     = Join-WfPath $MountPath $relative

        if ($WhatIfOnly) {
            Write-WfLog "would copy -> $relative" -Level INFO
            $copied.Add($relative)
            continue
        }

        New-WfDirectory (Split-Path $dest -Parent) | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        $copied.Add($relative)
    }

    Write-WfLog ("{0} file(s) copied" -f $copied.Count) -Level OK
    return [pscustomobject]@{ FileCount = $copied.Count; Files = $copied }
}

function Import-WfCertificate {
<#
.SYNOPSIS
    Adds certificates to a mounted image's machine store.
.DESCRIPTION
    Loads the offline SOFTWARE hive and writes the certificate blob into the
    machine store keys, which is how DISM-era offline certificate injection works
    -- there is no supported DISM verb for it.
.PARAMETER Store
    Root, CA or TrustedPublisher.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $CertificatePath,
        [ValidateSet('Root','CA','TrustedPublisher')] [string] $Store = 'Root',
        [string] $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $storeKeyLeaf = "Microsoft\SystemCertificates\$Store\Certificates"
    $imported     = New-Object System.Collections.Generic.List[object]

    $action = {
        param($keys)
        foreach ($path in $CertificatePath) {
            $resolved = (Resolve-Path -LiteralPath $path).Path
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $resolved
            $thumb = $cert.Thumbprint

            $certKey = Join-WfPath (Join-WfPath $keys.Software $storeKeyLeaf) $thumb
            if (-not (Test-Path -LiteralPath $certKey)) { New-Item -Path $certKey -Force | Out-Null }
            New-ItemProperty -Path $certKey -Name 'Blob' -PropertyType Binary `
                -Value $cert.RawData -Force | Out-Null

            Write-WfLog ("Imported {0} into {1} ({2})" -f $cert.Subject, $Store, $thumb) -Level OK
            $imported.Add([pscustomobject]@{
                Subject = $cert.Subject; Thumbprint = $thumb; NotAfter = $cert.NotAfter; Store = $Store
            })
        }
    }.GetNewClosure()

    Invoke-WfRegistryEdit -Action $action -MountPath $MountPath
    return $imported
}

function Test-WfUnattend {
<#
.SYNOPSIS
    Validates an unattend.xml and flags the settings that break a multi-model image.
.DESCRIPTION
    Checks it is well-formed, then looks for the specific mistakes that cause
    trouble in a shared image: a hard-coded ComputerName, a leftover product key,
    SkipRearm still set for a production build, and a missing generalize pass.
#>
    [CmdletBinding()]
    param([string] $Path)

    $cfg = Get-WfConfig
    if (-not $Path) { $Path = $cfg['UnattendPath'] }
    $Path = Assert-WfPath -Path $Path -Label 'Unattend'

    $findings = New-Object System.Collections.Generic.List[object]
    function Add-Finding {
        param([string] $Severity, [string] $Setting, [string] $Detail)
        $findings.Add([pscustomobject]@{ Severity = $Severity; Setting = $Setting; Detail = $Detail })
    }

    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw
    }
    catch {
        Add-Finding 'ERROR' 'XML' "Not well-formed: $($_.Exception.Message)"
        return $findings
    }

    $text = Get-Content -LiteralPath $Path -Raw

    if ($text -match '<ComputerName>\s*([^<*\s][^<]*)</ComputerName>') {
        Add-Finding 'ERROR' 'ComputerName' "Hard-coded to '$($Matches[1])'. Use * and let the provisioning script rename, or every terminal deploys with the same name."
    }
    else {
        Add-Finding 'OK' 'ComputerName' 'Not hard-coded'
    }

    if ($text -match '<ProductKey>') {
        Add-Finding 'WARN' 'ProductKey' 'A product key is present. Confirm it is the right SKU for IoT Enterprise LTSC -- a mismatch shows up as activation error 0xC004F069.'
    }

    if ($text -match '<SkipRearm>\s*1\s*</SkipRearm>') {
        Add-Finding 'WARN' 'SkipRearm' 'SkipRearm=1 is set. Correct while iterating on the reference VM; remove it for the final sealed build.'
    }

    if ($text -match 'pass="generalize"') {
        Add-Finding 'OK' 'generalize pass' 'Present'
    }
    else {
        Add-Finding 'WARN' 'generalize pass' 'No generalize pass found. Intentional only if you generalize from the command line.'
    }

    if ($text -match '<CopyProfile>\s*true\s*</CopyProfile>') {
        Add-Finding 'OK' 'CopyProfile' 'Enabled -- new users inherit the customised Administrator profile'
    }

    if ($text -match '<DriverPaths>') {
        Add-Finding 'WARN' 'DriverPaths' 'Unattend driver paths are configured. With an all-in-one image the drivers are already in the store; a stale path here just slows specialize down.'
    }

    foreach ($f in $findings) {
        $level = 'INFO'
        if ($f.Severity -eq 'ERROR') { $level = 'ERROR' }
        elseif ($f.Severity -eq 'WARN') { $level = 'WARN' }
        elseif ($f.Severity -eq 'OK') { $level = 'OK' }
        Write-WfLog ("{0}: {1}" -f $f.Setting, $f.Detail) -Level $level
    }

    return $findings
}

function Set-WfUnattend {
<#
.SYNOPSIS
    Places an unattend.xml into a mounted image as the sysprep answer file.
.DESCRIPTION
    Copies it to \Windows\Panther\unattend.xml, which is where Windows looks
    during specialize/oobeSystem on first boot. Validates first and refuses on any
    ERROR-severity finding unless -Force is used.
#>
    [CmdletBinding()]
    param(
        [string] $Path,
        [string] $MountPath,
        [switch] $Force
    )

    Assert-WfElevated
    $cfg = Get-WfConfig
    if (-not $Path)      { $Path      = $cfg['UnattendPath'] }
    if (-not $MountPath) { $MountPath = $cfg['MountPath'] }

    $Path = Assert-WfPath -Path $Path -Label 'Unattend'

    $findings = Test-WfUnattend -Path $Path
    $errors   = @($findings | Where-Object { $_.Severity -eq 'ERROR' })
    if ($errors.Count -gt 0 -and -not $Force) {
        throw "Unattend has $($errors.Count) blocking issue(s). Fix them or re-run with -Force."
    }

    $panther = New-WfDirectory (Join-WfPath $MountPath 'Windows\Panther')
    $dest    = Join-WfPath $panther 'unattend.xml'
    Copy-Item -LiteralPath $Path -Destination $dest -Force

    Write-WfLog "Unattend placed at Windows\Panther\unattend.xml" -Level OK
    return $dest
}

function Add-WfCapability {
<#
.SYNOPSIS
    Enables optional features or Features on Demand in a mounted image.
.DESCRIPTION
    .NET 3.5 is the usual one for POS -- older till and peripheral software still
    needs it, and it cannot be installed offline without the source media, so this
    takes a -Source path pointing at \sources\sxs on the LTSC media.
.PARAMETER Feature
    Optional feature names, e.g. NetFx3.
.PARAMETER Capability
    Capability names for Features on Demand, e.g. Language.Basic~~~nl-NL~0.0.1.0.
#>
    [CmdletBinding()]
    param(
        [string[]] $Feature,
        [string[]] $Capability,
        [string]   $Source,
        [string]   $MountPath
    )

    Assert-WfElevated
    if (-not $MountPath) { $MountPath = (Get-WfConfig)['MountPath'] }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($f in @($Feature)) {
        if (-not $f) { continue }
        Write-WfLog "Enabling feature $f" -Level STEP
        try {
            $params = @{ Path = $MountPath; FeatureName = $f; All = $true }
            if ($Source) {
                $params['Source']    = $Source
                $params['LimitAccess'] = $true
            }
            Enable-WindowsOptionalFeature @params -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ Name = $f; Type = 'Feature'; Status = 'Enabled'; Error = $null })
            Write-WfLog "$f enabled" -Level OK
        }
        catch {
            $msg = $_.Exception.Message.Trim()
            $results.Add([pscustomobject]@{ Name = $f; Type = 'Feature'; Status = 'Failed'; Error = $msg })
            Write-WfLog "$f failed: $msg" -Level ERROR
            if ($f -eq 'NetFx3' -and -not $Source) {
                Write-WfLog 'NetFx3 needs -Source pointing at \sources\sxs on the LTSC media.' -Level WARN
            }
        }
    }

    foreach ($c in @($Capability)) {
        if (-not $c) { continue }
        Write-WfLog "Adding capability $c" -Level STEP
        try {
            $params = @{ Path = $MountPath; Name = $c }
            if ($Source) { $params['Source'] = $Source; $params['LimitAccess'] = $true }
            Add-WindowsCapability @params -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ Name = $c; Type = 'Capability'; Status = 'Added'; Error = $null })
            Write-WfLog "$c added" -Level OK
        }
        catch {
            $msg = $_.Exception.Message.Trim()
            $results.Add([pscustomobject]@{ Name = $c; Type = 'Capability'; Status = 'Failed'; Error = $msg })
            Write-WfLog "$c failed: $msg" -Level ERROR
        }
    }

    return $results
}
