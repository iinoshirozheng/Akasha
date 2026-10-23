# HNSW traversal work：計數與正式版 profiles

**沒有修改正式引擎，沒有新效能通過主張；M5/M6 未完成。** 重複 current-state
檢查與不足四列的 distance batches 都不是目前最有力的改動方向。Named selective
的 visited 標記占較多 samples，其實際編譯呼叫包含 scratch 欄位搬移；下一步先
隔離驗證縮小可變參數範圍的成本，保留現有檢查，不直接改 visited 演算法。

來源 HEAD `fd82b49`，正式 engine `ac48cda`。正式 kernel SHA-256：
`80ddc239bc711b5b5c52acc44e9f705825cabac31b4d646503597ba1aa3e2155`。
Mojo 1.0.0 (`ed45d567`)，Apple M4 / Metal:4。

## 已驗證的工作

[診斷計畫](../plans/2026-10-04-traversal-work.md)。只有隔離 copy 的 `search_layer`
增加 local counters 與結束時的一筆 trace，逐邊 validation、visit、distance、heap、
admission 及公開 stats 均未改。Copied binding entry 編譯成功。

- **5,628 paired query audits**：原 default 三 corpus／四 filter／67 queries
  共 804 次，加 named 三 corpus／四 filter／六 ef／67 queries 共 4,824 次。
  逐次 IDs、F32/F64 bits、全部公開 stats 與同一正式 binary 的保存結果一致。
- **1,608 exact ID oracle checks**：兩種入口各三 corpus／四 filter／67 queries。
  Default 保存的品質為 12/12；named 為 44/72，28 個低 recall 格全部保留。
  這是 trial 0 的診斷重播，沒有冒充完整三 trial 的新 gate。
- **18 targeted Mojo**：layer 14、group order 1、live radius 3 通過。
  已知 group-order 小圖的兩次 trace 均為 13 edges、4 revisits、9 new neighbors，
  與原有測試圖及 counters 的加總一致。TestSuite 時間單位為毫秒。
- 正式版另兩個 named selective profiles 共 **2,880 repeat audits + 134 warmups**，
  每次均核對 IDs/F64 bits/stats；使用獨立 database clones，cache bytes 未改。

每份 layer trace 檢查 `edges = revisits + sum(group_size * group_count)`。
Group 0 也保留。所有 ef、widening rounds 與各 query 的原 trace 在 archive 中；
不把下一表的選定 ef 當作刪除其餘曲線的理由。所有 build/test/profile/compression
串行執行，沒有覆寫 worker。正式 source 逐檔與診斷前 hashes 相同。

Named 第一輪 launcher 把 `ef_search` 傳給 exact API，依契約遭拒，未開始 named
查詢量測；修正 harness 後使用新目錄完成。Targeted launcher 第一輪使用不存在的
`test_hnsw_four_grouping.mojo` 路徑，第一個 layer file 已通過；更正為既有
`test_hnsw_group_order.mojo` 後三檔全通過。兩次原始失敗均保存，重複的 layer
tests 不加總。沒有新的完整 Python／Mojo／crash／C ABI／examples 或 Qdrant run。

## 每次查詢實際遍歷工作

數字累計全部 layer calls，含 widening；比例由總數計算，不是逐 query 比例的平均。
Scalar tail 指 group 1/2/3 的新鄰居，分母不含 entry 或 greedy descent。

| 入口／corpus | filter | ef | layer calls/query | edges/query | revisits | scalar tail |
|---|---|---:|---:|---:|---:|---:|
| Default real-1536 | all | 16 | 2.00 | 1,566.43 | 43.97% | 5.67% |
| Default real-1536 | correlated | 32 | 1.00 | 1,523.45 | 42.60% | 5.72% |
| Default real-1536 | independent | 40 | 1.00 | 1,890.61 | 44.54% | 5.84% |
| Named uniform-128 | all | 128 | 1.00 | 5,993.42 | 34.97% | 4.98% |
| Named uniform-128 | correlated | 256 | 1.00 | 11,927.22 | 52.10% | 6.79% |
| Named uniform-128 | independent | 128 | 1.00 | 5,993.40 | 34.98% | 4.93% |
| Named uniform-128 | selective | 128 | 1.82 | 15,786.09 | 45.68% | 5.94% |
| Named uniform-1536 | all | 512 | 1.00 | 23,862.70 | 68.21% | 10.16% |
| Named uniform-1536 | correlated | 512 | 1.00 | 23,862.36 | 68.22% | 10.23% |
| Named uniform-1536 | independent | 512 | 1.00 | 23,860.18 | 68.21% | 10.22% |
| Named uniform-1536 | selective | 256 | 3.00 | 83,523.58 | 73.97% | 10.44% |
| Named real-1536 | all | 32 | 1.00 | 1,516.49 | 43.87% | 5.81% |
| Named real-1536 | correlated | 64 | 1.00 | 2,993.06 | 50.67% | 6.39% |
| Named real-1536 | independent | 64 | 1.00 | 2,984.72 | 49.39% | 6.28% |
| Named real-1536 | selective | 128 | 2.72 | 35,039.15 | 71.78% | 11.46% |

