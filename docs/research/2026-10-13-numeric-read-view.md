# Numeric reader：三個隔離版本與採用判定

**正式引擎未更動，三版皆尚未採用。** `_NumericReadView` 的型別、借用與計分
行為已在隔離來源通過；owned-backed 資料庫仍有暖查詢退步。bounded 版本保留
作為後續 immutable mapped owner 的實作基底，不能把這一步列為容量改善或
M5/M6 完成。[所有權計畫](../plans/2026-10-13-mapped-numeric-ownership.md) 的
Task 1 production adoption 仍待完成。

## 範圍與行為

每版皆複製完整 121-file source（包含新增 reader 與 binding entry）及 Python
package。正式 120 個 source hashes、Python library、C library 保持不變；
production engine 仍為 `6d01819`，本輪基線 commit 為 `2fea9c9`。

reader 保留來源的 immutable origin，指向 owned List 或 MappedFile owner。
它提供 checked scalar/SIMD loads 與 subrows，mapped loads 明確不要求對齊；
不回傳原始 pointer、不複製 List，也不改變 scalar authority。內部 prepared F32
與 typed field metrics 使用 reader，公開 List getter 與 non-raising legacy
accessor 不變。資料庫 recovery 尚未建立 mapped numeric rows；mapped scoring
目前只在新 behavior tests 中使用。

編譯器驗證發現，Mojo 1.0 雖拒絕修改 reader 的回傳值與把 local owner 的 reader
回傳成 static origin，卻允許 `values.clear()` 後再讀既有 reader。因此 owned
loads 除了 row bounds，也檢查目前 List 的長度；新 regression 證實清空後拒絕
scalar/SIMD/subrow 存取。原本允許 mutation 的 compile-only probe **從未執行**。
mapping close 後的讀取同樣拒絕。這些檢查不取代 operation owner 或並行同步。

## 固定暖查詢

相同三資料集、8192 points、k=10、seed=12345、每模式 64 timed + 3 warmups、
既定 ef、oracle、filters 與 reopen fixture。每版各三次輪替 baseline/candidate/
Qdrant triples，27 workers 全部完成。Qdrant Edge 0.8.0；Mac M4 Pro、24 GiB，
與使用者應用共用主機。所有波動均保留，不重跑到通過。

| 隔離版本 | 本版改動 | 同批 baseline → candidate 速度格 | pass→fail | Mojo | Python |
|---|---|---:|---:|---:|---:|
| checked reader | 具體 reader + checked loads | 21/36 → 21/36 | 1 | 74 | 359 |
| inline | inline F32 checked/prepared kernels 與 typed numeric score | 22/36 → 20/36 | 3 | 74 | 未跑 |
| bounded | inline 版的兩個 SIMD loops 改為 `offset <= count - width` | 25/36 → 23/36 | 3 | 23 | 359 |

三批前後品質各 **36/36**。每格仍要求 Recall@10 ≥ .95、QPS ≥ Qdrant **且**
p95 ≤ Qdrant。各批 baseline 不同，不能拿不同批次的計數直接相減。
不同版本的測試也不加總成一次完整驗證。

每版 2304 timed + 108 warmup 配對回應的 IDs、F32 score bits、visit stats 與
execution decisions 全相同。三版合計 81 workers 完成 21,708 exact oracle
checks、20,736 timed responses；反覆使用既定 queries 不是新的獨立 recall 樣本。

全量 exact 的 candidate/baseline QPS 比率：

| 版本 | uniform-128（三次） | uniform-1536（三次） |
|---|---|---|
| checked reader | .755 / .771 / .765 | .746 / .761 / .717 |
| inline | .864 / .853 / .854 | .828 / .764 / .770 |
| bounded | 1.047 / .949 / .952 | .969 / .938 / .951 |

bounded 高維全量 exact 的 p95 比率為 .987 / 1.043 / 1.037；仍有 QPS 退步，
也不能把幾格改善抵銷其他格。完整每格 latency、p50/p95/p99、Qdrant gates 皆
保存在 raw reports。

所有 pass→fail：

- checked：uniform-128 trial 2 selective。
- inline：uniform-128 trial 0 selective；uniform-1536 trials 0、2 selective。
- bounded：uniform-128 trial 1 selective；real-1536 trials 0、1 all。

## 機器碼與驗證

checked reader 的 prepared Dot width=16 kernel 從 167 instructions／668 bytes
增至 553／2212，包含 owned/mapped 分支與 live bounds。強制 inline 後不再保留
獨立 checked kernel symbols，但 exact caller 從 1114／4456 增至 3655／14620；
bounded 為 3522／14088。這是實際 binary 的 address-bounded disassembly，
不是原始碼大小或查詢時間；不能僅由程式碼大小推定效能。

9 個新 cases 涵蓋五種 scalar、signed zero/subnormal/NaN bit patterns、未對齊
loads、negative/overflow/truncated ranges、空資料、kind/dtype checks、explicit
close/clear，以及 10 種維度的單候選／雙候選 mapped/owned 混合計分位元。
既有 65 cases 包含 SIMD、paired exact、VectorValue、field metrics、flat、metric
dispatch、field rerank/IVF 與 generation fields。前兩版各跑完整 74；bounded
重跑新 9 + SIMD 9 + paired 5。checked／bounded 各完整 Python 359 通過，子
compiler 的相對與絕對 includes 皆導向該候選，完整呼叫紀錄已保存。

初始 missing-module failure、origin mismatch、mutable alias rejection、允許
owner mutation 的編譯結果、第一次選錯 disassembly symbol 的空結果，以及
bounded setup 的 assertion failure 均保留。setup failure 在寫 source 前發生，
當時的一次測試實際仍是 inline copy，不算 bounded 的新驗證。

沒有執行本輪 mixed、memory-cap、Linux、C ABI、crash 或 GPU suites。因未採用
且 durable/owner 路徑尚未改，沒有重跑既有容量矩陣。已有的 Linux emulation
結果仍不能列為 native Linux performance。

## 重現與來源

compiler 為 Mojo 1.0.0 (`ed45d567`)，flags 為 Metal:4／Apple M4。每版目錄位於
`.build/m5-resume/numeric-read-view{,-inline,-bounded}/`；`run.py`、`build.py`、
`verify.py`、`verify-python.py`、`measure-warm.py` 與 `assembly-kernels.py`
保存實際命令。所有 builds/tests/benchmarks/compression 依序執行，未覆寫使用中
的 library。第三版是後續隔離工作的基底；前兩版凍結不再修改。

| Binary | SHA-256 |
|---|---|
| 正式／baseline | `45b24374c5e19ee4d67d3523c59788b22064e69c6838955148fe6cfb52e798b9` |
| checked | `95cb12d5f15d358b7b58e5ebb2a7c8fe1aac39288ed1f92e9faa7e610036b2ec` |
| inline | `7eb19445e69df5fb6a7503475708ca3c82b9fe612f38dc83ba7aa6479d912bd1` |
| bounded | `0ecc68900d8c9b36da676d3ce692d6b3907917e784d094398e5cf34f40545d03` |

[凍結 source、drivers、logs、assembly 與完整 reports](2026-10-13-numeric-read-view.json.gz)。
Archive SHA-256：`655b804753a5ba01825c6c6b9780a17fa51acc444ffcc8e19bf23d1140aa1734`
（952 files，21,852,443 bytes）。
