# #39–#42：官方 primitives 與複製修正

環境：2026-09-07，Apple M4 Pro、Mojo 1.0.0 (`ed45d567`)、MAX 26.5.0。
起點 `1246e27`（engine 同 `9b98dbc`）。每個工作包獨立驗證／提交。

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
