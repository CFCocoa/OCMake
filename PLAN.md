# OCMake — declarative OpenCore EFI assembly in CMake

Status: Phases 0-6 built and tested; Phase 7 next. This file is the design — the *why*,
plus a per-phase log in §9 of the decisions and the bugs behind them. For the *what and
where* — file layout, target properties, generated file formats, the CMake traps, the
test suite — see **[IMPLEMENTATION.md](IMPLEMENTATION.md)**.

## 1. Goal and non-goals

**Goal.** A single `include(OCMake.cmake)` lets a repo describe an OpenCore EFI in
CMake. `cmake --build` produces a ready-to-drop-in `EFI/` folder. `cmake --install`
copies it onto a USB stick or the mounted ESP. Switching Release/Debug is one flag.

**Non-goals.**
- Not a config.plist generator or wizard. The base `config.plist` stays hand-written.
  OCMake only owns the parts that are derived from files on disk (`ACPI.Add`,
  `Kernel.Add`, `UEFI.Drivers`, `Misc.Tools`) and whatever the user explicitly
  asks it to patch (debug knobs, boot-args, secrets).
- Not a package manager with dependency solving. Versions are pinned explicitly.
- Not a replacement for ocvalidate or for reading the Dortania guide.

**Platforms.** macOS, Linux and Windows are all first-class (§6.3). Only the ESP-mount
convenience target is platform-specific.

## 2. What the user writes

```cmake
cmake_minimum_required(VERSION 3.25...4.4)
project(MyDesktop NONE)

include(FetchContent)
FetchContent_Declare(OCMake GIT_REPOSITORY https://github.com/<you>/OCMake GIT_TAG v0.1.0)
FetchContent_MakeAvailable(OCMake)
include(${ocmake_SOURCE_DIR}/OCMake.cmake)

# --- OpenCore itself. RELEASE/DEBUG follows CMAKE_BUILD_TYPE unless BUILD is given.
oc_opencore(VERSION 1.0.7)

# --- config.plist: hand-written base + layered edits
oc_config(config.plist)
oc_config_overlay(overlays/debug.plist   CONFIG Debug)      # deep-merged plist fragment
oc_config_set(Misc/Debug/Target  INTEGER 67 CONFIG Debug)   # keypath edits, typed
oc_config_set(Misc/Debug/AppleDebug BOOL ON CONFIG Debug)
oc_boot_args(APPEND -v debug=0x100 keepsyms=1 CONFIG Debug)
oc_secrets(secrets.plist)          # git-ignored; PlatformInfo/Generic/* etc. merged last

# --- kexts
oc_kext(Lilu          GITHUB acidanthera/Lilu          VERSION 1.7.1)
oc_kext(VirtualSMC    GITHUB acidanthera/VirtualSMC    VERSION 1.3.7
        KEXTS VirtualSMC SMCProcessor SMCSuperIO)             # pick from a multi-kext archive
oc_kext(WhateverGreen GITHUB acidanthera/WhateverGreen VERSION 1.7.0)
oc_kext(AppleALC      GITHUB acidanthera/AppleALC      VERSION 1.9.5)
oc_kext(NootedRed     GITHUB ChefKissInc/NootedRed     VERSION 0.8.10)  # tag is v0.8.10; handled
oc_kext(RestrictEvents GITHUB acidanthera/RestrictEvents VERSION latest) # resolved + pinned in lockfile
oc_kext(USBMap        PATH kexts/USBMap.kext)                    # local, committed
oc_kext(BrcmFirmware  URL https://.../x.zip SHA256 abcd... KEXTS BrcmFirmwareData BrcmPatchRAM3)

# Only genuinely irregular repos need a selector. itlwm ships per-macOS assets, no build variants:
oc_kext(AirportItlwm  GITHUB OpenIntelWireless/itlwm  VERSION latest
        ASSET "AirportItlwm_*_Sonoma14.4.kext.zip" MAX_KERNEL 23.99.99)

# --- ACPI
oc_ssdt(acpi/SSDT-EC-USBX.dsl acpi/SSDT-PLUG.dsl acpi/SSDT-AWAC.dsl)   # compiled with iasl
oc_acpi(acpi/SSDT-Vendor.aml)                                          # prebuilt

# --- drivers, tools, resources
oc_driver(OpenRuntime OpenCanopy ResetNvramEntry)   # from the OpenCore package
oc_driver(OpenHfsPlus)                              # also from the OpenCore package
oc_tool(OpenShell)
oc_resources(OcBinaryData AUDIO OFF IMAGE Acidanthera/GoldenGate FONT ON LABEL ON)

oc_efi()   # finalize: creates targets efi (ALL), validate, report; registers install rules
```

Every project also ships `CMakePresets.json`, copied verbatim from `presets/` (§3.8), so
the daily commands are:

```bash
cmake --workflow --preset release            # configure + build + validate, in one step
cmake --workflow --preset debug              # the same for the DEBUG variant
cmake --install build/release --prefix /Volumes/USB
cmake --preset offline                       # prove a fresh clone can build with no network
cmake --preset update                        # re-resolve and rewrite ocmake.lock
```

The underlying commands still work if you prefer them:

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release   # or Debug; both dirs can coexist
cmake --build build                             # -> build/EFI/{BOOT,OC}
ctest --test-dir build                          # ocvalidate + OCMake sanity checks
cmake --install build --prefix /Volumes/USB     # drop-in copy
cmake --build build --target install-esp        # mount internal ESP, back up, install
cmake --build build --target outdated           # table of pinned vs latest upstream versions
cpack --config build/CPackConfig.cmake          # MyDesktop-1.0.7-RELEASE.zip
```

## 3. Architecture

### 3.1 Repository layout of OCMake itself

```
OCMake/
  OCMake.cmake                 # entry point; includes cmake/*.cmake, defines the public API
  cmake/
    OCUtil.cmake               # logging, build-type mapping, the per-EFI data model (§3.7)
    OCLock.cmake               # ocmake.lock read/write, OC_UPDATE / OC_OFFLINE
    OCFetch.cmake              # download + extract with a shared cache
    OCResolve.cmake            # GitHub release resolution, asset selection (§3.4)
    OCOpenCore.cmake           # oc_opencore(): package layout, drivers/tools/ocvalidate lookup
    OCKext.cmake               # oc_kext() / oc_driver() / oc_tool()
    OCACPI.cmake               # oc_ssdt() / oc_acpi(), iasl discovery            [Phase 3]
    OCConfig.cmake             # oc_config*() / oc_boot_args() / oc_secrets()
    OCEFI.cmake                # oc_efi(): staging, install, cpack, report
    OCStage.cmake              # `cmake -P` script that rebuilds build/EFI from a manifest
  scripts/                     # Python 3 stdlib only (plistlib), no third-party deps
    oc_config.py               # apply overlays / keypath sets / boot-args / secrets / per-entry overrides
    oc_report.py               # BOM (markdown + json) from staged EFI
    oc_outdated.py             # GitHub releases query for `outdated`
  third_party/OCSnapshot/      # corpnewt/OCSnapshot, pinned commit (submodule or FetchContent)
  examples/minimal/            # a full working example, also used as the self-test
  tests/                       # CMake-driven tests (configure the example, run ctest)
