#!/usr/bin/env python3
"""Verify all shipped native libraries, including AARs, support 16 KB pages."""
import argparse
import struct
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("artifact", help="APK or AAB to inspect")
args = parser.parse_args()
count = 0
abis = set()
with zipfile.ZipFile(args.artifact) as archive:
    for name in archive.namelist():
        if not name.endswith(".so") or "/lib/" not in "/" + name:
            continue
        abi = name.split("/lib/", 1)[-1].split("/")[0] if "/lib/" in name else name.split("/")[1]
        if abi not in {"arm64-v8a", "x86_64"}:
            raise SystemExit(f"Unsupported ABI in {name}")
        data = archive.read(name)
        if data[:6] != b"\x7fELF\x02\x01":
            raise SystemExit(f"Expected a 64-bit little-endian ELF: {name}")
        offset = struct.unpack_from("<Q", data, 32)[0]
        size, number = struct.unpack_from("<HH", data, 54)
        loads = []
        for index in range(number):
            header = offset + size * index
            if struct.unpack_from("<I", data, header)[0] == 1:  # PT_LOAD
                loads.append(struct.unpack_from("<Q", data, header + 48)[0])
        if not loads or min(loads) < 16384:
            raise SystemExit(f"ELF does not support 16 KB pages: {name}: {loads}")
        count += 1
        abis.add(abi)
if not count:
    raise SystemExit("No native libraries found")
print(f"PASS: {count} native libraries support 16 KB pages; ABIs: {', '.join(sorted(abis))}")
