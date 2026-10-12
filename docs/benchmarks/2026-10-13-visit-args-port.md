# HNSW visit 參數縮減對照：本輪未採用

在 `6d01819` 的隔離完整 source/package 上，試移植既有
`8ba04ce07125e5b28fad51fc31d68b05b2e573b6`。原 parent 的 scratch source 與正式
檔案逐位元一致；候選只將 checked visit body 移到接收 mutable epoch List、
epoch、prepared count、slot 的 private helper，保留所有檢查與錯誤字串。

**未採用。** 同批暖查詢速度 **21/36 → 19/36**、mixed **23/36 → 18/36**，
分別有 **2／5 格 pass→fail**。前後品質皆 **36/36**，write + flush 都是 **3/9**。
Real ANN 的 QPS 在 15/18 格改善，p95 在 11/18 格改善，但局部小幅收益不足以
支持本輪採用。所有改善與退步都保留，未將不利結果改列為雜訊或重跑直到通過。
正式引擎與 Python／C binary 保持 `6d01819`。**M5/M6 仍 FAILED。**

## 行為與編譯產物

候選未新增 cache、配置、unsafe 存取或 inline annotation，沒有改 epoch／slot
寬度、配置行為、heap 操作、遍歷與計分順序。既有 scratch 案例涵蓋未 begin、
極端 slot、epoch wrap、hidden capacity、growth 與 heap 重用，沒有為 helper
另寫只鏡射實作的測試。

實際 Mac Mojo 1.0.0／Metal:4／Apple M4 Python library 的反組譯：

| 範圍 | Before | After |
|---|---:|---:|
| Visit callee 指令 | 124 | 108 |
| Visit callee bytes | 496 | 432 |
| Visit callee 靜態 store 指令 | 25 | 18 |
| Mapped filtered cosine layer 指令 | 1170 | 1118 |
| 同一 layer bytes | 4680 | 4472 |
| 同一 layer 靜態 visit calls | 2 | 2 |

這些是整函式靜態計數，含 prologue／錯誤路徑，不能當作動態成本或速度估計。
Store 計數包含 `stp`、`str`、`strb`、`stur`，不直接沿用原分支不同計數口徑。
兩版保留 epoch、prepared domain 及 List bounds checks；candidate 返回資料縮小。
第一次 `--macho --disassemble-symbols` 指令實際輸出整份 binary，已保留原輸出；
表格依後續 start/stop address 範圍反組譯計算。

## 本輪驗證與量測

107 個不同 Mojo 案例通過：scratch 11、layer 14、group 1、live radius 3、
filtered 8、widening 9、mutation 12、quantized 14、invariants 14、segmented 18、
named 3。完整 Python **359 passed**，3 個既有 warnings；child compiler wrapper
同時將相對與絕對 source includes 導向完整 120-file 候選樹。未在正式樹修改 source。

因未採用而停止進一步 adoption 驗證：C ABI／範例尚未執行，Linux 已準備 source
與四個 test copies，但未啟動容器或執行測試；這些準備檔仍保存，不列為通過。
Storage／GPU 未改，沒有重跑 crash／GPU，也未沿用舊 branch 結果當成本輪成功。

Candidate Python SHA-256：
`e12fb56498c0dcd96973a47f21da14d19aee4ca7649b65a513647d55cd7783b6`。
正式 baseline：`45b24374c5e19ee4d67d3523c59788b22064e69c6838955148fe6cfb52e798b9`。
採用判定時重新核對正式 120-file source 與 baseline binary hashes，皆未改。

沿用 [固定方法](2026-10-13-four-neighbor-port.md)：三 corpus、8192 points、
seed 12345、k=10、四模式、原 oracle／ef／timing boundary、Qdrant Edge 0.8.0，
每 corpus 三次 BAQ/AQB/QBA serial triples。Mixed 使用原三份 frozen 32-block
plans，無 retuning／tolerance／跨格抵銷。Build、tests、benchmark、compression
串行；沒有只挑有利資料，也沒有計入外部 HTTP 或持續 non-resident 驗收。

Warm 27 workers 完成，共 7,236 exact checks、6,912 timed response checks、
324 warmups；baseline/candidate 2,304 paired timed queries 與 108 paired
warmups 的 IDs／F32 bits／stats 相同。Mixed 27 workers 完成，7,776 audits、
27 reopens、18 Akasha leases 通過；2,592 paired queries 的 IDs／F32 bits／
stats／execution 全同。固定 query 重複不是新獨立品質樣本。Mixed exit 1 是
嚴格速度 gate FAILED，不是 worker 執行未完成。

Warm pass→fail：uniform-1536 trial 1 selective、real-1536 trial 1 all。
Mixed pass→fail：uniform-128 trial 2 selective、uniform-1536 trials 0/2
selective、real-1536 trial 1 all、trial 2 selective。其餘波動也完整列於下表。

