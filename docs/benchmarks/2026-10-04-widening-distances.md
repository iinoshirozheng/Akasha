# Named selective：widening 距離重用實驗

**兩個隔離候選均未採用，正式 source／binary 不變。** 高維 selective 的 QPS
提高約9–20%，但 uniform-128 selective 和未 widening 的其他格仍有退步，尚未建立
涵蓋其餘失敗格的收益。這是 named resident 前後診斷，不是 Qdrant gate，M5/M6 未完成。

## 實作與驗證

[設計](../plans/2026-10-04-widening-distances.md)由
[正式單圖逐輪計數](../research/2026-10-04-named-partition-work.md)出發。
兩版只改隔離 `hnsw_core.mojo`／`hnsw_scratch.mojo`：同操作第一次確實 widening
才配置 slot-indexed F32 距離表；不保留第一輪分數，後續輪次重用已驗證距離。
原 grouping、reduction、radius、停止規則、admission、ef、fallback、rerank 不變。
每次新操作重設，沒有跨 query／graph／mutation 重用，也沒有 durable format 變更。
每 slot 額外 4 bytes，capacity 留在 scratch；初始化為 O(slot count)。

第二版只讓已知為空的第二輪走 record-only specialization，第三輪起才查找；
若第二輪已是最高 ef，完全略過配置／記錄。沒有 corpus 或 dimension 閾值。

每版 **70 unique targeted Mojo tests** 通過：65 個既有 scratch、layer、group order、
filtered、query boundary、mutation、quantized、four-distance，加 4 個跨 query／
invalid query／epoch wrap／growth+tombstone 案例，及 1 個涵蓋11種 metric/scalar、
owned/mapped、各3個 query 的 native 多輪案例。重跑不重複加總。
Mojo 1.0.0 (`ed45d567`)、Apple M4／Metal:4；TestSuite 單位毫秒。
第一次 test 的 Float32 bitcast API、candidate 未初始化變數、native test 缺少
explicit copy/move 編譯失敗及修正後來源均保留，沒有刪掉失敗紀錄。

兩版各使用當時正式 merged graph cache 的完全相同 bytes，原三 corpus／三 trial、
四 filter、六 ef、67 queries（3 warmups）。每版18 workers串行完成；每版
**14,472 paired query IDs／F64 bits／全部 stats／recall** 一致，28,944 ANN audits、
4,824 exact ID oracle checks。沒有重建不同拓樸或跨 cohort 混合成 gate。
每個候選與其當次基線的 fixed-ef quality 都是 **132/216**；原84格低 recall 保留。

公開 stats 繼續計最後 ANN 輪的邏輯 scored slots 加 upper；快取命中仍是同一個
scored slot。另行插樁量實際交給 distance kernel 的列數；四列呼叫算4列，不能把
下述數字當成函式呼叫次數。這不是以 counter 不變宣稱沒有改善。

## 第一版完整選定格

每列包含原3 trials、兩版都達 .95 的最小 ef。QPS 比為 after/before（越大越好），
p95 比亦為 after/before（越小越好）；範圍包含全部 trial，不以 median 覆蓋退步。

| corpus | filter | ef | QPS 比範圍 | p95 比範圍 |
|---|---|---:|---:|---:|
| uniform-128 | all | 128 | .991–1.007 | .994–1.041 |
| uniform-128 | correlated | 256 | .983–1.095 | .831–1.025 |
| uniform-128 | independent | 128 | .980–.990 | .996–1.064 |
| uniform-128 | selective | 128 | .860–.945 | 1.081–1.269 |
| uniform-1536 | all | 512 | .961–.978 | 1.023–1.079 |
| uniform-1536 | correlated | 512 | 1.004–1.013 | .942–.987 |
| uniform-1536 | independent | 512 | .982–1.013 | .964–1.102 |
| uniform-1536 | selective | 256 | 1.148–1.204 | .814–.918 |
| real-1536 | all | 32 | .961–.993 | .948–1.050 |
| real-1536 | correlated | 64 | .986–1.002 | .986–1.025 |
| real-1536 | independent | 64 | .983–1.036 | .975–1.009 |
| real-1536 | selective | 128 | 1.090–1.093 | .838–.883 |

22/36 selected cells 有 QPS 或 p95 退步。uniform-128 selective 的一致退步與額外
記錄成本有相符工作證據；無 widening 格的差異仍保留，沒有未量測的因果歸因。

## 第一版實際距離工作

獨立 instrumented copied binding，原 trial0 三 corpus 的全部72格重播；4,824
query bits／stats 與未插樁候選一致，804 exact checks。以下不含 warmups。
upper 計一次，所有 base 輪均計入，原始每輪 trace 已保存。

