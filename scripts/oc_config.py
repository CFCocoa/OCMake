#!/usr/bin/env python3
"""Assemble EFI/OC/config.plist.

Pipeline: hand-written base -> OCSnapshot (file-derived sections) -> declared overrides.

Snapshot runs before overrides so OCSnapshot's dependency ordering and plugin discovery
apply and CMake declarations still win. OCSnapshot preserves matched entries, so hand
edits in the base plist survive wherever no override is declared.

Standard library only (plistlib), Python 3.9+.
"""
import argparse
import base64
import binascii
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SECTIONS = (("ACPI", "Add"), ("Kernel", "Add"), ("UEFI", "Drivers"), ("Misc", "Tools"))

# Apple's boot-args live under this NVRAM GUID.
BOOT_GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"


def die(msg):
    sys.stderr.write("oc_config: {}\n".format(msg))
    raise SystemExit(1)


def load_plist(path, what):
    try:
        with open(path, "rb") as fh:
            return plistlib.load(fh)
    except FileNotFoundError:
        die("{} does not exist: {}".format(what, path))
    except Exception as exc:  # plistlib raises several types for malformed input
        die("{} is not a readable plist ({}): {}".format(what, exc, path))


def staged_kexts(oc_dir):
    """Every loadable bundle under OC/Kexts, spelled the way Kernel.Add spells it.

    Plugins nested in Contents/PlugIns are separate Kernel.Add entries carrying a path
    relative to OC/Kexts -- VoodooPS2Controller.kext/Contents/PlugIns/VoodooPS2Mouse.kext.
    Listing only top-level bundles made every plugin of every kext look unstaged, which is
    how the laptop example failed the moment it declared VoodooPS2.

    Staging is right to copy only the top-level bundle: the plugins travel inside it. It is
    this comparison that has to know they are separately addressable.
    """
    kexts = oc_dir / "Kexts"
    if not kexts.is_dir():
        return set()
    return {p.relative_to(kexts).as_posix() for p in kexts.rglob("*.kext")
            if p.is_dir() and (p / "Contents" / "Info.plist").is_file()}


def clear_derived(cfg):
    """Empty the four sections OCMake derives from the staged tree.

    This is exactly what OCSnapshot's -c does -- its whole implementation is four lines
    substituting [] for these lists. Doing it here means it can happen at scaffold time,
    when nothing is staged yet and there is no snapshot to run.
    """
    for section, key in SECTIONS:
        node = cfg.get(section)
        if isinstance(node, dict) and key in node:
            node[key] = []
    return cfg


def scaffold(sample_path, out_path):
    """Create a fresh config.plist from OpenCore's own Docs/Sample.plist.

    A new project has to start from something, and Sample.plist is what everyone copies.
    Copied raw it is a trap: OCSnapshot merges, so the sample's own entries -- among them a
    *disabled* VoodooPS2Controller.kext -- outrank what the project declares, and the kext
    stages, appears in Kernel.Add and never loads.

    Handing over a cleaned copy removes the trap at the source rather than detecting it
    later: a config.plist in an OCMake project is never a raw sample, because OCMake made
    it. Everything outside the four derived sections is kept, #WARNING keys included.
    """
    cfg = clear_derived(load_plist(sample_path, "OpenCore sample plist"))

    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as fh:
        plistlib.dump(cfg, fh, sort_keys=True)


def run_snapshot(snapshot, work, oc_dir, oc_version):
    cmd = [sys.executable, str(snapshot), "-i", str(work), "-o", str(work),
           "-s", str(oc_dir), "-f"]
    if oc_version:
        cmd += ["-v", oc_version]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    # OCSnapshot exits 0 even when it refuses to do anything ("OC folder passed does not
    # exist!"), so its status tells us nothing. The output is verified by the caller.
    if proc.returncode != 0:
        die("OCSnapshot failed ({}):\n{}\n{}".format(proc.returncode, proc.stdout, proc.stderr))
    return proc.stdout + proc.stderr


def verify_snapshot(cfg, oc_dir, log):
    for section, key in SECTIONS:
        if not isinstance(cfg.get(section), dict) or key not in cfg[section]:
            die("OCSnapshot did not produce {}/{}. Its output was:\n{}".format(section, key, log))
    listed = {e.get("BundlePath") for e in cfg["Kernel"]["Add"]}
    on_disk = staged_kexts(oc_dir)
    missing = on_disk - listed
    extra = listed - on_disk
    if missing or extra:
        die("Kernel.Add does not match the staged kexts.\n"
            "  staged but not listed: {}\n  listed but not staged: {}\n"
            "OCSnapshot output was:\n{}".format(sorted(missing), sorted(extra), log))


def deep_merge(base, overlay):
    """Recursively merge dicts; anything else replaces outright.

    Arrays replace rather than concatenate: an overlay that sets Kernel/Add would
    otherwise duplicate entries, and the snapshot owns those lists anyway.
    """
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], value)
        else:
            base[key] = value
    return base


def coerce(type_name, raw):
    t = type_name.upper()
    if t == "STRING":
        return raw
    if t == "INTEGER":
        try:
            return int(raw, 0)
        except ValueError:
            die("INTEGER value is not a number: {!r}".format(raw))
    if t == "REAL":
        try:
            return float(raw)
        except ValueError:
            die("REAL value is not a number: {!r}".format(raw))
    if t == "BOOL":
        if raw.upper() in ("ON", "TRUE", "YES", "1"):
            return True
        if raw.upper() in ("OFF", "FALSE", "NO", "0", ""):
            return False
        die("BOOL value is not a boolean: {!r}".format(raw))
    if t == "DATA":
        text = raw.strip()
        try:
            if text.startswith("<") and text.endswith(">"):
                return bytes.fromhex(text[1:-1].replace(" ", ""))
            return base64.b64decode(text, validate=True)
        except (ValueError, binascii.Error):
            die("DATA value is neither base64 nor <hex>: {!r}".format(raw))
    die("unknown type {!r}".format(type_name))


