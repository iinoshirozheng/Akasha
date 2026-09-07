# Akasha 單機目標：生命週期、Arrow、向量型別與效能

日期：2026-09-07。研究基線：`94ff55f`；這是建議路線，未宣稱下列工作已實作。
依據：[函式與資料複製盤點](../research/2026-09-07-lifecycle-zero-copy-api-audit.md)。
既有 [#31–#38 執行計畫](2026-09-07-post-hnsw-performance.md) 保留原本編號與交付狀態。
本文 M1–M6 是能力里程碑，不是 repository 原有 Phase 或 issue 編號。

## 目標到第幾步

**M4 完成時，應具備約定向量型別、Qdrant 類型的單機生命週期，以及可安全借用的
Arrow 資料交換。M5 完成索引／查詢效能工作；M6 通過實測後，才能說在已驗收的
workload 上達到 Qdrant 同等速度。** 不能用完成項目數代替效能證據。

Qdrant 用作單機搜尋與維護行為的對照，Lance／Arrow 用作 columnar data、schema、
scanner 與 buffer ownership 的參考。單機目標不需要先完成 Raft、跨機 sharding
或所有 GPU 演算法；若需要這些能力，另設其功能與故障驗收。

## M1：官方 API 與可量測基線

- 先完成 A01/A02/A05/A06：官方 bit primitives、List copy／extend；Z02：incremental
  flush 先分支，避免 clone 全量 live entries 後丟棄。
- A03/A04 的 sort／BinaryHeap 先用編譯探針與既有 deterministic ties 測試適配，
  再量測 String copy、bounded replace-root 與 scratch allocation，符合合約才採用。
- 每個自訂通用 helper 要能回答：官方 API／既有依賴是否有對應能力、目前版本是否
  可用、語意是否相同。找不到等價 API 時，保留最小 domain wrapper 與原因。
- 建立 copied bytes、allocations、snapshot bytes、writer pause、index build count、
  GPU staging／transfer／resident bytes 的基線。不能把 view 建立次數當深拷貝次數。

驗收：Mojo 1.0.0 編譯；對應 helper 與既有行為測試；純替換不得改 durable bytes。
不以「上游有一個同名函式」取代版本、target、型別與 ownership 驗證。

## M2：向量 field schema 與權威資料合約

先固定 field schema／ownership 合約，再分型別完成可寫入、查詢、重開的垂直切片。
不用等所有型別 kernel 完成，便可依固定合約推進 M3；M4 的完成仍要求型別驗收齊全。

| 能力 | 要明定的語意 | 驗收 |
|---|---|---|
| Dense | 每個 field 的維度、metric、權威 scalar type；F32／F16／BF16／I8 的支援矩陣 | round-trip、距離 oracle、schema mismatch、混合 field 的查詢 |
| Sparse | term ID、weight、排序／重複／空向量規則、獨立索引 | upsert/delete/reopen、Dot、filter、fusion |
| Named vectors | 一個 point 多個具名 vector fields，各自 dimension／metric／index | 只更新一個 field 時其他 field 不變；缺值與刪除規則 |
| Multivectors | 每個 point 有變長向量矩陣、offsets、MaxSim／late-interaction 規則 | ragged／空列、MaxSim oracle、filter、持久化 |
| Binary | bit dimension、padding bit、Hamming／Jaccard；與 I8 或 binary quantization 區分 | 非整 byte 維度、padding、metric、讀寫一致 |
| 多模態關聯 | 文字／圖片／音訊／影片的向量 field 與 payload／URI／blob 的對應 | schema 與資料關聯；原始媒體 storage 另設容量與讀取合約 |

這是明確的目標矩陣，不是所有可能向量型別都已承諾支援；例如 F64、複數向量或
自訂 tensor operators 若新增，須擴充矩陣。F16／BF16／I8 graph encoding 的存在，
不能當成同型別權威資料與完整 ingest API 已完成。

Dense、sparse、payload 共用 point 的更新／刪除可見性；若提供原子多欄更新，必須
有同一提交邊界，不能 dense 成功、sparse 失敗後仍稱 batch atomic。
需要持久化 schema 改動時，更新 format、版本／遷移、fixtures 與 compatibility tests；
不默默重新解釋既有 F32 bytes。

## M3：Qdrant 類型的生命週期與共享資料

用 Qdrant optimizer 的「捕捉新寫入、鎖外建置、短暫發布」流程，結合 RocksDB
generation／snapshot pinning 概念，解決目前 snapshot 全量 clone 與長 writer lock。

1. 讓 immutable generation 擁有穩定的資料 columns、metadata、可重用索引與 config
   identity。snapshot 共享 owner；mutable delta 以有界凍結／版本隔離捕捉。
2. 寫入遵循 WAL durable ordering。維護工作 pin 輸入 generation，在 writer lock
   外 merge／build；新寫入進入新的 delta。發布前檢查 generation 與補齊變更，不能
   覆蓋建置期間的更新。檔案持久化準備、commit point 與短鎖區要明列並量測。
3. 為 indexing、merge、vacuum、configuration rebuild 共用最小 job lifecycle：
   scheduled → building → ready → published；失敗／取消清理未發布 artifact，保留可用舊代。
4. retirement 只移除可見性；generation pin、snapshot、Arrow lease、GPU 使用者都
   離開後才能關閉 mapping／回收檔案。backup 先 pin 一致輸入，再於鎖外做有界複製。
5. collection close 先停止新請求、drain worker、關閉 collection ownership；已承諾
   可獨立存活的讀取 lease 繼續有效。drop 若增加，需另定 logical delete／實體回收規則。
6. 依 bytes、deleted ratio、L0 pressure 與記憶體／I/O 預算選工作；建立 backpressure，
   不讓新 snapshot 或每個 query 意外觸發全量 clone／PQ training。

驗收：update/delete 可見性、old/new snapshots、close 競態、worker failure/cancel、
generation conflict、最後 lease 才回收、各 publish seam crash/restart、torn writes、
checksum／format compatibility、持續寫入時 compaction 的 p95/p99 writer pause。
snapshot 複製量不能隨全部 base vectors/payload bytes 增長；增量成本另量測。

## M4：Arrow typed borrowing、columnar scanner 與直接結果匯出

- Ingress：先用官方 `from_numpy_array` 接 Arrow primitive 的零拷貝 NumPy view，
  以 origin-tracked Span 讀取；producer 必須存活到最後 consumer 完成。拒絕不支援的
  dtype／stride／null／layout，檢查 offset、長度與 alignment，不做隱性全量轉型。
- Storage：在已定案的 generation 中保留穩定 columns／offsets；能直接掃描的資料
  不重建 List-of-vectors。動態可變資料、WAL encoding 與格式轉換的必要複製獨立計量。
- Export：scanner 借用 generation columns，結果直接寫入最終 ID／score buffers；
  透過 Arrow C Data ownership／release 匯出，避免先轉 Python objects 再建 Arrow。
  C Stream 用於有實際需求的批次掃描；跨程序另用 IPC／Flight 等傳輸合約。
- 以現成 PyArrow／NumPy 與標準 C Data ABI 為邊界；若需要原生 producer，只實作
  schema、buffer ownership、release bridge，不自行重寫 Arrow parser／IPC。
- 既有 owned `get`／export API 繼續回傳獨立資料；新 borrowed API 清楚標明壽命。
  retained producer lease 與 memcpy-owned result 是不同合約。

驗收：指標相同與 copied bytes、sliced/null/empty/ragged arrays、錯誤釋放、producer
先關閉、collection close 後讀取、compaction 後舊 view、不同 vector fields、長時間
scanner 與索引更新並行。測試實際 C release callback 與 owner，而非只計數的模型。

copy budget：借用交換不複製完整 primitive buffer；snapshot 不複製 immutable base；
熱查詢不整理整份資料。新計算輸出、明確 owned API、durable encoding、CPU/GPU
跨裝置傳輸可能需要配置或複製，必須量測，不能承諾整個資料庫所有路徑 0 copy。

## M5：索引與查詢效能

- A07 用官方 Dict 消除 sparse/fusion 的重複線性 lookup；保持累加順序與 ties。
- SQ8/PQ 訓練與 build 成為 generation/config 綁定的 artifact，query 只使用就緒索引。
  IVF／binary／MaxSim 分別有適用的索引與 rerank 路徑，避免一律塞進同一 HNSW。
- 延用 #33 的 candidate recall／final recall／fallback observability；補上新型別與
  lifecycle 的工作負載，不用降低 recall 換取表面速度。
- 整合 #34–#38 的 GPU context/buffer 重用、distance／Top-K、CPU SIMD、載入驗證、
  crossover。MAX 官方 kernels 通過可 import、Metal／CUDA target、ties 與 scratch
  capability gate 才採用；GPU ANN 視目標 workload 的實測缺口另行加入。
- Planner 根據 filter selectivity、index readiness、資料量／維度、K／batch、device
  residency 決定 exact／ANN／GPU，建立可讀取的選擇原因與 bounded work。

驗收：各 metric、負 ID／ties、odd dimensions、varied K、ragged／empty filters、
update/delete、base/delta；效能檢查包含 prepare、搜尋、rerank、payload 與傳輸。

## M6：Qdrant 對照驗收

固定 Akasha／Qdrant 版本、硬體／CPU threads／memory limit、資料與 query seeds、
向量型別／metric、filter、K、目標 recall、並行與讀寫混合比例。分開量測：

- Embedded kernel、bindings、HTTP service；跨不同 service 邊界的數字不可直接比。
- warm steady-state、cold/open、resident／non-resident、index build／maintenance。
- QPS、p50/p95/p99、candidate／final recall、filter correctness、RAM/disk、ingest，
  以及持續寫入／compaction 下的延遲與 snapshot／Arrow lease 記憶體。

先約定目標 workload 與容許差距，再跑 repeated trials、記錄離散程度並保留原始資料。
「同等速度」只能限定於通過門檻的 cells；不能外推所有維度、資料量或所有向量型別。
Qdrant 沒有直接對應的型別／metric，採適合的獨立 oracle／reference，列為不可直接比較。

## 每個參考課題與里程碑

| 課題 | 主要參考 | 目前基線／缺口 | 對應 |
|---:|---|---|---|
| 1. HNSW、layout、pruning、mmap | USearch、Qdrant | HNSW 已合併；持續量測 scratch／layout | M1、M5 |
| 2. Filtered ANN／不足 K 補搜 | Qdrant、pgvector | 已有 filtered candidate expansion；需新型別與高選擇性測量 | M5、M6 |
| 3. GPU context／resident buffers | Faiss、cuVS、MAX | #34 正在開發，需連到 generation owner | M3、M5 |
| 4. Tiled distance／parallel Top-K | Faiss、cuVS、MAX | #35 待交付；先查官方 kernels | M1、M5 |
| 5. CPU SIMD／compact layout | USearch、Faiss、Mojo stdlib | 已有 SIMD；#36 擴充量測 | M1、M5 |
| 6. SQ／PQ／IVF | Faiss、Lance | SQ8/PQ 已有，但 snapshot 路徑逐 query build；IVF 另補 | M3、M5 |
| 7. GPU ANN／CAGRA／multi-GPU | cuVS、Faiss | 另設 workload 與硬體目標；非單機 CPU parity 必備 | M5 後按需要 |
| 8. WAL／LSM／compaction／backpressure | RocksDB、Qdrant | 已有 WAL、manifest、segments、recovery；copy/lock 問題待解 | M1、M3 |
| 9. Segment／index lifecycle | Qdrant optimizers、RocksDB | background build、vacuum／rebuild、short publish、budgets 待整合 | M3 |
| 10. Snapshot／visibility／reclamation | Qdrant、RocksDB、pgvector | 已有 pins/retired queue；snapshot 仍全量 clone | M3 |
| 11. Arrow exchange／ownership | Apache Arrow、LanceDB | 已有 PyArrow C capsule import；compiled ingress 仍 boxing，result export 重建 | M4 |
| 12. Columnar data／fragments／versioning | Lance、Arrow | 目前 authority 仍以 MemTable owned records 為主 | M2、M3、M4 |
| 13. Object storage／multimodal media | Lance／LanceDB | 先定向量與 payload 關聯；remote storage／media streaming 是額外目標 | M2；儲存擴充另列 |
| 14. Planner／vectorized execution | DataFusion、DuckDB、Lance | 已有 planner／batch；需要 columns、pushdown 與量測決策 | M4、M5 |
| 15. Sparse／full-text／hybrid／ranking | Qdrant、Vespa、Weaviate | sparse／RRF 已有；lookup 待優化，full-text／多階 ranking 分項驗收 | M2、M5 |
| 16. 正式 Raft consensus | raft-rs、etcd-raft | 現有 coordinator quorum 不等於 Raft；先評估成熟 library 整合 | 單機目標以後 |
| 17. Sharding／replication／repair | Qdrant、Milvus、Weaviate、Vespa、Cassandra | 不以單機成功推定跨機一致性；需分散式故障模型 | 正式共識之後 |
| 18. 完整 vector field model | Qdrant、pgvector、Lance／Arrow | 補 named、multivector、binary 與 native scalar matrix | M2 |
| 19. 官方 API 與 copy audit | Mojo stdlib、MAX、Arrow、NumPy | 本次已建 inventory／重點查核／編譯探針；替換尚待實作 | M1，貫穿 M2–M6 |

Qdrant lifecycle 的具體上游依據是
[optimizer 實作](https://github.com/qdrant/qdrant/blob/master/lib/shard/src/optimize.rs)；
Arrow ownership 依 [C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html)，
Mojo typed borrow 依 [from_numpy_array](https://mojolang.org/docs/std/python/numpy/from_numpy_array/)。
其他專案是各課題的閱讀入口，並非聲稱其每個實作可直接連結到 Mojo／Metal。

下一個獨立實作切片：**M1 的 bit/List primitives 與 incremental flush 複製修正**。
隨後定 M2 ownership/schema 合約，將 M3 lifecycle 作為 M4 zero-copy exchange 的基礎。
與正在進行的 #34–#38 以檔案與 commit 邊界協調，整合後重新盤點 GPU owner 與 snapshot。
