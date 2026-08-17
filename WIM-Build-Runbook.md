# Design notes: building a multi-model WIM

The reasoning behind how WimForge works, written up as a runbook. If you just want
the procedure, use `ReferenceBuild/Reference-Build-Checklist.md` instead. This
document explains *why* each step is what it is.

Target: one WIM, deployed over WDS/PXE into an existing WinPE, plus USB media for
sites with no deployment server, that boots and self-configures correctly on every
hardware model in the fleet.

---

## How this maps onto the toolkit

The reasoning below predates the front-ends and is still what they do; the commands
are just no longer the way in. Double-click `WimForge-Menu.cmd` or
`WimForge-GUI.cmd`. Either one reaches everything, and the parity check keeps them
that way.

| This document | Where it lives now |
|---|---|
| 1. Tooling | Housekeeping → **Environment check** |
| 2. Reference VM | Reference VM tab → **Read the host and fill these in**, then down the tab |
| 3. Harvest drivers | Driver library → **Harvest this machine** |
| 4. Inject into the OS image | Servicing → **Run servicing** |
| 5. Inject into the boot image | Boot and publish → **Inject PE drivers** |
| 6. Validation | Housekeeping → **Environment check**, then the checks in §6 |
| 7. Maintenance | Updates → **Get latest cumulative**, then §7 |

`Export-ModelDrivers.ps1` and `Add-DriversToWim.ps1` are still in the repo and still
work: they are what the module grew out of, and they are the right thing for a
scheduled task. Every example below shows both.

Three things the toolkit knows that this document originally did not, each because
getting it wrong cost an afternoon:

- **The mount folder does not follow the workspace.** A mounted image is a live
  NTFS projection of a whole Windows installation held open by a filter driver, so
  it wants a short path on a local disk, away from anything that scans, syncs or
  version-controls the workspace. `Test-WfMountPath` explains the rest; the README
  has the long version.
- **The reference VM needs a switch that reaches the internet**, and that is not
  the same as an External switch. See §2.
- **A cumulative update cannot be identified from the DISM header.** See §1.

---

## 0. The base-image decision

Refresh the old image, or rebuild from clean media? Rebuild, but only the OS is
rebuilt, not the knowledge.

Build a **new reference image from clean Microsoft LTSC 2021 media, in a virtual
machine, in audit mode**, and treat the old WIM as documentation rather than as a
foundation. The reason is specific to what you are trying to achieve here rather
than general hygiene: an image captured on a physical machine already has that
machine's drivers staged and ranked in its driver store. When you then deploy it to
a second model, PnP is choosing between the drivers you injected and the ones the
image was born with, and the older, wrong-model driver sometimes wins. That class of
bug is miserable to diagnose. It usually shows up as one flaky peripheral on one
model, months later. A VM-built base has no physical hardware drivers at all, so
every driver in the finished image got there because you put it there.

The secondary reasons are the familiar ones. An older image carries an unknown
number of superseded updates inflating WinSxS, local profile residue, certificates
that have since expired, scheduled tasks nobody documented, and whatever the
previous engineer did by hand at 17:45 on a Friday. Rebuilding gives you a build you
can reproduce next year from a script instead of from an archaeology session.

What you should mine out of the old WIM before retiring it: mount it read-only and
pull the installed application list, the registry customisations, the `unattend.xml`,
the scheduled tasks, the local policy, and the driver store export. Diff the finished
new image against the old one before you sign it off. Anything present in the old
image that you cannot explain is either a forgotten requirement or dead weight, and
finding out which is the actual work of this project.

```powershell
# Read-only inspection of the old image
New-Item -ItemType Directory -Path C:\OldMount -Force
Mount-WindowsImage -ImagePath D:\Images\Old.wim -Index 1 -Path C:\OldMount -ReadOnly

Get-WindowsDriver  -Path C:\OldMount | Sort-Object ClassName | Format-Table ClassName,ProviderName,Version,Date
Get-WindowsPackage -Path C:\OldMount | Where-Object PackageState -eq 'Installed' | Format-Table PackageName
Get-ChildItem C:\OldMount\Windows\Panther\unattend.xml

# Copy the SOFTWARE hive out before loading it: reg load opens a hive read/write
# (it needs to write the hive log), which fails against a -ReadOnly DISM mount.
Copy-Item C:\OldMount\Windows\System32\config\SOFTWARE "$env:TEMP\OLDSW" -Force
reg load HKLM\OLDSW "$env:TEMP\OLDSW"

# Both hives -- 32-bit installers register under Wow6432Node on an x64 image
'HKLM:\OLDSW\Microsoft\Windows\CurrentVersion\Uninstall',
'HKLM:\OLDSW\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall' |
    Where-Object { Test-Path $_ } |
    ForEach-Object { Get-ChildItem $_ } |
    ForEach-Object { (Get-ItemProperty $_.PSPath).DisplayName } |
    Where-Object { $_ } | Sort-Object -Unique

# The provider keeps registry handles open; without this the unload fails with
# "Access is denied" and the dismount then fails too.
[GC]::Collect(); [GC]::WaitForPendingFinalizers()
reg unload HKLM\OLDSW
Remove-Item "$env:TEMP\OLDSW" -Force

Dismount-WindowsImage -Path C:\OldMount -Discard
```

