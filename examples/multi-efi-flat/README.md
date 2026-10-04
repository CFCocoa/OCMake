# One machine, two EFIs: the daily one and a rescue stick

> **Not a validated hardware configuration.** Both `config.plist` files are OpenCore's own
> `Docs/Sample.plist` with the four derived sections emptied and a handful of edits.
> `examples/b760i-aorus-pro` is the one validated on real hardware.

## What this is for

The recovery story OCMake actually recommends is a known-good EFI on a USB stick. It works
because on a separate volume the standard layout resolves against *that* filesystem —
`\EFI\BOOT\BOOTx64.efi` finds `\EFI\OC\OpenCore.efi` on the stick, not on the internal ESP —
so a stick you can boot is a machine you can get back.

The problem with that advice is that the stick rots. It was built from whatever the kexts
were six months ago, nobody rebuilds it, and the one time it matters it turns out to predate
the macOS upgrade that broke things.

Declaring it fixes that. The stick is rebuilt from the same kexts as the main EFI, every
time the main EFI is built:

```bash
cmake --build build
cmake --install build --component rescue --prefix /Volumes/USB
```

## Why this one is a flat file

The two EFIs here are nearly the same thing, so the file is grouped **by category** rather
than by EFI. Keeping the kexts together makes it obvious that both get the same ones;
keeping the drivers together puts the difference on adjacent lines:

```cmake
oc_driver(OpenRuntime OpenCanopy ResetNvramEntry EFI main)
oc_driver(OpenRuntime                            EFI rescue)
```

`examples/multi-efi` is the other layout — one directory per EFI — and suits two genuinely
different machines, where almost nothing lines up and grouping by category would only
interleave two unrelated lists.

Note there is no `oc_efi()` call anywhere in this file. `EFI <name>` on each declaration is
enough to create and name both, and finalization is deferred regardless.

## What differs, and why

|  | main | rescue |
|---|---|---|
| kexts | Lilu, VirtualSMC, SMCProcessor, WhateverGreen, AppleALC | the same five |
| ACPI | `SSDT-PLUG`, `SSDT-EC-USBX` | the same two |
| picker | OpenCanopy, GoldenGate icons | builtin — nothing extra to load |
| drivers | `OpenRuntime`, `OpenCanopy`, `ResetNvramEntry` | `OpenRuntime` only |
| tools | — | `OpenShell` |
| `ScanPolicy` | `0` | `0`, so it sees the stick it is booting from |
| `Timeout` | 5 | 10, and auxiliary entries shown so the shell is reachable |

The kexts and ACPI being identical is the point: a rescue EFI that boots with different
kexts than the one it is rescuing is not much of a rescue. Declaring them in one loop is
what stops them drifting.

`OpenShell` is only on the stick. A shell is what you want when something has gone wrong,
and exactly what you do not want sitting on the EFI you boot every day — OpenCore's own
Secure Boot checklist says not to sign it for the same reason.

## One secrets.plist, two EFIs

```cmake
foreach(efi IN LISTS BOTH)
  oc_secrets(secrets.plist EFI ${efi})
endforeach()
```

It is the same machine, so it is the same identifiers. An EFI that boots with someone
else's serial is not a rescue either.

The two `config.plist` bases *are* separate and named explicitly. Nothing here relies on
the `config.plist` default, which could not tell these two apart anyway.

## Building it

```bash
cp secrets.plist.example secrets.plist    # then put your own identifiers in it
cmake --workflow --preset release
```

Configuring prints what each EFI ended up with, which is how you check a declaration landed
where you meant:

```
-- OCMake: 2 EFIs: main (5 kexts, 2 ACPI, 3 drivers, 3 resource sets), rescue (5 kexts, 2 ACPI, 1 driver, 1 tool)
```
