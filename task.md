# AkashaDB 工作交接入口

更新：2026-10-03。最新採用 compaction 鎖外舊檔回收，保留 lease、durability、
retry 與來源所有權；**M5/M6 仍未完成**。本包 81 targeted Mojo／21 related crash／
355 Python／C ABI／三個範例通過，warm 16/36、mixed 28/36 嚴格速度門檻通過，
整體仍 FAILED。正式 binary 為 `3610e302…`，已不再是 `a710aa5` 的來源／產物。
[最新改動與完整證據](docs/benchmarks/2026-10-03-unlocked-reclamation.md)。

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
四列 distance 候選保持隔離，M5/M6 尚未完成；舊檔回收 I/O 已獨立實作驗證並採用。
