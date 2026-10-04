# IMPLEMENTATION.md

How OCMake actually works, at the level of files, functions, properties and file formats.

`PLAN.md` is the *why* — architecture in prose, plus a per-phase implementation log of the
decisions and the bugs behind them. This file is the *what and where*, so that picking the
work back up does not mean re-reading the source. When they disagree, the source wins and
this file is stale — say so.

Read §8 (**CMake rules learned the hard way**) before writing any CMake here; every rule in
it cost a real bug, several of them silent ones. Read §10 (**Vacuity checking**) before
adding a test, and again before believing one that passes.

---

## 1. Layout

```
OCMake.cmake              entry point: includes, init, the OC_DEFAULT_* table
cmake/OCUtil.cmake        logging, build-type mapping, the data model, provenance
cmake/OCLock.cmake        ocmake.lock read/write, OC_UPDATE / OC_OFFLINE
cmake/OCFetch.cmake       download + extract into the shared cache
cmake/OCResolve.cmake     GitHub API, asset picking, oc_require_package()
cmake/OCOpenCore.cmake    oc_opencore()
cmake/OCKext.cmake        oc_kext(), oc_driver(), oc_tool()
cmake/OCACPI.cmake        oc_ssdt(), oc_acpi(), iasl discovery
cmake/OCResources.cmake   oc_resources() -- OC/Resources from OcBinaryData
cmake/OCConfig.cmake      oc_config*(), oc_secrets(), the defaults machinery
cmake/OCPython.cmake      shared provisioning for scripts needing third-party packages
cmake/OCVault.cmake       oc_vault(), the vault.plist / vault.sig build step
cmake/OCValidate.cmake    ocvalidate discovery, provenance JSON, validate/report targets
cmake/OCEFI.cmake         oc_efi() and finalization (staging manifest, targets, install)
cmake/OCInstall.cmake     install-esp/diff-esp/outdated targets, CPack wiring
cmake/OCOutdated.cmake    runs under `cmake -P`; reads ocmake.lock, reports newer versions
cmake/OCStage.cmake       runs under `cmake -P` at build time; not included by OCMake.cmake
scripts/oc_config.py      base -> ops -> OCSnapshot -> overrides -> secrets
scripts/oc_check.py       OCMake's own sanity checks (`occheck-<n>`)
scripts/oc_report.py      BOM.md / BOM.json
scripts/oc_esp.py         ESP detection, diff and install (never mounts, never sudo)
third_party/OCSnapshot/   vendored from CorpNewt/OCSnapshot (BSD-3-Clause)
presets/CMakePresets.json the file every EFI repo is meant to copy verbatim
tests/                    ctest suite, all driven by `cmake -P` scripts
examples/minimal          Phase-0 example: OpenCore only, no config.plist
examples/b760i-aorus-pro  the real one, reproduces a known-good EFI
examples/laptop-template  a laptop starting point; never booted
examples/multi-efi        two EFIs in one repo, one directory each; never booted
examples/multi-efi-flat   two EFIs in one flat file, grouped by category; never booted
```

Floors: **CMake 3.25**, **Python 3.9**, standard library only. Presets file is version 6.
Ninja is the default generator; Unix Makefiles is tested and supported.

---

## 2. Lifecycle

Three distinct times things happen. Most confusion here comes from mixing them up.

### Configure time, in declaration order

`include(OCMake.cmake)` → includes all modules, `_oc_init_build_type()`,
`_oc_init_cache_dir()`, the `OC_DEFAULT_*` table, `find_package(Python3)`,
`enable_testing()`.

`enable_testing()` **must** be here. Called from the deferred finalize it is too late and
`CTestTestfile.cmake` is never written.

Then each `oc_*()` call resolves its EFI target (creating it on first use), fetches and
extracts what it needs *now* (archives are extracted at configure time, so their contents
can be globbed while generating), and records properties.

### End of directory — deferred finalization

`_oc_create_efi()` schedules `_oc_finalize_all` exactly once via
`cmake_language(DEFER DIRECTORY ${CMAKE_SOURCE_DIR} CALL _oc_finalize_all)`.

Deferred so that there is no "declared after `oc_efi()`" hole. Note who schedules it:
`_oc_create_efi()`, so the *first* `oc_*` call in a project arms finalization, not
`oc_efi()`. `oc_efi([<name>] [OUTPUT_DIR <dir>])` resolves the target, optionally overrides
`OC_OUTPUT_DIR`, and sets `OC_EFI` in the **caller's** scope so the declarations after it
belong to that EFI. It takes the name positionally, like `oc_kext(<name> ...)`, and rejects
anything else it is handed — which is the point of it being a call rather than
`set(OC_EFI ...)`: a misspelled variable is simply unread, the `PROJECT_NAME` fallback takes
over, and the declarations land on an EFI nobody named, silently and successfully. It is therefore optional (a project that
never calls it still builds) and order-independent (declarations after it still land), and
naming a second EFI or moving an output directory are the only things it is needed for.

Two EFIs declared in one directory cannot both fall back to the default `config.plist`;
that is refused, because they would share one machine's settings while each appeared to
have its own. Pointing both at one base through an explicit `oc_config()` is still allowed —
the difference is whether anyone chose it. The deferred call takes **no arguments** and walks the `OC_EFIS` global
registry, because `cmake_language(DEFER CALL f "${x}")` evaluates `${x}` when the call
*executes*, by which point a function-local `x` is gone.

`_oc_finalize_all()` prints a per-EFI summary when a project has more than one — which EFI
a declaration belongs to is valid CMake either way, so a misplaced one can only be shown,
never caught. `_oc_finalize_one()` then, per EFI: applies file defaults → writes the stage manifest →
`add_custom_command` for staging → config step → validation/report → `efi-<n>` target →
install rules. `_oc_finalize_all()` ends with `_oc_lock_flush()`.

### Build time

- `cmake -P cmake/OCStage.cmake -DOC_MANIFEST=... -DOC_EFI_DIR=...` wipes and rebuilds the
  EFI tree from the generated manifest.
- `python3 scripts/oc_config.py ...` writes `EFI/OC/config.plist`.
- `python3 scripts/oc_report.py ...` writes `BOM.md` / `BOM.json`.
- iasl compiles `.dsl` → `.aml` (its outputs are staging inputs).

`ctest` after a build runs `ocvalidate-<n>` and `occheck-<n>`.

---

## 3. The data model

Every EFI is an `INTERFACE` library named `oc_<name>` used as a typed property bag
(arbitrary properties on INTERFACE libraries need CMake 3.19+, comfortably under the
floor). `_oc_target(out explicit)` resolves which one a declaration belongs to:

> explicit `EFI <name>` argument **>** `OC_EFI` variable (block/subdirectory scope) **>** `PROJECT_NAME`

and creates it on first use. Output dir: `build/EFI` for the EFI named after the project,
`build/<name>/EFI` for any other — stated rather than magic, so adding a second EFI never
moves the first.

### Target properties

