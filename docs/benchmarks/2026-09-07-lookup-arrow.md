# #43–#45 lookup／Arrow 驗證

2026-09-07，Apple M4 Pro／macOS，Pixi Mojo 1.0.0 (`ed45d567`)／MAX 26.5.0。
基線 `7c75cc6`；工作分支 `codex/official-primitives-43-46`。

## #43 SparseIndex

官方 [Dict](https://mojolang.org/docs/std/collections/dict/Dict/) 的 `get`／
`pop(key, default)` 維護 record／term／score slots，沿用 List 的累計順序。
刪除搬移時修正位置，移除空 term，clone 重建獨立 lookup。沒有格式改動。

5 sparse tests（含 slot 搬移、刪除重插、負 ID、clone 與 Float32 cancellation）、
5 persistent sparse tests（WAL／checkpoint reopen、filtered／hybrid、compaction）、
6 snapshot tests 全部通過。

`lookup_bench.mojo` 在修改前後各編譯一次，以 `lookup_compare.py` 交替跑 5 對獨立程序；
每次 20 broad queries、200 selective queries，k=10。每 point 有共同 term 0 與專用
term id+1；查詢共同 term 加最後專用 term或只有最後專用 term。更新每 16th point，
最後 clone 一份。輸出 checksum 每組前後完全相同。時間中位數如下：

| Points | Build ms 前→後 | Selective μs 前→後 | Broad ms 前→後 | Clone ms 前→後 | Peak RSS MiB 前→後 |
|---:|---:|---:|---:|---:|---:|
| 512 | 0.280→0.168 | 0.560→0.395 | 0.0728→0.0157 | 0.261→0.135 | 13.17→13.50 |
| 2,048 | 3.541→0.509 | 1.650→0.405 | 1.1395→0.0519 | 3.543→0.541 | 13.66→14.58 |
| 8,192 | 45.774→1.694 | 5.760→0.380 | 17.2463→0.1906 | 46.210→2.054 | 15.77→18.83 |

Lookup work 由原碼計算，不冒充 CPU instruction measurement：共同 term 的首次 score
查找需要 N(N−1)/2 次 ID 比較（8,192 points 為 33,550,336），現在 N 次 Dict get
與 N 次 insert，第二個 term 再一次 get。Selective term 從 N+1 次 term 比較變一次 get。
Dict 為期望常數查找；posting 內刪除仍線性掃該 term 的 postings，未宣稱所有更新為 O(1)。

每 index **保留** N record + N+1 term mapping；64-bit Int key/value payload 下限
為 `16*(2*N+1)` bytes，8,192 points 為 262,160 bytes。Broad query 另暫存 N 個
score slot mapping，key/value 下限 131,072 bytes。這不含 hash/control metadata、
空容量與 allocator overhead，也不是精確 heap 大小。表中的 RSS 以 `os.wait4` 量得，
包含 build、query、mutation、original 與 clone 共存及 allocator retained pages，排除
compiler；不可解讀成單一 Dict 或純 retained heap。代價與時間收益一起保留。

重現（before binary 必須先於改動編譯）：

```sh
pixi run mojo build -I src benchmarks/mojo/lookup_bench.mojo -o .build/official-primitives-43-46/lookup-before
pixi run mojo build -I src benchmarks/mojo/lookup_bench.mojo -o .build/official-primitives-43-46/lookup-after43
pixi run python benchmarks/lookup_compare.py .build/official-primitives-43-46/lookup-before .build/official-primitives-43-46/lookup-after43 --mode sparse --output docs/benchmarks/results/2026-09-07-sparse-lookup.json
```

逐次資料：[sparse lookup JSON](results/2026-09-07-sparse-lookup.json)。此為 kernel
workload，沒有 Qdrant 對照，不代表服務吞吐或全工作負載效能。

## #44 RRF

同一 harness、5 對交替程序，每次 20 queries，k=10，兩份長度 N 的排名有一半重疊，
包含負 ID。相同公式與 dense→sparse 累計順序；5 RRF tests 與 5 persistent sparse
再驗證通過。Sparse/snapshot 無新變動，沿用 #43 結果。

| fetch_k | RRF ms 前→後 | Peak RSS MiB 前→後 |
|---:|---:|---:|
| 512 | 0.2665→0.0215 | 13.00→13.36 |
| 2,048 | 4.1832→0.0671 | 13.06→13.80 |
| 8,192 | 66.4427→0.2571 | 13.67→15.78 |

原 score ID 比較為 Θ(N²)，新版本每 query 為 2N 次 Dict get、1.5N 次 insert，
再走原來的 Top-K。N 放大 16 倍，舊查詢約 249 倍、新查詢約 12 倍。
Dict 僅 query 暫存，return 後不保留 owner；8,192 時 12,288 entries 的 key/value
payload 下限 196,608 bytes，另有容量／metadata／allocator 成本。峰值 RSS 是整個
程序的量測，可能包含 allocator 留存；不是全數有效 entries 的 heap size。

```sh
pixi run mojo build -I src benchmarks/mojo/lookup_bench.mojo -o .build/official-primitives-43-46/lookup-after44
pixi run python benchmarks/lookup_compare.py .build/official-primitives-43-46/lookup-before .build/official-primitives-43-46/lookup-after44 --mode fusion --output docs/benchmarks/results/2026-09-07-fusion-lookup.json
```

[逐次 fusion 結果](results/2026-09-07-fusion-lookup.json)。輸出 checksum 每組前後一致。

## #45 Arrow primitive borrow

PyArrow 的 numeric `slice().to_numpy(zero_copy_only=True, writable=False)` 保留 producer
owner，Mojo 官方 [from_numpy_array](https://mojolang.org/docs/std/python/numpy/from_numpy_array/)
以 immutable PythonObject 引數借用 F32／I64／I32 Span。指標逐欄一致，typed loop
不逐元素回 Python，accepted values 仍由既有 WAL／MemTable owned API 接收。
以專案安裝的 PyArrow 21 與 NumPy 2.4.6 實測；
[Arrow NumPy API](https://arrow.apache.org/docs/21.0/python/generated/pyarrow.Array.html#pyarrow.Array.to_numpy)
及 [C Data ownership](https://arrow.apache.org/docs/format/CDataInterface.html) 為原始參考。

Python 的 sparse preflight 以 NumPy 向量運算保留 ValueError 合約；native 也在任何
寫入前檢查全部 sparse rows。這些 boolean／offset scratch 有配置成本。Parent 與
child slice 交給 Arrow，各自 child offset 不再錯誤相減，terms/weights 可有不同的
實體 child offsets。Producer buffers 在同步呼叫期間不可被另一方修改或 resize。

`pixi run build-python`、20 Python Arrow tests、3 Mojo Arrow tests 通過。
新增真實 readonly Span 指標、I64/I32/F32、parent/child slice、bounds、dtype、rank、
stride、null、全部 sparse preflight、producer 釋放後 reopen／資料獨立性驗證。
NumPy subclass 的 `__getitem__` 一律拋錯時，native ingest 仍成功，直接檢查沒有
primitive Python element indexing。原來的 release counter test 是 descriptor 模型；
producer 壽命的證據是新增 real buffers 與既有 PyArrow C capsule round-trip tests。

`benchmarks/arrow_ingress.py` 固定 512×256，每 cell 暖機一次、5 次計時，新 collection
且包含 WAL fsync；source 已先建立。baseline 使用 `ff00ddd` 編譯後隔離保存的 Python
package；allocation probe 獨立執行，避免 tracemalloc 污染時間。下列是 before→after：

| Workload | Prepare ms | Kernel ms | Complete ingress ms | Python traced peak bytes | Arrow pool delta bytes | WAL file bytes |
|---|---:|---:|---:|---:|---:|---:|
| Dense only | 0.089→0.084 | 229.711→200.558 | 229.811→200.638 | 3,671→4,839 | 1,376→1,376 | 536,612→536,612 |
| Dense + 4 sparse terms + 64-byte string/row | 0.380→0.151 | 256.368→221.735 | 256.710→221.879 | 5,650→16,893 | 3,096→3,096 | 618,020→618,020 |

完整 ingress 中位數約降低 12.7%／13.6%。Before/after 分批執行且包含磁碟同步，屬本機
證據，沒有跨平台或 Qdrant parity 宣稱。Tracemalloc 只計 Python 可追蹤配置；Arrow
pool delta 包含 capsule/schema 等 metadata，不是 primitive data copy；不含 Mojo native
heap 或全部 temporary allocations。NumPy validation scratch 使 Python traced peak 增加。

Copy ledger（原碼推導的邊界成本，與實測 allocation／WAL bytes 分開）：

- Arrow→NumPy→Span：primitive data copied bytes **0**；各級指標由真實 buffer tests
  驗證。舊 memoryview 也沒有整欄複製，此項主要移除 boxing，而非聲稱少掉 owned data。
- 512×256 F32：輸入有 524,288 bytes；binding staging、WalRecord owned values、
  staged MemTable values 各寫入一份，合計下限 1,572,864 bytes，三組各 512 個 vector
  List backing allocations。這不是整條 native heap 的配置總數。
- Dense WAL encode 另有 body/writer/complete 的 serialization／append，未被 typed
  borrow 消除；表中的 WAL file bytes 是實測輸出長度，不冒充 memory-copy 次數。
- Sparse 共 2,048 elements，logical I64+F32 為 24,576 bytes；staging、SparseWalRecord、
  SparseIndex、pending WAL clone 仍持有各一份（struct padding／capacity 另計）。
- String payload 每次 512 個 `.as_py()` materializations，共 32,768 UTF-8 content bytes；
  後續 DocumentField、WAL、MemTable、metadata clones／編碼仍存在。Dense-only 沒有
  payload materialization。Sparse 寫入的 existence `MemTable.get` 也仍複製 dense record，
  可在下一批針對 borrow/existence 路徑處理。

Dense batch 與後續 sparse writes 維持分開的 WAL commits，未改成跨兩者 failure-atomic。
`results_to_record_batch` 和公開 copying helpers 仍回傳 owned results；沒有保留 Span。

```sh
pixi run env PYTHONPATH=.build/official-primitives-43-46/python-before:. python benchmarks/arrow_ingress.py --label ff00ddd-before45 --output docs/benchmarks/results/2026-09-07-arrow-before.json
pixi run env PYTHONPATH=python:. python benchmarks/arrow_ingress.py --label after45 --output docs/benchmarks/results/2026-09-07-arrow-after.json
```

[Before raw results](results/2026-09-07-arrow-before.json)、
[after raw results](results/2026-09-07-arrow-after.json)。上限／空批次錯誤沿用現有公開路徑。
