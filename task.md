# AkashaDB 工作入口

目標是完成 [tasks/todo.md](tasks/todo.md) 的 M5／M6；**目前尚未完成**。
`tasks/todo.md` 是唯一工作 checklist，歷史報告的缺口與測試數不能當成現況。

## 最新診斷（2026-10-04）：named 小分區有界掃描

正式 engine／kernel 仍為下方 `1318457`，未修改。九個原 corpus/trial native workers
直接載入前一 bundle 的 graph bytes，完成 24,120 組 scan/graph、2,513,574 common
F32 bits 與 14,472 原 bundle IDs／distance／widening 比對。所有 scan top-10
符合獨立 oracle；品質仍 141/216，75 個低 recall 格與 54 次結果差異完整保留。

選定 36 格的 native 分區搜尋總 mean／p95 均改善，mean 降低約 6.5–28.1%；
不包含 wrapper／rerank／IO，不是 public QPS 或 Qdrant gate，舊 bundle 尚未採用。
[全部證據與失敗紀錄](docs/research/2026-10-04-named-small-partitions.md)；接續
[小分區掃描＋完整 artifact 生命週期方案](docs/plans/2026-10-04-named-bounded-partitions.md)，
在最新 source 上隔離重接，不原樣重跑舊 bundle／repair。
原正式 gate 仍 warm21/36、mixed26/36、write+flush4/9，**FAILED，M5/M6未完成**。
沒有新完整 Mojo/Python/crash/C ABI／HTTP／Linux／nonresident 驗收；沒有 runner。

## 最新採用（2026-10-04）：delta live／history 分別限額

小型 delta 依 live rows 限制向量評分，另保留 physical history／ef 上限；累積替換
歷史後不再過早切回圖搜尋。唯一 engine 改動為 segmented HNSW 的 private predicate，
搜尋迴圈、驗證、分數、格式與 ownership 不變。146 unique targeted Mojo／506 完整
Python／C ABI/client／3 rebuilt examples 通過；正式路徑另 9 Mojo／26 Python 與
C/client/examples 再通過（不重複加總）。

原 54-worker 矩陣 warm 21→21/36、mixed 28→26/36、write+flush 4→4/9；兩版 recall
各 36/36，五個 performance pass→fail 全保留，**整體 FAILED，M5/M6 未完成**。
120 次 real mixed 後段查詢改走有界 scan，所有 IDs／score bits 一致；另 6 個 CPU
診斷 workers 的九個受影響後段群組 CPU 均降低 9–28%，不取代原效能 gate。
[完整實作、全部樣本、退步與凍結證據](docs/benchmarks/2026-10-04-delta-live-budget.md)。
**現行 kernel SHA-256**：
`eb3bebdea9ea4f9d8050d965af1625003d7aec9d841f02fbc9bf101c05f73945`。
Worker 未改；沒有新 full Mojo/crash、HTTP performance、Linux/GPU/ASan/nonresident gate。
接續原 real ANN／selective／maintenance 失敗格與 named 多 run／更新後重開生命週期。
目前沒有 Linux runner；sustained nonresident／memory-limit 保持未驗收。

以下記錄描述各歷史工作包，不取代本節現況。

## 前一診斷（2026-10-04）：mixed 查詢與 delta 歷史成本

正式engine／kernel仍為下方`9bf69e0`工作包，未修改。四個production profiles完成
91,392 repeat audits／268 exact checks／1,152 mixed audits，另4個reopen／Arrow leases
通過；real independent跨過physical-slot界線後distance evaluations增加約40%。

新增固定live rows、逐步替換歷史的native sweep：324格／15,552成對samples；scan
全數符合獨立oracle，graph的105格低recall全部保留。分開限制live vector work與
physical history的候選predicate新涵蓋72格，其中60格matched quality的mean／p95
均改善，另12格graph品質不足不作速度主張。**尚未實作／採用新policy，沒有新Qdrant
gate，M5/M6仍FAILED**。
[全部profiles與sweep](docs/research/2026-10-04-mixed-query-work.md)；接續按
[有界live／history設計](docs/plans/2026-10-04-delta-live-budget.md)做隔離實作、
邊界／native／owned/mapped驗證及原完整矩陣，不放寬fixed ef或recall標準。

