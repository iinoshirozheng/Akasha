# 下一輪工作包 checklist

依據：[plan.md](plan.md)。基線 `a8895c6`，engine `9b98dbc`。
使用者已授權實作 #39–#42；其餘維持規劃。狀態須附實際驗證證據。
路徑皆相對 repository root。每個工作包獨立提交，不把不同語意改動混成一筆。

## #39：移除 incremental flush 被丟棄的全量複製

**描述：** 在選定 base／delta 後才 materialize records；incremental flush 不先
clone 所有 live records。

**驗收：**
- [x] base checkpoint、incremental upsert/delete、無新寫入的既有行為與 durable bytes 保持一致。
- [x] 大 base 加少量 delta 時，不呼叫被丟棄的 full materialization；記錄前後 copied bytes／peak memory 與 flush 時間。
- [x] reopen、tombstone、checkpoint crash ordering 的既有測試通過。

**驗證：** `pixi run mojo run -I src tests/mojo/test_persistent_collection.mojo`、
`pixi run mojo run -I src tests/mojo/test_compaction.mojo`、
`pixi run mojo run -I src tests/crash/test_checkpoint_order.mojo`；
用固定 base/delta workload 做診斷量測，不用時間 assertion 判定正確性。

**相依：** 無。**規模：** M。
**預計檔案：** `src/akasha/api/collection.mojo`、
`tests/mojo/test_persistent_collection.mojo`、`benchmarks/mojo/compaction_bench.mojo`。