| Property | Written by | Meaning |
|---|---|---|
| `OC_NAME`, `OC_IS_EFI` | `_oc_create_efi` | identity |
| `OC_DECL_DIR` | `_oc_create_efi` | `CMAKE_CURRENT_SOURCE_DIR` at creation; base for default file lookup |
| `OC_OUTPUT_DIR` | `_oc_create_efi`, `oc_efi(OUTPUT_DIR)` | staged EFI root |
| `OC_OPENCORE_ROOT` | `oc_opencore` | extracted `X64/` dir; absence is a fatal error at finalize |
| `OC_OPENCORE_PKG` | `oc_opencore` | extraction root (holds `Utilities/`, `Docs/`) |
| `OC_OPENCORE_VER` / `_BUILD` | `oc_opencore` | resolved version and RELEASE/DEBUG |
| `OC_KEXT_SRCS` | `oc_kext` | absolute `.kext` bundle paths, in declaration order |
| `OC_KEXT_OVERRIDDEN` | `oc_kext` | bundles carrying per-entry overrides |
| `OC_KOVR_<bundle>_<FIELD>` | `oc_kext` | `MIN_KERNEL` `MAX_KERNEL` `ARCH` `ENABLED` `COMMENT` |
| `OC_ACPI_SRCS` | `oc_ssdt`, `oc_acpi` | `.aml` paths (compiled ones do not exist yet) |
| `OC_ACPI_SAMPLES` | `oc_ssdt(SAMPLES)` | sample names, for the drift check |
| `OC_DRIVERS` / `OC_TOOLS` | `oc_driver`, `oc_tool` | names inside the OpenCore package |
| `OC_DRIVERS_PATHS` / `OC_TOOLS_PATHS` | `oc_driver(PATH)`, `oc_tool(PATH)` | local `.efi` files |
| `OC_RES_SRCS` / `OC_RES_DSTS` | `oc_resources` | parallel lists: extracted dir -> `OC/Resources/<sub>` |
| `OC_CONFIG_BASE` | `oc_config`, `_oc_default_files` | hand-written base plist |
| `OC_CFG_SECRETS` | `oc_secrets`, `_oc_default_files` | merged last |
| `OC_CFG_OP_COUNT` | `_oc_add_op` | number of config ops |
| `OC_CFG_OP_<i>_KIND` + fields | `oc_config_overlay/_set/oc_boot_args` | one op; see below |
| `OC_DEFAULTS_APPLIED` | `_oc_default_ops` | human-readable list, for the status line |
| `OC_PROV_<KIND>` | `_oc_provenance` | items of that kind (`KEXT` `ACPI` `DRIVERS` `TOOLS` `PKG`) |
| `OC_PROV_<KIND>_<item>_<FIELD>` | `_oc_provenance` | `ORIGIN` `REPO` `VERSION` `URL` `SOURCE` |
| `OC_BOM_OUTPUTS` | `_oc_add_validation` | BOM files, so `efi-<n>` depends on them |

Non-alphanumerics in the `<bundle>` / `<item>` part are replaced with `_`.

**Config ops are stored indexed, not as a list** (`OC_CFG_OP_0_*`, `OC_CFG_OP_1_*`, …):
a keypath value or JSON blob can contain a semicolon, which would corrupt a CMake list.
Fields by kind: `overlay` → `PATH`; `set` → `KEYPATH` `TYPE` `VALUE`; `bootargs` →
`APPEND` `REMOVE`. **Order is semantic** — ops apply in index order, last writer wins.

Provenance origins: `github`, `url`, `local`, `opencore`, `prebuilt`, `compiled`,
`compiled-sample`.

### Global properties

`OC_EFIS` (registry of EFI names), `OC_FINALIZE_SCHEDULED`, `OC_LOCK_LOADED`,
`OC_LOCK_KNOWN` (keys read from the lockfile), `OC_LOCK_USED` (keys used this configure),
`OC_LOCK_<token>_{KEY,VERSION,BUILD,URL,SHA256}`.

### Cache variables / knobs

| Variable | Default | Purpose |
|---|---|---|
| `OC_BUILD` | `""` | **user override** of the variant; empty follows `CMAKE_BUILD_TYPE`. The *effective* value is a normal variable shadowing it — never cached. |
| `OC_CACHE_DIR` | `~/.cache/ocmake` (`LOCALAPPDATA` / `XDG_CACHE_HOME` respected) | shared archive + API cache |
| `OC_UPDATE` | `OFF` | re-resolve every pinned item, ignoring the lock |
| `OC_OFFLINE` | `OFF` | never touch the network; `file://` sources still work |
| `OC_DEFAULTS` | `ON` | apply the built-in defaults |
| `OC_DEFAULT_CONFIG` etc. | see `OCMake.cmake` | the defaults themselves; plain variables via `_oc_default()` |
| `OC_API_TTL` | `600` | seconds a cached GitHub API response stays fresh |
| `OC_OPENCORE_REPO` | `acidanthera/OpenCorePkg` | |
| `OC_BINARYDATA_REPO` | `acidanthera/OcBinaryData` | source of `OCBINARYDATA` drivers and (Phase 6) resources |
| `OC_BINARYDATA_REF` | `master` | resolved to a commit on a cold lock, then pinned |
| `OC_PYTHON_ENV` | managed under `OC_CACHE_DIR` | interpreter for scripts needing third-party packages |
| `OC_CRYPTOGRAPHY` | `cryptography>=42` | pip requirement for `oc_vault(SECUREBOOT)` |
| `OC_ESP` | `""` | ESP mount point; empty auto-detects. Also how you target a USB stick |
| `OC_ESP_BACKUP` | `ON` | archive the ESP's EFI before `install-esp` replaces it |
| `OC_ESP_BACKUP_DIR` | `<build>/esp-backup` | where that archive goes |
| `OC_PACKAGE` | `ON` | register the CPack ZIP |
| `OC_IASL` | found | ACPI compiler |
| `OC_IASL_MACIASL_TAG/_SHA`, `OC_IASL_ACPICA_TAG/_SHA` | pinned | per-platform iasl fallbacks |

`CMAKE_BUILD_TYPE` → `OC_BUILD`: `DEBUG`/`RELWITHDEBINFO` → `DEBUG`, everything else →
`RELEASE`. This single value drives the OpenCore package, every kext asset, the drivers,
and the `CONFIG` filter — see rule 8.6.

---

## 4. Public API

