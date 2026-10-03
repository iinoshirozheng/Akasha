# 2026-10-03 續作狀態

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