The one case where refreshing the old WIM in place is defensible: the old image was
itself VM-built, is documented, is not more than a year or two stale, and you are
against a delivery date. Then service it offline only, and never boot it and re-sysprep
it, because each generalize pass is another undocumented mutation.

---

## 1. Tooling

Install the **Windows ADK 10.1.26100.2454** plus the matching **Windows PE add-on**
on your build workstation. A newer ADK exists (10.1.28000.1, November 2025) but it
targets Windows 11 26H1 Arm64; 26100.2454 is the version whose stated support
covers Windows 10 including 21H2 / LTSC 2021, and it is the one to use here. The
rule that matters is that DISM must be at least as new as the image it mounts,
never older. Check the ADK download page for the current servicing patch before you
install, because the ADK has had security fixes in the imaging tools and the page lists
whichever KB applies. Always work from the *Deployment and Imaging Tools
Environment* shortcut (elevated) so the ADK's DISM is the one on PATH, not the
in-box one.

The ADK guidance above was re-checked against Microsoft's download page in August
2026 and still held. Housekeeping → Environment check reports which DISM is on PATH,
whether it is the in-box one or the ADK's, and what this workstation can therefore
service, which is the question the version numbers are a proxy for.

LTSC 2021 is supported to **13 January 2032** on the IoT SKU and is still receiving
cumulative updates. Since February 2021 the servicing stack update and the LCU ship
as a **single combined .msu** for Windows 10, so there is no separate SSU to
sequence.

Do not write the current KB number down anywhere, including here, because it is wrong
within a month. Use the Updates tab, which searches the Microsoft Update Catalog for
the image you have open.

**The trap that makes this worth a tool rather than a search box.** DISM cannot tell
you which release an image is. It reports `Version 10.0.19041` for the whole 19041
family (2004, 20H2, 21H1, 21H2 and 22H2 alike), and `SPBuild` is the UBR, not the
build. The only place the truth lives is the offline registry, which is why the
toolkit reads `CurrentVersion` out of the image's SOFTWARE hive rather than
believing the header.

It matters because a servicing family shares one LCU package, and that package is
titled with the NEWEST release in the family. An LTSC 2021 image is build 19044, and
the update you need is titled *Windows 10 Version 22H2*. Searching the catalog for
"21H2" finds nothing useful and looks like there is no update available.

---

## 2. Build the reference image (VM, audit mode)

Use a Hyper-V Gen 2 VM, one virtual disk, no checkpoints. Boot the LTSC 2021 media
and at the first OOBE screen press **Ctrl+Shift+F3** to drop into audit mode. You
land on the desktop as the built-in Administrator with no user profile created.

The Reference VM tab builds it. Click **Read the host and fill these in** first:
everything on that tab is a path or a name on the *Hyper-V host*, not on this
workstation, which is the detail that bites when the host is a server somewhere.

```powershell
New-WfReferenceVm -Name LTSC2021-POS-Reference -IsoPath D:\ISO\LTSC2021.iso `
                  -SwitchName LAN -MemoryGB 4 -VhdSizeGB 80 -CpuCount 2
