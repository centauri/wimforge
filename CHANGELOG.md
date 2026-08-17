<!-- WimForge -- https://github.com/centauri/wimforge
     Copyright (c) 2026 Paul Admiraal. MIT licence; see LICENSE. -->

# Changelog

Notable changes to WimForge. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Entries say what changed and, where it is not obvious, *why*. A line saying a
function was added is less useful in six months than a line saying which failure
it prevents.

## [Unreleased]

Nothing yet.

## [1.0.0] - 2026-08-17

First public release. 148 exported functions across 24 module files, two
front-ends kept at parity, and 42 test files.

### Image servicing

- Mount, update, inject, clean, commit and export as one run, working on a copy
  so a failed run costs a re-copy rather than the image. The mount is discarded
  on any failure.
- Package application routed through `dism.exe` for WIM-format `.msu` files.
  A 24H2/25H2/Server 2025 cumulative is a UUP package in WIM clothing, and
  `Add-WindowsPackage` loads DismApi in-process, where the Windows Update Agent
  COM activation is refused on a hardened workstation, giving `0x800401E3`. A separate
  process succeeds.
- Windows Server 2025 support throughout, including the catalog trap: build
  26100 server is listed as *"Microsoft server operating system version 24H2"*,
  server titles carry no build number, and client and server share one KB.
- DISM hex codes translated into causes and cures, including the ones whose
  message names something three layers from the actual problem.

### Drivers

- A library harvested per model with `Export-WindowsDriver`, rather than scraped
  from vendor driver packs.
- Superseded duplicates removed. A real harvest from a year-old laptop produced
  nine copies of one Bluetooth driver and 42 superseded packages in total.
- Microsoft-provided drivers filtered out, and a comparison that says whether a
  published image is carrying current drivers.

### Reference image and reference VM

- `New-WfReferenceImage` builds from clean media in Microsoft's documented
  order: servicing stack, languages, features, cumulative update **last**,
  across `winre.wim`, `boot.wim` and `install.wim`.
- Hyper-V reference VM, local or remote, with checkpoints, audit-mode
  preparation, sealing and capture.

### Languages and region

- A display-language library on disk, imported once from the *Languages and
  Optional Features* ISO. A language added after a cumulative update carries
  resources only to the build its pack shipped with, so the update is re-applied
  or the run says plainly that it still needs doing.
- Region presets for the Netherlands, Belgium (Dutch and French), Germany,
  Sweden and the United Kingdom, carrying formats, keyboard, time zone and the
  **GeoID**. There is no GeoID in `unattend.xml`, which is why images configured
  only from an answer file report themselves as American.
- WinPE records the country at deployment into a two-line `region.json`; the
  first boot applies it. With no answer recorded the image default stands, or
  one question appears at the first logon, not during setup, where there is no
  desktop to draw it on.

### WinPE

- Boot-image drivers limited to the classes PE needs, because a boot image has
  to fit in contiguous RAM.
- Optional components added with their documented dependency chains, and the
  cost in RAM reported rather than discovered.
- Your own tools and HTAs inside the boot image, with `.msi` and
  wrong-architecture binaries refused before anything is copied, since both fail
  silently on the terminal otherwise.
- HTAs get the legacy JScript registry fix automatically. Microsoft replaced the
  engine in the ADK for Windows 11 22H2, and an HTA written for the old one says
  only *"An error has occurred in the script on this page"*.
- `startnet.cmd` generated with `wpeinit` first and unmovable, and a payload
  folder found on the media at run time so large software costs the boot image
  nothing.

### Installation media

- `Update-WfMediaSetupFile` copies Setup back out of a serviced `boot.wim` onto
  the media. Microsoft: *"if these binaries aren't identical, Windows Setup will
  fail during installation."* Nothing about the media looks wrong without it.

### Lockdown, recovery and deployment

- UWF, Shell Launcher, Keyboard Filter and Custom Logon, with UWF enabled last:
  once the filter is on, nothing written afterwards survives.
- Push-button reset customisations and a WinPE recovery partition.
  `reagentc /setosimage` is documented as *"not used in Windows 10 or later"*;
  it still appears to succeed and does nothing, so neither is built on it.
- WDS publishing with SHA256 verification and retention, bootable USB media for
  sites with no deployment server, and post-deployment validation.

### Front-ends

- A Windows Forms GUI and a console menu, kept at strict parity by
  `Test-FrontEndParity.ps1`.
- Every list is picked rather than typed, read from a real source: time zones
  from the machine's own database, locales from .NET, keyboard layouts from the
  registry, and UI languages from the image itself, because offering one the
  image does not have would be offering a choice that does not exist.

### Tests

- 42 test files, none of which need DISM, an image or a network, and none of
  which need administrator rights. Every fixture is created under the OS temp
  folder and removed afterwards, so the suite is safe to run on any machine;
  `Test-TestHygiene.ps1` checks that mechanically.
- Most of the tests are mechanical guards written after a specific bug, each with
  a comment at the top saying which one.

[Unreleased]: https://github.com/centauri/wimforge/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/centauri/wimforge/releases/tag/v1.0.0
