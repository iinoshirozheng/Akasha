# AkashaDB 工作交接入口

更新：2026-10-12。**整體工作尚未完成**，M5/M6 效能矩陣仍未達標。
本次在 `main` 的 `a710aa5` 上繼續 profiling，發現並修正 maintenance deadlock
（`be3be53`）。前次 Git 交付的 push／merge 紀錄屬於 10/02，不能視為本次已 push。

## 閱讀順序

1. [本次修正、驗證與 mixed 原始結果](docs/research/2026-10-12-maintenance-shared-state.md)
2. [本次 profiling、暖查詢與未採用原型](docs/benchmarks/2026-10-12-mapped-probes.md)
3. [前次交接狀態、測試證據與重現指令](docs/handoff/2026-10-02-status-and-tests.md)
4. [前次 Git 交付紀錄](docs/handoff/2026-10-02-git-delivery.md)
5. [唯一工作項目 checklist](tasks/todo.md) 與 [驗收計畫](tasks/plan.md)

## 現況

Named/native vector 的遷移、原子提交、查詢、Python／Arrow、F16／BF16／I8／U8、
Binary／MaxSim、NDJSON 已串接並驗證；retained base／delta cache 已改善更新後重開。
最新採用 exact scan query preparation；詳細數據見
[最新量測報告](docs/benchmarks/2026-10-02-prepared-exact.md)。

本次 maintenance 修正：44 項相關 Mojo 通過；完整 Python 351 passed／1 skipped，
跳過的 Qdrant adapter 使用既有 pinned 套件補跑 1 passed。本機 distributed suite
在修正前的重建 baseline 通過 10 項。前次完整 CPU／crash／C ABI 結果見歷史報告；
這些不同範圍的驗證不能加總為新一輪完整整合。

未完成：M5/M6 全效能矩陣、持續 non-resident／memory-limit／concurrent-client
對照，以及 Linux runtime／GPU device 驗收。Qdrant 門檻已定案：相同 recall 下，
**每格 QPS ≥ Qdrant 且 p95 ≤ Qdrant**，不能跨格抵銷。新暖查詢 baseline 19/36、
修正後 mixed 17/36 通過；這不是與 10/02 結果的配對效能比較。

工作目錄：`/Users/ray/Projects/Akasha`，分支 `main`。
`.build/m5-resume/` 保留重建資料庫、隔離 binary 與所有實驗。
本檔僅作入口，不另設與 `tasks/todo.md` 重複的 checklist。