```cmake
oc_opencore([VERSION <x.y.z|latest>] [BUILD RELEASE|DEBUG] [ASSET <glob>]
            [URL <url> [SHA256 <hash>]] [EFI <name>])

oc_kext(<name> [GITHUB <owner/repo> VERSION <v>] [BUILD ...] [ASSET <glob>]
        [URL <url> [SHA256 <hash>]] [PATH <local .kext or dir>] [KEXTS <a> <b> ...]
        [MIN_KERNEL <v>] [MAX_KERNEL <v>] [ARCH <a>] [ENABLED <ON|OFF>] [COMMENT <s>]
        [EFI <name>])

oc_driver([<name> ...] [OCBINARYDATA <name> ... [REF <ref>]] [URL <url> [SHA256 <hash>]]
          [PATH <file.efi> ...] [EFI <name>])
oc_tool([<name> ...]   [URL <url> [SHA256 <hash>]] [PATH <file.efi> ...] [EFI <name>])

oc_ssdt(<file.dsl> ... [SAMPLES <name> ...] [FLAGS <iasl flags>] [EFI <name>])
oc_acpi(<file.aml> ... [EFI <name>])

oc_resources([OCBINARYDATA] [FONT ON|OFF] [LABEL ON|OFF] [AUDIO ON|OFF]
             [IMAGE ON|OFF|<set>] [REF <ref>] [URL <archive> [SHA256 <hash>]]
             [EFI <name>])

oc_config(<config.plist> [EFI <name>])
oc_config_overlay(<fragment.plist> [CONFIG <type>] [EFI <name>])
oc_config_set(<keypath> <STRING|INTEGER|BOOL|DATA|REAL> <value> [CONFIG <type>] [EFI <name>])
oc_boot_args([APPEND <arg> ...] [REMOVE <arg> ...] [CONFIG <type>] [EFI <name>])
oc_secrets(<plist> [OPTIONAL] [EFI <name>])

oc_efi([NAME <name>] [OUTPUT_DIR <dir>])
oc_lock(KEY ... VERSION ... BUILD ... URL ... SHA256 ...)   # only ever written by OCMake
```

### The argument convention

**A source keyword comes first and introduces the items that come from it. Bare arguments
mean the default source.** Follow this for anything added later.

```cmake
oc_ssdt(acpi/SSDT-X.dsl)                 # default source: files in the repo
oc_ssdt(SAMPLES SSDT-PLUG-ALT)           # from OpenCore's Docs/AcpiSamples/
oc_driver(OpenCanopy OpenRuntime)        # default source: the OpenCore package
oc_driver(OCBINARYDATA HfsPlus)          # from OcBinaryData
oc_driver(PATH drivers/Forked.efi)       # from the repo
```

One call may mix them: `oc_driver(OpenRuntime PATH local/Forked.efi URL <url>)` declares
three drivers from three sources, which a call-wide flag could not express.

`oc_kext()` and `oc_opencore()` look different, and are: they declare **one** package whose
first argument is the declaration's own name (also its lockfile key), with keyword
attributes after it. `KEXTS` there selects *within* the fetched archive — it is not a
source.

A driver or tool has four possible sources, and the last three all end up in
`OC_<kind>_PATHS` — once the binary is on disk, staging does not care where it came from:

| Form | Source |
|---|---|
| `oc_driver(OpenCanopy)` | the OpenCore package, staged by name at finalization |
| `oc_driver(OCBINARYDATA HfsPlus)` | OcBinaryData's `Drivers/`, pinned to a commit and locked |
| `oc_driver(URL <url> [SHA256 ...])` | any URL, named after the URL's basename; one per call, since `SHA256` pins that one file |
| `oc_driver(PATH drivers/X.efi)` | a local file — a fork, or something nobody publishes |

`OCBINARYDATA` exists because HfsPlus.efi (Apple's own driver, which OpenCorePkg cannot
redistribute) and the picker's `Resources/` live only in that repository's *tree*.
`acidanthera/OcBinaryData`'s GitHub releases are unrelated QEMU CI artefacts, so the
release-asset resolver cannot reach them — see `oc_require_file()`. `OC_BINARYDATA_REPO`
and `OC_BINARYDATA_REF` (default `master`) are the knobs; `REF` overrides per call.

`oc_resources()` fills `OC/Resources/` from the same repository. Defaults are FONT ON,
LABEL ON, IMAGE ON, AUDIO OFF — everything OpenCanopy needs to draw a picker. AUDIO is
opt-in: 362 `.wav` files and 6.3 MB, two thirds of the whole repository, read only when
`UEFI/Audio/AudioSupport` is on. The selectors name subdirectories *within* the source, so
they follow `oc_kext(... KEXTS ...)` rather than the source-first rule; `OCBINARYDATA` is
accepted and means what the defaults already do, so a call can name its source the way
`oc_driver()` does.

**IMAGE takes a set, and then writes `Misc/Boot/PickerVariant` itself.**
`IMAGE Acidanthera/GoldenGate` stages only that icon set — at its own path, since
PickerVariant addresses a set by where it sits inside `Resources/Image` — and sets the key
to match, converting `/` to the backslash OpenCore expects. Once the declaration names a
set, a plist repeating it is duplication with two ways to disagree. Bare `IMAGE` (or
`IMAGE ON`) stages the whole tree and leaves PickerVariant alone, which is what
`PickerVariant Auto` needs: it picks a set by macOS version, so all of them must be there.

PickerVariant is written as an ordinary config op at the call's position, so a later
`oc_config_set(Misc/Boot/PickerVariant ...)` still wins — the same ordering rule the
built-in defaults follow. A selector other than IMAGE given a non-boolean value is an
error, and a misspelled set lists the sets the archive actually holds.

Unlike a driver, resources come from **one archive of the repository at the pinned
commit**, not file by file. The default set is ~56 files: fetching them individually is
equally correct and equally verifiable, but it would put 56 entries per build variant into
a lockfile whose whole purpose is that a human reads it in a diff.

Keypath separator is `/` (NVRAM GUIDs contain dashes; dots would be ambiguous). Numeric
components index arrays: `Kernel/Add/0/Enabled`. `CONFIG <type>` is evaluated at configure
time against `OC_BUILD` only — OCMake is single-config by design, two build directories
coexist instead, so no generator expressions and the Python side never learns about build
types.

### Built-in defaults

The `OC_DEFAULT_*` table lives in `OCMake.cmake` and is the reference for what OCMake does
on its own. Applied at **two** moments, because "explicit wins" means two things:

- **ops are ordered** → seeded in `_oc_create_efi()` via `_oc_default_ops()`, *ahead* of
  every project declaration, so a later `oc_config_set()` overrides by coming later and
  `oc_boot_args(REMOVE ...)` composes with the default.
- **files are single-valued** → filled in at finalization via `_oc_default_files()`, the
  first point at which it is known the project declared none.

Debug-only, with no Release counterpart: every build re-derives `config.plist` from the
hand-written base, so Release simply never applies them. A committed `secrets.plist.example`
is how a project declares that it uses secrets — with the template present, a missing
`secrets.plist` is fatal and names it; with neither present, nothing is said.

`_oc_default(var value...)` only sets what is not already `DEFINED`, so `-D`, a pre-set
value and a post-include `set()` all win. Deliberately not cached: a cached copy of a value
that lives in `OCMake.cmake` goes stale in existing build dirs — the trap that made a
derived `OC_BUILD` unswitchable.

---

## 5. Internal helpers

Signatures are `(args)`; `out`-style parameters are variable *names* written with
`PARENT_SCOPE`.

