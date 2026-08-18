<!-- WimForge -- https://github.com/centauri/wimforge
     Copyright (c) 2026 Paul Admiraal. MIT licence; see LICENSE. -->

# Development

Calling the module from a script, the guards that keep two front-ends honest,
and the things worth knowing before changing any of it.

## Scripting it

The front-ends are thin. The monthly job runs unattended:

```powershell
Import-Module .\WimForge\WimForge.psd1

$target = Get-WfImageUpdateTarget                # ask the image what it is
Get-WfLatestUpdate -Category Cumulative -Product $target.Product `
                   -ProductAlternative $target.ProductAlternative `
                   -Architecture $target.Architecture -KnownKB $target.InstalledKB
Invoke-WfServicingRun -Notes 'August CU + new model'
Add-WfBootDriver -ExportPath D:\Imaging\Images\WinPE-2026-08.wim -WorkingCopy
Publish-WfImage  -ImagePath  D:\Imaging\Images\REFERENCE-2026-08.wim
```

Building a base image from scratch:

```powershell
New-WfReferenceVm
Set-WfGuestCredential
Initialize-WfReferenceBuild -Stage Start
# ... install the application stack ...
New-WfReferenceCheckpoint
Initialize-WfReferenceBuild -Stage PreSeal -Sysprep
Invoke-WfReferenceCapture -Notes 'Initial build'
```

`Get-Command -Module WimForge` lists everything; every function has full
comment-based help.

## A few things worth knowing

**Boot image indexes.** On Microsoft media, `boot.wim` index 1 is the base WinPE
and index 2 is Windows Setup, and index 2 is the one WDS boots. A copype-built
custom PE is a single index, 1. Both front-ends print the index table before
mounting anything.

**`/ResetBase` is a one-way door.** Large size win, but afterwards the applied
updates can no longer be uninstalled from the deployed OS.

**Single changes are applied in place.** The Customise operations mount the image
you named, make the change and commit to that file. Only the full servicing run
uses a working copy, because it produces a separate output file anyway.

**Stale mounts.** If a run is killed the mount survives. **Housekeeping → Repair
stale mounts** discards anything mounted and runs `dism /Cleanup-Mountpoints`.

**Modern cumulative updates are applied by `dism.exe`, not by the cmdlet.** A
Windows 11 24H2 (or 25H2, or Server 2025) cumulative is a UUP package that
arrives as a WIM-format `.msu`, and DISM does not unpack those itself. It asks
the Windows Update Agent to, over COM. `Add-WindowsPackage` loads DISM
in-process, inside the PowerShell host, and on a hardened workstation that
activation is refused: `0x800401E3`, which surfaces several layers up as *"An
error occurred applying the Unattend.xml file from the .msu package"*, a message
that names a file you do not have and a problem you do not have. The same package
applies to the same mounted image without complaint when `dism.exe /Add-Package`
does it, because `dism.exe` is a separate process. So WimForge reads the
container header and routes on it: cabinets keep the cmdlet, WIM-format packages
go to `dism.exe`. Nothing to configure, and nothing to notice unless you are
reading the log.

Worth knowing chiefly because of what it rules out. That error is not a disabled
Windows Update service, not a corrupted download, not a checkpoint `.msu` in the
wrong folder and not an image that needs rebuilding. All four were chased, and
all four were wrong. If it appears again, something has gone round the `dism.exe`
path.

## Running the tests

`Test-FrontEndParity.ps1` compares what the console and the GUI actually expose:
which module functions each calls, and which parameters each passes. One module
with two front-ends is easy to say and easy to lose: an option gets added to one
and not the other, and nobody notices until someone asks which is more capable.
Exit code 1 on a mismatch, including a parameter-only mismatch, which is the
case worth catching: calling the same function from both front-ends is not parity
if one of them cannot reach half the options. Pass `-AllowParameterDifferences`
when a difference is genuinely intentional.

It resolves splatted hashtables rather than giving up on them, so a call built as
`@params` is compared like any other.

