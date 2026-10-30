# Akasha 完整產品功能差異報告

日期：2026-10-30。盤點起點：`16c0c08`；Mojo `1.0.0 (ed45d567)`。

## 使用者目標與執行順序

先保存報告與任務清單，再完成先前未完成工作及缺少的 Qdrant、LanceDB、
一般資料庫功能。**先功能與正確性，全部功能驗收後才做效能優化。**
先讀取成熟產品原始碼，移植到 Mojo 並用上游測試／原生執行結果比對；不另創
搜尋、排序、索引、交易或一致性演算法。不能把局部元件、API 名稱、計畫或
mock 成功算作功能完成。

核心計算、查詢、索引、資料模型、持久化與交易語義由 Mojo 負責。
Python/C/Arrow、HTTP/gRPC 和網頁是邊界，不能把需要移植的資料庫邏輯藏進 Python。
網頁採網頁技術；現有 Python 服務可繼續處理傳輸與驗證。上游第三方函式庫
已有明確必要性時先查既有依賴，再選擇 Mojo 介面或經驗證的 FFI。

此次完整範圍包含前兩次比較中的所有缺口；Qdrant API inventory 的未對應
端點亦列為待辦。一般 DB 具體涵蓋 CRUD、條件、投影、索引、SQL、JOIN、
聚合、排序、約束、可組合交易、跨 collection 交易、view、trigger 與 procedure。
Cloud／Enterprise 功能列在產品工作包，不能因開源參考缺少服務控制面而刪除。
商用實作沒有公開原始碼的部分須記錄可取得的公開規格、可採用的開源實作及
尚待確定的行為，不能宣稱已經移植該商用產品的私有原始碼。

## 當前狀態

最新 D01c2 已完成巢狀 typed Arrow 匯出，與 D01c1 匯入共用原生型別契約；14 項相關原生測試及完整 Python **3,385 通過、1 跳過**。4,252 組浮點轉型結果與原始 Arrow 逐位元／溢位對照通過。動態 JSON extension、持久 schema／歷史版本與 Lance 格式仍未完成，見[匯出驗證與範圍](2026-10-30-rich-arrow-export-validation.md)。

| 領域 | 已有實作 | 缺口／限制 |
| --- | --- | --- |
| 向量 | dense/sparse/named/MaxSim、Dot/L2/cosine、HNSW、RRF／加權 RRF／DBSF、SQ8/PQ、IVF、同型別點 ID 查詢與跨 collection lookup、三種 exact 與 dense HNSW 推薦策略、來源對照的稀疏推薦執行、nearest MMR、原生 discovery/context 與 dense 兩階段 HNSW、nested prefetch 查詢樹、來源 MMR 階段與支援巢狀 payload／JSON 預設值、地理距離與日期的公式 | 完整 Query API、其他 metric、multivector HNSW、稀疏設定／IDF與完整來源 planner 對齊、探索批次與完整協定、完整公式／抽樣／feedback、完整跨型別與儲存前處理對照等；推薦重複向量召回缺口保留，所有邊界尚未暴露完整核心 |
| 原生資料型別 | F32/F16/BF16/I8/U8、packed Hamming/Jaccard | Qdrant 不同 datatype／quantization 需逐項對照，不能把 raw storage 當量化等價 |
| 文件 | string/int/float/bool、物件／陣列／null／UInt64、部分更新、整筆取代；payload v2 與舊格式讀取；依 IDs／既有條件選取的 payload set／overwrite／delete／clear 與路徑更新；原生 GeoPoint／DateTimeValue 驗證及地理／日期公式；巢狀 typed Arrow 匯入與指定型別／nullability／metadata 匯出 | 動態 Arrow JSON extension、任意頂層鍵、UUID 型別、專用日期／地理索引、完整混合批次及協定相容 |
| 搜尋／過濾 | 布林條件、純量索引、JSON-path／巢狀同元素條件、日期範圍、地理矩形／半徑／polygon、集合／純文字條件、空值／數量、點 ID／向量存在／固定 slice、獨立路徑空值條件、snapshot scan、投影 | 全文 tokenizer／BM25／位置式 phrase、專用日期／地理／巢狀／陣列索引、排序／分組／通用聚合 |
| 儲存 | WAL、原子點批次、manifest、compaction、mmap、恢復 | 歷史版本、time travel、動態 schema、Lance 相容、物件儲存、Blob 管理 |
| 交易 | 單 collection 原子批次、固定讀視圖、序列化 writer | BEGIN/COMMIT/ROLLBACK、隔離與衝突規則、跨 collection 原子性、約束 |
| 邊界 | Python、C ABI、Arrow、部分 FastAPI 路由 | Qdrant REST/gRPC 相容、完整 CRUD 管理與批次功能、SDK 生態 |
| 介面 | Swagger | Dashboard、資料瀏覽、查詢控制台、指標／權限／備份介面 |
| 叢集 | loopback 多程序 routing/quorum/failover/catch-up | 正式跨機、Raft topology、獨立 coordinator、成員管理、一致性選項、擴縮容 |
| 維運 | 備份／還原／NDJSON、基本 metrics/traces、資源限制 | API key／TLS／權限、稽核、安裝套件、監控告警、升級、雲端管理 |
| 效能 | 歷史測量與失敗紀錄 | M5/M6 未達標；合併後未完整驗收；原生 Linux 依既有指示暫緩 |

