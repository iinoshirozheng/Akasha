# Default collection legacy fixtures

Generated once using the unmodified Akasha source at `f6a938a5458f7be472420939becd577057950939`, Mojo 1.0.0
(ed45d567), on macOS arm64. `generate.mojo` records the exact operations; compile
it against that revision's `src`, never against the current writer. `sha256.json`
records the original bytes. Lock files and derived caches are excluded.

These fixtures retain collection config v1, dense WAL v2/v3, sparse WAL v1,
segment v3 and sparse segment v2, including committed HNSW v1 references where
present. Current public opens migrate to the field catalog and write point WAL
v5; tests must copy these frozen inputs to exercise pre-migration recovery.

`cases.json` maps each setup to its regression. `point-cutover-0/1` contain the
six-operation dense/sparse/delete/reinsert case without/with a checkpoint at
sequence 3. Cutover sequence is 6; live document versions are 1 and 5.