**OCUtil** — `_oc_info` / `_oc_warn`; `_oc_default(var ...)`; `_oc_init_build_type()`;
`_oc_init_cache_dir()`; `_oc_target(out explicit)`; `_oc_create_efi(n)`;
`_oc_schedule_finalize()`; `_oc_provenance(t kind item [ORIGIN|REPO|VERSION|URL|SOURCE])`;
`_oc_relpath(path out)` — project-relative, so a BOM is not machine-specific.

**OCLock** — `_oc_lock_token(key out)`; `_oc_lock_load()`; `_oc_lock_get(key v b u s)`;
`_oc_lock_set(key version build url sha256)`; `_oc_lock_flush()`.

**OCFetch** — `oc_fetch_archive(URL {OUT_DIR|OUT_FILE} SHA256 NAME OUT_VAR OUT_SHA256)`.
Downloads to `OC_CACHE_DIR` and verifies; `OUT_DIR` then extracts, `OUT_FILE` copies the
verified file there instead (a single `.efi` out of a repository tree is not an archive).
Everything before that split — cache lookup, hash policy, `OC_OFFLINE` diagnostics — is
shared, which is why it is one function. `file://` sources are *always* re-fetched (the
cache is filename-keyed and a local file can change under it) and are exempt from
`OC_OFFLINE`, which means "no network", not "no filesystem".

**OCResources** — `oc_resources()`. **OCInstall** — `_oc_add_install_targets(n t outdir)`,
`_oc_add_target_aliases(n)`, `_oc_add_packaging(n t)`.

**OCResolve** — `_oc_glob_to_regex(glob out)`; `_oc_http_json(url out_json out_code)`;
`_oc_gh_release(repo ref out_json)` (retries a `v`-prefixed tag);
`_oc_pick_asset(json build glob out_name out_url out_build)`;
`oc_require_package(NAME GITHUB VERSION BUILD ASSET URL SHA256 OUT_DIR OUT_VERSION OUT_BUILD OUT_URL)`;
`_oc_gh_commit(repo ref out_sha)`;
`oc_require_ref(NAME {OUT_FILE|OUT_DIR} {REPO REF [PATH] | URL} SHA256 OUT_VERSION OUT_URL)`;
`_oc_archive_root(dir out)`.

`oc_require_ref()` is the counterpart to `oc_require_package()` for repositories whose
payload is in the tree rather than in release assets — same lockfile, cache and offline
guarantees. With `PATH` it fetches that one file; without, the whole repository archive
(`_oc_archive_root()` then descends the single `<repo>-<commit>/` wrapper directory). It
resolves the ref to a commit and builds a `raw.githubusercontent.com` URL containing that
commit, so the URL is immutable and the recorded hash can never disagree with what it
serves. Pinning matters: a `master` URL would hash differently the moment the branch moved,
and the failure would surface as a confusing `EXPECTED_HASH` download error on the next
cold cache.

`VERSION` defaults to `latest` in both `oc_opencore()` and `oc_kext()`, applied in
`oc_require_package()` **before the lock key is built** so the key carries the spec
(`Lilu|latest|RELEASE`) rather than an empty field. It is not applied when a `URL` was
given: that entry is pinned by the URL, and labelling it `latest` would be a lie. The
lockfile is what makes the default safe — whatever `latest` resolved to is pinned by URL
and hash until `-DOC_UPDATE=ON`.

Asset selection order: explicit `ASSET` glob → `-<BUILD>.zip` (**anchored on the dash**) →
`-RELEASE.zip` fallback → the sole asset if there is exactly one → error listing what was
available. Precedence for the hash: user `SHA256` > lockfile > resolver.

**OCKext** — `_oc_find_kexts(root out)` (globs the bare filename `Info.plist`, see rule
8.3); `_oc_kext_listing(bundles out)`; `_oc_add_efi_binaries(t kind names paths)`.

**OCACPI** — `_oc_add_acpi_compile(t src out prefix flags)` records one compile;
`_oc_add_acpi_steps(t)` emits the rules at finalization (see rule 8.14);
`_oc_require_iasl(out)` (system `iasl` → per-platform pinned fallback);
`_oc_basename(path out)` — strips **one** trailing extension by regex, because
`get_filename_component(NAME_WE)` cuts at the *first* dot and mangles `SSDT-XHC.1.dsl`.

**OCConfig** — `_oc_config_applies(cfg out)`; `_oc_add_op(t kind out_index)`;
`_oc_default_ops(n)`; `_oc_default_files(n t out)`; `_oc_json_str/_oc_json_list`;
`_oc_write_overrides(t file)`; `_oc_ops_json(t out)`;
`_oc_add_config_step(n t outdir stamp out_var)`.

**OCValidate** — `_oc_find_ocvalidate(pkg out)` (per-platform name; `file(CHMOD)` because
zip extraction drops the executable bit); `_oc_write_provenance(t file)`;
`_oc_add_validation(n t outdir config)` — returns early when there is no config, which is
why a config-less EFI gets no BOM and no ctest tests.

**OCEFI** — `_oc_stage_add(lines_var deps_var outs_var src dst)`; `_oc_finalize_all()`;
`_oc_finalize_one(n)`.

**OCPython** — `_oc_python_env(out MODULE <import> REQUIRE <pip spec> REASON <text>)`;
`_oc_python_has(interpreter module out)`. The shared answer to "a script needs a package".
Resolution is cheapest-first: the interpreter already found, then the environment managed
under `OC_CACHE_DIR` (keyed by interpreter version, shared across projects *and* packages),
then provisioning. Step one matters — where the package is already available nothing is
downloaded and `OC_OFFLINE` stays satisfiable. Availability is asked by importing, not by
looking for a directory: an install interrupted halfway leaves something that looks present
and is not.

**OCVault** — `oc_vault(<BASIC|SECUREBOOT> [<Release|Debug|All>])`;
`_oc_add_vault_step(n t outdir config stamp out_var)`. The step runs after the config step,
because the manifest covers `config.plist` too, and depends on the staging stamp as well:
signing patches the staged `OpenCore.efi`, and a restage would put the unpatched one back
while `vault.sig` still described the patched key.

`scripts/oc_vault.py --sign` replaces `RsaTool` + `sign.command`. The public key goes into
`OpenCore.efi` in Chromium's `RSAPublicKey` layout, which acidanthera widened to 64-bit
header fields — **528 bytes, not the 520 the docs cite**:

```
u64 nwords    RSA_size / 8, i.e. 32 for RSA-2048
u64 n0inv     -1 / n mod 2^64
u32 n[64]     modulus, little-endian words
u32 rr[64]    R^2 mod n, R = 2^(bit length of n)
```

Verified against the shipped `RsaTool` two ways: regenerating its own `-sign` blob from the
modulus alone, and comparing `-pub` output for a key of ours. Both byte-identical.
`sign.command` uses `hexdump`/`awk`/`dd` to write it into the zeroed slot between
`=BEGIN OC VAULT=` and `==END OC VAULT==`; a slice assignment does it here, which is why
`--sign` is not platform-gated.

