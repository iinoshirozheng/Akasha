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

## #46 定案後的實作隊列（以下均未實作）

合約：[ADR 0007](../docs/adr/0007-generation-field-ownership.md)。每項是可單獨驗證的
切片，檔案為預計主要修改範圍；開始前沿實際 caller 確認，超過約 2–5 檔就先按接口
拆分。不得以保留舊 runtime fallback 讓半套 visibility resolver 通過測試。

建議下一個引擎項目是 **#47**；#59 的同 recall 對照同批提早建立。#47 的同 sequence
共享只是第一片，直到 #48/#49 才能驗收少量 delta 不複製全庫。#60–#63 不阻擋這條主線。

### #47 共享相同 view 的 snapshot root

- [ ] 將 snapshot owned data 與 handle/close 分離；同一 view revision 的 repeated capture
  共享不可變 root，原本 exact/get/filter/sparse/hybrid 語意全保留。第一次建 base 的成本
  明列，不能把此片宣稱為 bounded delta 已完成。根資料結構直接採 ADR base/delta 邊界。
- 相依：#46。主要檔：新 `src/akasha/storage/read_generation.mojo`、
  `src/akasha/api/snapshot.mojo`、`src/akasha/api/collection.mojo`、
  `tests/mojo/test_snapshot.mojo`、`tests/mojo/test_concurrency.mojo`。
- 驗收：0 delta 重複捕捉只增 owner；不同 sequence 不共用舊 root；舊 snapshot 經 replace/
  delete/reinsert/collection close 仍有效。close/RAII 不漏 pin，owned get 可自行修改。
  失敗 capture 不留下 pin；跑 snapshot/concurrency/batch tests 與成本 harness。無格式改動。

### #48 有界 head 與共享 dense fields

- [ ] 接受寫入時建立不可變 dense field owner，head 只改 latest-state descriptors；新 root
  複製有界 descriptors，base/sealed run 共享。rollover 移交 owner，atomic batch 一次發布。
  改 exact/get 的全點 visibility resolver，舊 row 在 Top-K 前被 shadow/tombstone 遮蔽。
- 相依：#47。主要檔：`read_generation.mojo`、`storage/memtable.mojo`、
  `api/collection.mojo`、`api/snapshot.mojo`、新 `tests/mojo/test_generation_delta.mojo`。
- 驗收：0/16/1,024 個 delta 的 base copied bytes 為 0；同 G 不同 S、批次邊界、
  sparse-only update 共用 dense bytes；rollover/超大單筆有測試。此片先交付可被 foreground
  呼叫的有界 in-memory consolidation，讓 sealed chain 不無限增長；#52 才把同一建置
  primitive 接入 worker/backpressure，明列此片仍可能有 consolidation writer stall。
  發布前失敗保留舊 root；重跑 batch torn-write crash。此片未改 durable schema。

### #49 Payload／sparse 與完整 point state 一致

- [ ] Payload/sparse 各自 field owner；partial field 更新沿用其他 owner，delete 清除整點，
  reinsert 不繼承舊 sparse。Immutable-run metadata/sparse index 與小 head 的直接求值
  共用同一 visibility resolver；避免每次 snapshot 重建全量 metadata/sparse。
- 相依：#48。主要檔：`read_generation.mojo`、`api/snapshot.mojo`、`api/collection.mojo`、
  新 `tests/mojo/test_generation_fields.mojo`、`tests/mojo/test_persistent_sparse.mojo`。
- 驗收：payload-only/sparse-only/full replacement、filters/NOT/hybrid、負 ID 與 Float32
  accumulation/ties 對照 owned oracle；更新後多 root 共存、flush/reopen 一致。失敗 sparse
  不發布新 root；沿用 dense/sparse 各自 WAL 合約與 sparse checkpoint crash gate。

### #50 Operation lease、close 與 GPU cache owner

