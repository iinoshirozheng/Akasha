# Named cache 批次局部修復的完整生命週期診斷

**候選未採用，M5/M6 未完成。** 每個受影響中心只修復一次，讓原高維更新的
距離計算減少 63.81%，但沒有解決所有生命週期與品質成本。
完整原曲線共 132→129/216 格達標，
其中 3 個固定 ef 格從通過轉為失敗；
23/36 選定格的 QPS 或 p95 相對正式版退步。
這是 named A/B 診斷，**沒有新的 Qdrant gate**；不能把它當作 M6 通過或失敗矩陣。

## 變動、契約與驗證

正式 engine `cc15f37`／工作 HEAD `78a5499`。正式與 before Python SHA-256：
`609aeb2b0d721cbc1d84f6aec1bd325a360484cfa72d207600313b342c5cd8d9`。
隔離候選 SHA-256：`c5728d7a2bec35186ea1c3af3845a8a3886ccb2e8b34182646c95802fffb9fdd`。
正式 source、Python、C ABI 與 worker 均未改。Mojo 1.0.0 (`ed45d567`)，Apple M4／Metal:4。

依 [batch 方案](../plans/2026-10-04-batched-cache-repair.md)，從既有 private refresh
候選分出獨立 source：先驗證／準備所有 changed IDs，收集原鄰居的 unique
`(slot, level)`，固定排序；一次覆寫 private prepared vectors，再修復各中心並
逐 changed point reconnect。新排程改變 topology，不宣稱與逐點版圖等價。
仍保留原 construction ef、checked distances、heuristic、inactive navigation
bridges、雙向 degree bounds、cache authority／CRC、locks 與 atomic publication。
Public upsert 的 append／history 契約未改；post-mutation 失敗使 private graph 無效。
沒有增加 score cache、公開配置、裸 Span 或較大 rerank budget。

相對正式 source 共八個 Mojo 檔不同；其中本次批次排程改的是 `hnsw.mojo`、
`hnsw_core.mojo`、`field_hnsw_cache.mojo`，其餘沿用前一隔離 kind-5 cache 設計。
全部 as-run sources 保存於 archive，沒有把未採用原型留在 production 路徑。

本候選通過 **79 unique targeted Mojo／388 完整 Python**：8 個 batch tests、
2 個基本 cache、7 個 extended cache（55 native metric／graph codec 組合）、
12 mutation、10 links、15 neighbor selection、14 quantized、9 field cache、2 control。
覆蓋 overlapping jobs／determinism、slot／level／current vector、sole-live／inactive
bridges、invalid input、pre-cancel／pre-expired、失敗後隔離與公共 mutation 契約。
沒有宣稱測過 deterministic mid-repair cancellation；source 含每個 work unit checkpoint。
新 API 在舊 private source 的首輪編譯因方法不存在而失敗，原 log 保留。

Binding 從 copied `after-src/bindings/python_module.mojo` 編譯；Python 使用 saved
package、import／SHA guards、`-o pythonpath=` 與 Metal wrapper PATH。388 項全部通過，
一個既有 Starlette warning。沒有新版完整 Mojo／crash／C ABI／examples／HTTP／Linux／
GPU／ASan／nonresident gate；先前可沿用的證據不加總冒充本輪完整整合。

## 修復工作計數

相同 frozen 8,192 點圖、819 updates、205 deletes、1536D Dot/F32：
batch 收集 **8,233 jobs**，實際 **102,698,038 distance calls**，
對照舊逐點計數 **283,741,054 calls**。
batch 方法單次計時 19.212 秒；舊 56.17 秒含 print instrumentation，
兩者不能當 acceptance latency A/B。

7,987 current IDs、12,268,032 component bits 與205 deleted IDs 核對通過，
結構驗證及 encode/decode/re-encode 逐 byte 相同。新 graph 為 52,246,628 bytes，
SHA-256 `ff3eb99bff5ccf090750b8eae2d592914c16a49f9d1d5fc8545d095707f8ebcf`。它與舊逐點 graph 不同。
舊 dynamic 排程有8,210 unique jobs；新 batch 於 mutation 前收集8,233，候選集合不同，
不拿兩者的去重比例直接推算速度。

## 完整曲線與所有退步

三 corpora × 三 trials × 兩版，AB／BA／AB；共18份完成結果。最初完成的
uniform-1536 trial 0 兩份原結果依 SHA 原樣沿用，其餘16個 worker 接續串行執行。
這些結果沒有重跑取代、刪除失敗或挑中位數；所有原 seeds／filters／K=10／
8192 rows／819 updates／205 deletes、六個 efs、每格3 warmups＋64 samples 保留。
Benchmark 沒有與 build／test／archive compression 重疊。