```

Consumption: FetchContent (recommended), git submodule, or a plain copy + `include()`.

### 3.2 Pipeline

**Configure time** (runs on `cmake -B`):
1. Map `CMAKE_BUILD_TYPE` → `OC_BUILD` (`Release`→`RELEASE`, `Debug`→`DEBUG`).
   `-DOC_BUILD=DEBUG` overrides. Per-item `BUILD` overrides that.
2. Resolve every declared source to a URL via **one** resolver (§3.4): a single
   GitHub releases API call returns the tag *and* the asset list, from which the
   version, the build variant and any `ASSET` glob are all satisfied at once.
   `URL ... SHA256 ...` and `PATH ...` bypass it.
3. Download into `OC_CACHE_DIR` (default `~/.cache/ocmake`, shared across build dirs)
   with `file(DOWNLOAD EXPECTED_HASH ...)`; extract with `file(ARCHIVE_EXTRACT)` into
   `build/_oc/<name>/`. Hashes are read from / written to `ocmake.lock` (see §3.5).
4. Locate tools: `Python3::Interpreter` (3.9+), `iasl` (`-DOC_IASL` → PATH → Homebrew /
   `/usr/local` / `/usr/bin` → on macOS a pinned fallback download; see §6.4), and
   `ocvalidate` from the OpenCore zip —
   `Utilities/ocvalidate/{ocvalidate, ocvalidate.linux, ocvalidate.exe}`, all three
   verified present in 1.0.7.
5. Emit the staging manifest describing every file that must end up in `EFI/` and every
   per-entry override (MinKernel, Arch, Enabled, Comment...). Output location: the default
   (implicitly named) EFI builds to `build/EFI`; additional named EFIs build to
   `build/<name>/EFI`. Stated rather than magic — adding a second EFI never moves the first.

**Build time** (`cmake --build`), as an `add_custom_command` chain with stamp files:
1. `acpi`: `iasl -p build/_oc/acpi/<name>/<base> <src>.dsl` per SSDT, incremental.
   (Not `-tc`, as sketched earlier: that flag additionally emits a C hex dump next to
   the `.aml`. Plain `-p` writes only the table.)
2. `stage`: `cmake -P OCStage.cmake` **wipes and recreates** `build/EFI`.
   Always from scratch so removed kexts/SSDTs never linger. Strips `.DS_Store`,
   `__MACOSX`, keeps `_CodeSignature`. Copies `BOOT/BOOTx64.efi`, `OC/OpenCore.efi`,
   drivers, tools, kexts, `.aml`, resources, and OpenCore's `.contentFlavour` /
   `.contentVisibility` dotfiles.

   *Implemented in Phase 0, differing from the sketch above in two ways.* The staging
   manifest is a **generated CMake script** of `oc_stage_copy(src dst)` calls, not JSON:
   CMake→CMake needs no parsing at all, and JSON is reserved for the Python config step
   in Phase 2, which is a different consumer. And every staged file is declared as an
   `OUTPUT` of the custom command rather than only a stamp — with a stamp alone, deleting
   anything inside `build/EFI` leaves a half-empty tree that still looks up to date, which
   `cmake --install` would then copy onto a USB.
3. `config`: `scripts/oc_config.py` runs the layered edit on a copy of the base plist:
   overlays → `oc_config_set` ops → boot-args → then `OCSnapshot.py -i <tmp> -o <tmp> -s build/EFI/OC -f`
   → per-entry overrides from the manifest → secrets → write `build/EFI/OC/config.plist`.
   (Snapshot runs before overrides so that OCSnapshot's dependency ordering and plugin
   discovery apply, and overrides win. Because OCSnapshot preserves matched entries,
   hand-edits in the base plist for e.g. `MinKernel` survive when no CMake override exists.)
4. `validate`: `ocvalidate build/EFI/OC/config.plist` — a POST_BUILD warning by default,
   and a hard failure as a ctest test.
5. `report`: `BOM.md` / `BOM.json` next to `EFI/` listing OC version, build type,
   every kext with its `CFBundleShortVersionString`, every SSDT, driver, tool.

**Install time**:
- `install(DIRECTORY build/EFI DESTINATION .)` so `--prefix /Volumes/USB` yields
  `/Volumes/USB/EFI`. Permissions are not preserved (FAT32).
- `install-esp` target: `diskutil mount <ESP>` (auto-detect the ESP of the boot disk,
  overridable with `-DOC_ESP=disk0s1`), rename any existing `EFI` to
  `EFI.bak-<timestamp>` (opt-out with `-DOC_ESP_BACKUP=OFF`), then `cmake --install`.
- `diff-esp` target: dry-run listing of what would change on the ESP.

### 3.3 Why reuse OCSnapshot instead of generating entries ourselves

corpnewt/OCSnapshot is the standalone CLI extraction of ProperTree's OC Snapshot. It
already does the hard parts: schema per OC version (auto-detected by hashing
`OpenCore.efi` against `Scripts/snapshot.plist`), topological ordering of `Kernel.Add`
from `OSBundleLibraries`, plugin kexts (`Contents/PlugIns`), `ExecutablePath`/`PlistPath`
discovery, duplicate `CFBundleIdentifier` handling with kernel-range awareness, and
preserving `Enabled`/`Comment`/`MinKernel` on matched entries. Re-implementing that in
CMake would be the bulk of the project and would drift. It is vendored at a pinned commit
and only driven through its CLI (`-i -o -s -c -f -v`), so upgrades are a one-line bump.

One consequence: `snapshot.plist` must know the OC version in use. For a brand-new OC
release before OCSnapshot updates, pass `-v <version>` explicitly from `oc_opencore(VERSION)`
and fall back to `latest` schema with a warning.

### 3.4 The unified resolver — `latest`, build variants and asset globs are one problem

All three are answered by a single GitHub API call, because
`/repos/{owner}/{repo}/releases/{latest|tags/X}` returns the tag **and** the full asset
list in one response. Proven working in ~20 lines of pure CMake:

```cmake
function(oc_gh_resolve repo ref asset_regex out_ver out_url)
  if(ref STREQUAL "latest")
    set(api "https://api.github.com/repos/${repo}/releases/latest")
  else()
    set(api "https://api.github.com/repos/${repo}/releases/tags/${ref}")
  endif()
  file(DOWNLOAD "${api}" "${CMAKE_CURRENT_BINARY_DIR}/rel.json" STATUS st)
  file(READ "${CMAKE_CURRENT_BINARY_DIR}/rel.json" j)
  string(JSON tag GET "${j}" tag_name)
  string(JSON n LENGTH "${j}" assets)
  math(EXPR n "${n}-1")
  foreach(i RANGE ${n})
    string(JSON nm GET "${j}" assets ${i} name)
    if(nm MATCHES "${asset_regex}")
      string(JSON url GET "${j}" assets ${i} browser_download_url)
      set(${out_ver} "${tag}" PARENT_SCOPE)
      set(${out_url} "${url}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
endfunction()
```

**Resolution order for a `GITHUB` item.** Fetch the release; then pick the asset by,
in order: an explicit `ASSET` glob → `-<BUILD>.zip` → `-RELEASE.zip` (with a
configure-time note that no debug asset exists) → the sole asset if there is exactly
one → otherwise a hard error listing the available assets so the user can add `ASSET`.
Nobody writes `BUILD RELEASE` to work around a missing debug build; `BUILD` exists only
to *deliberately* pin a variant (e.g. always ship release Lilu inside a debug EFI).

**What a survey of real repos showed** (checked against the live API while writing this):

| Repo | Tag | Assets | Consequence |
|---|---|---|---|
| Lilu, VirtualSMC, WhateverGreen, AppleALC, RestrictEvents, USBToolBox | `1.7.2` | `{Name}-{ver}-{DEBUG,RELEASE}.zip` | The convention holds; zero config |
| ChefKissInc/NootedRed | `v0.8.10` | `…-DEBUG.zip`, `…-RELEASE.zip`, `…-RESEARCH_RELEASE.zip` | Tag carries `v`, filename does not — never build the filename from the tag, read it from the asset list. And **anchor the regex on `-RELEASE.zip$`**: an unanchored `RELEASE\.zip$` also matches `RESEARCH_RELEASE.zip` |
| OpenIntelWireless/itlwm | `v2.3.0` | 9 assets, per-macOS (`AirportItlwm_v2.3.0_stable_Sonoma14.4.kext.zip`), no build variants | This is the *only* shape that needs `ASSET`, and it needs it for OS targeting, not for debug/release |

So `ASSET` stays in the API, but as a rare escape hatch rather than routine ceremony.

### 3.5 Lockfile, cache and reproducibility

`ocmake.lock` (committed) records for each declared item: resolved URL, SHA256, and for
`latest` the concrete version. Rules:
- If an entry exists and the declaration hasn't changed, use it (no network, hash verified).
- If the declaration changed or no entry exists, resolve, download, record.
- `-DOC_UPDATE=ON` re-resolves everything. `-DOC_OFFLINE=ON` errors instead of downloading.
- The lock is keyed by `(name, version, build)`, so Release and Debug entries coexist.

This gives byte-for-byte reproducible EFIs from a clean checkout, which is what makes
CI builds and GitHub-Release zips trustworthy.

**What is cached, and where.** Three separate layers, none of them in the build directory:

| Layer | Location | Keyed by | Invalidated by |
|---|---|---|---|
| Archives | `OC_CACHE_DIR` (default `~/.cache/ocmake`) | asset filename | a mismatching SHA256; a `file://` source always refreshes |
| API responses | `OC_CACHE_DIR/api/<sha256 of URL>.json` | request URL | `OC_API_TTL`, default 600s |
| Extracted trees | `<build>/_oc/<name>/` | archive SHA256, in a stamp file | a changed archive hash |

Only the third lives in the build directory, so **deleting the build directory costs
re-extraction, not re-downloading and not a single API call** — provided the lockfile
covers the variant being configured. `-DOC_OFFLINE=ON` is the check for that: it makes any
required network access an error, so a clean-build-directory configure that succeeds under
it proves the lock and cache are complete. Local `file://` sources are exempt, since
reading a local file is not network access.

**A warm build therefore means:** lockfile hit → no API call; cached archive whose hash
matches the lock → no download; unchanged archive hash → no re-extraction.

**Both build variants are kept in the lock.** Entries are keyed by
`<name>|<version spec>|<build>`, and the flush retains any existing entry whose build
differs from the one being configured. Pruning everything unused looked tidy but broke the
side-by-side Release/Debug workflow §2 advertises: each configure deleted the other
variant's entries, so every switch re-resolved every item — twelve API calls per switch for
the b760i example. Entries for the *current* variant are still pruned, so removing a kext
still removes its line.

### 3.6 ESP install and recovery

**Scope.** In scope: breakage the user just introduced themselves — a bad quirk, a broken or
mis-ordered kext, a bad ACPI patch, a wrong `MinKernel`. Explicitly out of scope: disk corruption,
a failing ESP, firmware or NVRAM damage. OCMake is not a backup tool.

**Install.** `install-esp` mounts the ESP (auto-detecting the boot disk's, overridable with
`-DOC_ESP=`), optionally archives the EFI it is about to replace *off* the ESP as a restore copy
(`-DOC_ESP_BACKUP=ON`, default on), and copies the staged tree in. `diff-esp` dry-runs what would
change. The mount step is the only per-platform shim: `diskutil` on macOS, `mount`/`lsblk` on
Linux, `mountvol` on Windows.

**Recovery: keep a known-good EFI on a USB stick.** This is deliberately the whole story for now.
It is free — the same `cmake --install build --prefix /Volumes/USB` that already exists — and it
is the only approach that needs no NVRAM changes, no device paths and no untested behavior. It
works because on a separate volume the standard layout resolves against *that* filesystem:
`\EFI\BOOT\BOOTx64.efi` finds `\EFI\OC\OpenCore.efi` on the USB, not on the internal ESP.

The lockfile complements it: `git checkout` an older `ocmake.lock` and rebuild reproduces any
previous EFI byte-for-byte (§3.5), so rollback also exists in git, not just on a stick.

#### Deferred: on-ESP generations (researched, not building)

Keeping the previous EFI bootable *on the ESP itself* was considered and cut as premature. The
findings are recorded here so revisiting is cheap and does not need a second source dive — both
were read from OpenCore master:

- `Application/OpenCore/OpenCore.c` — `OpenCore.efi` derives its storage root from **its own load
  path** (`OcCopyDevicePathFullName` then `UnicodeGetParentDirectory`). Everything it reads —
  `config.plist`, `ACPI/`, `Kexts/`, `Drivers/`, `Tools/`, `Resources/` — is relative to that
  directory. So a copy at `\EFI\OC-prev\` *is* self-contained and would boot correctly **if
  launched directly**.
- `Application/Bootstrap/Bootstrap.c` — `BOOTx64.efi` is the opposite. It tries a relative rule
  (up two directories, then `OpenCore.efi`) and then falls back to a **hardcoded**
  `EFI\OC\OpenCore.efi`. So booting `\EFI-prev\BOOT\BOOTx64.efi` silently loads the **new**
  `\EFI\OC\OpenCore.efi` — the user gets the broken EFI believing they booted the backup.

Any future on-ESP rollback must therefore bypass the bootstrap and point at `OpenCore.efi`
directly — via a firmware boot entry (`bcfg` from OpenShell, the same mechanism as
`Misc.Boot.LauncherOption`/`LauncherPath`) or a `Misc.Entries` picker entry, whose `Path` takes an
unchecked device path. The picker route additionally needs a machine-specific device path and
means OpenCore chainloading OpenCore, which the documentation neither blesses nor forbids and
which would need hardware validation first. That combination of cost and uncertainty is what made
the USB the better answer at this stage.

### 3.7 Where declarations live: the multi-EFI data model

`oc_kext()` and friends are free functions that accumulate state, and `oc_efi()` consumes it.
*Where that state lives* is the one Phase 0 decision that is expensive to reverse, because every
public function's signature depends on it. The feature (several EFIs in one repo — an installer
stick and an internal EFI, or a desktop and a laptop sharing most of their kexts) can ship in
Phase 8, but the model cannot.

#### Option 1 — Global lists

State goes in global properties; `oc_efi()` drains the accumulator, so multiple EFIs are
sequential *batches*.

```cmake
oc_kext(Lilu GITHUB acidanthera/Lilu VERSION 1.7.2)
oc_kext(VoodooPS2 GITHUB acidanthera/VoodooPS2 VERSION 2.3.7)
oc_efi(NAME laptop)          # drains everything declared so far

oc_kext(Lilu GITHUB acidanthera/Lilu VERSION 1.7.2)   # must be repeated
oc_kext(NootedRed GITHUB ChefKissInc/NootedRed VERSION 0.8.10)
oc_efi(NAME desktop)
```

```cmake
function(oc_kext name)
  cmake_parse_arguments(A "" "GITHUB;VERSION" "KEXTS" ${ARGN})
  set_property(GLOBAL APPEND PROPERTY OC_PENDING_KEXTS "${name}")
  set_property(GLOBAL PROPERTY OC_PENDING_${name}_VERSION "${A_VERSION}")
endfunction()

function(oc_efi)
  cmake_parse_arguments(A "" "NAME" "" ${ARGN})
  get_property(kexts GLOBAL PROPERTY OC_PENDING_KEXTS)
  # ...generate manifest, add targets...
  set_property(GLOBAL PROPERTY OC_PENDING_KEXTS "")   # drain for the next batch
endfunction()
```

Sharing requires a `macro()` wrapper re-running the declarations, which works (downloads are
cached, so it is not wasteful) but is blunt. The real problems are ordering and silence: the
model is stateful, so a declaration placed after the last `oc_efi()` is silently dropped, and
two EFIs can never be described in interleaved or non-linear order. Global properties at least
survive `add_subdirectory()`, which plain variables would not without `PARENT_SCOPE` plumbing.

**Verdict:** cheapest to build, and the single-EFI case reads perfectly. Multi-EFI is bolted on,
and the silent-drop failure needs a deferred end-of-configure guard to be safe at all.

#### Option 2 — Per-target properties, always explicit

Each EFI is an INTERFACE library used purely as a typed property bag; every call names its EFI.

```cmake
oc_add_efi(laptop)
oc_add_efi(desktop)
oc_add_kext_group(base)

oc_kext(base    Lilu       GITHUB acidanthera/Lilu VERSION 1.7.2)
oc_kext(base    VirtualSMC GITHUB acidanthera/VirtualSMC VERSION 1.3.7)
oc_kext(laptop  VoodooPS2  GITHUB acidanthera/VoodooPS2 VERSION 2.3.7)
oc_kext(desktop NootedRed  GITHUB ChefKissInc/NootedRed VERSION 0.8.10)

oc_efi_use(laptop  base)     # composition, declared once
oc_efi_use(desktop base)
```

```cmake
function(oc_add_efi name)
  add_library(oc_${name} INTERFACE)     # arbitrary properties on INTERFACE libs: CMake 3.19+
  set_property(TARGET oc_${name} PROPERTY OC_IS_EFI TRUE)
endfunction()

function(oc_kext target name)
  set_property(TARGET oc_${target} APPEND PROPERTY OC_KEXTS "${name}")
endfunction()
```

No hidden state, order-independent, survives `add_subdirectory()`, and genuine composition:
a shared group is declared once and reused. CMake owns the lifetime, and each EFI gets its own
targets and install component for free.

The cost is real and lands on the majority: every single-EFI user repeats the EFI name on every
line, forever, to pay for a feature they do not use. For a hobbyist-facing tool that is the wrong
trade.

*Note:* the natural-looking `target_link_libraries(oc_laptop INTERFACE oc_base)` for transitive
composition does **not** work here. Link-graph traversal via `$<TARGET_PROPERTY:...>` resolves at
*generate* time, but OCMake resolves and downloads at *configure* time, so it needs the values
earlier than genexes can supply them. Hence the explicit `oc_efi_use()`, which merges property
lists immediately.

#### Option 3 — Per-target properties with a defaulted implicit EFI (recommended)

Option 2's data model, with the EFI argument optional. Omitted, it resolves to an implicit target
named after `PROJECT_NAME`; supplied via an `EFI` keyword, it targets that one; and `block()` sets
a scoped default so multi-EFI blocks need not repeat it per line.

```cmake
# Single-EFI users write exactly what §2 already shows — no target names anywhere:
oc_kext(WhateverGreen GITHUB acidanthera/WhateverGreen VERSION 1.7.0)

# A shared group:
oc_kext(Lilu       EFI base GITHUB acidanthera/Lilu VERSION 1.7.2)
oc_kext(VirtualSMC EFI base GITHUB acidanthera/VirtualSMC VERSION 1.3.7)

# A second EFI, name stated once:
block()
  set(OC_EFI laptop)
  oc_kext(AirportItlwm GITHUB OpenIntelWireless/itlwm VERSION latest)
  oc_kext(VoodooPS2    GITHUB acidanthera/VoodooPS2   VERSION 2.3.7)
endblock()

oc_efi_use(laptop base)
oc_efi_use(MyDesktop base)
```

Resolution is explicit `EFI` keyword → `OC_EFI` variable → `PROJECT_NAME`, with the target created
lazily on first use:

```cmake
function(_oc_target out explicit)
  if(explicit)
    set(n "${explicit}")
  elseif(DEFINED OC_EFI)
    set(n "${OC_EFI}")
  else()
    set(n "${PROJECT_NAME}")
  endif()
  if(NOT TARGET oc_${n})
    add_library(oc_${n} INTERFACE)
    set_property(GLOBAL APPEND PROPERTY OC_EFIS "${n}")
    _oc_schedule_finalize()          # once, guarded by a global flag
  endif()
  set(${out} "oc_${n}" PARENT_SCOPE)
endfunction()

function(oc_kext name)
  cmake_parse_arguments(A "" "EFI;GITHUB;VERSION" "KEXTS" ${ARGN})
  _oc_target(t "${A_EFI}")
  set_property(TARGET ${t} APPEND PROPERTY OC_KEXTS "${name}")
endfunction()
```

Because `block()` (3.25, our floor) scopes variables, `OC_EFI` cannot leak past `endblock()`, and
functions still see it through CMake's dynamic scoping. `add_subdirectory()` works the same way,
which is the natural layout when each EFI has its own config.plist and ACPI sources.

Finalization is deferred to end-of-directory rather than requiring a closing `oc_efi()`, which
deletes Option 1's silent-drop failure mode outright — there is no "after the last call" to fall
into. `oc_efi()` survives only as an optional way to pass per-EFI options.

**This was prototyped and configured successfully** (CMake 4.4.2, three EFIs incl. one shared
group, implicit default, `block()` scoping, composition, and auto-finalize). Two findings worth
recording, both of which cost a debugging cycle:

- **`cmake_language(DEFER ... CALL f "${n}")` evaluates its arguments when the deferred call
  *executes*, not when it is scheduled.** A function-local `${n}` is long gone by end-of-directory,
  so every deferred call received an empty argument and failed on `TARGET oc_`. The fix is to defer
  a single **no-argument** finalizer that walks a `GLOBAL` registry of EFI names. That also means
  scheduling once instead of per-target, so the registry is not avoidable global state — but it
  holds only target *names*, never declarations.
- **Groups must be distinguished from EFIs** (`OC_IS_GROUP` vs `OC_IS_EFI`), or the finalizer
  happily tries to build `base` into an EFI folder of its own.

#### Comparison

| | 1. Global lists | 2. Per-target, explicit | 3. Per-target + implicit default |
|---|---|---|---|
| Single-EFI ergonomics | Best | Worst (name on every line) | Best (identical to option 1) |
| Multi-EFI ergonomics | Poor (batches, re-declaration) | Best | Best |
| Sharing between EFIs | `macro()` re-run | First-class group | First-class group |
| Order-dependent | Yes | No | No |
| Silent-drop failure | Yes, needs a guard | No | No (deferred finalize) |
| `add_subdirectory()` | Works via GLOBAL props | Natural | Natural |
| Implementation cost | Lowest | Medium | Medium (+ resolution rule) |
| Retrofittable later | No — signature change | n/a | n/a |

**Recommendation: option 3.** It costs one small resolution helper over option 2 and gives
single-EFI users exactly the option 1 syntax — the §2 example needs no target names at all. The
decisive point is that this is the only choice that does not force a future signature break: the
`EFI`/`OC_EFI` plumbing goes in during Phase 0, the group and multi-EFI *features* can wait for
Phase 8, and nothing user-facing changes when they land.

### 3.8 CMakePresets.json

`presets/CMakePresets.json` is copied verbatim into every project. Presets version 6, which
is exactly the CMake 3.25 floor — the version that introduced workflow presets.

| Preset | What it is for |
|---|---|
| `release` | The EFI you boot |
| `debug` | DEBUG OpenCore, kexts and drivers, plus `CONFIG Debug` edits |
| `offline` | Release with `OC_OFFLINE=ON` — fails unless `ocmake.lock` and the cache are complete |
| `update` | Release with `OC_UPDATE=ON` — re-resolves everything and rewrites the lock |

What this buys beyond defaulting the generator:

- **Ninja is the default, demonstrably.** Not a recommendation in a README — the preset
  sets it, so nobody accidentally gets the Makefile generator and its second-granularity
  mtime behavior (§6.5).
- **IDEs stop asking.** VS Code CMake Tools, CLion and Visual Studio all read presets, so
  there is no kit to pick and no build directory to invent.
- **`binaryDir` is `build/${presetName}`**, so Release and Debug coexist by construction
  rather than by the user remembering to use two directories. That is the workflow §2
  advertises and the reason the lockfile now keeps both variants (§3.5).
- **`offline` turns a documented property into a runnable check.** "A fresh clone builds
  with no network" stops being a claim and becomes one command — useful in CI, and the
  fastest way to notice a lockfile that has gone stale.
- **`installDir` is `dist/${presetName}`**, so `cmake --install build/release` with no
  `--prefix` lands somewhere sensible for inspection; `--prefix /Volumes/USB` still wins.
- **Workflow presets** collapse configure + build + validate into one command, which is
  also exactly what CI runs.
- **`CMakeUserPresets.json`** is the escape hatch: it is git-ignored by convention, so a
  user can add machine-local presets (an ESP path, a `GITHUB_TOKEN`-bearing environment,
  a different cache directory) without touching the committed file.

`noTestsAction: ignore` is set on the test presets so the workflows work before Phase 5
adds any tests.

Consumers cannot use presets' `include` field to point at OCMake's copy, because with
FetchContent the OCMake source directory does not exist until configure time — hence
copying rather than including. A `presets` test asserts the copies have not drifted.

## 4. Feature list (your 1–4 plus the blanks)

1. **No structured EFI in the repo.** Repo holds `CMakeLists.txt`, `config.plist`, `acpi/*.dsl`,
   optional local kexts, overlays, lockfile. Everything else is fetched.
2. **Kext management.** Declarative, pinned, hashed, cached, multi-kext archives, plugin kexts,
   local kexts, arbitrary URLs. Load order from `OSBundleLibraries` automatically; `DEPENDS`
   only needed to force order when metadata is missing.
3. **Release/Debug switch.** `CMAKE_BUILD_TYPE` picks OC + drivers + tools + every kext's
   build variant, and applies the Debug overlay / boot-args to config.plist. A missing
   debug asset falls back to release automatically, noted at configure time and in the BOM —
   no per-kext declaration needed (§3.4).
4. **ACPI in one step.** `.dsl` compiled by iasl, incremental, placed and registered.
   Prebuilt `.aml` supported. Compile errors surface as build errors with iasl's output.
5. **Secrets out of the repo.** Serial, MLB, ROM, SystemUUID (and anything else) live in a
   git-ignored `secrets.plist` or env vars (`oc_config_set(... ENV OC_SERIAL)`), merged last.
   The committed config.plist becomes shareable.
6. **Validation as tests.** `ctest` runs: ocvalidate; "every declared kext ended up in
   Kernel.Add and is Enabled"; duplicate bundle identifiers; `MinKernel`/`MaxKernel` sanity;
   Lilu plugins after Lilu; on an OC version bump, a diff of top-level keys in config.plist
   against the new `Docs/Sample.plist` to flag added/removed keys.
7. **Lockfile + offline + reproducible builds** (§3.5), which is what makes
   `VERSION latest` safe rather than a footgun.
8. **Bill of materials.** `BOM.md` generated each build, suitable for pasting in the README
   or attaching to a release.
9. **Packaging.** CPack zip `MyDesktop-<OC version>-<BUILD>.zip` containing `EFI/` and `BOM.md`.
10. **CI.** A reusable GitHub Actions workflow: ubuntu runner, `apt install acpica-tools`,
    `ocvalidate.linux` from the OC package, Python 3. Builds Release and Debug, runs ctest,
    uploads zips, publishes on tag. Everything in the pipeline is Linux-clean on purpose.
11. **`outdated` target.** Queries GitHub for each pinned `GITHUB` item and prints a table of
    pinned vs latest. Read-only, never edits declarations.
12. **Multiple EFIs per repo.** `oc_efi(NAME laptop)` / `oc_efi(NAME installer)` scopes:
    declarations between two `oc_efi()` calls (or an explicit `EFI laptop` argument) belong
    to that EFI. Each gets its own `EFI-<name>/`, targets and install component. Use cases:
    installer stick vs installed system, two machines sharing a kext set.
13. **ESP helpers.** `install-esp` with ESP detection and an off-ESP backup of the replaced tree,
    plus `diff-esp` (§3.6). Recovery is a known-good EFI on a USB, which the same `install` rule
    already produces; combined with the lockfile, any past EFI is reproducible from git.
14. **Alternate sources.** `URL`+`SHA256`, `PATH`, `GIT` (for repos that commit built kexts),
    and a `DORTANIA` source for the Dortania build repo nightlies.
15. **Kexts from source** (later). `oc_kext(... SOURCE_GITHUB owner/repo TAG ...)` wraps
    `xcodebuild` with MacKernelSDK + Lilu debug kext via ExternalProject. macOS-only, opt-in.
16. **Vaulting** (later). `oc_vault(ON KEY vault.key)` runs the OpenCore `CreateVault`
    utilities after the config step so `vault.plist`/`vault.sig` match the final files.

## 5. Implementation phases

Each phase ends with the example project building and its tests passing.

**Phase 0 — Skeleton (foundation). — DONE**
`OCMake.cmake` entry, module split, `oc_opencore()`, `oc_efi()` producing `EFI/BOOT` +
`EFI/OC/OpenCore.efi` only, `stage.cmake`, `install()` rule, `examples/minimal`.
Decisions locked here: CMake floor 3.25, Python floor 3.9, configure-time fetching,
cache dir, and the per-EFI interface-target data model (§3.7) — the `EFI` keyword and `OC_EFI`
resolution go in now even though multi-EFI is a Phase 8 feature, because they are a signature
change later.

**Phase 1 — Resolver + lockfile. — DONE**
`oc_gh_resolve()` (§3.4) with asset selection and debug fallback, the download/extract cache,
and `ocmake.lock` read/write with `OC_UPDATE`/`OC_OFFLINE`. Moved here from the old Phase 5:
it is ~100 lines total, everything downstream depends on it, and building it late would mean
writing a throwaway URL-construction path first. `VERSION latest` works from day one because
the lockfile pins it.

**Phase 2 — Kexts + snapshot (MVP). — DONE**
`oc_kext()` with `GITHUB`/`PATH`/`URL`, multi-kext `KEXTS`, `MIN_KERNEL`/`MAX_KERNEL`/`ARCH`/
`ENABLED`/`COMMENT` overrides. Vendor OCSnapshot. `oc_config()` + the config step
(base → snapshot → overrides). `oc_driver()`/`oc_tool()` from the OC package. At the end of
this phase the tool is already useful: hand-written config + declared kexts → complete EFI.

**Phase 3 — ACPI. — DONE**
`oc_ssdt()`/`oc_acpi()`, iasl discovery and fallback download, incremental compile,
error reporting.

**Phase 4 — Release/Debug and config layering. — DONE**
`OC_BUILD` mapping, per-item `BUILD`, debug-asset fallback, `oc_config_overlay()`,
`oc_config_set()` (typed keypaths, `/`-separated so NVRAM GUID keys work), `oc_boot_args()`,
`oc_secrets()`, `CONFIG <type>` filter on all of them.

**Phase 5 — Validation and reporting. — DONE**
ocvalidate discovery, `validate` target + ctest, the OCMake sanity checks listed in §4.6,
`report` target with `BOM.md`/`BOM.json`, Sample.plist key-drift check.

**Phase 6 — Install ergonomics, packaging, `outdated`.**
`install-esp` with per-platform ESP detection and off-ESP backup, `diff-esp`, CPack zip,
`oc_resources()` with OcBinaryData filtering (audio is large; default off), `outdated`
(trivial now — it is the Phase 1 resolver run in report-only mode).

**Phase 7 — CI and docs.**
Reusable workflow, README with the API reference, `examples/` for a desktop and a laptop,
self-tests in `tests/` — the matrix runs macOS, Linux **and Windows**, on both the CMake
floor (3.25) and current (4.4).

**Phase 8 — Stretch.**
Multiple `oc_efi()` scopes, `DORTANIA`/`GIT` sources, build-from-source kexts, vaulting.

## 6. Key design decisions

### 6.1 Decision table

| Question | Recommendation | Why |
|---|---|---|
| Fetch at configure or build time? | Configure time, FetchContent-style | Simple, cached, version changes force reconfigure anyway; build stays offline-safe |
| Build type via `CMAKE_BUILD_TYPE` or custom var? | `CMAKE_BUILD_TYPE` mapped, `OC_BUILD` override | Familiar; IDEs and presets already understand it; two build dirs side by side |
| Generate `Kernel.Add` ourselves or via OCSnapshot? | OCSnapshot, pinned | See §3.3; avoids reimplementing schema/ordering logic |
| Rebuild `EFI/` incrementally or from scratch? | From scratch each build | Only correct way to propagate deletions; the folder is small |
| Where do per-kext options live? | CMake declaration wins; hand edits in config.plist survive otherwise | Keeps config.plist authoritative except where the user chose to declare in CMake |
| Keypath separator for `oc_config_set` | `/` | NVRAM GUID keys contain `-` and dots would be ambiguous |
| Python or pure CMake for plist work? | Python (stdlib `plistlib`) | CMake cannot round-trip binary/XML plists; OCSnapshot needs Python anyway |
| Single-file `OCMake.cmake` or a directory? | Directory, consumed via FetchContent | Vendoring OCSnapshot + Python helpers is impossible in one file without embedding blobs |
| Construct asset URLs or read the asset list? | Read the list from the API | Tags and filenames disagree (`v0.8.10` → `NootedRed-0.8.10-…`); construction silently 404s |
| Is `VERSION latest` worth it? | Yes, from Phase 1 | ~20 lines on top of the resolver that must exist anyway; the lockfile removes the reproducibility objection |
| CMake floor | 3.25, range `3.25...4.4` | Nothing in 4.x is needed (§6.2); a high floor only excludes CI and distro CMake |
| Python floor | 3.9 | 3.13's plistlib addition is `aware_datetime`, irrelevant to config.plist (§6.2); OCSnapshot targets old Pythons |

### 6.2 Toolchain floors: why not CMake 4.x and Python 3.13

**CMake — floor 3.25, developed and CI-tested against current (4.4.x).**
Everything OCMake needs landed years ago: `file(ARCHIVE_EXTRACT)` 3.18, `string(JSON)` 3.19,
`cmake_path()` 3.20, `block()`/`return(PROPAGATE)` 3.25. I checked the 4.x notes for anything
that would change the design: 4.0 is a *removal* release (drops compatibility below 3.5 —
irrelevant to a new project) and 4.2 adds VS 18/FASTBuild generators, file-API fields,
`cmake_language(TRACE)`, `set(CACHE{...})`, `string(REGEX QUOTE)` and a CPack AppImage
generator. Nothing touches `file(DOWNLOAD)`, `string(JSON)`, presets, `install()` or custom
commands. The one mildly relevant 4.2 addition is `cmake -E copy_directory_if_newer`, and the
staging step deliberately wipes and rebuilds instead (§6 table), so even that is unused.

Raising the floor would therefore buy nothing while excluding distro CMake (Ubuntu 24.04
ships 3.28) and every CI image that has not caught up — which matters precisely because CI is
one of the reasons you picked CMake. Use `cmake_minimum_required(VERSION 3.25...4.4)`: the
range form keeps the low floor while opting into modern policy behavior, so there is no
"stuck on old semantics" cost either.

**Python — floor 3.9, tested on current.**
The plistlib changes you spotted do not help here. Reading the docs: 3.13 adds exactly one
thing, the keyword-only `aware_datetime` parameter on `load`/`loads`/`dump`/`dumps` (plus
`loads()` accepting `str` for XML input). `aware_datetime` governs whether `<date>` values
come back as timezone-aware `datetime` objects — and an OpenCore `config.plist` contains no
date fields at all. The substantive plistlib work was 3.4 (binary format, current API), 3.8
(`UID` for NSKeyedArchiver) and 3.9 (old API removed); 3.9 is the real floor because it is
where the API we use became the only API. Everything we need — binary and XML round-trip,
`<data>`, `<integer>` — has been stable since 3.4.

There is also a hard constraint pointing the same way: OCSnapshot must run under whatever
interpreter we require, and it targets old Pythons deliberately. Requiring 3.13 would gain
zero features and risk breaking the one dependency that matters.

### 6.3 Windows support

Windows is in, and the survey found only one genuine blocker — which is not in the core:

| Piece | Windows status |
|---|---|
| `plistlib` | Pure-Python stdlib, identical behavior on all platforms |
| OCSnapshot | Ships `OCSnapshot.bat`; stdlib-only Python |
| `ocvalidate` | **`ocvalidate.exe` confirmed present** in `Utilities/ocvalidate/` of OpenCore 1.0.7, alongside the macOS and `.linux` builds (as are `acdtinfo.exe`, `ocpasswordgen.exe`, `disklabel.exe`) |
| `iasl` | acpica.org publishes Windows binaries; MaciASL's is macOS-only, so the fallback download is per-platform |
| Download / extract / stage | `file(DOWNLOAD)`, `file(ARCHIVE_EXTRACT)`, `cmake -E` — all cross-platform |
| Kext bundles | Plain directories; extract and copy fine on NTFS/FAT32 |
| `install --prefix E:/` | Works; FAT32 has no permission bits to preserve on any platform |
| **ESP mounting** | The only divergence: `diskutil` (macOS) vs `mountvol`/`diskpart` (Windows) vs `mount`/`lsblk` (Linux) |

So `install-esp` becomes a thin per-platform shim behind one target name, and everything else
is shared. Two Windows-specific cautions to handle in the staging step: paths near the 260-char
`MAX_PATH` limit (kext plugin bundles nest deeply — use extended-length paths or keep the build
dir shallow), and avoiding symlink creation, which needs Developer Mode or elevation.

Practically, Windows users are also the ones who most need this: no Xcode, no ProperTree muscle
memory, and OpenCore EFIs are frequently assembled from a Windows machine.

### 6.4 The ACPI compiler

`iasl` is found in this order: `-DOC_IASL=<path>`, then `PATH`, then `/opt/homebrew/bin`,
`/usr/local/bin`, `/usr/bin`. A missing one is fetched once into `OC_CACHE_DIR`, pinned by
tag and SHA256:

| Platform | Fallback | Notes |
|---|---|---|
| macOS | MaciASL `Dist/iasl-stable` @ 1.6.5 | Universal binary; covers Apple silicon and Intel |
| Windows | open-acpica/acpica release asset `iasl` @ 20260408 | See the naming trap below |
| Linux | none — install `acpica-tools` | No prebuilt binary is published anywhere |

**The naming trap.** In open-acpica/acpica releases the asset called plain `iasl` is the
**64-bit Windows** build, and `iasl.exe` is the 32-bit one. Verified with `file(1)`: both
are PE, and the same holds for `acpidump`, `acpixtract` and `acpibin`. An extensionless
name on a GitHub release reads like a Unix binary and is not one, so the Windows fallback
downloads `iasl` and stores it as `iasl-acpica-<tag>.exe`.

Linux is the one platform with no prebuilt binary from anyone, which is also the platform
where it matters least: every distro packages it. `oc_acpi()` needs no compiler at all, so
a project shipping only prebuilt tables is unaffected everywhere.

### 6.5 Generators: why Make is still supported

Make caused three test failures across Phases 2 and 3, so retiring it in favour of
Ninja-only was considered and rejected.

The decisive point is that **OCMake cannot actually prevent it.** Choosing a generator is
the user's call and CMake's job; OCMake emits no generator-specific code (a grep for
`ninja`/`makefile`/`CMAKE_GENERATOR` across `cmake/`, `scripts/` and `OCMake.cmake` returns
nothing). "Dropping support" could only mean erroring out unless `CMAKE_GENERATOR` is
Ninja — hostile to anyone whose IDE or distro defaults otherwise — or, more likely, simply
not testing it. That trades three known quirks for unknown breakage.

The measured cost of keeping it is three `cmake -E sleep 1.1` calls in tests, and nothing
in the shipped code. The measured benefit is that Make surfaced a real property of the
build graph that Ninja hides: **Make compares mtimes at second granularity and treats
equal timestamps as up to date.** That is not only a test artifact — a user editing a
`.dsl` and rebuilding inside the same second can get a stale `.aml`. Ninja's finer
timestamps mask it. Testing both generators is what makes that visible at all.

So: Ninja is the recommended generator and what the docs use, Make stays in the test
matrix, and the mtime caveat is documented rather than papered over.

## 7. Risks and open points

- **OCSnapshot CLI stability.** Licensing is settled: the repo is **BSD 3-Clause**, so vendoring
  is fine with attribution (keep its LICENSE in `third_party/`). Remaining risk is CLI drift —
  pin a commit, drive it only through the documented flags (`-i -o -s -v -c -f`), and prefer a
  post-processing step in `oc_config.py` over patching it.
- **Schema lag.** New OpenCore releases precede `snapshot.plist` updates. Mitigated by passing
  `-v` explicitly and warning; ocvalidate remains the ground truth.
- **Inconsistent third-party release layouts.** Handled with `ASSET`, `KEXTS`, and `SUBDIR`;
  worst case `URL`+`SHA256`. The asset-matching regex must be anchored (`-RELEASE\.zip$`), or
  NootedRed's `RESEARCH_RELEASE.zip` matches a plain `RELEASE` pattern — a real bug the survey
  caught, and a regression test on day one.
- **GitHub API rate limits.** 60 requests/hour unauthenticated, and the resolver now runs for
  every `GITHUB` item rather than only for `latest`. Mitigated three ways: the lockfile means a
  warm build makes *zero* API calls; responses are cached in `OC_CACHE_DIR` with a short TTL so
  one reconfigure loop does not re-query; and `GITHUB_TOKEN`/`GH_TOKEN` is honored when set
  (CI always has one). A rate-limit response must produce a clear diagnostic, not a confusing
  JSON parse error — worth an explicit test.
- **Do not grow an on-ESP rollback by accident.** It is cut deliberately (§3.6). If it comes
  back, the hardcoded `EFI\OC` fallback in the bootstrap is a correctness trap, not a detail.
- **Binary plist vs XML output.** Always write XML; OpenCore reads both, diffs stay readable.
- **iasl versions** differ in strictness; document `-DOC_IASL=/path` and pin the fallback
  download.
- **FAT32 install quirks.** No permission bits, case-insensitive names; `install()` must not
  fail on `chmod`. On Windows, also watch `MAX_PATH` and avoid symlinks (§6.3).
- **Multiple `oc_efi()` scoping** — resolved in §3.7: per-target properties with a defaulted
  implicit EFI, prototyped and working. The plumbing lands in Phase 0; the feature can wait.

## 8. First concrete steps

1. Create the layout in §3.1 with empty modules and `examples/minimal`.
2. Add OCSnapshot as a submodule at a pinned commit; verify `OCSnapshot.py -h` runs with stdlib Python.
3. Implement `oc_opencore()` + `oc_efi()` + `stage.cmake` until `cmake --build` yields a bootable
   two-file EFI and `cmake --install --prefix` copies it.
4. Implement `oc_gh_resolve()` + the cache + `ocmake.lock` (§3.4 — the prototype in that section
   already runs against the live API; harden the asset-regex anchoring and add the rate-limit
   diagnostic).
5. Implement `oc_kext(GITHUB ...)` for Lilu and VirtualSMC, then the config step. Boot-test
   the result on real hardware once, before adding anything else.

A note on sequencing: steps 3–5 are the whole risk of the project. Everything after them is
additive and independently useful, so if the config pipeline turns out to fight OCSnapshot, that
is known within days rather than after the ACPI and packaging work is sunk.

## 9. Implementation log

### Phase 0 — done

Delivered: `OCMake.cmake`, `cmake/{OCUtil,OCFetch,OCOpenCore,OCEFI,OCStage}.cmake`,
`examples/minimal`, `examples/b760i-aorus-pro` (reference material, not yet buildable),
and a two-test suite. `cmake --build` stages `EFI/{BOOT,OC}`; `cmake --install --prefix`
copies it. Verified on Ninja and Unix Makefiles.

What the implementation changed about the design:

- **Staging manifest is generated CMake, not JSON** (§3.2). CMake→CMake needs no parsing;
  JSON is deferred to Phase 2 where Python is the consumer.
- **Staged files are declared build outputs, not just a stamp** (§3.2). Caught by the
  end-to-end test: with a stamp alone, deleting a file inside `build/EFI` left the build
  reporting success over a broken tree that `cmake --install` would happily ship.
- **`file(COPY)` preserves source timestamps**, so staged kexts would inherit the release
  zip's build date, read as older than the freshly generated manifest, and restage the
  whole tree on every build. `OCStage` touches after copying. Note `file(COPY_FILE)` does
  *not* preserve them, so only the directory path is affected — the touch on the file path
  is kept anyway rather than relying on undocumented behavior.
- **`.contentFlavour` / `.contentVisibility` exist in both `EFI/BOOT/` and `EFI/OC/`** of
  the release package and are easy to lose in a naive copy; staging handles them explicitly.
- **`OpenHfsPlus.efi` ships inside the OpenCore package**, not OcBinaryData — §2 corrected.
- **`cmake_language(DEFER ... CALL f "${x}")` evaluates arguments at execution time**, as
  §3.7 predicted; the shipped code defers one no-argument finalizer over a global registry.

Tests (`ctest`): `stage` is network-free and covers rename-on-copy for files and
directories, `.DS_Store` exclusion, dotfile preservation, wipe-and-rebuild removing stale
files, the directory-timestamp guard, and a hard error naming a missing source.
`example.minimal` configures, builds, installs, restores a deleted output, and asserts a
no-op rebuild does no work. Both regression guards were verified to actually fail when
their fix is reverted.

Known gaps, deliberate: no lockfile (Phase 1 — `oc_opencore` constructs the asset URL
directly and `SHA256` is optional), no config.plist, kexts, ACPI or drivers, so the staged
tree is **not bootable yet**.

### Phase 1 — done

Delivered: `cmake/OCLock.cmake` and `cmake/OCResolve.cmake`. `oc_opencore()` now resolves
through the GitHub API and records the result in `ocmake.lock`; `VERSION latest` works and
stays reproducible because the lock pins the resolved version. `oc_require_package()` is the
single entry point kexts will reuse in Phase 2.

Lock design: the key is `<name>|<version spec>|<build>` (plus the ASSET glob when given) and
the value records the **resolved** version, URL and sha256. Keeping the spec in the key and
the resolution in the value is what lets `latest` be both convenient and reproducible.
Entries are pruned to those actually used, and sorted, so the file stays diffable.

What the implementation changed or uncovered:

- **`file(DOWNLOAD)` discards the response body on an HTTP error**, so GitHub's JSON
  `{"message": ...}` is unavailable for diagnostics. The status code is recovered from the
  transfer `LOG` instead (`HTTP/1.1 404 Not Found`). The log is never printed: it contains
  the `Authorization` header.
- **Explicit `SHA256` was silently ignored** unless an explicit `URL` was also given. Fixed:
  a user pin now outranks both the lock and the resolver.
- **"Not in the cache" was the wrong diagnostic** when the archive *was* cached with a
  different hash — it sends the user hunting the wrong problem. Split into two messages, and
  the mismatch one names both hashes and points at `-DOC_UPDATE=ON`.
- **CMake's regex engine has no `{n}` repetition** (`[0-9a-f]{64}` never matches), and
  **`message()` output is wrapped at arbitrary widths**, so any assertion on an error string
  must normalise whitespace first. Both bit the tests; `assert_matches()` now handles the latter.
- **Test vacuity, again.** The RESEARCH_RELEASE guard passed even with the anchor removed,
  because `-RELEASE.zip` happens to precede `-RESEARCH_RELEASE.zip` in that release's asset
  list — the same luck the original §3.4 prototype had. Asset order is upload order, so a
  fixture with the adversarial ordering was added; it now fails without the anchor.

Tests (5, `ctest`): `stage`, `resolve` and `http` need no network. `resolve` covers glob-to-regex
escaping, the RESEARCH_RELEASE trap in both orderings, DEBUG selection, debug→release
fallback, sole-asset selection, ASSET globs against itlwm's per-OS assets, and the ambiguity
error listing what was available. `resolve.live` makes three API calls to verify the
tag-vs-version `v` prefix retry against the real NootedRed release and that `latest`
resolves. `example.minimal` adds cold resolution, lockfile stability across configures, a
warm `OC_OFFLINE=ON` configure making zero API calls, and a tampered lock hash being
rejected with the right message.

`http` closes what was briefly a gap. 401/403/429 cannot be provoked against real GitHub
without burning the rate limit, so `tests/stub_api.py` serves them from an ephemeral local
port and runs the CMake driver against it. It covers: 200 parsing; 404 being returned to the
caller rather than raised (which `_oc_gh_release` depends on for its v-prefix retry); the
403 message differing with and without a token; 429; 401; and the TTL cache serving a repeat
request without touching the server.

Two things only the stub could test, both now guarded:

- **The `Authorization` header is really sent.** The stub echoes what it received, so the
  test asserts `Bearer <token>` rather than trusting the code path.
- **The token never reaches an error message.** `file(DOWNLOAD)`'s `LOG` contains the
  `Authorization` header, so surfacing it on failure would print the user's credential.
  Verified by reverting the fix: the test fails when the log is interpolated into the 401.

One design note the stub made explicit: the API response cache is keyed by URL alone, not by
URL+token. That is deliberate — release metadata is public, so replaying a tokenless 200 is
correct, and an unauthenticated request against a private repo 404s, which is never cached.
It does mean a test asking "was the header sent?" must start from a cold cache.

### Phase 2 — done

Delivered: `cmake/OCKext.cmake` (`oc_kext`, `oc_driver`, `oc_tool`), `cmake/OCConfig.cmake`,
`scripts/oc_config.py`, and OCSnapshot vendored under `third_party/` (BSD-3-Clause, so
vendoring is fine with attribution — its LICENSE is kept alongside).

**The b760i example now reproduces the reference EFI.** `Kernel.Add` matches the
hand-built original exactly — same 18 entries in the same order, including OCSnapshot's
dependency ordering and the two plist-only injectors with empty `ExecutablePath` — and
`UEFI.Drivers` matches too. Only ACPI is absent, which is Phase 3.

§3.3's assumptions about OCSnapshot were confirmed against the real EFI: it prunes entries
whose bundle is gone *and* preserves `Enabled`/`Comment`/`MinKernel` on matched ones, so
`-c` is not needed and hand edits in the base plist survive.

What the implementation uncovered:

- **OCSnapshot refuses to run without the standard OC subdirectories** ("Incorrect OC
  Folder Structure"), even empty ones. The OpenCore package ships `ACPI/`, `Drivers/`,
  `Kexts/`, `Resources/` and `Tools/` as empty directories; staging now recreates them.
- **OCSnapshot exits 0 on some failures** — `-s /nonexistent` prints an error and returns
  success — so its exit status cannot be trusted. `oc_config.py` verifies the output
  instead: the four managed sections must exist, and `Kernel.Add` must match the kexts
  actually staged on disk.
- **Its `-v` flag selects the schema, and an unrecognised version picks the *oldest* one**,
  in which `UEFI.Drivers` is a list of bare strings — after which it crashes on entries it
  expects to be dicts. The flag is now passed only for a plausible `X.Y.Z`; otherwise it
  auto-detects from the binary.
- **`file(GLOB_RECURSE)` anchors the directory part of its pattern.** Searching with
  `"${root}/*/Contents/Info.plist"` silently found nothing in archives that nest bundles
  one level deeper (VirtualSMC ships `Kexts/*.kext`). A bare filename pattern recurses
  properly.
- **`if(<var> STREQUAL "")` compares against the literal token text when the variable is
  undefined.** `if(NOT A_PATH STREQUAL "")` was therefore true for an unset `A_PATH`,
  sending every kext down the local-`PATH` branch, where an empty path resolved to the
  project root and swept up every bundle in the source tree. All such comparisons now
  quote-dereference: `if(NOT "${A_PATH}" STREQUAL "")`.
- **`if(NOT A_NAME)` is wrong for user-supplied strings**, because `N`, `NO`, `OFF`,
  `FALSE` and `IGNORE` are CMake false constants. A test that happened to name a kext `N`
  exposed it; that name is now a deliberate test case.

Tests (6, `ctest`): `phase2` is network-free — `tests/make_fixture.py` builds a fake
OpenCore package and kext archives served over `file://` URLs. It covers both archive
layouts, `KEXTS` selection, local `PATH` bundles, per-entry overrides, dependency ordering,
drivers/tools coming only from what was declared, the empty-directory requirement, pruning
a dropped declaration from both the tree and config.plist, and six error paths with their
diagnostics.

### Phase 3 — done

Delivered: `cmake/OCACPI.cmake` with `oc_ssdt()` (compiled) and `oc_acpi()` (prebuilt),
iasl discovery with a macOS fallback, and incremental recompilation.

**The b760i example now reproduces the reference EFI completely.** All four file-derived
sections match — `ACPI.Add`, `Kernel.Add`, `UEFI.Drivers`, `Misc.Tools` — and both
prebuilt tables are byte-identical to the originals.

What the implementation uncovered:

- **The `-tc` flag in the original sketch was wrong.** It emits a C hex dump alongside the
  table, which would have been staged into `EFI/OC/ACPI/`. Plain `-p` writes only the `.aml`.
- **iasl's exit code is trustworthy** — 255 on a compile error, 0 on success — unlike
  OCSnapshot. Its diagnostics go to *stdout*, though, so the test helper had to capture
  both streams to assert on them.
- **acpica.org publishes no macOS or Linux binaries** (contrary to §3.2's original claim,
  now corrected). The fallback is MaciASL's committed `Dist/iasl-stable`, pinned by tag and
  SHA256 — a universal binary covering Apple silicon and Intel. Elsewhere OCMake refuses
  with per-platform install instructions rather than pretending it can fetch one.
- **`get_filename_component(... NAME_WE)` cuts at the *first* dot**, mangling names like
  `SSDT-XHC.1.dsl`. Stripping one trailing extension by regex is correct.
- **Upstream samples should be compiled in place, not copied in.** `oc_ssdt(SAMPLES <name>)`
  compiles straight out of the OpenCore package's `Docs/AcpiSamples/Source/`, which is
  already on disk. The b760i example keeps only the two tables that genuinely cannot be
  fetched. Committing a copy of an unmodified upstream file is the clutter §1 exists to remove.
- **The download cache is keyed by filename, so without a SHA256 a changed source at the
  same URL is invisible.** Harmless for release assets, which are immutable per URL, but
  wrong for a `file://` source a developer edits between configures — the fixture silently
  reused a stale package. Local sources now always refresh.
- **The OpenCore sample SSDTs are not drop-in substitutes for a real EFI's tables.** The
  b760i reference's `SSDT-EC-USBX.aml` is Dortania's comprehensive 7341-byte table (OEM ID
  `DRTNIA`) covering every EC/USBX device path; OpenCorePkg's same-named sample compiles to
  306 bytes. Substituting it built a *different* table while every filename still matched,
  which is the kind of thing a config-level diff cannot catch. The example ships the real
  one via `oc_acpi()`.
- **A compiled table is not byte-identical across iasl versions.** `SSDT-PLUG-ALT` differs
  from the reference in exactly three header bytes — the checksum and the compiler
  revision — so AML comparison has to be substantive, not byte-exact.

Tests (7, `ctest`): `acpi` covers compiled and prebuilt tables reaching both the staged
tree and `ACPI.Add`, verbatim copying of prebuilt tables, incremental recompilation when a
`.dsl` changes, and a broken `.dsl` failing the build with iasl's own diagnostic. It is
registered only when iasl is present or fetchable.

Every mtime-sensitive test needs an explicit `sleep`. The Makefile generator compares
timestamps at second granularity and treats *equal* mtimes as up to date, so a test that
edits and rebuilds inside one second cannot tell a correct incremental build from a broken
one. Phase 2's pruning test was left intermittently failing by this — passing on a rerun,
which is worse than failing outright — and only showed up when the Makefiles suite was run
repeatedly. Ninja's finer timestamps hide the problem entirely, so a single-generator run
would never have caught it.

### Phase 4 — done

Delivered: `oc_config_overlay()`, `oc_config_set()`, `oc_boot_args()`, `oc_secrets()` and
the `CONFIG <type>` filter, with the layering applied in `scripts/oc_config.py`.

Pipeline order is base → overlays → keypath sets → boot-args → **snapshot** → per-entry
overrides → secrets. Ops run before the snapshot so it sees a complete document and its
schema fixups reach whatever they added; secrets run last so machine identifiers win over
everything and never touch the committed config.

**The b760i example now builds both ways.** Release reproduces the reference config.plist
completely, including `SystemSerialNumber`/`MLB`/`SystemUUID`/`ROM` restored from a
gitignored `secrets.plist` — so the committed config carries none of them. Debug switches
OpenCore, all twelve fetched kexts and the drivers to their DEBUG builds, sets
`Misc/Debug/Target=67` and `AppleDebug=true`, and appends `-v debug=0x100 keepsyms=1` to
boot-args, leaving the Release build untouched.

Design notes:

- **`CONFIG <type>` is evaluated at configure time**, not via generator expressions.
  OCMake is single-config by design — two build directories coexist instead — so the
  Python side never needs to know about build types at all.
- **Deep merge**: dicts merge recursively, everything else replaces. Arrays replace rather
  than concatenate, since an overlay touching `Kernel/Add` would otherwise duplicate
  entries the snapshot owns.
- **`oc_boot_args()` edits in place** rather than replacing the string, and dedupes on the
  key of `key=value`, so `debug=0x100` supersedes an existing `debug=0x0` while unrelated
  hand-written args survive.
- **Keypaths are `/`-separated** (NVRAM GUIDs contain dashes); numeric components index
  arrays, and missing intermediate dicts are created.

**The bug worth recording.** Two `oc_config_set()` calls silently collapsed into one:
config ops are stored under an index counter, and the counter variable was named `n`.
`if(NOT n)` is therefore *always true* — the unary form of `if()` matches CMake's constant
table, which contains `N`, `Y`, `NO`, `OFF` and `IGNORE`, **case-insensitively and before
dereferencing the variable**. Every op overwrote index 0 and only the last survived. This
is the same landmine as Phase 2's kext named `N`, now in OCMake's own code, and it is
narrower than it first looks: binary forms (`if(n EQUAL 1)`, `if(n STREQUAL "x")`,
`if(n GREATER 0)`) dereference correctly — only the unary truthiness form is affected. An
audit found this was the single occurrence.

Verifying the fix took a second pass. Reverting the condition alone did *not* fail the
test, because the variable had also been renamed — and `count` is not a false constant.
Only reintroducing the original defect exactly (name `n` **and** `if(NOT n)`) reproduced
it. A guard that only appears to bite is worse than none.

**Three more bugs found from a user report that switching build type in an existing build
directory did nothing** (the first two are below; the third is the lockfile pruning
described in §3.5, which is what actually exhausted the GitHub rate limit during
development — deleting a build directory never costs an API call, but switching variants
did, because it destroyed the other variant's lock entries).

Two related fixes came out of the same investigation: `_oc_lock_load()` now runs for every
declaration rather than only on the GitHub path, since a URL-only project never read the
lock and so had nothing to retain; and `OC_OFFLINE` no longer blocks `file://` sources,
because "no network" should not mean "no filesystem".

**Two bugs found from a user report that switching build type in an
existing build directory did nothing.**

1. **The derived `OC_BUILD` was written to the cache**, which made it indistinguishable
   from a `-DOC_BUILD=` override on the next configure. A build directory configured
   Release stayed Release for ever: `-DCMAKE_BUILD_TYPE=Debug` was silently ignored and
   RELEASE binaries were staged. Only deleting the build directory helped. The cache entry
   now holds the *override* (empty = follow `CMAKE_BUILD_TYPE`) and the effective value is
   a normal variable recomputed every configure. An explicit override still wins, and now
   says so.
2. **`CONFIG` matched either `OC_BUILD` or `CMAKE_BUILD_TYPE`.** With
   `-DOC_BUILD=DEBUG -DCMAKE_BUILD_TYPE=Release` that made *both* `CONFIG Debug` and
   `CONFIG Release` ops apply. It now compares against the effective variant alone.

The second bug was only found because the first one's regression test kept passing. The
test observed a `CONFIG Debug` op, which fired off `CMAKE_BUILD_TYPE` even while the staged
binaries followed the stale `OC_BUILD` — a proxy derived from the same value it was meant
to check. The test now writes `${OC_BUILD}` itself into the config and asserts on that, and
fails when the defect is reintroduced. Twice now, "verify the guard actually bites" has
found a second problem rather than just confirming the first.

Tests (8, `ctest`): `config` is network-free and covers overlay deep-merge, all five value
types including `<hex>` and base64 `DATA`, intermediate-dict creation, numeric array
indexing, boot-args append/remove/replace-by-key, secrets winning over an earlier set, the
`CONFIG` filter in both a Release and a Debug build, and three error paths. Its first
assertions exist specifically to catch the index-collapse regression.

### Phase 5 — done

Delivered: `cmake/OCValidate.cmake`, `scripts/oc_check.py`, `scripts/oc_report.py`.
`cmake --workflow --preset release` now configures, builds and validates in one command.

**ocvalidate** is taken from the OpenCore package being staged, so the validator always
matches the OpenCore version — it refuses to check any other. It exits 1 on problems, so
unlike OCSnapshot its status can be trusted. The extracted binary needs `file(CHMOD)`:
zip extraction does not preserve the executable bit.

**It immediately found a real defect in the b760i example.** The hand-written config.plist
was missing `Booter/Quirks/ClearTaskSwitchBit` and `UEFI/Unload`, both required by
OpenCore 1.0.7. The *reference* EFI has the same two omissions, so the config was written
for an older OpenCore and had been paired with a newer one — exactly the drift §7 lists as
a risk, and invisible to every check OCMake had until now. Fixed in the example's base
config (OCMake reports; it does not silently patch a hand-written file).

**`oc_check.py` covers what ocvalidate structurally cannot**: ocvalidate knows OpenCore's
schema but not what the project *declared*, and it never looks at the files on disk.

| Check | Catches |
|---|---|
| `declared-kexts` | a declared kext missing from `Kernel.Add`, or silently disabled |
| `missing-file` | any `ACPI`/`Drivers`/`Tools`/`Kexts` entry, or `ExecutablePath`/`PlistPath`, with nothing behind it |
| `load-order` | a kext ordered before something in its `OSBundleLibraries` — Lilu plugins before Lilu |
| `duplicate-identifier` | two enabled kexts claiming one bundle id over overlapping kernel ranges |
| `kernel-range` | `MinKernel` above `MaxKernel` |

**`BOM.md` / `BOM.json`** are regenerated with every build, next to `EFI/`. They are written
from the staged tree rather than from the declarations, so they report what was actually
produced, and they deliberately contain no timestamp — the BOM changes only when the EFI
does, which keeps it useful in a diff. A test asserts that property.

**Provenance.** Each artefact is grouped by where it came from and cites its source:

- **Kexts** split into *Fetched* and *Local*. A fetched kext links to the repository the
  release came from, which is not derivable from the staged tree — `IntelBTPatcher.kext`
  ships in the **IntelBluetoothFirmware** release, `BlueToolFixup.kext` in **BrcmPatchRAM**,
  `SMCProcessor`/`SMCSuperIO` in **VirtualSMC**. Local kexts cite their path in the repo.
- **ACPI** splits into *Compiled* and *Prebuilt*, and a table built from OpenCore's own
  samples is labelled as such rather than pointing at a file that is not in the repo.

- **Drivers and tools** use the same table shape, each row citing its own source.
  `oc_driver(PATH ...)` / `oc_tool(PATH ...)` stage a local `.efi` — a fork of a driver, or
  one OpenCore does not ship — and those cite their path rather than the package.

**Rows fold, cells collapse.** Two passes over each table:

1. Consecutive rows differing *only* in the name merge into one, names stacked with `<br>`
   (how a markdown table expresses a multi-line cell). VirtualSMC's three kexts become one
   row; so do OpenCore's five drivers.
2. Anything still repeating the row above is blanked, so a source shared by rows that
   differ elsewhere — a different version, say — is still stated once. Version collapses
   only *within* such a run, so an incidental version match between unrelated sources
   still prints.

The b760i BOM goes from 18 kext rows to 11, and 5 driver rows to 1.

Rows sort by source name **case-folded**: sorting the rendered markdown ordered
`[OpenIntelWireless/...]` before `[acidanthera/...]`, because `O` precedes `a` in ASCII.
The sort key is the plain source name, with case deciding only between otherwise equal
strings. `BOM.json` is never folded or collapsed — it stays complete for machines.

The mapping is recorded at declaration time into `<name>-provenance.json`, because a
staged bundle carries no record of which release it arrived in. `oc_require_package()`
gained an `OUT_URL` for the same reason.

Adding the driver source exposed an accuracy bug: `oc_opencore()` recorded the default
repository even when an explicit `URL` had bypassed it, so a BOM could cite
acidanthera/OpenCorePkg for a package that never came from there. Provenance now follows
what was actually fetched.

A second, related gap: the report *hardcoded* the OpenCore package as the source of every
driver and tool. That was true only because `oc_driver()` could not express anything else.
Rather than write a test for an unreachable case, `PATH` support was added first — so a
forked driver is now declarable, carries its own provenance, and the test that it is not
misattributed exercises a real path.

Two test bugs worth recording, both found while checking the guards bite:

- **CMake expands `${ARGN}` as a list, so any argument containing `;` is split into
  several.** Inline Python one-liners in tests were being torn apart mid-statement. Worse,
  the damage was invisible in `run_expect_fail` cases: a mangled command fails, so those
  tests would have passed for entirely the wrong reason. Inline scripts now use newlines,
  never semicolons.
- **`file(COPY <dir> DESTINATION <dst>)` nests the source inside the destination**; the
  trailing-slash form copies its contents. The same rule OCStage already relies on.

Tests (10, `ctest`): `validate` is network-free — the fixture ships a stub `ocvalidate`
so discovery, `chmod`, and test registration are all exercised. It asserts both ctest tests
register and pass on a good tree, that the BOM lists kexts/drivers/tools and is stable
across a rebuild, and that each of the five checks fires on a purpose-built defect. Each
check was verified to make the suite fail when removed.

### Built-in defaults — done

Four declarations that every EFI was repeating verbatim are now defaults, so the
b760i CMakeLists.txt lost eleven lines and produces a byte-identical `config.plist` in
both variants. They live in `OCMake.cmake` as a `OC_DEFAULT_*` block, each variable named
after the function it feeds and holding exactly what that function would have been called
with — the file is the reference for what OCMake does on its own:

```cmake
_oc_default(OC_DEFAULT_CONFIG  "config.plist")     # oc_config()
_oc_default(OC_DEFAULT_SECRETS "secrets.plist")    # oc_secrets()
_oc_default(OC_DEFAULT_DEBUG_SET                   # oc_config_set(), DEBUG only
    "Misc/Debug/Target     INTEGER 67"
    "Misc/Debug/AppleDebug BOOL    ON")
_oc_default(OC_DEFAULT_DEBUG_BOOT_ARGS -v debug=0x100 keepsyms=1)   # oc_boot_args()
```

**An explicit declaration always wins — but that means two different things, so defaults
are applied at two different moments.** Config ops are *ordered*: they are seeded in
`_oc_create_efi()`, ahead of everything the project declares, so a later `oc_config_set()`
on the same key overrides by simply coming later, and `oc_boot_args(REMOVE keepsyms=1)`
composes with the default instead of fighting it. Files are *single-valued*: they are
filled in at finalization, the first point at which it is known that the project declared
none of its own. Seeding the ops last would have inverted the precedence silently, so the
test asserts the override, not just the default.

There is no RELEASE counterpart to the Debug knobs and none is needed: every build
re-derives `config.plist` from the hand-written base, so a Release build simply never
applies them.

**A committed `<file>.example` is how a project says it uses secrets.** Defaulting
`oc_secrets()` to `OPTIONAL` would have turned a forgotten `cp secrets.plist.example
secrets.plist` into an EFI that builds and validates with blank identifiers. So the
template's presence decides: with it, a missing `secrets.plist` is the fatal error it
always was, naming the template; with neither file present, the project has no secrets and
nothing is said.

**`_oc_default()` sets only what nobody else has chosen** (`if(NOT DEFINED ...)`), so a
default can be changed before `include(OCMake.cmake)`, after it, or with `-D` — all three
leave the variable `DEFINED`. It is deliberately not a cache entry: a cached copy of a
value that lives in `OCMake.cmake` would go stale in every existing build directory the
moment the file changed, which is the trap that made a derived `OC_BUILD` impossible to
switch. `-DOC_DEFAULTS=OFF` disables the lot; emptying one variable drops just that one.

Two things a default must not do quietly, both now printed at configure time:

- What it did — `'b760i-aorus-pro' defaults: config.plist, secrets.plist,
  Misc/Debug/Target=67, Misc/Debug/AppleDebug=ON, boot-args += -v debug=0x100 keepsyms=1`.
- What it did *not* find. Picking `config.plist` up by name removed the one thing that
  used to catch a typo in it — the project no longer names the file, so a misspelling is
  no longer a `FATAL_ERROR` from `oc_config()` but silence. Finalization now says so, and
  names the path it looked for and what is skipped without it (`ocvalidate`, `occheck`,
  the BOM).

Tests (11, `ctest`): the new `defaults` case is network-free and builds seven throwaway
projects — defaults picked up by name, Debug-only application, a project declaration
overriding both a `set` and a boot-arg, an explicit `oc_config()` not displaced by a
`config.plist` that happens to exist beside it, `-DOC_DEFAULTS=OFF`,
`-DOC_DEFAULT_CONFIG=...` from the command line, and the two error paths. All eight
mechanisms were reverted one at a time and each made the suite fail for its own reason —
including moving the op seeding to finalization, which fails on the override assertion
alone.

### OcBinaryData as a driver source — done

`oc_driver()` knew two sources: a name inside the OpenCore package, and a local `PATH`
file. Neither reaches OcBinaryData, which is where `HfsPlus.efi` — Apple's own HFS+ driver,
which OpenCorePkg cannot redistribute — and the picker's `Resources/` actually live. It now
knows four:

```cmake
oc_driver(OpenCanopy OpenRuntime)         # the OpenCore package
oc_driver(OCBINARYDATA HfsPlus)           # OcBinaryData, pinned to a commit
oc_driver(URL <url> [SHA256 <hash>])      # anywhere
oc_driver(PATH drivers/Local.efi)         # a file in the repo
```

(Spelled as they ended up: the source keyword moved in front of its items a moment later,
see *One argument convention* below.)

**The obstacle was that OcBinaryData publishes nothing.** Its GitHub releases exist, but
they are unrelated QEMU CI artefacts (`qemu.tar.xz`) — `Drivers/` and `Resources/` only
exist in the tree. So the release-asset resolver, which is what every other fetch goes
through, simply cannot see them.

`oc_require_file()` is the answer: the single-file counterpart to `oc_require_package()`,
sharing the lockfile, the cache and the offline guarantees. It resolves the ref to a commit
(`_oc_gh_commit()`) and fetches `raw.githubusercontent.com/<repo>/<commit>/<path>`.

**Pinning the commit is the whole point, not a nicety.** A `master` URL serves different
bytes over time, so the hash recorded in the lockfile would be a hash of *whatever master
was that day*. Nothing would notice until a cold cache, where `file(DOWNLOAD ...
EXPECTED_HASH)` would fail with a checksum error that names neither the branch nor the
change. Resolving to a commit makes the URL immutable, so the recorded hash is a statement
about a specific file for ever. It also costs exactly one API call, on a cold lock only —
the same shape as `VERSION latest`.

Fetching one 30 KB file rather than a 65 MB repository archive is the other reason for the
single-file path. Archive tarballs are also not byte-stable across GitHub's own
recompressions, which would make a pinned hash unreliable even for a pinned commit.

`oc_fetch_archive()` grew an `OUT_FILE` mode beside `OUT_DIR`: a bare `.efi` is not an
archive, but everything *before* the unpack — cache lookup, hash policy, `OC_OFFLINE`
diagnostics, the `file://` refresh rule — is identical, so this is one function rather than
two that would drift apart.

Lock entries are keyed by `OC_BUILD` even though these files have no build variants. That
looks redundant, and it is deliberate: `_oc_lock_flush()` keeps unused entries only when
their `BUILD` differs from the current one, so a build-less key would survive for ever
after its declaration was deleted. The cost is one extra resolve on the first variant
switch; the b760i lock therefore carries the same commit twice.

The example now uses `HfsPlus.efi` and the base `config.plist` names it. `ocvalidate` and
`occheck` pass, and the BOM cites the right repository:

```
| `HfsPlus.efi` | [acidanthera/OcBinaryData](https://github.com/acidanthera/OcBinaryData) |
| `OpenCanopy.efi`<br>… | [acidanthera/OpenCorePkg](https://github.com/acidanthera/OpenCorePkg) |
```

**A fixture bug the suite caught, and one it did not.** Adding a second `oc_driver()` to
the shared test fixture broke `acpi`, because two tests spliced their declarations in with
`string(REPLACE "oc_driver(" ...)` — which replaces *every* occurrence. `acpi` failed
loudly (a duplicate ACPI table). `config` kept passing while silently applying every op
twice, because setting the same key twice is idempotent — a latent vacuity risk of exactly
the kind §9 keeps warning about. The fixture now carries a unique `# @EXTRA@` marker on its
own line, and both tests anchor on that.

Tests: `phase2` and `validate` gained a `Remote.efi` fetched over `file://`, which
exercises the whole fetch → stage → snapshot → BOM path offline; three new error paths
(URL with several names, `OCBINARYDATA` on `oc_tool()`, the two source keywords together);
and `resolve.live` now resolves `OcBinaryData@master` to a 40-character commit. All five
new mechanisms were reverted one at a time and each failed for its own reason.

### One argument convention — done

`oc_ssdt(SAMPLES SSDT-PLUG-ALT)` and `oc_driver(HfsPlus OCBINARYDATA)` were mirror images:
source-then-items in one place, items-then-source in the other. The rule now, everywhere:

> **A source keyword comes first and introduces the items that come from it. Bare
> arguments mean the default source.**

Source-first was already the majority — `SAMPLES`, `PATH`, `KEXTS` all read that way — and
`OCBINARYDATA` was both the outlier and the newest, so it moved.

The fix is not only cosmetic. As a call-wide option, `OCBINARYDATA` silently redefined
*every* bare name in its call, so sources could not be mixed and `oc_driver(A B URL ...)`
had to be rejected as ambiguous. As a multi-value keyword each source owns its own items,
one call can draw on all four, and two error paths stopped existing:

```cmake
oc_driver(OpenRuntime OpenCanopy PATH local/Forked.efi URL "file://.../Remote.efi")
```

`URL` also lost its redundant leading name and now takes the staged name from the file it
points at, exactly as `PATH` does — so a name and a URL basename can no longer disagree
about what lands in `OC/Drivers/`. A URL not ending in `.efi` is an error rather than a
silently misnamed binary.

Two guards replaced the two that became impossible: a source keyword with nothing after it
is a typo rather than an empty set (`A_KEYWORDS_MISSING_VALUES`), and `URL` must point at a
`.efi`. Both were verified to fail when reverted, as was the mixed-source call itself.

`oc_kext()` and `oc_opencore()` deliberately keep their shape: they declare one package
whose first argument is the declaration's own name and lockfile key, with attributes after.
`KEXTS` selects within the fetched archive and is not a source. That distinction is now
written down in IMPLEMENTATION.md §4 so the next addition does not have to re-derive it.

### Phase 6 — install ergonomics, packaging, `outdated` — done

Five pieces, and three of them turned on decisions worth recording.

**`oc_resources()`** fills `OC/Resources/` from OcBinaryData, to §2's signature:

```cmake
oc_resources(OCBINARYDATA AUDIO OFF IMAGE Acidanthera/GoldenGate FONT ON LABEL ON)
```

Defaults FONT ON, LABEL ON, IMAGE ON, AUDIO OFF — audio being 362 `.wav` files and 6.3 MB,
two thirds of the whole repository, read only when `UEFI/Audio/AudioSupport` is on.

**IMAGE takes a set, and writing `Misc/Boot/PickerVariant` is part of its job.** Once the
declaration names an icon set, the plist repeating it is duplication with two ways to
disagree — the same reasoning that generates `Kernel.Add` rather than asking for it twice.
So `IMAGE Acidanthera/GoldenGate` stages that set alone (24 files, not 72) and writes the
key, converting `/` to the backslash OpenCore wants. Bare `IMAGE` keeps the old behaviour —
the whole tree, PickerVariant untouched — because `PickerVariant Auto` picks a set by macOS
version and needs all of them present. It is an ordinary config op at the call's position,
so a later `oc_config_set()` still wins.

`PickerVariant` addresses a set by where it sits inside `Resources/Image`, so a named set
is staged at its own path rather than flattened. The b760i example's base plist now says
`Auto` and the CMakeLists names the set; the two can no longer drift.

I built the first cut of this to §5's one-line summary and never read the §2 sketch, which
had specified the signature all along. Worth recording as a process failure rather than a
design one: the phase list is a summary, and §2 is the specification.

**Resources come as one archive, unlike drivers.** The default set is ~56 files. Fetching
them individually would be equally correct and better verified — but it would put 56
entries per build variant into a lockfile whose entire purpose is that a human reads it in
a diff. One declaration, one lock entry. `oc_require_file()` accordingly grew into
`oc_require_ref()`, which fetches either one file (`PATH`) or the repository archive, and
`_oc_archive_root()` descends the single `<repo>-<commit>/` wrapper GitHub puts around it.

**`install-esp` / `diff-esp`** are `scripts/oc_esp.py`, because the work is plist parsing,
tree hashing and zipping. Two rules make it safe:

- **It never mounts anything.** Mounting an ESP needs root on every platform, and a build
  target that silently asks for a password — or fails in CI, or hangs in an IDE that
  swallows stdin — is worse than one that prints the command to run. The good news, and
  the reason this works at all: an ESP is FAT32 and gets mounted with ownership off, so
  once mounted it is writable *without* privileges. Detection is `diskutil` on macOS
  (walking APFS physical stores to reach the boot disk) and `lsblk -J` on Linux; Windows
  asks for `-DOC_ESP=`, which is also how you target a USB stick.
- **It replaces `EFI/OC` and overwrites `EFI/BOOT`, and nothing else.** §3.6 said "copies
  the staged tree in", and the obvious reading — replace `EFI/` — would delete
  `EFI/Microsoft`, `EFI/ubuntu` and every other loader sharing the partition. A stale kext
  left behind is the failure mode that makes replacement necessary, so `EFI/OC` is wiped;
  everything outside it is left alone and reported as such.

That second rule had a consequence that only the test found: with unowned files counted as
differences, the tool could never report "up to date" on a dual-boot machine, and a second
`install-esp` would keep re-installing and re-archiving. Unowned removals are now excluded
from the *decision*, not just from the report.

Backups default on, off the ESP, as a timestamped zip with the `unzip` line to undo it
printed next to it. §3.6 is explicit that this is not a backup tool; the archive covers the
five minutes between replacing an EFI and discovering it was a bad idea.

**CPack** produces `<name>-EFI-OpenCore-<version>-<BUILD>.zip` with `EFI/` at the archive
root — drop-in ready, named after the thing that decides whether two of them are
interchangeable. `include(CPack)` works from the deferred finalizer.

**`outdated`** reads `ocmake.lock` and nothing else. The lock already records what was
pinned and the URL says where it came from, so no new state has to be generated and kept in
sync. It runs under `cmake -P`, never at configure time: checking for updates is a question
the user asks, it costs one API call per package, and it must never be able to fail a
build. It calls `_oc_http_json()` directly rather than `_oc_gh_release()`, so a repository
with no published release is a row in the report rather than an abort. Release entries
compare tags; commit-pinned ones (OcBinaryData) compare the tracked ref's head.

**A new check, `picker-resources`.** Nothing in `config.plist` references the picker's
icons, font or labels, so no existing check could notice they were never staged — the
symptom is a black screen at boot. It caught the b760i example immediately: it has shipped
OpenCanopy with `PickerMode: External` and an empty `Resources/` since Phase 2. The example
now calls `oc_resources()`, and its `PickerVariant` moved from `Blackosx\BsxM1` — a
third-party icon set nobody publishes as a fetchable release — to `Acidanthera\GoldenGate`.

**Two bugs of my own, both caught by running the thing.** `outdated` read `CMAKE_MATCH_1`
after further `string(REGEX ...)` calls had already overwritten it (it is global state, and
rule 8.1's neighbour). And its de-duplication compared a `;`-joined key against a list —
`list(APPEND)` flattens such a value into several elements, so `IN_LIST` could never match
it again and every package was reported twice.

Tests (12, `ctest`): the new `install` case is network-free — an OcBinaryData-shaped archive
over `file://`, and a fake ESP carrying an `EFI/Microsoft` that must survive. It covers the
default resource set and Audio staying out, diff reporting without touching anything,
install replacing `OC/` while sparing the other loader, the backup archive, `OC_ESP_BACKUP=OFF`,
a no-op second install, both refusal paths, the CPack layout and `outdated`'s
de-duplication, the selectors, a named icon set staging only itself and writing
PickerVariant, a bare call taking the defaults, and a later `oc_config_set()` still winning.
`validate` gained the empty-`Resources/` case; `install` has the complement, where
resources exist but a hand-written `PickerVariant` names a set that does not.

**And one vacuous test, caught the usual way.** The `outdated` de-duplication guard passed
with the fix reverted, because the fixture had only ever been configured once — its lockfile
held a single build variant, so there was nothing to de-duplicate. The test now configures
the other variant first and asserts the lock holds both. Same mechanism as the Phase 0
timestamp guard: *the fixture never exercised the path*. Ten of the eleven mechanisms were
non-vacuous first time; that one was not.

### Phase 7 — CI and docs — done

**`README.md`** is the front door: the pitch, a worked example, the command table, the full
API reference, the defaults, the knobs, and how the lockfile makes a build reproducible.
`PLAN.md` and `IMPLEMENTATION.md` are linked from it rather than duplicated into it.

**Two workflows.** `.github/workflows/ci.yml` runs the suite over seven legs — the floor
(CMake 3.25 + Python 3.9, the versions the README promises) and current, on macOS, Linux
and Windows, plus one Unix Makefiles leg. The generator difference is second-granularity
mtimes rather than anything platform-specific, so it does not need repeating on every OS. A
second job builds all three examples end to end, packages them with CPack and uploads the
zips. `GITHUB_TOKEN` lifts the API limit from 60 requests/hour to 1000, which the cold-lock
tests would otherwise exhaust.

`.github/workflows/build-efi.yml` is the reusable one a consumer repo calls. It builds,
validates, packages, uploads — and **fails if `ocmake.lock` moved during the build**. A
committed lockfile is the reproducibility claim; if configuring rewrote it, the artefact is
not what the repository says it is, and that should be loud rather than silent.

**`examples/laptop-template`.** Its `config.plist` is OpenCore 1.0.7's own
`Docs/Sample.plist` with laptop-shaped edits. It is labelled, in its directory name and in
the first line of its README, as never having booted anything — the b760i example is the
validated one, and conflating the two would be the worst possible outcome of adding a
second example. What it carries that a desktop cannot: `SMCBatteryManager`,
`SMCLightSensor`, VoodooPS2, `BrightnessKeys`, `NVMeFix`, `HibernationFixup`, and
`SSDT-PNLF` — the last three ACPI tables all compiled from OpenCore's own samples, so the
example commits no `.aml` at all.

**It paid for itself immediately, twice.**

*A real bug.* `verify_snapshot()` enumerated only top-level bundles under `OC/Kexts`, but a
kext's plugins are separate `Kernel.Add` entries addressed through their parent
(`VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext`). Every plugin therefore
read as "listed but not staged" and the build failed outright. Staging was right all along —
it copies the parent and the plugins travel inside it — so the fix was to teach the
*comparison* that they are separately addressable. No previously declared kext had nested
plugins, which is why five phases never hit it. The fixture now nests one, and the test
asserts all three properties: listed in `Kernel.Add`, staged inside the parent, and never
staged as a top-level bundle.

*The missing half of the snapshot.* The first message of this project asked for "OC
Snapshot and OC Clean Snapshot"; only the first was ever built. OCSnapshot merges, so an
entry it can match keeps its settings, `Enabled` included — that is what keeps b760i's
hand-written version `Comment`s and `ResetNvramEntry`'s `--preserve-boot` alive. But
`Docs/Sample.plist`, the file every new project copies, ships entries of its own including
a **disabled** `VoodooPS2Controller.kext`, so on a sample-derived base the sample's opinion
silently outranked the declaration.

Two designs were built and discarded before the right one. Cleaning **unconditionally** was
measured against b760i and rejected: it rewrites every `Comment` to the bundle name and
drops `ResetNvramEntry`'s `Arguments`. Cleaning when a section is **byte-identical to the
package's Sample.plist** works until acidanthera changes that file between releases, at
which point detection silently stops firing — a heuristic whose failure mode is silence, at
upgrade time. A marker key written into the config was considered next; it answers "clean
again?" but not "clean at all?", since an absent marker means both *fresh sample copy* and
*imported hand-tuned config*, which want opposite treatment.

The design that shipped removes the question instead of answering it. **There are two ways
into an OCMake project, told apart by whether the file is on disk:**

- **greenfield** — the declared `config.plist` does not exist, so OCMake writes one from
  the package's `Docs/Sample.plist` with the four derived sections emptied, and says so.
  Everything else, `#WARNING` keys included, is kept.
- **migration** — the file exists, so it is the user's, and it is merged into.

No detection, no marker, no version coupling: a `config.plist` in an OCMake project is
never a raw sample, because OCMake made it. `oc_config(<file> CLEAN)` remains for the one
case left over — a config copied from the sample by hand before OCMake was involved.

Emptying the four lists *is* `-c`: OCSnapshot's entire implementation of clean snapshot is
four lines substituting `[]`, and the two paths were verified to produce byte-identical
output. Doing it in `scaffold()` rather than passing the flag is what lets it happen at
creation time, when nothing is staged yet and there is no snapshot to run.

`oc_config()` no longer errors on a missing file — that path is now the greenfield case.
`examples/minimal` clears `OC_DEFAULT_CONFIG` to stay a bare OpenCore tree, which also keeps
its test free of Python and OCSnapshot.

*A bug the rework surfaced.* `_oc_info(msg)` took one argument, so every call that wrapped
its message across two string literals silently printed only the first. The `-UOC_BUILD`
hint added in Phase 4 had never once appeared, and its test asserted on the surviving half
so nothing noticed. Both helpers now join their fragments, and the test asserts the second
half.

**A wrong diagnosis, corrected.** I first reported that the shared `VoodooInput.kext`
between VoodooPS2 and VoodooI2C made OCSnapshot disable a whole kext tree, and dropped
VoodooI2C from the example on that basis. That was wrong, and the evidence was contaminated:
the run I read it from still had Sample.plist's stale disabled entries in the base, and I
never re-tested the duplicate in isolation. Against a clean base the snapshot disables
exactly the duplicate *entry* — `VoodooI2C.kext/Contents/PlugIns/VoodooInput.kext` — and
leaves both parents and every other plugin enabled, which is what ProperTree does and what
was expected of it. Both kexts ship in the example.

Two smaller findings, both handled by existing diagnostics rather than needing new ones: a
release tagged with no assets attached (VoodooI2C 2.9) reports "release has no downloadable
assets", and a renamed repository answers the API with a 301 whose body is
`{"message": "Moved Permanently"}` — currently surfacing as "has no release tagged X",
which is misleading and is noted below as the one known gap.

**Windows is now claimed but still unproven.** Every per-platform shim exists — `ocvalidate.exe`,
the open-acpica iasl, `LOCALAPPDATA` for the cache, `mountvol` guidance for the ESP — and
none of it has ever run. The matrix is what will find out; that is its job, and until it has
run green the Windows claim in the README is a claim.

### VERSION defaults to latest — done

`oc_opencore()` and `oc_kext()` no longer require a `VERSION`; without one they take the
newest release. The lockfile is what makes that safe rather than reckless: whatever
`latest` resolved to is pinned by URL and hash, so the second build and every build after
it is reproducible, a clean clone still builds with `-DOC_OFFLINE=ON`, and `-DOC_UPDATE=ON`
is the only thing that moves it.

Applied **before the lock key is built**, so the key carries the spec — `Lilu|latest|RELEASE`,
which has a stable identity across the versions it resolves to. Not applied when a `URL`
was given: that entry is pinned by its URL, and calling it `latest` would be false.

The two examples now demonstrate opposite ends of this. `laptop-template` names no versions
at all, which is right for a machine being brought up. `b760i-aorus-pro` pins every one,
because it reproduces a specific EFI that was validated on that board — and now says so.

`oc_kext()` also gained a real diagnostic for a declaration with no source at all, naming
all three (`GITHUB`, `URL`, `PATH`); previously it fell through to a resolver message that
demanded `GITHUB and VERSION` and never mentioned `PATH`.

**NootedRed in the laptop template.** AMD APU laptops drive the iGPU with NootedRed rather
than WhateverGreen, so it ships staged but `ENABLED OFF` — wrong for an Intel machine, one
word to switch. `occheck` exempts a deliberate `ENABLED OFF` from its declared-kexts check,
so this is a supported state rather than a warning to live with. It is also the one kext
here pinned on purpose, because it demonstrates two resolver behaviours in a real
declaration: its tags carry a `v` prefix its assets do not (`v0.8.10` →
`NootedRed-0.8.10-RELEASE.zip`), and it publishes `RESEARCH_RELEASE` builds beside
`RELEASE` ones — the asset that made `-RELEASE.zip` an anchored pattern back in Phase 1.

The default is tested offline rather than against the network: a project with no `VERSION`
anywhere is configured with `-DOC_OFFLINE=ON` against a lockfile seeded with `|latest|`
keys. Without the default the key would carry an empty field, the lock would miss, and
offline would fail — so the test asserts the key, not merely that some version was chosen.

### Phase 8 — stretch — done, with one item deliberately not built

**Multiple `oc_efi()` scopes already worked.** The Phase 0 data model — the `EFI` keyword,
`OC_EFI`, the `PROJECT_NAME` fallback — carried it: two EFIs, two trees, two target sets,
one shared lockfile, and a package both pin fetched once. What did not work was the two
places that had quietly assumed one:

- **Install silently produced a hybrid.** Every EFI installs to `<prefix>/EFI`, because
  that is the only layout firmware looks for, so `cmake --install` copied one over the
  other and said nothing. Now refused before anything is copied, naming the count and the
  way out (`--component <name>`). This was the one real bug in the feature.
- **CPack is a per-project singleton** and every EFI packs to the archive root, so a second
  `include(CPack)` would have produced one zip holding a mixture. Not registered at all
  when there is more than one EFI, and it says so.

The bare aliases (`validate`, `report`, …) turned out to be correct already: they are
created from the whole EFI list, so with several names none matches a target and none is
made — which is what the comment claimed and, this time, what the code did.

**`oc_vault()`.** Basic vaulting: `Misc/Security/Vault = Basic` plus `OC/vault.plist`
regenerated from the staged tree on every build. This is a good fit for a build system
precisely because the failure mode is severe — OpenCore refuses any file whose digest
disagrees, so a manifest that has drifted is a machine that stops at the picker.

`scripts/oc_vault.py` reimplements OpenCorePkg's `Utilities/CreateVault/create_vault.sh`,
which is bash plus openssl/xxd/find/awk and does not run on Windows. Correctness was not
argued, it was diffed: on the laptop example both produce the same 115 entries with
identical digests. The step runs after the config step, since the manifest covers
`config.plist` too, and `occheck` **recomputes** the manifest rather than trusting it —
the whole point of the check is the case where the generator did not run.

**Secure vaulting, cross-platform, without RsaTool.** The first cut declined it: RsaTool is
shipped only as a Mach-O x86-64 binary, and `sign.command` patches `OpenCore.efi` with
`hexdump`/`awk`/`dd`. Reading RsaTool.c rather than its shape changed the answer — the parts
are much smaller than the packaging.

`RsaTool -sign` generates a **fresh RSA-2048 key every run**, signs, embeds the public half,
and discards the private one. So there is no key to manage and nothing to keep secret, which
removes the reason to be cautious about generating keys in a build.

The public key goes in as Chromium's `RSAPublicKey`, which acidanthera widened to 64-bit
header fields — **528 bytes, not the 520 the documentation cites**. That is twelve lines of
integer arithmetic in Python, and it was not argued but verified against the shipped
RsaTool two ways: regenerating its own `-sign` output from the modulus alone, and comparing
`-pub` for a key of ours. Both byte-identical.

The `strings`/`dd` problem turned out not to exist. The slot between `=BEGIN OC VAULT=` and
`==END OC VAULT==` is exactly 528 zero bytes; writing into it is a slice assignment. That
left key generation and signing as the only platform-bound part — see the next entry.

`oc_vault()` takes its mode first and its variant scope second:

```cmake
oc_vault(SECUREBOOT All)      # laptop-template
oc_vault(BASIC Release)
```

`SECUREBOOT` rather than OpenCore's `Secure`, because the name should say what it needs: the
chain terminates at `OpenCore.efi` and only firmware UEFI Secure Boot verifies that.
`All` is the default scope — vaulting only Release would quietly leave a Debug build
unprotected, and plenty of people run Debug daily. Out of scope means no manifest *and* no
`Vault` key claiming there is one.

**And the scaffold no longer touches `Misc/Security/Vault`.** Phase 8's first cut relaxed
the sample's `Secure` to `Optional`, reasoning that a Secure vault with no manifest cannot
boot. That was the wrong call: it is Dortania-guide material, it is the user's config, and a
project that forgets to change it breaks exactly as it would have without OCMake. The
difference OCMake makes is that `occheck` says so at `ctest` rather than at the picker.

**`DORTANIA` as a kext source.** `oc_kext(Lilu DORTANIA)` takes the build Dortania
publishes for every upstream commit — where you go for a merged-but-unreleased fix, or a
DEBUG build of a project whose own releases ship none. Its index is one 10.5 MB JSON
document; a cold resolve costs ~3.5 s including the download, and a warm lock costs nothing.
The index publishes a SHA-256 per build, so the lock records a digest **the publisher
asserted** rather than one OCMake merely observed, and `file(DOWNLOAD)` verifies against it
before the bytes are used. An unknown project name lists the 37 it does have.

**Build-from-source kexts: not built, and I would argue against it.** Every candidate has
its own build system, most need `MacKernelSDK` and submodule checkouts, and all of them need
Xcode — so it is macOS-only, slow, and fragile in exactly the way the rest of OCMake is not.
`DORTANIA` covers the real motivation (a fix that is committed but unreleased) with a
verified binary and no toolchain at all.

**A gap that turned out not to exist.** Phase 7 recorded that a renamed repository — GitHub
answers the old path with `301 {"message": "Moved Permanently"}` — was reported as a missing
tag. It is not: `file(DOWNLOAD)` follows the redirect and the request succeeds. That note
came from reading a `curl` without `-L` and generalising, rather than asking the resolver.
`ECEnabler` was dropped from the laptop example on the same false premise and is back;
`resolve.live` now pins the behaviour so nobody "fixes" it later.

**A trap in OpenCore's own sample, caught by the new check on its first run.**
`Docs/Sample.plist` ships `Misc/Security/Vault = Secure`, so every greenfield project
scaffolded from it carried a config that cannot boot -- Secure means OpenCore refuses every
file it cannot find in a `vault.plist` that is not there. `ocvalidate` does not object: the
key is well-formed, it just describes files that do not exist. Nothing but the new vault
check would have found it, and it found it on the laptop example the moment it ran.

The scaffold now relaxes it to `Optional` and says so. That weakens nothing -- a setting
that cannot boot protects nothing -- and `oc_vault()` is how you turn vaulting on, manifest
included.

**And a bug in the new code, from a trap worth naming.** `cmake_parse_arguments()` sets an
unset option to the *string* `FALSE`, not to nothing. Testing it with `if(OPT)` is fine;
forwarding it as a value is not, and `DORTANIA "${A_DORTANIA}"` handed the resolver a
project called `FALSE`. IMPLEMENTATION.md §8.13.

Tests (13, `ctest`): the new `multi` case is network-free and covers separate trees, the
shared package being fetched once, the install refusal (and that nothing was copied before
it), single-component install, and the absent aliases and CPack config. `validate` gained
the vault: manifest written, `Vault` declared, `config.plist` hashed, `vault.plist` and
`OpenCore.efi` excluded, backslash paths, and a tampered file caught by recomputation.
`resolve.live` gained the rename and Dortania.

The vault tests are the ones worth describing. `verify_vault.py` deliberately shares no code
with the generator: it reads the public key back out of the patched `OpenCore.efi` and checks
`vault.sig` as raw RSA-2048 over the SHA-256 of `vault.plist`, exactly as OpenCore would.
Its first version had a hole — it validated the signature against the modulus and never
looked at `n0inv` or `rr`, so either could have been wrong while the test passed and the
machine still refused to boot. Both are now recomputed from the modulus and compared, and
both mutations fail the suite.

Every new mechanism was reverted one at a time and each failed for its own reason. Signing a
payload other than the manifest fails during the *build*, not the check, because
`verify_vault.py` checks the chain end to end, which is where a bad signature surfaces.

### Secure vaulting everywhere, and a shared Python environment — done

The first cut of `oc_vault(SECUREBOOT)` shelled out to openssl, which meant macOS and Linux
only and a Windows exclusion in the CI matrix. Both are gone.

**The choice was measured rather than argued.** Three options were on the table — Conan,
a repackaged openssl ZIP à la FireDaemon, or pyca/cryptography — plus a fourth nobody had
named: write the ~55 lines of RSA in the standard library, which benchmarked at 1.1 s mean
for a 2048-bit key and would have needed no dependency at all.

An objection I raised against `cryptography` did not survive contact: that fetching it would
break `-DOC_OFFLINE=ON`. It would not. OCMake already needs the network once to fetch
OpenCore, and offline has always meant *warm cache and committed lock*, not *never touched
the network*. An environment living in `OC_CACHE_DIR` has exactly that shape. The
reproducibility objection was weaker still and was withdrawn outright: the signing key is
regenerated every build, so the package version cannot affect the artefact.

What settled it was counting both sides:

| | crypto | infrastructure |
|---|---|---|
| standard library | 53 lines | 0 |
| pyca/cryptography | 5 lines | 41 |

Near-identical totals — but the *kind* of line flips. The 53 are a Miller-Rabin
implementation somebody has to own; the 41 are "does this import, if not make an
environment and install it", which reads at a glance. And the 41 amortise: they are
infrastructure for any future script that needs a package, not a vault-specific cost.

So `cmake/OCPython.cmake` is deliberately general. `_oc_python_env(MODULE ... REQUIRE ...
REASON ...)` resolves cheapest-first: the interpreter already found, then a shared
environment under `OC_CACHE_DIR` keyed by interpreter version, then provisioning. Step one
is the one that matters — where the package is already installed nothing is fetched at all,
which is the common case on Linux distributions and for anyone managing their own
environment. `OC_PYTHON_ENV` points at one you manage instead.

`OC_CRYPTOGRAPHY` is a floor (`cryptography>=42`) rather than an exact pin. Since the
artefact cannot depend on it and the three calls used have been stable for years, a pin
would only rot and eventually leave a new Python with no wheel.

`oc_vault(BASIC)` is untouched and still needs nothing but the standard library, so most
projects never provision anything.

CI covers both paths deliberately: the `tests` job installs cryptography so the suite's
SECUREBOOT branch runs rather than skipping, and the `examples` job does **not**, so
building `laptop-template` exercises OCMake provisioning the environment itself. The
`validate` test stays network-free by contract — it asks whether a capable interpreter
already exists and skips rather than reaching for the network.

### examples/multi-efi — done

Multiple `oc_efi()` scopes had a test but no example, so the feature was demonstrated only
against a fixture. `examples/multi-efi` builds a desktop and a laptop from one repository:
the OpenCore release and the three kexts every machine wants are declared once in a
`foreach()`, and only the machine-specific parts appear twice.

It is also the only place `OC_EFI` is shown. Both spellings are there deliberately, because
they suit different jobs: `EFI ${machine}` is what makes the shared loop possible, while
`block()` + `set(OC_EFI laptop)` reads better for a run of machine-specific declarations —
and `block()` is what stops the variable leaking into the next machine's section.

**Restructuring it into one CMakeLists per machine turned up a real bug.**
`add_custom_command(OUTPUT)` is visible only to targets in the directory that created it,
and every OCMake target is created by the deferred finalize at the top level. `oc_ssdt()`
was the one declaration that created its rule where it stood, so the idiomatic layout —
`add_subdirectory(desktop)`, `add_subdirectory(laptop)` — produced `.aml` rules nothing
could reach: *No rule to make target `_oc/acpi/laptop/SSDT-PLUG.aml`*. The compiles are now
recorded on the target and emitted during finalization, which is what everything else
already did. Rule 8.14.

The subdirectory layout also removed the workaround the flat version needed: each machine's
directory is where its EFI is first declared, so `OC_DECL_DIR` differs and the config and
secrets defaults resolve per machine. No `oc_config()` or `oc_secrets()` anywhere in the
example, and `common.cmake` needs no parameters — `include()` runs in the caller's scope, so
whichever `OC_EFI` that directory set is still in force.

**Writing it turned up a silent footgun.** Two EFIs declared in one directory both fall
back to `./config.plist`. The first scaffolded it, the second reused it, and nothing said
so — two machines sharing one config while each appeared to have its own. Now refused, with
the fix in the message. An *explicit* `oc_config()` pointing both at one base is left alone:
sharing a base and differing in declared kexts is a reasonable thing to want, and the
difference is whether anyone chose it.

`ocvalidate` caught the other mistake while the example was being written: the desktop
loaded OpenCanopy while its config still carried Sample.plist's `PickerMode Builtin`. That
became a real difference between the two machines rather than a patch — the desktop uses
the graphical picker with GoldenGate icons, the laptop the builtin one.

Both EFIs validate, the shared package is fetched and extracted once, and one `ocmake.lock`
carries ten entries per build variant rather than one set per machine.

### oc_efi(<name>) replaces set(OC_EFI ...) — done

Writing the multi-EFI example put `set(OC_EFI desktop)` in front of a reader, and it did not
survive the look. Two problems, one of them serious:

- **Wrong category.** It reads exactly like `OC_BUILD`, `OC_OFFLINE`, `OC_CACHE_DIR` — the
  user-facing configuration knobs. It is not one; it is a scope marker.
- **A bare `set()` cannot be checked.** `set(OC_EFl desktop)` — lowercase L — leaves
  `OC_EFI` unread, the `PROJECT_NAME` fallback takes over, and the whole file's declarations
  land on an EFI nobody named. It configures. It builds. It produces the wrong thing in
  silence, and in a two-machine repo both machines collapse into one.

`oc_efi(<name>)` fixes both by being a call: it sets the scope for the rest of the enclosing
scope, and rejects what it does not understand. The name is positional to match
`oc_kext(<name> ...)`, since it is now the first line of a machine's file rather than a
terminator at the bottom. `OC_EFI` goes back to being an internal detail.

Moving it to the top is also more honest about what the function is. It never finalized
anything — finalization is deferred and armed by whichever `oc_*` call comes first — so
sitting at the bottom implied a role it did not have. Its real job has always been "name and
configure this EFI", which is a thing you say before you start describing one.

The flat layout benefits too, and that was not the intent. It becomes section markers with
no `block()` and no variable, and a project that groups by category rather than by machine
keeps `EFI <name>` per declaration — which is also what makes a shared `foreach()` possible.

**Enforcement was considered and rejected as unachievable**, then found to be largely
unnecessary. A project is not known to be multi-EFI until the second one appears, so
declarations cannot be required to name an EFI retroactively; and the subdirectory layout
legitimately relies on ambient scope, so a blanket rule would have to exempt it. But
forgetting `EFI <name>` in a flat file already fails loudly for a reason nobody designed:
the declaration conjures an EFI named after the project, nothing gives that EFI an OpenCore
package, and finalization refuses. Only *naming the wrong EFI* is uncatchable, and that is
semantically valid CMake.

So the resolution is reported rather than enforced. A project with more than one EFI now
prints what each ended up with, at configure time rather than in a BOM after a build:

```
-- OCMake: 2 EFIs: desktop (6 kexts, 2 ACPI, 3 drivers, 3 resource sets), laptop (6 kexts, 3 ACPI, 2 drivers)
```

### examples/multi-efi-flat — done

The flat, category-grouped layout was documented in prose and demonstrated nowhere, so it
now has a working example. It is deliberately *not* a second copy of the subdirectory one:
grouping by category only earns its keep when the EFIs are near-identical, so this builds
two variants of **one** machine rather than two machines.

The variants are a daily EFI and a rescue stick — which closes a gap between §3.6 and the
examples. The recovery story has always been "keep a known-good EFI on a USB", and the
weakness of that advice is that the stick rots: built once from whatever the kexts were,
never rebuilt, and out of date exactly when it matters. Declaring it means it is rebuilt
from the same kexts as the main EFI every time, and installed with one flag:

```bash
cmake --install build --component rescue --prefix /Volumes/USB
```

The layout justifies itself in two lines, which is the point of having the example at all:

```cmake
oc_driver(OpenRuntime OpenCanopy ResetNvramEntry EFI main)
oc_driver(OpenRuntime                            EFI rescue)
```

Kexts and ACPI are declared in one `foreach()` over both, because a rescue EFI that boots
with different kexts than the one it is rescuing is not much of a rescue. `OpenShell` goes
only on the stick — what you want when something has gone wrong, and what OpenCore's own
Secure Boot checklist says not to sign for the same reason. Both share one `secrets.plist`,
since it is one machine; the two `config.plist` bases are separate and named explicitly.

There is no `oc_efi()` call in the file at all: `EFI <name>` on each declaration creates and
names both. That is worth having demonstrated somewhere too.

The summary line added in the previous entry carries the whole story:

```
-- OCMake: 2 EFIs: main (5 kexts, 2 ACPI, 3 drivers, 3 resource sets), rescue (5 kexts, 2 ACPI, 1 driver, 1 tool)
```

### Where this leaves things

Phases 0-8 are done. The known gaps, all deliberate and none blocking:

- **Windows is claimed but unproven.** Every shim exists; none has run. The CI matrix is
  what will find out.
- **Build-from-source kexts**, argued against above rather than merely deferred.
- **`oc_resources()` downloads the whole ~9.7 MB OcBinaryData archive** to stage the ~0.8 MB
  default set. One request and one lock entry, which is why it was chosen; the alternative
  is dozens of both.
