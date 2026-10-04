# Named HNSW 分區快取的生命週期診斷

**NOT ADOPTED；M5／M6 未完成。** 分區快取的隔離實作與驗證完成，更新後重開首查
快約 43–93 倍，但 36 個共同 recall 的暖格全部 QPS 退步，且有三個新 fixed-ef
recall 失敗。增加的 flush 成本亦保留。正式 source、Python binary、cache format
均未變；不能以首查改善抵銷其他格，不能把本診斷當作 Qdrant parity。

從 `d52a2878d75352a5cd6025ee85bbfaf270fceda3` 的正式來源複製獨立 source/package。
正式 kernel SHA-256：`780e8aaf3d7db9423251a4090fd069382d148d783451a91b6eb972893f5f74d6`。
候選 SHA-256：`a3e854ea769f58b90698eeff4713d3c075832167423b827bf9466f0c60b93b3e`。
Native worker SHA-256：`bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`，沒有覆寫。
Mojo 1.0.0 (`ed45d567`)，Apple M4／Metal:4；Python 3.11。

## 實作與邊界

依 [分區保存方案](../plans/2026-10-04-named-graph-bundle.md)，目前 writer 在多 run
或非空 head 時不保存 named graph；重開後以完整當前點集合重建圖。原型保存各張
已建好的圖及其目前有效成員，未做 reconciliation、插入、刪除或鄰居修復。

候選將每個 named artifact 表示為 owned graph partitions，保留 sorted current
rows、ID→(partition, slot) map 與 query lock。新建圖只有一個分區；載入時重綁
當前 authority ordinal。舊節點可導航，但不能供應結果。過濾與後續 read-layer
shadowing 先決定 admission，各分區沿用原 candidate／ef budget，最後合併並用
native F64 rerank。圖與所有向量的原驗證、prepared score 路徑沒有刪除。

Kind 5／payload version 1 保存 exact schema/config identity、HNSW snapshot bytes
及升序 slot/ID membership；每個當前 field ID 必須恰好出現一次，且 vector 必須
與 authority 完全一致。保留 AKIC CRC／原子替換／512 MiB payload bound，另共用
512 MiB conservative decode allocation bound，避免每張圖單獨符合、總量卻超額。
舊 kind 4 在候選 loader 明確為 miss；正式格式仍是 kind 4，未發生 authority 遷移。

Writer 只收集 ready immutable runs／matching frozen head，解析最新 ID 覆蓋，
省略零成員分區並攤平已載入的 bundle。Artifact/query locks 單次嘗試，忙碌、未建
圖或保存失敗可稍後重試；writer 不建圖。每欄位一個正式檔與至多一個 tmp，snapshot
不寫檔。新增 allocation 回歸用多張各自合法的圖超出總界線，確認原檔保留且鎖可重試。

七個 candidate source files 是 `collection`、`field_hnsw`、`field_ann`、
`field_hnsw_cache`、`read_generation`、`index_cache` 與 `hnsw_store`。
候選格式說明與全部 source/test snapshots 均在 archive；沒有推進到正式檔案。

## 精確驗證範圍

- **112 unique targeted Mojo passed**：含 7 個 bundle lifecycle、2 個 allocation、
  1 個 native multi-part test（55 組 authority/codec）、既有 9 個 field cache test
  （另 55 組 single-graph native/codec）、18 store、14 quantized，以及相關 named
  query、generation、maintenance、backup、compaction、control 測試。
- **11 related crash passed**：point checkpoint 1、checkpoint 7、backup publication 3。
- **506 完整 Python passed**；saved package import/path/hash guards、`-o pythonpath=`，
  child compile 繼承 candidate source wrapper、Metal wrapper 與 project Python PATH。
- **C ABI client 與 3 個重新編譯的 examples passed**。所有 benchmark 於上述工作
  完成後才啟動；與 build/test/archive compression 沒有重疊。

新增回歸核對更新／刪除／移除欄位／metadata、空欄位、多次 reopen 與後續 update，
graph snapshot bytes、ID/F64 score bits、搜尋工作量、舊 snapshot、取消與資源上限，
CRC 正確但 membership／current vector／identity／framing 錯誤，以及忙碌／未建圖／
保存失敗重試。Base/delta counters 隨目前 read-layer 分布改變；比較的是兩者總和，
不是聲稱兩個 counters 個別不變。