## 前一採用（2026-10-04）：authority／metadata payload 合併編碼

Legacy cache 每筆 payload 只驗證／編碼一次，供原 CRC 與 metadata framing 共用；
格式、checksum、持久化順序與 named point-store 路徑不變。
108 unique targeted Mojo／7 related crash／506 完整 Python／C ABI/client／3 rebuilt
examples 通過。原54-worker矩陣 warm25→26/36、mixed19→17/36、write+flush3→3/9；
recall兩版各36/36，四個mixed performance pass→fail全保留，**整體FAILED**。

九格 write+flush QPS 改善6–23%，p95八格改善、一格退步14.45%；另18個診斷workers
確認flush前景CPU均減少14–26%，不能以此取代原查詢gate。全部樣本、失敗、bytes／CRC
與正式路徑驗證見[完整報告](docs/benchmarks/2026-10-04-combined-cache-encoding.md)。
**該工作包 kernel SHA-256**：
`f33bdbf7734d2762450e9a5e9cb4234a46feee2a4b474907a9d6c3fb5ed2045d`。
Worker未改；沒有新full Mojo/crash、HTTP performance、Linux/GPU/ASan/nonresident gate。
M5/M6仍未完成，接續real ANN／mixed selective尾延遲與named多run重開生命週期。
目前沒有Linux runner，sustained nonresident／memory-limit保持未驗收。

## 前一診斷（2026-10-04）：Top-K admission 拆分未採用

候選在compiler gate停止：offer與exact caller指令數未縮小，沒有新效能量測。
兩版各8 targeted Mojo通過，保留3項獨立oracle；正式路徑另3項通過，不加總。
該診斷未改動`8ba04ce`；當時性能門檻與kernel不變，M5/M6未完成。
[完整證據與失敗紀錄](docs/benchmarks/2026-10-04-topk-admission.md)。

## 前一採用（2026-10-04）：checked visit 縮小參數

HNSW visit改用只借用epoch words的private helper，保留原epoch／bounds／owner與
所有搜尋行為。110 targeted Mojo／506完整Python／C ABI/client／3 rebuilt examples
通過；正式路徑另11 Mojo／143 Python與C loader/client／examples通過（不加總）。
[全部實作、驗證、原始samples與凍結證據](docs/benchmarks/2026-10-04-visit-arguments.md)。

Named 14,472 paired IDs／F64 bits／stats相同，品質132/216、84低recall格保留。
高維selective QPS改善3–7%，六個trials的p95皆改善；36選定格仍12格timing退步。
原54-worker Qdrant矩陣warm18→19/36、mixed24→27/36、write+flush3→3/9，
兩版recall各36/36；四個performance pass→fail全保留。**整體FAILED，M5/M6未完成**。
首輪child wrapper漏absolute src的紀錄保留，更正後506 Python完整重跑通過。
沒有新版full Mojo/crash／HTTP／Linux／GPU／ASan／nonresident gate，worker未改。
**該工作包kernel SHA-256**：
`3ec07dc3c9711ccdb024311831a86c3ed844556c383f7b5de9dcbae535d893c1`。
接續原real ANN／selective失敗格與M5剩餘artifact生命週期，不重跑已否決原型。

## 前一診斷（2026-10-04）：HNSW traversal work

隔離計數完成5,628 paired IDs／bits／stats、1,608 exact oracle checks及18 targeted
Mojo；正式source/binary未改。原real ANN重複邊43–45%，scalar tails約6%；current
重讀雖保留於machine code，但只占約0.8–1.4% query samples。另兩個正式named
selective profiles完成2,880 repeat audits＋134 warmups，visited標記占8.6–9.6%；
assembly顯示每次visit仍搬移多個scratch欄位；其後已採用頁首的縮小參數改動。
保留epoch／bounds／owner，不重做heap、validation reuse或raw Span原型。
[全部traces、profiles、失敗及凍結證據](docs/research/2026-10-04-traversal-work.md)。
這不是新效能gate；named trial-0品質44/72，28個低recall格全保留。M5/M6未完成，
沒有新完整Python／Mojo／crash／Qdrant／Linux／nonresident驗收。

