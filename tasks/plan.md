# #31–#38 之後的執行規劃

規劃日期：2026-09-07。複核基線：`main` 的 `a8895c6`；engine 是 `9b98dbc`。
規劃後使用者已授權實作 #39–#42；進度與驗證以 todo.md 為準。
工作包 #39–#46 是延續既有交付序號的建議編號，不是已建立的 GitHub issues。
唯一執行 checklist：[todo.md](todo.md)。完整能力與 19 個參考課題仍在
[單機路線](../docs/plans/2026-09-07-single-node-lifecycle-zero-copy.md)。

## 完成狀態與剩餘缺口

#31–#38 可以結案，沒有從該範圍查到尚未完成的必做收尾。核對 Git commits、
另一個 task 的完成狀態，以及 [Actions 34099524657](https://github.com/iinoshirozheng/Akasha/actions/runs/34099524657)：
native macOS／Linux 各通過 638 Mojo tests、Python 49／48 tests、9 crash tests、
C ABI、build、examples 與 quality gates；Apple M4 Pro 的 9 GPU tests 依交付紀錄通過。
`9b98dbc` 後兩筆提交只新增／更新文件與研究產物；本輪不重跑未變動的 engine suite。

新目標仍有以下缺口：

| 類別 | 複核證據 | 規劃 |
|---|---|---|
| Snapshot ownership | `ReadSnapshot.capture` 仍 clone MemTable／SparseIndex、重建 metadata | 共享 immutable generation，delta 版本隔離 |
| 多餘複製 | `_flush_unlocked` 先 materialize 全量，再替換成 delta；backup 整檔讀入 | #39 先消除 discarded copy；有界 backup 接生命週期工作 |
| Arrow | C capsule 進 PyArrow 後，Mojo binding 仍逐 primitive boxing；結果經 Python objects 重建 Arrow | #45 先做同步借用；後續直接結果 buffers 與 generation lease |
| Index lifecycle | Snapshot SQ8/PQ 每 query build；compaction、backup、HNSW rebuild 長時間 writer lock | pin → 鎖外 build → validate/publish → 最後 lease 回收 |
| 官方 API 重用 | bit／List loops、metadata sort、heaps、sparse／fusion lookup 待處理 | 小型等價替換先交付；heap/sort 通過語意及性能 gate 再換 |
| 向量型別 | 權威 dense F32 與 sparse 已有；named/multivector/binary/native scalar API 不完整 | #46 先定 field/ownership 合約，再逐型別完成讀寫查詢重開 |
| Qdrant 速度目標 | 尚無對照；高維 uniform ef=128 最低 mean Recall@10 約 0.684375 | 提前建立同 recall 的對照基線，最後才作 parity 驗收 |

已有的 GPU snapshot cache、ragged batch、tiled Top-K、compact SIMD、CRC table／mmap
驗證優化直接沿用。GPU 保持 opt-in；目前證據沒有支持新增 GPU ANN、重寫 scratch，
或宣稱 NVIDIA／AMD 已驗證。

## 執行順序

| 批次 | 工作 | 交付邊界 |
|---|---|---|
| 第一批 | #39 flush、#40 bit、#41 vector copy、#42 byte append | 4 個小改動各自驗證與提交；持久化 bytes／公開合約不變 |
| 第二批 | #43 sparse Dict、#44 fusion Dict、#45 Arrow typed ingress | 各自端到端可運作；保留 ties、更新刪除與 producer ownership |
| 設計檢查點 | #46 generation／field ownership 合約與成本基線 | 明確選定實作方式並拆出小工作包；不是一次重寫全庫 |
| 下一批能力 | 共享 snapshots → 背景 compaction／backup → index lifecycle → leased scanner/export | 依 #46 定案結果切片；每片包含 correctness／失敗路徑驗收 |
| 向量擴充 | named F32 → native scalar → binary → multivector/MaxSim | 每一型別都有 durable migration、write/read/search/reopen；不與核心 ownership 同批改 |
| 品質／速度對照 | Qdrant 基線與 recall–latency 曲線提前，整合後再跑最終矩陣 | 固定硬體、資料、recall、filter、並行與 service 邊界 |

#39–#45 並非 #46 的全部前置；ownership 設計可在第一批 checkpoint 後開始。
數字表示工作包識別，實際依賴以 checklist 為準。官方 heap/sort 的評估也不阻擋
生命週期設計，避免低影響清理延後最大的 snapshot／writer-lock 問題。

## 架構原則與待定案的具體問題

沿用已決定的最小核心：不可變資料共享 owner，新增寫入進 delta，generation pins
控制回收，Mojo origin-tracked Span 控制借用，公開官方 std／MAX API 優先。
不預先增加通用 storage backend／scheduler framework。

#46 必須解決：

1. 區分 manifest generation、accepted sequence 與 in-memory view identity：兩個
   snapshot 可有相同 manifest generation 卻不同 sequence。CPU／GPU／PQ cache key
   不能只用 manifest generation，也不能讓 flush 前的新寫入使用舊快取。
2. authoritative base／delta 的 ownership 與資料布局。先在現有 dense F32、payload、
   sparse 路徑落地，保留 field kind/scalar/dimension 的明確邊界；不能靠 `ArcPointer`
   包住可變 MemTable 就宣稱 snapshot isolation，也不能每次寫入 clone 全庫。
3. 凍結、sequence visibility、replace/delete masking、metadata/sparse 一致性；
   已有 snapshot 的值和 owned `get` 合約保持不變。
4. short publish 必須驗證輸入 generation 並處理新寫入；若失敗，舊代持續可用。
   不能僅把 `BlockingScopedLock` 移出就產生 manifest lost update。備份必須複製被
   pin 的那一份 manifest／檔案清單，不能解鎖後再讀最新 manifest。
5. close/drain/release 與 Arrow/GPU ownership。lease 必須持有真實 owner，裸指標
   或 release 次數模型不構成存活保證；最後使用者離開後才關閉 mapping／回收。
6. 新向量欄位及 dense/sparse 原子更新的 durable 合約。需要格式改動就明確版本化、
   遷移與相容測試，不在 List→Span 的小替換中偷渡。

參考已查閱的 Qdrant `lib/shard/src/optimize.rs` 的 COW/proxy、鎖外建置與短發布；
RocksDB `db/snapshot_impl.h` 的 sequence visibility，以及既有
[Phase 11 合約](../docs/plans/2026-08-26-snapshots-concurrency-batch-design.md)。
把狀態轉移套入 Akasha，不複製整套上游型別／鎖抽象。

## 後續能力的拆分規則

以下是尚待 #46 選定表示法的能力順序，不能當成可一次實作的大工作包。
在寫程式前，把每個能力拆成約 2–5 個檔案的垂直切片，放進 todo.md，附上測試。

| 能力 | 最小端到端成果 | 驗收重點 |
|---|---|---|
| Shared snapshot | F32 exact/get 在後續寫入後仍讀到舊值，再延伸 metadata/sparse/hybrid | snapshot 不複製 immutable base，替換刪除不洩漏到舊 view；中間切片明列仍 owned 的欄位 |
| Background compaction | pin committed inputs、鎖外 build、generation conflict 檢查、短發布 | 寫入持續進行、無 lost update、取消／失敗、crash 邊界 |
| Backup lifetime | 固定 manifest lease、有界 buffer copy、manifest-last | 來源持續 flush/compact、備份獨立可重開、峰值記憶體有界 |
| Index lifecycle | 先把 SQ8/PQ 提升成 config/view 綁定的可重用物件，再接 rebuild jobs | query 不重複 training、新舊 view 不混用、old index 到成功發布前可用 |
| Direct result export | 直接寫最終 ID/score buffers，由 Arrow consumer 持有結果 owner | 不經 Python row objects；結果可獨立存活，release exactly once |
| Borrowed scanner | Arrow view 共享 immutable data columns 與 generation lease | slice/null/offset、close／compaction 後仍有效、最後 lease 才回收 |
| 向量 fields | 每種 representation 各有 write/read/search/reopen 切片 | schema mismatch、mixed field、partial update/delete、format migration、metric oracle |

直接結果匯出若持有獨立 result owner，可以在 shared generation 前做；只有引用
generation data 的 view 需要 generation lease。這項區分避免把所有 Arrow 工作
強迫排到生命週期末端。

## 官方 API 查核的剩餘工作

#39–#45 完成後，更新 inventory 的處置／證據，不重新宣稱 1,567 個舊宣告全數已審。
先處理 A03 metadata sorts、A04 heaps、Z06 WAL borrowed decoder、A09/A10 filesystem
helpers，再按熱路徑成本查剩餘模組。每項記錄：採用 API／版本／等價語意／測試，
或保留 domain wrapper 的具體原因。動態 Bitmap、CRC durable bytes、fd-based fstat、
long-lived worker 仍保留原盤點辨識出的語意差異。

## 效能與驗證

目前高維低 recall 在 F32 controls 也出現，不能全歸因 BF16/F16；單一 higher-ef cell
改善到約 0.98–0.995，但增加延遲。下一個對照實驗先固定資料／seed／filter／K，
掃 ef／建圖設定並報 candidate recall、final recall、fallback 與 latency；不盲目
更動預設值，不靠 exact fallback 通過 ANN-only 品質比較。

Qdrant 先固定版本與 service 邊界，再量 recall 0.95／0.99 曲線作診斷，正式門檻依
目標 workload 定案。公開真實 embeddings 與合成 stress cells 分開；尚未定義代表性
production workload 或容許差距，不影響 #39–#46，但完成前不能宣稱全面 parity。

每個工作包先跑 narrow tests，新的 persistence 行為加 crash／compatibility。
每 2–3 個相關修改設 checkpoint；整合後才跑完整 CPU/Python、crash、C ABI、build
與 quality gates。GPU owner/query path 有變才加實機 GPU，沿用未變動的成功證據。
本輪只改 Markdown，驗證文件連結、序號／相依與來源位置。

## 協調與風險

| 風險 | 處理 |
|---|---|
| collection.mojo 同時被多項修改 | #39／#41 與 lifecycle 按 commit 邊界串行；不重啟已完成 #31–#38 |
| 把 owned copy 改借用破壞壽命 | #41 只換等價 List.copy；#45 同步 borrow 保留 producer；長壽命另用 owner |
| 基礎設計過大、等待所有型別 | #46 先鎖定 ownership 合約，現有 F32 路徑先完成；新型別逐片進入 |
| 將研究建議誤當實作已完成 | checklist 全部預設未完成；完成需 commit／測試／量測證據 |
| 檔案格式與一致性改動混在優化 | 前兩批維持 bytes；新格式只在獨立 migration 切片交付 |
