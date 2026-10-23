# HNSW visit：縮小可變參數範圍

**已採用這項單檔局部改進；完整效能 gate 仍 FAILED，M5/M6 未完成。**
Named 高維 selective 在六個原選定 trials 都改善 QPS 與 p95；所有原始慢樣本、
低 recall 格及四個 Qdrant performance pass→fail 都保留，沒有跨格抵銷。

## 實作與採用依據

[Traversal 診斷](../research/2026-10-04-traversal-work.md)量到 named selective 的
visit 占 query samples 8.6–9.6%。[本次設計](../plans/2026-10-04-visit-arguments.md)
只改 `hnsw_scratch.mojo`：將原有 checked visit body 移至 private `_visit_epoch`，
可變參數只包含 `List[UInt32]`，其餘為 epoch、prepared count、slot。既有 `visit`
方法委派給 helper，所有 checks、錯誤字串、word 讀寫及其他 scratch 方法不變。
没有新 type、cache、配置、套件、inline annotation、raw pointer/Span 或資料格式。

Compiler 自行展開小型委派 method，公開 traversal 呼叫改成較小的 helper：

| 正式編譯產物 | Before | After |
|---|---:|---:|
| Visit callee 整個 function 指令數 | 124 | 108 |
| Visit callee bytes | 496 | 432 |
| Visit callee 靜態 store 指令數 | 21 | 14 |
| Mapped filtered cosine layer 指令數 | 1,170 | 1,118 |
| 同一 layer bytes | 4,680 | 4,472 |

以上包含 prologue/errors，不是動態操作數或速度估算。兩版仍檢查未 begin、prepared
slot domain 及 List bounds。原 whole-scratch visit 的多個無關欄位搬移縮小，並保留
相同 mutable List owner。Epoch wrap、hidden capacity、growth 及 heap 狀態均未改。

Native named selective profiles 的 visit exclusive 占比從 **9.59→7.98%**
（uniform-1536）、**8.57→6.80%**（real-1536）；other HNSW 為14.15→11.23%、
13.22→11.00%。前後四個 profiles 共6,336 repeat audits與268 warmups，每次核對
IDs/F64 bits/stats。Before profiles 重用本輪先前的正式診斷，after 為另行七秒
重播／五秒取樣。百分比不是固定 query 的絕對成本，profile durations 不取代 gate。

採用依據是行為一致、實際呼叫／返回資料縮小，且被 profile 指向的 named selective
有重複公開查詢收益。這項決定沒有將任何 timing regression 改列為通過；也沒有
證明所有查詢都更快。正式 Qdrant 驗收仍依下方的每一原始格／trial 判定。

## 驗證範圍

Mojo 1.0.0 (`ed45d567`)，Apple M4 / Metal:4；copied binding entry 與 copied source
編譯，saved package pytest 使用 `-o pythonpath=` 並核對 import path／kernel hash。

- **110 unique targeted Mojo**：scratch 11、layer 14、group order 1、live radius 3、
  filtered 8、widening 9、mutation 12、quantized 14、invariants 14、segmented 18、
  named 6。既有測試涵蓋極端 slot、epoch wrap、invalid inputs、hidden capacity、
  deleted/replaced bridges、原生後端與 snapshot/concurrent-build。
- **506 完整 Python**、重建 **C ABI/client**、**3 rebuilt examples** 通過。
- 採用完全相同的 source/Python/C artifacts 後，正式路徑再通過 **11 Mojo／143
  Python**、C client 與三個 examples；C loader 實際路徑核對為 `.build/c`。
  這些重複檢查不加總成新 unique tests。Native worker 未改。

首輪506 Python也通過，但 child compiler wrapper 當時只重導相對 `-I src`，
漏了 absolute `ROOT/src`。該輪 child probes 因而使用正式舊 source；原始 logs／
wrapper 全保留。修正後完整重跑506，記錄並核對12個 original-source includes均
導向 candidate，才視為候選完整驗證。這是 harness 修正，沒有引擎測試失敗。
只有既有 Starlette/httpx deprecation warning。TestSuite 的時間單位為毫秒。

沒有新版完整 Mojo/crash／HTTP performance／Linux／GPU／ASan／持續 nonresident
或 controlled-memory gate。未變動的 storage/crash 證據沿用原有範圍，不能標成
本次完整引擎整合。Linux runner 仍不可用。

## Named：原三 corpus／三 trial／全部六 ef

18 workers，原 graph bytes、corpora/seeds/filters/K/ef/service boundaries 不變。
共28,944 ANN audits／4,824 exact ID checks；14,472 paired IDs／F64 bits／全部
stats相同。品質兩版均132/216，84個低recall格全部保留。36個選定格有12個QPS或
p95退步。以下列出全部選定 trials，不能用中位數掩蓋其中的慢樣本。

