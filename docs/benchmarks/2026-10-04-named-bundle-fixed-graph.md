# Named bundle：相同圖的查詢路徑對照

**候選仍未採用，M5／M6 未完成。** 繼 [分區生命週期診斷](2026-10-04-named-graph-bundle.md)
後，這次只比較相同 merged graph bytes 下的新舊查詢路徑，沒有新 Mojo 修改或
重新建圖。14,472 組成對查詢的 IDs、F64 score bits、recall、全部搜尋 stats
完全一致；fixed-ef 品質兩版均為 **132／216**。

這不是 Qdrant parity。相同圖的 36 個選定格仍有 **23 格 QPS 或 p95 退步**，
所有 trial 保留，不能宣稱 wrapper 零成本或全部等速。它也沒有重現上一組不同
拓撲時的 36／36 QPS 下降、13–73% 額外 distance calls。

## 控制方式

沿用上一份 frozen source／binary，正式 kernel SHA-256：
`780e8aaf3d7db9423251a4090fd069382d148d783451a91b6eb972893f5f74d6`；候選：`a3e854ea769f58b90698eeff4713d3c075832167423b827bf9466f0c60b93b3e`。
原型來源 archive SHA-256：`f64f3652facf3f2857a8168fd6eb2177aaf8578f426bbfab31177c1334fca653`，沒有改寫。
兩版都使用 project Python 3.11、Apple M4／Metal:4，import/path/hash guard 生效。

每個原 corpus/trial 都從前一 cohort 的 **before 最終資料庫**複製 authority。
Before 保留 kind-4 single-graph cache；after 只將同一 HNSW snapshot 封裝為一個
kind-5 分區，附完整 current membership 及相同 field identity。重算的是可重建
cache envelope CRC，authority 未修改。獨立 reader 核對 snapshot CRC/hash、
slot-ID-current membership；每次關閉後 cache bytes 未變。

三 corpus × 三 trials × 兩版本的 **18 workers 全部完成、exit 0**，串行執行，
交錯版本順序。原 seeds、filters、K、六個 ef、query 順序與每格三筆 warmup 全保留。
沒有重跑 ingest／update／graph build；本報告的首查與暖查詢時間不可與前一
lifecycle cohort 的整段時間直接相減來分配成本。

**28,944 ANN curve audits／4,824 exact oracle checks** 通過。逐 query 配對排除
latency 後，ordinal、warmup、recall、IDs、F64 bits、stats 全部相同，包含所有
低 recall 與失敗格。First query 的 results/bits/stats 也相同。
沒有新增 unit/full Mojo/crash/Python/C ABI/examples 測試次數；前一候選的
112 targeted Mojo／11 related crash／506 Python／C ABI／3 examples 證據仍適用。

## 全部三 trial 的速度範圍

每個 corpus/filter 選原 grid 中第一個 Recall@10 ≥ .95 的 ef；兩版選擇相同。
表格是三次 trial 的完整最小／最大範圍。QPS 比越高越好，p95 比越低越好；
原始每格數字與樣本均在 `summary.json`／各 `report.json`，沒有 median-only 判定。

| Corpus | Filter | Ef | QPS after/before | p95 after/before |
| --- | --- | ---: | ---: | ---: |
| uniform-128 | all | 128 | 0.799–1.113 | 0.868–1.397 |
| uniform-128 | correlated | 256 | 0.802–1.005 | 0.945–1.499 |
| uniform-128 | independent | 128 | 0.878–1.084 | 0.758–1.208 |
| uniform-128 | selective | 128 | 0.912–1.035 | 0.845–1.230 |
| uniform-1536 | all | 512 | 0.931–1.010 | 0.975–1.132 |
| uniform-1536 | correlated | 512 | 0.972–1.011 | 0.939–1.035 |
| uniform-1536 | independent | 512 | 0.989–1.019 | 0.948–1.045 |
| uniform-1536 | selective | 256 | 0.986–1.046 | 0.895–1.037 |
| real-1536 | all | 32 | 0.978–1.006 | 0.972–1.045 |
| real-1536 | correlated | 64 | 0.908–1.012 | 0.960–1.301 |
| real-1536 | independent | 64 | 0.970–1.084 | 0.888–1.045 |
| real-1536 | selective | 128 | 0.987–1.004 | 1.000–1.025 |

同圖實驗的 distance/visited/candidate/rerank counts **逐 query 相同**。這支持將
下一步放在多分區的額外搜尋工作上，但不能單靠兩組獨立 timing cohort 精確分解
wrapper、圖拓撲、記憶體布局與排程的時間占比。低維數據仍有明顯 trial 差異，
不把它們刪掉或當成達標。

下一步先計數多分區查詢各 partition 的 visited/distance/candidate 工作，並保留
原 IDs/score bits/總 stats 等價檢查；據此判斷小分區走圖的成本，再決定實作。
不先增加新的配置或抽象，不降低 recall／ef／候選預算，不重做舊 graph repair。

## 證據

[本次 frozen archive](results/2026-10-04-named-bundle-fixed-graph.json.gz)：
62 text entries／4,711,298 bytes，逐 entry SHA-256 回讀驗證通過。
SHA-256：`3d3f7e57feb7e2046e8f585bf32664321a8aabd806028d6cad6969d7ae03ea1b`。
使用的完整 source／binary identities 見上一份不可變 archive；本次 archive 保存
封裝 driver、graph hashes、全部原始 samples、job manifests 與彙整結果。

工作目錄 `.build/2026-10-04-named-bundle-fixed-graph`。重跑須建立新輸出目錄，
不能覆寫已保存的 cohort；只重新核對與彙整既有樣本可執行：

```sh
rtk proxy python3 .build/2026-10-04-named-bundle-fixed-graph/summarize.py
```

正式 source、kernel、native worker 均未變；無新 Qdrant、Linux、GPU、ASan 或
nonresident/memory-limit gate。沒有 active benchmark/build/test，M5/M6 checklist 未勾選。