## 最新隔離結果（2026-10-04）：HNSW heap 搬移未採用

新的正式版profile確認原uniform-128 all走planned exact，real filtered ANN的heap
只占約5% samples。單向搬移候選通過122 targeted Mojo；原54-worker Qdrant同批
warm25→23/36、mixed15→14/36、write+flush3→3/9、recall各36/36，五個performance
pass→fail全保留。Named另18 workers、14,472 paired IDs／bits／stats一致，品質
132→132/216，24/36選定timing退步。未採用，正式`ac48cda` source/binary不變。
[全部矩陣、五個profiles與assembly](docs/benchmarks/2026-10-04-heap-shifts.md)。
沒有新完整Python／Mojo／crash／C ABI／examples／HTTP／Linux／nonresident gate。
其後filtered admission與distance grouping的診斷見頁首；不直接刪檢查，
不原樣重跑heap候選。**M5/M6仍未完成**。

## 前一採用（2026-10-04）：native F64 四候選 rerank

Named dense ANN 的 native rerank 改為四候選並行、直接借用 read-run owners。
30 targeted Mojo／506 完整 Python／C ABI/client／3 rebuilt examples 通過；
正式套件再通過 3 Mojo／151 Python 與 C client／3 examples（重複檢查不加總）。
53,776 F64 bit 比較、5,400 public paired queries、14,472 named paired queries
一致；named 品質132→132/216、全部84個低recall格保留。第二版高維all QPS快
18–25%，選定36格仍有7格timing退步；第一版未採用，全部樣本／失敗均凍結。
[實作、三份archives與精確驗證](docs/benchmarks/2026-10-04-native-f64-four.md)。

原始54-worker Qdrant同批矩陣：warm **18→20/36**、mixed **24→23/36**、
write+flush **3→3/9**；兩邊recall各36/36，保留四個performance pass→fail。
整體仍FAILED，M5/M6不勾選。沒有新完整Mojo／crash／HTTP performance／Linux／
GPU／ASan／nonresident／memory-limit gate；worker未改，沒有Linux runner。
**該工作包 kernel SHA-256**：
`80ddc239bc711b5b5c52acc44e9f705825cabac31b4d646503597ba1aa3e2155`。
其後的candidate heap實驗見頁首；原HNSW搜尋與named更新生命週期仍有剩餘工作。
下方各工作包的「最新」及數字只描述當時版本，不取代頁首現況。

## 前一隔離結果（2026-10-04）：widening 距離重用未採用

[逐分區／逐輪計數](docs/research/2026-10-04-named-partition-work.md)確認正式單圖
也會重算。兩版隔離候選各70 targeted Mojo通過，包含11種native backend的
owned/mapped多輪案例；各18 workers、14,472 paired IDs／F64 bits／stats一致，
品質兩版各132/216。高維selective QPS提升約9–20%，但其餘格仍有退步，沒有新
Qdrant通過主張，正式source/binary未改。[完整實作、兩次曲線與失敗樣本](docs/benchmarks/2026-10-04-widening-distances.md)。
第二版分離record-only／reuse，仍有21/36選定格timing退步。原門檻不變，M5/M6
保持未完成。下一步回到沒有widening的高維all與named小分區額外工作，不原樣
重跑兩版；沒有新full Python／Mojo／crash／Linux／nonresident驗收。

## 前一隔離結果（2026-10-04）：named graph bundle 未採用

