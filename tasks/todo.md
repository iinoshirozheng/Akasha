# 下一輪工作包 checklist

最新採用 named HNSW 完整單一 run 快取；flush／close 保存已 ready 的圖，重開核對
identity／ID／向量並重綁 ordinal。忙碌 artifact／query 不阻塞 writer，稍後可重試。
正式 Python binary SHA-256：
`843186a731ceefaa38e6e5780a0eb13c180dcdc9525191d53f5c8ba0d89d79ba`。
第一版 77 targeted Mojo／1 targeted crash／376 Python／C ABI／3 examples；最終鎖修正
47 targeted Mojo／376 完整 Python／C ABI／3 examples；正式 package 再通過 125 targeted
Python／重建 C ABI。這些階段不加總為新完整 Mojo／crash／Linux／GPU gate。
最終三組各三次配對的 14,472 組 ID／F64 bits／stats 相同，28,944 ANN audits／4,824
exact checks 通過，兩版各保留 84 個低 recall 格。重開首查約 87–339 ms，但首次 flush
增加成本，選定暖查詢 24/36 格 QPS 或 p95 退步；未重跑或取代原 Qdrant gate。
多 run／更新後重開、首次建圖及 M6 效能／memory-limit 仍未完成。沒有 Linux runner。
[實作與全部樣本](../docs/benchmarks/2026-10-03-named-hnsw-cache.md)。
Frozen archive SHA-256：
`8677fec577201dbef6d184f47d6255871f2c98ccd12a46ac676d9dbe75a73356`。

以下保留前一工作包的歷史紀錄；最新狀態以上段與其報告為準。**M5/M6 未完成**。

最新採用 native F64 dense／MaxSim 的等長 Span iterator：保留原累加次序、
numeric validation 與 owner；省去逐座標錯誤訊息準備。僅拆 metric 迴圈的候選未採用。
正式 Python binary SHA-256：
`2d5e8e0910d4d81d84699e5bc023ba9824a5f9ab867b613cc6bcefcc7bcc0463`。
31 targeted Mojo／358 完整 Python／C ABI／三個範例通過；正式 package 再通過
7 score-bit Mojo／91 Python／C client。沒有重新跑完整 Mojo／crash／Linux／GPU。
獨立 named 診斷的 4,824 配對樣本 ID／F64 bits／stats 相同，高維 uniform QPS
提高約 7–13%、real 約 4–20%；首輪 128D all 退步仍保留。另三次完整 128D 曲線
的 all 均改善，但 selective 仍有 QPS／p95 退步，不能以中位數蓋過。
[實作、各次樣本與驗證](../docs/benchmarks/2026-10-03-native-metric-loops.md)。Frozen archive SHA-256：
`1084d5fc6c696fc0b2cd0bce1c116ca993524b0daa47eaf38940d5969fdbbfdb`。
**M5/M6 仍未完成**：未重跑原 Qdrant gate；named 首次重開建圖、並行與
nonresident／memory-limit 仍待完成。使用者目前沒有原生 Linux runner。
以下保留前一採用與獨立實驗，不將其通過格或比例合併。

前一採用 named HNSW 的 immutable-run 共享：新快照重用未變動的 base，只建新 run。
正式 Python binary SHA-256 為
`7db8a2d6b20436c5efdc71dd92565d58c4037448c32fbd7bfbee6a81c19910a6`。
第一版 76 targeted Mojo 通過；slot 版 22 targeted Mojo 通過；最後補上候選 heap
容量上限，8 targeted Mojo／358 完整 Python／C ABI／三個範例通過。最終正式
package 另通過 59 named Python／C client。不同階段不加總成完整 Mojo／crash。
量測使用容量修正前的 slot binary `2d7506f8…`；未重跑最後容量修正的速度。
固定 named 曲線的 1,608 exact checks／9,648 ANN audits 通過，12 組皆可達
Recall@10 ≥ .95；保留 baseline 28／candidate 25 個低 recall 曲線格。
全資料更新後首查 6.874／33.082／17.346 → 0.536／1.124／0.916 秒，但多數暖查詢
仍退步，128D independent 需更高 ef。首次開啟／重開仍建圖，不能宣稱全面加速。
[實作、完整樣本與限制](../docs/benchmarks/2026-10-03-named-run-hnsw.md)。Archive SHA-256：
`6115ca3fc12be54c10044c6148dd1f0b453a5eaaff99105dc08ad2531fee2899`。
容量修正與最新測試 archive SHA-256：
`99ba7da9d2305e80fec6de02e2bd98acf036116308c763d3a35881e884eaa2bf`。
**M5/M6 保持未完成**；未重跑原三次 Qdrant 矩陣，也未完成 nonresident／memory-limit
與 concurrent-client parity。使用者已確認目前沒有原生 Linux runner。
下一步處理小 run 建圖／查詢成本及首次重開的 named artifact 生命週期。

以下保留本次採用前的紀錄，當時的引擎／binary 並非最新狀態。

後續 delta scan 四列候選未採用：101 targeted Mojo／358 Python 通過，但 warm
23→22/36、mixed 28→29/36，合計三個 pass→fail，受影響 ANN 收益不穩定。
保留三項 scalar-oracle 回歸與[完整證據](../docs/benchmarks/2026-10-03-delta-scan-groups.md)；正式引擎仍為
`a57f11a` / `b183b880…`。這是獨立實驗，不取代或合併前次通過格。M5/M6 未完成。

依據：[plan.md](plan.md)。基線 `a8895c6`，engine `9b98dbc`。
使用者於 2026-09-30 已授權完成全部剩餘工作：#54 收尾、#55–#63、compaction
穩定性與後續向量型別擴充。執行計畫見
[完整交付計畫](../docs/plans/2026-09-30-complete-single-node.md)。狀態須附實際驗證證據。
路徑皆相對 repository root。每個工作包獨立提交，不把不同語意改動混成一筆。

**先前採用（2026-10-03）：** 在 `c00494f` 上加入篩選 exact scan 的兩列 checked
F32 計算，全 live set 保留原迴圈。99 targeted Mojo／358 Python／C ABI／三個範例
通過；warm 19→20/36（兩個 real-all pass→fail）、mixed 29→32/36，整體 FAILED。
保留全部退步、原未採用的 universal pairing 與 baseline profile。正式 binary
為 `b183b880…`。[完整證據](../docs/benchmarks/2026-10-03-paired-exact.md)。
沒有可用的原生 Linux runner；M5/M6 保持未勾選。以下為先前結果。

**前一採用（2026-10-03）：** 在鎖外回收基線 `7dd8647` 上重新驗證並採用四列 F32
HNSW；174 targeted Mojo／355 Python／C ABI／三個範例通過。Warm 18→22/36、mixed
23→26/36，真實 1536D mixed 九個 ANN 格皆改善，但保留 uniform-1536 independent
trial 1 的 pass→fail 及所有 QPS/p95 退步，整體 FAILED。正式 binary 為 `7b42e740…`。
[完整證據](../docs/benchmarks/2026-10-03-batch-after-reclaim.md)。M5/M6 不勾選。

