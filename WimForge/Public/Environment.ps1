# WimForge -- https://github.com/centauri/wimforge
# Copyright (c) 2026 Paul Admiraal. Released under the MIT licence; see LICENSE.

<#
    Environment.ps1 -- elevation and image discovery.

    A running process cannot give itself administrator rights; Windows only grants
    them at process creation. So "elevate from the menu" necessarily means
    relaunching the front-end through the UAC shell verb and letting the current
    one exit. Everything here is built around that fact rather than pretending
    otherwise.
#>

function Test-WfElevated {
<#
.SYNOPSIS
    True when the current process is running with administrator rights.
.DESCRIPTION
    Cheap and side-effect free, so it can be called freely. Assert-WfElevated is
    the version that throws; this one is for deciding what to offer.

    Both front-ends use it to grey out what cannot work rather than let it fail:
    every DISM mount needs administrator rights, and finding that out after a
    file dialog is worse than not being offered the button.
.EXAMPLE
    if (-not (Test-WfElevated)) { Write-WfLog 'Reads will be limited.' -Level WARN }
#>
    [CmdletBinding()]
    param()
    $id        = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-WfElevated {
<#
.SYNOPSIS
    Relaunches a script elevated through UAC.
.DESCRIPTION
    Starts a new PowerShell process with the RunAs verb, passing the same script
    and arguments. Returns $true if the elevated process actually started, $false
    if the user dismissed the UAC prompt -- the caller decides whether to exit.

    Deliberately relaunches the SAME host executable the caller is running under,
    so a 5.1 session stays 5.1. Launching pwsh.exe here would quietly move image
    servicing onto the DISM compatibility shim.
.PARAMETER ScriptPath
    The script to relaunch. Defaults to the caller's own script.
.PARAMETER Arguments
    Extra arguments appended after the script path, e.g. -ConfigPath D:\x.json.
.PARAMETER WorkingDirectory
    Defaults to the script's folder.
.EXAMPLE
    if (-not (Test-WfElevated)) {
        if (Start-WfElevated -ScriptPath $PSCommandPath) { exit }
    }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $ScriptPath,
        [string[]] $Arguments = @(),
        [string]   $WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Cannot relaunch: script not found at $ScriptPath"
    }

    # Which host to relaunch. Prefer the one we are running under so a 5.1
    # session stays 5.1 -- but only if it is actually a PowerShell console.
    # Under the ISE, (Get-Process).Path is powershell_ise.exe, and passing
    # -File to that opens an elevated *editor* instead of running the tool.
    $hostExe = $null
    try   { $hostExe = (Get-Process -Id $PID).Path } catch { }

    $hostLeaf = ''
    if ($hostExe) { $hostLeaf = (Split-Path $hostExe -Leaf).ToLower() }

    if ($hostLeaf -notin 'powershell.exe', 'pwsh.exe') {
        # Not a plain console host. Fall back to Windows PowerShell explicitly --
        # $PSHOME would give pwsh.exe under 7, which is the edition we are trying
        # to keep image servicing away from.
        $hostExe = Join-WfPath $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path $ScriptPath -Parent }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"") + $Arguments

    Write-WfLog "Relaunching elevated: $hostExe -File `"$ScriptPath`" $($Arguments -join ' ')" -Level STEP

    # ShellExecute is driven directly rather than through Start-Process.
    # Start-Process rewraps the underlying Win32Exception in a fresh
    # InvalidOperationException with no inner exception, so `catch
    # [Win32Exception]` never fires and a cancelled UAC prompt is indistinguishable
    # from a real failure. Matching on the message text is not an option either --
    # it is localised, and the message text is localised.
    $psi                   = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName          = $hostExe
    $psi.Arguments         = ($argList -join ' ')
    $psi.Verb              = 'runas'
    $psi.UseShellExecute   = $true
    $psi.WorkingDirectory  = $WorkingDirectory

    try {
        [void][System.Diagnostics.Process]::Start($psi)
        Write-WfLog 'Elevated process started. This one can now close.' -Level OK
        return $true
    }
    catch [System.ComponentModel.Win32Exception] {
        # 1223 = ERROR_CANCELLED: the user dismissed the UAC prompt. A decision,
        # not a fault.
        if ($_.Exception.NativeErrorCode -eq 1223) {
            Write-WfLog 'UAC prompt was cancelled -- still running without administrator rights.' -Level WARN
            return $false
        }
        Write-WfLog "Could not relaunch elevated: $($_.Exception.Message)" -Level ERROR
        return $false
    }
    catch {
        Write-WfLog "Could not relaunch elevated: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Get-WfImageInventory {
<#
.SYNOPSIS
    Lists the .wim files in a folder with size, age and what is inside them.
.DESCRIPTION
    Backs the image pickers in both front-ends. Reading the index table costs a
    metadata read per file, which is fast -- but on a slow share with many images
    it is noticeable, so -NoIndexes skips it.

    Any sidecar .json written by Publish-WfImage is picked up too, so a published
    image shows the notes it was published with.
.PARAMETER Path
    Folder to scan. Defaults to the configured ImageRoot.
.PARAMETER IncludePeImage
    Also include the configured PE image even when it lives outside Path.
.EXAMPLE
    Get-WfImageInventory | Format-Table Name, SizeGB, Modified, Indexes, ImageNames
#>
    [CmdletBinding()]
    param(
        [string] $Path,
        [switch] $Recurse,
        [switch] $NoIndexes,
        [switch] $IncludePeImage
    )

    $cfg = Get-WfConfig
    if (-not $Path) { $Path = $cfg['ImageRoot'] }

    $files = @()
    if (Test-Path -LiteralPath $Path) {
        $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.wim' -File -Recurse:$Recurse)
    }
    else {
        Write-WfLog "Image folder not found: $Path" -Level WARN
    }

    if ($IncludePeImage -and $cfg['PeImage'] -and (Test-Path -LiteralPath $cfg['PeImage'])) {
        $pe = Get-Item -LiteralPath $cfg['PeImage']
        if ($files.FullName -notcontains $pe.FullName) { $files += $pe }
    }

    $out = New-Object System.Collections.Generic.List[object]

    foreach ($f in $files) {
        $indexes    = $null
        $imageNames = ''

        if (-not $NoIndexes) {
            try {
                $info       = @(Get-WindowsImage -ImagePath $f.FullName -ErrorAction Stop)
                $indexes    = $info.Count
                $imageNames = ($info | ForEach-Object { '{0}:{1}' -f $_.ImageIndex, $_.ImageName }) -join ' | '
            }
            catch {
                $imageNames = "unreadable ($($_.Exception.Message.Split([Environment]::NewLine)[0]))"
            }
        }

        $notes = ''
        $sidecar = [IO.Path]::ChangeExtension($f.FullName, 'json')
        if (Test-Path -LiteralPath $sidecar) {
            try { $notes = (Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json).Notes } catch { }
        }

        $out.Add([pscustomobject]@{
            Name       = $f.Name
            SizeGB     = [math]::Round($f.Length / 1GB, 2)
            Modified   = $f.LastWriteTime
            AgeDays    = [math]::Round(((Get-Date) - $f.LastWriteTime).TotalDays)
            Indexes    = $indexes
            ImageNames = $imageNames
            Notes      = $notes
            Path       = $f.FullName
        })
    }

    return $out | Sort-Object Modified -Descending
}
