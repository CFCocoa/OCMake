#!/usr/bin/env python3
"""Compare or install a staged EFI tree against the EFI System Partition.

Scope (PLAN.md §3.6): recovering from breakage the user just introduced. Not a backup
tool, and it never touches disks, partition tables or NVRAM.

Two rules keep it safe:

  * It never mounts anything. Mounting an ESP needs root on every platform, and a build
    target that silently asks for a password -- or fails in CI, or hangs in an IDE that
    swallows stdin -- is worse than one that prints the command to run. Once mounted the
    ESP is writable without privileges (it is FAT32, mounted without ownership), so the
    install itself needs none.
  * It replaces EFI/OC and overwrites EFI/BOOT, and nothing else. Wiping EFI/ wholesale
    would delete EFI/Microsoft, EFI/ubuntu and every other loader sharing the partition.

Standard library only, Python 3.9+.
"""
import argparse
import hashlib
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ESP_TYPE_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
# Replaced wholesale; anything stale inside is a bug waiting to boot.
OWNED = ("OC",)


def die(msg):
    sys.stderr.write("oc_esp: {}\n".format(msg))
    raise SystemExit(1)


def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout if p.returncode == 0 else None


def detect_macos():
    """(mount point or None, the command that would mount it)."""
    out = run(["diskutil", "info", "-plist", "/"])
    if not out:
        return None, None
    info = plistlib.loads(out)
    # On APFS, / lives on a synthesised disk; the ESP is on the physical store behind it.
    stores = info.get("APFSPhysicalStores") or []
    store = stores[0].get("APFSPhysicalStore") if stores else info.get("DeviceIdentifier")
    whole = run(["diskutil", "info", "-plist", store]) if store else None
    disk = plistlib.loads(whole).get("ParentWholeDisk") if whole else info.get("ParentWholeDisk")
    if not disk:
        return None, None
    out = run(["diskutil", "list", "-plist", disk])
    if not out:
        return None, None
    for d in plistlib.loads(out).get("AllDisksAndPartitions", []):
        for part in d.get("Partitions", []):
            if part.get("Content") != "EFI":
                continue
            ident = part["DeviceIdentifier"]
            pinfo = run(["diskutil", "info", "-plist", ident])
            mp = plistlib.loads(pinfo).get("MountPoint") if pinfo else None
            return (mp or None), "sudo diskutil mount {}".format(ident)
    return None, None


def detect_linux():
    out = run(["lsblk", "-J", "-o", "PATH,PARTTYPE,MOUNTPOINT"])
    if not out:
        return None, None
    def walk(nodes):
        for n in nodes:
            yield n
            yield from walk(n.get("children", []))
    for n in walk(json.loads(out).get("blockdevices", [])):
        if (n.get("parttype") or "").lower() == ESP_TYPE_GUID:
            return n.get("mountpoint") or None, "sudo mount {} /boot/efi".format(n["path"])
    return None, None


def detect_esp():
    system = platform.system()
    if system == "Darwin":
        return detect_macos()
    if system == "Linux":
        return detect_linux()
    return None, None


def resolve_esp(explicit):
    if explicit:
        path = Path(explicit)
        if not path.is_dir():
            die("OC_ESP is not a directory: {}".format(path))
        return path
    mount, how = detect_esp()
    if mount:
        return Path(mount)
    hint = "Pass the mount point explicitly: cmake -DOC_ESP=/path/to/esp ..."
    if how:
        die("the ESP was found but is not mounted. Mount it, then run this again:\n"
            "  {}\n{}".format(how, hint))
    extra = ""
    if platform.system() == "Windows":
        extra = "  On Windows, assign it a letter first:  mountvol S: /S\n"
    die("could not detect an EFI System Partition.\n{}{}".format(extra, hint))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def tree(root):
    """Relative path -> sha256, for every file under root."""
    out = {}
    if not root.is_dir():
        return out
    for base, _, files in os.walk(root):
        for name in files:
            if name == ".DS_Store":
                continue
            p = Path(base) / name
            out[str(p.relative_to(root))] = sha256(p)
    return out


def compare(staged, esp_efi):
    have = tree(esp_efi)
    want = tree(staged)
    added = sorted(set(want) - set(have))
    removed = sorted(set(have) - set(want))
    changed = sorted(k for k in set(have) & set(want) if have[k] != want[k])
    return added, removed, changed


def split_removed(removed):
    """(what install would delete, what it would leave alone).

    Only files under OWNED are ours to remove. Everything else on the partition belongs to
    another loader, so it is neither deleted nor counted as a difference -- counting it
    would mean this tool never once reported "up to date" on a dual-boot machine.
    """
    prune = [r for r in removed if r.split(os.sep, 1)[0] in OWNED]
    keep = [r for r in removed if r.split(os.sep, 1)[0] not in OWNED]
    return prune, keep


def report(added, removed, changed, esp_efi):
    prune, keep = split_removed(removed)
    for rel in added:
        print("  + {}".format(rel))
    for rel in changed:
        print("  ~ {}".format(rel))
    for rel in prune:
        print("  - {}".format(rel))
    print("{} added, {} changed, {} removed from {}".format(
        len(added), len(changed), len(prune), "/".join(OWNED)))
    if keep:
        print("{} file(s) elsewhere under {} are left alone "
              "(other loaders share this partition)".format(len(keep), esp_efi))


def backup(esp_efi, dest_dir):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest_dir.mkdir(parents=True, exist_ok=True)
    archive = dest_dir / "EFI-{}.zip".format(stamp)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for base, _, files in os.walk(esp_efi):
            for name in files:
                p = Path(base) / name
                z.write(p, str(Path("EFI") / p.relative_to(esp_efi)))
    return archive


def install(staged, esp_efi):
    for name in OWNED:
        target = esp_efi / name
        if target.exists():
            shutil.rmtree(target)
    for base, _, files in os.walk(staged):
        rel = Path(base).relative_to(staged)
        (esp_efi / rel).mkdir(parents=True, exist_ok=True)
        for name in files:
            if name == ".DS_Store":
                continue
            shutil.copy2(Path(base) / name, esp_efi / rel / name)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--efi", required=True, help="staged EFI directory")
    ap.add_argument("--mode", choices=("diff", "install"), required=True)
    ap.add_argument("--esp", default="", help="mount point; auto-detected when empty")
    ap.add_argument("--backup-dir", default="", help="where the pre-install archive goes")
    ap.add_argument("--no-backup", action="store_true")
    args = ap.parse_args()

    staged = Path(args.efi)
    if not (staged / "OC" / "OpenCore.efi").is_file():
        die("{} is not a built EFI tree -- run cmake --build first".format(staged))

    esp = resolve_esp(args.esp)
    esp_efi = esp / "EFI"
    print("ESP: {}".format(esp))

    added, removed, changed = compare(staged, esp_efi)
    prune, _ = split_removed(removed)
    pending = bool(added or changed or prune)

    if args.mode == "diff":
        if pending:
            report(added, removed, changed, esp_efi)
        else:
            print("up to date; nothing would change")
        return 0

    if not pending:
        print("up to date; nothing to do")
        return 0
    report(added, removed, changed, esp_efi)

    if esp_efi.is_dir() and not args.no_backup:
        dest = Path(args.backup_dir) if args.backup_dir else staged.parent / "esp-backup"
        archive = backup(esp_efi, dest)
        print("backed up the current EFI to {}".format(archive))
        print("  restore with:  unzip -o {} -d {}".format(archive, esp))
    install(staged, esp_efi)
    print("installed {} -> {}".format(staged, esp_efi))
    return 0


if __name__ == "__main__":
    sys.exit(main())
