# 2026-10-03 續作狀態

最新採用 HTTP search 的單次 worker 排程，保留原 response validation。正式 package
41 targeted Python 通過；native binary 仍為 `2d5e8e09…`。三方對照的 strict parity
為前版 14/108 → 採用版 22/108，兩版各 108/108 recall；有 2 格 pass→fail，整體 FAILED。
[HTTP 排程實作與完整樣本](../benchmarks/2026-10-03-http-dispatch.md)。M5/M6 未完成。

最新補齊原生 HTTP／並行 1/2/4 clients 的完整量測：108/108 recall、16/108 strict
parity，整體 FAILED；24,120 query audits 全通過。33 targeted Python tests 與
兩個實際 server smoke 通過，production engine／binary 仍為 `d38bffa`／`2d5e8e09…`。
[HTTP 工作包與完整證據](../benchmarks/2026-10-03-http-parity.md)。M5/M6 尚未完成。

最新採用 native F64 dense／MaxSim 的等長 Span iterator：保留原累加次序、
numeric validation 與 owner；省去逐座標錯誤訊息準備。僅拆 metric 迴圈的候選未採用。
正式 Python binary SHA-256：
`2d5e8e0910d4d81d84699e5bc023ba9824a5f9ab867b613cc6bcefcc7bcc0463`。
31 targeted Mojo／358 完整 Python／C ABI／三個範例通過；正式 package 再通過
7 score-bit Mojo／91 Python／C client。沒有重新跑完整 Mojo／crash／Linux／GPU。
獨立 named 診斷的 4,824 配對樣本 ID／F64 bits／stats 相同，高維 uniform QPS
提高約 7–13%、real 約 4–20%；首輪 128D all 退步仍保留。另三次完整 128D 曲線
的 all 均改善，但 selective 仍有 QPS／p95 退步，不能以中位數蓋過。
[實作、各次樣本與驗證](../benchmarks/2026-10-03-native-metric-loops.md)。Frozen archive SHA-256：
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
[實作、完整樣本與限制](../benchmarks/2026-10-03-named-run-hnsw.md)。Archive SHA-256：
`6115ca3fc12be54c10044c6148dd1f0b453a5eaaff99105dc08ad2531fee2899`。
容量修正與最新測試 archive SHA-256：
`99ba7da9d2305e80fec6de02e2bd98acf036116308c763d3a35881e884eaa2bf`。
**M5/M6 保持未完成**；未重跑原三次 Qdrant 矩陣，也未完成 nonresident／memory-limit
與 concurrent-client parity。使用者已確認目前沒有原生 Linux runner。
下一步處理小 run 建圖／查詢成本及首次重開的 named artifact 生命週期。

以下保留本次採用前的紀錄，當時的引擎／binary 並非最新狀態。

後續 delta scan 四列候選未採用：101 targeted Mojo／358 Python 通過，但 warm
23→22/36、mixed 28→29/36，合計三個 pass→fail，受影響 ANN 收益不穩定。
保留三項 scalar-oracle 回歸與[完整證據](../benchmarks/2026-10-03-delta-scan-groups.md)；正式引擎仍為
`a57f11a` / `b183b880…`。這是獨立實驗，不取代或合併前次通過格。M5/M6 未完成。

先前採用[篩選 exact scan 的兩列 checked F32](../benchmarks/2026-10-03-paired-exact.md)：
99 targeted Mojo（94 個 final isolated source＋5 個 promotion 後 kernel tests）、
358 完整 Python、C ABI/client、三個範例通過；promoted package 的 3 個新增 Python
cases 也通過。未重跑完整 Mojo／crash／distributed。正式 binary SHA-256：
`b183b8805e8b7cf29b86cf443e1898befebac4cd77844680944f853461422412`。
Warm 19→20/36 有兩個 real-all pass→fail，mixed 29→32/36 無 pass→fail；仍 FAILED。
完整保留全 live set／ANN 退步與未採用的 universal pairing，不能跨格抵銷。
Archive SHA-256：`3e80c14a01efcfca271a8c22199483d3b0257c7dea1b75d4ab18c3f0a5045e7a`。
Archive 中新 profile 是 promotion 前 `c00494f`，real ANN mapped four-row 占
31–36% 主執行緒樣本；不是新 candidate 的效能驗收。原生 Linux runner 目前沒有，
M5/M6 未完成。以下按時間保留先前結果。

