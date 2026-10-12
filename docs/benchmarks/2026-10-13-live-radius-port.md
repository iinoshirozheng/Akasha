# Filtered HNSW 排除 inactive 節點的半徑占用

將既有 `cc15f37632fbe8c54948726882753a023b1c0fdc` 的 correctness 修正移植到
`f5184da`，僅修改 `hnsw_core.mojo` 並加入三個 regression cases。
刪除／取代的節點仍可當作通路，但不再占用 filtered search 的 retained
traversal radius；current 節點仍占半徑，與 metadata eligibility 無關。

三個 baseline 漏查案例皆失敗，候選在 generic 與專用 F32 L2 backend 皆通過。
採用依據是正確性。新同批暖查詢速度 **23/36 → 22/36**，mixed **24/36 → 26/36**，
前後品質皆 **36/36**；兩組各有 **1 格 pass→fail**，所有退步保留。
write + flush 前後仍 **3/9**。**M5/M6 仍 FAILED**，不宣稱此修正改善速度。

## 行為與驗證

舊 filtered 路徑會將距離很近的 inactive entry 或中間節點放進 navigation
heap，使 `ef=1` 的 retained radius 過窄；即使 admission flags 全為 true，
也可能回傳空結果或漏掉 unfiltered 路徑找到的最近 current 節點。
修正只在 filtered entry／neighbor 的 radius admission 前檢查 `is_current`。
候選 frontier、metadata 判斷、距離 kernel、持久化格式與公共介面未改。

新增三個案例分別覆蓋 deleted entry + bridge、deleted middle、replaced
middle，檢查結果及 visited／distance／rejection stats 與 unfiltered 一致。
每個候選案例呼叫 generic 和 specialized F32 L2 兩條路徑。Baseline 三個案例
均在第一個 generic 呼叫失敗，不能計為六個獨立 red cases。

| 範圍 | 本輪結果 |
|---|---|
| Targeted Mojo | 100 個不同案例通過，包含新三案例與 search layer、filter、stats、widening、mapped／quantized、incremental HNSW 等 |
| Python | 完整 359 passed，3 個既有 warnings；child compiler 導向隔離 source |
| C ABI | 隔離 shared library 與 `-Wall -Wextra -Werror` C client 重建執行通過 |
| 範例 | smoke、persistent_collection、configured_hnsw 通過 |
| Linux x86-64 模擬 | 新案例 3、search layer 14、filtered 8，共 25 個不同案例通過 |

Mac 使用 Mojo 1.0.0、`metal:4`／`apple-m4`，完整 120 個 source 與 binding
entry 在隔離樹編譯。採用時 root、Mac、Linux 隔離 source hashes 全部一致，
root 使用已測 Python／C binary。Linux 為 pinned Docker emulated
Westmere/SSE4.2，不能代表 native Linux performance。此次未改 storage／GPU，
未重跑 crash／GPU suite，也未將先前結果列為本輪新驗證。

Candidate Python SHA-256：
`45b24374c5e19ee4d67d3523c59788b22064e69c6838955148fe6cfb52e798b9`。
Baseline：`0bf644c16b119dbec1c41b5098a01ac3d7dbd6b036e65a8263c5e7e6c51879c3`。

## 固定 workload 的配對結果

沿用 [固定方法](2026-10-13-four-neighbor-port.md)：三個 8192-point corpora、
seed 12345、k=10、四 modes、原 oracle／ef／timing boundary、Qdrant Edge 0.8.0，
每 corpus 三次 BAQ/AQB/QBA serial triples，各自複製關閉資料庫再 reopen。
Mixed 使用原三份 frozen 32-block plans；沒有調整 ef、排除慢樣本或更換資料。
逐格門檻仍 Recall@10 ≥ .95、QPS ≥ Qdrant 且 p95 ≤ Qdrant，無 tolerance。

Warm 共 7,236 exact checks、6,912 timed response checks、324 warmups，
27 workers 完成。Baseline／candidate 的 2,304 paired timed responses 與
108 paired warmups，IDs、score vectors、stats 全同，共 24,120 個 Float32
score bit checks。Mixed 27 workers 全部完成，7,776 query audits、27 reopen
checks、18 Akasha leases 通過；2,592 paired queries 的 IDs 與 score vectors
全同，共 25,920 個共同 result score bit checks。固定 query 的重複執行不增加
獨立品質樣本。Mixed runner exit 1 表示嚴格速度驗收失敗。

這是 traversal correctness 修正，配對 runner 明確允許 visited stats 改變，
仍逐次執行既有 oracle／execution 驗證並比較共同 ID 的分數位元。
Mixed 有 **120 組**統計改變，皆為 real-1536：independent 42、all 39、
correlated 39。每組的 inactive rejections、base visited、distance evaluations、
visited 均有變；81 組另有 filtered rejections 改變。公共 `all` 查詢也可能
使用內部 admission flags，所以不能說只有 metadata-filter modes 受影響。
完整逐 query 差異已保存。例如 trial 0/block 26 independent，base visited
2317 → 2375、distance evaluations 2386 → 2444、inactive rejections 165 → 178。