- [ ] Query 取得獨立 operation owner，close 停止新操作、鎖外 drain，drop 該 handle owner；
  既有 snapshot 不失效。GPU cache 綁 root/layout/field/config/device，保留既有 budget／scratch。
- 相依：#49。主要檔：`api/collection.mojo`、`api/snapshot.mojo`、`compute/gpu/context.mojo`、
  新 `tests/mojo/test_generation_close.mojo`、相關 `tests/gpu/` lifecycle test。
- 驗收：已取得 operation 與 close 交錯、重複 close、worker error、最後 owner/pin 釋放，
  相同 G/不同 S cache freshness。GPU ownership 有改動才執行對應實機 gate；不可用 CPU
  fallback 作實機證據。無新格式，不以 Span origin 代替 operation owner。

### #51 Compaction 分離鎖外 build 與 conditional publish

- [ ] Foreground `compact()` 先 pin 精確 committed inputs，鎖外建置，短鎖核對 G/config
  後 publish；保留所有 sequence > H 的目前 head/sealed/WAL。衝突丟棄新輸出並有界重試。
- 相依：#50。主要檔：`storage/committed_compaction.mojo`、`api/collection.mojo`、
  `storage/retired_files.mojo`、新 `tests/mojo/test_compaction_publish.mojo`、
  `tests/crash/test_checkpoint_order.mojo`。
- 驗收：build 期間 writer 持續接受資料；concurrent flush 造成 conflict 時不覆蓋新 manifest；
  old snapshots/pinned files 可讀。輸出 fsync、manifest publish、root swap、cleanup 各 crash
  邊界可重開；checksum/cancel/IO failure 舊代不受損，無遺失 WAL tail。無格式變更。

### #52 Background worker 接用相同 publication 流程

- [ ] `_maintenance_entry` 接用 #51，不在整個 merge 期間持 writer lock；原單 worker、
  bounded pending work、error reporting、close/join 保持。接入 sealed delta merge/backpressure。
- 相依：#51。主要檔：`storage/maintenance.mojo`、`read_generation.mojo`、
  `tests/mojo/test_maintenance.mojo`、`tests/mojo/test_concurrency.mojo`。
- 驗收：連續寫入/flush/取消/close 壓力、衝突 retry budget、第一個錯誤回報、無死鎖或
  unbounded delta；沿用 #51 crash cases，量 writer p95/p99 stall。沒有新 worker framework。

### #53 Captured manifest backup 與 bounded copy

- [ ] 備份捕捉 manifest/config/檔案集合並持 lease；解鎖後只複製該集合。官方 FileHandle
  分塊讀寫，預設 1 MiB buffer；保留 target lock、temp/fsync/rename、manifest-last。
- 相依：#50（可在 #51 前做）。主要檔：`storage/operations.mojo`、`api/collection.mojo`、
  `storage/filesystem.mojo`、`tests/mojo/test_storage_operations.mojo`、新 backup crash test。
- 驗收：來源持續 flush/compact 時備份仍是單一 captured view，關閉/移除來源後獨立重開；
  大檔峰值記憶體不隨檔案大小線性增長。corrupt source、partial copy、manifest 前 crash、
  active/WAL target 拒絕；不默默新增 hardlink。Z07/A09 的 backup I/O 在此結案。

### #54 SQ8 ready artifact 重用

- [ ] SQ8 由 root/field/metric/config-bound owner 保管，query reuse ready artifact；
  建置中的狀態不冒充 ready，不因另一 handle close 被清除。
- 相依：#49。主要檔：`api/snapshot.mojo`、新 `index/artifact_state.mojo`、
  `index/quantization.mojo`、`tests/mojo/test_quantized_search.mojo`。
- 驗收：同 root repeated query build_count=1，更新/布局改變 freshness、metric/rescore 結果
  與舊 oracle 相同；失敗保留既有可用 artifact。純記憶體 derived cache，無 migration。

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