前一採用 [鎖外回收基線上的四列 F32 HNSW](../benchmarks/2026-10-03-batch-after-reclaim.md)：
174 targeted Mojo／355 Python／C ABI/client／三個範例通過。正式 binary SHA-256：
`7b42e740846e03d99291b38a4c94c3b0b54fa47ba75a34ab889baada6c68f822`。
Warm 18→22/36、mixed 23→26/36，仍有一個 mixed pass→fail，整體 FAILED。
真實 1536D mixed 九個 ANN 格 QPS/p95 皆改善，其他退步完整保留；不是全面 parity。
Archive SHA-256：`587aab62755ff3643d723c1dc9c5a0f5305ee8bb615f5f681d00ec1e8464a03f`。
M5/M6 未完成，接續定位 exact scan 成本。此輪未重跑 crash／distributed／完整 Mojo。

前一採用包 [compaction 鎖外回收](../benchmarks/2026-10-03-unlocked-reclamation.md)：
81 targeted Mojo（74 既有＋7 新增）、21 related crash、355 Python、C ABI/client、
三個範例皆通過。正式 source 已包含此改動，Python binary SHA-256 為
`3610e3022391e9d8731178781e2a002d273ba134055cd259e7939bb1e75b0c1c`。
Warm 16→16/36、mixed 27→28/36，無 pass→fail，仍有 p95 退步且整體 FAILED。
該包完成時四列 F32 候選仍保持隔離；後續獨立重評結果見上方最新紀錄。
本包 archive SHA-256：`83b77cf3ddec1a91101e560d9566b86dbcf6e0cf7a3430fd272fae17901a0f49`。
以下按時間保留先前結果，不能把早期「正式 source/binary 不變」當成現況。

本輪補完原先被 sandbox 阻擋的 distributed gate，新增三個 default-vector scan
回歸案例；兩個效能原型因公開查詢退步撤回。**M5/M6 尚未完成**，唯一 checklist
仍是 [tasks/todo.md](../../tasks/todo.md)，門檻保持每格相同 recall 下 QPS ≥ Qdrant、
p95 ≤ Qdrant，不跨格抵銷。

## 正式產物與提交

- 工作目錄與分支沿用 10-02 交接。
- `3b10af6`：single-borrow 原型與三個 metric-parametrized 回歸案例。
- `717e240`：撤回原型，只保留測試；正式 Mojo source 對 `a710aa5` diff 為空。
- 隨後的 docs commit 收入本輪量測、原始證據及本文件。以上為本地提交，尚未 push
  或再次 merge；10-02 的交付已完成，不重做歷史 merge。
- Python `_kernel.so` 已恢復原 SHA-256：
  `3ccdc28c64b16c26277649c1d890c552b437ad357fde30b02067f03a115b3401`。
- C ABI 已由恢復後來源重建並通過 client。無進行中的 build／test／benchmark。

## 驗證與決策

還原後同一次 pytest 執行 **365 passed = 355 Python + 10 distributed**，零失敗或
錯誤、3 個 warnings，16.26 秒。Distributed localhost 服務能正常啟動；這補完功能
gate，不等於完成 concurrent-client 或 HTTP 效能對照。

新增測試涵蓋 Dot／L2／Cosine，filtered/unfiltered exact 與 planned scan，包含
named-only、空 sparse、default field 補入／移除、刪除與 flush/reopen。
它們在基線與原型均通過，驗證既有合約未變。

未重新跑完整 Mojo、crash 或 examples；引擎已恢復既有驗證版本，沿用
[10-02 證據](2026-10-02-status-and-tests.md)。原型期間的 30 targeted Mojo、355 Python
及 C ABI 屬原型證據；不能把 direct-slot 的額外 14 Mojo 加成正式版整合數字。

Single-borrow 暖查詢基線／候選為 **16/36、17/36**，mixed **24/36、24/36**。
雖然 128D all QPS 提高，128D correlated 的兩次 p95 退步到 **2.219×、1.987×**；
那是受影響的 exact scan，不能說成未改 ANN 路徑的波動。直接 slot-zero 候選的暖查詢
為基線 **19/36**、候選 **18/36**，也未採用。所有查詢品質、score bits／ID 比對及
mixed reopen／lease 檢查通過；速度失敗與慢樣本完整保留。