**前一採用包（2026-10-03）：** compaction 舊檔回收移出 writer lock，保留 durable
publication、lease、錯誤重試及 close/source ownership；81 targeted Mojo／21 related
crash／355 Python／C ABI／三個範例通過。Warm 嚴格門檻 16→16/36，mixed 27→28/36，
無 pass→fail，但仍有個別 p95 退步，整體 FAILED。正式 binary 改為 `3610e302…`；
四列 F32 仍隔離。原生 Linux runner 目前沒有；M5/M6 不勾選。
[完整證據](../docs/benchmarks/2026-10-03-unlocked-reclamation.md)。以下為歷史實驗紀錄。

**2026-10-03 四列 F32 實驗：** 隔離候選通過 147 targeted Mojo／355 Python，
真實 1536D warm ANN 九格 QPS 均提高 20–39%，但 warm 嚴格門檻僅 16→18/36，
mixed 30→27/36 且有四個 pass→fail，尚未採用。另量出背景 compaction 舊檔回收
在 writer lock 內花 256–618 µs，是 mixed 慢查詢等待的主要來源之一；下一包縮短
此持鎖 I/O，保留同步／lease／crash 保證。原生 Linux runner 使用者確認目前沒有。
[原始證據](../docs/benchmarks/2026-10-03-four-distance.md)。M5/M6 不勾選。

**2026-10-03 後續查證：** HNSW 重複 prepared-query 驗證已量出呼叫次數與成本；
候選通過 143 targeted Mojo／355 Python，但 warm 19→17/36、mixed 32→30/36，
未證明穩定公開收益，故不採用。保留 2 項 public query boundary 回歸。
相同 binary 的 A/A 仍有 p95 波動；GC 診斷只能解釋部分慢樣本，均不排除失敗格。
[完整證據與控制實驗](../docs/benchmarks/2026-10-03-query-validation.md)。

**2026-10-03 後續實驗：** immutable F32 finite/norm summary 候選已完成隔離驗證
（94 targeted Mojo、354 Python＋補跑 pinned Qdrant 測試），但 warm 21→20/36、
mixed 25→25/36 且有 pass→fail 格，故未採用；正式來源與 binary 從未替換。
[完整試驗與證據](../docs/benchmarks/2026-10-03-owned-f32-summary.md)。M5/M6 保持未完成。

**最新續作（2026-10-03）：** 正式引擎維持 `a710aa5` 的來源與 binary。
兩個 default-vector lookup 候選均因公開 latency 退步撤回；保留三種 metric 的
缺少 default field／更新／刪除／重開回歸測試。還原後 **355 Python、10 distributed、
重建 C ABI 與 client** 全通過；先前 socket-bind 限制已解除。不同實驗中的不變
基線暖查詢為 **16/36、19/36**，mixed 為 **24/36**，仍未達每格 Qdrant 門檻。
不合併試跑、不排除慢樣本，也不以驗證或撤回原型代表 M5/M6 完成。
[續作紀錄](../docs/handoff/2026-10-03-status-and-tests.md)／
[完整量測與撤回原因](../docs/benchmarks/2026-10-03-default-vector-borrow.md)。

**前次狀態（2026-10-02）：** named／typed point 的遷移、原子提交、查詢、Python／Arrow、
原生 F16／BF16／I8／U8、Binary／MaxSim 與 typed NDJSON 匯出／匯入已實作驗證。
最近完整 CPU 整合為 **957 Mojo／23 crash／344 Python／C ABI／三個範例**，
涵蓋 NDJSON 與 CRC 改動。其後 exact scan query preparation 已通過 **88 項受影響
Mojo／349 項完整 Python／重建 C ABI 與三個範例**；共用 warm/mixed 門檻的後續
**16 項 targeted benchmark tests** 通過，未宣稱重新跑過完整 Mojo／crash 或 352 項 Python。
更新後重開已使用 retained base 與 delta cache。
目前唯一未勾選的工作是 **M5/M6 效能矩陣與最終交付**。使用者已確認完整矩陣
每格須在相同 recall 目標下同時達到 **QPS ≥ Qdrant、p95 ≤ Qdrant**，無容許差距、
不跨格抵銷。Qdrant 速度仍有差距；受控
持續 non-resident 查詢／memory limit、sandbox 禁止的網路測試尚未完成。
已補完三組資料的 0% 檔案駐留 cold-open 對照。下方各日期紀錄保留
當時的結果與限制，不代表較早的功能缺口至今仍存在。

效能 runner 已將 recall 可比與速度通過分開：QPS 或 p95 任一不達標即失敗。
最新暖查詢 **16/36**、resident mixed 查詢 **23/36** 同時通過速度門檻，
兩組各 36 格品質皆通過；速度失敗不能跨格或跨 workload 抵銷，不能結案。
[門檻](../docs/benchmarks/2026-10-02-qdrant-parity-gate.md)／
[最新量測](../docs/benchmarks/2026-10-02-prepared-exact.md)。

Git 交付已於 2026-10-02 完成：交付變更以 `92ff852`／`7bdd566`／`28e6048` 三個
commit 提交，分支已 push，merge commit `eef8dab` 已合併進 main 並 push，remote
main 核對為 `eef8dab`。merge 不代表 M5/M6 達標。紀錄見
[Git 交付](../docs/handoff/2026-10-02-git-delivery.md)。
交接入口見根目錄 [task.md](../task.md)，本檔仍是唯一工作項目 checklist。

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

## #46 定案後的實作隊列（#47–#55 已完成；#56–#63 已實作或評估驗證，待整合）

合約：[ADR 0007](../docs/adr/0007-generation-field-ownership.md)。每項是可單獨驗證的
切片，檔案為預計主要修改範圍；開始前沿實際 caller 確認，超過約 2–5 檔就先按接口
拆分。不得以保留舊 runtime fallback 讓半套 visibility resolver 通過測試。

**#56–#60** 已實作驗證、尚未提交整合：compaction job 競爭、鎖外建圖與 catch-up、v4 sidecar、備份複製，
以及跨 close／失敗 job 的遺留檔回收已完成，#59 的同 recall 基線也已建立。#47 已完成相同 view
共享，#48／#49 已讓 capture 不複製 dense／payload／sparse bytes，#50 已讓每個 query 持有
獨立 root owner，#51 已讓 foreground compact 鎖外 build、條件 publish，
#52 已讓 background worker 走同一流程並 rebase 到較新的 manifest，
#53 已讓 backup 只在鎖內 capture＋pin，鎖外有界複製，
#54 已讓 SQ8 artifact 由 root 保管、每 root 只建一次並共享；#55 已讓 PQ 依訓練參數共享。
#57 已讓單次 SearchRequest 直接輸出 owned Arrow columns；#58 已完成固定 view 的 bounded
scanner 與真實 C Data owner/release。#59 的 36 個配對通過 recall 門檻，但速度相當仍未達成；
暖查詢差距保留在 M5/M6；更新後重開已接入 v5 retained-base recovery，1536D
同 workload 最新由 75–76 秒降至 2.11 秒（單次試跑，完整矩陣仍待完成）。
已完成 #60 官方 stable sort 適配；#61 評估後依 gate 保留既有 heap。
#62 dense-WAL 有界解碼與 recovery、#63 唯讀 clone 移除均已實作驗證；下一項為 field schema／named F32 的格式與遷移。

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
- 2026-09-30 收尾：重新通過 8 個 targeted tests，提交 `7e98e89`。
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