`tests\` holds unit tests for the parts that can be tested without an image:
build-to-release mapping, architecture decoding, the catalog fallback logic, and
`Get-WfImageUpdateTarget` against a stubbed DISM. Each file exits non-zero on
failure and can be run on its own, but the whole suite plus the parity check and
the manifest load is one command:

```powershell
.\tests\Invoke-CiSuite.ps1
```

That is exactly what CI runs, once in Windows PowerShell 5.1 and once in
PowerShell 7, so a green run here is a green run there.

`Test-GuiLayout.ps1` checks hand-built panels arithmetically: the panel must set
its width before any child is added, and no child may extend past it. WinForms
anchoring records a control's distance from its container's edge at the moment
it is added, so a right-anchored button added to a panel that is still its
default 200px wide gets a negative offset and ends up hundreds of pixels off
screen once the panel reaches full width. No error, no log line. The controls
are simply not there. That shipped once.

`Test-ScriptOrder.ps1` walks both front-ends' syntax trees and fails if anything
at script level calls a method on a variable that is assigned further down the
file. Both are long scripts that run top to bottom, so a control registering
itself into a list that does not exist yet takes the whole script down on load,
before a window ever appears, which is not a subtle failure, but it is one no
amount of reading catches reliably. Function bodies and scriptblocks are exempt,
because they run later.

`Test-ListWrapping.ps1` fails on any `@($list)` where `$list` is a
`List[object]`. That throws "Argument types do not match" on PowerShell 7, and
only for `List[object]`; `List[string]` and `ArrayList` are fine, which is what
makes it so easy to write. It has been introduced three separate times here.
Use `.ToArray()`.

Two more Windows PowerShell 5.1 traps are worth knowing before adding code here,
since both have already caused bugs in this project. A function that returns `@()`
writes nothing to the output stream, so the caller gets `$null`, and
`@($null).Count` is 1, not 0, so the obvious emptiness check passes and the
`$null` travels on. And `$script:` assignments inside a `.GetNewClosure()`
scriptblock land in the closure's own scope and are silently discarded, so
anything that has to update script state must be done outside the closure.

When adding a function, put the logic in the module and list it in the manifest's
`FunctionsToExport`. A function is not callable until it is listed there, which is
deliberate: it stops half-finished helpers leaking into the menus.

If you add a GUI button, read the control values on the UI thread and pass them
through `Start-WfJob -Arguments`. The job body is marshalled to the background
runspace as text and rebuilt there. Never hand it a scriptblock that closes over
controls, because a scriptblock stays bound to the runspace that created it and
would resolve module commands against the wrong one.

## Cutting a release

Two workflows. `tests.yml` runs on every push and pull request. `release.yml`
runs only on a version tag, and publishes a downloadable archive.

```powershell
# 1. Bump the version in the manifest and write the CHANGELOG section.
#    Test-Docs.ps1 checks the two agree, so run the suite before tagging.
.\tests\Invoke-CiSuite.ps1

# 2. Commit, tag, push.
git commit -am "Release 1.1.0"
git tag v1.1.0
git push origin main --tags
```

The workflow then refuses to publish unless three things hold: the tag matches
`ModuleVersion` in `WimForge.psd1`, `CHANGELOG.md` has a `## [1.1.0]` section,
and every test file plus the parity check passes on the tagged commit. Tests
passing on a commit is not the same as tests passing on the tag, so they run
again there.

What it publishes is `WimForge-1.1.0.zip` with a versioned folder inside it, a
`.sha256` file beside it in `sha256sum` format, and the notes lifted out of the
CHANGELOG section rather than generated from commit subjects. GitHub attaches
its own "Source code (zip)" as well; the point of the built one is the
predictable name, the checksum and the gate.

The archive is the toolkit as you would run it, around 400 KB: the module, both
front-ends and their launchers, the standalone scripts, `ReferenceBuild`, the
documentation and the licence. The test suite and the parity check stay in the
repository, because somebody who wants those clones it.

What ships is a named list rather than a filter, and anything in the repository
root that is on neither list fails the build. An exclude list is the obvious way
round and the wrong one: a file added a year from now would ship in every release
without anyone deciding it should.

Two things are then checked against the built archive rather than assumed. That
the development files really are absent, because an include list that silently
copied the whole tree would satisfy every other check. And that every relative
link in the packaged documentation resolves inside the archive, because leaving a
file out is not only a missing file, it is a dead link in the README of every
copy anyone downloads. That check exists because the first version of the include
list did exactly that to the runbook.

A tag with a suffix, `v1.1.0-beta1`, is published as a prerelease. The version
check compares against the part before the dash, so the manifest stays at
`1.1.0`.

Before it publishes, the archive is extracted and checked: the manifest loads,
it exports something, the launchers and the licence are present, and no live
configuration file made it in.

## The window does nothing on a schedule

Worth knowing if you ever add to the GUI, because it is not obvious and it was
wrong once. A WinForms timer ticks four times a second for the life of the
window, and anything it does unconditionally it does unconditionally forever.
Three things used to sit in that handler, and between them they made the window
feel unstable: the cursor flickered, the Close button flickered, and clicks on
menus went missing.

Each had its own mechanism. Reading the mount table is `Get-WindowsImage
-Mounted`, which is a DISM call, and it was being made on the UI thread on every tick;
while it runs the window is not pumping messages, so a click that lands during it
is lost. `$form.Cursor` was assigned on every tick, and `Control.Cursor` is not
guarded the way most WinForms setters are: it forces a `WM_SETCURSOR` whether or
not the value changed, which pushed the I-beam over a text box back to an arrow
four times a second. And every action button had its `Enabled` rewritten each
tick, after which the mount label disagreed about two of them, so Close was set
enabled and then disabled within the same tick, a real state change each time,
and eight repaints a second on one button.

So the tick now acts on change rather than on schedule: button and cursor state
only when a job starts or finishes, the mount table only when something might
have changed it and otherwise every few seconds, and the log pane drained in one
go and scrolled once rather than scrolled per line. `Update-WfMountLabel` works
out the whole desired state, compares it against what is already on screen, and
writes nothing when they match. `tests/Test-GuiTimer.ps1` checks the shape of all
of that, because none of it fails anything. It just makes the window feel
broken.