已有能力依 `docs/python-api.md`、`docs/operations.md`、`docs/distributed.md`
與實際 `src/akasha`、`src/bindings`、`python/akashadb`、`apps/server` 交叉核對。
文件可能落後於程式：例如舊 Python API 說 named HNSW 沒有持久 sidecar，
合併後 `storage/field_hnsw_cache.mojo` 已加入可選快取；完成驗收須以實際路徑為準。

## 與三種產品定位的關係

- 對 Qdrant：額外選擇包含 IVF、raw BF16/signed I8、raw binary Hamming/Jaccard。
  Arrow C Data、C ABI 與 GPU exact batch 是整合／執行特性，不代表整體功能較完整
  或效能較好。Qdrant Edge 也有嵌入式使用，不能算 Akasha 獨有。
- 對 LanceDB：已有嵌入式、Arrow 批次、投影、掃描、向量與融合；尚無 Lance 格式、
  歷史版本、schema evolution、Blob/object-store 及完整 IVF 組合索引。
  Akasha 的 read snapshot 不等於可任意 checkout 歷史 table version。
- 對一般 DB：已有基礎資料儲存／操作與原子批次；尚無 SQL、關聯查詢、通用
  聚合或可組合／跨 collection 交易。不能用 WAL 與批次原子性宣稱完整 SQL ACID。

不計算無分母的完成百分比。細項以可驗收的任務與來源清單追蹤。

### 如何理解「比 Qdrant 多多少」

可以列出三組額外向量選擇，但不能據此說產品總功能比較多：

| Akasha 的額外選擇 | 實際能力及限制 |
| --- | --- |
| IVF 候選搜尋 | 已有原生查詢路徑；尚未實現 LanceDB 全套持久 IVF 組合索引 |
| 原生 BF16／signed I8 | 儲存和計分型別；不等同 Qdrant 的 uint8 或量化模式 |
| 原生 packed binary Hamming／Jaccard | 可直接處理二進位向量；與浮點向量的 binary quantization 是不同契約 |

