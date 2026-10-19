# 完整 mixed 工作負載的向量存取追蹤

本輪補足[兩筆固定查詢的 CPU 計數器](2026-10-20-immutable-point-memory-profile.md)無法代表完整 mixed 工作集合的限制。三個 frozen corpus 的 864 筆回應都與 deferred-ID parent 一致。把 Qdrant 的 sequential 判定套到 Akasha 的映射圖候選上，152,656 個至少兩筆的批次切片只有 23 個符合，約 **0.0151%**。這不支持直接採用 sequential mapping／讀取提示。

這份追蹤是診斷，不是新效能 gate；保留版本仍為 mixed **25/36**。

## 實作與驗證範圍

從 `immutable-point-deferred-id` 完整複製 132 份 Mojo 原始碼及 Python package，七個檔案只加入診斷事件：collection 的查詢起訖、篩選與 cap 後的 HNSW 批次、mapped／owned graph 的一列與四列計分，以及權威資料的批次與列位址。沒有改變算術、候選順序、來源篩選、格式、鎖或 public getter。

每個事件記錄即將計分的 slot、列起始位址與長度；不記錄向量值。位址只用於這次程序內的範圍計算，沒有儲存或傳回可以延長 mapping 生命週期的 pointer。權威數值列仍在原有 owner borrow 中讀取。

- Parent native：`64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`。
- Diagnostic native：`81b626589347703318e23ded721f4d2c2f57ebe67e48d93cef900d3561941348`。
- Mojo：`1.0.0 (ed45d567)`，原生 shared library 編譯成功。
- 三個 worker 依序執行，每個使用 frozen 初始資料庫的新副本，完整重播 32 個 block、288 次查詢、每 block 的八筆 upsert 與 flush。
- **864 筆** IDs、F32 score bits、stats、execution、recall 與 oracle 逐筆符合 parent；**三次** exact reopen 與 **三次** retained Arrow lease 檢查通過。
- 另外九筆 warmup 有 trace，但沒有拿回傳結果與 parent 比對，也不列入 864 筆。

Parser 驗證每個非空 HNSW batch 的事件筆數等於篩選／cap 後的 count。ANN 的 mapped + owned graph 列數等於 `distance_evaluations`，權威列數等於 `reranked_candidates`。planned-exact 路徑沒有 graph 計分，其權威列數等於 `distance_evaluations`；不能再把 exact 的 retained/reranked 結果數加成額外距離計算。

## Qdrant 原始碼對照

固定 pin 為 `21db2f3ff95d50de3a2b88a741312c056fd1762d`。Archive 內的 `PointScorer`、`query_scorer/mod.rs`、`immutable_dense_vectors.rs`、`common.rs` 與 LICENSE 均逐份比對 `git show` 和本地 checkout。

Qdrant 先處理候選的刪除／filter 與 cap，再交給 storage 批次計分；讀取批次上限為 64。`is_read_with_prefetch_efficient` 在至少兩筆時，用 `max_offset - min_offset < count * 2` 決定是否選 sequential。以下是該公式作用於 **Akasha 的 slot 排列**，不是 Qdrant runtime 的 batch 分布。

| Corpus / mode | 至少兩筆的 64 筆切片 | 符合 sequential 條件 |
| --- | ---: | ---: |
| uniform-128 / all | 9,575 | 0 |
| uniform-128 / correlated | 17,091 | 0 |
| uniform-128 / independent | 17,067 | 2 |
| uniform-1536 / all | 35,425 | 3 |
| uniform-1536 / correlated | 23,511 | 11 |
| uniform-1536 / independent | 23,533 | 3 |
| real-1536 / all | 2,730 | 0 |
| real-1536 / correlated | 15,050 | 1 |
| real-1536 / independent | 8,674 | 3 |

selective 皆走 planned exact，沒有映射圖計分批次。以上包含 upper/base traversal 中實際送去計分的非空批次；單一 entry 的直接計分另存於 trace，不算入這個至少兩筆的分母。

## 每次查詢的實際列數

每列是 72 次 mixed 查詢的平均；「權威」包含 ANN rerank 或 planned exact 的實際列計分。

| Corpus / mode | Mapped graph | Owned graph | 權威數值列 | Mapped 單列 kernel 的列數占比 |
| --- | ---: | ---: | ---: | ---: |
| uniform-128 / all | 3,455.4 | 816.7 | 256.0 | 5.96% |
| uniform-128 / correlated | 1,310.2 | 37.3 | 460.7 | 30.16% |
| uniform-128 / independent | 1,312.3 | 40.5 | 460.8 | 30.38% |
| uniform-1536 / all | 6,808.8 | 820.2 | 1,024.0 | 11.52% |
| uniform-1536 / correlated | 1,706.7 | 37.3 | 716.8 | 38.63% |
| uniform-1536 / independent | 1,699.7 | 40.3 | 716.8 | 38.76% |
| real-1536 / all | 762.1 | 743.9 | 64.0 | 8.28% |
| real-1536 / correlated | 958.0 | 37.1 | 460.4 | 40.24% |
| real-1536 / independent | 613.2 | 202.7 | 256.0 | 33.01% |

三個 selective 路徑皆平均計分 249.7 筆權威列，沒有 graph 列計分。

uniform-1536 correlated／independent 的 mapped 列範圍去重後，每次約 9.95／9.93 MiB，跨約 1,714／1,711 個 16 KiB virtual page；權威列另有約 4.20 MiB，跨約 858／903 個 virtual page。這些數字排除了 query、metadata、object header 與未計分的驗證讀取；不是 RSS、實體 page、cache miss、bandwidth 或 nonresident 證明。Archive 另外保留每個 query 的 4 KiB 和 128-byte 範圍計算，4 KiB 結果也不是 Linux 測量。

較多單列 kernel 呼叫不等於適合重做兩列尾端計分；[既有 tail-pair 實驗](../benchmarks/2026-10-16-neighbor-tail-pair.md)已因跨 cell 退步排除。本輪沒有重做該原型。

## 後續實驗與產物

本輪選擇測試一個與舊實驗不同的假設：只對已通過篩選與 cap 的 mapped F32 候選，提示讀取其第一個位址。這是對 Qdrant 候選處理順序的 Akasha 優化實驗，並非聲稱 Qdrant 同步 mmap 路徑有相同的硬體 prefetch 指令。[該原型的完整結果](2026-10-20-immutable-point-admitted-prefetch.md)仍未改善目標 cell，因此排除。

- 本機：`.build/qdrant-alignment/immutable-point-access-trace/`。
- [Archive](2026-10-20-immutable-point-access-trace.json.gz)：179 份文字產物，10,768,016 bytes。
- SHA-256：`f396a54b619df4d4b91b608eaa99dcc28491ad81b850d1f6b9722ea5b8f81300`。
- 包含完整 diagnostic source、差異、原始 trace、每個 query 的分析、worker 報告、命令及 pinned upstream 檔案。二進位與資料庫以 hash／既有 frozen evidence chain 識別。
- `analyze.py` 使用封存的 host page size，能只靠 archive 中的 raw log 與報告重算；`archive_evidence.py` 驗證來源、所有回應、範圍計數與壓縮 round-trip。
