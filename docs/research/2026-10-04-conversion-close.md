# Search conversion-close abort fixed

Adopted a minimal binding correction in `search_approx` and `search_dense_where`:
after Python input conversion, each recognized metric branch checks that the
collection is still open before accessing the native handle. A vector's
`__len__`/`__iter__` or an integer conversion can call `collection.close()`.
Previously the subsequent empty `Optional.value()` aborted the entire process;
it now raises `collection is closed`. Unknown-metric error precedence remains.

There are nine guard sites, one executed per valid call. The initial closed
check remains, as do conversion order and validation. There is no GIL release,
shared heap owner, engine change, persistent format change or C ABI change.
The unadopted [GIL experiment](../benchmarks/2026-10-04-binding-gil.md) discovered
the defect; none of that candidate's implementation was promoted.

## Validation

The new subprocess regressions cover three search routes (approximate, filtered
approximate and filtered exact), list/column output, three conversion callbacks,
and dot/L2/cosine/unknown metrics. Every child verifies the imported binary's
path and hash. Successful children also reopen the collection and check the
stored record. The baseline produces **54 failures**, all process exit 133 at
empty Optional, and **18 passes** for unchanged unknown-metric errors.

The isolated candidate passes **72 targeted tests and 460 full Python tests**
(388 existing plus the 72 new cases). Compilation used the copied binding entry
and source with Mojo **1.0.0 (ed45d567)**, Apple M4/Metal:4. Saved-package tests
used `-o pythonpath=`, explicit Pixi Python PATH and import/hash guards; child
compiles route through the copied source and existing Metal wrapper. Build
duration 41.18 s; full Python duration 25.98 s. The existing Crashpad initialization
message and Starlette/httpx deprecation warning are retained in the logs.

Promotion copied the validated source and exact candidate binary. All **72
targeted tests passed again against production**, without adding that repeat to
the full-suite count. Native worker hash remained unchanged. No benchmark,
compression, build or test jobs overlapped.

No new full Mojo/crash/C ABI/examples, HTTP performance, Linux/GPU/ASan or
sustained nonresident gate was run. Core source is unchanged from `cc15f37`;
prior applicable engine validation remains. **M5/M6 remain unfinished and their
performance gates FAILED**; this work makes no new speed or recall claim.

## Identities and reproduction

Current Python kernel SHA-256:
`b8a66097cb6c0f598238e6e79a997820c4b4e1fdc55b8a09bd3cdc174dab7865`.
Binding source SHA-256:
`d37c017baccee7e5a0e6fe987128d2bb08265b5332bf5501855a801b7ec7cc5a`.
Previous kernel `609aeb2b…` and both full source/package snapshots are retained
under `.build/2026-10-04-conversion-close`.

[Frozen evidence](../benchmarks/results/2026-10-04-conversion-close.json.gz):
291 text files, 629,083 bytes, SHA-256
`76a26ed87b22c7ff8dbdcae71c1c4970a9e8d2986517931a51a9e262d3752b21`.
Gzip readback and every embedded file hash passed. It includes source snapshots,
the regression test, exact commands, build/test logs, all baseline failures,
XML reports, production promotion identities and final import verification.
It does not contain the compiled binaries.

Current working-tree regression command:

```sh
rtk proxy env PATH="$PWD/.build/compiler-bin:$PATH" pixi run python -m pytest tests/python/test_search_conversion_close.py -q
```

For isolated reproduction, inspect the frozen `build.py`, `test.py`, identity
and command records, extract into a fresh directory and rebase absolute paths.
Do not rerun over saved output files. Build the copied
`after-src/bindings/python_module.mojo`, not the root entry. Include the Pixi bin
when explicitly replacing PATH after `pixi run`.

Other binding entry points contain similar conversion/native-access sequences.
This fix covers the two reproduced search methods; follow-up work will reproduce
and correct the remaining affected boundaries rather than claim blanket safety.
