#!/usr/bin/env python3
"""Generate official-decoder expected output for PBZ __Advanced__ records."""

from __future__ import annotations

import argparse
import ctypes
from pathlib import Path

from extract_vectors import extract_advanced


def load_decompress(dll_path: Path):
    lib = ctypes.CDLL(str(dll_path))
    function = lib.OodleLZ_Decompress
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


def decompress(decompress, compressed: bytes, raw_size: int) -> bytes:
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
        raise ValueError(f"Oodle returned {result}, expected {raw_size}")
    return destination.raw[:raw_size]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--oodle-dll", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("save", type=Path)
    args = parser.parse_args()

    compressed, raw_size, _ = extract_advanced(args.save)
    function = load_decompress(args.oodle_dll)
    expected = decompress(function, compressed, raw_size)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(expected)
    print(f"{args.output} {len(expected)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
