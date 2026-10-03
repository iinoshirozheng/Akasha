# AkashaDB 工作交接入口

最新採用 named HNSW 的 immutable-run 共享：新快照重用未變動的 base，只建新 run。
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
[實作、完整樣本與限制](docs/benchmarks/2026-10-03-named-run-hnsw.md)。Archive SHA-256：
`6115ca3fc12be54c10044c6148dd1f0b453a5eaaff99105dc08ad2531fee2899`。
容量修正與最新測試 archive SHA-256：
`99ba7da9d2305e80fec6de02e2bd98acf036116308c763d3a35881e884eaa2bf`。
**M5/M6 保持未完成**；未重跑原三次 Qdrant 矩陣，也未完成 nonresident／memory-limit
與 concurrent-client parity。使用者已確認目前沒有原生 Linux runner。
下一步處理小 run 建圖／查詢成本及首次重開的 named artifact 生命週期。

以下保留本次採用前的紀錄，當時的引擎／binary 並非最新狀態。

後續 delta scan 四列候選未採用：101 targeted Mojo／358 Python 通過，但 warm
23→22/36、mixed 28→29/36，合計三個 pass→fail，受影響 ANN 收益不穩定。
保留三項 scalar-oracle 回歸與[完整證據](docs/benchmarks/2026-10-03-delta-scan-groups.md)；正式引擎仍為
`a57f11a` / `b183b880…`。這是獨立實驗，不取代或合併前次通過格。M5/M6 未完成。

更新：2026-10-03。最新採用篩選 exact scan 的兩列 checked F32 計算；全 live set
保留原順序迴圈。**M5/M6 仍未完成**。99 targeted Mojo／358 Python／C ABI／三個
範例通過。Warm 19→20/36（兩個 pass→fail）、mixed 29→32/36，整體 FAILED；
所有慢樣本與未採用的全掃描 pairing 試驗皆保留。正式 binary 為 `b183b880…`。
[最新改動、profile 與完整證據](docs/benchmarks/2026-10-03-paired-exact.md)。
先前採用的[四列 HNSW](docs/benchmarks/2026-10-03-batch-after-reclaim.md)與
[鎖外回收](docs/benchmarks/2026-10-03-unlocked-reclamation.md)保持適用；不同驗證
範圍不合併成完整整合。原生 Linux runner 使用者確認目前沒有。

本輪先前已補完 distributed 驗證（10/10），新增三種 metric 的
default-vector scan 回歸測試，並完成兩個效能候選的量測及撤回。
後續 immutable F32 summary 候選也因公開速度退步未採用；
[試驗與證據](docs/benchmarks/2026-10-03-owned-f32-summary.md)。
HNSW query 驗證候選也未採用；已補 2 項邊界回歸與 A/A、GC 診斷，
[證據](docs/benchmarks/2026-10-03-query-validation.md)。
最新紀錄見 [10-03 續作狀態](docs/handoff/2026-10-03-status-and-tests.md)。

2026-10-02 的 Git 交付已完成：當時全部交付變更已 commit、push，並以
merge commit `eef8dab` 合併進 `main` 且 push。功能與驗證紀錄已整理；
**整體工作尚未完成**，M5/M6 效能矩陣仍未達標。

## 閱讀順序

1. [最新續作狀態、測試與效能決策](docs/handoff/2026-10-03-status-and-tests.md)
2. [10-02 交接狀態、測試證據與重現指令](docs/handoff/2026-10-02-status-and-tests.md)
3. [原 handoff prompt](docs/handoff/2026-10-02-prompt.md) 與 [Git 交付紀錄](docs/handoff/2026-10-02-git-delivery.md)
4. [唯一工作項目 checklist](tasks/todo.md) 與 [驗收計畫](tasks/plan.md)

## 現況

Named/native vector 的遷移、原子提交、查詢、Python／Arrow、F16／BF16／I8／U8、
Binary／MaxSim、NDJSON 已串接並驗證；retained base／delta cache 已改善更新後重開。
先前採用 exact scan query preparation；詳細數據見
[10-02 量測報告](docs/benchmarks/2026-10-02-prepared-exact.md)。

本輪先前還原基線後：**355 Python／10 distributed／重建 C ABI 與 client 全通過**。
未重跑完整 Mojo／crash／examples；正式引擎未變，沿用仍適用的既有證據。
先前完整整合：957 Mojo／23 crash／344 Python／C ABI／三個範例。
最新改動：88 項受影響 Mojo、349 項完整 Python、C ABI／三個範例，另有後續
16 項 benchmark tests。這些是不同範圍的既有結果，不能加總為新一輪完整整合。

未完成：M5/M6 全效能矩陣、持續 non-resident／memory-limit 與 concurrent-client
parity。先前被 sandbox 阻擋的 distributed suite 本輪已通過，但不等於 HTTP
效能對照完成。Qdrant 門檻已定案：相同 recall 下，**每格 QPS ≥ Qdrant
且 p95 ≤ Qdrant**，不能跨格抵銷。本輪不變基線的兩次暖查詢為 16/36、19/36，
mixed 為 24/36；都是不同實驗的結果，未達全面 parity。候選與全部慢樣本見
[10-03 量測與撤回原因](docs/benchmarks/2026-10-03-default-vector-borrow.md)。

工作目錄：`/Users/ray/Projects/Akasha/.worktrees/production-hnsw-plan`。
分支 `feat/48-bounded-generation-head` 的 10-02 交付已合併進 `main`，之後同步至
`a710aa5`。本輪新增本地 commits `3b10af6`（原型與測試）、`717e240`（撤回原型，
保留測試）及續作文件；尚未推送或再次合併 main。前次交接完成時沒有進行中的 benchmark／build／test；後續實驗狀態見最新對話。
本檔僅作入口，不另設與 `tasks/todo.md` 重複的 checklist。

最新診斷：[四列 F32 與 compaction 持鎖成本](docs/benchmarks/2026-10-03-four-distance.md)。
原四列 distance 候選曾保持隔離；鎖外回收獨立採用後，已重新量測並整合四列距離計算。
不同實驗不合併通過格；M5/M6 尚未完成。