Key generation and PKCS#1 v1.5 signing come from **pyca/cryptography**, imported lazily so
the manifest half still runs with nothing installed. Writing them by hand was measured
first: 53 lines against 5, with the 53 being a Miller-Rabin implementation. The library
replaces every piece of crypto, leaving only `public_blob()` and `embed_key()` — byte
layout, not cryptography, and unavoidable either way.

**OCResolve (Dortania)** — `_oc_dortania_build(project build out_version out_url out_sha
out_build)` reads a 10.5 MB index once (TTL-cached, and skipped entirely on a warm lock) and
returns the newest build's link plus its published SHA-256.

**OCStage** (runs under `cmake -P`) — `oc_stage_copy(src dst)`, `oc_stage_mkdir(dst)`.

---

## 6. Generated files and their formats

### `<build>/_oc/`

| Path | What |
|---|---|
| `<n>-stage.cmake` | generated manifest of `oc_stage_copy` / `oc_stage_mkdir` calls |
| `<n>-stage.stamp` | touched after staging; the config step depends on it |
| `<n>-overrides.json` | ops + per-kext overrides + declared kexts + secrets path |
| `<n>-provenance.json` | where every artefact came from, for the BOM |
| `binary/<Drivers\|Tools>/<x>.efi` | drivers and tools fetched as single files |
| `ocbinarydata/` | the OcBinaryData archive, extracted, for `oc_resources()` |
| `../esp-backup/EFI-<UTC>.zip` | what `install-esp` replaced (default location) |
| `OpenCore-<v>-<BUILD>/`, `kext-<name>/`, `acpi/` | extracted trees |

### `<n>-overrides.json`

```json
{ "ops": [ {"op":"overlay","path":"..."},
           {"op":"set","keypath":"Misc/Debug/Target","type":"INTEGER","value":"67"},
           {"op":"bootargs","append":["-v"],"remove":[]} ],
  "kexts": { "Lilu.kext": {"MinKernel":"20.0.0","Enabled":true,"Comment":"..."} },
  "declared_kexts": ["Lilu.kext", "..."],
  "secrets": "/abs/path/secrets.plist" }
```

`ops` order is significant. Consumed by `oc_config.py`; `declared_kexts` is also consumed by
`oc_check.py` as the manifest.

### `<n>-provenance.json`

```json
{ "kexts":    { "Lilu.kext": {"origin":"github","repo":"acidanthera/Lilu",
                              "version":"1.6.7","url":"https://..."} },
  "acpi":     { "SSDT-AWAC.aml": {"origin":"prebuilt","source":"acpi/SSDT-AWAC.aml"} },
  "drivers":  { "OpenCanopy.efi": {"origin":"opencore"} },
  "tools":    {},
  "packages": { "OpenCore": {"origin":"github","repo":"...","version":"1.0.7","url":"..."} } }
```

`origin: opencore` is resolved by the reporter to the *package's* source, so it is never
hardcoded to acidanthera — a `file://` or forked package cites itself.

### `ocmake.lock` (committed)

CMake source, one `oc_lock()` call per entry, sorted by key. Key is
`<name>|<version spec>|<BUILD>` plus `|<asset glob>` when `ASSET` was given — keyed on the
*spec*, so `latest` has a stable identity. Single-file entries from `oc_require_file()` use
`<repo>:<path in repo>|<ref>|<BUILD>` and carry the resolved commit as their `VERSION`.

Everything is keyed by `BUILD` even when the artefact has no build variants (OcBinaryData
drivers, kexts published as a single asset): entries for the *other* variant are precisely
what the flush preserves, so a build-less key would never be pruned when its declaration
goes away. The cost is one extra resolve the first time you switch variants.

`_oc_lock_flush()` writes the entries used this configure **plus every existing entry whose
`BUILD` differs from the current one**. Pruning everything unused looked tidy but deleted
the other variant's entries on every switch, so each Release↔Debug flip re-resolved
everything and exhausted the 60/hour anonymous API limit. Entries for the *current* variant
are still pruned, so removing a kext still removes its line.

### `OC_CACHE_DIR`

Archives at the top level keyed by filename; GitHub API responses at `api/<sha256 of url>.json`
with a `OC_API_TTL` freshness window. Extracted trees are *not* here — they live in the
build directory.

### Staged tree

`<build>/EFI/{BOOT,OC}`, with `OC/{ACPI,Drivers,Kexts,Resources,Tools}` created even when
empty (OCSnapshot refuses to run otherwise: "Incorrect OC Folder Structure").
`.contentFlavour` / `.contentVisibility` are staged next to both binaries. `BOM.md` and
`BOM.json` go *next to* `EFI/`, not inside it.

Install: `cmake --install <build> --prefix /Volumes/USB` → `/Volumes/USB/EFI/...`. No
`USE_SOURCE_PERMISSIONS` — the destination is usually FAT32.

---

## 7. Python scripts

All standard library, Python 3.9+.

**`oc_config.py`** `--base --oc-dir --snapshot --out [--overrides] [--oc-version]`
Pipeline: base → ops (overlay / set / bootargs) → **OCSnapshot** → per-entry overrides →
secrets. Snapshot runs before overrides so its dependency ordering and plugin discovery
apply while CMake declarations still win; it preserves matched entries, so hand edits in the
base survive wherever no override is declared.

Two OCSnapshot facts encoded here:
- It **exits 0 on some failures** ("OC folder passed does not exist!"), so its status tells
  you nothing → `verify_snapshot()` checks the four sections exist and that `Kernel.Add`
  matches the staged kexts exactly, and prints OCSnapshot's own output on mismatch.
- `-v` with a version it does not recognise selects the **oldest** schema (`UEFI.Drivers` as
  bare strings) and then crashes, so the flag is passed only for a plausible `X.Y.Z` and
  otherwise it auto-detects from the binary.

`edit_boot_args()` compares on the *key* of `key=value`, so `debug=0x100` replaces an
existing `debug=...` rather than duplicating it. Boot-args live under
`7C436110-AB2A-4BBB-A880-FE41995C9F82`.

`scaffold()` writes a new `config.plist` from the package's `Docs/Sample.plist` with the
four derived sections emptied — which is exactly what OCSnapshot's `-c` does (its whole
implementation is four lines substituting `[]` for those lists, and the two were verified to
produce byte-identical output). Doing it here rather than passing `-c` is what lets it
happen at creation time, when nothing is staged yet and there is no snapshot to run.

`staged_kexts()` walks recursively and returns paths relative to `OC/Kexts`, because a
kext's plugins under `Contents/PlugIns` are **separate `Kernel.Add` entries**
(`VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext`). Staging is right to copy
only the top-level bundle — the plugins travel inside it — but this comparison has to know
they are separately addressable, or every plugin reads as "listed but not staged".

