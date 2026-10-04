# Native F64 四候選 rerank

現有 named profile 的 uniform-1536 all 約24.95%搜尋 samples在 native F64 metric；
`field_metrics._numeric_score` 每次只處理一個候選，按 component 依序加總。
依 [既有 profile](../benchmarks/2026-10-04-named-cache-final.md)和現行原碼，這是
沒有 widening 時仍存在的成本。原 scalar 函式保留作為數值 oracle 與尾端路徑。

核對本地 Faiss `faiss/utils/simd_impl/distances_autovec-inl.h:96` 的四候選獨立
accumulator 模式；只採用跨候選並行的形狀，不採用其 imprecise math 設定。
Akasha 使用四個F64 lane，每列維持原 component 加總順序，不在component間重排
reduction。Dot／L2／cosine、五種native scalar都須逐bit等同現有函式。

隔離實作只增密集欄位四候選metric helper，接入 named ANN global rerank，每批四個
候選，尾端沿用現行函式。維持每筆 location／field／control 檢查與global budget，
Span／List borrow保留真正owner。Binary／sparse／MaxSim與HNSW距離路徑不受影響。
不是先前被否決的F32 prepared HNSW rerank或forced-inline原型。

驗證順序：五scalar／三metric、多dimensions與極值的bit parity及維度／zero cosine
錯誤；微量測只作診斷；再跑相關named／rerank／query control測試、原三corpus／
三trial完整named曲線。需要採用才補相應整合及原Qdrant驗收；不以此單一診斷勾選
M5/M6。資料、seeds、filters、K、efs、trials、service boundary保持原樣，所有慢
sample、recall failure及編譯失敗均保存。build/test/benchmark/compression串行。

起點`f0572f5`；隔離目錄`.build/2026-10-04-native-f64-four`。
已核對Mojo1.0.0 (`ed45d567`)，Apple M4／Metal:4。
