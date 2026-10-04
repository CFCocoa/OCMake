#!/usr/bin/env python3
"""Build a self-contained OCMake project for the Phase 2 tests.

Creates a fake OpenCore package and kext archives so kext discovery, multi-kext
selection, local bundles, drivers/tools and the config step can all be exercised
offline. Usage: make_fixture.py <workdir> <ocmake_root>
"""
import plistlib
import shutil
import sys
import zipfile
from pathlib import Path


def kext(path, ident, executable=None, libraries=None):
    (path / "Contents").mkdir(parents=True, exist_ok=True)
    info = {
        "CFBundleIdentifier": ident,
        "CFBundlePackageType": "KEXT",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1.0",
    }
    if executable:
        info["CFBundleExecutable"] = executable
        (path / "Contents" / "MacOS").mkdir(exist_ok=True)
        (path / "Contents" / "MacOS" / executable).write_bytes(b"\xcf\xfa\xed\xfe fake")
    if libraries:
        info["OSBundleLibraries"] = libraries
    with open(path / "Contents" / "Info.plist", "wb") as fh:
        plistlib.dump(info, fh)


def zipdir(src, archive, arcbase=""):
    with zipfile.ZipFile(archive, "w") as z:
        for p in sorted(src.rglob("*")):
            if p.is_file():
                z.write(p, str(Path(arcbase) / p.relative_to(src)))