**`oc_check.py`** `--efi --manifest [--sample]` — exits non-zero on any failure. Checks:
`declared-kexts`, `missing-file`, `kernel-range`, `duplicate-identifier`, `load-order`,
`picker-resources`, plus non-fatal `check_sample_drift` notes against OpenCore's
`Docs/Sample.plist`.

`picker-resources` exists because nothing in `config.plist` references the picker's icons,
font or labels, so no other check can notice they were never staged — the symptom is a
black screen at boot. It fires when OpenCanopy is enabled with `PickerMode: External` and
`Resources/Image` or `Resources/Font` is empty, and when `PickerVariant` names a set that
was not staged.

**`oc_esp.py`** `--efi --mode {diff,install} [--esp] [--backup-dir] [--no-backup]`
Two rules make this safe, and both are load-bearing:

- **It never mounts anything.** Mounting an ESP needs root on every platform. A build
  target that silently asks for a password — or fails in CI, or hangs in an IDE that
  swallows stdin — is worse than one that prints the command to run. Once mounted the ESP
  is writable *without* privileges (FAT32, mounted with ownership off), so the install
  itself needs none. Detection is macOS (`diskutil`, walking APFS physical stores to reach
  the boot disk) and Linux (`lsblk -J`, ESP type GUID); Windows asks for `-DOC_ESP=`.
- **It replaces `EFI/OC` and overwrites `EFI/BOOT`, and nothing else.** Wiping `EFI/`
  wholesale would delete `EFI/Microsoft`, `EFI/ubuntu` and every other loader sharing the
  partition. `OWNED` is the list of directories it may remove, and `split_removed()` keeps
  unowned files out of the *decision* as well as the report — counting them meant it never
  once said "up to date" on a dual-boot machine.

**`oc_report.py`** `--efi --name [--oc-version --oc-build --provenance --markdown --json]`
Renders BOM.md as markdown tables, grouped: kexts *Fetched* / *Local*, ACPI *Compiled* /
*Prebuilt*. Resources are reported one row per set with a file count, not one row per file
— 104 icons and labels would bury everything else, and the unit a reader cares about is
whether Audio is there at all. Two rendering passes — `merge_rows()` folds consecutive rows differing only in
the first column, stacking names with `<br>`; then blank-cell collapsing hides values
repeated from the row above. Sorting uses `source_key()` (plain source name, not the
rendered markdown link) with `sort_key()` = `(text.lower(), text)`, so case decides only
between otherwise-equal strings. **`BOM.json` is never folded or collapsed.**

---

## 8. CMake rules learned the hard way

Each of these was a real bug; most were silent.

**8.1 — `if(<var>)` matches CMake's false-constant table before dereferencing, case
insensitively.** `N`, `Y`, `NO`, `OFF`, `FALSE`, `IGNORE`, `NOTFOUND`, `""`, `0`. A variable
*named* `n` therefore always reads false whatever it holds — which made `if(NOT n)` in
`_oc_add_op` always true, so every config op overwrote index 0 and only the last survived.
A kext *named* `N` broke `if(NOT A_NAME)` the same way.
→ For anything holding user data, write `if("${x}" STREQUAL "")`, never the unary form.

**8.2 — `if(<var> STREQUAL "")` uses the literal token text when the variable is
undefined.** `if(NOT A_PATH STREQUAL "")` was *true* for an unset `A_PATH` (it compared the
string `A_PATH`), sending every kext down the local-PATH branch and sweeping up every bundle
in the source tree. → Always quote-dereference both sides: `if(NOT "${A_PATH}" STREQUAL "")`.

**8.3 — `file(GLOB_RECURSE)` anchors the directory part of the pattern.**
`"${root}/*/Contents/Info.plist"` misses `Kexts/VirtualSMC.kext/Contents/Info.plist`.
→ Use a bare filename pattern: `file(GLOB_RECURSE out "${root}/Info.plist")`.

**8.4 — `${ARGN}` expands as a list, so any argument containing `;` is split.** Inline
Python one-liners in tests were torn apart mid-statement. Worst in `run_expect_fail` cases:
a mangled command still fails, so the test passes for entirely the wrong reason.
→ Inline scripts use newlines, never semicolons.

**8.5 — `file(COPY <dir> DESTINATION <dst>)` nests the source inside the destination**;
the trailing-slash form `"${src}/"` copies its *contents*. Also, `file(COPY)` **preserves
source mtimes**, so staged files inherit the zip's timestamp, look older than the manifest,
and restage on every build → OCStage touches after copying.

**8.6 — A derived value must never be cached.** Caching the computed `OC_BUILD` made it
indistinguishable from a user override on the next configure, so a build directory
configured Release stayed Release for ever and `-DCMAKE_BUILD_TYPE=Debug` silently staged
RELEASE binaries. → The cache entry holds the *user's override* (empty = follow
`CMAKE_BUILD_TYPE`); the effective value is a normal variable recomputed every configure.
The same reasoning is why `_oc_default()` is not cached.

**8.7 — `CONFIG` must compare against the effective variant only.** Accepting
`CMAKE_BUILD_TYPE` too meant `-DOC_BUILD=DEBUG -DCMAKE_BUILD_TYPE=Release` applied *both*
Debug and Release ops, and it masked 8.6 by keeping a CONFIG op firing off
`CMAKE_BUILD_TYPE` while the binaries followed `OC_BUILD`.

**8.8 — Declare real staged files as `OUTPUT`, not just a stamp.** With a stamp alone, a
half-deleted EFI tree looks up to date and `cmake --install` happily copies it to a USB.

**8.9 — `cmake_language(DEFER CALL f "${x}")` evaluates arguments at execution time**, when
function-locals are gone. → Defer a no-argument finalizer over a global registry.

**8.10 — `file(DOWNLOAD)` discards the response body on HTTP error.** The status code has to
be recovered from the transfer `LOG`, and the log must never be printed — it contains the
`Authorization` header.

**8.11 — CMake's regex engine has no `{n}` repetition**, and `message()` wraps output at
arbitrary columns. → `assert_matches` flattens whitespace first; check lengths separately
with `string(LENGTH)`. The regex engine is also **byte-oriented**: `.` matches one byte of a
multi-byte character, so an em dash in a pattern will not behave.

**8.12 — OCSnapshot merges; an entry it can match keeps its settings, `Enabled` included.**
That is the feature — hand edits survive, which is what keeps b760i's version `Comment`s and
`ResetNvramEntry`'s `--preserve-boot` alive across a rebuild. It is also a trap for any
config copied from OpenCore's `Docs/Sample.plist`, which ships entries of its own including
a **disabled** `VoodooPS2Controller.kext`: the sample's opinion then outranks the
declaration and the kext stages, appears in `Kernel.Add` and never loads.

The fix is at the source, not in a detector: **if a declared `config.plist` is not on disk,
OCMake creates it** from the package's `Docs/Sample.plist` with the four derived sections
emptied (`scaffold()` in `oc_config.py`, via `_oc_scaffold_config()`). A config.plist in an
OCMake project is therefore never a raw sample. A file that exists is the user's and is
merged into, untouched.

