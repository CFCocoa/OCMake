#!/usr/bin/env python3
"""OCMake's own sanity checks on a staged EFI.

These are deliberately the checks ocvalidate cannot make: it validates a config.plist
against OpenCore's schema, but it does not know what the project *declared*, and it does
not cross-check the plist against the files actually on disk.

Exit 0 if clean, 1 if any check fails. Standard library only.
"""
import argparse
import json
import plistlib
import sys
from pathlib import Path

import oc_vault

LILU = "as.vit9696.lilu"


class Report:
    def __init__(self):
        self.problems = []
        self.notes = []

    def fail(self, check, msg):
        self.problems.append((check, msg))

    def note(self, msg):
        self.notes.append(msg)


def kext_info(bundle):
    """(identifier, dependencies) from a kext bundle, lowercased for comparison."""
    plist = bundle / "Contents" / "Info.plist"
    if not plist.is_file():
        return None, {}
    try:
        with open(plist, "rb") as fh:
            info = plistlib.load(fh)
    except Exception:
        return None, {}
    ident = (info.get("CFBundleIdentifier") or "").lower()
    libs = {k.lower() for k in (info.get("OSBundleLibraries") or {})}
    return ident, libs


def parse_kernel_version(value):
    """'20.4.0' -> (20, 4, 0); empty means unbounded."""
    if not value:
        return None
    parts = []
    for chunk in str(value).split("."):
        try:
            parts.append(int(chunk))
        except ValueError:
            return None
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def check_declared_kexts(cfg, manifest, rep):
    """Every kext the project declared must be present and enabled."""
    declared = manifest.get("declared_kexts") or []
    listed = {e.get("BundlePath"): e for e in cfg["Kernel"]["Add"]}
    for bundle in declared:
        entry = listed.get(bundle)
        if entry is None:
            rep.fail("declared-kexts", "{} was declared but is not in Kernel.Add".format(bundle))
        elif not entry.get("Enabled", False):
            # Only a problem when the project did not ask for it.
            overrides = (manifest.get("kexts") or {}).get(bundle) or {}
            if overrides.get("Enabled") is not False:
                rep.fail("declared-kexts", "{} is in Kernel.Add but disabled".format(bundle))


def check_files_exist(cfg, oc_dir, rep):
    """Everything the plist points at must actually be staged."""
    for entry in cfg["ACPI"]["Add"]:
        if entry.get("Enabled", True) and not (oc_dir / "ACPI" / entry["Path"]).is_file():
            rep.fail("missing-file", "ACPI.Add references ACPI/{} which is not staged".format(entry["Path"]))
    for section, folder in (("Drivers", "Drivers"), ("Tools", "Tools")):
        entries = cfg["UEFI"]["Drivers"] if section == "Drivers" else cfg["Misc"]["Tools"]
        for entry in entries:
            if entry.get("Enabled", True) and not (oc_dir / folder / entry["Path"]).is_file():
                rep.fail("missing-file",
                         "{} references {}/{} which is not staged".format(section, folder, entry["Path"]))
    for entry in cfg["Kernel"]["Add"]:
        bundle = oc_dir / "Kexts" / entry["BundlePath"]
        if not bundle.is_dir():
            rep.fail("missing-file", "Kernel.Add references {} which is not staged".format(entry["BundlePath"]))
            continue
        for key, folder in (("ExecutablePath", None), ("PlistPath", None)):
            rel = entry.get(key)
            if rel and not (bundle / rel).is_file():
                rep.fail("missing-file", "{}: {} points at {} which does not exist".format(
                    entry["BundlePath"], key, rel))


def check_kernel_ranges(cfg, rep):
    for entry in cfg["Kernel"]["Add"]:
        lo = parse_kernel_version(entry.get("MinKernel"))
        hi = parse_kernel_version(entry.get("MaxKernel"))
        if lo and hi and lo > hi:
            rep.fail("kernel-range", "{}: MinKernel {} is above MaxKernel {}".format(
                entry["BundlePath"], entry.get("MinKernel"), entry.get("MaxKernel")))


