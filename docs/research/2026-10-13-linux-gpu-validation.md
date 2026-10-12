# Linux runtime and Metal device checks

The maintenance fix was exercised on both supported operating-system ABIs.
Linux ran as **emulated x86-64 in Docker Desktop on the ARM64 Mac**, not native
x86 hardware. This establishes the listed runtime behavior, not native Linux
performance or a complete Linux CPU suite.

The isolated copy was made at `0fccf23` (engine fix `be3be53`) and installed
with `pixi install --frozen`, using Pixi 0.76.1 and Mojo 1.0.0 (`ed45d567`).
The official `ghcr.io/prefix-dev/pixi:0.76.1` image had digest
`sha256:540414f50b96439a6ba1475b79b2e2dd2208e86ebef33e2fbf2a176a8f037d31`.
Its four-CPU, 6 GiB container used a separate source tree and native binaries,
published no ports, and was stopped after validation. That resource cap is
not a memory-constrained query benchmark. The emulated CPU exposed Westmere
features, without AVX.

| Linux validation | Result |
|---|---|
| Mapping ABI against native C headers | 3 passed; macOS-only regression skipped |
| Mapping capability tests | 10 passed |
| Maintenance, including lock-wait shared-state regression | 6 passed |
| Background publication | All 20 distinct cases passed across the ordinary-user run and one targeted retry |
| SIMD distance | 9 passed |
| Full Python suite and two targeted retries | 350 distinct passed; 2 skipped |
| Fresh Python extension and native worker | Built successfully |
| Fresh C library and `pixi run test-c` | Passed |

The raw failures remain in the artifact. Running permission-failure tests as
root made the expected `chmod` I/O failure succeed. A first attempt to switch
users without Pixi activation could not find the Mojo standard library. The
correct `pixi run runuser -u ubuntu -- mojo run …` invocation passed 19 cases;
one fixture still belonged to root. After changing ownership of that test's
directory, its single-case retry passed. These are not presented as one clean
20-case run.

The first Python command omitted the `PYTHONPATH=python:.` environment used by
the repository's `test-python` task. It passed 348 cases, skipped two, and
failed two CLI subprocess imports. Both CLI cases passed with the task's
environment restored. The remaining skips were the macOS ARM64 regression and
the optional pinned Qdrant adapter dependency. The latter already passed in
the separate macOS validation; it was not installed or counted as run on Linux.

On the Apple M4 Pro, the affected snapshot/device-cache tests ran with
`--target-accelerator=metal:4 --target-cpu=apple-m4`:

| Metal tests | Result |
|---|---|
| `tests/gpu/test_gpu_snapshot.mojo` | 2 passed |
| `tests/gpu/test_gpu_cache.mojo` | 7 passed |

These include actual-device CPU/GPU differential results, cache reuse and
freshness, concurrent queries, sibling handles and close during queries. One
case intentionally injects a device-launch failure and verifies CPU fallback;
the nine cases are not nine device-only execution paths. Unrelated flat/tiled
GPU suites were not rerun.

[All logs, failed attempts, commands, JUnit reports and source/binary identities](2026-10-13-linux-gpu-validation.json.gz).
SHA-256: `8bd9e20553b645fc21daaec2f388a6366b1cd35c2854b48da2e5c7b7702f103b`.