Two earlier designs were tried and are worth not repeating. Cleaning *unconditionally* was
measured against b760i: it rewrites every `Comment` to the bundle name and drops
`ResetNvramEntry`'s `Arguments`. Cleaning when a section is *byte-identical to the sample*
works until OpenCore changes Sample.plist between releases, at which point it silently
stops firing — a heuristic whose failure mode is silence. File existence is a fact and has
neither problem.

**8.13 — `cmake_parse_arguments()` sets an unset option to the string `FALSE`, not to
nothing.** Testing it with `if(OPT)` is correct, but *forwarding* it as a value is not:
`DORTANIA "${A_DORTANIA}"` handed the resolver a project literally called `FALSE`, which it
dutifully failed to find. Normalise to empty in the `else()` branch before passing an option
along as a value.

**8.14 — `add_custom_command(OUTPUT)` is visible only to targets in the directory that
created it.** OCMake's targets are all created by the deferred finalize at the top level, so
a rule created where a declaration *stood* is unreachable if that declaration was in a
subdirectory. `oc_ssdt()` was the only one doing this, and a project laid out as one
`CMakeLists.txt` per machine — the idiomatic shape — failed with "No rule to make target
`_oc/acpi/laptop/SSDT-PLUG.aml`". The rules are now recorded on the target and emitted by
`_oc_add_acpi_steps()` during finalization, like everything else.

**8.15 — Second-granularity mtimes, and equal mtimes count as up to date.** Under Unix
Makefiles a regenerated input written in the same second as its consumer is considered
current. → Tests that rebuild after a reconfigure insert `cmake -E sleep 1.1`.

---

## 9. Tests

```bash
cmake -S . -B build && ctest --test-dir build --output-on-failure
```

`ctest -E "live|example"` skips everything needing network. Add `-G "Unix Makefiles"` to
run the suite on the other generator — do this before calling anything done.

| Test | Network | Covers |
|---|---|---|
| `stage` | no | staging, wipe-and-rebuild of stale files, directory timestamps, missing-source error |
| `resolve` | no | glob→regex, asset picking, build-variant anchoring |
| `presets` | no | `presets/CMakePresets.json` parses and matches the copies in examples |
| `http` | stub | 401/403/429/404 and malformed JSON, via `stub_api.py` |
| `phase2` | local | kexts, multi-kext archives, nested plugins, local PATH, drivers/tools (package, URL, PATH), variant switching |
| `config` | local | overlays, typed sets, boot-args, secrets, CONFIG filter, lock retention |
| `defaults` | local | the `OC_DEFAULT_*` machinery, precedence, opt-out, error paths |
| `validate` | no | ocvalidate discovery (stub), the six checks, BOM content and stability |
| `install` | local | `oc_resources()`, diff/install-esp, backups, CPack, `outdated` |
| `acpi` | local | iasl discovery, `.dsl` compilation, `SAMPLES`, BOM sort keys |
| `multi` | local | several `oc_efi()` scopes: separate trees, the install guard, no bare aliases |
| `resolve.live` | **yes** | the real GitHub API: tags, assets, ref→commit, a renamed repo, Dortania |
| `example.minimal` | **yes** | cold resolve, lock stability, tamper rejection, install, deleted-file restore, no-op rebuild |

`resolve.live` and `example.minimal` carry
`SKIP_REGULAR_EXPRESSION "GitHub API refused the request"` — a rate limit is an environment
condition, not a regression (the 403 path itself is covered deterministically by `http`).
The `acpi` test only registers when `iasl` is present or the platform is macOS (where it is
auto-fetched).

`make_fixture.py` writes a `# @EXTRA@` marker line into the generated `CMakeLists.txt`, and
tests that need extra declarations splice them in there. Do **not** anchor on a real call:
`string(REPLACE "oc_driver(" ...)` inserted twice the moment the fixture grew a second
`oc_driver()`, which broke `acpi` loudly and made `config` apply every op twice in silence.

Helpers: `tests/assert.cmake` (`assert_exists`, `assert_missing`, `assert_same_file`,
`assert_matches`, `assert_not_matches`, `run`, `run_expect_fail`, `step`),
`make_fixture.py` (a whole offline project: fake OpenCore package, kext archives, base
plist), `make_layers.py` (overlay + secrets plists), `stub_api.py`, `get_plist.py`,
`dump_config.py`.

### The discipline that matters

**Every regression guard is verified to fail when its fix is reverted.** This is the single
most important practice in the repo and it has its own section: see §10.

---

## 10. Vacuity checking

**A test that passes when its fix is removed proves nothing.** Every regression guard here
has been run against a deliberately broken tree. This is not a nicety: it has caught three
tests that were silently worthless, and surfaced two real bugs that a fully green suite was
hiding.

### The procedure

1. Revert **one** mechanism — the smallest edit that reinstates the original bug.
2. Run the specific test.
3. Confirm it fails, **and read the `FAIL (...)` line**: it must name *your* assertion.
4. Restore, then move to the next mechanism.

Step 3 is the one that gets skipped. A broken tree fails easily — a parse error, a missing
file, a command that dies before reaching the assertion — and every one of those "fails the
test" without telling you anything about the guard. If a mutation fails for the wrong
reason, the fixture or the assertion needs work, not the mutation.

Script the mutations rather than editing by hand; a forgotten restore is worse than no
check at all. The harness used throughout, adapted per change:

```bash
BK=$(mktemp -d); cp cmake/OCKext.cmake "$BK/"
check() {  # check <label> <ctest -R pattern>
  if ctest --test-dir "$BUILD" -R "$2" --output-on-failure >/tmp/v.out 2>&1
  then echo "VACUOUS: $1"
  else echo "ok: $1"; grep -m1 'FAIL (' /tmp/v.out
  fi
  cp "$BK"/*.cmake cmake/
}
```

Prefer mutations that reinstate the *original* defect over ones that merely break things:
`if(<guard>)` → `if(FALSE)` for a check, deleting the block for a feature. Renaming a
variable is almost always the wrong mutation — see case 3.

Each change's mechanism count is recorded in `PLAN.md` §9 ("all eight were reverted one at
a time and each failed for its own reason"). Enumerating them is part of the work: it is
how you notice the mechanism you did not test.

### How tests have actually lied

Five distinct mechanisms so far. Each defeats a different kind of care, so all five are
worth being able to recognise.

**1 — The fixture never exercises the path.** `OCStage` touches files after `file(COPY)`,
because `file(COPY)` preserves source mtimes; without the touch, staged kexts read as older
than the generated manifest and the whole tree restages every build. The guard passed with
the touch removed: Phase 0 staged no *directories*, and the file path used
`file(COPY_FILE)`, which sets a fresh mtime anyway — so nothing in the fixture could ever
carry an old timestamp. `test_stage.cmake` now ages the fixture's sources to 2020 with
`os.utime` and asserts the staged copy is not from 2020.

