# Reference build checklist

Building a base image from clean Windows 10 IoT Enterprise LTSC 2021
media, in a VM, ready for the toolkit to service.

Work through it in order. The whole thing is roughly half a day the first time
and about an hour every time after, because step 4 leaves you a snapshot you
restore instead of starting over.

---

## Why a VM and not a physical terminal

The decisive reason is specific to a one-image-many-models fleet. An image
captured on a physical target machine already has that terminal's drivers staged
*and ranked* in its driver store. Deploy it to a second model and Windows is
choosing between the drivers you injected and the ones the image was born with.
The wrong one wins often enough to matter, and it surfaces months later as one
flaky peripheral on one model, which is a miserable thing to diagnose. A
VM-built base has no physical hardware drivers at all, so everything in the
finished image is there because you put it there.

The second reason is that it makes rebuilding cheap. The audit-mode snapshot in
step 4 is your real master: next quarter you restore it, apply the new cumulative
update, re-seal, re-capture. On metal that is a full rebuild each time, and there
is no way back from a bad sysprep.

Two things make this easier than it used to be. LTSC has no Store apps, so the
classic "sysprep failed because of a per-user Appx package" trap largely does not
apply. And Hyper-V's synthetic drivers are in-box in Windows 10, so a Generation 2
VM contributes nothing third-party to the driver store: there are no integration
components to install or strip out afterwards.

**The one case for metal:** part of the stack genuinely refuses to install without
the hardware attached. Some OPOS and peripheral suites bind at install time. If
your application stack installs cleanly on a machine with
no peripherals connected, build in a VM.

Do not worry about firmware. Generation 2 gives you UEFI/GPT, but a WIM is
firmware-agnostic, because partitioning happens at deploy time in your PE script, so a
Gen 2 reference build deploys fine to a legacy-BIOS terminal too.

---

## 1. Create the VM

On the Hyper-V host, elevated:

```powershell
.\New-ReferenceVM.ps1 -IsoPath D:\ISO\LTSC2021.iso -Path E:\VMs -SwitchName 'Default Switch'
```

It creates a Generation 2 VM with fixed memory, Secure Boot on with the
Microsoft Windows template, standard checkpoints, and **automatic checkpoints
turned off**. That last one matters: Hyper-V enables automatic checkpoints on new
VMs by default, they fire on every start, and one taken mid-sysprep gives you a
reference build that is quietly wrong.

## 2. Install Windows, then stop

Boot the VM, install LTSC 2021 as normal. At the **first OOBE screen**, the
region picker, press **Ctrl+Shift+F3**.

That reboots into audit mode: you land on the desktop as the built-in
Administrator, with no user profile created and OOBE not yet run. A Sysprep
dialog appears; leave it open or close it, it does not matter.

Do not click through OOBE. If you do, you have created a user profile that will
travel in the image, and the cleanest fix is to start again.

## 3. Prepare, then install the stack

Inside the VM, elevated:

```powershell
.\Prepare-ReferenceBuild.ps1 -Stage Start
```

This is the step people skip and regret. It stops Windows Update installing its
own drivers. In a VM that means generic virtual-hardware drivers get staged and
ranked, and they then compete with the real vendor drivers you inject later. It
also turns off hibernation (a multi-GB `hiberfil.sys` otherwise gets captured),
disables reserved storage (roughly 7 GB back), and sets a power plan where the
machine does not go to sleep mid-task.

Then install, in this order: runtimes and prerequisites, your application stack,
then agents, certificates and the local policy baseline.

Leave out anything model-specific, anything easier to deliver by your software distribution tool afterwards,
and anything needing a peripheral attached. The image should be the stable
substrate, not the whole payload. Every extra thing in it is something you have
to rebuild the image to change.

Do **not** join the domain, and do not rename the machine.

## 4. Snapshot before you seal

```powershell
Checkpoint-VM -Name 'LTSC2021-POS-Reference' -SnapshotName 'audit-mode pre-sysprep'
```

