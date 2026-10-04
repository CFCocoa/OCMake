#!/usr/bin/env python3
"""Verify a Secure vault the way OpenCore does, trusting nothing the generator said.

Reads the public key back out of the patched OpenCore.efi, then checks vault.sig as a raw
RSA-2048 PKCS#1 v1.5 signature over the SHA-256 of vault.plist. Deliberately does not reuse
oc_vault.py's signing path: a check that shares code with the thing it checks proves less.
"""
import hashlib
import struct
import sys
from pathlib import Path

SHA256_DIGESTINFO = bytes.fromhex("3031300d060960864801650304020105000420")
BEGIN = b"=BEGIN OC VAULT="


def main():
    oc = Path(sys.argv[1])
    data = (oc / "OpenCore.efi").read_bytes()
    start = data.find(BEGIN)
    if start < 0:
        print("no OC VAULT marker in OpenCore.efi")
        return 1
    blob = data[start + len(BEGIN):start + len(BEGIN) + 528]
    nwords, n0inv = struct.unpack_from("<QQ", blob, 0)
    words = struct.unpack_from("<{}I".format(nwords * 4), blob, 16)
    modulus = sum(w << (32 * i) for i, w in enumerate(words[:nwords * 2]))
    rr = sum(w << (32 * i) for i, w in enumerate(words[nwords * 2:]))
    if modulus.bit_length() != 2048:
        print("embedded modulus is {} bits, expected 2048".format(modulus.bit_length()))
        return 1

    # n0inv and rr are what OpenCore's Montgomery arithmetic runs on. A signature check
    # against the modulus alone would pass with either of them wrong, and the machine would
    # still refuse to boot -- so recompute both from the modulus and compare.
    b64 = 1 << 64
    if n0inv != (b64 - pow(modulus, -1, b64)) % b64:
        print("embedded n0inv is not -1/n mod 2^64")
        return 1
    if rr != (1 << modulus.bit_length()) ** 2 % modulus:
        print("embedded rr is not R^2 mod n")
        return 1

    signature = int.from_bytes((oc / "vault.sig").read_bytes(), "big")
    recovered = pow(signature, 65537, modulus).to_bytes(256, "big")
    digest = hashlib.sha256((oc / "vault.plist").read_bytes()).digest()
    padding = b"\xff" * (256 - 3 - len(SHA256_DIGESTINFO) - len(digest))
    expected = b"\x00\x01" + padding + b"\x00" + SHA256_DIGESTINFO + digest
    if recovered != expected:
        print("signature does not verify against the embedded key")
        return 1
    print("chain OK: vault.sig verifies against the key inside OpenCore.efi")
    return 0


if __name__ == "__main__":
    sys.exit(main())
