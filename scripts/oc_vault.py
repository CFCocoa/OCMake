#!/usr/bin/env python3
"""Write EFI/OC/vault.plist, and with --sign the Secure vault that goes with it.

A vault is a manifest of SHA-256 digests for everything under OC/. With Vault set to Basic,
OpenCore refuses to load a file whose digest does not match -- which makes a stale manifest
a machine that will not boot, so this is generated from the staged tree on every build
rather than maintained by hand.

Reimplements OpenCorePkg's Utilities/CreateVault/create_vault.sh and, for --sign, the
RsaTool + sign.command pair. Both are Unix shell and do not run on Windows; the manifest
half here is pure Python and does. The output format is theirs, byte for byte: paths
relative to OC/ with backslashes, the raw 32-byte digest as <data>, sorted by byte order,
and Version 1.

--sign additionally does what sign.command does:

  1. generate a *fresh* RSA-2048 key -- upstream regenerates per run, and so do we: the
     public half is embedded into OpenCore.efi in the same operation, so there is no key
     to manage and nothing to keep secret afterwards
  2. sign SHA-256 of vault.plist, PKCS#1 v1.5, into a raw 256-byte vault.sig
  3. serialise the public key into the 528-byte Chromium-derived RSAPublicKey layout
  4. write that over the zeroes between the =BEGIN OC VAULT= and ==END OC VAULT== markers
     inside OpenCore.efi

sign.command reaches for hexdump/awk/dd for step 4; a slice assignment does it here.

The manifest half is standard library only, Python 3.9+, and runs anywhere. --sign needs
pyca/cryptography for steps 1 and 2 -- key generation and PKCS#1 v1.5 signing. Writing
those by hand was measured against using the library and came to about the same number of
lines, except that the hand-written ones would have been a Miller-Rabin implementation
nobody wants to own. OCMake provisions the package itself; see cmake/OCPython.cmake.
"""
import argparse
import hashlib
import plistlib
import struct
import sys
from pathlib import Path

# create_vault.sh skips these. OpenCore.efi is excluded because it is the thing doing the
# verifying -- it cannot hash itself -- and vault.* because they are the manifest and its
# signature. The MemTest86 entries are logs it writes next to itself at runtime.
def excluded(rel):
    name = rel.name
    if name.startswith("."):
        return True
    if name.lower().startswith("vault."):
        return True
    if name == "OpenCore.efi":
        return True
    if name == "MemTest86.log":
        return True
    return name.startswith("MemTest86-Report-") and name.endswith(".html")


def vault_files(oc_dir):
    """{ 'Drivers\\OpenRuntime.efi': <32 raw digest bytes> } for everything OC/ carries."""
    oc_dir = Path(oc_dir)
    found = {}
    for path in oc_dir.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(oc_dir)
        if any(part.startswith(".") for part in rel.parts[:-1]) or excluded(rel):
            continue
        found[str(rel).replace("/", "\\")] = hashlib.sha256(path.read_bytes()).digest()
    return found


MARKER_BEGIN = b"=BEGIN OC VAULT="
MARKER_END = b"==END OC VAULT=="


def die(msg):
    sys.stderr.write("oc_vault: {}\n".format(msg))
    raise SystemExit(1)


def load_crypto():
    """Imported lazily so the manifest half keeps working with nothing installed."""
    try:
        from cryptography.hazmat.primitives import hashes as _hashes
        from cryptography.hazmat.primitives.asymmetric import padding as _padding
        from cryptography.hazmat.primitives.asymmetric import rsa as _rsa
    except ImportError:
        die("a Secure vault needs the Python package 'cryptography', which is not "
            "importable. OCMake normally provisions it; run this through the build "
            "rather than by hand, or pip install cryptography.")
    return _rsa, _padding, _hashes


def public_blob(modulus):
    """The public key as OpenCore.efi expects to find it embedded.

    Chromium's RSAPublicKey, which acidanthera widened to 64-bit header fields -- so 528
    bytes, not the 520 the Chromium documentation describes:

        u64 nwords      RSA_size / 8, i.e. 32 for RSA-2048
        u64 n0inv       -1 / n mod 2^64
        u32 n[64]       modulus, little-endian words
        u32 rr[64]      R^2 mod n, where R = 2^(bit length of n)

    Verified byte for byte against the shipped RsaTool, both by regenerating its own -sign
    output from the modulus alone and by comparing -pub for a key of ours.
    """
    bits = modulus.bit_length()
    nwords = ((bits + 7) // 8) // 8
    b64 = 1 << 64
    n0inv = (b64 - pow(modulus, -1, b64)) % b64
    rr = (1 << bits) ** 2 % modulus
    out = struct.pack("<QQ", nwords, n0inv)
    for value in (modulus, rr):
        v = value
        for _ in range(nwords * 2):
            out += struct.pack("<I", v & 0xFFFFFFFF)
            v >>= 32
    return out


def embed_key(opencore, blob):
    """Overwrite the zeroed key slot inside OpenCore.efi."""
    data = bytearray(opencore.read_bytes())
    begin = data.find(MARKER_BEGIN)
    end = data.find(MARKER_END)
    if begin < 0 or end < 0:
        die("{} has no OC VAULT markers; it is not an OpenCore binary this can sign "
            "for".format(opencore.name))
    start = begin + len(MARKER_BEGIN)
    room = end - start
    if room != len(blob):
        die("{} has room for {} key bytes but the key is {}".format(
            opencore.name, room, len(blob)))
    data[start:end] = blob
    opencore.write_bytes(bytes(data))


def sign(oc_dir, vault):
    """Produce vault.sig and embed the matching public key into OpenCore.efi."""
    opencore = oc_dir / "OpenCore.efi"
    if not opencore.is_file():
        die("OpenCore.efi is not staged, so there is nothing to embed the key into")
    rsa, padding, hashes = load_crypto()

    # The key exists only for this build. sign.command does the same, and OpenCore's
    # documentation is explicit that a new one should be made every time so an older
    # configuration cannot be loaded against it. Nothing is kept, so nothing leaks.
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    blob = public_blob(key.public_key().public_numbers().n)

    signature = key.sign(vault.read_bytes(), padding.PKCS1v15(), hashes.SHA256())
    if len(signature) != 256:
        die("expected a 256-byte RSA-2048 signature, got {}".format(len(signature)))
    (oc_dir / "vault.sig").write_bytes(signature)

    embed_key(opencore, blob)
    return len(blob)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--oc-dir", required=True, help="staged EFI/OC directory")
    ap.add_argument("--out", required=True, help="vault.plist to write")
    ap.add_argument("--sign", action="store_true",
                    help="also write vault.sig and embed the public key in OpenCore.efi")
    args = ap.parse_args()

    oc_dir = Path(args.oc_dir)
    if not oc_dir.is_dir():
        die("staged OC directory does not exist: {}".format(oc_dir))

    files = vault_files(oc_dir)
    if not files:
        die("nothing to hash under {}".format(oc_dir))

    # Sorted so the manifest is reproducible; plistlib writes dict keys sorted anyway.
    doc = {"Files": {k: files[k] for k in sorted(files)}, "Version": 1}
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as fh:
        plistlib.dump(doc, fh, sort_keys=True)
    print("oc_vault: hashed {} files into {}".format(len(files), out.name))
    if args.sign:
        embedded = sign(oc_dir, out)
        print("oc_vault: signed vault.plist and embedded a {}-byte key in "
              "OpenCore.efi".format(embedded))
    return 0


if __name__ == "__main__":
    sys.exit(main())
