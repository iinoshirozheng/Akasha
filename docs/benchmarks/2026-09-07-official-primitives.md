# #39–#42：官方 primitives 與複製修正

環境：2026-09-07，Apple M4 Pro、Mojo 1.0.0 (`ed45d567`)、MAX 26.5.0。
起點 `1246e27`（engine 同 `9b98dbc`）。每個工作包獨立驗證／提交。

## 整合結果

四個工作包已完成：#39 `dc0a9f5`、#40 `a4a8b86`、#41 `209a34a`、#42 `ae9524c`。
在 `ae9524c` 的相同 source/tests/dependencies 上完成以下本機原生驗證：

| Command | 結果 |
|---|---|
| `pixi run test` | 83 個 Mojo 檔案、645 tests 通過；Python 49 tests 通過 |
| `pixi run test-crash` | 9 tests 通過 |
| `pixi run test-c` | C ABI integration 通過 |
| `pixi run build` | Mojo examples 與 Python shared library 編譯成功 |
| `pixi run check-hnsw-quality` | 既有 locked quality gates 通過 |
| `pixi run check-post-hnsw-quality` | 11 cells 通過；ANN-only 無 exact fallback |

pytest 另回報 2 個 extension metadata deprecation warnings；沒有測試失敗。
本輪未新增 Linux CI／實機 GPU 結果，未變更 GPU code、ABI、依賴或 durable formats。
各 gate 指令、source commit 與日誌 hashes 在
[validation JSON](results/2026-09-07-official-primitives-validation.json)。

全部驗證結束後，使用下方相同 workload 再跑 7 組 paired trials，比較原始 baseline
與整合後 `ae9524c`；沒有 compiler 或測試並行。每次重新複製同一 prepared fixture，
before/after 執行順序交替。

| 指標 | Baseline median | #39–#42 median |
|---|---:|---:|
| Public flush | 218.317 ms | 178.084 ms |
| Open/update/flush/close process peak RSS | 315.422 MiB | 282.984 MiB |

此 workload 的 median latency 減少 18.4%，process peak RSS median 減少 32.438 MiB。
7 組 before/after 的所有 `.bin` 檔案 hashes 完全相同。
這是合併效果，不把差異歸因於單一工作包，也不外推到所有 workload；
#39 單獨量測未顯示端到端改善，原始結果仍保留於下節。
[Combined results JSON](results/2026-09-07-official-primitives-combined.json)

## #39：Incremental flush

`_flush_unlocked` 現在先選 base／delta，再 materialize owned entries。
對既有 checkpoint，不再建立並丟棄整份 `live_entries()`。
格式、順序與 public owned API 不變。

新增 regression 逐 byte 比較 base 與包含 replace/delete/insert 的 delta，檢查 no-op
flush 不新增 data segment、WAL 清空與重開後的資料。修改前後均通過；修正後
`test_persistent_collection` 17 tests、`test_compaction` 2 tests、
`tests/crash/test_checkpoint_order` 1 test 通過，合計 20 tests。

另以隔離的 source copies 加入診斷列印，只統計 public flush 期間的
`MemTable.live_entries` 與 `MemTableEntry.clone` 呼叫；計時 binary 不含這些列印。
128 points × 8 F32、4 個更新的結果：

| 指標 | 修改前 | 修改後 |
|---|---:|---:|
| `live_entries()` 呼叫 | 1 | 0 |
| Entry clones | 260 | 132 |
| Clone 的 vector bytes | 8,320 | 4,224 |

差異正好是一份 128-point live base。剩餘 128 次 clone 來自
`authoritative_index_checksum` 的 owned `entry_at`，另 4 次是必要 delta materialization；
沒有把這次修正宣稱為整個 flush 都只做 delta work。

public flush 的量測使用 8,192 points × 64 F32、每筆 4,096-byte string payload，
一次更新 16 points。初始 collection 在獨立程序準備，每組 before/after 都複製同一
fixture，交替執行順序，共 7 組。沒有同時執行 compiler 或其他測試。

| 指標 | 修改前 median | 修改後 median |
|---|---:|---:|
| `collection.flush()` | 215.935 ms | 215.966 ms |
| 整個 open/update/flush/close 程序 peak RSS | 315.391 MiB | 315.438 MiB |

這組端到端時間與 peak RSS 沒有顯示改善；不宣稱加速或降低 process peak。
已消除的是每次多餘複製的一份 base：此 workload 為 2 MiB vector 加 32 MiB payload
logical bytes（依 fixture 大小計算，不含 field names、entry headers／allocator overhead）。
索引 fingerprint／cache publication 與其他既有成本仍包含於 public flush 計時。

每一組 before/after 的全部 `.bin` 檔案 SHA-256 相同，包含 dense/sparse segments、
manifest、config 與 index sidecars。原始數字、binary hashes 與 trace 記錄見
[results JSON](results/2026-09-07-official-primitives-flush.json)。

重現：使用同一版 benchmark 分別對 baseline／修正後 source 編譯，再執行：

```sh
pixi run mojo build -I src benchmarks/mojo/flush_bench.mojo -o .build/flush-after
python3 benchmarks/flush_compare.py --before /path/to/flush-before --after .build/flush-after --output .build/flush-results
```

測試與診斷完整日誌留在 `.build/official-primitives/`。

## #40：官方 bit primitives

Bitmap 的 bit count 改用 `std.bit.pop_count`，set ordinals 使用
`count_trailing_zeros` 逐個清除最低 set bit。移除手寫 `_popcount`，保留 runtime
大小、cached cardinality 與 bounded ascending ordinals。

6 個 Bitmap tests 通過，新增 0／1／63／64／65／127／128／129／257 大小的 scalar
set-algebra 對照、resize padding、空 word、clone 與重複 clear 驗證；另有 7 個
filtered HNSW tests 與 5 個 filter-expression tests 通過，合計 18 tests。

## #41：官方 owned vector copy

collection／MemTable 的 `_clone_vector` 已移除，7 處使用者改用 `List.copy()`；
`DocumentRecord.clone` 也改用官方 copy。WAL 與 staged batch、recovery、get 的
owned 邊界不變。空向量／tombstone／metadata-only projection 都保留同一語意。

14 個 MemTable、7 個 persistent document、6 個 snapshot、5 個 atomic batch
tests 通過，共 32 tests。新增測試直接修改 caller mutations、returned record、
cloned vector/payload，確認各自隔離；snapshot 在 collection 更新與 close 後仍
保留原值，WAL 重開後也符合接受的 sequence／資料。

## #42：官方 bulk append

`BinaryWriter.write_bytes` 改用 `List.extend(Span(values))`，借用只持續於 append，
writer 仍持有獨立 bytes。CRC table、polynomial、byte order 與 reader 檢查不變。

5 個 checksum/codec tests（含新增的 16,387-byte 多段 append、empty chunks、
來源修改、take/reuse 與 aliasing 驗證）、1 個 CRC table、2 個 WAL v1 compatibility、
1 個 segment v1 compatibility tests 通過，合計 9 tests。
