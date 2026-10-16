"""Run the fsync failure probe with a loader shim scoped to one child process."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> None:
    fixtures = Path(__file__).resolve().parent / "fixtures"
    root = fixtures.parents[2]
    with tempfile.TemporaryDirectory(prefix="akasha-reclaim-fence-") as temporary:
        work = Path(temporary)
        library = work / "fail_directory_sync.so"
        binary = work / "lease_reclaim_fence"
        if sys.platform == "darwin":
            flags = ["-dynamiclib"]
            loader = "DYLD_INSERT_LIBRARIES"
        elif sys.platform == "linux":
            flags = ["-shared", "-fPIC", "-ldl"]
            loader = "LD_PRELOAD"
        else:
            raise RuntimeError(f"unsupported file-lease platform: {sys.platform}")
        subprocess.run(
            ["cc", str(fixtures / "fail_directory_sync.c"), *flags, "-o", str(library)],
            check=True,
        )
        subprocess.run(
            ["mojo", "build", "-I", str(root / "src"),
             str(fixtures / "lease_reclaim_fence.mojo"), "-o", str(binary)],
            check=True,
        )
        database = work / "database"
        environment = dict(os.environ)
        environment[loader] = str(library)
        environment["AKASHA_FSYNC_FAIL_MARKER"] = str(database / "fail-sync")
        subprocess.run([str(binary), str(database)], env=environment, check=True, timeout=60)


if __name__ == "__main__":
    main()
