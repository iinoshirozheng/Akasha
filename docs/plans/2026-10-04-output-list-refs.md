# Python回傳容器ownership修復與原矩陣驗證

基線`ba33618`，核心engine`1318457`，Mojo1.0.0/Python3.11。唯一checklist仍是
[tasks/todo.md](../../tasks/todo.md)，M5/M6未完成，無Linux runner。

12個正式輸出路徑probe均有額外reference；新增weakref marker cases確認結果被
caller丟棄後仍存活。Mojo1.0普通call／__setitem__的owned-ref處理是已定位原因。
先以compiled probe驗證既有`Python.list(Span[PythonObject])`釋放元素，再以local
Mojo List owner組裝原query／schema／get／export／native vector輸出，shape與bits不變。

Nested named vectors／export sparse與scanner metadata的dictionary assignment改用
既有CPython.PyDict_SetItem；private helper借用三個owner，保持至呼叫返回。
Binary bytes constructor沿用同一Python callable，用既有vectorcall機制避免保留
temporary list，保留error與callback。只改兩個binding檔，未改engine／格式／worker。
Arrow schema建構與其他普通call仍須另查，不宣稱全binding無洩漏。

依序跑red/green窄測試、完整saved-package Python、原18-worker named curves與
54-worker before/after/Qdrant resident矩陣。原corpora/seeds/filters/K/ef/queries/
trials/service boundaries與40秒deadline均不變；超時後才native capture，不替換trial。
所有build/test/bench/compression串行，沒有測試期間重建worker。

只依實際結果決定採用；A/B退步與低recall全保留，不另設每個A/B必須改善的門檻。
M5/M6仍需每格Recall@10≥.95、QPS≥Qdrant、p95≤Qdrant，不能跨格抵銷。
