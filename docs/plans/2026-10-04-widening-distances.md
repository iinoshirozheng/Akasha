# 隔離實驗：同操作 widening 距離重用

依 [正式單圖逐輪計數](../research/2026-10-04-named-partition-work.md)，named
uniform-1536 selective ef256 平均三輪、21,803 次距離計算；real selective ef128
平均 2.70 輪。不同輪次使用相同 prepared query、同一不可變 graph、同一 admission。
現有實作重置 traversal scratch，重新計算相同節點的已驗證距離。

已核對現有 `search_layer`、scratch、heap、widening、相關 tests，以及本地 Qdrant
`reference/qdrant/lib/segment/src/index/hnsw_index/graph_layers.rs:108` 的逐輪 visited／
score／radius 實作（reference 位於主工作目錄）。Qdrant 此入口沒有 Akasha 的外層
widening 契約，不能直接替換搜尋演算法。此實驗不引入新依賴。

最小候選只改 `hnsw_core.mojo` 和 `hnsw_scratch.mojo`：

- 原第一輪完全沿用未快取 specialization。確實需要第二輪才配置／重設 slot-indexed
  F32 距離表；NaN 為未計算，既有 checked kernels 只產生有效距離。
- 第二輪起可重用同操作距離；第一輪分數未保留。四列 group 只有全部命中才跳過
  kernel，部分命中仍執行原四列路徑，維持 reduction、lane、順序與 bits。
- 每個新操作首次 widening 都重設表；不跨 query、mutation 或 graph reuse。
  table 保留 capacity，每 slot 4 bytes；重設為 O(graph slots)，須量測而不假定免費。
- 原逐輪 boundary validation、edge validation、visited、admission、inactive radius、
  ef doubling、停止規則、exact fallback 及 rerank budget 不變。重用值曾在此操作內
  通過原 checked distance；沒有取消首次 row 檢查。cache specialization 仍檢查範圍。
- 公開 stats 保持最後一輪邏輯 scored-slot 計數；trace 另量實際 kernel 計算的列數，
  不以公開 counter 宣稱消除了多少物理計算。

先驗證跨 query、invalid query、visit epoch wrap、graph growth／tombstone，再跑
相關原測試。隔離 copied binding build；完整三 corpus／三 trial／原四 filter／六 ef
resident named grid 比對全部 IDs／F64 score bits／stats 與 recall，包含每個 raw sample。
量測與 build/test/compression 串行。只有有用且可維護的結果才考慮正式採用；之後仍須
相關整合及原 Qdrant gate，這個診斷本身不完成 M5/M6。

工作目錄 `.build/2026-10-04-widening-distances`；起點 `1b043c3`。
正式 source、binary、格式在實驗中保持不變。使用 Mojo 1.0.0 (`ed45d567`)，Apple M4／
Metal:4；不重跑已否決的 prepared rerank、query validation reuse 或 bundle 修復原型。

第一版完成 70 targeted Mojo 及原三次完整曲線：14,472 paired queries 的全部結果／
stats 一致，品質兩版132/216。高維 selective 有改善，uniform-128 selective 則三次
退步；尚未採用。逐輪插樁確認後者53/64筆只記錄、無第三輪重用，而高維兩格
實際交給距離 kernel 的列數分別減少34.79%與25.27%。

第二版 `.build/2026-10-04-widening-record` 只修正已知冷快取的額外成本：第二輪
使用 record-only specialization，第三輪以後才查找；若最多只能再跑一輪，完全
略過配置及記錄。沒有改候選或 widening 判斷，也沒有依 corpus／dimension 加閾值。
兩份 source、binary、測試與所有曲線各自保存，不覆寫第一版。

第二版亦完成70 targeted Mojo、18 workers、14,472 paired query bits/stats一致；
品質仍132/216，21/36選定格有QPS或p95退步。高維 selective 改善保留，但沒有
建立涵蓋其餘失敗格的收益，兩版未採用。[完整結果](../benchmarks/2026-10-04-widening-distances.md)。
這不是新增「任一A/B退步即否決」門檻；原逐格Qdrant門檻保持不變，尚未有新通過。
