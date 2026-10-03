# AkashaDB 工作入口

目標是完成 [tasks/todo.md](tasks/todo.md) 的 M5／M6；**目前尚未完成**。
`tasks/todo.md` 是唯一工作 checklist，歷史報告的缺口與測試數不能當成現況。

## 最新工作包（2026-10-03）

已採用 named HNSW 的完整單一 run 快取：flush／close 保存已建好的圖，重開時驗證
欄位、設定、ID 與向量內容，再重新綁定 ordinal。忙碌的 builder／query 會略過保存，
不等待其鎖；查詢與 held snapshot 不寫快取。多 run 更新後重開仍可能重建。
[實作、每個 trial 與完整證據](docs/benchmarks/2026-10-03-named-hnsw-cache.md)。

正式 `python/akashadb/_kernel.so` SHA-256：
`843186a731ceefaa38e6e5780a0eb13c180dcdc9525191d53f5c8ba0d89d79ba`。
Frozen archive SHA-256：
`8677fec577201dbef6d184f47d6255871f2c98ccd12a46ac676d9dbe75a73356`。

第一版 77 targeted Mojo／1 targeted crash／376 完整 Python／C ABI／3 examples；
最終鎖修正另通過 47 targeted Mojo／376 完整 Python／C ABI／3 examples。正式 package
再通過 125 targeted Python 與重建 C ABI/client。未重跑完整 Mojo／crash／Linux／GPU。
不同階段不加總成一輪完整整合；TestSuite 時間是毫秒。

三資料集各三次配對的 14,472 組 ID／F64 bits／stats 一致，28,944 ANN audits 與
4,824 exact oracle checks 通過；兩版各保留 84 個低 recall 曲線格。最終版 resident
重開首查約 87–339 ms，原版約 6.9–32.5 s；首次 flush 變慢，36 個選定暖查詢格仍有
24 格 QPS 或 p95 退步。這是 named 診斷，**不等於 Qdrant parity**。

## 剩餘驗收與固定門檻

M5 尚有首次建圖、多 run／更新後重開的 named artifact 生命週期成本。M6 須完成
原定全部暖查詢、混合維護、HTTP／並行與 resident/nonresident／memory-limit 矩陣。
使用者目前沒有原生 Linux runner；不要重問或自行配置付費資源。

門檻已定案：共同 Recall@10 ≥ .95，每一格／trial **QPS ≥ Qdrant 且 p95 ≤ Qdrant**，
無容許差距、不跨格抵銷、不刪慢樣本、不改 fixed corpora/seeds/filters/K/efs/service
boundaries。`.99` 曲線只作診斷。IVF 低 probe、MaxSim 小候選集的 recall 失敗仍保留。

上次正式 HTTP gate 為 22/108 strict parity（兩版各 108/108 recall，含 2 格 pass→fail），
[報告](docs/benchmarks/2026-10-03-http-dispatch.md)。原 binding warm／mixed 最近採用
結果為 20/36、32/36，皆 FAILED；它們早於後續 named/native 改動，沒有重跑成現行
binary 的新 gate。先前 distributed 功能 10/10 通過，不代表 HTTP 效能達標。

## 閱讀順序與執行規則

1. `AGENTS.md`、`/Users/ray/.codex/RTK.md`，以及修改 Mojo 前的 `mojo-syntax` skill。
2. [唯一 checklist](tasks/todo.md)、[原驗收計畫](tasks/plan.md)。
3. [最新 named cache 報告](docs/benchmarks/2026-10-03-named-hnsw-cache.md)及
   [10-03 各工作包狀態與測試範圍](docs/handoff/2026-10-03-status-and-tests.md)。
4. [10-02 原交接](docs/handoff/2026-10-02-status-and-tests.md)與
   [已完成的 Git 交付](docs/handoff/2026-10-02-git-delivery.md)。

工作目錄 `/Users/ray/Projects/Akasha/.worktrees/production-hnsw-plan`，分支
`feat/48-bounded-generation-head`。原 10-02 交付已由 `eef8dab` 合併並 push 至 main，
不要重做；後續工作按語意分別 commit，目前未再次 push／merge。

所有 shell 命令以 `rtk` 開頭。Mojo 1.0.0 (`ed45d567`)，Apple M4／Metal:4；
Python／child compile 繼承 `.build/compiler-bin` wrapper PATH。Benchmark 必須串行，
不與 build/test/archive compression 重疊；tests 期間不覆寫 native worker。
Isolated binding 從複製的 source 與 binding entry 編譯；saved-package pytest 使用
`-o pythonpath=` 並核對實際 import。保留未提交修改與全部失敗樣本；`.build` 是暫存，
凍結 archive 不改寫，舊 driver 不盲目原地重跑。既有仍適用的測試結果沿用。

下一步持續處理 M5 剩餘生命週期與 M6 失敗格的實測瓶頸；先確認成本，不直接刪除
validation，也不重做已否決原型。ASan runtime、原生 Linux 與新 GPU device gate
沒有新通過結果。交接、commit 或 merge 都不代表原任務全部完成。