| Corpus / filter | ef | QPS after/before, trials 0 / 1 / 2 | p95 after/before, trials 0 / 1 / 2 |
|---|---:|---|---|
| uniform-128 / all | 128 | 1.2030 / 1.1165 / 1.0890 | 0.7764 / 0.8934 / 0.9977 |
| uniform-128 / correlated | 256 | 0.9353 / 1.0139 / 1.0630 | 1.2629 / 1.1337 / 0.9684 |
| uniform-128 / independent | 128 | 0.9868 / 1.0594 / 0.9506 | 0.8471 / 0.8757 / 1.2964 |
| uniform-128 / selective | 128 | 1.0985 / 1.1647 / 0.8870 | 0.9234 / 0.7930 / 1.0595 |
| uniform-1536 / all | 512 | 1.0826 / 1.0641 / 1.0058 | 0.9065 / 0.9372 / 1.0376 |
| uniform-1536 / correlated | 512 | 1.0361 / 1.0187 / 1.0321 | 0.9588 / 1.0110 / 0.9601 |
| uniform-1536 / independent | 512 | 1.0709 / 1.0271 / 1.0334 | 0.8976 / 0.9790 / 0.9574 |
| uniform-1536 / selective | 256 | 1.0420 / 1.0333 / 1.0610 | 0.9841 / 0.9984 / 0.9365 |
| real-1536 / all | 32 | 0.9924 / 0.9833 / 1.0227 | 0.9996 / 1.1316 / 0.9878 |
| real-1536 / correlated | 64 | 0.9891 / 1.0090 / 1.0087 | 1.0273 / 1.0359 / 0.9950 |
| real-1536 / independent | 64 | 1.0216 / 1.0269 / 0.9777 | 0.9502 / 0.9380 / 1.0697 |
| real-1536 / selective | 128 | 1.0607 / 1.0617 / 1.0719 | 0.9406 / 0.9309 / 0.9633 |

QPS ratio >1、p95 ratio <1 較好。Uniform-1536 selective QPS提高3.3–6.1%，
real selective提高6.1–7.2%；六次p95皆改善。Named uniform-128 all提高8.9–20.3%，
但其他128D filters仍有退步。這是named診斷，不能代替原default Qdrant矩陣。

## 原始 Qdrant warm／mixed gate

54 workers串行完成，原B/A/Q、Q/A/B、B/A/Q順序與所有corpora、efs、filters、K、
trials、service boundaries保留。沒有build/test/profile/compression重疊。
每格Recall@10 ≥ .95、QPS ≥ Qdrant且p95 ≤ Qdrant；沒有容許差距。

| Gate | Before | After | Quality |
|---|---:|---:|---|
| Warm strict parity | 18/36 | 19/36 | 各36/36 |
| Mixed query strict parity | 24/36 | 27/36 | 各36/36 |
| Durable write+flush parity | 3/9 | 3/9 | 原durability/oracle驗證通過 |

P/F按trial 0/1/2排列，由未四捨五入的QPS及p95判定：

| Corpus / filter | Warm before → after | Mixed before → after |
|---|---|---|
| uniform-128 / all | FFF → FFF | PPP → PPP |
| uniform-128 / correlated | PPP → PPP | PPP → PPP |
| uniform-128 / independent | PPP → PPP | PPP → PPP |
| uniform-128 / selective | FPP → FPP | PFP → FFP |
| uniform-1536 / all | PPP → PPP | PPP → PPP |
| uniform-1536 / correlated | PPP → PPP | PPP → PPP |
| uniform-1536 / independent | PPP → PPP | PPP → PPP |
| uniform-1536 / selective | FFF → PFF | PFF → FPP |
| real-1536 / all | FPF → FFP | PFP → PPP |
| real-1536 / correlated | FFF → FFF | FFF → PPF |
| real-1536 / independent | FFF → FFF | FFF → FFF |
| real-1536 / selective | FFF → FFF | FPF → PFF |

四個performance pass→fail：warm real-all trial1；mixed uniform-128 selective
trial0、uniform-1536 selective trial0、real selective trial1。全部保留。A/B timing
regressions為warm20/36、mixed18/36；這份比較不能把每個差異歸因到某個source細節。
原default uniform workloads與real selective走planned exact，也不能拿這些格的變化
當成HNSW helper加速證據。

Warm共有7,236三方query audits與7,236 exact checks；2,412 paired IDs/stats及
24,120 F32 bits一致。Mixed有7,776三方audits、2,592 paired IDs/stats與25,920
F32 bits一致；每份原32-block寫入／flush、最終reopen、Arrow lease驗證均完成。
所有workers exit0；獨立assessment exit1是正確的**FAILED**，不是量測沒跑完。

## 正式狀態與凍結證據

來源基線HEAD `a984c3f`，原engine `ac48cda`，加上本次唯一scratch source改動。
正式Python kernel SHA-256：
`3ec07dc3c9711ccdb024311831a86c3ed844556c383f7b5de9dcbae535d893c1`。
正式C library：
`36079fa20ee5da05820f11eeb3120514ceafc19b299526871baa6eaf1fd27e77`。
Native worker保持
`bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`。

[Frozen archive](results/2026-10-04-visit-arguments.json.gz)：589 entries，
9,173,867 bytes，SHA-256
`b2af3bd07d4fd0fc5784afd3c0fd4ea89d0d7b8d0bc1a03437234554886a492b`。
已解壓回讀全部entry hashes。包括copied sources/patch、原始曲線與所有samples、
profiles、assembly、harness correction、tests/JUnit、commands、child include audit、
C/examples及promotion loader／identity證據。Binary、DB及workload payload只存hash。

暫存 `.build/2026-10-04-visit-arguments` 已凍結。原writing drivers及身份guard描述
實際當時的before/after階段；不要在原目錄重跑或改寫archive。重現時在新目錄恢復
sources/scripts、固定原inputs與graph bytes、核對各階段package／compiler identity，
依序build→targeted→curves→matrix→profiles→full Python→C/examples；採用後另驗證
正式路徑。`summarize-matrix.py`的預期退出碼仍是1。

目前可直接重跑的窄回歸：

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run -I src tests/mojo/test_hnsw_scratch.mojo
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD/python:$PWD:$PWD/.build/qdrant-compare/deps" python -m pytest tests/python/test_named_vectors.py tests/python/test_native_oracles.py tests/python/test_field_rerank.py -q -o pythonpath=
```

接續處理原real ANN／selective失敗格與M5多run／更新後重開生命週期；距離仍為主要
查詢成本。此次縮小visit參數不能視為artifact生命週期或原完整矩陣已完成。