```

Automatic checkpoints are turned off deliberately. Hyper-V enables them on new VMs,
they fire on every start, and one taken during sysprep leaves a reference build that
is quietly wrong and only shows up at capture.

**The switch is the setting that fails silently.** A name that does not exist is
rejected by `New-VM` in thirty seconds. One with no route out is *accepted*: the VM
is created, Windows installs, and the build cannot reach Windows Update, which
surfaces hours later looking like a different problem. What matters is not the
switch type:

| | Internet | Reachable from the LAN |
|---|---|---|
| External | yes | yes |
| Default Switch (reports as Internal, uses ICS) | yes | no |
| Internal with a NAT behind it | yes | no |
| Internal, bare | no | no |
| Private | no | no |

The first three are all fine for a build that only needs updates. Only External will
do if the build pulls an installer off a share. The tab says which is which.

Processor compatibility mode is off by default and should stay off unless this VM
itself will be moved to a host with an older CPU. It does not affect the captured
image (a WIM carries no processor features), and off is faster for the servicing
that happens inside the VM.

Install everything that is genuinely common to all models: your application
stack, runtimes, agents, certificates, the local policy baseline.
Leave out anything model-specific and anything that is easier to deliver by software distribution
afterwards: the image should be the stable substrate, not the whole payload.

Two things to get right before you sysprep:

**Do not burn activation rearms during development.** Every `sysprep /generalize`
resets the licensing state, and you will generalize this VM more than once. Put
`SkipRearm = 1` in the generalize pass of your unattend while you are iterating,
and remove it for the final build:

```xml
<settings pass="generalize">
  <component name="Microsoft-Windows-Security-SPP"
             processorArchitecture="amd64"
             publicKeyToken="31bf3856ad364e35"
             language="neutral" versionScope="nonSxS">
    <SkipRearm>1</SkipRearm>
  </component>
</settings>
```

**Keep the unattend model-agnostic.** No `ComputerName` (use `*` and let your
existing hostname automation set it), no model-specific driver paths, no
hardware-specific power plan. `CopyProfile` is the one thing worth setting if you
customised the Administrator profile and want new users to inherit it.

Snapshot/export the VM in audit mode *before* sysprep. That pre-sysprep VM is your
real master. Next quarter's rebuild starts by restoring it, applying updates, and
re-sealing, rather than by starting over.

```powershell
# By hand, inside the guest
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:C:\unattend.xml

# Or from the Reference VM tab: Checkpoint, then Clean up and SEAL, then Capture.
# The checkpoint is not optional -- sealing is one-way, and the pre-sysprep VM is
# what next quarter's rebuild starts from.
Initialize-WfReferenceBuild -Stage PreSeal -Sysprep -UnattendPath D:\Imaging\unattend.xml
```

Then boot the VM from a WinPE ISO and capture:

```
Dism /Capture-Image /ImageFile:D:\Images\LTSC2021-Base.wim /CaptureDir:C:\ ^
     /Name:"Windows 10 LTSC Base" /Description:"VM reference build 2026-08" /Compress:max
```

---

## 3. Harvest drivers, one folder per model

Run `Export-ModelDrivers.ps1` on one known-good machine of each model, meaning a machine
where Device Manager is clean, all peripherals work, and the vendor packages are
already installed. `Export-WindowsDriver` returns exactly the third-party INF
drivers Windows actually staged, which is the important difference from dumping
whole vendor driver packs into the image. A vendor pack contains every variant for
every board revision; feeding all of that to the PnP ranker is how you end up with a
machine that picks a driver that *almost* matches. Harvesting from a working machine
gives you the set that demonstrably works.

```powershell
# Driver library tab -> Harvest this machine, or:
Export-WfModelDriver -ExcludeMicrosoft

# The original standalone script still works and is the better fit for a
# scheduled task on a reference machine:
.\Export-ModelDrivers.ps1 -Destination \\srv01\Imaging$\Drivers
```

**`-ExcludeMicrosoft` is usually what you want.** Microsoft's own inbox drivers are
already in the image; harvesting them adds size and gives the PnP ranker more
candidates to choose between for no benefit.

**Duplicates are the other thing to know about.** The DriverStore keeps every
version it has ever staged, and `Export-WindowsDriver` exports all of them, so a
machine that has had three versions of the same NIC driver hands you three copies.
`Remove-WfDuplicateDriver` keeps the newest of each INF (by version, then date, and
it never compares different INF names against each other) and reports what it
dropped. Run it after a harvest, before the folder goes into the library.

You get `Drivers\<Vendor>_<Model>\`, a `_manifest.csv` of every package with its
class, provider, version and date, and a `_system.json` recording which machine and
BIOS level it came from. The script also warns you if the reference machine still
has devices in a non-OK state, fix those first, because otherwise you are baking
the gap into every machine you deploy.

Some target hardware ships driver-only `.exe` installers. Most support silent
extraction (`/extract`, `/s /e`, or 7-Zip on the payload); extract to a model folder
and it injects like any other. Anything that only exists as an installer with real
setup logic (OPOS/JavaPOS layers, most receipt printer suites, tools with services)
is not a driver injection problem. Those belong in your application layer or your software distribution tool,
not in the WIM's driver store.

Keep this driver library in your Git provisioning repo alongside the scripts, but
keep the binaries out of Git itself: version the manifests and the scripts, and
point at a file share (or LFS) for the driver payloads. The manifest is what you
actually want history on: it tells you which driver version was in which image.

---

## 4. Inject into the OS image

```powershell
# Servicing tab -> Run servicing, or:
# Note the switches are all SKIPs -- the full run is the default, and you opt out
# of parts of it rather than in.
Invoke-WfServicingRun -SourceImage D:\Images\LTSC2021-Base.wim -Index 1 `
                      -Notes 'quarterly'

# The standalone script, unchanged:
.\Add-DriversToWim.ps1 `
    -WimPath     D:\Images\LTSC2021-Base.wim `
    -DriverRoot  \\srv01\Imaging$\Drivers `
    -UpdatePath  D:\Updates `
    -Cleanup `
    -WorkingCopy `
    -ExportPath  D:\Images\LTSC2021-POS-2026-08.wim
```

