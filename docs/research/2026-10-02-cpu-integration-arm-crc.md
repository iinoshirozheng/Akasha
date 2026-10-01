# CPU integration after feature-gated CRC

The current worktree passes **957 Mojo tests in 131 files, 23 crash tests in eight
files, all 344 Python tests**, the rebuilt C ABI client and three rebuilt examples
(`smoke`, `persistent_collection`, `configured_hnsw`). The compiler is locked Mojo
1.0.0 (ed45d567), targeting Apple M4 / Metal:4 on this macOS ARM64 host.

All native test executables were rebuilt before execution. The independent
file-lease reader initially failed because its child compiler missed the existing
Metal-target wrapper. The validation launcher was corrected and only that file
and unrun files resumed, without rebuilding or rerunning successful files. The
original failure and final success logs are preserved. Python retains three
existing deprecation warnings. The C maintenance worker source is unchanged;
its shared library was not overwritten while tests were running.

The five new target checks demonstrate CRC instructions only for enabled
AArch64 targets, including explicit disable/enable overrides and Linux x86-64
assembly compilation. Numeric and protected-page tests run under four ARM target
feature combinations. These are not Linux execution or GPU-device gates.

Commands, JUnit, native build/run output and all source/test snapshots are in the
[CRC evidence archive](../benchmarks/results/2026-10-02-arm-crc.json.gz), SHA-256
`8019f4ab9c46557c569cdb4a36934cb45179e91ba661fdab735c1d66510016fa`.
[Lifecycle measurements](../benchmarks/2026-10-02-arm-crc.md) separately cover
resident mixed operations, fresh Qdrant comparisons and verified zero-resident
file-data opens. The earlier [network and Git restrictions](2026-10-02-cpu-integration.md)
remain; those denied operations were not retried. Sustained non-resident query
loads, controlled memory budgets, overall Qdrant parity and final Git delivery
remain open.
