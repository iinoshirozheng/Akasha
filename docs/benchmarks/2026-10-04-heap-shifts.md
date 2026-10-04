# HNSW heap 單向搬移：未採用

一個檔案的隔離候選通過 **122 targeted Mojo**，原 **54-worker Qdrant** 與
**18-worker named** 矩陣均完成。IDs、分數位元、統計與品質保持相同，公開查詢
沒有穩定收益，候選**未採用**。正式 engine 仍是 `ac48cda`，M5/M6 未完成。

## 先確認實際路徑與成本

起點 `ac48cda634a383de74a6d2a99e2e8b42ef0bcce4`；Mojo 1.0.0 (`ed45d567`)，
Apple M4／Metal:4。原 gate 的 uniform-128 all 是 **planned exact**，不是 ANN。
real-1536 correlated／independent 才是需要分析的 ANN 失敗格。三個新的正式版
profiles 完成 **68,672 次**重複 IDs／F32 bits／全部 stats 比較。

| Real ANN profile | Four-row distance | Single-row distance | HNSW heaps | Visit scratch | Query preparation |
| --- | ---: | ---: | ---: | ---: | ---: |
| correlated | 33.10% | 14.22% | 5.19% | 4.12% | 2.66% |
| independent | 34.34% | 13.92% | 5.02% | 4.17% | 2.05% |

表中是 query boundary 內的 **exclusive samples**，不是時間歸因的精確比例。
Tree parser 逐節點扣除子節點，總和核對完整 main thread；不因函式參數型別含有
`HnswSearchScratch` 就把整個 search layer 算進 visit。這兩格距離仍占主要成本，
heap 約5%，因此不預設小型 heap 優化能填滿 Qdrant 差距。

uniform-128 all 的 binding frame 被 tail-call elide，只剩2個可見 query-boundary
samples，不能使用該分母。其4,201個 main-thread samples 中，checked exact metric
37.09%、default-field lookup 23.52%、BoundedTopK 7.74%；Python／audit工作亦在
main-thread 分母中。這是路徑對照，不重做已否決的 default-field borrow 原型。

## 隔離實作與驗證

`CandidateMinHeap`／`ResultMaxHeap` 原 sift 每層交換兩個元素。候選保存原元素，
每層只搬移父／子元素，最後填回。比較順序、distance／ID／slot tie 規則、
reserve／clear／capacity shrinking、root replacement、錯誤與所有持久化格式保留。
沿用有 owner 的 List，沒有新增配置、unsafe pointer 或未初始化 storage。

