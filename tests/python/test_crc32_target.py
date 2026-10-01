"""CRC acceleration must follow compiler features, preserving portable builds."""

from pathlib import Path
import re
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    "triple,cpu,features,hardware",
    [
        ("aarch64-apple-darwin", "apple-m4", None, True),
        ("aarch64-apple-darwin", "apple-m4", "-crc", False),
        ("aarch64-apple-darwin", "generic", None, False),
        ("aarch64-apple-darwin", "generic", "+crc", True),
        ("x86_64-unknown-linux-gnu", "x86-64", None, False),
    ],
)
def test_crc32_instructions_require_aarch64_crc_feature(
    tmp_path: Path, triple: str, cpu: str, features: str | None, hardware: bool
) -> None:
    probe = tmp_path / "crc_target.mojo"
    probe.write_text(
        """
from akasha.storage.checksum import crc32
from std.sys.arg import argv

def main() raises:
    var data = List[UInt8]()
    for index in range(Int(argv()[1])):
        data.append(UInt8(index))
    print(crc32(data))
"""
    )
    assembly = tmp_path / "crc_target.s"
    command = [
        "mojo", "build", "--target-triple", triple, "--target-cpu", cpu,
        "--emit", "asm", "-I", str(ROOT / "src"), str(probe), "-o", str(assembly),
    ]
    if features is not None:
        command.extend(["--target-features", features])
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    emitted = assembly.read_text()
    instructions = set(re.findall(r"^\s+(crc32\w*)\s", emitted, re.MULTILINE))
    if hardware:
        assert "crc32x" in instructions
        assert "crc32b" in instructions
        assert not any(name.startswith("crc32c") for name in instructions)
    else:
        assert not instructions
