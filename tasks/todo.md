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
- [ ] 改用官方 owned copy，移除過時 helper；不引入新的通用 clone 抽象。
- [ ] 改變 caller input／returned vector 不影響 collection；snapshot isolation 不變。
- [ ] payload clone、空值、sequence 與 ID 行為保持，未改動資料格式。

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
- [ ] empty／連續多段／大 buffer append 後 bytes 與現有 codec fixtures 完全相同。
- [ ] `take_bytes` 後 writer 可重用，來源 buffer 壽命／修改不影響已寫 bytes。
- [ ] CRC polynomial、byte order、bounds／corruption checks 不變。

**驗證：** `pixi run mojo run -I src tests/mojo/test_storage_checksum.mojo`、
`pixi run mojo run -I src tests/mojo/test_crc32_table.mojo`、
`pixi run mojo run -I src tests/mojo/test_wal_v1_compat.mojo`、
`pixi run mojo run -I src tests/mojo/test_segment_v1_compat.mojo`。

**相依：** 無。**規模：** S。
**預計檔案：** `src/akasha/storage/checksum.mojo`、`tests/mojo/test_storage_checksum.mojo`。

## Checkpoint B：#41／#42

- [ ] owned-result regressions 與 format fixtures 通過，沒有 silent borrow 或 CRC 格式改變。
- [ ] 第一批完成後執行一次 `pixi run build`，更新 A01/A02/A05/A06/Z02 的查核狀態。

## #43：SparseIndex 使用官方 Dict lookup

**描述：** 移除 record／term／score 的重複線性搜尋，使用已存在的 std Dict。

**驗收：**
- [ ] upsert、delete、delete/reinsert、slot 移動都更新 lookup；clone／reopen 結果一致。
- [ ] sparse Dot 與 filtered/hybrid 結果、浮點累加順序與 ID ties 不變。
- [ ] 多 point／term 與少量命中的固定 workload 記錄 lookup work／memory／latency，無 per-candidate 全表 ID scan。

**驗證：** `pixi run mojo run -I src tests/mojo/test_sparse_index.mojo`、
`pixi run mojo run -I src tests/mojo/test_persistent_sparse.mojo`、
`pixi run mojo run -I src tests/mojo/test_snapshot.mojo`。

**相依：** 無。**規模：** M。
**預計檔案：** `src/akasha/index/sparse.mojo`、`tests/mojo/test_sparse_index.mojo`、
`tests/mojo/test_persistent_sparse.mojo`；量測如需新增專用檔，限本工作負載。

## #44：RRF fusion 使用官方 Dict 累計

**描述：** `_accumulate` 以 ID lookup 替代遍歷已有 scores，沿用目前 RRF 公式與輸入順序。

**驗收：**
- [ ] overlapping／disjoint lists、empty input、負 ID、ties 與 rank_constant 皆符合現有合約。
- [ ] 浮點累加順序與 deterministic output 不被 Dict iteration order 改變。
- [ ] 隨 fetch_k 增大的量測顯示移除 quadratic ID lookup，包含 Dict 記憶體成本。

**驗證：** `pixi run mojo run -I src tests/mojo/test_rank_fusion.mojo`、
`pixi run mojo run -I src tests/mojo/test_persistent_sparse.mojo`。

**相依：** 無；整合驗證可在 #43 後一次完成。**規模：** S。
**預計檔案：** `src/akasha/query/fusion.mojo`、`tests/mojo/test_rank_fusion.mojo`。

## Checkpoint C：#43／#44

- [ ] Sparse／hybrid／snapshot narrow tests 通過；記錄效能與 retained memory。
- [ ] 沒有新增格式或自訂 hash table，查核 A07 逐項更新。

## #45：Arrow primitive ingress 改為 typed borrow

**描述：** 使用 PyArrow／NumPy 官方 view 與 Mojo `from_numpy_array`，把 ID、dense
F32 與 sparse primitive buffers 一次借用成 Span，消除元素級 Python boxing。
同步呼叫期間保留 producer owner；WAL/MemTable 仍依既有 owned 合約接收資料。

**驗收：**
- [ ] 指標相同、sliced offset／dtype／contiguity／readonly／bounds／null 檢查有真實 buffer 測試；原 producer 可安全釋放。
- [ ] compiled primitive loop 不再呼叫逐元素 Python 轉型；寫入／重開／dense+sparse 結果相同，不擴大 atomic batch 宣稱。
- [ ] payload materialization 與 durable owned copy 單獨計量；不宣稱整條 ingest 零複製，不提供會懸空的 retained Span。

**驗證：** `pixi run build-python`、
`pixi run env PYTHONPATH=python:. pytest tests/python/test_arrow_c_data.py -q`、
`pixi run mojo run -I src tests/mojo/test_arrow_c_data.mojo`；固定 rows×dimension
量測 ingress time／allocations／copied bytes，延用本次官方 API 探針。

**相依：** 無；建議第一批 checkpoint 後交付。**規模：** M。
**預計檔案：** `python/akashadb/arrow.py`、`src/bindings/python_module.mojo`、
`tests/python/test_arrow_c_data.py`、`tests/mojo/test_arrow_c_data.mojo`。

## #46：定案 generation／field ownership，拆出生命週期實作

**描述：** 用目前 F32/payload/sparse 與 GPU cache 為落地範圍，定案 immutable base、
delta、accepted sequence、leases／close／publish 的合約；為 named/type 擴充留下具體
field 邊界。交付設計、成本基線與下一批小型實作清單，不直接大改全庫。

**驗收：**
- [ ] ADR 決定 snapshot 捕捉、delta visibility、metadata/sparse 一致性、cache identity、pin／publish／retire 與 close；列出實際選擇與淘汰原因。
- [ ] 量測 0／少量 delta、相同 manifest 不同 sequence、多個存活 snapshot 的 capture time／copied bytes／RAM，並用最小 Mojo 探針確認選定 owner／borrow 語意能編譯。
- [ ] 將 shared snapshot、background compaction、backup、index lifecycle、Arrow result/scanner 拆成約 2–5 檔的小包，更新 todo；每包有 dependency、失敗／crash 驗收，需格式改動者另列 migration。

**驗證：** 檢查所有 ADR invariants 對應現有或明列的新 regression；
`pixi run bench-phase11` 做可重現成本量測；新增的 owner 探針使用
`pixi run mojo run -I src <probe.mojo>` 在當時 locked toolchain 編譯。
量測 harness 若有變動，只跑對應檢查，不把設計交付當成引擎功能驗收。

**相依：** Checkpoint B 的最新來源；不依賴 #43–#45 完成。
**規模：** M（設計／量測，後續實作另拆）。
**預計檔案：** 新的 `docs/adr/` ownership ADR、`benchmarks/mojo/phase11_bench.mojo`、
新的 `docs/research/` 成本報告、`tasks/plan.md`、`tasks/todo.md`；獨立探針可放 `.build/`。

## Checkpoint D：下一批啟動條件

- [ ] #45 借用邊界與 #46 ownership 合約互相一致，已完成項目各附 commit／驗證證據。
- [ ] 只有定案且拆小的生命週期切片進入實作；保留完整 M2–M6 目標，不以 #46 文件完成代替功能。
- [ ] 把同 recall 的 Qdrant 基線與高維品質曲線排入下一批，先量差距再決定 HNSW 調校。
- [ ] 下一批同時列入 A03/A04 官方 sort/heap 適配，以及 Z06/A09 的 bounded decode／I/O；優先度依量測，避免延後 shared snapshot。
