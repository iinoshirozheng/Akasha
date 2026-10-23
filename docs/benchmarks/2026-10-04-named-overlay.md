# Named retained-base／delta：隔離整合與成本驗證

M5/M6 **尚未完成，本候選未採用**。正式 engine 保持 `cc15f37`，Python kernel
保持 `609aeb2b0d721cbc1d84f6aec1bd325a360484cfa72d207600313b342c5cd8d9`。
本包接續 [primitive 成本探針](2026-10-04-named-overlay-cost.md)與
[接合設計](../plans/2026-10-04-named-overlay-design.md)，完成可編譯的隔離整合。

單次原 uniform-1536 完整曲線中，更新後重開首查 **33.13→1.71 秒**；fixed quality
仍為 9→9/24，沒有 pass→fail。但 3/4 個選定暖格退步，第二次重開也較慢，因此
不擴大完整 cohort、不帶回正式 source。冷查詢改善不抵銷暖查詢或維護成本。

## 實作與實際修復

隔離目錄為 `.build/2026-10-04-named-overlay`，從 HEAD `63fb5bb` 的正式來源複製。
六個變動檔：`segmented_hnsw.mojo`、`field_hnsw.mojo`、`field_ann.mojo`、
`field_hnsw_cache.mojo`、`index_cache.mojo`、`read_generation.mojo`。

- Segmented collectors 增加編譯期 scored 輸出，原 ID-only specialization 保留。
  共用原 traversal、source admission、widening 與 counters；不重算 graph score。
  Named 仍先以原 global budget 做 F32 top-k，再做 native F64 rerank。
- Named artifact 持有既有 `SegmentedHnsw`；filter/shadowing 依 public ID 判斷，
  current native row ordinal 與 base/delta slot 分開。舊 snapshot 保持原 owner。
- AKIC kind 6 在同一原子 envelope 保存 field identity、base snapshot、可選 delta。
  外層 CRC、內層 graph/config/sequence、native prepared bits／I8 scale 均驗證。
  Source map 從 current authority 重建；exact source key 下的錯向量／額外 delta ID
  仍為 miss。Stale key 才在尚未發布的 private owner 上更新 delta。
- Ready base 可在有 later runs/head 時保存，沿用 writer/query lock、busy skip、
  tmp/fsync/rename 與失敗後重試。原 rebuild thresholds 保留。

首次大資料量測發現一項實際缺陷：v1 強制編碼空 delta。1,536 維的空 AKHG 預估
解碼記憶體為 `164 + 1536×4 = 6308` bytes，超過原 amplification budget
`max(4096, 164×32) = 5248`，因此 best-effort cache 保存被略過。獨立 empty
snapshot probe 與新 lifecycle test 均重現。**沒有放寬 snapshot 安全限制**；v2
以零長度表示 physically empty delta，載入時用已驗證的 field config 建立空圖。
非空 delta 的原 decoder 與檢查保留。