- [x] PQ 沿用 artifact owner，cache key 包含 subspaces/centroids/training iterations/seed
  等實際參數及 root coverage；不要只用 k 或 manifest G。
- 相依：#54。主要檔：`api/snapshot.mojo`、`index/artifact_state.mojo`、
  `index/quantization.mojo`、`tests/mojo/test_product_quantization.mojo`。
- 驗收：cold build/warm query 分開量測、不同參數不誤中、失敗/取消不發布半成品、
  query 不反覆 training；matched-recall/rescore 測試保留。持久化 PQ artifact 若要加，另立版本切片。
- 完成（2026-09-30）：root 持有 `PqArtifacts`，以官方 Dict 的三整數 tuple 分開
  subquantizers／centroids／iterations；既有初始化完全 deterministic，無 seed 參數。
  registry 短鎖只取 owner，每個 key 的 `ArtifactState[PqIndex]` 分別鎖住首建置；
  metrics／k／rerank 共用 ready，換 root 自然失效，關閉 sibling 不清除共用 artifact。
  沿用 `QueryControl` 為 PQ 新增 optional cancellation／deadline／candidate budget，
  gather、training、encode、score、rerank 與 publish 前檢查；失敗／取消不發布，之後可重試。
  10 PQ＋8 SQ8＋2 query-control＋10 snapshot＋5 generation-close tests 通過；
  `bench-phase12` 的 SQ8/PQ recall（1.0／0.77）、exact rerank、warm/cold reopen 通過。
  另修該舊 benchmark 仍檢查 legacy hnsw.cache 的失效 gate（未含 #55 基線同樣失敗），
  改驗當前 sidecar；cold case 確實移除 sidecar 並逐項比較結果。
  1024×32、兩組 PQ 設定、3 processes×7 roots×64 warm calls，build_count 皆為 1；
  cold 6.959／4.073 ms，warm 49.72／52.39 µs。無格式變更，未重跑無關 crash/GPU gates。
  限制：每個存活 root 的各訓練設定各保留一份，未加淘汰；同 key 首查等待建置鎖，
  取得鎖後才觀察取消；既有 build 的 quadratic ID validation 未更動。
  [實作／量測／驗證](../docs/benchmarks/2026-09-30-pq-artifacts.md)。

### #56 HNSW rebuild 鎖外建置與 bounded catch-up

- 前置穩定性修復（2026-09-30）：已重現 foreground／worker 同 inputs 競爭；共用 job
  lock 排除重複 full-compaction build，鎖順序固定 job → writer，等待不占 writer。
  同步 maintenance、無 worker 的 flush／backup 也改用相同鎖外 builder，移除舊
  `_compact_committed`／`_maintenance_unlocked`／`_retire_or_reclaim` 路徑。
  備份在同步 compact 前 capture＋pin，驗證舊檔保活及刪除來源後可獨立重開。
  62 targeted Mojo、9 crash tests 通過；原 flush 競態在無負載及 6 個 busy processes
  下各重複 12 次，共 24 次通過；66 Python、C ABI、build 也通過。此前置階段尚未包含 #56 本體，後續實作見下。
  [原因、改動與驗證](../docs/benchmarks/2026-09-30-compaction-admission.md)。

- [x] 建立 pinned root 的 graph，publication 時核對 field/config 並用既有增量更新追上
  accepted mutations；無法有界追上就重排，不發布漏掉更新的 graph。
  2026-09-30：capture＋journal rotation＋publish 在 writer lock 內，完整建圖、source-map
  建置、catch-up 與舊 graph 釋放在鎖外。每個 journal 最多 1,024 個 final states，
  每次 capture 最多 4 輪 catch-up，整個 operation 最多 4 次 capture。overflow／持續
  寫入／stale config／failure 不取代仍有效的 graph；所有 accepted write paths 都記錄。
  手動 rebuild、flush、compact、maintenance、backup 都走此流程，移除舊鎖內 rebuild。
  18 個新 publication 測試涵蓋交錯、重試上限、關閉、失敗、鎖外 catch-up 與 reopen；
  [設計、分段量測與驗證](../docs/benchmarks/2026-09-30-hnsw-rebuild.md)。
- [x] 完成 sidecar 的版本化唯一檔名、pin 退役、backup 複製與 crash 驗證。
  2026-09-30：v4 reader／writer、獨立 fixture、唯一檔名與 pin 退役已實作，保留 v3 固定
  sequence 檔名合約；backup 複製 captured HNSW，collection close 後保留來源檔案鎖。
  新增同序號 5 個 crash 邊界、備份中斷與 BF16 restore、CRC 正確但 header 不符的驗證。
  752 Mojo／66 Python／19 crash、build、C ABI、三個範例與兩套品質 gate 通過；
  [實作／驗證與限制](../docs/benchmarks/2026-09-30-hnsw-sidecar-publication.md)。
  #59 的同 recall 對照另列，現已完成基線量測，速度差距保留於 M5/M6。
- [x] 完成遺留檔案生命週期：所有 generation 的未引用 job output 都依 exact file lease
  清理；跨 collection close 的最後 reader release 主動回收已退休檔案。
  2026-09-30：每 generation 共用 shared flock；獨立 collection／process 的 reader 都保留
  原檔，目錄 descriptor 防止改名／替換後誤刪其他目錄。foreground compaction 與 backup
  都保留 source writer ownership 至完成。新增 9 個生命週期測試；完整 94 檔 761 Mojo、
  66 Python、19 crash 與 C ABI 通過。首次 pin／最後回收的 I/O 成本獨立量測。
  [實作、量測與驗證](../docs/benchmarks/2026-09-30-file-retirement.md)。
- 相依：#50/#51。主要檔：`api/collection.mojo`、`index/segmented_hnsw.mojo`、
  新 `tests/mojo/test_hnsw_publish.mojo`、`tests/mojo/test_hnsw_rebuild.mojo`、
  `tests/crash/test_hnsw_checkpoint_order.mojo`。
- 驗收：replace/delete/reinsert/flush 與 rebuild 交錯、不同 config 拒絕 stale artifact、
  crash 後 authoritative/derived checkpoint 一致；既有品質 gate 加 #59 同 recall 對照。

