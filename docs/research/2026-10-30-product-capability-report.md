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

| 領域 | 已有實作 | 缺口／限制 |
| --- | --- | --- |
| 向量 | dense/sparse/named/MaxSim、Dot/L2/cosine、HNSW、RRF、SQ8/PQ、IVF | 完整 Query API、其他 metric、融合／推薦／探索／MMR 等；所有邊界尚未暴露完整核心 |
| 原生資料型別 | F32/F16/BF16/I8/U8、packed Hamming/Jaccard | Qdrant 不同 datatype／quantization 需逐項對照，不能把 raw storage 當量化等價 |
| 文件 | 平面 string/int/float/bool、部分更新、整筆取代 | nested JSON、陣列、null、日期／UUID／geo、完整 payload 操作 |
| 搜尋／過濾 | 布林條件、純量索引、snapshot scan、投影 | 全文 tokenizer／BM25／phrase、nested／geo、排序／分組／通用聚合 |
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