**完成證據：** [#39 量測與驗證](../docs/benchmarks/2026-09-07-official-primitives.md)。

## #40：Bitmap 使用官方 bit primitives

**描述：** `_popcount` 使用 `std.bit.pop_count`；set-bit enumeration 使用
`count_trailing_zeros`。保留 runtime-sized Bitmap。

**驗收：**
- [x] 0／all-bits／63、64 邊界／尾端 padding 與 ascending ordinals 相同。
- [x] cached cardinality、resize、intersection/union/difference 不變。
- [x] 官方 primitive 於專案 Mojo 版本編譯；移除不再使用的手寫迴圈。

**驗證：** `pixi run mojo run -I src tests/mojo/test_bitmap.mojo`、
`pixi run mojo run -I src tests/mojo/test_hnsw_filtered.mojo`。

**相依：** 無。**規模：** S。
**預計檔案：** `src/akasha/index/bitmap.mojo`、`tests/mojo/test_bitmap.mojo`。

## Checkpoint A：#39／#40

- [x] narrow tests 與 #39 量測留存；更動只包含對應行為，已通過的測試不無故重跑。
- [x] durable format／public API diff 為空；每個 package 有獨立 commit。

## #41：Owned vector copy 使用官方 List.copy

**描述：** 替換 collection／MemTable `_clone_vector` 與 DocumentRecord 的同語意
向量複製。此包保留 owned API，不把 get 變成 borrowed view。

**驗收：**
- [x] 改用官方 owned copy，移除過時 helper；不引入新的通用 clone 抽象。
- [x] 改變 caller input／returned vector 不影響 collection；snapshot isolation 不變。
- [x] payload clone、空值、sequence 與 ID 行為保持，未改動資料格式。

**驗證：** `pixi run mojo run -I src tests/mojo/test_memtable.mojo`、
`pixi run mojo run -I src tests/mojo/test_persistent_documents.mojo`、
`pixi run mojo run -I src tests/mojo/test_snapshot.mojo`。

**相依：** #39（共用 collection.mojo，依提交順序整合）。**規模：** M。
**預計檔案：** `src/akasha/api/collection.mojo`、`src/akasha/storage/memtable.mojo`、
`src/akasha/document/record.mojo`、`tests/mojo/test_memtable.mojo`、
`tests/mojo/test_persistent_documents.mojo`。

## #42：BinaryWriter bulk append 使用官方 List.extend

**描述：** `write_bytes` 改用官方 bulk append；沿用 #37 的 CRC table 與既有 binary codec。

**驗收：**
- [x] empty／連續多段／大 buffer append 後 bytes 與現有 codec fixtures 完全相同。
- [x] `take_bytes` 後 writer 可重用，來源 buffer 壽命／修改不影響已寫 bytes。
- [x] CRC polynomial、byte order、bounds／corruption checks 不變。

**驗證：** `pixi run mojo run -I src tests/mojo/test_storage_checksum.mojo`、
`pixi run mojo run -I src tests/mojo/test_crc32_table.mojo`、
`pixi run mojo run -I src tests/mojo/test_wal_v1_compat.mojo`、
`pixi run mojo run -I src tests/mojo/test_segment_v1_compat.mojo`。

**相依：** 無。**規模：** S。
**預計檔案：** `src/akasha/storage/checksum.mojo`、`tests/mojo/test_storage_checksum.mojo`。

## Checkpoint B：#41／#42

- [x] owned-result regressions 與 format fixtures 通過，沒有 silent borrow 或 CRC 格式改變。
- [x] 第一批完成後執行一次 `pixi run build`，更新 A01/A02/A05/A06/Z02 的查核狀態。

**整合完成：** engine `ae9524c`；645 Mojo、49 Python、9 crash tests、C ABI、build、
既有與 11-cell post-HNSW quality gates 全部通過。#39–#42 分別為 `dc0a9f5`、
`a4a8b86`、`209a34a`、`ae9524c`。A06 僅完成本批範圍內的 BinaryWriter，其他候選保留。
指令／量測／限制見 [驗證報告](../docs/benchmarks/2026-09-07-official-primitives.md)。

## #43：SparseIndex 使用官方 Dict lookup

**描述：** 移除 record／term／score 的重複線性搜尋，使用已存在的 std Dict。

**驗收：**
- [x] upsert、delete、delete/reinsert、slot 移動都更新 lookup；clone／reopen 結果一致。
- [x] sparse Dot 與 filtered/hybrid 結果、浮點累加順序與 ID ties 不變。
- [x] 多 point／term 與少量命中的固定 workload 記錄 lookup work／memory／latency，無 per-candidate 全表 ID scan。

**驗證：** `pixi run mojo run -I src tests/mojo/test_sparse_index.mojo`、
`pixi run mojo run -I src tests/mojo/test_persistent_sparse.mojo`、
`pixi run mojo run -I src tests/mojo/test_snapshot.mojo`。

**相依：** 無。**規模：** M。
**預計檔案：** `src/akasha/index/sparse.mojo`、`tests/mojo/test_sparse_index.mojo`、
`tests/mojo/test_persistent_sparse.mojo`；量測如需新增專用檔，限本工作負載。

**完成 commit：** `85a9b85`。

**完成證據：** SparseIndex／persistent sparse／snapshot 共 16 tests 通過；
[固定 workload 與記憶體報告](../docs/benchmarks/2026-09-07-lookup-arrow.md)。

## #44：RRF fusion 使用官方 Dict 累計

**描述：** `_accumulate` 以 ID lookup 替代遍歷已有 scores，沿用目前 RRF 公式與輸入順序。

**驗收：**
- [x] overlapping／disjoint lists、empty input、負 ID、ties 與 rank_constant 皆符合現有合約。
- [x] 浮點累加順序與 deterministic output 不被 Dict iteration order 改變。
- [x] 隨 fetch_k 增大的量測顯示移除 quadratic ID lookup，包含 Dict 記憶體成本。

**驗證：** `pixi run mojo run -I src tests/mojo/test_rank_fusion.mojo`、
`pixi run mojo run -I src tests/mojo/test_persistent_sparse.mojo`。

**相依：** 無；整合驗證可在 #43 後一次完成。**規模：** S。
**預計檔案：** `src/akasha/query/fusion.mojo`、`tests/mojo/test_rank_fusion.mojo`。

**#44 commit：** `ff00ddd`；RRF／persistent sparse 共 10 tests 通過。

## Checkpoint C：#43／#44

- [x] Sparse／hybrid／snapshot narrow tests 通過；記錄效能與 retained memory。
- [x] 沒有新增格式或自訂 hash table，查核 A07 逐項更新。

## #45：Arrow primitive ingress 改為 typed borrow

**描述：** 使用 PyArrow／NumPy 官方 view 與 Mojo `from_numpy_array`，把 ID、dense
F32 與 sparse primitive buffers 一次借用成 Span，消除元素級 Python boxing。
同步呼叫期間保留 producer owner；WAL/MemTable 仍依既有 owned 合約接收資料。

**驗收：**
- [x] 指標相同、sliced offset／dtype／contiguity／readonly／bounds／null 檢查有真實 buffer 測試；原 producer 可安全釋放。
- [x] compiled primitive loop 不再呼叫逐元素 Python 轉型；寫入／重開／dense+sparse 結果相同，不擴大 atomic batch 宣稱。
- [x] payload materialization 與 durable owned copy 單獨計量；不宣稱整條 ingest 零複製，不提供會懸空的 retained Span。

**驗證：** `pixi run build-python`、
`pixi run env PYTHONPATH=python:. pytest tests/python/test_arrow_c_data.py -q`、
`pixi run mojo run -I src tests/mojo/test_arrow_c_data.mojo`；固定 rows×dimension
量測 ingress time／allocations／copied bytes，延用本次官方 API 探針。

**相依：** 無；建議第一批 checkpoint 後交付。**規模：** M。
**預計檔案：** `python/akashadb/arrow.py`、`src/bindings/python_module.mojo`、
`tests/python/test_arrow_c_data.py`、`tests/mojo/test_arrow_c_data.mojo`。

**#45 commit：** `234547a`；20 Python Arrow + 3 Mojo Arrow tests 通過，
完整 CPU suite 在同一 engine 通過 650 Mojo／66 Python tests。

## #46：定案 generation／field ownership，拆出生命週期實作

**描述：** 用目前 F32/payload/sparse 與 GPU cache 為落地範圍，定案 immutable base、
delta、accepted sequence、leases／close／publish 的合約；為 named/type 擴充留下具體
field 邊界。交付設計、成本基線與下一批小型實作清單，不直接大改全庫。

**驗收：**
- [x] ADR 決定 snapshot 捕捉、delta visibility、metadata/sparse 一致性、cache identity、pin／publish／retire 與 close；列出實際選擇與淘汰原因。
- [x] 量測 0／少量 delta、相同 manifest 不同 sequence、多個存活 snapshot 的 capture time／copied bytes／RAM，並用最小 Mojo 探針確認選定 owner／borrow 語意能編譯。
- [x] 將 shared snapshot、background compaction、backup、index lifecycle、Arrow result/scanner 拆成約 2–5 檔的小包，更新 todo；每包有 dependency、失敗／crash 驗收，需格式改動者另列 migration。

**驗證：** 檢查所有 ADR invariants 對應現有或明列的新 regression；
`pixi run bench-phase11` 做可重現成本量測；新增的 owner 探針使用
`pixi run mojo run -I src <probe.mojo>` 在當時 locked toolchain 編譯。
量測 harness 若有變動，只跑對應檢查，不把設計交付當成引擎功能驗收。

**相依：** Checkpoint B 的最新來源；不依賴 #43–#45 完成。
**規模：** M（設計／量測，後續實作另拆）。
**預計檔案：** 新的 `docs/adr/` ownership ADR、`benchmarks/mojo/phase11_bench.mojo`、
新的 `docs/research/` 成本報告、`tasks/plan.md`、`tasks/todo.md`；獨立探針可放 `.build/`。

**完成證據：** [ADR 0007](../docs/adr/0007-generation-field-ownership.md)、
[成本／compiled probe](../docs/research/2026-09-07-generation-costs.md)，以及
[完整整合 gate](../docs/benchmarks/2026-09-07-lookup-arrow.md) 全部通過。

## Checkpoint D：下一批啟動條件

- [x] #45 借用邊界與 #46 ownership 合約互相一致，已完成項目各附 commit／驗證證據。
- [x] 只有定案且拆小的生命週期切片進入實作；保留完整 M2–M6 目標，不以 #46 文件完成代替功能。
- [x] 把同 recall 的 Qdrant 基線與高維品質曲線排入下一批，先量差距再決定 HNSW 調校。
- [x] 下一批同時列入 A03/A04 官方 sort/heap 適配，以及 Z06/A09 的 bounded decode／I/O；優先度依量測，避免延後 shared snapshot。

## #46 定案後的實作隊列（#47–#54 已完成；#55–#63 待實作）

合約：[ADR 0007](../docs/adr/0007-generation-field-ownership.md)。每項是可單獨驗證的
切片，檔案為預計主要修改範圍；開始前沿實際 caller 確認，超過約 2–5 檔就先按接口
拆分。不得以保留舊 runtime fallback 讓半套 visibility resolver 通過測試。

建議下一個引擎項目是 **#55**；#59 的同 recall 對照同批提早建立。#47 已完成相同 view
共享，#48／#49 已讓 capture 不複製 dense／payload／sparse bytes，#50 已讓每個 query 持有
獨立 root owner，#51 已讓 foreground compact 鎖外 build、條件 publish，
#52 已讓 background worker 走同一流程並 rebase 到較新的 manifest，
#53 已讓 backup 只在鎖內 capture＋pin，鎖外有界複製，
#54 已讓 SQ8 artifact 由 root 保管、每 root 只建一次並共享。
#60–#63 不阻擋這條主線。

### #47 共享相同 view 的 snapshot root

- [x] 將 snapshot owned data 與 handle/close 分離；同一 view revision 的 repeated capture
  共享不可變 root，原本 exact/get/filter/sparse/hybrid 語意全保留。第一次建 base 的成本
  明列，不能把此片宣稱為 bounded delta 已完成。根資料結構直接採 ADR base/delta 邊界。
- 相依：#46。主要檔：新 `src/akasha/storage/read_generation.mojo`、
  `src/akasha/api/snapshot.mojo`、`src/akasha/api/collection.mojo`、
  `tests/mojo/test_snapshot.mojo`、`tests/mojo/test_concurrency.mojo`。
- 驗收：0 delta 重複捕捉只增 owner；不同 sequence 不共用舊 root；舊 snapshot 經 replace/
  delete/reinsert/collection close 仍有效。close/RAII 不漏 pin，owned get 可自行修改。
  失敗 capture 不留下 pin；跑 snapshot/concurrency/batch tests 與成本 harness。無格式改動。
- 完成：`dc858ab`（2026-09-17）。官方 ArcPointer root/base owner、collection-local cache、
  manifest／background publication 失效與最後 owner 釋放 pin；GPU state 仍各 handle 獨立。
  0 delta／8 snapshots 只建 1 次 base，後續 authoritative copied bytes = 0；16 delta 仍每次
  全量重建。656 Mojo／66 Python／9 crash／10 實機 GPU、C ABI、build 與品質 gates 通過。
  [實作與成本報告](../docs/benchmarks/2026-09-17-shared-snapshot.md)。

### #48 有界 head 與共享 dense fields

- [x] 接受寫入時建立不可變 dense field owner，head 只改 latest-state descriptors；新 root
  複製有界 descriptors，base/sealed run 共享。rollover 移交 owner，atomic batch 一次發布。
  改 exact/get 的全點 visibility resolver，舊 row 在 Top-K 前被 shadow/tombstone 遮蔽。
- 相依：#47。主要檔：`read_generation.mojo`、`storage/memtable.mojo`、
  `api/collection.mojo`、`api/snapshot.mojo`、新 `tests/mojo/test_generation_delta.mojo`。
- 驗收：0/16/1,024 個 delta 的 base copied bytes 為 0；同 G 不同 S、批次邊界、
  sparse-only update 共用 dense bytes；rollover/超大單筆有測試。此片先交付可被 foreground
  呼叫的有界 in-memory consolidation，讓 sealed chain 不無限增長；#52 才把同一建置
  primitive 接入 worker/backpressure，明列此片仍可能有 consolidation writer stall。
  發布前失敗保留舊 root；重跑 batch torn-write crash。此片未改 durable schema。
- 完成：`8351235`（引擎與測試）、`09fe0ff`（成本 harness），2026-09-24。ArcPointer dense
  owner、1,024 點／4 MiB head、sealed runs、8 段後 foreground consolidation；各 layer 先遮蔽
  再 filter／Top-K，再以 BoundedTopK 合併。0/16/1,024 delta 以 owner identity 稽核 dense
  copied bytes = 0；16 delta × 8 snapshots 的 capture 中位數 dense-only 0.007 ms、dense+sparse
  0.691 ms（幾乎全為 sparse 全量 clone，屬 #49）。仍有 consolidation writer stall（4,096 點約
  2.0 ms，#52）；GPU flat table 仍各 handle 建立（#50）；`apply_batch` staging 仍 clone 全表
  descriptors／payload 並重建 metadata（writer 路徑，未列任務）。664 Mojo／66 Python／9 crash／
  10 實機 GPU、C ABI、build 與品質 gates 通過。
  [實作與成本報告](../docs/benchmarks/2026-09-24-bounded-head.md)。

### #49 Payload／sparse 與完整 point state 一致

- [x] Payload/sparse 各自 field owner；partial field 更新沿用其他 owner，delete 清除整點，
  reinsert 不繼承舊 sparse。Immutable-run metadata/sparse index 與小 head 的直接求值
  共用同一 visibility resolver；避免每次 snapshot 重建全量 metadata/sparse。
- 相依：#48。主要檔：`read_generation.mojo`、`api/snapshot.mojo`、`api/collection.mojo`、
  新 `tests/mojo/test_generation_fields.mojo`、`tests/mojo/test_persistent_sparse.mojo`。
- 驗收：payload-only/sparse-only/full replacement、filters/NOT/hybrid、負 ID 與 Float32
  accumulation/ties 對照 owned oracle；更新後多 root 共存、flush/reopen 一致。失敗 sparse
  不發布新 root；沿用 dense/sparse 各自 WAL 合約與 sparse checkpoint crash gate。
- 完成（2026-09-25）：entry 持 dense／payload／sparse 三個共享 owner；base／sealed run
  各建 metadata＋sparse index，frozen head 直接求值，`filtered_ordinals`／
  `conditioned_ordinals`／`sparse_hits` 為唯一欄位 resolver。publisher 以 accepted sequence
  記錄每個操作（含 sparse-only），不再持有全域 SparseIndex。順帶修正 delete→reinsert 後
  reopen 復活舊 sparse（WAL tail 與 sparse checkpoint 兩路）：recovery 依 sequence 併入
  dense WAL delete，runtime 補 sparse pending delete；WAL 格式不變。16 delta × 8 snapshots
  dense+sparse capture 0.691 → 0.003 ms、held RSS 11.5 → 3.4 MiB，capture 0 payload／sparse
  copy。代價：rollover／consolidation 多建 sparse index（#52）；writer 仍另持一份
  SparseIndex 供 sparse checkpoint；無公開 payload-only 寫入（owner 獨立性在 publisher 層測）。
  668 Mojo／66 Python／9 crash／10 實機 GPU、C ABI、build 通過。
  [實作與成本報告](../docs/benchmarks/2026-09-25-field-owners.md)。

### #50 Operation lease、close 與 GPU cache owner

- [x] Query 取得獨立 operation owner，close 停止新操作、鎖外 drain，drop 該 handle owner；
  既有 snapshot 不失效。GPU cache 綁 root/layout/field/config/device，保留既有 budget／scratch。
- 相依：#49。主要檔：`api/collection.mojo`、`api/snapshot.mojo`、`compute/gpu/context.mojo`、
  新 `tests/mojo/test_generation_close.mojo`、相關 `tests/gpu/` lifecycle test。
- 驗收：已取得 operation 與 close 交錯、重複 close、worker error、最後 owner/pin 釋放，
  相同 G/不同 S cache freshness。GPU ownership 有改動才執行對應實機 gate；不可用 CPU
  fallback 作實機證據。無新格式，不以 Span origin 代替 operation owner。
- 完成（2026-09-25）：snapshot 每個 query 在 handle 鎖內複製 root owner、鎖外只經該 owner
  讀；root slot 與鎖放在 heap（inline 版本在 close 競爭下讀到已釋放 run）。close 冪等，
  鎖內取出、鎖外 drop；collection close 同樣把 cached root 移到 writer 鎖外釋放。collection
  無鎖 query（exact／filtered／where／sparse／hybrid／device）改為驗證後走 snapshot
  operation，不再無鎖讀 writer live 表。GPU state 改掛 `ReadGeneration.device`（每 root
  一份，同 root handle 共用，同 G 新 S 必為新 state），移除 collection `_GpuReadSnapshot`。
  代價：collection query 每次 capture 原本約 15 µs，其中 14.2 µs 是讀 manifest 取
  generation；後續改由 `ReadGenerationCache.generation` 在每個 manifest publish（flush、
  HNSW 升降級、compact、背景 maintenance）與 open 時記錄，capture 降到 0.22 µs，
  collection query 與 snapshot query 同價（layered where 約 318 µs、sparse 約 9 µs，
  即 #49 resolver 成本）；寫後查 +13% → 約 +10%。
  snapshot query 成本不變。673 Mojo／66 Python／9 crash／12 實機 GPU、C ABI、build 通過。
  [實作與成本報告](../docs/benchmarks/2026-09-25-operation-owners.md)。

### #51 Compaction 分離鎖外 build 與 conditional publish

- [x] Foreground `compact()` 先 pin 精確 committed inputs，鎖外建置，短鎖核對 G/config
  後 publish；保留所有 sequence > H 的目前 head/sealed/WAL。衝突丟棄新輸出並有界重試。
- 相依：#50。主要檔：`storage/committed_compaction.mojo`、`api/collection.mojo`、
  `storage/retired_files.mojo`、新 `tests/mojo/test_compaction_publish.mojo`、
  `tests/crash/test_checkpoint_order.mojo`。
- 驗收：build 期間 writer 持續接受資料；concurrent flush 造成 conflict 時不覆蓋新 manifest；
  old snapshots/pinned files 可讀。輸出 fsync、manifest publish、root swap、cleanup 各 crash
  邊界可重開；checksum/cancel/IO failure 舊代不受損，無遺失 WAL tail。無格式變更。
- 完成（2026-09-26）：begin 在鎖內 checkpoint WAL tail、取 manifest 與其精確 bytes、pin G；
  build 在鎖外合併成 `segment-compact-<G+1>-<n>.bin`／`sparse-compact-…`（`O_EXCL` 建立、
  fsync、sync 目錄）；finish 在鎖內放 pin，bytes 未變才 publish G+1（durable manifest →
  read root → index caches → inputs 交 lease-aware retirement），否則丟輸出、重抓，4 次後
  raise。open 清掉目標代數大於 committed 的輸出。背景 worker 共用這三個函式但仍整段持鎖（#52）。
  壓測（每 1 ms 一筆 upsert，20 輪 flush＋compact，三個 process 中位數）：與 compact 重疊的
  upsert p50／p95／p99 由 133／139／148 ms 降為 0.49／0.69／67 ms，每輪可寫筆數 1 → 約 87；
  殘留 p99 來自鎖內兩段約 32 ms 的 HNSW snapshot／index cache 寫入（#54／#56 範圍）。
  conflict rate：每 50／200／1000 ms flush 一次為 100%／49%／9%；50 ms（短於一次約 150 ms 的
  build）時 20 次 compact 全數用完 retry budget，#52 移出鎖後須接受 capture 之後附加的 delta
  或對 flush 加 backpressure。684 Mojo／66 Python／14 crash、C ABI、build 通過；GPU 路徑未變，
  未跑。[實作與量測報告](../docs/benchmarks/2026-09-26-compaction-publish.md)。

### #52 Background worker 接用相同 publication 流程

- [x] `_maintenance_entry` 接用 #51，不在整個 merge 期間持 writer lock；原單 worker、
  bounded pending work、error reporting、close/join 保持。接入 sealed delta merge/backpressure。
- 相依：#51。主要檔：`storage/maintenance.mojo`、`read_generation.mojo`、
  `tests/mojo/test_maintenance.mojo`、`tests/mojo/test_concurrency.mojo`。
- 驗收：連續寫入/flush/取消/close 壓力、衝突 retry budget、第一個錯誤回報、無死鎖或
  unbounded delta；沿用 #51 crash cases，量 writer p95/p99 stall。沒有新 worker framework。
- 完成（2026-09-26）：finish 在鎖內重讀目前 manifest，採 RocksDB version edit 式 rebase：
  captured inputs 仍是 leading run（名稱、checksum、sequence 範圍、sparse 檔一致）時，新
  manifest 為 `[output] + capture 後附加的 segments`，代數為目前 + 1，last sequence 與 HNSW
  reference 取自目前 manifest；只有 inputs 已被取代才算 conflict。inputs 在 publish 前的
  目前代數退休，tombstone elision 不變。worker 以相同三個函式與 4 次 budget 在鎖外 build；
  budget 用完只計數（`background_compaction_counts()`），不算 failure；close 後才完成的
  job 丟棄輸出。sealed run 到第 8 個時請 worker merge：鎖內 capture、鎖外 merge 與 sparse
  build、短鎖只替換 captured prefix；reset 前 capture 的 merge 丟棄；未載入 worker 時照
  #48 inline merge。16 個 sealed run 時 write 不 admit，請求 merge、放鎖睡 1 ms 重試，close
  或 maintenance failure 結束等待；merge 錯誤走 maintenance failure，已 ack 寫入留在 WAL。
  另修 drop 未 close 的 collection 時 `__deinit__` 在 join 前釋放 worker 共用狀態的舊 bug。
  另加 L0 stall：flush 看到 8 個 L0 segment（`LEVEL_ZERO_SEGMENT_LIMIT`，flush policy 觸發點
  4 的兩倍）時不寫，請 worker compact、放鎖睡 1 ms 重試（RocksDB level-zero stop），close 或
  maintenance failure 結束等待；少了它，unfair spin lock 下 upsert／flush 緊迴圈會讓 job 一直
  publish 不了，segments 無上限，bounded-segments 測試間歇失敗。
  壓測（2026-09-27 一批、全程電池無睡眠；每 1 ms 一筆 upsert，三個 process 中位數）：worker
  compaction 期間可寫筆數每輪 1 → 約 83；扣除排在 `flush()` 後的 upsert，job-only p50／p99
  0.48／1.06 ms（之前那筆等完整個 job，約 120 ms）；整體 p99 34 ms 是約 35 ms 的 `flush()`
  鎖（worker 鎖內 begin／finish 中位數 0.04／0.56 ms）。sealed merge 那筆 upsert p50 5.1 →
  1.2 ms，backpressure 未觸發。job-only 最大值（本批最多 106 ms、前一批 282 ms）是 upsert
  在鎖內 WAL append＋fsync 的 I/O stall，不是 worker 持鎖：探針量到最長 184 ms 的 upsert 有
  183.4 ms 在 fsync，當時沒有 job 或 flush；baseline 的 quiet upsert 也到 114 ms。
  conflict：flush 不再造成 conflict，200／1000 ms 的 foreground conflict 19／2 → 0；50 ms 無
  負載時 20 個 call 都第一次就 publish（之前 18／20 用完 budget）。但旁邊跑 12 個 busy loop
  時仍有 4–11／20 call 用完 budget（之前 17–20），worker 從未用完：前後台仍互搶同一批
  inputs，AkashaDB 沒有 RocksDB `being_compacted`／`exclusive_manual_compaction` 那樣的互斥，
  列為限制。segments 最多 9（L0 stall 上限）。無負載的結果也受 bench 自己在 flush 後讀
  manifest 時是否持鎖影響：同一 1be5483 engine 的 foreground conflict 鎖外 3–23、鎖內 0；
  355e1d5 用完 budget 的 call 鎖外 0–5、鎖內 18–20。前一批 baseline 只 2／20 用完，用的就是
  鎖外讀的 bench。#51 的 bench 在 355e1d5 上仍 20／20，與 #51 報告一致。
  前一批非正式壓測的兩個失敗：`conflict bench task failed` 已重現，是 1be5483 bench 在鎖外
  讀 manifest，被 worker publish 回收的 segment 造成 missing segment；engine 只在 open 或鎖內
  讀 manifest，bench 已改鎖內讀，32 個 case 無錯。hang 未重現：1be5483 與目前 tree 各 5 個
  process（無負載、busy loop、併行 `mojo build`）跑完 worker＋6 輪 sealed 共 70 段，原因未定。
  foreground `compact()` 的兩段約 32 ms 鎖不變（#54／#56）。703 Mojo／66 Python／15 crash、
  C ABI、build 通過；GPU 路徑未變，未跑。
  [實作與量測報告](../docs/benchmarks/2026-09-26-background-publication.md)。

### #53 Captured manifest backup 與 bounded copy

- [x] 備份捕捉 manifest/config/檔案集合並持 lease；解鎖後只複製該集合。官方 FileHandle
  分塊讀寫，預設 1 MiB buffer；保留 target lock、temp/fsync/rename、manifest-last。
- 相依：#50（可在 #51 前做）。主要檔：`storage/operations.mojo`、`api/collection.mojo`、
  `storage/filesystem.mojo`、`tests/mojo/test_storage_operations.mojo`、新 backup crash test。
- 驗收：來源持續 flush/compact 時備份仍是單一 captured view，關閉/移除來源後獨立重開；
  大檔峰值記憶體不隨檔案大小線性增長。corrupt source、partial copy、manifest 前 crash、
  active/WAL target 拒絕；不默默新增 hardlink。Z07/A09 的 backup I/O 在此結案。
- 結果（2026-09-27）：`backup_to` 分三步：鎖內 flush、capture manifest／config／live
  count 並 pin 該 generation；鎖外 `copy_checkpoint` 複製；結束時 unpin，下一次 reclaim
  才回收。每個 dense／sparse 檔經 `FileHandle.read(Span)`／`write_all` 串流進
  `<name>.tmp`，同時比對 magic、body CRC-32、尾端 checksum 與 descriptor，拒絕長度變化，
  fsync 後 rename；一次 directory fsync 後才 publish manifest。報告取自 capture 的狀態，
  複製後不再 decode。buffer 1–7 byte 與 4096 都逐位元相同；128 MiB 檔的峰值 RSS 增加
  16 KiB，負控制（buffer＝檔案大小）增加 130 MiB 而失敗。新測試：來源在複製中
  flush＋compact 且 sidecar 已刪、lease 釋放後回收、刪除來源後 restore 再開；corrupt／
  magic 錯／截斷的 dense 與 sparse 檔；committed／WAL-only／開啟中的 target；crash 在
  manifest 前（torn tmp）與 manifest rename 前，retry 覆寫殘留。未新增 hardlink。
  新增串流 `crc32_update`，`crc32_range` 改用它（同一查表）。
  限制：(1) backup manifest 省略 HNSW sidecar（v2，同 generation／last sequence），開啟時
  重建 graph。checkpoint 直接刪改 `hnsw-<sequence>.bin`，不受 pin 保護，格式又固定其名稱；
  要複製它需讓 sidecar 經 pin 退役，屬 #56 範圍但尚未列入其驗收。(2) restore 仍嚴格
  decode 整個備份（來源不受信任），記憶體仍是 O(segment)，只有複製是有界的。
  (3) 失敗的複製在 target 留下已複製檔與 `.tmp`，沒有 manifest 故不是備份；retry 覆寫。
  707 Mojo／66 Python／17 crash、C ABI、build 通過；GPU 路徑未變，未跑。

### #54 SQ8 ready artifact 重用

- [x] SQ8 由 root/field/metric/config-bound owner 保管，query reuse ready artifact；
  建置中的狀態不冒充 ready，不因另一 handle close 被清除。
- 相依：#49。主要檔：`api/snapshot.mojo`、新 `index/artifact_state.mojo`、
  `index/quantization.mojo`、`tests/mojo/test_quantized_search.mojo`。
- 驗收：同 root repeated query build_count=1，更新/布局改變 freshness、metric/rescore 結果
  與舊 oracle 相同；失敗保留既有可用 artifact。純記憶體 derived cache，無 migration。
- 結果（2026-09-27）：新增 `index/artifact_state.mojo` 的 `ArtifactState[T]`：
  `absent/building/ready/failed` 狀態、lock、ready `ArcPointer`、build／failure 計數與
  測試用 delay／fail hook。`ReadGeneration.sq8` 每 root 持有一個 `ArtifactState[Sq8Index]`，
  與 #50 的 `device` 同一 pattern。`_search_sq8` 不再每次 query 重建：`_sq8_artifact`
  在 root 的 artifact lock 內檢查 ready，否則 `begin` → gather → `Sq8Index.build` →
  `publish`；鎖從檢查持到 publish，併發首查只建一次並共享同一 `ArcPointer`。失敗只記錄
  訊息、不 publish、raise，下一次 query 重試；`publish` 不取代既有 ready artifact。
  root 即 key：layout／field／config／coverage 在 root 生命期固定，任何寫入或 flush 產生
  新 root 與新 state，freshness 不需另外判斷；handle close 只釋放該 handle 的 root owner，
  artifact 隨 root 的最後一個 owner 釋放。三種 metric、有無 rerank 的結果與舊的
  query-time `Sq8Index.build` oracle 逐位元相同。`index/quantization.mojo` 未改。
  新測試：同 root 三輪六種查詢 build_count=1、sibling handle 共享同一 state；upsert 後
  新 root 由 absent 重建且舊 root 不變、flush 後新 generation 結果與前一 root 相同；
  fail hook 讓建置失敗 → failed／無 ready／build_count 0，舊 root 仍服務，清掉 hook 後
  重建成功；first handle 與 collection close 後 second 仍以同一 artifact 查詢；
  8 workers × 4 次併發首查 build_count=1、failure_count=0；純 `ArtifactState` 生命週期。
  限制：(1) 一個 artifact 服務三種 metric——SQ8 codec 與 metric、訓練參數無關，故 key
  不含 metric。(2) artifact 記憶體隨每個存活 root 存在（約 n·d＋8n bytes），無預算或
  淘汰。(3) 建置期間持鎖，其他 query 等待而非觀察到 building。(4) `Sq8Index.build`
  既有的 O(n²) 重複 ID 檢查未動。
  713 Mojo／66 Python／17 crash、build 通過；`test_compaction_publish.mojo` 的
  `test_racing_flushes_rebase_without_conflicts` 在完整跑時 retry budget 耗盡一次，
  同一測試在不含 #54 的乾淨 HEAD worktree 也失敗、重跑通過，是 #52 benchmark 已註明
  的 timing 依賴（CPU 負載下不成立），與本項無關。GPU 路徑未變，未跑。

### #55 PQ training 與 query 分離

- [ ] PQ 沿用 artifact owner，cache key 包含 subspaces/centroids/training iterations/seed
  等實際參數及 root coverage；不要只用 k 或 manifest G。
- 相依：#54。主要檔：`api/snapshot.mojo`、`index/artifact_state.mojo`、
  `index/quantization.mojo`、`tests/mojo/test_product_quantization.mojo`。
- 驗收：cold build/warm query 分開量測、不同參數不誤中、失敗/取消不發布半成品、
  query 不反覆 training；matched-recall/rescore 測試保留。持久化 PQ artifact 若要加，另立版本切片。

### #56 HNSW rebuild 鎖外建置與 bounded catch-up

- [ ] 建立 pinned root 的 graph，publication 時核對 field/config 並用既有增量更新追上
  accepted mutations；無法有界追上就重排，不發布漏掉更新的 graph。
- 相依：#50/#51。主要檔：`api/collection.mojo`、`index/segmented_hnsw.mojo`、
  新 `tests/mojo/test_hnsw_publish.mojo`、`tests/mojo/test_hnsw_rebuild.mojo`、
  `tests/crash/test_hnsw_checkpoint_order.mojo`。
- 驗收：replace/delete/reinsert/flush 與 rebuild 交錯、不同 config 拒絕 stale artifact、
  crash 後 authoritative/derived checkpoint 一致；既有品質 gate 加 #59 同 recall 對照。

### #57 Arrow 直接 result columns

- [ ] Native search results 直接寫入官方 NumPy typed output buffers，再交 PyArrow；
  移除逐 result Python object staging。輸出是自有 owner，跨 collection close 存活。
- 相依：#45，**不等待 shared snapshot**。主要檔：`src/bindings/python_module.mojo`、
  `python/akashadb/arrow.py`、`tests/python/test_arrow_c_data.py`、`benchmarks/arrow_ingress.py`。
- 驗收：ID/I64、score/F32、empty/ties/sliced output、來源關閉後有效；記錄 result
  columnization copy 次數與 pointer/release。沒有持久化改動，不宣稱 AoS→SoA 必然 0 copy。

### #58 Leased scanner／Arrow C Data export

- [ ] Scanner 固定 root，逐 run/chunk 產生 batch；可連續借用的欄位由真實 C Data
  owner/release state 保活，不連續的 filter/gather/cast 產生獨立 owned buffers。
- 相依：#49/#50/#57。主要檔：新 `src/bindings/arrow_export.mojo`、`api/snapshot.mojo`、
  `python/akashadb/arrow.py`、`tests/python/test_arrow_c_data.py`、新 scanner Mojo test。
- 驗收：多 batch、slice、projection、早停/取消、producer/scanner/snapshot/collection 任意
  合法關閉次序、最後 release 回收、空資料；同時驗 pointer/已複製 bytes/峰值 RAM。
  先做 pinned Mojo 1.0 C callback/owner prototype，不以現有 descriptor release counter 當實作。

### #59 Qdrant 同 recall 基線與高維品質曲線

- [ ] 先跑既有 128 維與高維資料，分開 uniform synthetic 與至少一組真實 embeddings；
  固定 engine/Qdrant commits、硬體、資料/seed、metric、filter、k、threads、service 邊界。
- 相依：#46，可先於 #47 啟動。主要檔：新 `benchmarks/qdrant_compare.py`、
  `benchmarks/post_hnsw.py`、新的 `docs/benchmarks/` 報告與 results。
- 驗收：ef sweep 直到雙方落在相同 Recall@k 門檻；報 QPS/p50/p95/p99、build/update/
  memory/cold-warm，不拿 embedded kernel 對 HTTP。至少解釋既有 ef=128 最低 0.684375
  recall 的曲線；未達 recall cell 標失敗/不比較速度，失敗可重跑且資料 checksum 固定。

### #60 A03 官方 sort 適配

- [ ] Keyword/SortedBlock 排序使用官方 sort 的 comparator，保留 field/value/ordinal ties。
- 相依：#46；主要檔：`index/keyword.mojo`、`index/sorted_block.mojo`、對應兩個 tests、
  `benchmarks/mojo/metadata_bench.mojo`。以語意/byte-equivalence/scaling gate 決定替換，
  不合適就記錄原因，不新增自訂 sorting framework。無格式/例外行為改動。

### #61 A04 官方 heap 適配

- [ ] 分別評估 Top-K 與 HNSW min/max heap 的可直接 API，保留 reserve/clear/reuse、
  comparator 和 ID ties；先一種 heap 通過再擴充。
- 相依：#46；主要檔：`compute/topk.mojo` 或 `index/hnsw_heap.mojo`（一項一提交）、
  對應 test、benchmark/report 共約 3–4 檔。empty/full/reuse/ties/極端 scores 與 allocation/
  latency 無回歸才移除舊實作，否則留下官方不適配的證據。無 durable migration。

### #62 Z06/A09 有界 borrowed WAL decoder

- [ ] BinaryReader 借用有 owner 的 bytes/span，逐 bounded record decode；只在接受
  authoritative state 時取得 owned values，避免整份 WAL/range 的重複拷貝。
- 相依：#45 的 borrow 經驗，獨立於 #47。主要檔：`storage/checksum.mojo`、
  `storage/wal.mojo`、`tests/mojo/test_wal.mojo`、`tests/mojo/test_wal_v1_compat.mojo`、
  `tests/crash/test_wal_tail.mojo`。v1/v2/v3 bytes/CRC/overflow/bounds/torn final envelope
  與 repair-after-append 均驗證，benchmark 含大 WAL peak RAM；不能用省 checksum 換速度。

### #63 Read-only fingerprint／existence 去除 owned clone

- [ ] `authoritative_index_checksum` 改借用 entry 欄位；sparse upsert 的存在檢查使用
  ordinal/liveness，避免 `get` 複製 vector/payload。
- 相依：#46。主要檔：`api/collection.mojo`、`storage/index_cache.mojo`、
  flush/sparse 對應 tests、`benchmarks/mojo/flush_bench.mojo`（先確認 caller 再拆）。
- 驗收：fingerprint bytes、checkpoint/source freshness 不變，負 ID/刪除不存在點與
  failure sequence 不變；用 #39 的固定大 payload workload 量測。Crash gate 沿用仍適用結果。

### 向量型別後續 lane：先 migration，再逐型別

M4–M6 目標保留。下一個 schema 工作先交付 field catalog、named F32 與 combined mutation
的 durable 規格/fixtures（`formats/`、`docs/adr/` 約 2–3 檔），再拆 reader-first migration、
writer/API、search/reopen 三片。每片最多約 2–5 檔並列舊版本、unknown version、torn write、
rollback/forward recovery tests。Native F16/BF16/I8/U8、binary metrics、multivector/MaxSim
依同樣順序逐型別交付；不能用 #46 的 descriptor 設計就標成「支援各種類型」。
