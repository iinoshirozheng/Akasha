# AkashaDB 工作交接入口

更新：2026-10-13。**整體工作尚未完成**，M5/M6 效能矩陣仍未達標。
本次在 `main` 的 `a710aa5` 上繼續 profiling，發現並修正 maintenance deadlock
（`be3be53`）。前次 Git 交付的 push／merge 紀錄屬於 10/02，不能視為本次已 push。

## 閱讀順序

1. [四候選 HNSW 移植與配對驗證](docs/benchmarks/2026-10-13-four-neighbor-port.md)、
   [三資料集受控記憶體矩陣](docs/benchmarks/2026-10-13-memory-cap-matrix.md) 與
   [mapped segment 恢復修正](docs/benchmarks/2026-10-13-mapped-segment-read.md)
2. [本次修正、驗證與 mixed 原始結果](docs/research/2026-10-12-maintenance-shared-state.md)
3. [本次 profiling、暖查詢與未採用原型](docs/benchmarks/2026-10-12-mapped-probes.md)
4. [外部並行客戶端矩陣](docs/benchmarks/2026-10-13-concurrent-clients.md)
5. [Linux runtime／Metal device 驗證](docs/research/2026-10-13-linux-gpu-validation.md)
6. [前次交接狀態、測試證據與重現指令](docs/handoff/2026-10-02-status-and-tests.md)
7. [前次 Git 交付紀錄](docs/handoff/2026-10-02-git-delivery.md)
8. [唯一工作項目 checklist](tasks/todo.md) 與 [驗收計畫](tasks/plan.md)

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

[首輪受控記憶體診斷](docs/benchmarks/2026-10-13-memory-cap-probe.md) 的 open OOM
促成 [mapped segment 讀取修正](docs/benchmarks/2026-10-13-mapped-segment-read.md)：
移除整份 encoded segment 副本，real-1536 現在可於 224／192 MiB 下完成恢復與查詢；
128 MiB 仍 OOM。192 MiB 的三個 ANN 模式具持續非駐留證據，selective exact 不具此證據。
完整暖查詢前後品質皆 36/36、速度皆 16/36；包含退步格，不宣稱查詢速度改善。
相關驗證為 105 Mojo、23 crash、完整 Python 355 項加 1 項新編譯檢查，以及 C ABI；
Linux 原型另有 22 targeted Mojo 通過。這些診斷仍不代表全效能矩陣通過。

三資料集受控記憶體矩陣已執行完成：128／192／256 MiB 各三次對照，54 個受限
worker 中 48 完成、6 次 Akasha 初始化 OOM，無逾時；配對品質 84/108、速度
57/108，整體 FAILED。另有 6 個 6 GiB 控制 worker。所有完成者共 14,472 exact
checks／110,592 timed response checks 通過。Akasha 9 格、Qdrant 28 格各自具
持續壓力證據，但同一 cap／trial 雙方皆符合者為 0/108；owned exact 向量仍無
非駐留證據。這是 emulated Linux 結果，不能列為 native Linux performance。

未完成：M5/M6 逐格速度與記憶體容量門檻、雙方持續 non-resident 對照，以及尚未
執行的環境／整合 gate。Qdrant 門檻已定案：相同 recall 下，
**每格 QPS ≥ Qdrant 且 p95 ≤ Qdrant**，不能跨格抵銷。

最新採用既有 `c00494f` 的四候選 F32 HNSW 實作，只移植三個來源檔與兩個測試。
同批暖查詢速度 16/36 → 19/36、mixed 15/36 → 19/36，前後品質皆 36/36，無
通過轉失敗格；real-1536 九格暖 ANN QPS 提高 21.6–40.1%、p95 皆降低。
所有 exact 波動、mixed selective 尾延遲退步均保留；write + flush 仍僅 3/9。
97 Mojo、完整 Python 356、C ABI、三個範例通過；Linux 模擬另通過 31 Mojo。
此結果不能與其他批次直接計算效能差值，完整 M5/M6 仍 FAILED。

工作目錄：`/Users/ray/Projects/Akasha`，分支 `main`。
`.build/m5-resume/` 保留重建資料庫、隔離 binary 與所有實驗。
本檔僅作入口，不另設與 `tasks/todo.md` 重複的 checklist。