The script mounts the image, applies any `.msu`/`.cab` in `-UpdatePath` in filename
order, injects every model's drivers, runs component store cleanup with
`/ResetBase`, commits, and exports a maximally compressed WIM. `-WorkingCopy` leaves
your base image untouched, so a failed run costs you a re-copy rather than a
re-capture. On any error the mount is discarded rather than left half-serviced.

Expect the image to grow by roughly the summed size of the driver folders, minus
overlap. For a handful of POS models that is typically a few hundred MB, and the
`/ResetBase` cleanup usually more than pays for it. If a driver fails to inject, the
script reports it with the reason; unsigned OEM packages need `-ForceUnsigned`,
while an architecture mismatch means you harvested an x86 package for an x64 image
and there is no flag that fixes it.

One consequence of the all-in-one approach worth knowing: first boot is longer,
because Windows installs the matching drivers during specialize/OOBE on hardware it
is seeing for the first time. On target hardware that is usually tens of seconds, not
minutes, and it is a one-time cost per machine.

---

## 5. Inject into the boot image: the WDS-critical step

The most common failure mode with a multi-model image is not the OS image at all.
It is WinPE: the machine PXE-boots, or it doesn't; it sees the disk, or it doesn't.
Your PE needs the **network** driver to talk to the server and the **storage
controller** driver to see the target disk, for every model, or that model silently
drops out of the deployment path.

```powershell
# Boot and publish tab -> Inject PE drivers, or:
Add-WfBootDriver -BootImagePath D:\Images\WinPE-POS.wim -Index 1

# The standalone script:
# Your own custom PE wim (single index)
.\Add-DriversToWim.ps1 `
    -WimPath    D:\Images\WinPE-POS.wim `
    -Index      1 `
    -DriverRoot \\srv01\Imaging$\Drivers `
    -BootImage `
    -ExportPath D:\Images\WinPE-POS-2026-08.wim

# A boot.wim taken straight off Microsoft media -- index 2, see the note below
.\Add-DriversToWim.ps1 -WimPath D:\Images\boot.wim -Index 2 `
    -DriverRoot \\srv01\Imaging$\Drivers -BootImage `
    -ExportPath D:\Images\boot-POS-2026-08.wim