這不是新版完整 Mojo／23 crash gate。未新增 Linux／ASan／GPU device／持續
nonresident／controlled memory-limit 驗收；使用者已表示沒有可用 Linux runner。
現有 Starlette deprecation、Crashpad 訊息留在 log。TestSuite 的時間單位是 **ms**。

Baseline reproducer 的預期失敗是 reopen `cache_hit=False`，保留 exit 1／72.347 ms。
開發中的 missing publisher argument、不可複製 List iteration、Optional Array/List、
VectorValue copy 與 UInt64 shift 編譯錯誤均保留對應 source/test/log，修正後才進入
正式診斷；沒有刪除失敗的性能樣本。

## 固定生命週期結果

原三 corpora、三 trials、四 filters、六 efs、K=10、seeds、原始新增／替換／刪除
資料全部沿用；18 個 worker 串行完成（全部 exit 0），交錯 before/after 順序。
原 query 序列每格前三筆 warmup 保留但不納入原本的量測彙總。每格全部 raw latency、
recall、IDs、F64 bits、stats 在 report.json；沒有丟棄慢 trial 或增加預設 ef。

**28,944 ANN curve audits／4,824 exact oracle checks 通過**。這代表輸出範圍、分數
及 oracle 核對完成，不代表每個 ANN ef 都達 .95。每次兩版本的 initial／updated
IDs、score bits、stats 相同；候選首個 reopen query 與 pre-close 的 bits/work 相同，
第二次 reopen query 亦保持相同。候選快取在無新內容的再次 flush/close 後 bytes 相同。

| Corpus | Trial | Reopen 首查秒：before → after | 更新後 flush ms：before → after | 更新查詢至重開首查總耗時 after/before |
| --- | ---: | ---: | ---: | ---: |
| uniform-128 | 0 | 6.913 → 0.105 | 25.0 → 90.6 | 0.102 |
| uniform-128 | 1 | 6.886 → 0.109 | 25.1 → 90.7 | 0.103 |
| uniform-128 | 2 | 6.912 → 0.105 | 25.0 → 90.9 | 0.102 |
| uniform-1536 | 0 | 33.286 → 0.364 | 71.2 → 250.9 | 0.053 |
| uniform-1536 | 1 | 33.355 → 0.358 | 63.0 → 259.1 | 0.053 |
| uniform-1536 | 2 | 33.178 → 0.355 | 72.2 → 278.4 | 0.054 |
| real-1536 | 0 | 17.530 → 0.405 | 65.1 → 320.9 | 0.094 |
| real-1536 | 1 | 17.455 → 0.395 | 68.2 → 343.0 | 0.095 |
| real-1536 | 2 | 17.516 → 0.409 | 72.2 → 326.5 | 0.094 |

總耗時欄包含 updated query、flush、close、reopen、first query，沒有只將重建工作
轉移到未列出的 flush。初始建圖沒有改善；後續已經有完整 single-graph cache 的
第二次首查，候選通常較慢。各階段完整耗時在 `lifecycle-summary.json`。

## Recall 與暖查詢的取捨

Fixed-ef .95 品質通過 **132→141／216**，12 格改善、3 格新增失敗：
**uniform-128／independent／ef128，三個 trials 皆 0.95→0.94375**。
每種 corpus/filter 都仍能在原 ef grid 找到達 .95 的設定；所有低 recall 格完整保留。
既有 .99 curves 的定位仍是診斷，未變更使用者指定 gate。

下表每格選原 grid 中「同一 ef、兩版本都達 .95」的第一個 ef。範圍顯示全部三次
trial 的最小／最大值，沒有用 median 遮蓋失敗。QPS 比越高越好，p95 比越低越好。