兩個暖查詢實驗各有 27 workers、6,912 timed audits、7,236 exact checks；mixed
有 27 workers、7,776 audits、27 reopen、18 Akasha leases。它們是獨立實驗，不能
相加稱為一輪完整矩陣。[逐格結果與可攜 archive](../benchmarks/2026-10-03-default-vector-borrow.md)。

## 下一步線索與限制

Profile 已保存到 archive：128D exact 的欄位查找／取值占不少樣本，但兩個相應原型
沒有通過公開效能驗收，不要未有新假說就重做。Real ANN 的主要樣本在 mapped／owned
distance kernel；全部 query norm／value validation 合計約主執行緒樣本的 6.7%，
其中包含必要驗證，沒有量出「重複驗證」的獨立成本或呼叫計數，不能據此刪除檢查。
舊 prefetch rejection 位於 `docs/benchmarks/results/2026-10-01-hnsw-prefetch.json`，
需與 10-02 交接列出的 rejected probes 一起參考。

持續 nonresident／controlled-memory、concurrent-client／HTTP parity、整體逐格速度
門檻仍未完成。主機 Docker 可用，但 daemon 是 Linux ARM64，現有 pixi image 為 AMD64，
repo lock 只有 macOS ARM64／Linux x86-64；本輪沒有在模擬架構上測量或宣称 native
Linux performance。沒有新 ASan runtime、Linux runtime 或 GPU device gate。

## 重現

指令與 archive hash 見 [量測報告](../benchmarks/2026-10-03-default-vector-borrow.md)。
本地最終測試檔：

- `.build/2026-10-03-resume/restored-python-network.xml`／`.log`
- `.build/2026-10-03-resume/restored-c-build.log`／`restored-c-test.log`
- `.build/2026-10-03-resume/restored-identity.json`

Archive 也保留原型期間的 `production-identity.json`，那是暫時安裝原型時的紀錄；
以 `restored-identity.json` 為最終來源／binary 狀態。歷史 archive 保持不變。
所有 benchmark 必須串行且不與 build／test／壓縮重疊；新量測使用新輸出目錄。

## 後續：owned F32 summary（未採用）

隔離候選通過 94 targeted Mojo；Python 354 passed／1 optional dependency skip，
補入 pinned Qdrant 後該檔 16 項通過（不是 370 個 unique tests）。Warm 21→20/36、
mixed 25→25/36，均有 pass→fail 格；全部品質與 score-bit audits 通過。候選未採用，
正式 source/binary 從未替換。初次 Python 未啟用 pixi 的編譯器環境失敗也已保留。
[完整報告與 immutable archive](../benchmarks/2026-10-03-owned-f32-summary.md)。

## 後續：HNSW query 驗證與 A/A／GC 診斷

[完整量測與 archive](../benchmarks/2026-10-03-query-validation.md)。候選 143 targeted
Mojo／355 Python 通過，但 warm 19→17/36、mixed 32→30/36，未採用；正式來源與
binary 仍不變。保留 2 項 public query boundary 回歸，已在 production source 通過。
同來源重建 A/A 為 17→17/36，相同 binary/package 的 A/A 為 18→15/36；資料皆保留，
不能把失敗格當成噪音刪除。GC 每資料集影響 5 筆 timed query，但多數最慢樣本沒有 GC。
後續應檢驗主要 mapped distance 成本，不再憑小幅單格變動採用候選。已詢問是否有
可用原生 Linux x86-64 runner 以完成受控 memory-limit／持續 nonresident gate；
使用者回覆目前沒有可用 runner；本工作包沒有完成該 gate。

## 後續：四列 distance 與 compaction 持鎖成本

[完整量測與凍結證據](../benchmarks/2026-10-03-four-distance.md)。隔離 candidate
147 targeted Mojo／355 Python 通過，warm 16→18/36、mixed 30→27/36，未放入正式
source/binary。保留新增 grouped-admission 順序測試（也在 baseline 通過）。所有
ID、score bits、stats、execution 相同；不排除四個 mixed pass→fail。
CPU/GC 與 lock trace 將 mixed 慢樣本定位到背景 compaction；publish 內的舊檔回收
含 directory sync 花 256–618 µs，durable manifest 發布花 181–276 µs。
下一步獨立驗證鎖外 reclamation；不可省略 manifest durability、file lease 或 error retry。
