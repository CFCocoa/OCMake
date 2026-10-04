#!/usr/bin/env python3
"""Print a config.plist as flat assertable lines for the CMake tests."""
import plistlib
import sys

cfg = plistlib.load(open(sys.argv[1], "rb"))
adds = cfg["Kernel"]["Add"]
print("order " + ",".join(e["BundlePath"] for e in adds))
for e in adds:
    print("kext {} enabled={} min={} comment={}".format(
        e["BundlePath"], e.get("Enabled"), e.get("MinKernel", ""), e.get("Comment", "")))
    print("exec {}={}".format(e["BundlePath"], e.get("ExecutablePath", "")))
print("acpi " + ",".join(sorted(e["Path"] for e in cfg["ACPI"]["Add"])))
print("drivers " + ",".join(sorted(e["Path"] for e in cfg["UEFI"]["Drivers"])))
print("tools " + ",".join(sorted(e["Path"] for e in cfg["Misc"]["Tools"])))
