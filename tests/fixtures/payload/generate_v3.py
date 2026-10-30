"""Assemble the v3 fixture independently of Akasha's native encoder."""

import argparse
import json
import struct
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("v3.bin"))
    args = parser.parse_args()
    fixture = json.loads(Path(__file__).parents[1].joinpath("jsonb-codec/cases.json").read_text())

    def source_body(value: list) -> bytes:
        matches = {row["hex"] for row in fixture["cases"] if row["input"] == value}
        if len(matches) != 1:
            raise ValueError(f"Expected one source encoding for {value}")
        return bytes.fromhex(matches.pop())

    def jsonb(body: bytes) -> bytes:
        return b"\x09" + struct.pack("<I", len(body)) + body

    def key(value: str) -> bytes:
        body = value.encode("utf-8")
        return struct.pack("<I", len(body)) + body

    nested = (
        b"\x07" + struct.pack("<I", 2)
        + key("jsonb") + jsonb(source_body([13, "-1", 28800]))
        + key("plain") + b"\x03" + struct.pack("<d", -0.0)
    )
    array = b"\x06" + struct.pack("<I", 3) + b"\x05" + jsonb(source_body([5])) + nested
    args.output.write_bytes(struct.pack("<IHHI", 0xFFFFFFFF, 3, 0, 1) + struct.pack("<H", 1) + b"x" + array)


if __name__ == "__main__":
    main()