**This snapshot is the master.** Everything after this point is one-way. Next
time you need a new base image you restore this, apply the current cumulative
update, re-seal and re-capture. You never start from the ISO again.

Consider exporting the VM as well if the Hyper-V host is not backed up.

## 5. Clean up and seal

Put `unattend.xml` somewhere in the VM, then:

```powershell
.\Prepare-ReferenceBuild.ps1 -Stage PreSeal -Sysprep
```

The cleanup stops Windows Update (sysprep fails outright if an update is
mid-installation, and the error points nowhere useful), runs the online
component cleanup with `/ResetBase`, clears temp folders and the update download
cache, clears every event log, and then lists any third-party drivers still in
the driver store.

That last list should be **empty**. Anything in it came from somewhere and will
be captured into every machine, which is worth explaining before it ships.

You will be asked to type `SEAL`. The VM then runs
`sysprep /generalize /oobe /shutdown` and powers off.

**Do not boot it again.** Booting a generalized machine runs the specialize pass
and consumes the sealed state; you would have to seal it a second time.

## 6. Capture

Back on the host, with the VM powered off:

```powershell
Import-Module .\WimForge\WimForge.psd1
New-WfCapture -VhdxPath 'E:\VMs\LTSC2021-POS-Reference.vhdx' `
    -Notes 'Initial build, app stack v1.0, June CU'
```

This mounts the VHDX read-only via `Mount-DiskImage`, so no Hyper-V role is
needed, no WinPE stick, and the VM is never modified. It finds the Windows
volume, checks for `Sysprep_succeeded.tag` and refuses if the build was not
generalized, then captures with maximum compression and verification, and writes
a build history record.

Point the toolkit's `BaseImage` setting at the result, in **Housekeeping →
Settings**, or just drop the WIM in the `Images` folder and pick it in any prompt.

## 7. Hand off to servicing

The captured image is a clean, hardware-agnostic base with no updates and no
drivers. From here the toolkit takes over:

1. **Drivers → Harvest this machine**, run on one known-good terminal per model.
2. Put the current cumulative update `.msu` in the `Updates` folder. Since
   February 2021 the servicing stack and the cumulative update ship as one
   combined file, so there is nothing to sequence.
3. **Servicing → Run servicing** applies the update, injects every model's
   drivers, cleans the component store, exports a compressed final image.
4. **Boot and WDS → Inject PE drivers** for the boot image.
5. **Publish** both.
6. Deploy to one physical machine of **every** model and run
   **Build → Validate this machine** on each.

---

## Before you ship the first real image

Three things that are correct during development and wrong in production:

**Remove `SkipRearm`** from the answer file. It preserves the activation rearm
count across generalize, which is what you want while you are sealing the VM
repeatedly, but the build you actually ship should start with a clean licensing
state. The toolkit flags this every time you run `Test-WfUnattend`, on purpose.

**Replace the Administrator password placeholder**, and make sure
`SetupComplete.cmd` rotates it at first boot. `PlainText=false` does not protect
anything. Windows only base64-encodes the value, and anyone holding the WIM can
decode it in a line of PowerShell. There is no secure way to put a password in an
answer file; the answer is to treat it as a throwaway.

**Settle activation.** Nothing is in the answer file yet. If a MAK goes in later
it has to be the IoT Enterprise LTSC key, because the wrong SKU shows up as
`0xC004F069`, which you have chased before.

## Provisioning hook

The answer file deliberately has no `AutoLogon` and no `FirstLogonCommands`.
Per-machine work belongs in:

    <PayloadRoot>\Windows\Setup\Scripts\SetupComplete.cmd

which `Copy-WfPayload` places in the image and Windows runs as SYSTEM after
setup finishes, before anyone logs on. That is the right home for the hostname
rename, the domain join and the admin password rotation, not an answer file
that ships inside every machine.

## Diffing against the old image

Before signing the new base off, mount the old WIM read-only and compare. Use
**Housekeeping → Image inventory report** on both. Anything present in the old
image that you cannot explain in the new one is either a forgotten requirement or
dead weight, and working out which is the actual work of this project.
