# AkashaDB 工作交接入口

更新：2026-10-02。使用者要求先整理交接，並已授權 commit、push、merge 本分支全部
交付變更到 `main`。功能與驗證紀錄已整理；**整體工作尚未完成，Git 交付也尚未執行成功**。

## 閱讀順序

1. [交接狀態、測試證據與重現指令](docs/handoff/2026-10-02-status-and-tests.md)
2. [可直接貼到新對話的 handoff prompt](docs/handoff/2026-10-02-prompt.md)
3. [Git 交付狀態與接續步驟](docs/handoff/2026-10-02-git-delivery.md)
4. [唯一工作項目 checklist](tasks/todo.md) 與 [驗收計畫](tasks/plan.md)

## 現況

Named/native vector 的遷移、原子提交、查詢、Python／Arrow、F16／BF16／I8／U8、
Binary／MaxSim、NDJSON 已串接並驗證；retained base／delta cache 已改善更新後重開。
最新採用 exact scan query preparation；詳細數據見
[最新量測報告](docs/benchmarks/2026-10-02-prepared-exact.md)。

先前完整整合：957 Mojo／23 crash／344 Python／C ABI／三個範例。
最新改動：88 項受影響 Mojo、349 項完整 Python、C ABI／三個範例，另有後續
16 項 benchmark tests。這些是不同範圍的既有結果，不能加總為新一輪完整整合。

未完成：M5/M6 全效能矩陣、持續 non-resident／memory-limit 測試、受 sandbox
阻擋的網路測試與 Git 交付。Qdrant 門檻已定案：相同 recall 下，**每格 QPS ≥ Qdrant
且 p95 ≤ Qdrant**，不能跨格抵銷。最新暖查詢只有 16/36、mixed 查詢 23/36 通過。

工作目錄：`/Users/ray/Projects/Akasha/.worktrees/production-hnsw-plan`。
分支 `feat/48-bounded-generation-head`，交接 HEAD `31f27e5`。
大量變更尚未提交，請保留原工作目錄；目前沒有進行中的 benchmark／build／test。
本檔僅作入口，不另設與 `tasks/todo.md` 重複的 checklist。