| selective 格 | ef | 原總距離列數 | 候選實際列數 | 減少 | 有重用／64 queries |
|---|---:|---:|---:|---:|---:|
| uniform-128 | 128 | 8,679.75 | 8,679.75 | 0% | 0 |
| uniform-1536 | 256 | 21,803.30 | 14,217（約） | 34.79% | 64 |
| real-1536 | 128 | 9,890.20 | 7,391（約） | 25.27% | 44 |

uniform-128 有53筆啟用記錄但沒有第三輪可重用；real 則有20筆。這支持第二版
分離記錄與查找成本，不能把省下距離比例直接當作端到端速度。

## 第二版完整選定格

第二次獨立18-worker cohort，同樣保存全部 trials 與固定 grid。

| corpus | filter | ef | QPS 比範圍 | p95 比範圍 |
|---|---|---:|---:|---:|
| uniform-128 | all | 128 | 1.000–1.208 | .725–1.095 |
| uniform-128 | correlated | 256 | .908–1.200 | .792–1.311 |
| uniform-128 | independent | 128 | .984–1.057 | .889–1.027 |
| uniform-128 | selective | 128 | .911–1.091 | .826–1.107 |
| uniform-1536 | all | 512 | .905–.993 | .980–1.256 |
| uniform-1536 | correlated | 512 | .968–1.004 | 1.001–1.064 |
| uniform-1536 | independent | 512 | .990–.996 | 1.010–1.022 |
| uniform-1536 | selective | 256 | 1.152–1.200 | .828–.935 |
| real-1536 | all | 32 | .987–.995 | .997–1.030 |
| real-1536 | correlated | 64 | .985–.998 | .989–1.033 |
| real-1536 | independent | 64 | 1.004–1.011 | .974–.994 |
| real-1536 | selective | 128 | 1.097–1.104 | .853–.865 |

21/36 selected cells 有 QPS 或 p95 退步。高維 selective 改善重現，uniform-128
selective 不再三次全退步，但未建立穩定收益。沒有 widening 的格無法從距離重用
獲益；其時間變化全部保留，不推斷為特定 codegen 或排程原因。

未採用是對收益範圍、記錄／記憶體成本及反覆退步的工程判斷；不是新增「任一
A/B 退步即否決」使用者門檻。原門檻仍是完整固定矩陣逐格／trial 的共同 recall
下 QPS ≥ Qdrant 且 p95 ≤ Qdrant。這兩輪沒有執行或通過新的 Qdrant gate。
下一步回到沒有 widening 的高維 all 與 named 小分區額外工作，不原樣重跑兩版。

## 保存與重現

第一版 archive `docs/benchmarks/results/2026-10-04-widening-distances.json.gz`：
768 entries／7,241,485 bytes，SHA-256
`c35d513015b9007a322a09bd4db757aa18beba98508d5732e5fa2db6d6c597be`。
第二版 archive `docs/benchmarks/results/2026-10-04-widening-record.json.gz`：
484 entries／5,546,522 bytes，SHA-256
`2d358a4dc983c46f9fa3ea21fc8c3e58131edd5f02f8b257e83ef7002e053457`。

包含 source、as-run tests、失敗來源、完整 raw samples／stats、drivers、identities、
logs 與 summaries；所有 entries 重新解壓核對，所有 targeted metadata 的 test／
source hashes 均能解析到保存的內容。包含未執行的相鄰測試來源以供重現，不計入70項。
資料與圖來源指向前一 bundle archive
`f64f3652facf3f2857a8168fd6eb2177aaf8578f426bbfab31177c1334fca653`，各 job 保存
corpus／oracle／cache／graph hashes。

候選 kernel SHA-256 分別為
`6a37e2693829ff8caaaf48a0ac863ce4a234f0560a10201273bf9a366e9b15e0`、
`385b14be4f73982edecb688c2b11aa140d5fe671ca9bebcbd8354ffe8a3e2b54`。
As-run 的核心重現命令（repository root）如下；兩個目錄內的 build／curve driver
使用 exclusive output creation，須還原到新目錄、調整其來源路徑，不能覆寫凍結樣本。

```sh
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-widening-distances/build.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-widening-distances/curves.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-widening-distances/summarize.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-widening-distances/profile-build.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-widening-distances/profile.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-widening-record/build.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-widening-record/curves.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-widening-record/summarize.py
```

正式 kernel SHA-256 維持
`780e8aaf3d7db9423251a4090fd069382d148d783451a91b6eb972893f5f74d6`。
沒有重跑完整 Python／Mojo／crash／C ABI／examples／Qdrant／Linux／GPU／ASan／
nonresident gate；正式版本已有仍適用的成功驗證沿用，不能算成這兩版的新測試。
