# Immutable point：Qdrant 批次讀取與 CPU 計數器對照

本輪以 Qdrant 原始碼確認批次向量讀取的實作，再對保留的 deferred-ID 版本取得 CPU 計數器。沒有修改產品程式、採用新的優化或新增達標項目。嚴格 mixed 結果仍為 **25/36**；這些短追蹤不能取代完整工作負載的品質、QPS 與 p95 門檻。

## 固定實作與原始碼

- Parent：`immutable-point-deferred-id`，132 份 Mojo 原始碼的 SHA-256 均與既有 archive 相符。
- Akasha native SHA-256：`64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`。
- Qdrant Edge native SHA-256：`746ce4acdbb56db68aaba805bddf52961a083c5ed5da19f16b5ba500114c788d`。
- Qdrant source pin：`21db2f3ff95d50de3a2b88a741312c056fd1762d`。Archive 的八份上游檔案（含 LICENSE）逐份比對 `git show` 與本地 checkout，避免誤用另一份 checkout 的 HEAD。
- Production `src/` 仍與 `a6822c3` 相同；前一輪被排除的 mapped-loop 原型不是本輪 parent。

實際讀到的路徑如下：

| Qdrant 檔案 | 本輪確認的行為 |
| --- | --- |
| `vector_storage/common.rs` | `VECTOR_READ_BATCH_SIZE` 為 64。 |
| `dense/immutable_dense_vectors.rs` | 同步路徑每批先準備向量切片，再呼叫 scorer；具非同步能力的 storage 另有路徑。 |
| `chunked_vectors/read_only/read_ops.rs` | 同樣先填入批次切片，再執行 callback。 |
| `query_scorer/mod.rs` | 少於兩筆不選 sequential；其餘以 offset 的跨度是否小於筆數兩倍判定。 |
| `query_scorer/metric_query_scorer.rs`、`dense/dense_vector_storage.rs` | 串接 point offsets、批次向量存取與 similarity。 |
| `lib/common/common/src/universal_io/mmap/mod.rs` | mmap 讀取回傳檢查過範圍的借用切片；依存取模式選擇 mapping pointer，讀取生命週期有明確契約。 |

上游的「先準備切片」不能直接解讀成預先讀完整向量或發出硬體 prefetch。Akasha 的顯式可關閉 mapping 也不能直接照搬逃逸的裸指標。需要保留 ownership、關閉與越界檢查，並用實測決定是否採用相同的批次安排。

前一輪[縮減映射計分迴圈檢查](2026-10-20-immutable-point-mapped-loop.md)雖減少了組合語言分支，完整 screen 沒有穩定改善，因此未採用。更早的[HNSW prefetch 實驗](../benchmarks/results/2026-10-01-hnsw-prefetch.json)也沒有提供可直接採用的證據。

## 追蹤範圍與驗證

使用 frozen `uniform-1536` 初始資料庫、correlated / independent 各兩筆固定查詢（ordinal 3、4），維持兩引擎原有 ef 512。每次用獨立資料庫副本，worker 重複建立 request 並搜尋；計數器附加至該 worker，記錄五秒。所有錄製、匯出與分析依序執行，沒有同時跑 build、測試或 benchmark。

有效資料共有八份：兩引擎 × 兩種 filter mode × CPU Bottlenecks / Instruction Processing。它們有 **16 筆前置、16 筆後置**回應驗證，IDs、F32 score bits 與可取得的 stats 均符合 parent 對應的初始查詢結果。迴圈中的每次回應並未逐筆驗證；重複次數也包含錄製之外的時間，不能當作獨立品質樣本或拿來正規化計數器。

分析解析 XML 的 `id/ref`，只保留目標 PID，依 thread 與 Performance / Efficiency core class 分組，保留全部 **160,793 個數值 interval**。按照安裝版本的 metric metadata，比例以 interval duration 加權；另外保留 cycle-weighted 值。每個指標有各自的數值覆蓋率，sentinel 維持 null，不補零、不將分類重新正規化。

表格取主要搜尋 thread 的 Performance core group：Akasha 為 main thread，Qdrant 為 `edge-search-0`。兩者是不同的執行路徑與分母；Qdrant main thread 和少量 Efficiency core 資料另存於 archive，沒有併入下表。表中各比例的 duration 覆蓋率皆大於 99.99%。

## 有效觀察

CPU Bottlenecks 的 duration-weighted 比例：

| 引擎 / filter | Delivery | Discarded | Processing | Useful |
| --- | ---: | ---: | ---: | ---: |
| Akasha correlated | 3.99% | 10.21% | 39.72% | 45.01% |
| Qdrant correlated | 4.26% | 8.32% | 63.13% | 23.93% |
| Akasha independent | 4.01% | 10.11% | 40.62% | 44.21% |
| Qdrant independent | 4.26% | 8.38% | 62.94% | 24.05% |

