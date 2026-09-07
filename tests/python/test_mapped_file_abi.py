from __future__ import annotations

import platform
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]


def _run(*args: str) -> str:
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def _values(output: str) -> dict[str, int]:
    return {
        key: int(value)
        for key, value in (line.split("=") for line in output.splitlines())
    }


def test_mapping_layout_matches_native_c_headers(tmp_path: Path) -> None:
    c_probe = tmp_path / "c_probe"
    _run(
        "cc",
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        str(ROOT / "tests/c/mapped_file_abi_probe.c"),
        "-o",
        str(c_probe),
    )
    source = tmp_path / "mojo_probe.mojo"
    source.write_text(
        """
from akasha.storage.mapped_file import (
    _STAT_BYTES, _STAT_SIZE_OFFSET, _STAT_MODE_OFFSET, _STAT_MODE_BYTES,
    _PROT_READ, _MAP_PRIVATE,
)
from std.ffi import c_long, c_size_t
from std.io.file import O_RDONLY
from std.sys.info import align_of, is_little_endian, size_of

def main():
    print("stat_bytes=" + String(_STAT_BYTES))
    print("stat_alignment=" + String(align_of[Int]()))
    print("size_offset=" + String(_STAT_SIZE_OFFSET))
    print("size_bytes=" + String(size_of[Int]()))
    print("size_signed=" + String(Int(Int(-1) < 0)))
    print("mode_offset=" + String(_STAT_MODE_OFFSET))
    print("mode_bytes=" + String(_STAT_MODE_BYTES))
    print("off_t_bytes=" + String(size_of[c_long]()))
    print("size_t_bytes=" + String(size_of[c_size_t]()))
    print("little_endian=" + String(Int(is_little_endian())))
    print("o_rdonly=" + String(O_RDONLY))
    print("prot_read=" + String(_PROT_READ))
    print("map_private=" + String(_MAP_PRIVATE))
    print("map_failed=-1")
"""
    )
    native = _values(_run(str(c_probe)))
    mojo = _values(_run("mojo", "run", "-I", str(ROOT / "src"), str(source)))
    assert mojo == native


@pytest.mark.skipif(
    platform.system() != "Darwin", reason="macOS ARM64 regression"
)
def test_generic_arm64_without_amx_can_map_files(tmp_path: Path) -> None:
    probe = tmp_path / "generic_target.mojo"
    probe.write_text(
        """
from std.sys.info import CompilationTarget

def main():
    comptime assert CompilationTarget.is_macos()
    comptime assert not CompilationTarget.is_apple_silicon()
"""
    )
    _run("mojo", "run", "--target-cpu", "generic", str(probe))
    # Run the real mapping, size, file-type, bounds, and ownership tests under
    # the target that previously failed at compile time.
    _run(
        "mojo",
        "run",
        "--target-cpu",
        "generic",
        "-I",
        str(ROOT / "src"),
        str(ROOT / "tests/mojo/test_mapped_file.mojo"),
    )


@pytest.mark.parametrize(
    "triple,cpu,message",
    [
        ("x86_64-apple-darwin", "x86-64", "supports macOS ARM64 only"),
        ("aarch64-unknown-linux-gnu", "generic", "supports Linux x86-64 only"),
    ],
)
def test_unverified_mapping_abis_remain_rejected(
    tmp_path: Path,
    triple: str,
    cpu: str,
    message: str,
) -> None:
    result = subprocess.run(
        [
            "mojo",
            "build",
            "--target-triple",
            triple,
            "--target-cpu",
            cpu,
            "--emit",
            "object",
            "-I",
            str(ROOT / "src"),
            str(ROOT / "tests/mojo/test_mapped_file.mojo"),
            "-o",
            str(tmp_path / "unsupported.o"),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert (
        result.returncode != 0
    ), "unverified mapping ABI unexpectedly compiled"
    assert message in result.stderr, result.stderr