C ABI、Arrow C Data 和 GPU exact batch 是整合／執行選擇，也不宜把每個介面
名稱算作獨立的產品優勢。Qdrant 已有 Edge 嵌入式產品和 GPU 索引能力，不能
泛稱嵌入式或 GPU 為 Akasha 獨有。此比較以固定來源盤點及當日官方
[向量文件](https://qdrant.tech/documentation/manage-data/vectors/)、
[索引文件](https://qdrant.tech/documentation/manage-data/indexing/) 和
[Edge 文件](https://qdrant.tech/documentation/edge/) 為依據。

### 一般 DB 功能的可用邊界

| 能力 | Akasha 當前狀態 |
| --- | --- |
| CRUD、依 ID 讀取、條件過濾、欄位投影、批次掃描 | 已有，支援範圍依原生／Python API |
| 純量索引、WAL、重啟恢復、compaction、備份還原 | 已有；不能推論所有部署和事故情境已驗收 |
| 單 collection 原子批次、保留固定讀視圖 | 已有；不是任意歷史版本查詢或可組合交易 |
| SQL、JOIN、通用 GROUP BY／聚合、CTE、window | 尚未實作 |
| BEGIN／COMMIT／ROLLBACK、跨 collection 交易 | 尚未實作 |
| UNIQUE／外鍵等約束、view、trigger、procedure | 尚未實作 |

LanceDB 的 [table versioning](https://docs.lancedb.com/tables/versioning) 與
[schema evolution](https://docs.lancedb.com/tables/schema) 是另外的持久資料能力，
Akasha 的 Arrow 邊界與讀快照尚不能取代它們。

Dense HNSW 推薦的實作、對照及品質限制見
[推薦 ANN 驗證](2026-10-30-recommendation-ann-validation.md)。能執行這個路徑
不等於完整 Qdrant Query API、整體品質或效能達標。
稀疏推薦另已驗證來源的不同執行路徑；零分是否回傳取決於 plain／批次／最後
posting 路徑，不能概括為一律排除。一般 nearest／預設欄位／融合重排亦已接到同一核心；
新增小數與溢位對照揭露並修正了乘加融合改變 F32 結果的問題。
見[共用稀疏驗證](2026-10-30-sparse-nearest-validation.md)。
Nearest MMR 已接上原生、Python 與 Arrow；來源選擇、方向性 MaxSim 與保留原分數
已有對照。nested prefetch 已於 Q04a 整合，完整協定仍待完成，見
[MMR 驗證](2026-10-30-mmr-validation.md)。
Q04a 原生通用查詢樹已接上 Mojo／Python／Arrow，包含來源 prefetch、父層 filter、
全域本 collection ID 排除、候選聯集重排與 root／nested／leaf MMR。
仍非完整 Query API，見[通用查詢驗證](2026-10-30-universal-query-validation.md)。

Q04b 數值公式已接上 Mojo／Python／Arrow，包含來源短路求值、缺值預設、
純量條件與三種衰減函數，對 prefetch 候選聯集重排。309 組來源案例與完整
Python 測試已驗證；當時完整 JSON-path、日期、地理與 rich defaults 尚未完成；路徑、rich 值、地理距離與日期已由後續 D01a／Q04d／Q04e／Q04f 補入，
不能列為完整公式相容。見[公式驗證](2026-10-30-formula-validation.md)。

D01a／Q04c 已移植共用 JSON-path 語法、路徑操作與 Rust Unicode 17 分類，
公式可讀取加引號的字面欄位、Unicode 名稱並接受完整 UInt64 分數索引。
此階段只有路徑語法，見[路徑驗證](2026-10-30-json-path-validation.md)。
後續 D01b 已加入物件／陣列／null／UInt64 持久化及來源對照的 owned-value
get/set/remove；Python、現有 HTTP、備份與 NDJSON v2 可保存巢狀資料。
後續 D05a 已將 collection 路徑更新接上 Mojo／Python／現有 HTTP，保留所有向量，
在同一寫入鎖下選取、轉換並原子提交。rich Arrow 與專用索引仍未完成；nested／日期範圍與地理矩形／半徑過濾由後續 D03d 補入。
見[rich payload 驗證與範圍](2026-10-30-rich-payload-validation.md)。
Q04d 已將來源 payload retriever 的路徑取值、單層陣列攤平、缺值／null 分別處理、
UInt64 與 rich defaults 接入 Mojo／Python／Arrow 公式查詢；這不包含
專用 typed-index retriever；地理／日期公式由後續 Q04e／Q04f 補入。見
[rich formula 驗證](2026-10-30-formula-payload-validation.md)。
Q04e／D03b 已移植 Qdrant GeoPoint 驗證及其固定 geo 0.33.1 的 Haversine 距離，
接入 Mojo／Python／Arrow 的地理公式、路徑／預設值與衰減組合。地理矩形／半徑過濾由後續 D03d 補入，專用索引仍待完成；
日期型別及公式由後續 Q04f 補入，見[地理公式驗證](2026-10-30-geo-formula-validation.md)。
Q04f／D03c 已移植 Qdrant／chrono 0.4.45 日期解析、UTC／閏秒與微秒時間戳，
日期常數、payload 日期及衰減公式可經 Mojo／Python／Arrow 使用。日期範圍條件已由後續 D03d 補入，
專用索引及完整協定仍未完成，見[日期驗證](2026-10-30-datetime-validation.md)。
D03d 已將 Qdrant plain payload checker 接上 Mojo／Python／Arrow 與現有 HTTP：
JSON-path、巢狀同元素條件、至少 N 條件、集合／純文字、數值／日期範圍、
空值／數量、地理矩形／半徑可用於搜尋及條件更新。10,781 組原始來源案例
涵蓋 10 組預期拒絕；完整驗證見[payload filter 驗證](2026-10-30-payload-filter-validation.md)。
D03d 本身不包含 polygon；後續 D03e 已補入原始 GeoRust 幾何與 robust 自適應
精度判定。專用 typed indexes、tokenizer／BM25 與完整 Qdrant 協定仍未完成。
見[polygon 驗證](2026-10-30-polygon-validation.md)。
D03f 已補上點 ID／向量存在／固定 slice 與獨立路徑空值條件，保留來源 nested
身分隔離；12,656 組來源案例與 2,187 組雜湊對照，完整 Python 3,248 項通過。
現有 signed Int64 點 ID 與預設 sparse field_id 選取是原生契約；完整 UInt64／UUID
持久化與協定仍未完成。見[點條件驗證](2026-10-30-point-filter-validation.md)。
更新操作與 native／Qdrant 提交語義邊界另見
[payload mutation 驗證](2026-10-30-payload-mutations-validation.md)。

探索／context 已接上 Mojo／Python／Arrow 的 exact、稀疏完整計分與 dense 兩階段
HNSW，含同 collection ID 排除、外部 lookup 與 snapshot。來源對照也修正了
`-0.0` 加總起始值導致的排名差異；完整 batch／協定、型別／儲存與來源 planner
仍未完成。見[discovery 驗證](2026-10-30-discovery-validation.md)。

## 固定來源與授權

現有參考目錄在盤點時均無未提交修改：

| 來源 | Commit | 用途 |
| --- | --- | --- |
| Qdrant v1.19.0 | `74f3e85b9473c62560006c043e13737ce6b48412` | 公開 API、查詢、payload、索引、叢集 |
| Qdrant Edge 0.8.0 | `21db2f3ff95d50de3a2b88a741312c056fd1762d` | 延續已有行為 oracle，不覆寫歷史參考 |
| Lance | `ad2ee27f0f0ad2cd4d756b85214b5a7e5dc1b06e` | table/version/schema/transaction/Blob/storage |
| LanceDB | `2fbf6d62113face594782e0030909740069a4313` | SDK、query/index/table 管理 |
| RocksDB | `6dbb6f30e604e0047db29f06fe1c28c348074c98` | 批次／交易／恢復參考 |
| raft-rs | `ad13f3d90780f53aea2488c6a4b76c0d334bf136` | consensus state machine 與訊息測試 |
| pgvector | `e48241b4dcc045b18902914f668d03d1d399dfbe` | PostgreSQL 向量／型別邊界 |

地理距離另外固定 GeoRust geo 0.33.1（`5ab50b072e34a915a33eaa46c80763d51d61295e`），
使用 Qdrant Cargo.lock 對應的 crate checksum；來源與 MIT 通知已登錄 port registry。
日期另外固定 chrono 0.4.45（`170338250e836976a211e64728ec956e45e78a39`），
原始 license、calendar/scanner 來源與 Rust whitespace 表的來源版本均分別登錄。

每次移植登錄檔案、commit、函式、原檔 hash、license/NOTICE、Mojo 對應檔、
改寫範圍及 differential test。原始碼內保留來源與授權註記，隨專案保存必要通知。
新功能若只出現在目前官方文件的較新版本，新增固定 checkout 和差異清單；
上述 v1.19.0 並非刪除較新功能需求的理由。SQL 需額外固定 PostgreSQL／
DataFusion 等適用的開源來源，不能僅憑 pgvector 當 SQL 引擎來源。

## 已完成的歷史驗證與繼承限制

`docs/handoff/2026-10-23-branch-consolidation.md` 記錄合併時的 50 個 Mojo 模組、
619 個不同 Python 案例、9 個 crash 模組、10 個本機 distributed 案例與 builds。
這些是當時來源的證據，並非新功能驗收，也不是整套產品完成。
原來的 Recall >= 0.95、QPS >= Qdrant、p95 <= Qdrant 門檻保留。
只對 Qdrant real-1536/correlated 使用者核准的 ef=128 例外保留；
不刪舊失敗、不調低門檻、不採用已封存但未驗收原型。

## 參考文件

- Qdrant：https://qdrant.tech/documentation/overview/
- Query：https://qdrant.tech/documentation/search/search/
- Index：https://qdrant.tech/documentation/manage-data/indexing/
- Edge：https://qdrant.tech/documentation/edge/
- LanceDB：https://docs.lancedb.com/
- Version/schema：https://docs.lancedb.com/tables/versioning 、https://docs.lancedb.com/tables/schema
- Storage：https://docs.lancedb.com/storage/configuration
- SQL 版別：https://docs.lancedb.com/search/sql （Enterprise endpoint）與公開 DuckDB/Lance integration

下一步與逐項狀態見 [完整任務清單](../plans/2026-10-30-feature-completion.md)。