較高的 Processing 比例不等於引擎較慢。這是 CPU 執行特性的比例，不能推導跨引擎的操作次數或每次查詢成本。

Instruction Processing 細項：

| 引擎 / filter | Critical L1D miss，未執行 µop | Critical L1D miss，仍執行 µop | Executing | Execution latency | Non-critical L1D miss |
| --- | ---: | ---: | ---: | ---: | ---: |
| Akasha correlated | 14.46% | 27.39% | 55.35% | 1.83% | 0.98% |
| Qdrant correlated | 19.87% | 17.64% | 56.09% | 3.53% | 2.87% |
| Akasha independent | 13.98% | 27.43% | 55.80% | 1.84% | 0.96% |
| Qdrant independent | 20.44% | 20.86% | 52.37% | 3.42% | 2.91% |

前兩欄分別描述最老的 tracked load/store 等待 L1D 之外資料時，執行端沒有／仍有執行 µop 的情況。它們不是 cache miss 次數占所有 load 的比例，也不代表 DRAM bandwidth。解讀依據為安裝版本的 RecountDT metric 定義及 [Apple CPU bottleneck 說明](https://developer.apple.com/documentation/xcode/addressing-cpu-bottlenecks)。

八份追蹤的目標 thread cycle 總量中，Performance core 占比皆大於 99.97%。這組資料不支持「Akasha 主要跑在效率核心」的解釋。Akasha 的 critical-miss idle 比例也沒有高於 Qdrant，因此不能據此將 mixed 差距歸因為 Akasha 獨有的資料等待或直接採用 prefetch。

這些結果仍只涵蓋少量重複的初始查詢；工作集合與完整 mixed 更新序列不同，且每種設定只有一次 capture。它們能排除過早的結論，不能證明完整工作負載的主要瓶頸。

## 失敗嘗試與證據處理

第一份自訂 processing template 將 analysis identifier 錯設為 `processing`。錄製與匯出雖回傳 0，卻沒有 `MetricTableForThread`。該份沒有計數器證據，其額外兩筆前置、兩筆後置查詢驗證不混入八份有效 capture 的計數。

讀取本機安裝的 analysis 定義後，改用 `analysisMode=bottleneck`、`countingMode=processing` 與正式 mode label，再確認輸出表與 metric 名稱。原設定、修正腳本及 hashes 都保留；沒有修改 Xcode 安裝檔。初始 analyzer 對 sentinel／分類總和有錯誤假設，其腳本亦保留。一次尚未完成匯出的解析及 archive 引用不存在檔案的錯誤另有紀錄；均未拿失敗產物充當有效數據。

原始 `.trace`、TOC 可能包含程序環境；原始 metrics XML 包含 Apple 說明文字。因此 archive 保留完整目標數值、來源 hashes、移除環境與唯一裝置標籤的 TOC、命令、query audits、分析腳本及 pinned Qdrant source。原始 trace、metrics XML、專有 template bytes 與資料庫副本留在本機。

## 決策與尚未完成項目

保留 deferred-ID parent，下一步量測**完整 frozen mixed 工作負載的向量 slot／page 存取分布**，再選擇符合 ownership 契約的批次讀取改動。不得根據兩筆重複查詢增加配置、調整 ef 或放寬門檻。

既有結果仍為 mixed 25/36、quality 33/36、write + flush 9/9；八個 speed failure 與三個 Qdrant real-correlated quality failure 均未解決。完整 warm、mixed、concurrent、capacity、原生 Linux 及 M5/M6 gate 仍依[原計畫](../plans/2026-10-13-mapped-numeric-ownership.md)驗證。本輪未改產品程式，沿用 parent 的 CPU、Python、crash 與 C ABI 成功結果，沒有重新執行不受影響的測試。

## 可重現產物

- 本機工作目錄：`.build/qdrant-alignment/immutable-point-memory-profile/`。
- [數值與原始碼證據 archive](2026-10-20-immutable-point-memory-profile.json.gz)：147 份文字產物，4,718,507 bytes。
- SHA-256：`21701db88766c3ca35469f48642a514a47d8df28e70bdf89f3ad7982e2e68b17`。
- `normalize_counters.py` 從本機 XML 擷取數值；`aggregate_counters.py` 只需 archive 內的 `normalized/` 即可重算八份摘要。
- `freeze_profile.py` 驗證 132 份 parent source、native identities、上游 pin、所有前後置查詢、加權數值、archive hashes 與壓縮後 round-trip。