Real ANN 九格暖查詢 QPS 7 格改善、p95 5 格改善；mixed 各為 8／6 格。
不能用這些格抵銷七個 pass→fail，亦不能將 exact 路徑波動歸因於 visit helper。
共享 M4 Pro／24 GiB 主機，量測前 swap used 21,274 MiB，無已記錄的 thermal／
performance warning，不代表沒有干擾；本輪沒有建立每個差異的因果歸屬。
舊 branch 的 named curves 屬不同 scope，不能取代當前 default matrix 的採用依據。

A/B 為 candidate/baseline，A/Q 為 candidate/Qdrant。QPS 越高越好、p95 越低越好；
表格顯示三位小數，狀態使用原始完整精度。

### warm

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 0.968 | 1.001 | 0.794 | 1.296 | FAILED → FAILED |
| uniform-128 | 0 | correlated | 1.319 | 0.518 | 3.091 | 0.386 | PASSED → PASSED |
| uniform-128 | 0 | independent | 0.958 | 1.043 | 3.029 | 0.344 | PASSED → PASSED |
| uniform-128 | 0 | selective | 1.024 | 0.848 | 1.248 | 0.712 | PASSED → PASSED |
| uniform-128 | 1 | all | 0.985 | 1.030 | 0.857 | 1.113 | FAILED → FAILED |
| uniform-128 | 1 | correlated | 0.762 | 1.966 | 2.103 | 0.904 | PASSED → PASSED |
| uniform-128 | 1 | independent | 1.043 | 0.959 | 2.645 | 0.506 | PASSED → PASSED |
| uniform-128 | 1 | selective | 1.071 | 0.973 | 1.092 | 0.885 | PASSED → PASSED |
| uniform-128 | 2 | all | 1.098 | 0.815 | 0.882 | 1.096 | FAILED → FAILED |
| uniform-128 | 2 | correlated | 1.051 | 0.928 | 3.313 | 0.293 | PASSED → PASSED |
| uniform-128 | 2 | independent | 1.015 | 0.969 | 3.029 | 0.406 | PASSED → PASSED |
| uniform-128 | 2 | selective | 1.460 | 0.809 | 0.834 | 1.848 | FAILED → FAILED |
| uniform-1536 | 0 | all | 0.946 | 0.980 | 2.461 | 0.415 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 0.926 | 1.035 | 1.466 | 0.754 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 0.953 | 1.005 | 1.533 | 0.696 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 1.055 | 0.904 | 0.959 | 1.043 | FAILED → FAILED |
| uniform-1536 | 1 | all | 0.957 | 1.059 | 2.435 | 0.412 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 0.969 | 1.031 | 1.518 | 0.723 | PASSED → PASSED |
| uniform-1536 | 1 | independent | 0.991 | 1.008 | 1.591 | 0.693 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 0.994 | 1.086 | 0.995 | 1.052 | PASSED → FAILED |
| uniform-1536 | 2 | all | 1.026 | 0.940 | 2.544 | 0.399 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 0.983 | 1.025 | 1.511 | 0.738 | PASSED → PASSED |
| uniform-1536 | 2 | independent | 1.023 | 1.004 | 1.701 | 0.676 | PASSED → PASSED |
| uniform-1536 | 2 | selective | 1.047 | 0.941 | 0.998 | 1.032 | FAILED → FAILED |
| real-1536 | 0 | all | 1.018 | 0.996 | 1.091 | 0.957 | PASSED → PASSED |
| real-1536 | 0 | correlated | 1.096 | 0.874 | 0.851 | 1.066 | FAILED → FAILED |
| real-1536 | 0 | independent | 1.026 | 0.967 | 0.765 | 1.216 | FAILED → FAILED |
| real-1536 | 0 | selective | 1.020 | 0.956 | 0.959 | 1.091 | FAILED → FAILED |
| real-1536 | 1 | all | 0.881 | 1.133 | 0.957 | 1.096 | PASSED → FAILED |
| real-1536 | 1 | correlated | 0.957 | 1.107 | 0.813 | 1.159 | FAILED → FAILED |
| real-1536 | 1 | independent | 1.008 | 1.003 | 0.753 | 1.270 | FAILED → FAILED |
| real-1536 | 1 | selective | 0.989 | 1.005 | 0.937 | 1.084 | FAILED → FAILED |
| real-1536 | 2 | all | 1.038 | 0.937 | 1.150 | 0.915 | PASSED → PASSED |
| real-1536 | 2 | correlated | 1.025 | 0.965 | 0.877 | 1.062 | FAILED → FAILED |
| real-1536 | 2 | independent | 1.009 | 1.001 | 0.797 | 1.196 | FAILED → FAILED |
| real-1536 | 2 | selective | 1.232 | 0.659 | 0.958 | 0.989 | FAILED → FAILED |

