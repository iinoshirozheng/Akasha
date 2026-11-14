"""Actual post-rename directory fsync failure, isolated to one child process."""
import os
from pathlib import Path
import subprocess
import sys

import pytest


@pytest.mark.parametrize("kind", ["bitmap", "btree"])
def test_catalog_directory_sync_failure_requires_reopen(tmp_path, kind):
    if sys.platform not in ("darwin", "linux"):
        pytest.skip("directory fsync interposer supports macOS and Linux")
    root = Path(__file__).resolve().parents[2]
    library = tmp_path / "fail_sync.so"
    flags = ["-dynamiclib"] if sys.platform == "darwin" else ["-shared", "-fPIC", "-ldl"]
    subprocess.run(["cc", str(root / "tests/crash/fixtures/fail_directory_sync.c"),
                    *flags, "-o", str(library)], check=True)
    script = tmp_path / "probe.py"
    script.write_text('''
import sys
from pathlib import Path
from akashadb import Collection, JsonbValue, PayloadField, PointMutation, ValidationError
path = Path(sys.argv[1])
db = Collection(path, 1)
db.apply_point_batch([PointMutation.upsert(1, fields=[PayloadField(
    "data", "jsonb", JsonbValue.from_json('{"v":1}'))])])
db.flush()
marker = path / "fail-sync"
marker.touch()
try:
    db.create_json_index("v", "data", "v", kind=sys.argv[2])
except ValidationError:
    pass
else:
    raise AssertionError("publication must report directory sync failure")
assert not marker.exists(), "interposer did not consume the marker"
try:
    db.apply_point_batch([PointMutation.delete(1)])
except ValidationError as error:
    assert "reopen" in str(error)
else:
    raise AssertionError("uncertain writer accepted another mutation")
db.close()
db = Collection(path, 1)
assert db.json_indexes()[0]["name"] == "v"
assert db.json_indexes()[0]["kind"] == sys.argv[2]
assert db.get_point(1) is not None
db.drop_json_index("v")
db.close()
''')
    environment = dict(os.environ)
    environment["DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD"] = str(library)
    environment["AKASHA_FSYNC_FAIL_MARKER"] = str(tmp_path / "database" / "fail-sync")
    result = subprocess.run([sys.executable, str(script), str(tmp_path / "database"), kind],
                            env=environment, capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