原 default 的兩組 uniform 全部 filter 與 real selective 都走 planned exact，
沒有 layer trace。不能用 HNSW 改動解釋這些格的速度。

## Profiles 與 machine code

沿用 [heap 工作包](../benchmarks/2026-10-04-heap-shifts.md) 的正式版 real
correlated/independent samples，重新以實際 method names 分類；沒有重跑或重算成
新的 audits。先扣除 children，exclusive categories 的總數核對 main-thread samples。
Current-state reads 占 query boundary **1.36% / 0.82%**；source + metadata
admission 為 **3.56% / 4.25%**。這些包含必要工作，不是可消除成本的估算。

Mapped filtered cosine layer 的實際 function 範圍為 `0x299210–0x29a458`。
Entry 的 `is_current` calls 位於 `0x2997b0` / `0x29982c`；neighbor calls 位於
`0x299dc4` / `0x299e0c`。兩次之間各有 result-heap offer，compiler 沒有消除重讀。
即使如此，其所有 reads 的 sample 占比也小，不據此增加 admission cache。

新增 profiles 使用**未改的正式 binary**，每組先做 67 warmups，再重播約七秒並
用 `/usr/bin/sample` 取樣五秒。下表為 query-boundary exclusive samples 的百分比；
歸類保留未知／其他部分，不能把 parent 和 child 重複相加。

| Named selective | uniform-1536 | real-1536 |
|---|---:|---:|
| Query-boundary samples | 3,766 | 3,607 |
| Four-row distance | 43.68% | 41.61% |
| Single-row distance | 11.07% | 11.26% |
| Visit scratch | 9.59% | 8.57% |
| HNSW heaps | 10.52% | 6.10% |
| Other HNSW | 14.15% | 13.22% |
| Native F64 rerank | 2.31% | 3.05% |

`HnswSearchScratch.visit` 的正式 function 範圍為 `0x1fdf08–0x1fe0f8`。機器碼
只有一次 List 長度檢查，故「將 getter/setter 合併成一次 ref」未必能再省檢查。
它同時保存多個 scratch 欄位並在返回區寫回；正常 hit/miss 都經過該返回區。
`sub sp, sp, #0x840` 與額外 register-save frame 亦保留於 disassembly。
這些是靜態事實，不能將搬移指令數直接換算成延遲或認定全部 visit samples 都由此造成。

下一個獨立候選可將 checked visit helper 的可變參數縮至 `visited_epochs`，另傳
epoch、prepared count、slot；原 `visit` 介面維持。先確認 compiler 是否真的縮小
呼叫／返回資料，再測 bit/stat parity 及公開矩陣。保留 UInt32 epoch wrap、未 begin、
prepared-range 與 List bounds 錯誤、無重新配置的正常查詢及同一 scratch owner。
不加 raw Span/pointer、forced inline、跨 query cache 或新的配置層。

Local Qdrant `74f3e85` 的 `visited_pool.rs` 亦將 epoch counters 與 heaps 分開；
原文／hash 已保存。其 u8 epoch、visit 時自動 resize 與 Akasha 契約不同，不照搬。
原 Akasha graph trait 是 readonly；cross-level edge 檢查及 invalid-boundary 不改
scratch/stats 的測試均保留。此次沒有重排或省略這些檢查。

## 凍結證據與重現

[Immutable archive](../benchmarks/results/2026-10-04-traversal-work.json.gz)：
340 entries，2,848,715 bytes，SHA-256
`6d554d4fcb029831d3861c4a088de136aa4a9e9a3c46eb2521d525e350e68c94`。
已解壓回讀每個 entry SHA。包含 copied sources/counter patch、driver、原始失敗、
完整 traces、production references、profiles、assembly、tests/logs 與 identities。
Binary、database、workload payload 以 hashes 識別，沒有嵌入 archive。

Instrumented kernel SHA-256：
`a1028db95d14ded043f57f453eec75d8775c5f37a17683dca2a357f9db0ec7a8`。
正式 source/kernel/native worker 不變。沒有新 HTTP／Linux／GPU／ASan／持續
nonresident／controlled-memory gate；沒有可用 Linux runner。

暫存目錄 `.build/2026-10-04-current-state-audit` 已凍結，不原地重跑 writing drivers。
在新目錄復原 sources 與 scripts 後，依保存的 paths/identities 修改輸出位置，串行
執行 `build.py`、corrected targeted command、`count.py`（named）、修正過的
`count-initial.py`（default）及 `named-profile.py`。原 `count-initial.py` 保存的是
首次 harness 失敗版本，不直接當成完整可成功 runner。分析用 `summarize-counts.py`、
`samples-detail.py`、`named-samples.py`，它們只寫 derived summaries，但同樣用新目錄。
完整固定 Qdrant 門檻維持逐格 Recall@10 ≥ .95、QPS ≥ Qdrant、p95 ≤ Qdrant。
