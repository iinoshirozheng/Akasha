# AkashaDB 工作入口

目標是完成 [tasks/todo.md](tasks/todo.md) 的 M5／M6；**目前尚未完成**。
`tasks/todo.md` 是唯一工作 checklist，歷史報告的缺口與測試數不能當成現況。

## 最新採用（2026-10-04）：filtered HNSW inactive radius

已修正 deleted/replaced slots 占用 filtered navigation radius、導致全允許 filter
也可能提早停止的缺陷。唯一 engine 改動為 `hnsw_core.mojo`，新增三個重現測試。
119 targeted Mojo／388 完整 Python／C ABI／3 rebuilt examples 通過；採用後同一
binary 的 3 Mojo／8 server tests／C client／3 examples 再驗證通過，不重複加總。
[修正、全部矩陣與證據](docs/benchmarks/2026-10-04-live-filtered-radius.md)。

正式 Python kernel SHA-256：
`609aeb2b0d721cbc1d84f6aec1bd325a360484cfa72d207600313b342c5cd8d9`。
Frozen archive SHA-256：
`77ae0191f6ebbe08689c184c9f6cc0aa5686480ca0f102e98a5bb29f159c53ce`。
固定三方 warm 19→22/36、mixed 19→19/36、write+flush 3→3/9；recall 各 36/36。
有兩個 performance pass→fail，全部保留，**整體 FAILED、M5/M6 未完成**。未重跑
完整 Mojo／crash／HTTP performance／Linux／GPU／ASan／nonresident gate。

較大的 named cache reconciliation 候選仍未採用。接續處理其更新後重開與暖查詢
成本，以及原 M6 失敗格；以下各段為先前工作包的證據，不代表新版完整整合。

[後續 private point-refresh](docs/benchmarks/2026-10-04-cache-point-refresh.md)
亦未採用：113 unique targeted Mojo／388 Python 通過。單次 uniform-1536 完整
ef/filter grid 中，slot 9,011→8,192、暖 QPS 快 3–9%、quality 9→9/24 無新增失敗，
但更新後重開首查 4.90→53.58 秒。另 native profile 確認修復的主要成本，全部
失敗與樣本已凍結。正式 source/binary 不變；下一步查既有 retained-base／delta
能否沿用到 named lifecycle，不擴大或盲目重跑此候選。這不是完整 Qdrant 矩陣。

[既有 base／delta 成本探針](docs/benchmarks/2026-10-04-named-overlay-cost.md)
三次均通過：相同 graph／819 updates／205 deletes 的 primitive 更新 4.42–4.46 秒
降至 1.33–1.34 秒，47,922 current-vector audits／73,608,192 component bits 通過；
append 圖與前次逐 byte 相同、segmented base 未改。這不是 named query／recall 或
Qdrant gate。下一步依 [接合設計](docs/plans/2026-10-04-named-overlay-design.md)
先補 scored candidates，維持原全域 rerank budget，再隔離驗證 cache 生命週期。

[搜尋修正後的新生命週期比較](docs/benchmarks/2026-10-04-named-cache-final.md)：
18 workers／28,944 ANN audits／4,824 exact checks 完成，fixed recall 132→135/216、
無 pass→fail，但 30/36 暖 timing 退步；快取候選仍未採用。另 8 個 native profiles
通過 53,312 ID／F64 bits／stats audits，同 ef 多 10–13% 距離計算，selective 主要
成本在 HNSW。無新 source/test/binary 修改；下一步評估降低歷史 slot 遍歷成本，
不移除檢查或改固定 gate。Frozen archive SHA-256：
`6d02ac803f9e81b99e44325a044eea38e5bb3a7f1816c462808a63741c603c01`。

## 前一採用（2026-10-03）

已採用 Python 向量轉換時每次只查找一次驗證函式／類別；每個 component 的型別、
bool 排除、數值及範圍檢查保持不變。唯一 source 改動為 `src/bindings/point_values.mojo`。
[實作、profiles、所有 trial 與證據](docs/benchmarks/2026-10-03-python-vector-validation.md)。

該版 `python/akashadb/_kernel.so` SHA-256：
`53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6`。
該工作包 frozen archive SHA-256：
`de892118a0f539d3e0439a53ca261ddda53751d19080148b19078c80e2a87c57`。

12 項新增 protocol／原子拒絕案例在基線與候選皆通過；候選 **388 完整 Python**、
採用後 **129 targeted Python** 通過。引擎／C ABI／worker 未改，沿用前一工作包證據，
本輪未重跑完整 Mojo／crash／C ABI／examples／Linux／GPU。不同階段不加總成完整整合。

Named resident 的三資料集各三次完整六 ef 曲線，14,472 paired ID／F64 bits／stats
相同，28,944 ANN audits／4,824 exact ID oracle checks 通過，兩版各保留 84 個低
recall 格。36 個選定格 QPS 全提高、30 格同時改善 p95；另外 6 格 p95 退步保留。
這是 named 前後診斷，**不等於 Qdrant parity**。

前一採用為 [named HNSW 完整單一 run 快取](docs/benchmarks/2026-10-03-named-hnsw-cache.md)：
flush／close 保存 ready graph，重開驗證 identity、ID／向量並重綁 ordinal；busy lock
略過保存。該包 47 targeted Mojo／376 Python／C ABI／3 examples 的最終驗證仍適用。
同一 binary 的載入／重建診斷確認圖檔與查詢 bits 相同，但仍有 25/36 暖格退步；
持續查詢沒有建立載入方式的因果成本，未因這個診斷改動圖解碼。