### #57 Arrow 直接 result columns

- [x] Native search results 直接寫入官方 NumPy typed output buffers，再交 PyArrow；
  移除逐 result Python object staging。輸出是自有 owner，跨 collection close 存活。
- 相依：#45，**不等待 shared snapshot**。主要檔：`src/bindings/python_module.mojo`、
  `python/akashadb/arrow.py`、`tests/python/test_arrow_c_data.py`、`benchmarks/arrow_ingress.py`。
- 驗收：ID/I64、score/F32、empty/ties/sliced output、來源關閉後有效；記錄 result
  columnization copy 次數與 pointer/release。沒有持久化改動，不宣稱 AoS→SoA 必然 0 copy。
- 完成實作／驗證（2026-09-30，尚未提交）：新增 `search_record_batch(collection, request)`，
  共用原 SearchRequest dispatcher 與 native query methods 的 compile-time result exporter。
  三 metric × 四 mode × filtered/unfiltered、empty、I64 邊界、ties、close/slice/release，
  共 26 個新增案例；46 Arrow／完整 92 Python tests 及 build-python 通過。實際攔截確認
  兩個 NumPy buffers、12 bytes/result、Arrow pointer identity 與最後 slice 釋放。
  4096×16 exact dot，k=32/1024/4096 的 query+export 中位數，Python rows 123/837/2990 µs，
  direct columns 130/201/330 µs；小結果未宣稱較快。保留既有 public row API，scanner 留 #58。
  [實作、量測與驗證](../docs/benchmarks/2026-09-30-arrow-results.md)。

### #58 Leased scanner／Arrow C Data export

- [x] Scanner 固定 root，逐 run/chunk 產生 batch；可連續借用的欄位由真實 C Data
  owner/release state 保活，不連續的 filter/gather/cast 產生獨立 owned buffers。
- 相依：#49/#50/#57。主要檔：新 `src/bindings/arrow_export.mojo`、`api/snapshot.mojo`、
  `python/akashadb/arrow.py`、`tests/python/test_arrow_c_data.py`、新 scanner Mojo test。
- 驗收：多 batch、slice、projection、早停/取消、producer/scanner/snapshot/collection 任意
  合法關閉次序、最後 release 回收、空資料；同時驗 pointer/已複製 bytes/峰值 RAM。
  先做 pinned Mojo 1.0 C callback/owner prototype，不以現有 descriptor release counter 當實作。
- 完成實作／驗證（2026-09-30，尚未提交）：Mojo `ReadSnapshot.scanner()` 與 Python
  `scan_record_batches()` 提供固定 view、run/chunk iteration、typed projection、filter、
  cancellation/deadline、slot/buffer limits；一筆 dense 借用，跨筆 gather 直接填最終 owned
  buffers。現行 schemaless payload 要求明確型別，缺值為 null，型別不符失敗並關閉。
  真實 PyArrow consumer 驗證 native pointer、relocated child、parent/slice 任意合法 close、
  最後 release 與跨執行緒 sidecar 回收；C header/compiled Mojo ABI 對照通過。
  111 Python、35 targeted Mojo、build、C ABI、三範例通過；格式／write/crash/GPU 路徑未變。
  4096×128、batch 1/128/1024/4096 的 complete scan 中位數為 24.898/1.151/0.946/0.998 ms；
  逐批 copied/borrowed bytes 與程序 peak RSS 明列，未宣稱整庫 columnar 零複製。
  [實作、所有權與量測](../docs/benchmarks/2026-09-30-arrow-scanner.md)。

### #59 Qdrant 同 recall 基線與高維品質曲線

- [x] 先跑既有 128 維與高維資料，分開 uniform synthetic 與至少一組真實 embeddings；
  固定 engine/Qdrant commits、硬體、資料/seed、metric、filter、k、threads、service 邊界。
- 2026-09-30 實作／驗證完成（尚未提交）：已建立 native Python 對 native Python 的 runner、固定來源的
  shared workload 與獨立 exact oracle；官方 Qdrant Edge 0.8.0 輪子已驗 hash 並隔離安裝。
  完整 118 Python 與 6 個 native/Python generator parity cases 通過；128D／1536D
  uniform dot 與 real 1536D cosine 各三次試跑，共 36 個 paired cells 通過 Recall@10 >= 0.95，
  仍有明顯速度差距。F16 診斷完整重現 ef=128 的 0.684375，ef=512 後各 ANN mode 超過 0.98。
  強制 Edge 全走圖搜尋的失敗案例也保留原始資料與 as-run source。五份 raw archives
  包含 queries、stages、RSS、cold/open 與 checksum；未達門檻不產生速度比。
  另確認小量更新 flush 後沒有完整 HNSW
  sidecar，1536D 重開會重建約 75–76 秒；M5/M6 冷啟動收尾仍須處理此成本。
  [進度、方法與已完成原始結果](../docs/benchmarks/2026-09-30-qdrant-comparison.md)。
- 相依：#46，可先於 #47 啟動。主要檔：新 `benchmarks/qdrant_compare.py`、
  `benchmarks/post_hnsw.py`、新的 `docs/benchmarks/` 報告與 results。
- 驗收：ef sweep 直到雙方落在相同 Recall@k 門檻；報 QPS/p50/p95/p99、build/update/
  memory/cold-warm，不拿 embedded kernel 對 HTTP。至少解釋既有 ef=128 最低 0.684375
  recall 的曲線；未達 recall cell 標失敗/不比較速度，失敗可重跑且資料 checksum 固定。

### #60 A03 官方 sort 適配

- [x] Keyword/SortedBlock 排序使用官方 sort 的 comparator，保留 field/value/ordinal ties。
- 相依：#46；主要檔：`index/keyword.mojo`、`index/sorted_block.mojo`、對應兩個 tests、
  `benchmarks/mojo/metadata_bench.mojo`。以語意/byte-equivalence/scaling gate 決定替換，
  不合適就記錄原因，不新增自訂 sorting framework。無格式/例外行為改動。
- 完成實作／驗證（2026-10-01，尚未提交）：採用 pinned Mojo 1.0 的
  `sort[stable=True](Span(...))`；三種 entry 共用既有全序，移除三個 heapsort/sift。
  預設 quicksort 在先升後降輸入較慢，保留拒用量測；stable sort 的 60 個配對 cell、
  各 3 trials 共 360 runs，其結果 bytes/CRC 全相同，中位排序時間為原本 0.298–0.974 倍。
  10 萬點 metadata 完整建置 37.892 → 31.000 ms；未宣稱 query 或 Qdrant parity 提升。
  21 個 compiled copy probe cases 皆 0 entry copies；代價為 72/40 bytes/entry 暫存
  descriptors，10 萬筆長字串 peak RSS +6.891 MiB。新增 4 regressions 在替換前後皆通過，
  最終 62 targeted Mojo／118 Python、build、3 examples 通過；格式與 crash/GPU 路徑未變。
  [設計、原始量測、記憶體取捨與驗證](../docs/benchmarks/2026-10-01-metadata-sort.md)。