### mixed

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 1.064 | 0.618 | 1.870 | 0.451 | PASSED → PASSED |
| uniform-128 | 0 | correlated | 0.970 | 0.996 | 3.482 | 0.604 | PASSED → PASSED |
| uniform-128 | 0 | independent | 0.911 | 1.379 | 3.683 | 0.551 | PASSED → PASSED |
| uniform-128 | 0 | selective | 0.850 | 1.747 | 1.296 | 2.098 | FAILED → FAILED |
| uniform-128 | 1 | all | 1.016 | 0.991 | 1.709 | 0.485 | PASSED → PASSED |
| uniform-128 | 1 | correlated | 1.186 | 0.867 | 3.456 | 0.601 | PASSED → PASSED |
| uniform-128 | 1 | independent | 0.982 | 1.142 | 3.358 | 0.776 | PASSED → PASSED |
| uniform-128 | 1 | selective | 1.033 | 0.898 | 1.108 | 2.559 | FAILED → FAILED |
| uniform-128 | 2 | all | 1.280 | 0.815 | 2.000 | 0.585 | PASSED → PASSED |
| uniform-128 | 2 | correlated | 1.067 | 1.050 | 4.128 | 0.338 | PASSED → PASSED |
| uniform-128 | 2 | independent | 1.019 | 1.028 | 3.796 | 0.538 | PASSED → PASSED |
| uniform-128 | 2 | selective | 0.663 | 2.788 | 1.207 | 1.681 | PASSED → FAILED |
| uniform-1536 | 0 | all | 0.995 | 1.013 | 2.419 | 0.411 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 0.986 | 0.957 | 1.766 | 0.622 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 0.920 | 1.064 | 1.790 | 0.611 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 0.953 | 1.297 | 1.091 | 1.178 | PASSED → FAILED |
| uniform-1536 | 1 | all | 0.980 | 1.068 | 2.417 | 0.446 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 0.977 | 1.099 | 1.848 | 0.626 | PASSED → PASSED |
| uniform-1536 | 1 | independent | 0.953 | 0.979 | 1.827 | 0.624 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 0.983 | 0.901 | 1.125 | 1.438 | FAILED → FAILED |
| uniform-1536 | 2 | all | 1.015 | 0.926 | 2.585 | 0.358 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 1.002 | 0.987 | 1.900 | 0.617 | PASSED → PASSED |
| uniform-1536 | 2 | independent | 1.030 | 0.822 | 2.026 | 0.521 | PASSED → PASSED |
| uniform-1536 | 2 | selective | 0.944 | 1.392 | 1.181 | 1.182 | PASSED → FAILED |
| real-1536 | 0 | all | 1.014 | 1.073 | 0.936 | 1.040 | FAILED → FAILED |
| real-1536 | 0 | correlated | 1.005 | 0.954 | 0.868 | 1.010 | FAILED → FAILED |
| real-1536 | 0 | independent | 1.026 | 0.945 | 0.564 | 1.490 | FAILED → FAILED |
| real-1536 | 0 | selective | 1.029 | 0.751 | 0.960 | 1.074 | FAILED → FAILED |
| real-1536 | 1 | all | 1.024 | 1.034 | 1.044 | 1.033 | PASSED → FAILED |
| real-1536 | 1 | correlated | 0.999 | 1.007 | 0.929 | 1.137 | FAILED → FAILED |
| real-1536 | 1 | independent | 1.027 | 0.933 | 0.613 | 1.610 | FAILED → FAILED |
| real-1536 | 1 | selective | 0.982 | 0.787 | 1.054 | 1.093 | FAILED → FAILED |
| real-1536 | 2 | all | 1.010 | 0.982 | 1.047 | 1.041 | FAILED → FAILED |
| real-1536 | 2 | correlated | 1.023 | 0.914 | 0.964 | 1.056 | FAILED → FAILED |
| real-1536 | 2 | independent | 1.003 | 0.889 | 0.613 | 1.625 | FAILED → FAILED |
| real-1536 | 2 | selective | 0.945 | 1.362 | 1.079 | 1.274 | PASSED → FAILED |

## 不可變證據

[原始資料](2026-10-13-visit-args-port.json.gz) 包含移植來源與原分支設計／報告、
候選 patch／source、實際編譯產物摘錄及原完整 disassembly、validation commands／
logs、所有 warm／mixed jobs／reports／逐 query samples、三份 frozen mixed plans、
host／source／binary identities、child compiler argv、未執行的驗證準備與拒絕紀錄。
解壓後每檔 SHA-256、27 mixed worker plan hashes 重新核對通過。

Archive SHA-256：`4f7691466f952a9c0c4fa7303d8b5bba6d96e18cce9ccd86fa840049a539b269`
（230 files，26,172,760 bytes）。