本地 Qdrant 使用 Rust BinaryHeap 與 bounded queue；
[Rust 官方實作](https://doc.rust-lang.org/src/alloc/collections/binary_heap/mod.rs.html#792-930)
亦使用保存元素後填回的方式減少搬移。這只支持演算法選擇，不能證明 Mojo 生成
同樣有效率的機器碼。本候選不是先前被否決的 Mojo 官方 heap API 替換。

三個新測試先在 baseline 通過，再在候選通過：獨立 insertion-sorted oracle、
4,096次交錯操作、變動capacity、reserve／clear/reuse、singleton、錯誤不改既有
entries、負ID、tertiary slot、signed-zero bits、有限極值與正負infinity。
第一次測試的 List constructor 語法錯誤及原碼保留，修正後才執行 oracle。

候選13個檔案共 **122 unique targeted Mojo**：新測試3、heap9、scratch11、
search-layer14、filtered8、widening9、live-radius3、group-order1、mutation12、
quantized14、invariants14、segmented18、named6。TestSuite 時間是毫秒。
Copied binding 由 `after-src/bindings/python_module.mojo` 建置，與 source/binary
hash 核對。沒有新完整Python／Mojo／crash／C ABI／examples／HTTP performance／
Linux／GPU／ASan／nonresident／memory-limit gate；正式 worker 未改。

## 原始矩陣與全部失敗

Original corpora、seeds、filters、K、efs、service boundaries、三 trials 均保留；
Qdrant順序 B/A/Q、Q/A/B、B/A/Q，named順序 AB、BA、AB，使用fresh clones。
所有build/test/benchmark/compression串行。各cohort分開報告，不拼接歷史通過數。

| 原 Qdrant gate | 正式 baseline | 隔離候選 |
| --- | ---: | ---: |
| Warm matched recall ≥ .95 | 36/36 | 36/36 |
| Warm QPS 與 p95 strict parity | 25/36 | 23/36 |
| Mixed matched recall ≥ .95 | 36/36 | 36/36 |
| Mixed QPS 與 p95 strict parity | 15/36 | 14/36 |
| Durable write+flush parity | 3/9 | 3/9 |

五個 performance pass→fail 保留：warm uniform-128/trial1/all、uniform-1536/trial1/
selective、real-1536/trial2/selective；mixed uniform-128/trial1/all與trial2/all。
Warm 有25/36、mixed有22/36格A/B QPS或p95退步。這不是每項退步的因果證明，
也不能刪除發生在未改動路徑上的慢samples。整體 **FAILED**；assessment exit1
是完整量測後的正確 gate，不是程序中止。

Warm 7,236三方audits／7,236 exact checks，2,412 A/B IDs／stats一致，24,120
F32 bits一致；mixed 7,776三方audits，2,592 A/B IDs／stats一致，25,920 bits一致。
全部mixed workers通過reopen oracle與32 writes/flushes，兩個Akasha版本的
Arrow lease都跨close存活。

Named **14,472 paired queries** 的IDs／F64 bits／stats一致，**28,944 ANN audits／
4,824 exact checks**，fixed-ef品質 **132→132/216**，原有84個低recall格保留。
36個選定格中24格timing退步。三個trial的完整範圍如下，不能只取中位數：

| Corpus / filter | QPS after/before | p95 after/before |
| --- | ---: | ---: |
| uniform-128 all | 1.035–1.482 | 0.556–0.961 |
| uniform-128 correlated | 0.754–1.193 | 0.787–1.435 |
| uniform-128 independent | 0.779–1.311 | 0.777–1.309 |
| uniform-128 selective | 0.930–1.135 | 0.828–1.228 |
| uniform-1536 all | 0.993–1.007 | 0.998–1.011 |
| uniform-1536 correlated | 0.970–1.005 | 0.987–1.034 |
| uniform-1536 independent | 0.990–1.004 | 0.997–1.020 |
| uniform-1536 selective | 0.971–1.005 | 1.005–1.086 |
| real-1536 all | 0.885–0.994 | 1.065–1.482 |
| real-1536 correlated | 0.906–0.985 | 1.000–1.128 |
| real-1536 independent | 0.965–1.023 | 0.951–1.070 |
| real-1536 selective | 0.990–1.011 | 0.980–1.029 |

## 為何不採用

Assembly中，`CandidateMinHeap._sift_up`整個函式126→209條指令，兩個outlined
sift-down各234→324。
這些是含prologue／errors的靜態數字，不是動態cost。實際sift-down迴圈的舊交換
用兩個`stp`寫32 bytes；候選用三個`str`寫16 bytes，另在最後填回。搬移bytes
減少，並沒有等比例減少memory instructions；兩版仍有List bounds診斷準備。
不能只由函式大小推論全部效能差異。

另兩個候選profiles完成31,744次repeat audits，五個profiles合計 **100,416次**。
Heap samples在real correlated為5.19→5.50%、independent為5.02→4.99%；沒有
一致占比下降。Diagnostic mean thread CPU雖415.76→376.09 μs、468.56→439.18 μs，
這是不同時間的sampling runs，不取代三trial公開矩陣，也不拿來覆蓋慢samples。
現有證據不足以用此內部改寫換取穩定公開收益，保留原heap。

## 凍結證據與重現

[Immutable archive](results/2026-10-04-heap-shifts.json.gz)：710 entries，25,425,511 bytes。
SHA-256：`b98e167073956024a51cab58d4b7b811270ef3822625e63b0b58aa26d4bb61eb`。
Gzip readback及所有embedded file hashes已核對，保存兩份source/package、tests、
失敗compile、全部72 workers與5 profiles、raw samples、assembly、drivers與identities。

正式kernel仍為 `80ddc239bc711b5b5c52acc44e9f705825cabac31b4d646503597ba1aa3e2155`；
未採用kernel為 `cb571ba99258a11f03ae600c08cdb099ef2ccfa7c1ef6350365450c0ef2b2bda`。
`.build/2026-10-04-{frontier-profile,heap-shifts}` 是暫存，不重跑會覆寫來源或產物的
driver。重新assessment只重建derived summary，原Qdrant gate保持FAILED／exit1：

```sh
rtk proxy env PYTHONPATH=.:.build/qdrant-compare/deps .pixi/envs/default/bin/python .build/2026-10-04-heap-shifts/summarize-matrix.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-heap-shifts/summarize.py
```

接續檢查filtered admission對同一slot重複讀取current-state的實際成本，以及主要
distance kernel成本；先確認呼叫與驗證合約，不直接刪檢查。不原樣重跑本候選。
無Linux runner，持續nonresident／受控memory-limit仍未驗證，M5/M6不能勾選。
