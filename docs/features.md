<!-- WimForge -- https://github.com/centauri/wimforge
     Copyright (c) 2026 Paul Admiraal. MIT licence; see LICENSE. -->

# What WimForge does

The long version, feature by feature, with the reasoning. The
[README](../README.md) has the summary; [getting-started.md](getting-started.md)
covers installation and the workspace.

## Contents

- [Reference VM](#reference-vm)
- [Driver library](#driver-library)
- [Display languages](#display-languages)
- [One image, many countries](#one-image-many-countries)
- [Your own software inside WinPE](#your-own-software-inside-winpe)
- [The Setup refresh installation media is owed](#the-setup-refresh-installation-media-is-owed)
- [Updates from the Microsoft Update Catalog](#updates-from-the-microsoft-update-catalog)
- [Servicing](#servicing)
- [Boot images](#boot-images)
- [Offline customisation](#offline-customisation)
- [Device lockdown](#device-lockdown)
- [Regional settings and identity](#regional-settings-and-identity)
- [Slimming](#slimming)
- [Recovery](#recovery)
- [Publishing, validation and history](#publishing-validation-and-history)

## Reference VM

create a Generation 2 VM configured for imaging, prepare audit
mode, checkpoint, seal with sysprep, capture. The guest is driven over PowerShell
Direct, which runs on VMBus and so needs no network adapter, firewall rule or
name resolution. The Hyper-V host may be local or a separate server.

## Driver library

harvest a model's drivers from a known-good machine, list the
library with age and size per model, retire hardware you no longer support, and
compare a built image against the library to see whether it is carrying current
drivers.

**Which models, and which library, are both picked rather than typed.** The
models to inject come from a ticklist of what is actually on disk: INF count,
how many of those WinPE cares about, size, and how long ago that machine was
harvested. A folder name remembered from a harvest six months ago is a
typo waiting to fail twenty minutes into a servicing run. The library folder
itself sits at the top of the Drivers tab, prefilled from the configuration and
overridable with a folder browser: an engineer regularly has more than one
library: last quarter's, a colleague's, one on a share for a particular
customer's fleet. Editing the setting to service one image and remembering
to put it back afterwards is how the wrong drivers end up in an image. Clearing
the box falls back to the configured folder. The console menu has the same
override under **Drivers → Driver library folder**, for the length of the
session; neither writes to the configuration.

## Display languages

a library, because a language is a package rather than a
setting. A region (user locale, keyboard, time zone, home location) can be
changed at any moment, offline or on a running terminal, and costs nothing. A
display language cannot: the pack has to be physically in the image, and DISM is
blunt about it: *"if the language is not installed in the Windows image, the
command will fail"*. An answer file asking for a UI language that is not there
fails just as surely, only more quietly.

So an estate spanning several countries carries the languages it might need and
picks the region per site. `Import-WfLanguagePack` copies a language out of the
"Languages and Optional Features" ISO into `Languages\<tag>\` once;
`Get-WfLanguageLibrary` lists what has been imported and whether each has its
pack; `Add-WfLanguage` puts chosen languages into a mounted image, pack first
then its Features on Demand. `Set-WfImageLocale` now refuses a UI language the
image does not contain and says what it does contain, rather than applying the
other four settings and failing on the fifth.

Two things that bite here are handled rather than documented. Microsoft requires
the cumulative update to be **re-applied after** languages are added, otherwise
the new language carries resources only up to the build its pack shipped with,
nothing fails, and the symptom is English strings in a translated menu on a
terminal already in a shop. Pass `-CumulativeUpdate` and it goes in again; leave
it out on an image that already has one and the run says plainly what is still
owed. And the supplemental font packs are named after the script rather than the
locale (`Fonts-PanEuropeanSupplementalFonts`), so they belong to no language
folder and are deliberately not imported, with a line in the log saying so,
because a file that silently does not get copied is found out from a menu with
missing glyphs six months later.

Note there is no `nl-BE` or `fr-BE` display language, because Microsoft does not ship
one. Belgium is Dutch or French menus with Belgian formats and an AZERTY layout
on top, which is a region question, not a language one.

## One image, many countries

The region half of the same problem, and the part
that has to be decided three times over: at build time, at deployment, and at
first boot. `Get-WfRegionPreset` carries a row per country (Netherlands,
Belgium (Dutch), Belgium (French), Germany, Sweden, United Kingdom) because a
country is five settings that have to agree with each other, and setting the
formats to Dutch while leaving the home location American gives a terminal that
is half of each. `Set-WfImageRegion` applies one of those rows to a mounted image
and records it as that image's default.

The home location is the one nothing else can set. There is **no GeoID in
`unattend.xml`**. `Microsoft-Windows-International-Core` has `UILanguage`,
`UILanguageFallback`, `SystemLocale`, `UserLocale` and `InputLocale`, and that is
the lot, so every build configured only from an answer file has terminals in
Dutch shops reporting themselves as American, and nobody notices until something
region-aware behaves oddly. Offline, `Set-WfImageGeoId` writes it into the
default user hive. On a running machine it goes through the *international
settings* answer file, which is a different format from `unattend.xml`, is
applied with `control.exe intl.cpl,,/f:`, and does carry both the GeoID and the
flags that copy the finished set to the default user account and the logon
screen. `Get-WfRegionAnswerXml` produces one, which is useful on its own for a terminal
already in a shop with the wrong region on it, where reimaging is hours and
running one command is seconds.

Deployment and first boot are deliberately split. `New-WfRegionPeScript`
generates a WinPE fragment that asks which country and writes a two-line
`region.json` into the applied image. It is batch, because WinPE only has
PowerShell if somebody added the optional component, and it sets nothing at all.
`New-WfRegionFirstBoot` puts the other half into the image: a script that runs
from `SetupComplete.cmd`, applies `region.json` if it is there and never asks, and
otherwise leaves the baked-in default alone. With `-Ask` it registers a `RunOnce`
so the first person to log on gets one question with the image's own region
pre-selected and a countdown. The question cannot live in `SetupComplete.cmd`
itself, because that runs as SYSTEM with no interactive desktop, where anything waiting
for input hangs the machine with a blank screen and no way to tell why.

`Get-WfRegionAnswer` reads both files back off a volume and says which one wins.
`Write-WfRegionAnswer` records an answer from PowerShell, for a WinPE or a
deployment share that has it.

## Your own software inside WinPE

A boot image is a
good place for a diagnostic or a vendor flashing tool and a bad place for anything
large, because WinPE boots into memory and needs *"a contiguous portion of physical
memory (RAM) which can hold the entire Windows PE (WIM) image"*, so every megabyte
inside `boot.wim` is a megabyte every terminal has to find in one block, on top of
its scratch space. `Add-WfPeTool` therefore reports the cost loudly and pushes
anything past a threshold towards the other route: `New-WfPeStartnet -PayloadFolder`
searches every volume at run time for a folder on the media, which costs the boot
image nothing and works for gigabytes.

Two things WinPE will not do whatever you try, and both fail silently on the
terminal rather than loudly on the workstation, so both are checked before a single
file is copied. An `.msi` cannot install, because there is no Windows Installer service in
PE, and *".MSI installation files"* is on Microsoft's own list of what PE does not
support. And a 32-bit binary cannot run in a 64-bit PE: there is no WoW64 component,
the only emulation component that exists is x64-on-Arm64, and 32-bit WinPE itself
was retired after Windows 10 2004. `Add-WfPeTool` reads the machine type out of
every binary's PE header and refuses the mismatch, because the alternative is a
command that returns instantly and does nothing.

`New-WfPeStartnet` is one place that assembles the boot script instead of three that
each write their own. `wpeinit` always comes first and cannot be moved. Microsoft:
*"Startnet.cmd starts Wpeinit.exe. Wpeinit.exe installs Plug and Play devices,
processes Unattend.xml settings, and loads network resources."* Anything above that
line runs with no drivers bound and no network, which presents as a broken script
rather than a script run too early. `Add-WfPeOptionalComponent` puts PowerShell and
the rest in with their dependencies resolved in Microsoft's documented order, and
`Set-WfPeShell` replaces the command prompt with your application, pointing
`winpeshl.ini` at a generated wrapper that calls `wpeinit` first, because replacing
the shell means `startnet.cmd` never runs and Microsoft documents neither half of
that. `Get-WfPeReport` says what an image contains and roughly how much contiguous
RAM it will want at boot, which is the number that decides whether it works on a
thin till.

**Not everything worth putting in a boot image is an .exe.** An HTA is a few
kilobytes of HTML and turns a deployment console from a command window into
something with buttons on it; a `.cmd` is the most portable thing there is; a
`.ps1` is convenient if PowerShell is in the image anyway. They are not started
the same way, and getting it wrong is quiet. `Get-WfPeLaunchCommand` decides:
`mshta.exe` for an HTA, `call` for a batch file, `powershell.exe -ExecutionPolicy
Bypass -File` for a script, `cscript //nologo` for VBScript, and a refusal for
anything WinPE cannot start at all.

Going through `mshta.exe` rather than writing the bare path is deliberate. The
`.hta` association does appear to be registered in WinPE, and a Microsoft forum
thread shows a bare path launching one, but no Microsoft documentation says so,
and MDT's own `LiteTouch.wsf` builds `MSHTA.exe "…\Wizard.hta"` rather than
trusting it. An association is a nice thing to have and a poor thing to depend on.

Each kind also needs something *in* the image before it can run: an HTA needs
`WinPE-HTA`, which depends on `WinPE-Scripting`. `Add-WfPeTool` checks that while
the image is already open, and `Get-WfPeReport` says it again in front of whoever
is about to write the stick. An HTA in a boot image with no `WinPE-HTA` is a few
kilobytes of HTML that can never run, and nothing about the image looks wrong.

And there is a trap that is nobody's fault but costs a day. From the ADK for
Windows 11 22H2 onwards, Microsoft replaced the JScript engine, and an HTA that
worked for years comes up with *"An error has occurred in the script on this
page"*, a message that names neither the ADK nor the engine. MDT documents the
fix as two registry values; `Add-WfPeTool` writes them whenever the tool it is
adding is an HTA, and `Enable-WfPeLegacyJScript` does it on its own for an image
that already has one and broke after an upgrade.

`New-WfPeMenuHta` generates a working menu to start from: buttons that run
commands through `WScript.Shell`, sized for a 1024×768 PE screen. It is written
in VBScript rather than JScript on purpose: a sample whose whole job is to work
on the first boot should not depend on the registry fix above being right.

## The Setup refresh installation media is owed

Windows Setup exists
twice, `\sources\setup.exe` on the media and a copy inside `boot.wim`, and
servicing the boot image moves one forward and leaves the other behind. Microsoft is
blunt about the result: *"If these binaries aren't identical, Windows Setup will
fail during installation."* Nothing about the media looks wrong without this step,
which is exactly why it is the one that gets left out.

`Update-WfMediaSetupFile` is the last thing a media refresh does. It copies
`setup.exe` always and `setuphost.exe` only when the boot image is build 26100 or
later, since that file does not exist before Windows 11 24H2 and its absence on older
media is correct rather than a failure. It then refreshes the boot manager by
searching the media for `b*.efi` and overwriting by file name, which is how
Microsoft's own script does it and means media laid out differently still gets
serviced. Pass `-SetupDynamicUpdate` and it expands that first: the update package
can carry its own `setup.exe`, so doing it afterwards would put the older binary
straight back and undo the whole step. Which index holds Setup is asked rather than
assumed. Microsoft's script tests for index 2, but that mapping appears in no
documentation and a copype-built image has one index, so `Get-WfMediaSetupIndex`
looks for the index that actually contains `sources\setup.exe`.

**A harvest keeps only the newest copy of each driver.** The Windows driver store
keeps every version of a package it has ever staged, and `Export-WindowsDriver`
exports all of them: a real harvest from a year-old Dell laptop produced nine
copies of the Intel Bluetooth driver, seven of the graphics extension, and 42
superseded packages in total. Shipping all of that is exactly what harvesting
from a known-good machine was supposed to avoid. It hands the PnP ranker the
pile of near-identical candidates the whole design is trying to keep away from
it. Newest wins, by version then date, and packages with different inf names are
never compared, so nothing that is genuinely a different driver can be removed.
Pass `-KeepAllVersions` if you want the old behaviour.

**Drivers → Remove superseded duplicates** does the same to a library that was
harvested before this existed, without re-harvesting. It lists what it would
remove before removing anything.

Harvesting also asks whether to keep Microsoft-provided packages. These are the ones
Windows Update handed the reference machine rather than the ones the vendor
shipped: generic display, audio, Bluetooth, assorted class drivers. Whether you
want them depends on the target: an image at the same patch level almost
certainly has them already, so they are bulk for no gain, but a terminal that
never reaches Windows Update may genuinely need one. They are kept by default,
because a harvest that silently drops something is worse than one that is
slightly fat, and the count is reported either way with the full list in the log.
The same choice exists at injection time, where it is reversible and leaves the
library untouched.

The provider is read from what DISM recorded at harvest, falling back to the
INF's own `Provider=`, resolving the `%TOKEN%` indirection through `[Strings]`,
since that is how nearly every INF writes it. The match is deliberately narrow:
Microsoft as the provider, not any string containing the word. "Microsoft Partner
Ltd" is not Microsoft, and dropping its driver quietly is exactly the failure
that would not surface until a terminal was in a store.

## Updates from the Microsoft Update Catalog

search the Microsoft Update Catalog by category (cumulative, .NET,
Defender) or free text, pick what you want from the results, and download it
straight into the Updates folder. Also a one-step "get the latest cumulative" for
scripted monthly runs. Downloads are verified as real cabinet files before being
kept, so a proxy login page never sits in the Updates folder waiting to fail a
servicing run twenty minutes in.

**Read the target from the image** rather than typing a product string and
trusting it a year later. `Get-WfImageUpdateTarget` reads the image and works out
the product, release and architecture to search for, and flags results whose KB
is already installed.

That reading has to come from the image's registry. The WIM header cannot answer
the question: DISM reports version 10.0.19041 for every image in that family, so
2004 and 21H2 look identical there, and its "ServicePack Build" is the UBR rather
than the build.

Getting at that registry does not require mounting the image. The SOFTWARE hive
is pulled straight out of the `.wim` through `wimgapi`, the same library DISM
itself sits on, which takes seconds instead of the minute or two a mount costs,
and leaves nothing behind if it is interrupted. The result is cached against the
image's size and timestamp, so asking twice is free and a serviced image is read
again. If the image happens to be mounted already, that mount is used as it
stands. A mount is only taken when the extraction fails, or when
`-IncludePackage` asks for the list of updates already installed, which is the
one thing no shortcut can produce.

It also knows which builds share one update package. A 21H2 image, meaning LTSC 2021,
needs to search for **22H2** to find its own cumulative, because Microsoft titles
that single package with the newest release still being serviced. Searching the
release the image honestly is returns nothing at all, which looks exactly like a
broken tool.

Server images have the same problem in a worse form. Windows Server 2025 updates
are not titled "Windows Server 2025" anywhere in the catalog. The July 2025
cumulative is *2025-07 Cumulative Update for **Microsoft server operating system
version 24H2** for x64-based Systems (KB5062553)*. Server 2022 is the same shape,
"version 21H2", which is a server release and has nothing to do with the Windows
10 release of that name. WimForge maps the build to the string the catalog
actually uses and offers the obvious name below it as a second attempt.

Server titles also stop short of the build they install: a client cumulative
ends `(KB5101650) (26100.8875)` and the server one for the same month ends at the
KB. That is not a build that does not exist, only one written down elsewhere:
Server 2025 and Windows 11 24H2 ship as one KB, so the KB is looked up and the
client entry answers for it. The "vs image" column keeps working; when nothing
answers, it says so rather than reporting *0 of these would move it forward*,
which reads as "you are up to date" on a list nothing could measure.

Server 2025 needs one more distinction, and it is the sharpest edge in the whole
update path: **Server 2025 and Windows 11 24H2 are the same build, 26100, and
share the same KB number.** Searching that KB returns three entries, two client
and one server, and once the file is on disk the only thing telling them apart is
`-2025` in the middle of the name. So downloads are filed by generation,
`Updates\Windows11\` and `Updates\Server2025\`, and applying a server package to a
client image is refused by name rather than left to fail somewhere inside DISM.
The reverse is only warned about, because it rests on a marker being *absent*,
and refusing on absent evidence would block a legitimate update the day Microsoft
changes the naming.

Picked updates can go two ways. **Download** puts them in the Updates folder,
where the next servicing run applies them along with everything else in there,
the right thing for the monthly cycle. **Download + inject** mounts the image you
name, applies only the updates you picked, and commits, which is the right thing
when you want this one KB in this one image and nothing else. Either way a failed
download stops the whole thing rather than quietly injecting a shorter list than
you chose.

There is no official catalog API, so this scrapes the same two pages every tool in
this space does, so expect it to break occasionally when Microsoft changes the
page. It fails with a specific message when that happens, and downloading the
`.msu` by hand into the Updates folder always still works.

## Servicing

mount, apply cumulative updates, inject the driver library, clean
the component store, export compressed. As one run or as individual steps. The
mount is discarded on any failure rather than left half-serviced.

The inventory report comes in two depths. Identity, edition, release, build, UBR
and the third-party driver list are read out of the `.wim` directly and take
seconds. The drivers come from `SYSTEM\DriverDatabase`, which records every
staged package under its *original* inf name rather than the `oemNN.inf` it was
published as. The update and feature lists are what still needs a mount: those
live in the COMPONENTS hive, which is large enough that extracting it would cost
more than the mount it was meant to avoid. They are reported as unknown rather
than as zero, which would read as "this image has no updates in it".

The driver comparison takes the same shortcut. `Compare-WfDriver -Quick` reads
the image's driver list from that registry instead of mounting, and falls back
to mounting on its own if the key is not there. One honest caveat: the per-driver
version is stored in an undocumented binary field, so it is decoded
conservatively and validated, so an implausible date is reported as
`VersionUnknown`, never guessed. When the version matters more than the minutes,
mount.

Index tables never needed a mount at all, and choosing an image now shows what is
in it: index, name, edition, architecture, languages, size, and a plain note for
the conventions worth knowing. In the GUI, picking an image follows straight
through to the index table when the file has more than one; every index box also
has its own **Pick...** button. The console prints the same summary the moment an
image is chosen.

That matters more than it sounds. Every operation that mounts now names an index,
which several of them previously did not. They took whatever `Mount-WfImage`
defaulted to. On a single-index capture that is invisible; on a retail
`install.wim`, where each edition is a separate index, it silently services the
wrong one. `tests\Test-IndexIsPassed.ps1` walks both front-ends' syntax trees and
fails if any call to `Mount-WfImage`, `Invoke-WfServicingRun` or
`Invoke-WfUpdateInject` omits it.

## Boot images

inject only the classes WinPE actually needs: network, storage,
chipset, USB controllers. A model whose NIC driver is missing here never
PXE-boots and silently drops out of a rollout.

## Offline customisation

apply `.reg` files to the offline hives, copy a
payload tree into the image, import certificates into the offline machine store,
validate and place `unattend.xml`, enable features such as .NET 3.5.

## Device lockdown

the features that turn a Windows image into a terminal, and
the reason to be on IoT Enterprise in the first place. Unified Write Filter makes
the disk immutable, so a till that loses power nightly comes back to a known-good
state every time. Shell Launcher runs your application instead of Explorer.
Keyboard Filter swallows Ctrl+Alt+Del, Alt+Tab and the Windows key at a
customer-facing screen. Custom Logon removes the logon UI and the Windows
branding on the way up.

What can be done offline splits cleanly, and that split shapes the design.
*Enabling* the features is a DISM operation, so it happens in the image. Custom
Logon is plain registry values, so it goes into the image too, and every path taken
from Microsoft's device lockdown documentation rather than from memory. UWF,
Keyboard Filter and Shell Launcher are configured through `uwfmgr` and WMI,
neither of which exists in an offline image, so their settings are written into a
first-boot script that applies them on the terminal with nobody present.

One ordering rule in that script is not obvious and is enforced by test: UWF is
enabled **last**. Once the filter is on and the machine reboots, everything
written afterwards is discarded, so enabling it first would throw away the rest of
the configuration on the next power cycle, and it would look exactly like the
settings had never applied.

Exclusions matter more than the filter does. A till that discards its own
transaction log every night is worse than one with no write filter at all, so
both front-ends ask before writing a protected volume with nothing excluded.

**The first-boot seam.** `\Windows\Setup\Scripts\SetupComplete.cmd` is the
supported hook between imaging and provisioning, and the rules around it are easy
to get wrong. It runs once, as SYSTEM, after setup and before the first logon; it
has no interactive desktop, so anything that waits for input hangs the machine
with nothing on screen; a non-zero exit is ignored, so failure is silent; and
Windows deletes the script afterwards. So whatever you supply is wrapped with its
output redirected to a log outside the Scripts folder, which survives. An
`ErrorHandler.cmd` goes in beside it, for the case where Setup itself fails and
there is otherwise nothing to read.

## Regional settings and identity

UI language, system locale, user locale,
keyboard and time zone, applied to the image with DISM rather than left to
`unattend.xml`. Deploy the same image from a USB stick somebody built in a hurry
and it still comes up in the right date format; the answer file becomes a way to
override the defaults rather than the only thing that sets them. English UI with
Dutch regional formats is `-UILanguage en-US -SystemLocale nl-NL -UserLocale
nl-NL`. Settings are read back afterwards rather than trusted, because some DISM
versions accept a value they then do not apply.

Also here: the OEM manufacturer, model and support details that show in System
properties, which is small and worth a call not being routed three times before it
reaches you, and **local group policy**, which drops a prepared `Registry.pol`
into the image so a baseline applies on a terminal that has never seen a domain.
The `.pol` is checked for its `PReg` signature first: copy a `.reg` file there by
mistake and Windows would ignore it silently, forever.

## Slimming

provisioned AppX packages, capabilities and optional features,
each listed before anything is removed and only ever by name. There is no
"remove everything unnecessary" button, because nothing can know what is
unnecessary on your estate. Packages other things depend on (VCLibs, the .NET
native framework, the Store) are refused unless you insist, since what they
break does not break today.

## Recovery

`Winre.wim` lives *inside* the installed image and gets
none of the drivers injected around it. On a terminal whose storage controller
needs a third-party driver, recovery comes up with no disk to reset and no
network to reach a share, which you discover on the day you need it. The same
classes the boot image gets (storage, network, chipset, USB) go in, with the
recovery image copied out, serviced and put back with its hidden and system
attributes restored.

## Publishing, validation and history

copy to WDS with SHA256 verification, a sidecar `.json`
describing the build, and retention of older versions.

**Validation.** Run on a freshly imaged machine: unhealthy devices, drivers that
fell back to a Microsoft generic package, activation, domain trust, hostname,
free space, pending reboots, time source. Output as a pass/fail report to attach
to a hardware validation document.

**Build history.** Every run records what was done to which image, by whom, with
which driver and update counts. That file is the difference between an afternoon
and a week when something odd turns up a year later.