**28,944 ANN audits／4,824 exact oracle checks** 通過。
更新後重開的圖不同，9,975/14,472 paired ID lists 相同，
133,569 個 common-ID F64 score-bit 比對全相同。
每版第二次重開皆保持其 IDs／F64 bits／stats；候選 kind5 的8,192 physical slots
與7,987 live points，正式 kind4 的7,987 slots 均核對實際 cache header／CRC。

全部 36 個 mode／trial 都能在原 grid 的某個 ef 達到 Recall@10 ≥ .95。
仍保留 baseline 84、candidate
87 個低 recall 格。以下是固定 ef 的新增品質失敗：

| Corpus | Trial | Mode | ef | Recall before / after |
|---|---:|---|---:|---:|
| uniform-128 | 0 | independent | 128 | 0.9500000 / 0.9453125 |
| uniform-128 | 1 | independent | 128 | 0.9500000 / 0.9453125 |
| uniform-128 | 2 | independent | 128 | 0.9500000 / 0.9453125 |

生命週期單位為 **ms，before / after**；不以首查改善抵銷暖查詢或 maintenance：

| Corpus | Trial | 更新後重開首查 | 更新後 flush | 第二次重開首查 |
|---|---:|---:|---:|---:|
| uniform-128 | 0 | 6,808.12 / 6,055.89 | 24.15 / 75.78 | 87.84 / 91.39 |
| uniform-128 | 1 | 6,906.40 / 6,078.52 | 24.68 / 77.60 | 87.75 / 91.36 |
| uniform-128 | 2 | 6,859.49 / 6,090.65 | 24.83 / 77.65 | 86.44 / 92.77 |
| uniform-1536 | 0 | 33,061.49 / 19,786.99 | 60.87 / 200.66 | 293.38 / 309.31 |
| uniform-1536 | 1 | 33,247.66 / 19,847.61 | 83.03 / 197.56 | 287.60 / 309.98 |
| uniform-1536 | 2 | 33,272.57 / 19,906.76 | 66.10 / 188.31 | 290.73 / 308.11 |
| real-1536 | 0 | 17,464.28 / 13,203.75 | 58.41 / 196.66 | 330.96 / 358.10 |
| real-1536 | 1 | 17,459.98 / 13,217.31 | 57.81 / 198.18 | 338.35 / 357.65 |
| real-1536 | 2 | 17,444.23 / 13,126.22 | 64.58 / 198.37 | 333.66 / 344.63 |

下表各版選原 grid 中第一個達標 ef；完整同 ef 與第一個共同達標 ef 亦保留。
QPS ratio 是 after/before，越高越好；p95 ratio 越低越好。Named driver 的 p95
沿用 NumPy percentile，與正式 Qdrant gate 的 nearest-rank 不同，不能混接。