def ranges_overlap(a, b):
    a_lo = parse_kernel_version(a.get("MinKernel")) or (0, 0, 0)
    a_hi = parse_kernel_version(a.get("MaxKernel")) or (9999, 0, 0)
    b_lo = parse_kernel_version(b.get("MinKernel")) or (0, 0, 0)
    b_hi = parse_kernel_version(b.get("MaxKernel")) or (9999, 0, 0)
    return a_lo <= b_hi and b_lo <= a_hi


def check_duplicate_identifiers(cfg, oc_dir, rep):
    """Two enabled kexts with the same bundle identifier and overlapping kernel ranges."""
    by_ident = {}
    for entry in cfg["Kernel"]["Add"]:
        if not entry.get("Enabled", True):
            continue
        ident, _ = kext_info(oc_dir / "Kexts" / entry["BundlePath"])
        if ident:
            by_ident.setdefault(ident, []).append(entry)
    for ident, entries in sorted(by_ident.items()):
        for i, first in enumerate(entries):
            for second in entries[i + 1:]:
                if ranges_overlap(first, second):
                    rep.fail("duplicate-identifier",
                             "{} and {} both provide {} over overlapping kernel ranges".format(
                                 first["BundlePath"], second["BundlePath"], ident))


def check_load_order(cfg, oc_dir, rep):
    """A kext must appear after every kext it depends on -- Lilu plugins after Lilu."""
    order = []
    for entry in cfg["Kernel"]["Add"]:
        if not entry.get("Enabled", True):
            continue
        ident, libs = kext_info(oc_dir / "Kexts" / entry["BundlePath"])
        order.append((entry["BundlePath"], ident, libs))
    position = {}
    for index, (_, ident, _) in enumerate(order):
        if ident and ident not in position:
            position[ident] = index
    for index, (bundle, _, libs) in enumerate(order):
        for dep in sorted(libs):
            if dep in position and position[dep] > index:
                who = "Lilu" if dep == LILU else dep
                rep.fail("load-order", "{} loads before {}, which it depends on".format(bundle, who))


def check_picker_resources(cfg, oc_dir, rep):
    """OpenCanopy with an empty Resources/ draws nothing -- a black screen at boot.

    The graphical picker reads its icons from Resources/Image, its font from
    Resources/Font and its entry labels from Resources/Label. None of it ships with
    OpenCore: it lives in OcBinaryData, which is what oc_resources() fetches. Nothing
    in config.plist references those files, so no other check can notice they are absent.
    """
    drivers = [d.get("Path") for d in cfg.get("UEFI", {}).get("Drivers", [])
               if d.get("Enabled", True)]
    if "OpenCanopy.efi" not in drivers:
        return
    if cfg.get("Misc", {}).get("Boot", {}).get("PickerMode") != "External":
        return
    for sub in ("Image", "Font"):
        d = oc_dir / "Resources" / sub
        if not d.is_dir() or not any(p.is_file() for p in d.rglob("*")):
            rep.fail("picker-resources",
                     "OpenCanopy is enabled and PickerMode is External, but "
                     "Resources/{} is empty; add oc_resources()".format(sub))
            return

    # PickerVariant names a directory *inside* Resources/Image, so a config naming a set
    # that was never staged falls back to the built-in icons without saying so.
    variant = cfg["Misc"]["Boot"].get("PickerVariant", "Auto")
    if variant and variant not in ("Auto", "Default"):
        rel = variant.replace("\\", "/").strip("/")
        if not (oc_dir / "Resources" / "Image" / rel).is_dir():
            rep.fail("picker-resources",
                     "PickerVariant is '{}' but Resources/Image/{} was not staged".format(
                         variant, rel))


