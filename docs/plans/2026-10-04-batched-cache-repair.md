# 每個受影響中心只修復一次的 private cache 候選

M5/M6 未完成；本方案已在 `.build/2026-10-04-batched-cache-repair` 隔離實作，
完成三 corpora／三 trials 後**未採用**，正式 engine 仍為 `cc15f37`。
[實測計數](../research/2026-10-04-refresh-work.md)顯示 38,256 neighbor repair jobs
只有 8,210 個不同 center/level，reciprocal connect 占 47.43% distance calls。
[retained-base/delta](../benchmarks/2026-10-04-named-overlay.md)雖降低冷查詢成本，
暖查詢仍因 stale base traversal 退步；不再原樣擴大這兩個被否決候選。

## 最小設計

從已保存的 private point-refresh source 建另一隔離目錄，維持正式版本作 before。
只改 private named cache reconciliation，public upsert 的 append/replaced-history
契約不動；不新增公開參數、score cache、配置層或 fallback。

1. 從目前 authority 的 sorted rows 找出 changed existing IDs，與新增、移除分開。
   先驗證 ID／輸入／prepared representation，收集原圖中受影響的 current
   `(slot, level)` 鄰居並去重、固定排序。Slots／IDs／level 不變。
2. 一次準備所有 changed point 的 private overwrite，再讓每個 affected center/level
   只做一次 local repair。候選取該 center 當時 current graph 的一／二跳範圍，
   使用原 construction ef、checked pair distances 與 neighbor heuristic。
   這會改變 topology，不能宣稱與逐點版結果等價，也不能假設計數去重等於速度提升。
3. 保留既有 inactive navigation bridges，刪除／新增邊都使用原 reciprocal operations；
   不直接覆寫單向鄰接表。最後依固定 ID 次序，以原 search/heuristic reconnect 各
   changed point，維持 bounded symmetric links。
4. 沿用 QueryControl 的 preparation／每個 center／reconnect checkpoints，任何
   post-mutation failure 都 quarantine private owner，不得發布 partially repaired graph。
   保留 source identity、全部 current-vector coverage、既有 rebuild thresholds、
   snapshot ownership、query/writer locks 與 atomic optional-cache publication。
5. 在新候選移除被取代的逐點 private entry，而不是疊一層相容 wrapper；原被否決
   source/binary/archive 全部留在舊隔離目錄。No-owner raw Span、改 validation、
   放大 rerank budget、降 recall／ef 等都不在此方案內。

需要依原 calls/tests 選最窄的批次入口，避免為這個工作新增一般化抽象。Qdrant 的
once-per-center 排程是參考；它的 deletion-shortcut 與 link assignment 不是可直接
照搬的實作。沒有足夠證據前不做跨向量版本的 pair-distance memoization。

## 驗證順序與停止條件

先以窄測試證明 overlapping updated neighborhoods 不會重複排同一 center/level，
並驗證 prepared bits、slot/level/current flags、對稱 degree bounds、determinism、
entry/sole-live、inactive bridges、invalid input、cancel/deadline 與 failure quarantine。
同時確認 public mutation 路徑原語意未變。

再跑 named/native 的 55 metric/codec 組合、cache save/reopen、舊 snapshot 與原
rerank budget；從複製 binding entry 編譯，saved-package pytest 使用 `-o pythonpath=`
和 import/hash guards。依實際 persistence 變動補相關驗證，沿用未變動的證據。

先比較同一 uniform-1536 原完整 grid 的實際 repair 工作、首查、暖查詢與 recall。
所有失敗與原 samples 保留。首輪 79 targeted Mojo／388 Python 通過，native
distance calls 減少 63.8%；uniform-1536 首查 33.06→19.79 秒、quality 9→9/24，
但四個選定暖格均退步。這是 named A/B 診斷，尚未執行 Qdrant gate。

2026-10-04 更正：先前「任一 selected warm A/B 退步即不擴大／不採用」是本方案
自行加入的停止條件，不是使用者要求。正式門檻仍是原固定矩陣逐格 QPS ≥ Qdrant
且 p95 ≤ Qdrant；不能把兩者混為一談，也不能用冷查詢改善抵銷正式失敗格。
保留本次全部 A/B 退步，並已完成三 corpus／三 trial 的生命週期曲線：
28,944 ANN audits／4,824 exact checks 通過，fixed recall 132→129/216，
三個 uniform-128 independent／ef128 格新增失敗，23/36 選定暖格退步。
首查三 corpus 均降低，但更新修復成本與品質退步尚未解決；候選未採用，沒有
新完整 Mojo／crash／C ABI／examples 或 Qdrant gate。原正式矩陣沒有 named adapter，
不能將 named 曲線拼接到 default-field 的 Qdrant 數字上宣稱 parity。
不得以一次計數診斷或單格改善宣稱 M5/M6 完成。Linux runner 仍不可用。
