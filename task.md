# AkashaDB 工作交接入口

更新：2026-10-13。**整體工作尚未完成**，M5/M6 效能矩陣仍未達標。
本次在 `main` 的 `a710aa5` 上繼續 profiling，發現並修正 maintenance deadlock
（`be3be53`）。前次 Git 交付的 push／merge 紀錄屬於 10/02，不能視為本次已 push。

## 閱讀順序

1. [本次修正、驗證與 mixed 原始結果](docs/research/2026-10-12-maintenance-shared-state.md)
2. [本次 profiling、暖查詢與未採用原型](docs/benchmarks/2026-10-12-mapped-probes.md)
3. [外部並行客戶端矩陣](docs/benchmarks/2026-10-13-concurrent-clients.md)
4. [Linux runtime／Metal device 驗證](docs/research/2026-10-13-linux-gpu-validation.md)
5. [前次交接狀態、測試證據與重現指令](docs/handoff/2026-10-02-status-and-tests.md)
6. [前次 Git 交付紀錄](docs/handoff/2026-10-02-git-delivery.md)
7. [唯一工作項目 checklist](tasks/todo.md) 與 [驗收計畫](tasks/plan.md)

## 現況

Named/native vector 的遷移、原子提交、查詢、Python／Arrow、F16／BF16／I8／U8、
Binary／MaxSim、NDJSON 已串接並驗證；retained base／delta cache 已改善更新後重開。
最新採用 exact scan query preparation；詳細數據見
[最新量測報告](docs/benchmarks/2026-10-02-prepared-exact.md)。

本次 maintenance 修正：44 項相關 Mojo 通過；完整 Python 351 passed／1 skipped，
跳過的 Qdrant adapter 使用既有 pinned 套件補跑 1 passed。本機 distributed suite
在修正前的重建 baseline 通過 10 項。前次完整 CPU／crash／C ABI 結果見歷史報告；
這些不同範圍的驗證不能加總為新一輪完整整合。

已補齊指定 Linux x86-64 runtime 測試（Docker 模擬執行）：45 個不同 Mojo 案例、
350 個不同 Python 案例與 C ABI 通過，保留環境失敗及補跑紀錄；完整 native Linux
CI 仍未驗證。Metal snapshot／cache 9 項通過，含實機路徑與故障 fallback。

外部客戶端採用雙方相同 HTTP shim 與單一 engine handle：1 client 控制組 21/36、
4 clients 14/36 達速度門檻，72 格配對品質皆通過。此為獨立服務邊界，不能與
binding-only 矩陣合併；完整結果仍為 FAILED。相關 19 項 Python 測試通過。

[首輪受控記憶體診斷](docs/benchmarks/2026-10-13-memory-cap-probe.md)：real-1536 在
256 MiB 下 Akasha 完成但保持駐留；224／192／128 MiB 在 open 階段 OOM。
Qdrant 各上限皆完成，部分查詢具持續非駐留證據；單次模擬 Linux 診斷不代表全矩陣。

未完成：M5/M6 全效能矩陣、持續 non-resident／memory-limit 對照，以及尚未執行的
環境／整合 gate。Qdrant 門檻已定案：相同 recall 下，
**每格 QPS ≥ Qdrant 且 p95 ≤ Qdrant**，不能跨格抵銷。新暖查詢 baseline 19/36、
修正後 mixed 17/36 通過；這不是與 10/02 結果的配對效能比較。

工作目錄：`/Users/ray/Projects/Akasha`，分支 `main`。
`.build/m5-resume/` 保留重建資料庫、隔離 binary 與所有實驗。
本檔僅作入口，不另設與 `tasks/todo.md` 重複的 checklist。
