# Two machines, one repository

> **Neither configuration here has booted anything.** This example exists to show the
> *shape* of a repo that builds more than one EFI — `examples/b760i-aorus-pro` is the one
> validated on real hardware. Both `config.plist` files are OpenCore's own
> `Docs/Sample.plist` with the four derived sections emptied and a couple of per-machine
> edits, exactly as OCMake would have scaffolded them.

## Layout

```
CMakeLists.txt        project(), include(OCMake.cmake), add_subdirectory() x2
common.cmake          what every machine here wants
desktop/CMakeLists.txt
desktop/config.plist
laptop/CMakeLists.txt
laptop/config.plist
```

One directory per machine, which is how a CMake project with two of anything is usually
laid out. Each machine's file names the EFI it describes and then just declares:

```cmake
oc_efi(laptop)
include(${CMAKE_SOURCE_DIR}/common.cmake)

oc_kext(VoodooPS2 GITHUB acidanthera/VoodooPS2)
oc_ssdt(SAMPLES SSDT-PLUG SSDT-EC-USBX SSDT-PNLF)
```

`oc_efi(<name>)` names the EFI that everything after it belongs to, for the rest of the
enclosing scope — so no `EFI <name>` on any line. `add_subdirectory()` scopes it, so it
cannot leak into the other machine, and `include()` runs in the caller's scope, which is
why `common.cmake` needs no parameters at all:

```cmake
# common.cmake
oc_opencore()
oc_kext(Lilu GITHUB acidanthera/Lilu)
...
```

Adding a third machine is one more subdirectory and one more `add_subdirectory()`. Nothing
in `common.cmake` changes.

The shared package is **fetched and extracted once**, not once per EFI, and there is one
`ocmake.lock` with one entry per declaration rather than one per machine.

## config.plist and secrets.plist are not named anywhere

Each machine's directory is where its EFI was first declared, so the defaults resolve to
that directory's own files — `desktop/config.plist` for one, `laptop/config.plist` for the
other. This is the main practical reason to prefer the subdirectory layout: in a single
flat `CMakeLists.txt` both EFIs would fall back to the same `./config.plist`, and OCMake
refuses that rather than letting two machines share one config in silence.

## What each machine gets

|  | desktop | laptop |
|---|---|---|
| picker | OpenCanopy, `PickerMode External`, GoldenGate icons | builtin text picker |
| audio | AppleALC | — |
| input | — | VoodooPS2 |
| ACPI | `SSDT-PLUG`, `SSDT-EC-USBX` | those plus `SSDT-PNLF` for backlight |
| HFS+ | OpenCorePkg's driver | `HfsPlus.efi` from OcBinaryData |

Each builds into `build/<name>/EFI` and gets its own targets:

```bash
cmake --build build --target efi-laptop      # just that one
ctest --test-dir build                       # ocvalidate + occheck for both
cmake --build build --target report-desktop  # that machine's bill of materials
```

There are no bare `validate` / `report` / `outdated` targets and no CPack config here —
with two EFIs there is nothing sensible for them to mean.

## Installing

Every EFI installs to `<prefix>/EFI`, because that is the only layout firmware looks for.
Installing both together would mean one silently overwriting the other, so OCMake refuses:

```bash
cmake --install build --prefix /Volumes/USB                     # error: names both
cmake --install build --component laptop --prefix /Volumes/USB  # this one
```

## Building it

```bash
cp desktop/secrets.plist.example desktop/secrets.plist   # then put your own identifiers in
cp laptop/secrets.plist.example  laptop/secrets.plist
cmake --workflow --preset release
```

Configuring prints what each machine ended up with, which is the check that a declaration
landed where you meant:

```
-- OCMake: 2 EFIs: desktop (6 kexts, 2 ACPI, 3 drivers, 3 resource sets), laptop (6 kexts, 3 ACPI, 2 drivers)
```

## A flat layout works too

If you would rather group by category than by machine, `EFI <name>` on each declaration
does that, and is also what lets one loop declare the same kexts for several machines:

```cmake
# --- kexts
oc_kext(Lilu      GITHUB acidanthera/Lilu      EFI desktop)
oc_kext(Lilu      GITHUB acidanthera/Lilu      EFI laptop)
oc_kext(AppleALC  GITHUB acidanthera/AppleALC  EFI desktop)
oc_kext(VoodooPS2 GITHUB acidanthera/VoodooPS2 EFI laptop)
```

Forgetting the keyword is not silent: the declaration falls back to an EFI named after the
project, which nothing gave an OpenCore package, and configuring stops with
`EFI 'rigs' has no OpenCore package`.
