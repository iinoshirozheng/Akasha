# HNSW heap 單向搬移實驗

起點 `ac48cda`，正式 Python `80ddc239bc711b5b5c52acc44e9f705825cabac31b4d646503597ba1aa3e2155`。
原 warm gate 的 real-1536 correlated／independent 為 ANN 且失敗；uniform-128 all
為 planned exact，不能把其落後歸因於 HNSW。新的三個 native profiles 完成68,672
次 repeat IDs／F32 bits／stats 比較；兩個 real 格 heap exclusive samples約5%，
距離計算47–48%。這個實驗只能處理其中一小部分，不預設能完成M5/M6。

現有 `CandidateMinHeap`／`ResultMaxHeap` 每層 sift 使用兩個 List element 交換。
本地Qdrant透過Rust BinaryHeap處理 frontier與bounded results；Rust官方實作使用
保存待移動元素、逐層搬移父／子、最後填回的方式降低搬移量：
<https://doc.rust-lang.org/src/alloc/collections/binary_heap/mod.rs.html#792-930>。
沿用Akasha的List、完整比較規則、容量／reserve／clear／root replacement／錯誤
契約，只改一個既有檔案的sift內部。無unsafe pointer、未初始化storage、額外配置
或新abstraction；不是重做已否決的Mojo官方heap API替換。

先以獨立排序oracle測試交错push/pop、clear/reuse、變動capacity、singleton、
negative IDs、tertiary slots、signed-zero bits及finite extremes；baseline也必須通過。
再驗證layer／scratch／filtered／owned/mapped／mutations等受影響路徑，建置copied
binding，保留原54-worker warm/mixed/Qdrant矩陣及named完整曲線。若值得採用才
擴展Python／C ABI／examples；所有timing退步、recall failure與失敗實驗均保存。
Mojo1.0.0 (`ed45d567`) 已核對，所有build/test/benchmark/compression串行。