### #61 A04 官方 heap 適配

- [x] 分別評估 Top-K 與 HNSW min/max heap 的可直接 API，保留 reserve/clear/reuse、
  comparator 和 ID ties；先一種 heap 通過再擴充。
- 相依：#46；主要檔：`compute/topk.mojo` 或 `index/hnsw_heap.mojo`（一項一提交）、
  對應 test、benchmark/report 共約 3–4 檔。empty/full/reuse/ties/極端 scores 與 allocation/
  latency 無回歸才移除舊實作，否則留下官方不適配的證據。無 durable migration。
- 完成評估（2026-10-01，證據尚未提交）：官方 BinaryHeap 原型的 60 組 Top-K
  oracle／signed-zero／extreme／reuse 比對通過，entry 同為 16 bytes、預留後無 backing
  growth。32 paired cells × 3 trials 共 192 runs 中 28 cell 較快，但 k=1 的四個持續替換
  cell 退步；放大至 100 萬 inputs × 20 rounds、5 trials 後仍慢 12.7–14.2%，未過無回歸 gate。
  HNSW 所需的 existing-heap reserve／capacity／root replacement 缺少公開 API，三個
  compiler probes 確認；不以 private `_data` 或重建／額外 bookkeeping 拼成替代品。
  因此三個 production heaps 均保留，無 engine 改動。24 既有 heap/scratch tests 通過；
  完整 232 timing runs、原型與拒用原因見 [#61 報告](../docs/benchmarks/2026-10-01-official-heap.md)。

### #62 Z06/A09 有界 borrowed WAL decoder

- [x] BinaryReader 借用有 owner 的 bytes/span，逐 bounded record decode；只在接受
  authoritative state 時取得 owned values，避免整份 WAL/range 的重複拷貝。
- 相依：#45 的 borrow 經驗，獨立於 #47。主要檔：`storage/checksum.mojo`、
  `storage/wal.mojo`、`tests/mojo/test_wal.mojo`、`tests/mojo/test_wal_v1_compat.mojo`、
  `tests/crash/test_wal_tail.mojo`。v1/v2/v3 bytes/CRC/overflow/bounds/torn final envelope
  與 repair-after-append 均驗證，benchmark 含大 WAL peak RAM；不能用省 checksum 換速度。
- 完成實作／驗證（2026-10-01，尚未提交）：borrowed reader／payload、64 KiB 預讀與 bounded envelope／repair、
  collection recovery 三片已實作。解碼 view 在 buffer reuse 前結束；dense/sparse 依序合併，
  authority 接收移交的 owned buffers，matching HNSW sidecar 以第二次有界讀取 replay。
  1,853 個新舊 decoder／preflight 案例結果相同；42 次配對量測通過，5 萬筆大 payload
  重開 peak RSS 398.500 → 16.453 MiB、時間 491.702 → 254.319 ms。完整 98 檔／789 Mojo、
  118 Python、19 crash、C ABI、build、3 examples、兩組品質 gates 全部通過。
  Owned replay API 仍保留回傳的歷史 records；sparse WAL、segment 與 HNSW 無 sidecar 重建成本未改。
  [實作、量測與驗證](../docs/benchmarks/2026-10-01-borrowed-wal.md)。

### #63 Read-only fingerprint／existence 去除 owned clone

- [x] `authoritative_index_checksum` 改借用 entry 欄位；sparse upsert 的存在檢查使用
  ordinal/liveness，避免 `get` 複製 vector/payload。
- 相依：#46。主要檔：`api/collection.mojo`、`storage/index_cache.mojo`、
  flush/sparse 對應 tests、`benchmarks/mojo/flush_bench.mojo`（先確認 caller 再拆）。
- 驗收：fingerprint bytes、checkpoint/source freshness 不變，負 ID/刪除不存在點與
  failure sequence 不變；用 #39 的固定大 payload workload 量測。Crash gate 沿用仍適用結果。
- 完成實作／驗證（2026-10-01，尚未提交）：fingerprint 使用 `entry_ref_at`；sparse
  upsert 使用 ordinal/liveness，保留驗證與 WAL ordering。49 targeted Mojo、118 Python
  與 rebuilt binding 通過；6 個獨立 fingerprint fixtures、失敗追加／重開驗證保持一致。
  48 次直接量測、14 次 flush 量測與 6 次獨立追蹤通過；flush 每組 durable bytes 相同。
  大 payload flush 中位數 161.730 → 160.377 ms，RSS 幾乎不變；sparse 未有一致加速。
  指標探針與官方來源確認 String 採 COW，不把 payload 邏輯大小誤報成實際 memcpy。
  [實作、量測與限制](../docs/benchmarks/2026-10-01-readonly-copies.md)。

### 向量型別後續 lane：先 migration，再逐型別

M4–M6 目標保留。下一個 schema 工作先交付 field catalog、named F32 與 combined mutation
的 durable 規格/fixtures（`formats/`、`docs/adr/` 約 2–3 檔），再拆 reader-first migration、
writer/API、search/reopen 三片。每片最多約 2–5 檔並列舊版本、unknown version、torn write、
rollback/forward recovery tests。Native F16/BF16/I8/U8、binary metrics、multivector/MaxSim
依同樣順序逐型別交付；不能用 #46 的 descriptor 設計就標成「支援各種類型」。

- [x] Catalog metadata：v2 `collection.bin` 規格、三份獨立 fixtures、欄位 model／codec／
  bounded file reader。2026-10-01 通過 10 新測試與 28 既有 config/migration 測試；
  production open/writer 尚未接入。[驗證](../docs/research/2026-10-01-field-catalog.md)。
- [x] 統一 point model 與 complete-state record：獨立 typed field owners、部分更新與
  document/point sequence、六份獨立 fixtures、全型別 body codec。2026-10-01 通過
  19 新測試及 21 既有 metadata/payload/sparse 測試；尚未接入 WAL／collection。
  [規格與驗證](../docs/research/2026-10-01-point-records.md)。
- [x] Field-aware WAL／segment v4 規格、獨立 fixtures、codec 與 bounded mixed reader。
  7 envelope、8 mixed-stream 測試通過；legacy 1,853-case compatibility corpus 與先前輸出相同。
- [x] Storage authority 垂直切片：catalog publication、point batch staging／fsync、共用
  legacy preflight、cutover replay、v4 base/delta、compaction／重開。新增 30 項 targeted tests
  通過；尚未接通 public collection／snapshot／binding，完整 crash gate 仍待完成。
  [目前實作與驗證範圍](../docs/research/2026-10-01-field-authority.md)。
- [x] Typed read owners／exact kernels／maintenance primitives：5 種 native dense 與
  binary／MaxSim 精確搜尋、共享 typed snapshot 與缺欄位排除、v4 compaction rebase／leases、
  catalog-aware streamed backup／restore 的 targeted tests 通過。Migration 保留 owner，
  head budget 計入各型別 bytes；public API 後續進度如下，M4 完整 index 矩陣尚未驗收。
  [驗證與限制](../docs/research/2026-10-01-field-authority.md)。
- [x] 將 field-aware authority 接入 production collection，完成 migration／checkpoint
  failure/crash 與 publication 的整合驗證。
  已接入 public collection、snapshot、既有 writes 的 combined WAL 路徑、同步／背景
  compaction 與備份還原；4 項整合測試及 10 個 checkpoint crash 邊界通過。
  Python／Arrow 已接入 5 種 native dtype、binary、MaxSim、命名 sparse；27 項
  Python point 測試與 26 項 typed Arrow 測試通過，Python 全套 170 passed / 1 optional
  skip；再加入獨立 Float64／bitset oracle、named HNSW／fusion 後，最新版全套 **234 passed**。
  Default HNSW retained-base recovery、更新／刪除／還原與 36 個新 crash 狀態通過；
  1536D 建置 78.1 → 38.1 秒、重開 3.86 → 2.11 秒、暖查詢約快 18%，仍落後 Qdrant。
  [量測與驗證](../docs/benchmarks/2026-10-01-hnsw-accumulators.md)。
  Named dense HNSW 已接上獨立 field artifact、native F64 rerank、Python／Arrow、
  filter、期限／上限與 failed/concurrent-build；3 Mojo + 26 Python 新測試通過。
  Named sparse postings 已保留 F64 累加、空／零／負分語意、failure/retry/concurrent-build；
  多欄位 RRF 在同一 captured root 查詢，Python／Arrow、filters、close/reopen 通過。
  Named graph 首次查詢建置，尚無 durable sidecar。完整整合已通過 123 檔／917 Mojo、
  234 Python、23 crash、C ABI、build 與三個範例；效能矩陣與最終提交仍待完成。
  [整合證據與限制](../docs/research/2026-10-01-named-field-search.md)。
- [x] Named F32 與 dense/sparse/payload 原子更新：authority、checkpoint、snapshot、
  index/search/reopen、Python/Arrow 全路徑驗證。
  依上述完整回歸，原子提交、失敗不發布、舊快照、named HNSW／sparse／RRF 與 typed
  Arrow 已驗收。每個新 root 的 named 索引冷建成本仍屬 M5/M6。
- [x] Native F16/BF16/I8/U8、binary Hamming/Jaccard、multivector MaxSim 逐型別交付。
  各型別 authority／codec／Python／Arrow／查詢／重開與獨立 Float64／bitset oracle
  通過。BF16 已驗證 native list／Arrow UInt16 bits；選用的 `ml_dtypes` producer 未安裝，
  不列為已跑 gate。IVF 與索引效能擴充仍歸下一項。
- [x] Named/native point 的 NDJSON logical export/import 保真與原子提交。
  2026-10-02 收尾重現：兩筆 point（其中一筆沒有 default dense）匯出只剩一筆，
  命名向量也未帶出。既有 physical backup／restore 與 Arrow 驗收不涵蓋這條路徑；
  已補獨立版本／schema、全部 native fields、缺值／空值、舊格式相容與一次 point batch
  提交。22 項新回歸與完整 Python **339 passed**；frozen fixture、原生數值極值／負零、
  來源關閉、CLI、失敗不提交與發布失敗保留舊檔均通過。
  [實作與驗證](../docs/research/2026-10-02-named-logical-export.md)。
- [ ] M5/M6 暖查詢／更新後重開／讀寫維護與 resident/non-resident 矩陣，最終整合交付。
  Named cache reconciliation 候選未採用：首查快 6–7 倍，但初版 fixed recall
  132→129/216、28/36 timing 退步。定位 filtered inactive radius 缺陷；隔離修正
  128 targeted Mojo／388 Python 通過，固定圖 recall 129→135/216、無 pass→fail，
  仍有 20/36 timing 退步。初版另通過 115 targeted Mojo／11 crash／388 Python／
  C ABI／3 examples；範圍不混算。正式 source/binary 未變，下一步獨立驗證搜尋修正。
  [全部樣本與重現](../docs/benchmarks/2026-10-04-named-cache-reconcile.md)。
  Paired finite validation 候選未採用：89 unique targeted Mojo／388 Python 通過，
  public warm 23→24/36、mixed 19→21/36，仍有五個 pass→fail；write+flush 3→3/9。
  保留三個 exponent/lane 回歸、兩版 micro、selective profiles 與所有 samples；
  正式核心未改。[完整證據](../docs/benchmarks/2026-10-04-paired-finite-max.md)。
  下一步處理 M5 多 run／更新後重開的 named artifact 生命週期。
  Segment F32 整段寫入候選未採用：73 targeted Mojo／8 related crash／388 Python
  通過，bytes 相同；micro 改善未穩定反映在 public flush。三方 warm／mixed 皆
  19→18/36，write+flush 3→3/9，保留全部失敗；正式來源與 binary 不變。
  [完整實驗](../docs/benchmarks/2026-10-04-segment-bulk-write.md)。
  鎖停滯後續 100 次原 binary／100 次隔離 owner 診斷，各通過 28,800 audits、
  100 reopens、100 leases；診斷版 20 項背景維護測試通過。原 DB 複本恢復 9 個
  exact oracle 與序號 9424 通過；仍未重現、原因未解、未改正式鎖。下一步獨立
  驗證高維 segment 編碼成本。[完整診斷](../docs/benchmarks/2026-10-04-baseline-lock-stall.md)。
  Payload scratch 候選未採用：67 targeted Mojo／388 Python／9 related crash／C ABI／
  3 examples 通過；三方 warm 19→18/36 有兩個 pass→fail，mixed 24→29/36 不抵銷。
  原基線首輪另有 BlockingScopedLock 停滯，124.97 秒後終止；13 次診斷未重現，
  原因仍未解，保留完整 stack／部分資料庫。正式 source/binary 不變；下一步查此停滯。
  [候選、全部樣本與未解失敗](../docs/benchmarks/2026-10-04-payload-buffer.md)。
  2026-10-04 現行 binary 的固定三次矩陣：warm 22/36、mixed 查詢 25/36、HTTP
  18/108 strict parity；各自 recall 36/36、36/36、108/108 全通過。Durable write+flush
  3/9 通過；所有 audits／18 mixed reopen／9 Arrow leases 通過，三組整體 FAILED。
  這是獨立現況量測，不與歷史通過格合併，也不是實作 A/B；無新 nonresident gate。
  [完整現況與 immutable 證據](../docs/benchmarks/2026-10-04-current-parity.md)。
  2026-10-04 現行來源完整 **141 檔／1,001 Mojo、8 檔／23 crash、3 rebuilt examples**
  與既有 C client 通過；沿用同 binary 的 388 完整 Python。保留 reader launcher
  首次失敗與 9/9 來源模式重跑，不重複加總；沒有新 Linux／GPU／ASan gate。
  [最新 CPU 整合證據](../docs/research/2026-10-04-cpu-integration.md)。
  最新 Python 向量轉換重用單次操作的驗證 callable/type，逐值檢查不變；388 完整
  Python／採用後 129 targeted Python 通過。Named 三資料集各三次完整曲線的
  14,472 paired ID／F64 bits／stats 相同，28,944 ANN audits／4,824 exact ID checks
  通過；兩版各 84 低 recall 格保留。36 選定格 QPS 全提高、30 格 p95 改善，6 格
  p95 退步仍保留；不取代原 Qdrant gate，也不代表 M5/M6 完成。
  [完整 profiles／配對／驗證](../docs/benchmarks/2026-10-03-python-vector-validation.md)。
  已採用 HTTP search 單次 worker 排程；41 targeted Python 與 OpenAPI／結果位元
  檢查通過。獨立三方 strict parity 14→22/108，兩格 pass→fail 仍保留，整體 FAILED；
  不與前次 16/108 合併。[實作、profile 與全部試跑](../docs/benchmarks/2026-10-03-http-dispatch.md)。
  原生 HTTP／並行 1/2/4 clients 的三資料集×三 trial 已完整量測：108/108 recall、
  16/108 strict parity，整體 FAILED；24,120 query audits 與 33 targeted Python
  tests／兩個實際 server smoke 通過。沒有新完整 engine 整合；原 binding gate 獨立保留。
  [完整 HTTP 證據](../docs/benchmarks/2026-10-03-http-parity.md)。
  最新 planner 隔離複核支持 uniform 選 exact／real 低 ef 選 ANN；14,472 exact 與
  14,472 approx audits 保留 57 個低 recall pass cells，未改 production 路由，
  不取代 Qdrant gate。[完整證據](../docs/benchmarks/2026-10-03-planner-recheck.md)。
  IVF-flat 已接通 native 五型別、三種 metric、Mojo／Python／Arrow／多欄位融合；
  3 Mojo + 25 Python 新測試與控制項測試通過，最新 Python 全套 264 passed。
  180 probe/filter/dtype/metric 量測格保留完整 recall 與原始延遲；完整 probe 與獨立
  oracle 相符，低 probe 在均勻資料上未達 .95 recall，不宣稱速度達標。
  [IVF 驗收及限制](../docs/benchmarks/2026-10-01-field-ivf.md)。
  Binary／MaxSim 候選重排已接通同一 captured root 的 dense/sparse/IVF/HNSW 取回、
  原生精確重排與 Python／Arrow；52 Python + 1 Mojo 驗證通過。50 個候選預算／filter／
  metric 量測格保留失敗 recall 與慢樣本；隨機 token 的 mean pooling 未在小候選集
  達到 .95 recall，不宣稱加速。[驗收](../docs/benchmarks/2026-10-01-field-rerank.md)。
  固定成本 planner 的三組資料各三次 Qdrant 對照已完成；36 格通過 recall，真實資料
  暖查詢仍落後，速度目標未完成。[結果](../docs/benchmarks/2026-10-01-planner-cost.md)。
  Resident 90/10 讀寫混合與每批 flush 已完成三資料集各三次對照，5,184 個 query 的
  filter／live ID／recall audit、18 次最終重開 oracle 全通過；Arrow lease 跨 compaction
  與 close 仍有效，釋放後舊檔回收。36 格達 .95 recall；真實資料、寫入與高維 flush
  仍有速度差距。[量測](../docs/benchmarks/2026-10-01-qdrant-mixed.md)。
  2026-10-02 最新 Python 整套 **317 passed**；legacy batch 已改成 bounded staging，
  WAL／發布失敗要求 reopen，metadata 改二分定位與標準 List 移動。三組各三次配對、
  5,184 query audit／18 次 reopen／lease 檢查通過；uniform 寫入 p95 中位數降 49%／28%。
  真實資料有新舊版各自的慢樣本，不能宣稱穩定 tail 改善；匯入中位數接近持平。
  [實作、測試與全部試跑](../docs/benchmarks/2026-10-02-bounded-batch.md)。
  分塊 CRC 與 mmap 範圍 checksum 已通過全套 **125 檔／933 Mojo、317 Python、
  23 crash、C ABI 與三個範例**。三組各三次配對的 5,184 query audit／18 次 reopen
  與 lease 全通過；flush p95 配對中位數降低 46%／60%／58%，高維重開降低約
  12%／15%，仍未達 Qdrant 全矩陣目標。[量測](../docs/benchmarks/2026-10-02-block-crc.md)。
  後續 fingerprint 改逐筆串流並重用 header，checksum fixtures 保持一致；56 項受影響
  Mojo／7 crash、317 Python 與重建 C ABI 通過。1536D 獨立測試約 41 → 24 ms，
  尖峰 RSS 約 180 → 68 MiB；三組配對的內容／lease／recall 全通過。Flush 改善，
  reopen 幾乎持平，真實資料 write-only p95 略升，所有樣本保留。
  [量測與驗證](../docs/benchmarks/2026-10-02-stream-fingerprint.md)。
  HNSW delta 已使用驗證後的 checkpoint cache，compaction 保留有效 artifact，失敗可重試；
  F32 snapshot bytes 保持一致。最新 58 個 cache 案例、相關 Mojo／crash、317 Python 與
  重建 C ABI 通過。九組配對重開中位數約 688/1708/1401 → 127/357/366 ms；代價是
  flush p95 增加 45–56%、write+flush 增加 33–37%，沒有標為全效能提升。
  [完整試跑與驗證](../docs/benchmarks/2026-10-02-hnsw-overlay-cache.md)。
  最新 Qdrant mixed 九組對照的 5,184 audits／36 recall 格／18 reopen 全通過；真實資料
  independent filter、高維 selective／write+flush／reopen 仍有落差，保留全部慢樣本。
  Resident/non-resident 與最終交付尚未全數完成。
  [最新對照](../docs/benchmarks/2026-10-02-qdrant-mixed-overlay.md)。
  HNSW 遍歷改成每個節點／層定位一次鄰接範圍，保留逐次 owner／bounds 與目標層檢查。
  245 項 Mojo、9 crash、317 Python、C ABI 通過；九組 native 配對候選／結果位元一致，
  原生查詢中位數降低約 17%／5%／7%。公開 mixed 的 5,184 audits／72 recall 格／
  18 reopen／18 lease 全通過；真實資料三種 ANN 查詢 QPS 中位數增約 4–7%，仍有
  correlated 與 selective 慢樣本，不能宣稱尾延遲或 Qdrant 全矩陣達標。
  [量測與驗證](../docs/benchmarks/2026-10-02-hnsw-neighbor-ranges.md)。
  小型 delta 已依實體槽位／總維度／ef 上限切換精確評分，base 仍走 HNSW；原生後端、
  過濾、替換歷史與同分排序通過，130 Mojo／9 crash／317 Python／C ABI 全通過。
  九組公開配對的 5,184 audits／72 recall 格／18 reopen／18 lease 全通過；真實資料
  ANN QPS 配對中位數提高約 12%／21%／17%，精確控制組與 write-only 有較慢樣本。
  最新 Qdrant 暖查詢 432 曲線格保留 105 格 recall 失敗，36 組選定對照通過；真實資料
  QPS 仍約為 Qdrant 的 .43–.73 倍。Mixed 真實 independent 約 .74 倍，write+flush
  與重開仍未達標。[全部診斷、試跑與限制](../docs/benchmarks/2026-10-02-hnsw-delta-scan.md)。
  F32 segment／WAL／owned HNSW 解碼改成有界整段讀取，保留位元、格式與全部驗證。
  58 項 prototype codec／fixture、正式 120 Mojo／20 crash／317 Python／C ABI 通過；
  ASan 因執行期符號無法連結，未列為通過。九組正式 mixed 配對的 5,184 audits／
  72 recall 格／18 reopen／18 lease 全通過，重開中位數約 125/352/367 → 117/253/269 ms。
  真實資料 write+flush 中位數略升，未宣稱查詢／寫入改善。首次原型建置入口錯誤的
  比較已保留並排除，修正後核對 binary 與結果再採用。
  [原始證據與限制](../docs/benchmarks/2026-10-02-f32-read-probe.md)。
  Mapped F32 結構驗證改成有界分塊讀取，數值與圖驗證保持不變；九組公開重開配對
  的 ID／score 一致，128D 約 112 → 109 ms，1536D 約 262/275 → 219/227 ms。
  最新完整整合 **130 檔／954 Mojo、23 crash、317 Python、C ABI、三個範例**通過。
  跨程序 lease 測試首次因子程序未繼承 Metal target 而編譯器失敗，修正 runner 後通過，
  原始失敗保留；NDJSON 收尾缺口另列於上方。
  [量測與完整驗證](../docs/benchmarks/2026-10-02-mapped-vector-read.md)。
  雙方使用相同細化 ef grid 的九組暖查詢配對完成：864 格、55,296 query audits、
  4,824 exact oracle checks 全部留存，363 格 recall 失敗未排除；36 組選定對照皆達
  Recall@10 ≥ .95。真實資料 QPS 仍為 Qdrant 的 .57–.84 倍，128D all 約 .71 倍、
  1536D selective 約 .80 倍，效能目標未完成。這是參數曲線細化，非引擎改動加速。
  [完整結果與來源](../docs/benchmarks/2026-10-02-refined-ef-warm.md)。
  HNSW source／ordinal／eligibility 的 `Dict.get` 替換已評估並撤回：正確性通過，
  但公開真實資料查詢出現退步；拆分 source 與 eligibility 後仍未通過效能 gate。
  正式來源與 Python binary 已還原至驗證過的基線，C ABI 重建通過；保留負 ID／
  missing ID／ordinal 0 回歸與全部慢樣本。
  [未採用原因與量測](../docs/benchmarks/2026-10-02-hnsw-lookup-probes.md)。
  圖驗證與雙向邊 audit 已重用每層有界鄰接範圍，保留逐邊 owner／bounds 與完整
  結構檢查。108 Mojo／9 crash／339 Python／C ABI 通過；九組公開重開配對的
  576 exact oracle／576 ANN 結果一致。重開中位數約 108/216/228 → 98/209/218 ms，
  尚未宣稱暖查詢、寫入或 Qdrant 全矩陣達標。
  [驗證與量測](../docs/benchmarks/2026-10-02-hnsw-validation-ranges.md)。
  補跑分散式 gate 為 3 passed／7 failed：七項在 `socket.bind(127.0.0.1)` 被 sandbox
  拒絕，尚無本輪網路／HTTP 驗收結果。[整合證據與限制](../docs/research/2026-10-02-cpu-integration.md)。
  最終提交受目前 sandbox 限制：worktree 的 git index 實際位於主 checkout 的
  `.git/worktrees/production-hnsw-plan`，建立 `index.lock` 被拒絕；沒有完成 staging／commit。

- 2026-10-02：未採用 HNSW validation 的 prefix-base lookup。候選通過 109 Mojo／
  9 crash／339 Python／C ABI，但真實資料重開八組平衡順序配對的延遲中位比值為
  1.011，未證明改善；已復原原程式與 Python binary、重建 C，保留跨層反向邊回歸。
  [完整試驗與撤回證據](../docs/benchmarks/2026-10-02-hnsw-validation-level-bases.md)。

- 2026-10-02：採用依實際 target feature 啟用的 AArch64 CRC32，持久化 bytes 不變；
  四種 feature 組合的 bitwise／protected-page 驗證、五種 target 機器碼檢查通過。
  完整整合 **957 Mojo／23 crash／344 Python／C ABI／三個範例** 通過。
  真實資料 cached reopen 213 → 154 ms；mixed flush p95 54.8 → 32.9 ms、
  write+flush 70.2 → 48.8 ms，保留 128D write-only 退步與查詢慢樣本。
  前後及 Qdrant 兩輪 mixed 各有 5,184 audits 通過；Qdrant 對照仍有高維寫入、
  cached reopen、independent／selective 查詢差距，暖查詢目標仍未全達成。
  新建 inode 逐檔 mincore 證明 27 次 cold-open 均為 0% 駐留；864 exact checks
  與另行既定 ef 的 2,304 完整 query audits／36 recall 格通過，未將低 ef 失敗刪除。
  [完整量測](../docs/benchmarks/2026-10-02-arm-crc.md)／
  [整合驗證](../docs/research/2026-10-02-cpu-integration-arm-crc.md)。

- 2026-10-02：F32 exact scan 每次操作只驗證一次 query／計算一次 cosine query norm，
  保留每筆 candidate 驗證、原有浮點運算次序與 HNSW checked pair 評分。
  88 項受影響 Mojo、349 項完整 Python、重建 C ABI／三個範例通過；後續共用
  warm/mixed 速度門檻的 16 項 targeted tests 通過。1536D all 暖查詢 QPS 配對
  中位數提高 49%，但不宣稱 ANN 或全矩陣改善。最新暖查詢 16/36、mixed 23/36
  達嚴格 Qdrant 速度門檻；保留 selective 退步、ANN 慢樣本與全部失敗格。
  HNSW prepared-rerank／forced-inline 原型未採用。完整原始數據、原型與測試證據
  已凍結；[報告與 SHA-256](../docs/benchmarks/2026-10-02-prepared-exact.md)。
  本輪依使用者要求停在交接，不再啟動新的效能實驗；M5/M6 保持未勾選。
