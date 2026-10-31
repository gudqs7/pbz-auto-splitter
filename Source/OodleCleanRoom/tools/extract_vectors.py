#!/usr/bin/env python3
"""Extract PBZS __Advanced__ Oodle vectors without decoding Oodle."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import struct
from pathlib import Path

from Crypto.Cipher import AES


MAGIC = b"PBZS"
KEY_MATERIAL_A = bytes.fromhex(
    "ec88a5760acdfb3b30d9f0b8ad07c52a"
    "c6da79183761234af91e8b7108287c7b"
)
KEY_MATERIAL_B = bytes.fromhex(
    "f9295b795f2d1012bea564d9f9849443"
    "acf07e18da4c34f0e6999f26e0d14256"
)
AES_KEY = bytes(a ^ b for a, b in zip(KEY_MATERIAL_A, KEY_MATERIAL_B))


def decrypt_record(blob: bytes) -> bytes:
    if len(blob) < 36 or blob[:4] != MAGIC:
        raise ValueError("not a PBZS encrypted record")
    if blob[4] != 1 or blob[5] != 1:
        raise ValueError(f"unsupported PBZS record {blob[4]}:{blob[5]}")
    cipher = AES.new(AES_KEY, AES.MODE_GCM, nonce=blob[8:20], mac_len=16)
    return cipher.decrypt_and_verify(blob[36:], blob[20:36])


def extract_advanced(save: Path) -> tuple[bytes, int, bytes]:
    data = save.read_bytes()
    if len(data) < 12 or data[:4] != MAGIC:
        raise ValueError("not a PBZS container")
    index_size = struct.unpack_from("<I", data, 8)[0]
    index = decrypt_record(data[12 : 12 + index_size])
    position = 12
    while position < len(index):
        name_length = struct.unpack_from("<H", index, position)[0]
        position += 2
        name = index[position : position + name_length].decode("utf-8")
        position += name_length + 2
        raw_size, offset, encrypted_size = struct.unpack_from(
            "<III", index, position
        )
        position += 12
        if name == "__Advanced__":
            start = 12 + index_size + offset
            encrypted = data[start : start + encrypted_size]
            if len(encrypted) != encrypted_size:
                raise ValueError("truncated __Advanced__ chunk")
            return decrypt_record(encrypted), raw_size, data
    raise ValueError("__Advanced__ not found")


def classify_advanced(oo: bytes, raw_size: int) -> dict[str, object]:
    if len(oo) < 2 or (oo[0] & 0x0F) != 0x0C:
        raise ValueError("not an Oodle block")
    result: dict[str, object] = {
        "stored": bool(oo[0] & 0x40),
        "restart": bool(oo[0] & 0x80),
        "decoder_id": oo[1] & 0x7F,
        "checksums": bool(oo[1] & 0x80),
    }
    if not result["stored"]:
        if len(oo) < 5:
            raise ValueError("truncated Oodle quantum")
        quantum = int.from_bytes(oo[2:5], "big")
        result["quantum_header"] = f"0x{quantum:06x}"
        result["compressed_size"] = (quantum & 0x3FFFF) + 1
    result["raw_size"] = raw_size
    return result


def make_official_decoder(dll_path: Path):
    library = ctypes.CDLL(str(dll_path))
    function = library.OodleLZ_Decompress
    function.restype = ctypes.c_ssize_t
    function.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ssize_t,
        ctypes.c_void_p,
        ctypes.c_ssize_t,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_ssize_t,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_ssize_t,
        ctypes.c_int,
    ]
    return function


def decode_official(decompress, compressed: bytes, raw_size: int) -> bytes:
    source = ctypes.create_string_buffer(compressed + b"\0" * 65536)
    destination = ctypes.create_string_buffer(raw_size + 65536)
    result = decompress(
        source,
        len(compressed),
        destination,
        raw_size,
        0,
        0,
        0,
        None,
        0,
        None,
        None,
        None,
        0,
        3,
    )
    if result != raw_size:
        raise ValueError(f"official decoder returned {result}/{raw_size}")
    return destination.raw[:raw_size]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--oodle-dll", type=Path)
    parser.add_argument("saves", type=Path, nargs="+")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    official = (
        make_official_decoder(args.oodle_dll)
        if args.oodle_dll is not None
        else None
    )
    manifest = []
    seen: set[str] = set()

    for save in args.saves:
        oo, raw_size, container = extract_advanced(save)
        oo_hash = hashlib.sha256(oo).hexdigest()
        if oo_hash in seen:
            continue
        seen.add(oo_hash)
        name = f"{save.stem}-{oo_hash[:12]}"
        oo_path = args.output / f"{name}.oodle"
        oo_path.write_bytes(oo)
        expected = args.output / f"{name}.expected"
        if official is not None:
            expected_bytes = decode_official(official, oo, raw_size)
            expected.write_bytes(expected_bytes)
        else:
            if not expected.exists():
                raise FileNotFoundError(
                    f"missing official decoder output: {expected}"
                )
            expected_bytes = expected.read_bytes()
            if len(expected_bytes) != raw_size:
                raise ValueError(f"expected size mismatch for {save}")
        manifest.append(
            {
                "name": name,
                "source": str(save),
                "source_sha256": hashlib.sha256(container).hexdigest(),
                "oodle_sha256": oo_hash,
                "expected_sha256": hashlib.sha256(expected_bytes).hexdigest(),
                "raw_size": raw_size,
                "oodle_size": len(oo),
                "framing": classify_advanced(oo, raw_size),
            }
        )

    (args.output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"extracted {len(manifest)} unique vectors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
