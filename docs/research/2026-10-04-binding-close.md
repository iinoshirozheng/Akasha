# Callback-safe Python binding boundaries

Adopted the follow-up to [the first search conversion fix](2026-10-04-conversion-close.md).
The boundary audit reproduced **33 additional empty-Optional process aborts**:
32 in ordinary/search/batch/named/scanner input conversion and one after Arrow
import closed a scanner. Thirteen other audited cases already passed and retain
their behavior. All baseline results and failed edit diagnostics are preserved.

`src/bindings/python_module.mojo` is the only changed production source. It
converts Python arguments before borrowing the native collection and rechecks
the existing handle before schema capture or native operations. Metric branches
keep the unknown-metric error precedence. Legacy Arrow ingestion passes the
Python owner to its existing helper, retains array owners and bounded staging,
and borrows the collection only after conversion and a final open check. Named
Arrow ingestion checks before schema capture and commit. No rejected write
reaches native commit.

Scanner construction checks before schema and snapshot acquisition; next-batch
checks after cancellation conversion. Visited-slot stats are captured before
Arrow export can call Python. A batch already acquired stays valid when the
import callback closes its scanner; a controlled search's captured snapshot also
continues working after collection close. These are existing lifetime contracts,
not new fallback paths. No GIL release, heap-owner change, engine/API/format change
or new dependency was introduced. See the [scoped plan](../plans/2026-10-04-binding-close.md).

## Validation and limits

- Initial baseline: 45 cases, **32 process aborts and 13 passes**. The separately
  added Arrow import case also aborts, for 33 distinct failing cases. All aborts
  are exit 133 / signal 5 at empty `Optional.value()`.
- Candidate: **46 targeted and 506 full Python tests passed**. Full-suite count
  comprises 388 original tests, 72 first-stage cases and 46 follow-up cases.
- Promotion: the identical tested binary and source were copied into production;
  **118 targeted Python tests passed again** against guarded production imports.
  This repeat is not added to the full-suite count.
- Every subprocess regression guards the exact binary path/hash. Rejected
  mutation cases reopen and verify unchanged sequence and original record.
  Snapshot/scanner export cases check the retained result and visited count.

Tests used the project Python 3.11, `-o pythonpath=`, explicit Pixi bin and Metal
wrapper PATH. Child compiles route to copied source. The candidate compiled from
its copied binding entry with Mojo 1.0.0 (`ed45d567`), Apple M4/Metal:4. Full
Python took 34.66 s; promoted targeted tests 13.68 s. Existing Crashpad and
Starlette/httpx deprecation messages remain in logs. The first scripted edit
matched `get_point` when seeking `get` and stopped on an assertion before writing
any source; the corrected selector and failure explanation are retained.

The native worker and all core source remain unchanged. No new full Mojo/crash/
C ABI/examples, performance matrix, Linux/GPU/ASan or sustained nonresident
gate was run. Earlier applicable core validation remains. This is a correctness
fix; **M5/M6 performance remains FAILED and the checklist stays open**. It does
not establish absence of every possible Python re-entry defect.

## Identities and evidence

Current Python kernel SHA-256:
`780e8aaf3d7db9423251a4090fd069382d148d783451a91b6eb972893f5f74d6`.
Binding source SHA-256:
`4e2737c068928b0554429b43874760e5ba86dd00757c615b655818f0716e6a55`.
Native worker SHA-256, unchanged:
`bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`.

[Immutable archive](../benchmarks/results/2026-10-04-binding-close.json.gz):
302 text files, 636,537 bytes, SHA-256
`680044b66adf214d6b8a6299904d9ab8c0e73b0660d0a00b49917be2203b398c`.
Gzip readback and every embedded file hash passed. Includes complete before/after
source/package text, both test revisions, exact commands, failed runs, build/log/
XML results and promotion identities. Compiled binaries are not embedded.
As-run directory: `.build/2026-10-04-binding-close`.

Current-tree reproducer:

```sh
rtk proxy env PATH="$PWD/.build/compiler-bin:$PATH" pixi run python -m pytest tests/python/test_search_conversion_close.py tests/python/test_binding_conversion_close.py -q
```

For isolated reproduction, extract into fresh paths and inspect/rebase the
archived `build.py`, `test.py`, `test-export.py`, identity and exact command records.
Compile `after-src/bindings/python_module.mojo`; retain `-o pythonpath=` and import
guards. Do not rerun over frozen outputs. Builds, tests, benchmarks and archive
compression remain serial. The next performance investigation returns to the
measured HTTP JSON parsing cost without changing fixed workload or recall gates.
