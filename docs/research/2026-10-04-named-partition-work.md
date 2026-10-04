# Named HNSW 逐分區／逐輪工作計數

正式單圖與未採用 bundle 都有 selective widening 重算。這是下一個可驗證的成本來源；
不是效能通過結果。正式 source、binary、格式保持不變，M5/M6 未完成。

## 範圍與一致性

Mojo 1.0.0 (`ed45d567`)、Apple M4／Metal:4。從
[bundle 原樣本](../benchmarks/2026-10-04-named-graph-bundle.md)複製兩版 source、
Python package、trial 0 的最終 database；在 field query、widening、plain search
加入 print-only 計數。各三 corpus，原四 filter／六 ef／67 queries 全數重播，
沒有改 seeds、候選預算、資料或搜尋路徑。全部 build、worker 串行完成。

兩版各 **4,824 query IDs／F64 score bits／全部公開 stats** 與各自原報告逐筆相同，
合計 9,648；各 804 exact ID oracle checks，合計 1,608。不是兩版結果彼此相同。
關閉後 cache hash 未變。正式版 4,824 graph calls 中 669 次 widening；bundle
12,864 partition calls 中 1,091 次 widening。計數含原 warmups，下表平均不含 warmups。

公開 `distance_evaluations` 仍遵循 upper descent 加最後一輪 base 的既有契約。
額外 trace 分別保留所有輪次；全輪成本只計 upper 一次，不修改公開 counter。
未宣稱 profile 插樁時間為速度，沒有新 Qdrant gate 或新完整測試。

## 同 ef 的工作量

ef 選原 trial 0 兩版都達 Recall@10 ≥ .95 的最小共同值。`全輪／末輪` 為每筆查詢
距離計算平均（含 upper），四捨五入；所有 144 cells 與原始 trace 均在 archive。

| corpus | filter | ef | 正式全輪／末輪 | bundle 全輪／末輪 |
|---|---|---:|---:|---:|
| uniform-128 | all | 128 | 3,957／3,957 | 4,839／4,839 |
| uniform-128 | correlated | 256 | 5,778／5,778 | 6,707／6,707 |
| uniform-128 | independent | 256 | 5,774／5,774 | 6,718／6,705 |
| uniform-128 | selective | 128 | 8,680／5,460 | 10,670／6,702 |
| uniform-1536 | all | 512 | 7,648／7,648 | 8,664／8,664 |
| uniform-1536 | correlated | 512 | 7,643／7,643 | 8,660／8,660 |
| uniform-1536 | independent | 512 | 7,643／7,643 | 8,656／8,656 |
| uniform-1536 | selective | 256 | 21,803／8,027 | 23,110／9,084 |
| real-1536 | all | 32 | 912／912 | 1,579／1,579 |
| real-1536 | correlated | 64 | 1,542／1,542 | 2,320／2,320 |
| real-1536 | independent | 64 | 1,562／1,562 | 2,348／2,348 |
| real-1536 | selective | 128 | 9,890／4,970 | 13,278／6,548 |

正式 uniform-1536 selective 每次三輪；bundle 的 base 分區也是三輪，平均 22,256
次距離計算。bundle 額外小分區並非全部廉價：real all ef32 的 649／170-slot 分區
各約 493／177 次計算，疊加到 base 約 909 次。這支持額外圖遍歷有實際工作，
但不能從不同 cohort 的時間相減，聲稱已精確拆出 wrapper／拓樸耗時。

bundle 有 5,754 次 matched ≤ budget，其中 480 次回傳少於 matched；正式版則為
603／477。不能假設小集合已全部列舉，直接改成 flat 或縮候選需求而宣稱結果不變。

下一步在正式單圖做隔離、同操作距離重用：只於真正 widening 後啟用，先核對
結果位元、stats、跨 query／mutation 的隔離及實際 kernel calls，再量完整原 grid。
不更改 ef、停止規則或檢查契約。原 default-field real ANN 零 widening 的證據仍有效；
這次新線索適用於 named selective，不能推論所有原 M6 失敗格都会改善。

## 保存與重現

Frozen archive：`docs/benchmarks/results/2026-10-04-named-partition-work.json.gz`，
304 entries／3,130,126 bytes；SHA-256：
`3ed79cdd1f559a51eeabcac8259862dc99627b3216ca237e6d3189baef0d6f60`。

包含兩份完整 instrumented source、identities、build logs、drivers、jobs、raw traces、
結果／stats、完整 summary。沿用的資料、未插樁 source/binary identities 指向原
bundle archive `f64f3652facf3f2857a8168fd6eb2177aaf8578f426bbfab31177c1334fca653`。
正式 kernel 為 `780e8aaf3d7db9423251a4090fd069382d148d783451a91b6eb972893f5f74d6`。

As-run commands（工作目錄 repository root）：

```sh
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-named-partition-work/build.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-named-partition-work/profile.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-named-partition-work/before-build.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-named-partition-work/before-profile.py
rtk proxy .pixi/envs/default/bin/python .build/2026-10-04-named-partition-work/summarize.py
```

Drivers 使用 exclusive log/output creation，避免覆寫。重現須還原到新目錄並調整
driver 內的來源路徑；不可在凍結目錄盲跑。此次沒有新增 full Mojo／crash／Python／
C ABI／Linux／GPU／ASan／nonresident gate。