Warm uniform-128 selective trial 1 從 pass 轉 fail，QPS 為 baseline .871 倍、
p95 1.219 倍；mixed uniform-1536 selective trial 2 也從 pass 轉 fail，
QPS .914 倍、p95 1.723 倍。其餘改善與退步均列於下表，不跨格抵銷。
write + flush 僅 uniform-128 三次達標，仍有不同 durability／maintenance 邊界。

共享 M4 Pro／24 GiB 主機，量測前 swap used 21,458 MiB，無已記錄的 thermal／
performance warning，不代表無干擾。不能與上一批次直接相減推算效能，也不能
替代 memory-cap、雙方持續 non-resident、HTTP concurrency 或 native Linux gates。

A/B 為 candidate/baseline，A/Q 為 candidate/Qdrant；QPS 越大越好，p95 越小越好。
表格三位小數僅供顯示，pass/fail 使用原始完整精度。

### warm

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 0.997 | 1.072 | 0.831 | 1.254 | FAILED → FAILED |
| uniform-128 | 0 | correlated | 0.730 | 1.334 | 1.912 | 0.727 | PASSED → PASSED |
| uniform-128 | 0 | independent | 1.289 | 0.532 | 3.130 | 0.368 | PASSED → PASSED |
| uniform-128 | 0 | selective | 1.030 | 0.951 | 1.130 | 0.852 | PASSED → PASSED |
| uniform-128 | 1 | all | 1.017 | 0.952 | 0.839 | 1.141 | FAILED → FAILED |
| uniform-128 | 1 | correlated | 1.116 | 0.591 | 3.625 | 0.271 | PASSED → PASSED |
| uniform-128 | 1 | independent | 0.797 | 1.548 | 2.138 | 0.863 | PASSED → PASSED |
| uniform-128 | 1 | selective | 0.871 | 1.219 | 1.024 | 1.046 | PASSED → FAILED |
| uniform-128 | 2 | all | 1.016 | 0.962 | 1.201 | 0.620 | PASSED → PASSED |
| uniform-128 | 2 | correlated | 0.902 | 1.371 | 2.785 | 0.500 | PASSED → PASSED |
| uniform-128 | 2 | independent | 0.844 | 1.372 | 2.691 | 0.405 | PASSED → PASSED |
| uniform-128 | 2 | selective | 0.805 | 1.161 | 0.858 | 1.186 | FAILED → FAILED |
| uniform-1536 | 0 | all | 0.996 | 1.002 | 2.522 | 0.401 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 0.980 | 1.023 | 1.518 | 0.725 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 1.006 | 0.990 | 1.577 | 0.687 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 1.009 | 1.019 | 1.190 | 0.727 | PASSED → PASSED |
| uniform-1536 | 1 | all | 0.995 | 1.008 | 2.561 | 0.381 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 1.016 | 0.964 | 1.529 | 0.721 | PASSED → PASSED |
| uniform-1536 | 1 | independent | 0.997 | 1.008 | 1.552 | 0.712 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 0.965 | 1.112 | 1.045 | 0.882 | PASSED → PASSED |
| uniform-1536 | 2 | all | 0.995 | 1.001 | 2.512 | 0.395 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 0.999 | 1.001 | 1.573 | 0.723 | PASSED → PASSED |
| uniform-1536 | 2 | independent | 0.978 | 1.031 | 1.552 | 0.707 | PASSED → PASSED |
| uniform-1536 | 2 | selective | 0.977 | 1.062 | 1.135 | 0.838 | PASSED → PASSED |
| real-1536 | 0 | all | 0.966 | 1.034 | 1.113 | 0.933 | PASSED → PASSED |
| real-1536 | 0 | correlated | 0.962 | 1.031 | 0.830 | 1.124 | FAILED → FAILED |
| real-1536 | 0 | independent | 0.981 | 1.002 | 0.753 | 1.296 | FAILED → FAILED |
| real-1536 | 0 | selective | 1.015 | 1.035 | 0.987 | 1.003 | FAILED → FAILED |
| real-1536 | 1 | all | 1.010 | 0.953 | 1.131 | 0.916 | PASSED → PASSED |
| real-1536 | 1 | correlated | 1.005 | 1.001 | 0.816 | 1.134 | FAILED → FAILED |
| real-1536 | 1 | independent | 0.838 | 1.316 | 0.660 | 1.538 | FAILED → FAILED |
| real-1536 | 1 | selective | 1.020 | 0.960 | 0.959 | 1.093 | FAILED → FAILED |
| real-1536 | 2 | all | 0.975 | 1.006 | 1.049 | 1.006 | FAILED → FAILED |
| real-1536 | 2 | correlated | 1.075 | 0.930 | 0.895 | 1.025 | FAILED → FAILED |
| real-1536 | 2 | independent | 1.028 | 0.973 | 0.766 | 1.279 | FAILED → FAILED |
| real-1536 | 2 | selective | 0.971 | 1.068 | 0.914 | 1.141 | FAILED → FAILED |