```

`-BootImage` filters to the classes PE actually needs (`Net`, `SCSIAdapter`, `HDC`,
`System`, `USB`), so you are not carrying audio and graphics drivers into a boot
image that has to fit in RAM and travel over TFTP. USB is in that list deliberately:
newer platforms need the xHCI host controller driver in PE or the keyboard is dead
at the PE prompt.

**Index note. Get this right or the drivers land in an image nothing boots.** On
untouched Microsoft install media, `boot.wim` index 1 is the base *Microsoft Windows
PE* image and index 2 is *Microsoft Windows Setup*, and index 2 is the one WDS and
Setup actually boot. (Windows RE is not in `boot.wim` at all; `winre.wim` lives
inside `install.wim` under `\Windows\System32\Recovery\`.) So if you are servicing a
media-sourced `boot.wim`, use `-Index 2`, or inject into both. Your own custom PE
wim, built with `copype` / MakeWinPEMedia, is a single-index file, index 1. The
script prints the index table before it mounts anything when `-BootImage` is set,
but confirm it yourself first:

```powershell
Get-WindowsImage -ImagePath D:\Images\boot.wim | Format-Table ImageIndex, ImageName
```

After exporting, re-import the boot image into WDS (replace, don't add alongside, because
duplicate boot images in the same architecture cause a PXE menu nobody wants to
explain to whoever is standing at the machine) and make sure your TFTP server is serving the refreshed file.
If a separate TFTP server handles that leg, confirm the block size / window size settings
still perform acceptably with the larger boot.wim; a PE that grew by 150 MB over
TFTP is noticeably slower to load if the transfer is tuned conservatively.

### Your own software inside the boot image

A boot image is a good place to put a diagnostic or a vendor flashing tool, and a
bad place to put anything large. WinPE boots into memory, and Microsoft is
specific about what that costs: *"a contiguous portion of physical memory (RAM)
which can hold the entire Windows PE (WIM) image must be available."* So every
megabyte inside boot.wim is a megabyte every terminal has to find in one block,
on top of its scratch space.

```powershell
# What is in there now, and what it will need at boot.
Get-WfPeReport -BootImagePath C:\Imaging\Pe\boot.wim

# A small tool, into \Windows\Tools\<name>. Refused before anything is copied if
# the folder holds an .msi (there is no Windows Installer service in WinPE) or a
# binary of the wrong architecture (there is no WoW64 either, and a 32-bit tool
# in an amd64 PE returns instantly and does nothing).
Add-WfPeTool -Source D:\Tools\HardwareDiag -Command Diag.exe -BootImagePath C:\Imaging\Pe\boot.wim

# PowerShell, if the boot script really needs it. Its dependencies go in first,
# in Microsoft's documented order -- WMI, NetFX, Scripting, then PowerShell.
# Well over a hundred megabytes, all of it RAM on the terminal.
Add-WfPeOptionalComponent -Component PowerShell -BootImagePath C:\Imaging\Pe\boot.wim

# The writeable part of the RAM disk. Five values exist and no others.
Set-WfPeScratchSpace -SizeMB 512 -BootImagePath C:\Imaging\Pe\boot.wim
```

For anything large, put it on the media instead and have PE find it at run time.
It costs the boot image nothing, and it is the difference between a stick that
boots on a 4GB till and one that does not:

```powershell
# wpeinit first -- always, and not moveable. It installs the Plug and Play
# devices and brings up the network, so anything above it runs on a machine with
# neither and looks broken for reasons that have nothing to do with it.
New-WfPeStartnet -BootImagePath C:\Imaging\Pe\boot.wim -AllTools `
                 -PayloadFolder 'WimForge\Tools' -PayloadCommand 'menu.cmd' `
                 -RegionScript 'region.cmd'
```

The payload folder is searched for on every volume rather than assumed, because
*"WinPE drive letter assignments change each time you boot"*, and X: is skipped,
since that is the RAM disk the script is running from.

### HTAs, and where they belong

An HTA is the cheapest way to give WinPE a real front end, and the size argument
above does not apply to it at all. A menu is a few kilobytes, so *in the image*
is the right default. It is always there, it works when the stick's second
partition did not mount, and it does not depend on finding a volume before it can
draw anything.

Put it on the media instead while you are still writing it. A change is then a
file copy rather than mount-edit-dismount, and a site-specific menu should not
force a boot image rebuild. Move it into the image once it settles.

```powershell
# A working menu to start from -- VBScript, buttons that run commands, sized for
# a 1024x768 PE screen.
New-WfPeMenuHta -Title 'Plus POS' -Path C:\Imaging\Pe\Menu\menu.hta -Item @(
    @{ Label = 'Deploy'; Command = 'X:\deploy.cmd'; Hint = 'Applies the image and records the region' }
    @{ Label = 'Command prompt'; Command = 'cmd.exe' }
)

# Into the image. This also turns the legacy JScript engine back on, because an
# HTA in a modern boot image otherwise answers with "An error has occurred in
# the script on this page" and nothing that names the ADK or the engine.
Add-WfPeTool -Source C:\Imaging\Pe\Menu -Command menu.hta -Name Menu `
             -BootImagePath C:\Imaging\Pe\boot.wim

# It needs WinPE-HTA, which pulls in WinPE-Scripting.
Add-WfPeOptionalComponent -Component WinPE-HTA -BootImagePath C:\Imaging\Pe\boot.wim

# Started through mshta.exe, not by file association -- the association is
# undocumented in WinPE and MDT never relied on it either.
New-WfPeStartnet -BootImagePath C:\Imaging\Pe\boot.wim -AllTools
```