分區快取完成隔離實作；112 targeted Mojo／11 related crash／506 完整 Python／
C ABI／3 rebuilt examples 通過。原三 corpus／三 trial 共 18 個 lifecycle workers
完成，28,944 ANN audits／4,824 exact checks 通過。首查快約 43–93 倍，但共同
recall 的 36 個暖格全部 QPS 退步；fixed-ef recall 132→141/216，新增三個失敗。
保存時間增加；正式 source/binary/格式不變，M5/M6 不勾選。
[全部證據與限制](docs/benchmarks/2026-10-04-named-graph-bundle.md)。
[同圖對照](docs/benchmarks/2026-10-04-named-bundle-fixed-graph.md)亦完成18 workers：
14,472組成對query的IDs／score bits／全部stats一致，品質兩版均132/216；
23/36選定格仍有QPS或p95退步，未重現多分區一致降速，沒有新Qdrant gate。
[逐分區／逐輪計數](docs/research/2026-10-04-named-partition-work.md)亦完成：
9,648 query bits／stats、1,608 exact checks 一致；正式單圖 selective 也有重算，
uniform-1536 平均三輪、21,803 次距離計算。其後完成的兩版 widening 距離
重用實驗見上方最新結果；此計數沒有新的效能達標主張。

## 前一採用（2026-10-04）：Python 搜尋轉換時 close

相鄰 binding／Arrow／scanner 已完成同類修正：另重現 33 個 abort，13 個既有通過
案例保留；46 targeted／506 完整 Python 通過，採用後兩份回歸共 118 項再通過。
轉換完成後才借用原生 collection；scanner 先保存統計，已捕獲 snapshot／batch
仍可跨 close 使用。唯一正式 source 變更為 Python binding，core／worker 未改。
[後續完整證據](docs/research/2026-10-04-binding-close.md)。
**該工作包 kernel SHA-256**：
`780e8aaf3d7db9423251a4090fd069382d148d783451a91b6eb972893f5f74d6`。
該 binding 工作包沒有新效能／完整 Mojo／crash／Linux 驗收。
M5/M6 整體仍 FAILED，不能以正確性修正當作效能達標。
後續 [JSON decoder 相容性探針](docs/research/2026-10-04-http-json-compatibility.md)：
20,006 numeric bits 一致，但 direct replacement 改變 5 種 accepted inputs 和 3 種
錯誤回應；未採用、沒有新速度主張。其後的 M5 多 run artifact 實作與量測結果
見上方最新隔離結果；不重跑已否決的 reconciliation／overlay。

`search_approx`／`search_dense_where` 在 Python 轉換後重新檢查 handle，修正 callback
呼叫 close 後的程序 abort，保留未知 metric 的錯誤優先順序。54 個 baseline abort／
18 個既有通過案例均保留；候選 72 targeted／460 完整 Python 通過，採用後 72 項
再驗證通過。沒有 GIL／owner／engine 變更，也沒有新的效能通過主張。
[修正與證據](docs/research/2026-10-04-conversion-close.md)。
第一階段 kernel SHA-256：
`b8a66097cb6c0f598238e6e79a997820c4b4e1fdc55b8a09bd3cdc174dab7865`。
相鄰 binding 的後續結果見上段；M5/M6 仍未完成。

## 前一採用（2026-10-04）：filtered HNSW inactive radius

已修正 deleted/replaced slots 占用 filtered navigation radius、導致全允許 filter
也可能提早停止的缺陷。唯一 engine 改動為 `hnsw_core.mojo`，新增三個重現測試。
119 targeted Mojo／388 完整 Python／C ABI／3 rebuilt examples 通過；採用後同一
binary 的 3 Mojo／8 server tests／C client／3 examples 再驗證通過，不重複加總。
[修正、全部矩陣與證據](docs/benchmarks/2026-10-04-live-filtered-radius.md)。

該工作包 Python kernel SHA-256：
`609aeb2b0d721cbc1d84f6aec1bd325a360484cfa72d207600313b342c5cd8d9`。
Frozen archive SHA-256：
`77ae0191f6ebbe08689c184c9f6cc0aa5686480ca0f102e98a5bb29f159c53ce`。
固定三方 warm 19→22/36、mixed 19→19/36、write+flush 3→3/9；recall 各 36/36。
有兩個 performance pass→fail，全部保留，**整體 FAILED、M5/M6 未完成**。未重跑
完整 Mojo／crash／HTTP performance／Linux／GPU／ASan／nonresident gate。

