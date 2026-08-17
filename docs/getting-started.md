<!-- WimForge -- https://github.com/centauri/wimforge
     Copyright (c) 2026 Paul Admiraal. MIT licence; see LICENSE. -->

# Getting started

Installing WimForge, setting up the workspace, and the one folder that does not
go where you would expect. For what the toolkit does once it is running, see
[features.md](features.md); for why the build is shaped the way it is, see the
[runbook](../WIM-Build-Runbook.md).

## Requirements

- **Windows PowerShell 5.1**, not PowerShell 7. The DISM module ships in-box and
  with the ADK and runs natively under 5.1; under 7 it loads through the
  WinPSCompatSession shim, which is where long-running mount operations
  intermittently fail. 5.1 is also STA by default, which WinForms requires.
- **Windows ADK** with the Deployment Tools, if you build WinPE media. Start from
  the *Deployment and Imaging Tools Environment* shortcut when you do: it puts
  `copype`, `MakeWinPEMedia`, `oscdimg` and `bcdboot` on `PATH`, which nothing
  else does.

  For servicing alone the ADK is usually unnecessary. The DISM cmdlets come from
  the in-box PowerShell module either way, because that shortcut sets `PATH`, not
  `PSModulePath`, so it cannot change which module is loaded. It only redirects
  `dism.exe`, which this toolkit calls just for `/ResetBase`,
  `/AnalyzeComponentStore` and `/Cleanup-Mountpoints`. Microsoft publishes a
  [compatibility matrix](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-supported-platforms)
  rather than a stated rule, but it comes to the same thing: newer DISM services
  older images, not the other way round. The in-box version is your workstation's
  own Windows version, so servicing a down-level image is fine. You need the ADK
  when the image is *newer* than the machine servicing it, which is the case the
  docs explicitly tell you to install the Deployment Tools for.
- **Administrator rights** for anything that mounts an image.
- **Hyper-V**, only for the reference VM features, and it may be a remote server.

Developed against Windows 10 IoT Enterprise LTSC 2021, but nothing is tied to
that edition.

## Installing and first run

Double-click either launcher in Explorer:

```
WimForge-Menu.cmd            console
WimForge-GUI.cmd             GUI
```

Or from a prompt, if you prefer one:

```powershell
.\Start-WimForgeMenu.ps1     # console
.\Start-WimForgeGui.ps1      # GUI
```

The launchers exist because double-clicking a `.ps1` runs it through whatever is
registered for `.ps1`, and on a machine with PowerShell 7 installed that is
`pwsh` -- where the DISM module runs through a compatibility shim rather than
natively. They call Windows PowerShell 5.1 by full path, ask for elevation up
front so there is one UAC prompt, and hold the window open if something fails at
startup instead of closing on a flash of black. Arguments are passed through, so
`WimForge-Menu.cmd -ConfigPath D:\Other.json` works.

First run walks you through setup: it lists the local fixed drives with their
free space, offers the sensible workspace folders -- the roomiest drive, the
system drive, and next to the toolkit itself -- and creates the folder structure
under whichever you pick. There is no configuration file to edit by hand.

### The mount folder does not follow the workspace

Everything else does: images, drivers, updates, payload, logs and the build
history all move when the workspace moves. The mount folder deliberately stays
put, at a short path on a local disk, and that is worth understanding before
tidying it into the workspace.

A mounted image is not a folder of files. It is a live NTFS projection of a whole
Windows installation -- fifteen-odd GB of it, with hardlinks, reparse points and
ACLs -- held open by a filter driver until it is dismounted. So:

- It needs **NTFS**. A FAT32 or exFAT stick cannot represent a Windows
  installation at all, and a UNC path has no local volume for the filter driver.
- Anything that **walks the folder holds files open**: real-time antivirus, a
  sync client, a search indexer, a backup agent. A file still open at dismount is
  what produces "the directory could not be completely unmounted", and the mount
  is then stale until it is cleaned up by hand.
- A mount inside a **git working tree** means every `git status` enumerates a
  full Windows installation.
- **Path length** is the one that surprises people. The deepest paths inside a
  serviced image are in WinSxS and run to roughly 200 characters on their own;
  MAX_PATH is 260, and this toolkit does walk the mount when it compares drivers
  and reads INFs. A short root like `C:\WimMount` leaves room for that. A mount
  six folders deep inside a project directory does not, and the failure lands in
  the middle of a servicing run rather than at the start.
- Microsoft's own guidance is direct about profile folders: *"Don't mount images
  to protected folders, such as your User\Documents folder."*

`Test-WfMountPath` checks all of that and says what would go wrong. It runs as
part of **Housekeeping → Environment check**, at first run, and on demand from
**Settings → Check the mount folder**. It reports rather than refuses, so a
sensible mount folder somewhere unusual is still yours to choose.

Then run **Housekeeping → Environment check**: elevation, which DISM is on PATH,
whether the configured paths exist, whether a stale mount is left over, and
whether there is disk space. Most failed image jobs are one of those five things,
and finding out before a twenty-minute mount is cheaper than after.

Both front-ends offer to restart elevated when they are not. Windows only grants
administrator rights at process creation, so no process can give them to itself, and
"elevate" always means a new window opens and the current one closes. Pass
`-Elevate` to skip the question, which is what you want on a shortcut.

## One image at a time

Pick the image once. Everything that acts on it, servicing, customisation,
updates and the driver comparison, uses that one, and both front-ends show which it
is and what it turned out to be. In the GUI it lives in a bar above the tabs; in
the console it is on the main menu and in the header of every screen. Choosing it
reads it straight away, so the release, build and edition are on screen before
anything touches the file. Boot images keep their own picker, because a
`boot.wim` is a different file rather than a different opinion about the same one.

**Mount once, then work.** Any operation that needs the image mounted will reuse
a mount that is already open, and leave it open. So a run of five customisations
is one mount, five changes and one commit, rather than five mounts and five
commits: twenty minutes of DISM to make five changes that each take seconds.
Mount from the Servicing tab (or the console's servicing menu), do the work, then
dismount and commit when you are done. Nothing mounted is still fine: each
operation mounts, applies its change, commits, and discards on failure, exactly
as before.

A mount of a *different* image is refused rather than worked around. Quietly
dismounting somebody's half-finished work to make room is not a thing a tool
should decide on its own, so it says which image is open and leaves it alone.

## Configuration

Everything is set from **Housekeeping → Settings** in the console or the
**Settings** tab in the GUI: every value listed, a folder or file browser on
anything path-shaped, and a colour showing whether each path is fine, missing a
folder, or on a drive that does not exist here.

Almost everything hangs off one **workspace folder**. *Move workspace* repoints
images, drivers, updates, payload, logs and history in a single step.

The live configuration is created per-machine at
`%ProgramData%\WimForge\config.json`. The repo ships only
`WimForge.config.example.json`, which nothing reads, so no machine's drive
letters are ever committed. Pass `-ConfigPath` to use a different file.

A configuration pointing somewhere unreachable, such as a workspace on a drive this
machine does not have, which is what a config copied between workstations looks
like, is reported in plain terms with an offer to fix it, rather than as a wall
of provider errors. Paths are built as strings and only checked where they are
actually used.
