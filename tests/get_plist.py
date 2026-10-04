#!/usr/bin/env python3
"""Print '/'-separated key paths from a plist as `keypath=repr` lines, for assertions."""
import plistlib
import sys

cfg = plistlib.load(open(sys.argv[1], "rb"))
for keypath in sys.argv[2:]:
    node = cfg
    missing = False
    for part in [p for p in keypath.split("/") if p]:
        if isinstance(node, list):
            if not part.isdigit() or int(part) >= len(node):
                missing = True
                break
            node = node[int(part)]
        elif isinstance(node, dict) and part in node:
            node = node[part]
        else:
            missing = True
            break
    print("{}={}".format(keypath, "<absent>" if missing else repr(node)))
