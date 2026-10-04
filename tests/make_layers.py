#!/usr/bin/env python3
"""Write the overlay and secrets plists used by test_config.cmake."""
import plistlib
import sys
from pathlib import Path

fx = Path(sys.argv[1])
BOOT_GUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"

with open(fx / "overlay.plist", "wb") as fh:
    plistlib.dump({
        "Misc": {
            "Debug": {"AppleDebug": True},
            "BlessOverride": ["keep", "gets-replaced"],
        },
        "NVRAM": {"Add": {BOOT_GUID: {"boot-args": "keepsyms=1 debug=0x0 alcid=11"}}},
    }, fh)

# Deliberately re-sets a key an earlier oc_config_set() wrote, to prove secrets land last.
with open(fx / "secrets.plist", "wb") as fh:
    plistlib.dump({
        "PlatformInfo": {"Generic": {"SystemSerialNumber": "SECRET123"}},
        "Misc": {"Security": {"SecureBootModel": "Secret"}},
    }, fh)
