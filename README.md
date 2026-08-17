# WimForge

**Build, service and deploy one Windows image that covers every hardware model
in your fleet**, instead of maintaining an image per model.

[![Tests](https://github.com/centauri/wimforge/actions/workflows/tests.yml/badge.svg)](https://github.com/centauri/wimforge/actions/workflows/tests.yml)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1%20Desktop-5391FE.svg)](#requirements)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows-0078D4.svg)](#requirements)

```
 __      ___       ___
 \ \    / (_)_ __ | __|__ _ _ __ _ ___
  \ \/\/ /| | |  \| _/ _ \ |_/ _` / -_)
   \_/\_/ |_|_|_|_|_|\___/_| \__, \___|
                             |___/
```

WimForge is a **PowerShell toolkit for offline Windows image servicing and
deployment**: DISM automation with the sharp edges filed off. It builds a
reference image from clean media, harvests drivers from real machines into a
library, applies cumulative updates and customisations offline, services the
WinPE `boot.wim` and `winre.wim`, publishes to WDS or a USB stick, and validates
a machine after deployment.

It is a module with two front-ends over it, a console menu and a Windows Forms
GUI, kept at strict parity by a check that fails the build if they drift. Every
button is also a plain function you can call from a script or a scheduled task.

Built for **Windows 10 IoT Enterprise LTSC** point-of-sale terminals, and
equally at home with **Windows 11 24H2/25H2** or **Windows Server 2025**. If you
are running MDT and looking for something smaller, or hand-rolling DISM scripts
and tired of it, this is aimed squarely at you.

<!-- Add a screenshot here before publishing: docs/images/gui.png
     A picture of the GUI is the single biggest thing you can do for this page.
![The WimForge GUI](docs/images/gui.png)
-->

---

## Contents

- [Why one image](#why-one-image)
- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Documentation](#documentation)
- [Layout](#layout)
- [Development](#development)
- [Licence](#licence)

---

## Why one image

An image per hardware model multiplies every change by the number of models.
WimForge takes the other approach: one hardware-agnostic base with every model's
drivers injected, letting Windows pick the right ones at first boot. Adding a
model becomes a one-machine job: harvest its drivers, drop the folder in the
library, re-run servicing. No new image, no new task sequence, no per-model
branch in the deployment script.

The catch is driver provenance, and much of the design follows from it. Drivers
are harvested from known-good machines with `Export-WindowsDriver` rather than
scraped out of vendor driver packs: a vendor pack carries every variant for every
board revision, and feeding all of that to the PnP ranker is how a machine ends
up running a driver that *almost* matches. The base image is built in a VM,
because an image captured on physical hardware already has that model's drivers
staged and ranked, and they then compete with the ones you inject.

---

## What it does

Each of these is covered properly in **[docs/features.md](docs/features.md)**.
This is the map.

| | |
|---|---|
| **Reference image from clean media** | Servicing stack, languages, features, then the cumulative update **last**, across `winre.wim`, `boot.wim` and `install.wim` in Microsoft's documented order. Nothing is committed if any step fails. |
| **Driver library** | One folder per model, harvested with `Export-WindowsDriver` from known-good machines. Superseded duplicates removed, Microsoft-provided drivers filtered out, and a comparison that tells you whether a published image is carrying current drivers. |
| **Offline servicing** | Mount a working copy, apply updates, inject drivers, clean the component store, commit and export, with the mount discarded on any failure, so a bad run costs a re-copy rather than the image. |
| **Updates from the Microsoft Update Catalog** | Searches the catalog for the image you actually have open. DISM cannot tell you which release an image is, so the release is read out of the offline registry instead of guessed from the build number. |
| **`dism.exe` for modern packages** | A 24H2/25H2/Server 2025 cumulative is a UUP package in a WIM-format `.msu`, and `Add-WindowsPackage` fails on it with `0x800401E3` on a hardened workstation. Package application is routed accordingly, with the reasoning written down. |
| **Display languages** | A library on disk, imported once from the *Languages and Optional Features* ISO. Language packs go in before the cumulative, and if one is already there it is re-applied, because Microsoft requires it and nothing tells you when it was skipped. |
| **One image, many countries** | Region presets for NL, BE (Dutch and French), DE, SE and UK: formats, keyboard, time zone and the **GeoID that `unattend.xml` cannot set**. WinPE records the answer at deployment; the first boot applies it. |
| **WinPE boot images** | Network, storage, chipset and USB drivers only, because a boot image has to fit in RAM. Plus optional components with their dependency chains, your own tools and HTAs, and a generated `startnet.cmd` that puts `wpeinit` first. |
| **The Setup refresh nobody does** | Servicing `boot.wim` leaves the media's `\sources\setup.exe` behind, and Microsoft is blunt: *"if these binaries aren't identical, Windows Setup will fail during installation."* |
| **Device lockdown** | UWF, Shell Launcher, Keyboard Filter and Custom Logon, which is what IoT Enterprise is licensed for and almost nobody uses. UWF is enabled **last**, for reasons that are not obvious until it costs you an afternoon. |
| **Recovery and reset** | `reagentc /setosimage` is documented as *"not used in Windows 10 or later"*. It still appears to succeed and does nothing. What does work is built instead: push-button reset customisations, or a WinPE recovery partition. |
| **Reference VM** | Hyper-V, local or remote, with checkpoints, audit-mode preparation, sealing and capture. |
| **Publishing and validation** | Copy to WDS with SHA256 verification and retention, build a bootable USB stick for sites with no deployment server, and check a freshly imaged terminal for generic-driver fallback, activation and domain trust. |
| **DISM errors that mean something** | A hex code translated into what actually went wrong and what to do, including the ones whose message points three layers away from the cause. |

---

## Requirements

- **Windows PowerShell 5.1** (Desktop edition), not PowerShell 7. The DISM
  module ships in-box and runs natively under 5.1; under 7 it loads through the
  WinPSCompatSession shim, which is where long-running mount operations
  intermittently fail. 5.1 is also STA by default, which WinForms requires.
- **Administrator rights** for anything that mounts an image.
- **Windows ADK** with the Deployment Tools, for WinPE media and optional
  components. Not needed for servicing alone.
- **Hyper-V**, only for the reference VM features, and it may be a remote host.

Full detail, including which DISM services which image, is in
[docs/getting-started.md](docs/getting-started.md#requirements).

---

## Quick start

Clone it, then double-click either launcher in Explorer:

```
WimForge-Menu.cmd            console
WimForge-GUI.cmd             GUI
```

Or from a prompt:

```powershell
.\Start-WimForgeMenu.ps1
.\Start-WimForgeGui.ps1
```

First run walks you through setup: it lists the local fixed drives with their
free space, offers sensible workspace folders, and creates the folder structure
under whichever you pick. There is no configuration file to edit by hand.

Then run **Housekeeping → Environment check** before anything else. Most failed
image jobs are one of five things: not elevated, the wrong DISM on `PATH`, a
missing path, a stale mount, or no disk space. Finding out before a
twenty-minute mount is cheaper than after.

Scripted, without either front-end:

```powershell
Import-Module .\WimForge\WimForge.psd1

Invoke-WfServicingRun -SourceImage D:\Images\Base.wim -OutputName 'POS-2026-08'
```

---

## Documentation

| Document | What is in it |
|---|---|
| **[docs/getting-started.md](docs/getting-started.md)** | Requirements, installation, the workspace, and why the mount folder deliberately does not follow it. |
| **[docs/features.md](docs/features.md)** | Every feature, with the reasoning and the traps behind each one. |
| **[docs/development.md](docs/development.md)** | Calling the module from scripts, the mechanical guards, and what to know before changing the front-ends. |
| **[WIM-Build-Runbook.md](WIM-Build-Runbook.md)** | Design notes: why a multi-model build is shaped this way, step by step, with the DISM commands behind each stage. |
| **[ReferenceBuild/Reference-Build-Checklist.md](ReferenceBuild/Reference-Build-Checklist.md)** | The procedure for building a new base image, without the reasoning. |
| **[CHANGELOG.md](CHANGELOG.md)** | What changed, and when. |

Releases are built by a workflow on a version tag: a `WimForge-<version>.zip`
with a SHA256 file beside it, published only if the tag, the manifest and the
CHANGELOG agree and every test passes. See
[docs/development.md](docs/development.md#cutting-a-release).

---

## Layout

```
WimForge-Menu.cmd            Explorer launcher for the console
WimForge-GUI.cmd             Explorer launcher for the GUI
Start-WimForgeMenu.ps1       console front-end
Start-WimForgeGui.ps1        Windows Forms front-end
Test-FrontEndParity.ps1      checks both front-ends expose the same things
tests/                       42 test files, no DISM, no image, no network
docs/                        the long-form documentation
WimForge/                    the module both front-ends call
  WimForge.psd1              manifest -- the public surface is defined here
  WimForge.psm1              loader
  Private/Core.ps1           logging, guards, INF parsing, path helpers
  Private/NativeWim.ps1      reads one file out of a .wim without mounting it
  Public/BootAndPublish.ps1  WinPE drivers, WDS publishing
  Public/Branding.ps1        name, version, banner
  Public/BuildOps.ps1        capture, USB media, post-deploy validation
  Public/Choices.ps1         the lists behind every "pick one"
  Public/Configuration.ps1   config, setup, environment check, build history
  Public/Customise.ps1       registry, payload, certificates, unattend, features
  Public/DismErrors.ps1      hex codes turned into causes and cures
  Public/Drivers.ps1         the driver library
  Public/Environment.ps1     elevation, image inventory
  Public/Languages.ps1       display languages: a library, and adding them
  Public/Lockdown.ps1        UWF, Shell Launcher, Keyboard Filter, first boot
  Public/Media.ps1           the Setup refresh installation media is owed
  Public/PeCustomise.ps1     your own software inside WinPE, and startnet.cmd
  Public/Recovery.ps1        getting a terminal back to the image it shipped with
  Public/ReferenceImage.ps1  building from clean media, in Microsoft's order
  Public/ReferenceVm.ps1     Hyper-V reference VM, local or remote
  Public/Region.ps1          country presets and the GeoID unattend cannot set
  Public/Regional.ps1        locale, time zone, OEM identity, local policy
  Public/Servicing.ps1       mount, updates, cleanup, export, full run
  Public/Slimming.ps1        apps, capabilities, features, the recovery image
  Public/Updates.ps1         Microsoft Update Catalog search and download
  Public/VmChoices.ps1       what the Hyper-V host already knows
ReferenceBuild/              building a base image from clean media
  Reference-Build-Checklist.md   start here for a new base image
  New-ReferenceVM.ps1        standalone VM creation
  Prepare-ReferenceBuild.ps1 runs inside the VM, in audit mode
  unattend.xml               answer file template for sealing
```

---

## Development

```powershell
# every test file -- no DISM, no image, no network, seconds to run
Get-ChildItem tests\Test-*.ps1 | ForEach-Object { & $_.FullName }

# the two front-ends must expose the same capabilities
.\Test-FrontEndParity.ps1
```

They are safe to run on any machine: no DISM, no image, no network, no
administrator rights, and every fixture is created under the OS temp folder and
removed afterwards. `Test-TestHygiene.ps1` checks that mechanically, so it stays
true.

The tests are not only unit tests. Most of them are **mechanical guards** written
after a specific bug, so the same class cannot come back quietly: front-end
parity, script ordering, GUI layout and timer behaviour, list wrapping, call
signatures checked against the AST, documentation checked against the code, and
repository hygiene. Each one has a comment at the top saying what it was written
after.

[docs/development.md](docs/development.md) has the rest, including what to know
before touching either front-end.

---

## Licence

MIT. See [LICENSE](LICENSE).

Paul Admiraal · https://github.com/centauri/wimforge