`Get-WfPeReport` is the pre-flight for this: it is the only place that knows both
what is in the image and what each tool needs to start, so it names any tool that
cannot run and the component that would fix it.

To make PE look like a product rather than a command window, `Set-WfPeShell`
writes `winpeshl.ini`, and an HTA works there as well as an .exe. It points at a
generated wrapper rather than straight at your application, deliberately:
replacing the shell means startnet.cmd never runs, and startnet.cmd is what calls
wpeinit. Microsoft documents neither half of that, so the wrapper makes the
question moot instead of relying on being right about it.

Two details of the file format decide how that is written. Microsoft: *"You can't
specifiy any command-line options with LaunchApp"* (their typo), so `[LaunchApps]`
is used instead, the section that does take arguments. And the wrapper is a
`.cmd`, which is not an executable but input to one, so the entry is `cmd.exe`
with the wrapper as its argument. One more thing worth knowing before making an
HTA the shell: *"Windows PE will reboot when that command prompt exits"*, so a
close button on a shell HTA is a reboot button wearing the wrong label, and
`New-WfPeMenuHta -NoQuit` leaves it out.

---

## 5a. The Setup refresh the media is owed

Service boot.wim and the media is **not finished**. Windows Setup exists twice,
`\sources\setup.exe` on the media and a copy inside the boot image, and
servicing moves one forward and leaves the other behind. Microsoft:

> *"If these binaries aren't identical, Windows Setup will fail during
> installation."*

Nothing about the media looks wrong without this step. It is the last thing a
media refresh does:

```powershell
# The Dynamic Update goes in FIRST when there is one. That order is load-bearing:
# the update package can carry its own setup.exe, so expanding it afterwards
# would put the older binary straight back and undo the whole step.
Update-WfMediaSetupFile -MediaPath C:\Media\Win11-24H2 `
                        -SetupDynamicUpdate C:\Updates\setup-du.cab
```

It copies `setup.exe` always, `setuphost.exe` only when the boot image is build
26100 or later (it does not exist before Windows 11 24H2, and its absence on
older media is correct rather than a failure), and refreshes the boot manager by
searching the media for `b*.efi` and overwriting by file name, which is how
Microsoft's own script does it, and means media laid out differently still gets
serviced.

Which index of boot.wim carries Setup is asked, not assumed. Microsoft's script
tests for index 2, but that mapping appears in no documentation and a
copype-built image has one index, so `Get-WfMediaSetupIndex` looks for the index
that actually contains `sources\setup.exe`.

---

## 6. Validation before rollout

Deploy to one physical machine of **every** model. Not a sample, every model. The
whole point of the exercise is the models you did not test.

On each, after first boot:

```powershell
# Nothing unhealthy
Get-PnpDevice -PresentOnly | Where-Object Status -ne 'OK' |
    Format-Table FriendlyName, Class, Status, InstanceId

# Which driver actually won, per device
Get-PnpDevice -PresentOnly | Get-PnpDeviceProperty -KeyName DEVPKEY_Device_DriverVersion,DEVPKEY_Device_DriverProvider

# Everything staged in the store
pnputil /enum-drivers
```

Then the things a driver check will not catch: activation state (`slmgr /dlv`, where a
build that burned its rearms during development is the common trap, see §2), domain
join and trust, the application stack launching, and every attached peripheral
exercised for real. Confirm the machine takes a hostname from your automation rather
than keeping the image's.

If the image was locked down, check those too, because none of them fail loudly:

```powershell
uwfmgr get-config                       # is the filter on, and what is excluded
Get-WmiObject -Namespace root\standardcimv2\embedded -Class WEKF_PredefinedKey |
    Where-Object Enabled                # which key combinations are actually blocked