def set_keypath(cfg, keypath, value):
    """Set a '/'-separated key path. Numeric components index into arrays."""
    parts = [p for p in keypath.split("/") if p != ""]
    if not parts:
        die("empty keypath")
    node = cfg
    for i, part in enumerate(parts[:-1]):
        where = "/".join(parts[:i + 1])
        if isinstance(node, list):
            node = index_list(node, part, where)
        elif isinstance(node, dict):
            if part not in node:
                node[part] = {}          # create intermediate dicts
            node = node[part]
        else:
            die("{} is a {}, not a container".format(where, type(node).__name__))
    last = parts[-1]
    if isinstance(node, list):
        idx = as_index(last, keypath)
        if idx >= len(node):
            die("{}: index {} is out of range ({} entries)".format(keypath, idx, len(node)))
        node[idx] = value
    elif isinstance(node, dict):
        node[last] = value
    else:
        die("{} is a {}, not a container".format(keypath, type(node).__name__))


def as_index(part, where):
    if not part.isdigit():
        die("{}: '{}' indexes an array, so it must be a number".format(where, part))
    return int(part)


def index_list(node, part, where):
    idx = as_index(part, where)
    if idx >= len(node):
        die("{}: index {} is out of range ({} entries)".format(where, idx, len(node)))
    return node[idx]


def edit_boot_args(cfg, append, remove):
    entry = cfg.setdefault("NVRAM", {}).setdefault("Add", {}).setdefault(BOOT_GUID, {})
    current = entry.get("boot-args", "")
    if not isinstance(current, str):
        die("NVRAM boot-args is not a string")
    args = current.split()
    # Compare on the key of key=value args, so debug=0x100 replaces an existing debug=...
    def key_of(a):
        return a.split("=", 1)[0]
    drop = {key_of(a) for a in remove} | {key_of(a) for a in append}
    args = [a for a in args if key_of(a) not in drop]
    args += [a for a in append]
    entry["boot-args"] = " ".join(args)


def apply_ops(cfg, ops):
    for op in ops:
        kind = op.get("op")
        if kind == "overlay":
            deep_merge(cfg, load_plist(op["path"], "overlay"))
        elif kind == "set":
            set_keypath(cfg, op["keypath"], coerce(op["type"], op["value"]))
        elif kind == "bootargs":
            edit_boot_args(cfg, op.get("append", []), op.get("remove", []))
        else:
            die("unknown op {!r}".format(kind))


def apply_overrides(cfg, overrides):
    for bundle, fields in sorted(overrides.get("kexts", {}).items()):
        entries = [e for e in cfg["Kernel"]["Add"] if e.get("BundlePath") == bundle]
        if not entries:
            die("override for '{}' but it is not in Kernel.Add; is it declared?".format(bundle))
        for entry in entries:
            for key, value in sorted(fields.items()):
                entry[key] = value


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", help="hand-written config.plist")
    ap.add_argument("--oc-dir", help="staged EFI/OC directory")
    ap.add_argument("--snapshot", help="path to OCSnapshot.py")
    ap.add_argument("--out", help="config.plist to write")
    ap.add_argument("--overrides", help="JSON of declared per-entry overrides")
    ap.add_argument("--oc-version", help="OpenCore version, for the snapshot schema")
    ap.add_argument("--clean", action="store_true",
                    help="rebuild all four derived sections instead of merging into them")
    ap.add_argument("--sample", help="OpenCore's Docs/Sample.plist, for --scaffold")
    ap.add_argument("--scaffold", metavar="PATH",
                    help="create a fresh cleaned config.plist at PATH from --sample, then exit")
    args = ap.parse_args()

    if args.scaffold:
        if not args.sample:
            die("--scaffold needs --sample")
        scaffold(args.sample, args.scaffold)
        return 0
    for name, value in (("--base", args.base), ("--oc-dir", args.oc_dir),
                        ("--snapshot", args.snapshot), ("--out", args.out)):
        if not value:
            die("{} is required".format(name))

    oc_dir = Path(args.oc_dir)
    if not oc_dir.is_dir():
        die("staged OC directory does not exist: {}".format(oc_dir))

    cfg = load_plist(args.base, "base config.plist")

    declared = {"ops": [], "kexts": {}, "secrets": None}
    if args.overrides:
        with open(args.overrides) as fh:
            declared = json.load(fh)

    if args.clean:
        print("oc_config: rebuilding the four derived sections (CLEAN)")
        clear_derived(cfg)

    # Overlays, keypath sets and boot-args run *before* the snapshot, so the snapshot sees
    # a complete document and its schema fixups apply to whatever they added.
    apply_ops(cfg, declared.get("ops", []))

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "config.plist"
        with open(work, "wb") as fh:
            plistlib.dump(cfg, fh)
        log = run_snapshot(Path(args.snapshot), work, oc_dir, args.oc_version)
        cfg = load_plist(work, "snapshot output")
        verify_snapshot(cfg, oc_dir, log)

    apply_overrides(cfg, declared)

    # Secrets last: they must win over everything and never reach the committed config.
    if declared.get("secrets"):
        deep_merge(cfg, load_plist(declared["secrets"], "secrets"))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as fh:
        plistlib.dump(cfg, fh)  # XML: OpenCore reads both, diffs stay readable


if __name__ == "__main__":
    main()