def main():
    work = Path(sys.argv[1]).resolve()
    root = Path(sys.argv[2]).resolve()
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)

    # --- fake OpenCore package: X64/EFI/... plus the empty dirs OCSnapshot requires
    pkg = work / "pkgsrc"
    boot = pkg / "X64" / "EFI" / "BOOT"
    oc = pkg / "X64" / "EFI" / "OC"
    boot.mkdir(parents=True)
    (oc / "Drivers").mkdir(parents=True)
    (oc / "Tools").mkdir(parents=True)
    (boot / "BOOTx64.efi").write_bytes(b"MZ fake bootstrap")
    (boot / ".contentFlavour").write_text("Auto")
    # Real OpenCore.efi carries a zeroed 528-byte slot between these markers, which is
    # where oc_vault(SECUREBOOT) writes the public key. Without it the fixture could only
    # ever test the refusal path.
    (oc / "OpenCore.efi").write_bytes(
        b"MZ fake opencore" + b"=BEGIN OC VAULT=" + bytes(528) + b"==END OC VAULT==")
    (oc / ".contentFlavour").write_text("Auto")
    for d in ("OpenRuntime.efi", "OpenCanopy.efi", "Unused.efi"):
        (oc / "Drivers" / d).write_bytes(b"MZ fake driver")
    (oc / "Tools" / "OpenShell.efi").write_bytes(b"MZ fake tool")
    # A stand-in ocvalidate, so discovery and test registration are exercised. Upstream's
    # real one is version-locked to the OpenCore it ships with.
    val = pkg / "Utilities" / "ocvalidate"
    val.mkdir(parents=True)
    for stub in ("ocvalidate", "ocvalidate.linux", "ocvalidate.exe"):
        path = val / stub
        path.write_text("#!/bin/sh\necho 'stub ocvalidate:' \"$1\"\nexit 0\n")
        path.chmod(0o755)

    samples = pkg / "Docs" / "AcpiSamples" / "Source"
    samples.mkdir(parents=True)
    (samples / "SSDT-SAMPLE.dsl").write_text(
        'DefinitionBlock ("", "SSDT", 2, "OCM", "SAMPLE", 0x00000000)\n'
        '{\n    External (_SB_, DeviceObj)\n    Scope (\\_SB)\n'
        '    {\n        Device (SMP0)\n        {\n'
        '            Name (_HID, "SMPL0000")\n        }\n    }\n}\n')
    # --- the package's own Docs/Sample.plist, and two bases derived from it.
    # Its Kernel/Add disables Alpha.kext: that is the shape that bit the laptop example,
    # where Sample.plist's disabled VoodooPS2Controller outranked the declaration.
    sample = {
        "ACPI": {"Add": [{"Comment": "sample", "Enabled": True, "Path": "SSDT-SAMPLE.aml"}]},
        "Kernel": {"Add": [{"BundlePath": "Alpha.kext", "Comment": "from the sample",
                            "Enabled": False, "ExecutablePath": "Contents/MacOS/Alpha",
                            "MaxKernel": "", "MinKernel": "", "PlistPath": "Contents/Info.plist"}]},
        "UEFI": {"Drivers": [{"Comment": "sample", "Enabled": True, "Path": "Sample.efi"}]},
        # Vault Secure is what OpenCore's real Sample.plist ships, and it is unusable
        # without a vault.plist: the scaffold has to relax it.
        "Misc": {"Security": {"Vault": "Secure"},
                 "Tools": [{"Comment": "sample", "Enabled": True, "Name": "Sample",
                            "Path": "Sample.efi"}]},
    }
    (pkg / "Docs").mkdir(parents=True, exist_ok=True)
    with open(pkg / "Docs" / "Sample.plist", "wb") as fh:
        plistlib.dump(sample, fh)

    zipdir(pkg, work / "opencore.zip")

    # --- flat archive: one bundle at the root (the Lilu shape)
    flat = work / "flatsrc"
    kext(flat / "Alpha.kext", "test.alpha", executable="Alpha")
    zipdir(flat, work / "flat.zip")

    # --- nested archive: several bundles under Kexts/ (the VirtualSMC shape).
    # Beta depends on Alpha, so a correct snapshot orders Alpha first.
    nested = work / "nestedsrc"
    kext(nested / "Kexts" / "Beta.kext", "test.beta", executable="Beta",
         libraries={"test.alpha": "1.0"})
    kext(nested / "Kexts" / "Gamma.kext", "test.gamma", executable="Gamma")
    # A plugin nested inside Beta (the VoodooPS2Controller shape). OpenCore loads it as a
    # separate Kernel.Add entry addressed through its parent, but staging copies only the
    # parent -- the plugin travels inside it.
    kext(nested / "Kexts" / "Beta.kext" / "Contents" / "PlugIns" / "BetaPlugin.kext",
         "test.beta.plugin", executable="BetaPlugin", libraries={"test.beta": "1.0"})
    zipdir(nested, work / "nested.zip")

    # A driver that did not come from OpenCore -- a fork, or one OpenCore does not ship.
    (work / "local").mkdir(exist_ok=True)
    (work / "local" / "Forked.efi").write_bytes(b"MZ forked driver")

    # A driver fetched as a bare file rather than out of an archive: the OcBinaryData
    # shape (HfsPlus.efi and friends live in a repo tree, not in a release), served over
    # file:// so the test needs no network.
    (work / "remote").mkdir(exist_ok=True)
    (work / "remote" / "Remote.efi").write_bytes(b"MZ remote driver")

    # --- local bundle, plist-only (the CPUFriendDataProvider shape)
    kext(work / "local" / "Delta.kext", "test.delta")

    # --- an OcBinaryData-shaped archive: a single top-level directory, as GitHub's
    # zipballs have, so _oc_archive_root() has something real to descend into.
    obd = work / "obdsrc" / "OcBinaryData-testcommit"
    for sub, names in (("Font", ["Font_1x.bin"]),
                       ("Label", ["Apple.lbl"]),
                       ("Image/Acidanthera/Test", ["Cursor.icns"]),
                       # A second set, so "only the one that was named" is provable.
                       ("Image/Acidanthera/Other", ["Cursor.icns"]),
                       ("Audio", ["AXEFIAudio_Beep.wav"])):
        (obd / "Resources" / sub).mkdir(parents=True, exist_ok=True)
        for n in names:
            (obd / "Resources" / sub / n).write_bytes(b"fake " + n.encode())
    zipdir(work / "obdsrc", work / "ocbinarydata.zip", arcbase="")

    # --- minimal hand-written config.plist
    base = {
        "ACPI": {"Add": [], "Delete": [], "Patch": [], "Quirks": {}},
        "Booter": {"MmioWhitelist": [], "Patch": [], "Quirks": {}},
        "DeviceProperties": {"Add": {}, "Delete": {}},
        "Kernel": {"Add": [], "Block": [], "Emulate": {}, "Force": [],
                   "Patch": [], "Quirks": {}, "Scheme": {}},
        "Misc": {"BlessOverride": [], "Boot": {}, "Debug": {}, "Entries": [],
                 "Security": {}, "Serial": {}, "Tools": []},
        "NVRAM": {"Add": {}, "Delete": {}},
        "PlatformInfo": {"Generic": {}},
        "UEFI": {"APFS": {}, "Audio": {}, "Drivers": [], "Input": {}, "Output": {},
                 "ProtocolOverrides": {}, "Quirks": {}, "ReservedMemory": []},
    }
    with open(work / "base.plist", "wb") as fh:
        plistlib.dump(base, fh)

    # Two more bases, differing only in where the disabled Alpha entry came from.
    import copy
    from_sample = copy.deepcopy(base)
    for sec, key in (("ACPI", "Add"), ("Kernel", "Add"), ("UEFI", "Drivers"), ("Misc", "Tools")):
        from_sample[sec][key] = copy.deepcopy(sample[sec][key])
    with open(work / "sample-base.plist", "wb") as fh:
        plistlib.dump(from_sample, fh)

    own = copy.deepcopy(base)
    own["Kernel"]["Add"] = [dict(sample["Kernel"]["Add"][0], Comment="mine, on purpose")]
    with open(work / "own-base.plist", "wb") as fh:
        plistlib.dump(own, fh)

    url = lambda name: "file://" + str(work / name)
    (work / "CMakeLists.txt").write_text("""\
cmake_minimum_required(VERSION 3.25...4.4)
project(fixture NONE)
include({root}/OCMake.cmake)

oc_opencore(VERSION 1.0.7 URL "{opencore}")
oc_config(base.plist)

oc_kext(Alpha URL "{flat}" MIN_KERNEL 20.0.0 COMMENT "pinned by test")
oc_kext(Beta  URL "{nested}" KEXTS Beta)
oc_kext(Delta PATH local/Delta.kext ENABLED OFF)

# Tests splice further declarations in at the marker below. It is a unique token because
# anchoring on a real call (oc_driver, say) silently inserts twice the moment the fixture
# grows a second one -- which is exactly what happened when a second oc_driver() arrived.
# @EXTRA@

oc_driver(OpenRuntime OpenCanopy PATH local/Forked.efi URL "{remote}")
oc_tool(OpenShell)

oc_efi()
""".format(root=root.as_posix(), opencore=url("opencore.zip"),
           flat=url("flat.zip"), nested=url("nested.zip"),
           remote=url("remote/Remote.efi")))


if __name__ == "__main__":
    main()