reagentc /info                          # WinRE enabled, and pointing where
Get-WinSystemLocale; Get-TimeZone       # the regional settings took
type C:\Windows\Temp\WimForge-FirstBoot.log
```

That last one matters more than it looks. `SetupComplete.cmd` runs once as SYSTEM
with no desktop and is deleted afterwards, and a non-zero exit code from it is
ignored, so the log it writes is the only evidence that anything in it ran at all.

Record the pass in a hardware validation document per model. You already have the
VALHW template pattern for this, and a multi-model image is exactly the case where
"it worked on the one I tested" is the risk you are managing.

---

## 6a. What else goes into the image

None of this is required to deploy, and all of it is easier to do offline than to
undo on a shop floor.

**Regional settings.** These usually live only in `unattend.xml`, which makes them
right only when the answer file is used. Set them in the image and the answer file
becomes a way to override the default rather than the only thing standing between
you and a US keyboard. UI language, system locale, user locale, keyboard and time
zone are separate settings that get conflated: an English UI with Dutch formats, the
usual answer for a Dutch estate whose support notes are in English, is UI `en-US`
with system and user locale `nl-NL`. A UI language can only be set to one already in
the image; DISM cannot invent it.

**One image, many countries.** The five settings above travel together as a preset,
so they cannot end up disagreeing with each other:

```powershell
# What the presets are. GeoIDs are Microsoft's, not ISO numbers -- Belgium is 21
# and Germany is 94, and there is no pattern to guess from.
Get-WfRegionPreset | Format-Table Id, Country, UserLocale, InputLocale, GeoId, TimeZone

# The image's own default. -UILanguage en-US is the usual estate answer: English
# menus, local formats. Without it the preset asks for that country's menus, and
# an image that does not have that language pack gets a warning and the other
# four settings rather than a failed build.
Set-WfImageRegion -Id NL -UILanguage en-US

# Just the home location, on an image whose formats are already right. This is
# the one thing unattend.xml cannot do -- Microsoft-Windows-International-Core
# has no GeoID element, so an image configured only from an answer file is in
# the wrong country and looks fine.
Set-WfImageGeoId -GeoId 176 -CountryCode NL
```

Per-site choice is split in two, and the split is the point. WinPE records an
answer and changes nothing; Windows applies it at first boot, where the tools for
it exist:

```powershell
# Deployment side: a numbered menu for the technician, as batch, because WinPE
# only has PowerShell if somebody added the optional component. Call it from
# startnet.cmd after /Apply-Image. It writes \ProgramData\WimForge\region.json
# onto the applied volume -- found by looking for it, since WinPE drive letters
# are not the letters Windows will use.
New-WfRegionPeScript -Offer NL, BE-nl, BE-fr, DE, SE -DefaultId NL -Path C:\Imaging\Pe\region.cmd

# Image side: reads that file at first boot and applies it, silently, before
# anyone logs on. -Ask adds one question at the FIRST LOGON for the case where
# nothing was recorded -- not during setup, because SetupComplete.cmd runs as
# SYSTEM with no desktop and anything waiting for input there hangs the machine
# with a blank screen.
New-WfRegionFirstBoot -Offer NL, BE-nl, BE-fr, DE, SE -Ask -TimeoutSeconds 45