### mixed

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 1.047 | 1.007 | 2.029 | 0.373 | PASSED → PASSED |
| uniform-128 | 0 | correlated | 1.046 | 0.905 | 4.038 | 0.301 | PASSED → PASSED |
| uniform-128 | 0 | independent | 0.992 | 0.781 | 3.715 | 0.408 | PASSED → PASSED |
| uniform-128 | 0 | selective | 1.322 | 0.338 | 1.707 | 0.644 | FAILED → PASSED |
| uniform-128 | 1 | all | 0.949 | 1.098 | 1.729 | 0.525 | PASSED → PASSED |
| uniform-128 | 1 | correlated | 0.870 | 1.831 | 3.276 | 0.673 | PASSED → PASSED |
| uniform-128 | 1 | independent | 1.080 | 0.760 | 3.282 | 0.482 | PASSED → PASSED |
| uniform-128 | 1 | selective | 1.044 | 1.094 | 1.382 | 0.834 | PASSED → PASSED |
| uniform-128 | 2 | all | 0.977 | 1.340 | 2.073 | 0.479 | PASSED → PASSED |
| uniform-128 | 2 | correlated | 1.034 | 0.840 | 4.275 | 0.326 | PASSED → PASSED |
| uniform-128 | 2 | independent | 1.100 | 0.570 | 4.290 | 0.322 | PASSED → PASSED |
| uniform-128 | 2 | selective | 0.962 | 0.890 | 1.386 | 1.558 | FAILED → FAILED |
| uniform-1536 | 0 | all | 1.012 | 0.999 | 2.495 | 0.416 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 1.003 | 1.013 | 1.836 | 0.647 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 1.000 | 1.003 | 1.897 | 0.623 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 1.452 | 0.553 | 1.148 | 0.910 | FAILED → PASSED |
| uniform-1536 | 1 | all | 1.008 | 0.951 | 2.442 | 0.396 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 1.016 | 0.957 | 1.792 | 0.705 | PASSED → PASSED |
| uniform-1536 | 1 | independent | 1.022 | 0.841 | 1.881 | 0.581 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 0.968 | 1.601 | 1.062 | 1.622 | FAILED → FAILED |
| uniform-1536 | 2 | all | 0.995 | 1.025 | 2.487 | 0.396 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 0.998 | 1.015 | 1.867 | 0.669 | PASSED → PASSED |
| uniform-1536 | 2 | independent | 0.980 | 1.090 | 1.948 | 0.574 | PASSED → PASSED |
| uniform-1536 | 2 | selective | 0.914 | 1.723 | 1.111 | 1.609 | PASSED → FAILED |
| real-1536 | 0 | all | 0.978 | 1.093 | 1.066 | 0.799 | PASSED → PASSED |
| real-1536 | 0 | correlated | 0.950 | 1.134 | 0.945 | 0.957 | FAILED → FAILED |
| real-1536 | 0 | independent | 0.970 | 1.032 | 0.634 | 1.297 | FAILED → FAILED |
| real-1536 | 0 | selective | 0.958 | 0.931 | 1.088 | 1.024 | FAILED → FAILED |
| real-1536 | 1 | all | 1.017 | 0.945 | 1.158 | 0.750 | PASSED → PASSED |
| real-1536 | 1 | correlated | 0.984 | 1.049 | 1.015 | 0.914 | PASSED → PASSED |
| real-1536 | 1 | independent | 0.990 | 0.988 | 0.668 | 1.344 | FAILED → FAILED |
| real-1536 | 1 | selective | 0.987 | 1.024 | 1.194 | 1.027 | FAILED → FAILED |
| real-1536 | 2 | all | 1.000 | 0.942 | 1.028 | 0.976 | FAILED → PASSED |
| real-1536 | 2 | correlated | 0.983 | 1.026 | 0.904 | 1.158 | FAILED → FAILED |
| real-1536 | 2 | independent | 1.021 | 0.988 | 0.615 | 1.637 | FAILED → FAILED |
| real-1536 | 2 | selective | 0.979 | 1.017 | 1.168 | 0.915 | PASSED → PASSED |

## 不可變證據

[原始資料](2026-10-13-live-radius-port.json.gz) 包含原始移植來源、實際測試版本、
baseline 失敗與候選 validation commands／logs、child compiler argv、全部 warm／
mixed worker jobs／reports／latencies／stats、差異列表、三份 frozen plans、
host／source／binary identities、方法及採用紀錄。解壓後每檔 SHA-256 與全部
27 mixed worker plan hashes 均重新核對通過。

Archive SHA-256：`b94266f1c68ac3b736dbd4ccd68cf8a5fa4b7936d46747ad14b83c2678ea8ca2`
（222 files，18,716,755 bytes）。
