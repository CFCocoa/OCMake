#!/usr/bin/env python3
"""Bill of materials for a staged EFI: what is in it and at which version.

Written from the staged tree rather than from the declarations, so it reports what was
actually produced. Deliberately contains no timestamp, so the BOM only changes when the
EFI does and stays useful in a diff.
"""
import argparse
import json
import plistlib
from pathlib import Path


def kext_row(bundle):
    info = {}
    plist = bundle / "Contents" / "Info.plist"
    if plist.is_file():
        try:
            with open(plist, "rb") as fh:
                info = plistlib.load(fh)
        except Exception:
            info = {}
    return {
        "bundle": bundle.name,
        "version": info.get("CFBundleShortVersionString") or "",
        "identifier": info.get("CFBundleIdentifier") or "",
    }


def source_key(prov):
    """Plain text to sort a source by -- the markdown link is punctuation-first and would
    order by '[' and '`' rather than by the name a reader sees."""
    if not prov:
        return ""
    origin = prov.get("origin")
    if origin == "github" and prov.get("repo"):
        return prov["repo"]
    if origin == "url" and prov.get("url"):
        return prov["url"].rsplit("/", 1)[-1]
    return prov.get("source") or ""


def sort_key(text):
    """Case-insensitive, with case only deciding between otherwise equal strings --
    so acidanthera/... sorts before OpenIntelWireless/..., not after it."""
    return (text.lower(), text)


def source_cell(prov):
    """One markdown cell describing where an artefact came from."""
    if not prov:
        return "—"
    origin = prov.get("origin")
    if origin == "github" and prov.get("repo"):
        return "[{0}](https://github.com/{0})".format(prov["repo"])
    if origin == "url" and prov.get("url"):
        return "[{}]({})".format(prov["url"].rsplit("/", 1)[-1], prov["url"])
    if origin == "compiled-sample":
        return "`{}` (OpenCore sample)".format(prov.get("source", ""))
    if prov.get("source"):
        return "`{}`".format(prov["source"])
    return "—"


def collect(efi, name, version, build, prov):
    oc = efi / "OC"
    cfg = {}
    config_path = oc / "config.plist"
    if config_path.is_file():
        with open(config_path, "rb") as fh:
            cfg = plistlib.load(fh)

    entries = {e.get("BundlePath"): e for e in cfg.get("Kernel", {}).get("Add", [])}
    kexts = []
    for bundle in sorted((oc / "Kexts").iterdir()) if (oc / "Kexts").is_dir() else []:
        if not bundle.is_dir() or not bundle.name.endswith(".kext"):
            continue
        row = kext_row(bundle)
        entry = entries.get(bundle.name, {})
        row["enabled"] = bool(entry.get("Enabled", False))
        row["min_kernel"] = entry.get("MinKernel") or ""
        row["max_kernel"] = entry.get("MaxKernel") or ""
        row["provenance"] = prov.get("kexts", {}).get(bundle.name, {})
        kexts.append(row)

    def listing(folder, key, pattern="*.efi"):
        d = oc / folder
        names = sorted(p.name for p in d.glob(pattern)) if d.is_dir() else []
        return [{"name": n, "provenance": prov.get(key, {}).get(n, {})} for n in names]

    acpi_names = sorted(p.name for p in (oc / "ACPI").glob("*.aml")) if (oc / "ACPI").is_dir() else []
    acpi = [{"table": t, "provenance": prov.get("acpi", {}).get(t, {})} for t in acpi_names]

    return {
        "name": name,
        "opencore": dict({"version": version, "build": build},
                         **{"provenance": prov.get("packages", {}).get("OpenCore", {})}),
        "kexts": kexts,
        "acpi": acpi,
        "drivers": listing("Drivers", "drivers"),
        "tools": listing("Tools", "tools"),
        "resources": resources(oc, prov),
    }


def resources(oc, prov):
    """One row per Resources/ subdirectory, with how many files it staged.

    Listing 104 icons and labels individually would bury everything else, and the unit a
    reader cares about is the set: Audio is present or it is not.
    """
    root = oc / "Resources"
    if not root.is_dir():
        return []
    rows = []
    for sub in sorted(p for p in root.iterdir() if p.is_dir()):
        count = sum(1 for f in sub.rglob("*") if f.is_file())
        if not count:
            continue
        rows.append({"name": sub.name, "files": count,
                     "provenance": prov.get("resources", {}).get(sub.name, {})})
    return rows


KEXT_GROUPS = (("Fetched", ("github", "url")), ("Local", ("local",)))
ACPI_GROUPS = (("Compiled", ("compiled", "compiled-sample")), ("Prebuilt", ("prebuilt",)))


def merge_rows(rows):
    """Fold consecutive rows that differ only in the first column into a single row.

    Names stack inside the cell with <br>, which is how a markdown table expresses a
    multi-line cell. Everything a group has in common is then stated exactly once.
    """
    merged = []
    for row in rows:
        if merged and merged[-1][1:] == list(row[1:]):
            merged[-1][0] = merged[-1][0] + "<br>" + row[0]
        else:
            merged.append(list(row))
    return merged


