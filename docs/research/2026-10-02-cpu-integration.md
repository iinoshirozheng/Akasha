# CPU integration checkpoint after bounded batches and block CRC

The production checkpoint containing named/native fields, IVF, candidate rerank,
bounded legacy batches, sorted postings and portable block CRC passes:

| Gate | Result |
| --- | --- |
| Mojo | 125 files, 933 tests passed |
| Crash recovery | 8 files, 23 tests passed |
| Python bindings | 317 passed, 3 warnings, 25.19 seconds |
| External C ABI | Rebuilt library; C11 client compiled with `-Wall -Wextra -Werror` and passed |
| Examples | smoke, persistent collection, configured HNSW built and passed |
| Whitespace | `git diff --check` passed |

Compiler: project-pinned Mojo 1.0.0 (ed45d567), Apple M4 target, `metal:4`.
Explicit accelerator targeting avoids the sandbox's Metal autodetection failure.
The native worker library was retained throughout the run. Test executables were
built with two workers, then run serially; performance measurements started only
after all builds and tests had ended.

Commands for the standard gates were expanded to avoid rebuilding an in-use
native worker and to supply the explicit compiler target. For each Mojo/crash
file, the runner used `pixi run mojo build --target-accelerator=metal:4
--target-cpu=apple-m4 -I src FILE -o BINARY`, then `pixi run BINARY`.
`test_file_retirement.mojo` starts a child using `mojo run argv()[0]`; running its
prebuilt executable therefore failed to launch the child. Rerunning that file
from source under its original `mojo run` contract passed all nine tests. The
initial failure, corrected command and all successful logs are retained.

The Python compiler launcher adds only the accelerator argument, preserving the
ABI rejection and generic-CPU tests' own target arguments. Python ran with
`PYTHONPATH=python:.:.build/qdrant-compare/deps pytest tests/python -q --tb=short`.
The archive records production-source and native-binary hashes, per-file build
and run results, runner sources, examples and the terminal summaries for Python
and C: [integration evidence](2026-10-02-cpu-integration.json.gz).

The supplementary `pytest tests/distributed -q --tb=short` gate did **not** pass:
three tests passed, while seven could not start their replica listener because
`socket.bind` on `127.0.0.1` returned `PermissionError: [Errno 1] Operation not
permitted`. Their parent processes then received EOF. No network workaround or
sandbox escalation was attempted. The current environment therefore cannot
establish the multiprocess network/HTTP gate.

This checkpoint does not establish Qdrant performance parity, controlled
non-resident behavior, or final Git delivery. Staging remains blocked because
the worktree index is outside the writable roots. Later production changes
require their own affected checks; this record identifies the verified CRC
checkpoint rather than silently inheriting future changes.