| Corpus | Filter | 共同 ef | QPS after/before | p95 after/before | distance calls after/before |
| --- | --- | ---: | ---: | ---: | ---: |
| uniform-128 | all | 128 | 0.664–0.708 | 1.476–1.547 | 1.223–1.223 |
| uniform-128 | correlated | 256 | 0.721–0.796 | 1.035–1.394 | 1.161–1.161 |
| uniform-128 | independent | 256 | 0.652–0.709 | 1.592–1.724 | 1.161–1.161 |
| uniform-128 | selective | 128 | 0.756–0.777 | 1.104–1.344 | 1.227–1.227 |
| uniform-1536 | all | 512 | 0.812–0.823 | 1.194–1.252 | 1.133–1.133 |
| uniform-1536 | correlated | 512 | 0.844–0.863 | 1.144–1.218 | 1.133–1.133 |
| uniform-1536 | independent | 512 | 0.770–0.842 | 1.187–1.367 | 1.133–1.133 |
| uniform-1536 | selective | 256 | 0.908–0.938 | 0.962–1.187 | 1.132–1.132 |
| real-1536 | all | 32 | 0.754–0.786 | 1.246–1.376 | 1.732–1.732 |
| real-1536 | correlated | 64 | 0.786–0.813 | 1.214–1.264 | 1.505–1.505 |
| real-1536 | independent | 64 | 0.779–0.806 | 1.250–1.289 | 1.503–1.503 |
| real-1536 | selective | 128 | 0.728–0.746 | 1.480–1.580 | 1.317–1.317 |

**36／36 QPS 退步**（after/before 0.652–0.938）；因此也全部屬 QPS 或 p95 退步。
距離計算增加 13.2–73.2%，與額外分區／導航節點的工作相符。這是計數證據，不足以
將全部時間歸因於拓撲；還需以相同圖 bytes 隔離 query wrapper 成本。

| Corpus | Graph partitions before → after | Physical slots before → after | Cache MiB before → after |
| --- | ---: | ---: | ---: |
| uniform-128 | 1 → 2 | 7,987 → 9,011 | 5.676 → 6.497 |
| uniform-1536 | 1 → 3 | 7,987 → 9,011 | 48.583 → 54.903 |
| real-1536 | 1 → 3 | 7,987 → 9,011 | 48.553 → 54.868 |

上表為每 corpus 的 trial 0；全部 trials 的實際 header/CRC/membership/hash 都已核對，
每份 current membership 為 7,987 個 IDs，與 authoritative final state 一致。
容量／coverage 的成功不等於記憶體壓力或持續 nonresident 驗收。

## 決定與重現

**不採用這個版本。** 首查節省是真實改善，但原 .95 門檻下暖查詢有一致且明顯的
成本，還增加了 fixed-ef recall 失敗與 flush 時間。本工作包沒有新 Qdrant benchmark，
也没有更新原 warm/mixed/HTTP/write+flush parity 成績；M5/M6 checklist 保持未勾選。

下一步先以同一份 merged graph bytes 做查詢路徑對照，拆分新 wrapper 與 retained
partition 的成本，再決定是否有必要改動小分區查詢策略。不要重跑此完整 lifecycle
cohort，也不要重做已否決的 graph reconciliation／逐點／批次 repair。

[完整 frozen archive](results/2026-10-04-named-graph-bundle.json.gz)：
**938 text entries／6,539,825 bytes**，逐 entry SHA-256 已回讀驗證。
Archive SHA-256：`f64f3652facf3f2857a8168fd6eb2177aaf8578f426bbfab31177c1334fca653`。

另有 [as-run test source 補檔](results/2026-10-04-named-graph-bundle-test-source.json.gz)：
1 entry／3,515 bytes，SHA-256 `9418c9e30839e26a4c9959bc4c9499097a30e0ac8e7ba6d9b4de8eecbcf21072`。
它還原早期成功的 lifecycle-v2 測試中後來移除的 unused loop binding，與原 manifest
記錄的 SHA-256 完全一致。主 archive 未改寫；全部 as-run test 與 1,800 筆 source
hash 引用均已核對到保存的文字。

`.build/2026-10-04-named-graph-bundle` 是當次工作目錄。重現時從 archive 取出 source、
wrapper、tests 與 drivers 至新的隔離目錄，先核對 identity/input hashes，再依序執行
Mojo → copied binding build → saved-package Python → C/examples → lifecycle。
不要原地重跑會覆寫產物的 driver；archive 本身不改寫。

仍適用的原始 commands 及環境、退出碼、source hashes 均在 JSON manifests。
只有重新彙整已有原始樣本可以直接使用下列命令，不會重跑 benchmark：

```sh
rtk proxy python3 .build/2026-10-04-named-graph-bundle/summarize.py
```

沒有 active benchmark/build/test；原 10-02 Git merge 不重做，此證據按工作包另行 commit。