The same mechanism again, in Phase 6: the `outdated` de-duplication guard passed with the
fix removed, because the fixture had only ever been configured *once*, so its lockfile held
a single build variant and there was nothing to de-duplicate. The test now configures the
other variant first and asserts the lock really holds both.

**2 — Ordering makes the assertion true by luck.** An unanchored `RELEASE\.zip$` also
matches `NootedRed-0.8.10-RESEARCH_RELEASE.zip`. The guard passed with the anchor removed,
because the fixture happened to list `-RELEASE.zip` first and the correct asset won anyway.
`resolve_case.cmake` now carries a second fixture, `NOOTED_RESEARCH_FIRST`, with the assets
in the adversarial order — which is a perfectly possible API response, since GitHub returns
assets in upload order.

**3 — Incomplete revert.** The `if(NOT n)` bug (a variable *named* `n` always reads false —
rule 8.1). Reverting only the condition did not reproduce it, because the fix had *also*
renamed the variable, and the renamed variable was fine. Only restoring the name `n`
**and** the condition brought the bug back. If a fix changed two things, revert both.

**4 — The assertion is satisfied by a different mechanism.** `_oc_config_applies()`
accepted `CMAKE_BUILD_TYPE` as well as `OC_BUILD`, so `CONFIG Debug` ops fired off a value
the staged binaries did not follow. The build-type switching test kept passing the whole
time, because it observed the switch *through a CONFIG-filtered op* — derived from the very
value it was trying to test. It only surfaced under `-DOC_BUILD=DEBUG
-DCMAKE_BUILD_TYPE=Release`, where both variants' ops applied at once. The test now
observes `OC_BUILD` directly through a `Build/Variant` key. **Never assert on a value
computed by the thing under test.**

**5 — A shared fixture drifts out from under the tests.** `test_acpi` and `test_config`
spliced their declarations in with `string(REPLACE "oc_driver(" ...)`. The moment the
fixture grew a *second* `oc_driver()`, both spliced twice. `acpi` failed loudly with a
duplicate ACPI table. `config` kept passing while applying every op twice — invisible,
because setting the same key twice is idempotent. The fixture now carries a unique
`# @EXTRA@` marker on a line of its own. **Never anchor a splice on a real call.**

### Two real bugs the discipline surfaced

Not vacuous tests, but defects found only because a guard was interrogated instead of
trusted:

- **`oc_opencore()` recorded the default repository even when an explicit `URL` had
  bypassed resolution**, so a BOM could cite acidanthera/OpenCorePkg for a package that
  never came from there.
- **The reporter hardcoded the OpenCore package as the source of every driver.** That was
  "correct" only because `oc_driver()` could not express anything else. Rather than write a
  test for an unreachable case, `PATH` support was added first — so the test that a driver
  is not misattributed exercises a real code path.

The second generalises: **if a guard cannot fail today, it is not a guard.** Either make
the case reachable or stop claiming it is covered.

### Scope, and what is knowingly unguarded

This applies to *regression guards* — tests asserting that a specific defect stays fixed.
End-to-end feature tests do not need a mutation for every line, though they are still worth
watching for silently doing nothing (an `assert_matches` against output that is empty
passes nothing; `run_expect_fail` on a command mangled by rule 8.4 passes for the wrong
reason).

Known gaps, stated rather than pretended away:

- **`ONLY_IF_DIFFERENT` on the fetched-binary copy** has no test. A reconfigure restages
  regardless — the generated manifest is rewritten and is a dependency too — so there is
  nothing observable to assert. It is defensive, and the comment in `OCFetch.cmake` says so.
- **Restaging after a reconfigure** is structural rather than a defect. The invariant that
  *is* tested is the narrower "build twice without reconfiguring does no work".

---

## 11. Invariants

Things that are true today and should stay true; each has a test behind it.

1. A committed `ocmake.lock` plus a warm cache configures and builds with
   `-DOC_OFFLINE=ON`, making **zero** API calls.
2. Re-configuring leaves `ocmake.lock` byte-identical.
3. A tampered lock hash is rejected with a diagnostic that names the real problem — the
   archive is cached and its hash disagrees — not "not in the cache".
4. Release and Debug build directories coexist; switching either one never re-resolves the
   other's entries.
5. Deleting any file inside `build/EFI` is repaired by the next build.
6. A no-op rebuild does no work (nothing restages).
7. `config.plist` is re-derived from the hand-written base every build; OCMake only rewrites
   `ACPI.Add`, `Kernel.Add`, `UEFI.Drivers`, `Misc.Tools`, plus what the project declares.
8. Secrets are merged last and never appear in the committed base.
9. The b760i example reproduces its reference EFI and passes `ocvalidate` for the matching
   OpenCore version.
10. `BOM.json` is complete and unfolded, whatever `BOM.md` does for readability.
11. `install-esp` never removes a file outside `EFI/OC`, so another OS's loader on the
    same partition survives it.
12. Running `install-esp` twice in a row does nothing the second time, on a shared ESP
    as well as a dedicated one.

---

## 12. The examples

**`examples/minimal`** — OpenCore only, deliberately no `config.plist`. It exercises the
Phase-0 path and prints the "has no config.plist" notice; do not "fix" that by adding one
without also accounting for the Python/OCSnapshot dependency it would pull into the one
test that currently has none.

**`examples/laptop-template`** — a laptop starting point, **never booted**. Its
`config.plist` is OpenCore's own `Docs/Sample.plist` with the four derived sections emptied
and laptop-shaped edits applied. Its job in CI is to keep the laptop-only declarations
(VoodooPS2, SMCBatteryManager, `SSDT-PNLF`, nested plugins) exercised; its job in the repo
is to be honest that it is a template. Do not promote it to "validated" without hardware.

**`examples/b760i-aorus-pro`** — a real EFI pulled from GitHub, validated for Sonoma.
`config.plist` is committed with the four `PlatformInfo/Generic` identity keys blanked;
`secrets.plist` is gitignored and `secrets.plist.example` is the committed template.
`reference-EFI/` is gitignored ground truth (35 MB, 33 of which is downloadable kexts —
precisely the clutter OCMake exists to remove).

To compare a change against the previous behaviour without disturbing the tree:

```bash
git archive HEAD | tar -x -C /tmp/head   # then copy in the gitignored secrets.plist
```

build both, and `diff <(plutil -convert xml1 -o - a) <(plutil -convert xml1 -o - b)`.

---

## 13. Where things stand

Phases 0–6 are done and logged in `PLAN.md` §9, along with the built-in defaults, the
OcBinaryData source and the argument convention. **Phase 7** is next: CI and docs — a
reusable workflow, a README with the API reference, a laptop example alongside the desktop
one, and a matrix over macOS, Linux **and Windows** on both the CMake floor (3.25) and
current. Phase 8 is the stretch list (multiple `oc_efi()` scopes, DORTANIA/GIT sources,
build-from-source kexts, vaulting).

Working method, at the user's request: **one phase at a time**, because design gaps only
show up while writing the real implementation.
