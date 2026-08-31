from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def _compile_mojo(
    tmp_path: Path, name: str, source: str
) -> subprocess.CompletedProcess[str]:
    source_path = tmp_path / f"{name}.mojo"
    source_path.write_text(source)
    return subprocess.run(
        [
            "mojo",
            "build",
            "-I",
            str(ROOT / "src"),
            str(source_path),
            "-o",
            str(tmp_path / name),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def test_raw_mapping_parts_constructor_is_not_callable(tmp_path: Path) -> None:
    result = _compile_mojo(
        tmp_path,
        "raw_mapping_parts",
        """
from akasha.storage.mapped_file import MappedFile

def main():
    var forged = MappedFile(None, 1, -1)
    _ = forged.byte_length()
""",
    )

    assert result.returncode != 0, "raw mapping parts unexpectedly compiled"
    assert "no matching function in initialization" in result.stderr


def test_mapped_slice_cannot_escape_as_untracked_origin(tmp_path: Path) -> None:
    result = _compile_mojo(
        tmp_path,
        "escaped_mapping_slice",
        """
from akasha.storage.mapped_file import MappedBytes, MappedFile

def escaped(path: String) raises -> MappedBytes[ImmUntrackedOrigin]:
    var mapped = MappedFile.open_readonly(path)
    return mapped.checked_slice(UInt64(0), UInt64(0))

def main():
    pass
""",
    )

    assert result.returncode != 0, "owner-borrowing mapped slice unexpectedly escaped"
    assert "cannot implicitly convert" in result.stderr
