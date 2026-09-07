# #31–#38 之後的執行規劃

規劃日期：2026-09-07。複核基線：`main` 的 `a8895c6`；engine 是 `9b98dbc`。
使用者已依序授權 #39–#42 與 #43–#46；目前 #43–#45 engine 已提交，
#46 ownership 設計／成本／後續切片已交付；進度與驗證以 todo.md 為準。
工作包 #39–#46 是延續既有交付序號的建議編號，不是已建立的 GitHub issues。
唯一執行 checklist：[todo.md](todo.md)。完整能力與 19 個參考課題仍在
[單機路線](../docs/plans/2026-09-07-single-node-lifecycle-zero-copy.md)。

## 完成狀態與剩餘缺口

#31–#38 可以結案，沒有從該範圍查到尚未完成的必做收尾。核對 Git commits、
另一個 task 的完成狀態，以及 [Actions 34099524657](https://github.com/iinoshirozheng/Akasha/actions/runs/34099524657)：
native macOS／Linux 各通過 638 Mojo tests、Python 49／48 tests、9 crash tests、
C ABI、build、examples 與 quality gates；Apple M4 Pro 的 9 GPU tests 依交付紀錄通過。
`9b98dbc` 後兩筆提交只新增／更新文件與研究產物；本輪不重跑未變動的 engine suite。

以下為規劃時缺口；#39–#45 的已完成部分見下方交付紀錄，生命週期功能仍待下一批：

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

#39–#42 已各自實作及提交，對應 `dc0a9f5`、`a4a8b86`、`209a34a`、`ae9524c`。
針對修改的驗證已通過；完整整合 gate 的結果集中於
[驗證報告](../docs/benchmarks/2026-09-07-official-primitives.md)。

| 批次 | 工作 | 交付邊界 |
|---|---|---|
| 第一批 | #39 flush、#40 bit、#41 vector copy、#42 byte append | 4 個小改動各自驗證與提交；持久化 bytes／公開合約不變 |
| 第二批（完成） | #43 `85a9b85`、#44 `ff00ddd`、#45 `234547a` | Dict slots 與 typed ingress 已驗證；650 Mojo／66 Python tests 通過 |
| 設計檢查點（完成） | #46 ADR 0007、cost harness、owner probe | 只完成設計／量測與 #47–#63 拆解，未實作 shared generation |
| 下一批能力 | 共享 snapshots → 背景 compaction／backup → index lifecycle → leased scanner/export | 依 #46 定案結果切片；每片包含 correctness／失敗路徑驗收 |
| 向量擴充 | named F32 → native scalar → binary → multivector/MaxSim | 每一型別都有 durable migration、write/read/search/reopen；不與核心 ownership 同批改 |
| 品質／速度對照 | Qdrant 基線與 recall–latency 曲線提前，整合後再跑最終矩陣 | 固定硬體、資料、recall、filter、並行與 service 邊界 |

#39–#45 並非 #46 的全部前置；ownership 設計可在第一批 checkpoint 後開始。
數字表示工作包識別，實際依賴以 checklist 為準。官方 heap/sort 的評估也不阻擋
生命週期設計，避免低影響清理延後最大的 snapshot／writer-lock 問題。

## #46 已定案的架構與下一批

完整合約是 [ADR 0007](../docs/adr/0007-generation-field-ownership.md)，
量測／compiler 限制見 [成本報告](../docs/research/2026-09-07-generation-costs.md)。
4,096×128 + payload/sparse 的每份 snapshot 仍複製至少 3.094 MiB content；
8 份約增 39 MiB RSS，16-point delta 沒有明顯減少 capture 成本。

採用 immutable base／sealed runs，加有界 mutable head descriptors；字段資料接受後
由獨立 immutable owner 保管。Capture 分享 base/field owners，只複製有界 head。
同 G 不同 accepted sequence、同 sequence 不同 layout 各有正確 root identity；
exact/filter/sparse/hybrid 共用全點 visibility resolver，shadow 在 Top-K 前處理。

官方 ArcPointer 負責生命週期，但其 pointee mutation 並非 thread-safe。Mojo 1.0
compile-only probe 也顯示 origin 標註不能單獨阻止 wrapper close 後沿用 Span。因此
同步 operation／Arrow export 各自持 strong owner；Span 不作可任意 retained 的裸介面。
Close 停新操作、鎖外 drain，再 drop 自己的 owner；已有 snapshot/export 獨立存活。

Compaction 採 pin inputs → 鎖外 build/fsync → 核對 G/config → 保留 accepted tail →
短發布 → lease-aware retirement。新 flush 造成 generation conflict 就丟棄新輸出並
有界重排，不能覆蓋新 manifest。Backup 持精確 captured manifest/files lease，分塊
copy 並 manifest-last。SQ8/PQ/HNSW artifacts 綁 root/field/config，避免 query 重建。

下一批以 todo 中獨立工作包執行：

| 順序 | 工作包 | 可驗收能力 |
|---|---|---|
| 引擎主線 1 | #47 → #48 → #49 | 同 view 共享 root → bounded dense delta → payload/sparse 一致性 |
| 引擎主線 2 | #50 → #51 → #52 | operation/close/GPU owner → compaction conditional publish → worker |
| 可提早並行的能力 | #53 backup、#54/#55 quantized artifacts、#56 HNSW rebuild | 依 todo 的實際 dependencies 啟動 |
| Arrow | #57 直接 result（只依賴 #45）；#58 leased scanner | owned result 可先做，引用 base 的 scanner 需 generation lease |
| 速度／品質 | #59 提前跑 | Qdrant 同 recall 與高維曲線，最後才驗收 parity |
| 官方 API 清理 | #60 sort、#61 heap、#62 WAL decode、#63 fingerprint/existence | 各自等價與量測 gate，不阻擋 snapshot 主線 |

#47 只是 repeated capture 共享，直到 #48/#49 才能驗收小 delta 無全庫 clone。
Named fields/native scalar/binary/multivector 仍依 M4–M6 逐型別；先有獨立 durable
migration 合約與 fixtures，再做 writer/API/search/reopen，不能把 graph codec 當權威 dtype。

## 官方 API 查核的剩餘工作

#39–#45 均已更新 audit 的處置／證據；A07 lookup 完成、A08/Z03 Arrow 部分完成，
其他 Python list API／direct export／durable copies 仍保留。不重新宣稱 1,567 個舊宣告全數已審。
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
本輪 #43–#45 的完整 CPU、crash、C ABI、build 與兩組品質 gate 均通過，量測見
[#43–#46 驗證報告](../docs/benchmarks/2026-09-07-lookup-arrow.md)。
#46 只改量測 harness／設計與 compiled probe，不把設計驗證當引擎功能驗收。

## 協調與風險

| 風險 | 處理 |
|---|---|
| collection.mojo 同時被多項修改 | #39／#41 與 lifecycle 按 commit 邊界串行；不重啟已完成 #31–#38 |
| 把 owned copy 改借用破壞壽命 | #41 只換等價 List.copy；#45 同步 borrow 保留 producer；長壽命另用 owner |
| 基礎設計過大、等待所有型別 | #46 先鎖定 ownership 合約，現有 F32 路徑先完成；新型別逐片進入 |
| 將研究建議誤當實作已完成 | checklist 全部預設未完成；完成需 commit／測試／量測證據 |
| 檔案格式與一致性改動混在優化 | 前兩批維持 bytes；新格式只在獨立 migration 切片交付 |