較大的 named cache reconciliation 候選仍未採用。接續處理其更新後重開與暖查詢
成本，以及原 M6 失敗格；以下各段為先前工作包的證據，不代表新版完整整合。

[Python ANN GIL 候選](docs/benchmarks/2026-10-04-binding-gil.md)未採用：
34 targeted／388 完整 Python 通過；fixed warm 20→22/36、mixed 25→25/36、
HTTP 24→28/108，整體 FAILED。保留所有 A/B 退步、9 個 performance pass→fail
及三個 Qdrant 低 recall 格；錯誤 runtime 的早期量測獨立保留。Production 未改。
由此重現的兩個搜尋入口 abort 已以上方獨立最小 handle recheck 修正。

[Mapped F32 雙區塊探針](docs/benchmarks/2026-10-04-mapped-chunks.md)未採用：
3 metric tests／1,646,592 score-bit 比對通過，42 筆微量測全保留。128D 七次改善，
1536D Dot／Cosine 分別有 2／3 次退步；沒有 public query／Qdrant 新通過主張。
正式 source/binary 不變。接續檢查原 HTTP 失敗格的實際成本，不重做此微調。

[每中心一次的 private batch 修復](docs/benchmarks/2026-10-04-batched-cache-repair.md)
已完成隔離實作與完整 named 生命週期曲線，**未採用**。79 targeted Mojo／388 完整
Python 通過；相同高維更新的 distance calls 減少 63.8%。三 corpus／三 trial 共
28,944 ANN audits／4,824 exact checks 通過，但 fixed recall 132→129/216，
uniform-128 independent／ef128 三次新增失敗，23/36 選定暖格退步。首查約
6.8→6.1 秒／33.1→19.8 秒／17.5→13.2 秒，修復仍昂貴；正式 source/binary 不變。
本曲線不是 Qdrant gate；已更正方案自行加上的「任一 A/B 退步即否決」限制，
正式門檻仍是原固定矩陣逐格 QPS／p95 對 Qdrant。沒有新完整 Mojo／crash／C ABI／
examples／Linux gate。Frozen archive SHA-256：
`b23fe72b48884f9ebb9113e8dd1dde9194c26e5fcc1282c948b7bfd81ffbeff5`。

[前一修復計數](docs/research/2026-10-04-refresh-work.md)：819 updates 產生
38,256 jobs／8,210 unique center-level，78.54% 重複，reciprocal connect 占47.43%。
它支持上述 batch 實驗，不能把去重比例當速度。後續回到 M6 實測失敗格與 M5
生命週期；不原樣重跑 batch／overlay 候選。正式 real ANN 三次皆無 widening，
沒有支持為此加入跨輪距離快取；既有 counter 的最後 ANN 輪契約保持不變。

[Named retained-base／delta 接合](docs/benchmarks/2026-10-04-named-overlay.md)
已完成隔離實作，**未採用**。跨階段 150 unique targeted Mojo；修正空 delta 後
23 項相關 Mojo／388 完整 Python／C ABI／3 rebuilt examples 通過，11 crash 為
前一整合階段。單次原 uniform-1536 完整 grid，更新後首查 33.13→1.71 秒、
quality 9→9/24 無新增失敗，但 3/4 選定暖格退步、第二次重開變慢。四個 native
profiles／7,488 audits 支持 stale-base 遍歷成本仍在；all 多算約 981 次距離與
約 969 次 source rejection。首次 missing-cache 失敗與空 snapshot allocation
上限重現均保留，改用可選空 delta，沒有放寬安全限制。正式 source/binary 不變；
其後已完成上方 local repair 計數；下一步驗證 batch 候選，不盲目重跑舊演算法。
Frozen archive SHA-256：
`2f9f97e8b4d9c5408af60fbfe0772550c181b21abccdde61e3f00682cfa3a2b2`。

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
Qdrant gate。此為前一 primitive 階段；其後已依
[接合設計](docs/plans/2026-10-04-named-overlay-design.md)完成上述隔離候選，
原全域 rerank budget 不變，但暖效能仍未通過。

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