Mojo 1.0.0 (`ed45d567`)，Apple M4／Metal:4。Scored type 使用 1.0 已支援的
[conditional type expression](https://mojolang.org/releases/v1.0.0/)；compiler
要求在已選定的 `comptime if` 分支以 `rebind` 明確對齊 conditional List element。
首輪未 refinement 的編譯錯誤也保留，沒有以新版本語法繞過 compiler。

## 驗證範圍

| 階段 | 已通過範圍 | 說明 |
|---|---:|---|
| scored-only | 47 targeted Mojo | 新增 3 項，含 176 組 backend／owned/mapped／filter 組合，ID 次序、F32 score bits、stats、準備次數與原 ID-only 相符 |
| named v1 | 102 targeted Mojo | 13 項新增 lifecycle／corruption tests、62 項既有 query/cache/native tests、27 項 publication/compaction/backup tests |
| named v1 | 11 related crash | point checkpoint、checkpoint order、backup publication |
| empty-delta v2 | 23 targeted Mojo | 22 項上述相關案例重跑，加 1 項高維回歸；高維回歸含 11 種 metric/codec，修正前失敗、修正後通過 |
| v1 與 v2 各自 | 388 完整 Python、C ABI/client、3 rebuilt examples | 使用各自 isolated binding，import path／SHA 與 Metal child-compile wrapper 已核對 |

跨階段只有 **150 個 unique targeted Mojo**，不是把重跑加總，也不是新版完整 Mojo。
11 crash 在 v1 執行；v2 只改 optional-empty-delta 的編碼／載入，未再跑 crash。
原 authority、atomic publish、worker 未改，沿用對應證據。沒有新版完整 Mojo、
Qdrant/default/HTTP 效能矩陣、Linux、GPU、ASan 或持續 nonresident gate。

55 種 native scalar × metric/graph codec 的整合循環，包含 replace、missing field、
delete、new ID、native F64 bits、舊 snapshot、cache hit、第二次重開不建 delta。
另有 valid outer CRC 下錯 base／delta、額外 current delta ID、內層截斷／損壞／
尾隨 bytes，以及取消、query lock busy、tmp 保存失敗／重試和多輪更新。

保留的其他失敗：原版兩項新增 lifecycle 回歸均失敗；scored baseline 缺少新 API；
一個 invalid-domain fixture 先在 setup 就拋錯，已修正到預期驗證邊界；一個多輪
fixture 錯誤期待小 delta 不重建，實際已達既有 inactive threshold。後者增加
「到門檻重建」與「未到門檻繼續沿用」兩項獨立覆蓋，沒有修改門檻。

v1 kernel：`ea8a62d4eff9355860cd57358e13987e3ee6024d7fc1f10dfa97624313198318`。
v2 kernel：`ed48ce76442727368a23bb0bc07a0764890c4d059cfad91314e6c8d1b05568cd`。
`identity-v1.json`／`v1-src`／`v1-python` 保留 v1；最終 `identity.json`／`after-src`
與 `after-python` 對應 v2。正式 source、Python binary 與 native worker hash 未變。

## 一個原始高維 trial

保留原 8,192 points、1,536 dimensions、seed 12345、Dot/F32、K=10、819 updates、
205 deletes、6 個 ef `[32,64,128,256,512,1024]`、4 filters，以及每格 3 warmups＋
64 measured queries。原樣本／warmups／低 recall 格都在 archive。沒有 Qdrant 對手，
這是正式版與候選版的 named lifecycle 診斷，**不是 M6 parity gate**。

完整重跑 `highdim-v2` 兩個 workers：3,216 ANN result audits、536 exact oracle
checks。1,608 paired queries 中 666 組 ID lists 相同；12,723 個 common-ID F64
score bits 相同。所有 stats 都有差異，沒有宣稱 graph/search 完全等價。初始與更新
後、尚未重開的單次查詢 ID／bits／stats 則兩版相同。

兩版各 9/24 fixed quality 格通過，所有四個 modes 都在原 ef grid 達 Recall@10≥.95，
無 fixed quality pass→fail；各自其餘 15 格失敗保留。選定 ef 兩版相同：

| mode | ef | QPS 正式→候選 | p95 ms 正式→候選 | 暖 timing |
|---|---:|---:|---:|---|
| all | 512 | 284.96→252.34 | 3.660→4.281 | 退步 |
| correlated | 512 | 260.42→234.82 | 4.209→4.800 | 退步 |
| independent | 512 | 267.15→248.30 | 3.937→4.204 | 退步 |
| selective | 256 | 133.19→136.26 | 8.629→7.681 | 改善 |

`highdim-v2-summary.json` 的 `TARGET_REACHED` **只表示 recall grid 找到合格 ef**；
採用決定是獨立 `decision.json` 的 `NOT_ADOPTED`。不能把 exit 0 當效能全面通過。

更新後首查 33,132.07→1,714.71 ms；第二次重開首查 292.63→378.72 ms。
原初始建圖首查仍為 34.17→34.43 秒。Updated flush 62.41→184.40 ms，候選此時
新增保存 ready base 的工作。這些時間分開保存，不跨服務邊界抵銷。

正式完整 cache 50,942,724 bytes／7,987 slots；候選 57,474,633 bytes／9,011
physical slots（base 8,192＋delta 819），authority 仍只有 7,987 current points。
候選 base SHA 在 reconcile 前後相同；第二次重開的 ID／F64 bits／stats 也完全相同。

首次 `highdim-probe` 中正式版完成 24 格，候選在 missing-cache assertion 中止，
未進入 reopen／curves。原報告、完整正式版樣本、candidate partial report、jobs、
logs 與來源均保留；沒有把那一組未配對結果合入上面的完整 paired trial。

## 成本證據與下一步

相同 selected ef 下，候選每 query 的 mean distance counts 比正式版增加
12.83%／4.81%／4.77%／2.85%（依上述 mode 次序）。all 為 7,647.91→8,628.91，
增加約 981 次，並有 969.02 次 source rejection；兩版皆零 widening。選定 filtered
格也沒有新增 widening rounds，因此目前不能把退步歸因於額外 widening。

另以 all／correlated 各兩版，共 **4 個獨立 native profiles**；每個先暖機，再執行
7 秒並取 5 秒 native sample。7,488 次 repeated ID／F64 bits／stats 都與未 profile
曲線相符，cache SHA 在 profile 前後不變。這些時間不納入 acceptance latency。

| mode | variant | mean query thread CPU μs | HNSW sample share* | native F64 metric share |
|---|---|---:|---:|---:|
| all | 正式 | 3394.63 | 58.74% | 24.97% |
| all | 候選 | 3807.67 | 61.49% | 22.29% |
| correlated | 正式 | 3561.35 | 59.03% | 22.98% |
| correlated | 候選 | 3845.85 | 61.93% | 21.37% |

*HNSW share 合併 four/single candidate distance 與 other HNSW 的 exclusive
samples，分母為 `BoundCollection.search_field` 內樣本；不能單靠 symbol attribution
把所有額外成本歸因於一次 Dict lookup。All 的額外距離與 source rejection 是直接
counter 證據。現有資料支持先處理 stale base rows 的遍歷，而不是再移除 query 或
candidate checks。

下一步先量測先前 local repair 的重複工作，並對照既有 batch graph-healing 做法，
確認是否有可驗證的去重空間；沒有新機制與測試依據前，不重跑原 53 秒逐點修復
或完整 cohort。初始建圖、暖效能、維護成本與原 M6 失敗格仍未解決。

## 證據與重現

Frozen archive：`results/2026-10-04-named-overlay.json.gz`，2,456,333 bytes、858
text entries，gzip 解壓及每個 entry SHA-256 都已核對。
SHA-256：`2f9f97e8b4d9c5408af60fbfe0772550c181b21abccdde61e3f00682cfa3a2b2`。

Archive 保存所有 scripts、各階段 sources、tests、失敗 attempts、逐筆 curves、
profiles、commands、exit codes、identities 與決定。附入完整測試 source 是為重現，
不代表執行過完整 Mojo。大型 binaries/database/corpus 未嵌入文字 archive；workload
SHA 與 deterministic spec 在各 job，採用原 `cost-plan-uniform-1536` 輸入。

以下為當時執行入口；logs/output 使用 exclusive create，**不可在原 OUT 盲目重跑**。
重現須先從 archive 恢復 text sources，另建 OUT、保留原 inputs、調整 wrapper 中的
絕對 source 路徑。編譯使用複製的 binding entry，所有 benchmark 與 build/test 串行。

```sh
rtk proxy python .build/2026-10-04-named-overlay/validate-v2.py
rtk proxy python .build/2026-10-04-named-overlay/python-tests-v2.py
rtk proxy python .build/2026-10-04-named-overlay/postvalidate-v2.py
rtk proxy pixi run python .build/2026-10-04-named-overlay/highdim-v2.py
rtk proxy pixi run python .build/2026-10-04-named-overlay/summarize-highdim-v2.py
rtk proxy pixi run python .build/2026-10-04-named-overlay/profile.py
rtk proxy python .build/2026-10-04-named-overlay/summarize-profiles.py
```

TestSuite 方括號時間是 **毫秒**；driver `seconds` 才是編譯＋執行 wall seconds。
Git commit／archive 與以上功能驗證均不代表 M5/M6 完成。