def check_vault(cfg, oc_dir, rep):
    """A vault OpenCore is told to enforce must match the tree it ships with.

    Vault Basic makes OpenCore refuse any file whose digest disagrees with vault.plist, so
    a manifest that has drifted from the staged tree is not a warning -- it is a machine
    that stops at the picker. Recomputed here rather than trusted, because the whole point
    of the check is the case where the generator did not run.
    """
    mode = cfg.get("Misc", {}).get("Security", {}).get("Vault", "Optional")
    if mode == "Optional":
        return
    path = oc_dir / "vault.plist"
    if not path.is_file():
        rep.fail("vault", "Misc/Security/Vault is {} but OC/vault.plist is missing".format(mode))
        return
    if mode == "Secure" and not (oc_dir / "vault.sig").is_file():
        rep.fail("vault", "Misc/Security/Vault is Secure but OC/vault.sig is missing; "
                          "OCMake generates Basic manifests only")

    try:
        listed = plistlib.load(open(path, "rb")).get("Files") or {}
    except Exception as exc:
        rep.fail("vault", "vault.plist is not readable ({})".format(exc))
        return
    actual = oc_vault.vault_files(oc_dir)
    for name in sorted(set(actual) - set(listed)):
        rep.fail("vault", "{} is staged but not in vault.plist".format(name))
    for name in sorted(set(listed) - set(actual)):
        rep.fail("vault", "vault.plist lists {}, which is not staged".format(name))
    for name in sorted(set(listed) & set(actual)):
        if bytes(listed[name]) != actual[name]:
            rep.fail("vault", "{} does not match its vault.plist digest".format(name))


def check_sample_drift(cfg, sample_path, rep):
    """Top-level keys OpenCore's own sample has that this config lacks, and vice versa."""
    if not sample_path or not Path(sample_path).is_file():
        return
    try:
        with open(sample_path, "rb") as fh:
            sample = plistlib.load(fh)
    except Exception:
        return
    missing = sorted(set(sample) - set(cfg))
    extra = sorted(k for k in set(cfg) - set(sample) if not k.startswith("#"))
    if missing:
        rep.note("top-level keys in OpenCore's Sample.plist but not here: {}".format(", ".join(missing)))
    if extra:
        rep.note("top-level keys here but not in Sample.plist: {}".format(", ".join(extra)))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--efi", required=True, help="staged EFI directory")
    ap.add_argument("--manifest", help="OCMake overrides JSON, for what was declared")
    ap.add_argument("--sample", help="OpenCore Docs/Sample.plist, for key drift")
    args = ap.parse_args()

    oc_dir = Path(args.efi) / "OC"
    config = oc_dir / "config.plist"
    if not config.is_file():
        sys.stderr.write("oc_check: {} does not exist -- build first\n".format(config))
        return 1
    with open(config, "rb") as fh:
        cfg = plistlib.load(fh)

    manifest = {}
    if args.manifest and Path(args.manifest).is_file():
        with open(args.manifest) as fh:
            manifest = json.load(fh)

    rep = Report()
    check_declared_kexts(cfg, manifest, rep)
    check_files_exist(cfg, oc_dir, rep)
    check_kernel_ranges(cfg, rep)
    check_duplicate_identifiers(cfg, oc_dir, rep)
    check_load_order(cfg, oc_dir, rep)
    check_picker_resources(cfg, oc_dir, rep)
    check_vault(cfg, oc_dir, rep)
    check_sample_drift(cfg, args.sample, rep)

    for msg in rep.notes:
        print("note: {}".format(msg))
    if not rep.problems:
        print("oc_check: all checks passed")
        return 0
    for check, msg in rep.problems:
        sys.stderr.write("FAIL [{}] {}\n".format(check, msg))
    sys.stderr.write("oc_check: {} problem(s)\n".format(len(rep.problems)))
    return 1


if __name__ == "__main__":
    sys.exit(main())
