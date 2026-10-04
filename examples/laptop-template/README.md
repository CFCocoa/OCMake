# Laptop template

> **This is not a validated machine configuration.** It has never booted anything. The
> `b760i-aorus-pro` example next door reproduces a real EFI that runs on real hardware;
> this one exists to show the *declarations* a laptop needs and a desktop does not. Treat
> every value in `config.plist` as a starting point to verify against your own machine,
> not as an answer.

## What it is

`config.plist` is OpenCore 1.0.7's own `Docs/Sample.plist` (BSD-3-Clause, acidanthera) with
four kinds of edit:

- `PlatformInfo/Generic/SystemProductName` set to `MacBookPro16,1`, and the four identity
  keys blanked — they live in `secrets.plist`, exactly as in the b760i example
- `Misc/Security/ScanPolicy 0` and `SecureBootModel Disabled`, the usual bring-up settings
- `Misc/Boot/PickerMode External`, since this example stages OpenCanopy and its resources
- `ACPI/Add`, `Kernel/Add`, `UEFI/Drivers` and `Misc/Tools` emptied — the same state
  OCMake writes when it creates a `config.plist` for you

That last point is not hand-tidying. Those four sections are derived from what you declare,
and OCSnapshot *merges*: an entry it can match keeps its settings, `Enabled` included.
Sample.plist ships a **disabled** `VoodooPS2Controller.kext`, so a raw copy of it would
silently disable the kext this project declares, plugins and all.

You will not hit that in a new project, because you do not copy Sample.plist yourself — a
project whose `config.plist` is missing gets one created, already cleaned:

```
-- OCMake: created config.plist from OpenCore 1.0.7's Docs/Sample.plist -- hand-written from here on, so commit it
```

This example commits its config because it also carries the edits below, so it ships in
exactly the state that scaffolding would have produced.

## What is laptop-specific here

| Declaration | Why a desktop does not need it |
|---|---|
| `SMCBatteryManager` | battery percentage |
| `SMCLightSensor` | ambient light sensor behind auto-brightness |
| `VoodooPS2` | the keyboard, and the trackpad on anything still speaking PS/2 |
| `BrightnessKeys` | the screen brightness keys |
| `NVMeFix` | NVMe power management, which matters on battery |
| `HibernationFixup` | suspend/hibernate |
| `SSDT-PNLF` | backlight control |

`SSDT-PLUG`, `SSDT-EC-USBX` and `SSDT-PNLF` all come from OpenCorePkg's own
`Docs/AcpiSamples/Source` via `oc_ssdt(SAMPLES ...)`, compiled by `iasl` at build time —
nothing to commit, and they follow the OpenCore version automatically. Machines older than
Skylake want `SSDT-EC` instead of `SSDT-EC-USBX`.

## Both trackpad drivers ship

VoodooPS2 drives the keyboard (and a PS/2 trackpad); VoodooI2C drives an I2C trackpad.
Shipping both is fine, and this example does.

They each bundle their own `VoodooInput.kext`, so two entries end up sharing one
`CFBundleIdentifier`. The snapshot disables exactly the duplicate **entry** —
`VoodooI2C.kext/Contents/PlugIns/VoodooInput.kext` — and leaves both parent kexts and every
other plugin enabled. One VoodooInput loads, which is what you want; nothing else is
touched. `occheck` would tell you if a kext you declared came out disabled.

If your trackpad is PS/2 you can drop VoodooI2C, and if it is I2C you can drop VoodooPS2's
trackpad plugin, but neither is required to get a working machine.

(Upstream tagged `2.9` with no assets attached to the release; `2.9.1` is the first usable
tag after it. `oc_kext` reports that as "release has no downloadable assets".)

## Vaulting

`config.plist` keeps the `Misc/Security/Vault = Secure` that `Docs/Sample.plist` ships —
OCMake does not quietly relax it — and the project vaults for real:

```cmake
oc_vault(SECUREBOOT All)
```

That writes `vault.plist`, signs it into `vault.sig`, and embeds the public key in
`OpenCore.efi`, all with a key generated fresh for the build and thrown away. `All` rather
than `Release` because running Debug day to day should not mean giving up the vault.

The first build provisions pyca/cryptography under `OC_CACHE_DIR` if it is not already
importable; after that it costs nothing, and `-DOC_OFFLINE=ON` works as usual.

The chain still ends at `OpenCore.efi`, which only firmware UEFI Secure Boot verifies —
hence the name. `oc_vault(BASIC ...)` is the unsigned variant: it catches a half-copied
tree, not an attacker.

Drop the `oc_vault()` line and you must set `Vault` to `Optional` yourself, or the machine
will stop at the picker. `occheck` catches that before you find out at boot.

## What you still have to decide

None of this can be guessed from a template, and all of it is machine-specific:

- **USB mapping.** Nothing here maps ports. Build a `USBMap.kext` with USBToolBox or
  USBMap and add `oc_kext(USBMap PATH kexts/USBMap.kext)`.
- **The audio layout ID** for `AppleALC`, in `DeviceProperties`.
- **Framebuffer patches** for `WhateverGreen`, if the iGPU needs them.
- **CPU power management.** `SSDT-PLUG` covers the common case; `CPUFriend` plus a
  generated `CPUFriendDataProvider.kext` is the next step if frequencies are wrong.
- **Quirks.** Sample.plist's defaults are deliberately generic. `Booter/Quirks` and
  `Kernel/Quirks` depend on the chipset and firmware.
- **`ECEnabler`**, if the embedded controller reports battery values wider than 8 bits —
  common on recent laptops, and not declared here because it is not universal.

## Building it

```bash
cp secrets.plist.example secrets.plist    # then put your own identifiers in it
cmake --workflow --preset release
```

`secrets.plist` is gitignored, and the committed `secrets.plist.example` is what makes a
missing one a hard error rather than an EFI that quietly boots with blank identifiers.
