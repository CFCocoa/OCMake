# B760I AORUS PRO — reference example

The EFI this example reproduces was dropped in from GitHub, validated for Sonoma.
**Validated.** `ctest` after a build runs `ocvalidate` (version-matched, from the OpenCore
package) plus OCMake's own checks. Doing this the first time found two keys the config was
missing for OpenCore 1.0.7 — `Booter/Quirks/ClearTaskSwitchBit` and `UEFI/Unload` — which
the upstream reference EFI is also missing. Both are now in `config.plist`.

**It builds.** `cmake -B build && cmake --build build` produces a complete `build/EFI` —
kexts, ACPI, drivers, the picker's resources and an assembled `config.plist`.
`cmake --build build --target diff-esp` shows what installing it would change;
`install-esp` does it, after archiving what it replaces. `cpack -G ZIP` packages the tree.

The `PickerVariant` moved from the reference EFI's `Blackosx\BsxM1` to
`Acidanthera\GoldenGate`: the original is a third-party icon set that nobody publishes as
a fetchable release, and OCMake declares only what it can fetch or what lives in the repo.

## ⚠️ The identifiers in the original config.plist were someone else's

`PlatformInfo/Generic` arrived with a populated `SystemSerialNumber`, `MLB`, `SystemUUID`
and `ROM`. Those came from whoever published the EFI. Booting with them is a bad idea:
they are tied to another machine, and reusing a serial that is already associated with an
Apple ID risks iMessage/FaceTime activation problems for both parties.

So they were split out:

| File | Contents | Committed? |
|---|---|---|
| `config.plist` | Everything else, with those four keys blanked | yes |
| `secrets.plist` | The original values, so the example still works locally | **no** — gitignored |
| `secrets.plist.example` | Placeholders showing the shape | yes |

**Generate your own** with [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) for
`MacPro7,1` and replace `secrets.plist` before booting this on real hardware.
`secrets.plist` is picked up by name and merged last, after the snapshot and every
override, which is what keeps the committed config.plist shareable. Because
`secrets.plist.example` is committed next to it, forgetting to create `secrets.plist`
stops the configure and points at the template, rather than quietly building an EFI with
blank identifiers.

## What is committed

- `config.plist` — the hand-written base. OCMake never generates this; it only rewrites
  the file-derived sections (`ACPI.Add`, `Kernel.Add`, `UEFI.Drivers`, `Misc.Tools`).
- `kexts/` — the three kexts that genuinely cannot be fetched:
  - `CPUFriendDataProvider.kext` — generated per-machine by CPUFriendFriend
  - `USBInjectAll.kext`, `XHCI-unsupported.kext` — rehabman-era, no GitHub releases
- `reference-EFI/` — the original tree, **gitignored**. 33 MB of its 35 MB is
  downloadable kexts, which is precisely the clutter OCMake exists to remove. It is kept
  locally as the ground truth to diff against as later phases land.

## Inventory, for the phases that will declare it

Kexts to fetch (Phase 2): Lilu, VirtualSMC (+SMCProcessor, SMCSuperIO), WhateverGreen,
AppleALC, CPUFriend, RestrictEvents, AppleIGC, AirportItlwm, BlueToolFixup,
IntelBluetoothFirmware, IntelBTPatcher, RadeonSensor, SMCRadeonGPU.

ACPI (Phase 3): `SSDT-AWAC`, `SSDT-EC-USBX`, `SSDT-PLUG-ALT` — all three ship as `.dsl`
sources in OpenCorePkg's `Docs/AcpiSamples/Source/`, so they can be compiled rather than
committed as `.aml`.

Drivers: OpenCanopy, OpenRuntime, ResetNvramEntry and ToggleSipEntry ship inside the
OpenCore package's `EFI/OC/Drivers/`. `HfsPlus.efi` does not — it is Apple's own HFS+
driver, which OpenCorePkg cannot redistribute, so it comes from `acidanthera/OcBinaryData`
via `oc_driver(OCBINARYDATA HfsPlus)`, pinned to a commit in `ocmake.lock`. The reference
EFI used OpenCorePkg's `OpenHfsPlus.efi`, the open reimplementation; both work, and most
builds prefer HfsPlus for speed.

Tools: `oc_tool(OpenShell)` stages OpenCore's UEFI shell from the same package, and the
snapshot writes the `Misc.Tools` entry — `Auxiliary`, with the `OpenShell:UEFIShell:Shell`
flavour. The reference EFI shipped none; this one carries it because a shell is the first
thing you want when a board does not behave as expected.

Two entries in `Kernel.Add` have no `ExecutablePath` (`CPUFriendDataProvider`,
`XHCI-unsupported`): they are plist-only injectors, and a useful test that the snapshot
step handles them.