def render(headers, rows, group_col, follow_cols=()):
    """Render a markdown table: identical rows fold together, and a value repeating the
    row above is blanked so a run of rows sharing a source shows it once.

    follow_cols are blanked only inside such a run, so an incidental version match
    between unrelated sources still prints.
    """
    rows = merge_rows(rows)
    out = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    previous = None
    for row in rows:
        cells = list(row)
        if previous is not None and row[group_col] == previous[group_col]:
            cells[group_col] = ""
            for col in follow_cols:
                if row[col] == previous[col]:
                    cells[col] = ""
        out.append("| " + " | ".join(cells) + " |")
        previous = row
    return out


def kext_table(rows):
    # Sorted by source, so kexts from one release sit together and the shared source
    # collapses into a single visible cell.
    ordered = sorted(rows, key=lambda k: (sort_key(source_key(k["provenance"])),
                                          sort_key(k["bundle"])))
    table = [[k["bundle"], k["version"] or "—", source_cell(k["provenance"]),
              "yes" if k["enabled"] else "**no**",
              k["min_kernel"] or "—", k["max_kernel"] or "—"] for k in ordered]
    return render(["Kext", "Version", "Source", "Enabled", "MinKernel", "MaxKernel"],
                  table, group_col=2, follow_cols=(1,))


def grouped(items, groups, origin_of):
    """Split items by provenance origin, plus anything that matched no group."""
    out = []
    claimed = set()
    for title, origins in groups:
        rows = [i for i in items if origin_of(i) in origins]
        claimed.update(id(i) for i in rows)
        if rows:
            out.append((title, rows))
    rest = [i for i in items if id(i) not in claimed]
    if rest:
        out.append(("Other", rest))
    return out


def markdown(bom):
    oc = bom["opencore"]
    out = ["# {} — bill of materials".format(bom["name"]), ""]
    out += ["OpenCore **{}** ({}) — {}".format(
        oc["version"], oc["build"], source_cell(oc.get("provenance"))), ""]

    out += ["## Kexts ({})".format(len(bom["kexts"])), ""]
    if bom["kexts"]:
        for title, rows in grouped(bom["kexts"], KEXT_GROUPS,
                                   lambda k: (k["provenance"] or {}).get("origin")):
            out += ["### {} ({})".format(title, len(rows)), ""] + kext_table(rows) + [""]
    else:
        out += ["_none_", ""]

    out += ["## ACPI ({})".format(len(bom["acpi"])), ""]
    if bom["acpi"]:
        for title, rows in grouped(bom["acpi"], ACPI_GROUPS,
                                   lambda a: (a["provenance"] or {}).get("origin")):
            table = [[a["table"], source_cell(a["provenance"])] for a in rows]
            out += ["### {} ({})".format(title, len(rows)), ""]
            out += render(["Table", "Source"], table, group_col=1) + [""]
    else:
        out += ["_none_", ""]

    # Drivers and tools usually come from the OpenCore package, but a fork or a driver
    # OpenCore does not ship can be declared with PATH -- so each row cites its own source.
    oc_source = source_cell(oc.get("provenance"))

    def binary_source(item):
        if (item["provenance"] or {}).get("origin") == "opencore":
            return oc_source
        return source_cell(item["provenance"])

    def binary_key(item):
        if (item["provenance"] or {}).get("origin") == "opencore":
            return source_key(oc.get("provenance"))
        return source_key(item["provenance"])

    out += ["## Resources ({})".format(sum(r["files"] for r in bom["resources"])), ""]
    if bom["resources"]:
        ordered = sorted(bom["resources"], key=lambda r: (sort_key(source_key(r["provenance"])),
                                                          sort_key(r["name"])))
        table = [["`{}`".format(r["name"]), str(r["files"]), source_cell(r["provenance"])]
                 for r in ordered]
        # No follow_cols: a file count is this set's own, not an attribute shared with
        # the row above, so two sets that happen to be the same size must both show it.
        out += render(["Set", "Files", "Source"], table, group_col=2) + [""]
    else:
        out += ["_none_", ""]

    for title, key in (("Drivers", "drivers"), ("Tools", "tools")):
        out += ["## {} ({})".format(title, len(bom[key])), ""]
        if bom[key]:
            ordered = sorted(bom[key], key=lambda i: (sort_key(binary_key(i)),
                                                      sort_key(i["name"])))
            table = [["`{}`".format(i["name"]), binary_source(i)] for i in ordered]
            out += render([title[:-1], "Source"], table, group_col=1)
        else:
            out.append("_none_")
        out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--efi", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--oc-version", default="")
    ap.add_argument("--oc-build", default="")
    ap.add_argument("--markdown")
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--provenance", help="JSON describing where each artefact came from")
    args = ap.parse_args()

    prov = {}
    if args.provenance and Path(args.provenance).is_file():
        with open(args.provenance) as fh:
            prov = json.load(fh)

    bom = collect(Path(args.efi), args.name, args.oc_version, args.oc_build, prov)
    if args.markdown:
        Path(args.markdown).parent.mkdir(parents=True, exist_ok=True)
        Path(args.markdown).write_text(markdown(bom) + "\n")
    if args.json_out:
        Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json_out).write_text(json.dumps(bom, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