| Corpus | Trial | Mode | ef before / after | QPS ratio | p95 ratio |
|---|---:|---|---:|---:|---:|
| uniform-128 | 0 | all | 128 / 128 | 0.7902 | 1.4580 |
| uniform-128 | 0 | correlated | 256 / 256 | 1.0309 | 0.9153 |
| uniform-128 | 0 | independent | 128 / 256 | 0.6488 | 1.5296 |
| uniform-128 | 0 | selective | 128 / 128 | 1.0231 | 0.9071 |
| uniform-128 | 1 | all | 128 / 128 | 1.0617 | 0.7502 |
| uniform-128 | 1 | correlated | 256 / 256 | 1.0185 | 0.9943 |
| uniform-128 | 1 | independent | 128 / 256 | 0.6578 | 1.4654 |
| uniform-128 | 1 | selective | 128 / 128 | 1.0889 | 0.9079 |
| uniform-128 | 2 | all | 128 / 128 | 0.9924 | 1.0277 |
| uniform-128 | 2 | correlated | 256 / 256 | 1.1480 | 0.7422 |
| uniform-128 | 2 | independent | 128 / 256 | 0.6429 | 1.4901 |
| uniform-128 | 2 | selective | 128 / 128 | 0.9869 | 1.0511 |
| uniform-1536 | 0 | all | 512 / 512 | 0.9680 | 1.0523 |
| uniform-1536 | 0 | correlated | 512 / 512 | 0.9821 | 1.0327 |
| uniform-1536 | 0 | independent | 512 / 512 | 0.9736 | 1.0344 |
| uniform-1536 | 0 | selective | 256 / 256 | 0.9766 | 1.0458 |
| uniform-1536 | 1 | all | 512 / 512 | 1.0131 | 0.9350 |
| uniform-1536 | 1 | correlated | 512 / 512 | 0.9909 | 1.1059 |
| uniform-1536 | 1 | independent | 512 / 512 | 0.9751 | 1.0386 |
| uniform-1536 | 1 | selective | 256 / 256 | 0.9467 | 1.1254 |
| uniform-1536 | 2 | all | 512 / 512 | 0.9920 | 0.9519 |
| uniform-1536 | 2 | correlated | 512 / 512 | 0.9798 | 1.0099 |
| uniform-1536 | 2 | independent | 512 / 512 | 0.9882 | 1.0008 |
| uniform-1536 | 2 | selective | 256 / 256 | 0.9692 | 1.0769 |
| real-1536 | 0 | all | 32 / 32 | 1.0083 | 0.9744 |
| real-1536 | 0 | correlated | 64 / 64 | 1.0810 | 0.8087 |
| real-1536 | 0 | independent | 64 / 64 | 1.0271 | 0.9553 |
| real-1536 | 0 | selective | 128 / 128 | 0.9317 | 1.0604 |
| real-1536 | 1 | all | 32 / 32 | 0.9656 | 1.0398 |
| real-1536 | 1 | correlated | 64 / 64 | 1.0860 | 0.8324 |
| real-1536 | 1 | independent | 64 / 64 | 1.0216 | 0.9378 |
| real-1536 | 1 | selective | 128 / 128 | 0.9445 | 1.0371 |
| real-1536 | 2 | all | 32 / 32 | 0.9871 | 1.0561 |
| real-1536 | 2 | correlated | 64 / 64 | 1.0145 | 0.9367 |
| real-1536 | 2 | independent | 64 / 64 | 0.9988 | 1.0256 |
| real-1536 | 2 | selective | 128 / 128 | 0.9725 | 0.9616 |

`work-summary.json` 保存每格第一個共同達標 ef 的計數。既有 widening API 只報
upper descent 與最後一輪 ANN 的 counters，前輪與 exact fallback 不計入；
`test_hnsw_widening.mojo` 明確保護此契約，不能將它們誤報成全部距離計算量。
uniform-1536 trial0 all/correlated/independent 無 widening，候選平均約多192個
inactive visits；selective 有2次 widening，其計數只作最後一輪觀察。沒有直接刪橋或
略過驗證來壓低數字，也沒有依此另加未經證明的 query-distance cache。

## 判定與不可變證據

先前方案將任一 A/B 暖退步當成停止條件，這是我們自行加上的限制，已更正。
使用者的原門檻始終是同 recall 下原矩陣**每格 QPS ≥ Qdrant 且 p95 ≤ Qdrant**。
原正式比較使用 default field；本曲線走 `search_field`、包含 native F64 rerank，
不能直接拼接 default-field 的 Qdrant 成績或宣稱 native named parity。

本次不採用的工程理由是修復本身仍昂貴、128D 同 ef recall 下降而需要擴大搜尋，
且選定暖曲線出現上述退步；首查改善不足以支持新增這條修復路徑。
這不代表它已執行並失敗於正式 Qdrant gate，也不把所有 A/B 退步當成使用者禁令。
正式來源保持原樣，M5 首次建圖／多 run 更新後重開以及 M6 既有失敗格仍待完成。
使用者沒有原生 Linux runner；不宣稱 controlled-memory 或 sustained nonresident 通過。

[Archive](results/2026-10-04-batched-cache-repair.json.gz)：380 text entries、
5,866,574 bytes，SHA-256：`b23fe72b48884f9ebb9113e8dd1dde9194c26e5fcc1282c948b7bfd81ffbeff5`。
Gzip readback 與全部 embedded SHA 已核對。含完整 sources／copied packages 文字、
測試／logs、baseline failure、native probe、全部 lifecycle samples／輸入與 binary
identity、各項 summaries、wrapper 與 drivers；大 binary／database／NPZ 以 hashes 識別。
Frozen archives 不改寫；`.build` 僅暫存，重現請先提取 driver 到新目錄並檢查 output。

完成結果的重新 assessment（第一項預期 exit1 表示品質退步，量測已完成）：

```sh
rtk proxy python3 .build/2026-10-04-batched-cache-repair/summarize-lifecycle.py
rtk proxy python3 .build/2026-10-04-batched-cache-repair/summarize-work.py
```
