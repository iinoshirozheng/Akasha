# Typed logical export/import

The public NDJSON export now preserves named-only and payload-only points and
every native vector field. The previous document-projection exporter lost that
data: the recorded two-point probe exported only the default-dense point and
omitted its named field. Thirteen initial tests failed against that behavior.

The binding now captures schema, config and point states from one immutable root,
using the existing point-to-Python converter also used by `get_point`. A separate
Python codec implements the [frozen version 1 format](../formats/logical-point-format.md).
Its explicit schema covers dense F32/F16/BF16/I8/U8, binary, multivectors and sparse
fields. Import validates all records and invokes one existing point-batch commit.
It clears absent fields on overwritten IDs and retains unrelated target IDs.
Legacy unversioned document export/import is retained. Existing physical storage
formats and authority mutation code are unchanged.

The CLI creates a matching catalog for new/empty destinations and rejects an
incompatible existing collection without migrating it. Atomic export publication
uses a unique temporary file; failure preserves the previous destination and
cleans the temporary output. Source sequences are provenance; target WAL sequences
are freshly allocated. Row limits and the kernel's existing native validation apply.

Validation on Mojo 1.0.0, Apple M4/metal:4:

- 22 new Python tests, including a frozen independent fixture, all native kinds,
  missing/empty/default fields, full replacement, source mutation/close after
  capture, invalid late values, malformed schema/version/count, duplicate IDs/JSON
  keys, binary padding, finite-number rules, CLI behavior and row limits.
- Numeric extrema/subnormals/signed-zero bit checks, unsigned 64-bit collection
  and field HNSW seeds, and named ANN search after import pass.
- Rebuilt Python extension: **339 passed**, three existing warnings, 11.29 s.
  The initial 16 targeted tests passed, followed by the expanded suite.
- An early CLI test compared rebuildable cache bytes as well as authority; normal
  reopen refreshed `metadata.cache`. The corrected assertion checks all authority
  files unchanged and verifies the existing point/sequence. The failed assertion
  and final results are both retained.
- `git diff --check` passed. C and engine/GPU paths did not change in this slice;
  the immediately preceding full checkpoint's 954 Mojo / 23 crash tests, C ABI
  and examples remain applicable. The binding and complete Python suite are fresh.

This fixes the newly discovered logical-operation gap. Qdrant performance parity,
controlled non-resident/network gates and final Git delivery remain separate,
unfinished items; no overall completion is claimed.

[Source snapshots, frozen fixture, reproduction and validation logs](2026-10-02-named-logical-export.json.gz)
have SHA-256 `7ce1dee8c38dd74a6446ecbc1ceb54e65d3f61fe6e4f1ea1c57ba48b8b86d4e8`.
