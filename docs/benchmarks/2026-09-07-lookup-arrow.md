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