## 2026-10-04 CPU 整合 checkpoint

現行 `3a5ad04` 完整 **141 檔／1,001 Mojo、8 檔／23 crash、3 個重建 examples**
與既有 C client 全通過；同 binary 的 388 完整 Python／129 targeted 結果沿用。
跨程序 reader 的首輪 launcher 失敗與來源模式 9/9 重跑均保留；沒有修改 source/test。
[範圍、重現與完整證據](docs/research/2026-10-04-cpu-integration.md)，archive SHA-256：
`5b02346d8b6693dfc69855e611fbaf1c46717f21d81f1ac6b259784859f11043`。
M5/M6 仍未完成；現行 binary 的固定 warm／mixed／HTTP gates 已重測如下。

## 剩餘驗收與固定門檻

M5 尚有首次建圖、多 run／更新後重開的 named artifact 生命週期成本。M6 須完成
原定全部暖查詢、混合維護、HTTP／並行與 resident/nonresident／memory-limit 矩陣。
使用者目前沒有原生 Linux runner；不要重問或自行配置付費資源。

門檻已定案：共同 Recall@10 ≥ .95，每一格／trial **QPS ≥ Qdrant 且 p95 ≤ Qdrant**，
無容許差距、不跨格抵銷、不刪慢樣本、不改 fixed corpora/seeds/filters/K/efs/service
boundaries。`.99` 曲線只作診斷。IVF 低 probe、MaxSim 小候選集的 recall 失敗仍保留。

2026-10-04 前一 binary 的獨立現況：warm **22/36**、mixed 查詢 **25/36**、HTTP **18/108**
strict parity；recall 各為 36/36、36/36、108/108。Durable write+flush **3/9** 通過。
三組量測及 audits 完整結束，assessment exit 1 是正確 FAILED gate。
[完整逐格結果與證據](docs/benchmarks/2026-10-04-current-parity.md)，archive SHA-256：
`2acea3566eae5e2d4fe34bd35d3f157f601a491ca587a96442bcfe17cdaa63e2`。
這是獨立現況矩陣，不與歷史實驗合併或宣稱 A/B 改善；先前 distributed 功能 10/10
通過，不代表 HTTP 效能達標。接續 profile uniform-128 all、real ANN 與高維維護成本。

後續 [payload buffer 候選與鎖停滯證據](docs/benchmarks/2026-10-04-payload-buffer.md)
**未採用**：67 targeted Mojo／388 Python／9 related crash／C ABI／3 examples 通過，
但三方 warm 19→18/36 出現兩個 pass→fail；mixed 24→29/36 不能抵銷。正式來源／
binary 不變。首輪原基線 worker 曾停滯於 BlockingScopedLock，124.97 秒後終止；
額外 13 次診斷與後續矩陣未重現，原因仍未查明。下一步優先重現並定位此鎖停滯。

後續 [鎖停滯診斷](docs/benchmarks/2026-10-04-baseline-lock-stall.md)：100 次原 binary
與 100 次隔離 owner 診斷各通過 28,800 audits／100 reopens／100 leases；20 項診斷版
背景維護測試通過，未重現異常。原部分資料庫複本恢復通過 9 個 exact oracle，序號
9424 已核對。**原因未解，未改正式鎖**。保留失敗；下一步獨立驗證高維 segment
逐值編碼的成本，不以成功重跑宣稱修復。

[Segment F32 bulk 候選](docs/benchmarks/2026-10-04-segment-bulk-write.md)亦未採用：
73 targeted Mojo／8 related crash／388 Python 通過；完整編碼 bytes 相同，微量測
變快，但 uniform-1536 flush p95 三次慢 4–8%。三方 warm／mixed 皆 19→18/36，
write+flush 3→3/9；保留全部退步。正式 source/binary 不變；下一步回到 real ANN／
selective query 的實際主要成本，不重跑已否決原型。

[Paired finite validation 候選](docs/benchmarks/2026-10-04-paired-finite-max.md)
未採用：新 selective profiles 確認 paired kernel 約占主執行緒 48–54%；縮小驗證
狀態解決第一版 cosine register spills，但 public warm 23→24/36、mixed 19→21/36
仍有五個 pass→fail，write+flush 3→3/9。89 unique targeted Mojo／388 Python
通過；保留三個已在基線通過的 exponent/lane 回歸。正式 source/binary 未變；
下一步處理 M5 多 run／更新後重開的 named cache 生命週期，不重跑此原型。

[Named cache reconciliation 候選](docs/benchmarks/2026-10-04-named-cache-reconcile.md)
仍未採用：115 targeted Mojo／11 related crash／388 Python／C ABI／3 examples 通過，
更新後重開首查約快 6–7 倍，但初版有 3 個 fixed-ef recall 退步與 28/36 暖格退步。
另定位 filtered HNSW 讓 inactive slots 占用搜尋半徑的既有缺陷；隔離修正通過
128 targeted Mojo／388 Python，固定圖曲線 129→135/216 recall 通過、無新增失敗，
但仍有 20/36 timing 退步。兩組完整 18-worker cohort 與全部失敗已凍結；正式來源／
binary 未變。下一步獨立驗證這項搜尋修正，再決定 cache 候選，M5/M6 保持未完成。

## 閱讀順序與執行規則

1. `AGENTS.md`、`/Users/ray/.codex/RTK.md`，以及修改 Mojo 前的 `mojo-syntax` skill。
2. [唯一 checklist](tasks/todo.md)、[原驗收計畫](tasks/plan.md)。
3. [最新 Python validation 報告](docs/benchmarks/2026-10-03-python-vector-validation.md)及
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