# What a volume will come up as -- the recorded answer if there is one, the
# image default otherwise.
Get-WfRegionAnswer -TargetRoot W:\
```

For a terminal already in a shop with the wrong region on it, the answer file
beats a reimage by several hours:

```powershell
$xml = Get-WfRegionAnswerXml -Id BE-fr
Set-Content -LiteralPath C:\region-be-fr.xml -Value $xml -Encoding UTF8
# then, on the terminal, as an administrator:
#   control.exe intl.cpl,,/f:"C:\region-be-fr.xml"
#   tzutil /s "Romance Standard Time"
#   restart -- the system locale and the logon screen only follow a reboot
```

That XML is the *international settings* answer file, which is a different format
from `unattend.xml` and the only one that carries a GeoID. It reports nothing at
all, no exit code and no message, so the generated first-boot script reads the
settings back and logs what it found rather than trusting it.

**Device lockdown.** UWF, Shell Launcher, Keyboard Filter, Custom Logon. Enterprise
and IoT Enterprise only, which a POS estate is licensed for and almost never uses.
Enabling the features happens in the image; configuring them needs `uwfmgr` and WMI,
which an offline image cannot reach, so that half goes into a first-boot script.

One ordering rule, and it is not obvious: **UWF is enabled last**. Once the filter
is on and the machine reboots, nothing written afterwards survives, so enabling it
first discards the rest of the configuration on the next power cycle, and it looks
exactly like the settings never applied. And get the exclusions right: a till that
discards its own transaction log every night is worse than no write filter at all.

**Slimming.** There is no "remove everything unnecessary" button, because nothing
can know what is unnecessary on your estate. List first, then name what goes.
Provisioned apps, capabilities and optional features are three different things
removed three different ways.

**Recovery.** Worth reading `WimForge/Public/Recovery.ps1` before planning around
it, because the obvious approach does not work: `reagentc /setosimage`, the command
that registers a custom OS image for Reset this PC, is documented as *"not used in
Windows 10 or later."* It still exists and still appears to succeed. It does
nothing. What does work is either push-button reset re-applying your provisioning
packages from `\Recovery\Customizations`, or a WinPE boot entry with the WIM staged
on its own partition. Both are built; they answer different questions.

And whatever else happens, service `winre.wim`. The recovery image inside the
installed image gets none of the drivers injected around it, so on a terminal whose
storage controller needs one, recovery comes up with no disk to reset and no network
to reach a share. You find that out on the day you need it.

---

## 7. Maintenance rhythm

The build is only worth it if re-running it is cheap. Restore the pre-sysprep
audit-mode VM, apply the current LCU and any application updates, re-seal,
re-capture, then re-run the servicing pass against the same driver library.
Quarterly is a reasonable cadence for LTSC; monthly is usually more churn than a POS
fleet wants.

The quarterly loop, in the tool: select the working image once at the top. Every
tab uses it, and a mount is reused rather than taken again. Then Updates → **Read
this image** → **Get latest cumulative** → **Download + inject**, then
Servicing → **Run servicing**, then Boot and publish.

When a new hardware model arrives, it is a one-machine job: build it out by hand
once, harvest its drivers, drop the folder into the library, and re-run the
injection against both the OS image and the boot image. No new WIM, no
new task sequence, no per-model branch in the deployment script. That is the payoff
for the all-in-one approach, and it is why it is the right call for a fleet that
grows by one model at a time.

Keep a `CHANGELOG` next to the image files recording, per build: LTSC build number,
LCU applied, driver library commit, models validated, and who signed it off. When a
store reports something odd in fourteen months, that file is the difference between
an afternoon and a week.

---

## Quick reference

```powershell
# The tool, from a prompt rather than a menu
Import-Module .\WimForge\WimForge.psd1
Get-Command -Module WimForge          # every function has full comment-based help
Test-WfEnvironment                    # elevation, DISM, paths, stale mounts, space
Test-WfMountPath                      # is the mount folder somewhere an image can mount
Get-WfImageReport -Quick              # what an image is, without mounting it

# Raw DISM, for when something has gone wrong enough to want it
# Mount / unmount by hand
Mount-WindowsImage   -ImagePath .\install.wim -Index 1 -Path C:\WimMount
Dismount-WindowsImage -Path C:\WimMount -Save        # or -Discard
dism /Cleanup-Mountpoints                            # after a crash

# Find a server cumulative. The catalog does not say "Windows Server 2025"
# anywhere: build 26100 server is sold there as "Microsoft server operating
# system version 24H2", and build 20348 (Server 2022) as "version 21H2" --
# which is a server release and unrelated to the Windows 10 release of that
# name. Get-WfImageUpdateTarget maps the build to the right string for you.
Find-WfUpdate -Product 'Microsoft server operating system version 24H2' -Architecture x64

# The same KB covers client and server: KB5062553 returns a Windows 11 x64
# entry, a Windows 11 arm64 entry and a server entry. On disk the difference is
# the -2025 in windows11.0-kb5062553-x64-2025.msu, and WimForge files the two
# under Updates\Server2025\ and Updates\Windows11\ so they cannot be mixed up.

# Apply a modern cumulative by hand -- dism.exe, NOT Add-WindowsPackage.
# A 24H2 / 25H2 / Server 2025 cumulative is a UUP package in a WIM-format .msu,
# and DISM unpacks those through the Windows Update Agent over COM. The cmdlet
# hosts DISM inside the PowerShell process and that activation is refused on a
# hardened workstation -- 0x800401E3, reported as an Unattend.xml error. The
# executable asks from its own process and succeeds with the same file.
dism.exe /Image:C:\WimMount /Add-Package `
    /PackagePath:C:\Imaging\Updates\Windows11\KB5121767\windows11.0-kb5121767-x64.msu `
    /ScratchDir:C:\Imaging\Logs\DismScratch

# Inspect
Get-WindowsImage  -ImagePath .\install.wim
Get-WindowsDriver -Path C:\WimMount | Where-Object { -not $_.Inbox }
Get-WindowsPackage -Path C:\WimMount

# Size
dism /Image:C:\WimMount /Cleanup-Image /AnalyzeComponentStore
Export-WindowsImage -SourceImagePath .\in.wim -SourceIndex 1 `
    -DestinationImagePath .\out.wim -CompressionType Max
```
