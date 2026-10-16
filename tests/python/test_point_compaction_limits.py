"""Run a legal merge fan-in above an isolated process's descriptor limit."""

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]


def test_point_compaction_under_low_descriptor_limit(tmp_path: Path) -> None:
    source = tmp_path / "merge_limit.mojo"
    source.write_text(
        "from test_point_merge import test_merge_many_segments_matches_owned_checkpoint\n"
        "def main() raises:\n"
        "    test_merge_many_segments_matches_owned_checkpoint()\n"
    )
    binary = tmp_path / "merge_limit"
    build = subprocess.run(
        ["mojo", "build", "-I", str(ROOT / "src"), "-I", str(ROOT / "tests/mojo"),
         str(source), "-o", str(binary)],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    assert build.returncode == 0, build.stdout + build.stderr
    run = subprocess.run(
        [sys.executable, "-c",
         "import os, resource, sys; "
         "soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE); "
         "resource.setrlimit(resource.RLIMIT_NOFILE, (32 if soft == resource.RLIM_INFINITY else min(soft, 32), hard)); "
         "os.execv(sys.argv[1], [sys.argv[1]])", str(binary)],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    assert run.returncode == 0, run.stdout + run.stderr
