# 四候選 F32 HNSW 移植與配對驗證

採用既有 feature branch 的 `c00494f2b2a06e9878f808f43b0b8cbb37bebcb0`：
F32 HNSW base-layer 一次計算四個 first-visited neighbor，共用 query loads，
各候選維持獨立 accumulator、原本 SIMD 寬度、reduction 與 tail 次序。
移植至本輪 `03720e8`（engine 包含 maintenance shared-state 與 mapped segment
reader 修正）。原 commit 的三個被改檔案，其 parent 版本與本輪原始版本逐 byte
相同；只移植 `hnsw_core.mojo`、`hnsw_storage.mojo`、`hnsw_view.mojo` 及兩個測試。
來源 branch head 為 `8241450`，此工作沒有合併該 branch 的其餘變更。

**本輪暖查詢與 mixed 配對品質皆為前後 36/36；速度分別為 16/36 → 19/36、
15/36 → 19/36，沒有 PASSED → FAILED。M5/M6 仍為 FAILED。**
採用依據是 real-1536 ANN 的穩定暖查詢改善及結果一致性；不能把未走此 kernel
的 exact 格波動歸因於此改動，也不能用增加的通過格數抵銷其他格失敗。

## 實作與驗證

分組只限 backend tag 0–2 的 F32 level 0；完整四筆共用 query loads，不足四筆、
其他 scalar kind、upper layer 保留原本距離 kernel。保留 owned row offset 與
mapped load 邊界檢查；first-visit 蒐集後仍按原順序更新 results、filtered
admission、candidate heap 與統計。格式及對外介面未變。

先以未修改 source 編譯新增測試，確認因缺少 `_distance_to_four_f32` 失敗；
再於包含完整 120 個 Mojo 檔案及 binding entry 的隔離 source tree 驗證：

| 範圍 | 本輪結果 |
|---|---|
| Mojo | 97 個不同案例通過：新增四候選距離 3、順序 1；既有 accumulator、dispatch、search layer、stats、widening、filtered、mapped view、quantization、mapped vectors、incremental collection |
| Python | 隔離 `_kernel.so` 完整 `tests/python`，356 passed |
| C ABI | 隔離 shared library 重建、`-Wall -Wextra -Werror` C 測試通過 |
| 範例 | smoke、persistent_collection、configured_hnsw 編譯執行通過 |
| Linux x86-64 模擬 | 四候選距離、順序、search layer、distance dispatch，31 個不同案例通過 |

新增距離測試涵蓋 dot／L2／cosine、owned／mapped、14 種維度（含 SIMD tail 與
1536）、重複／不同 slot、每 lane 越界、錯誤 query dimension 與 close 後拒絕。
逐 lane 比較單筆 kernel 的 Float32 bits。順序測試包含完整 group、tail、
重訪、filtered bridge、刪除、tie 與 scratch 重用。

Python 測試衍生 compiler 子程序的所有 root source include／entry 已導向隔離
source；wrapper 的 original/effective argv 全部保存，明確 cross-target 測試
保留其原 target。Mac 編譯使用 Mojo 1.0.0、`metal:4`／`apple-m4`。
Linux 使用既有 pinned Docker 環境、emulated Westmere/SSE4.2；不是 native
Linux／AVX 驗收。此次未改 GPU／durable format，未重跑完整 crash／GPU suites；
先前適用的驗證不加總成本輪新測試。

採用時核對 root、隔離 Mac、隔離 Linux 全部 120 個 source hash 一致。
root Python 使用量測及測試過的同一 binary：
`9009e41a9653079a667546e9dea06386c0c52fbe9094c958e7d82ea25bebf1b4`。
baseline binary 為
`c17d07a551109cb37d7322699ee2318b7d6d2dd3e8c5f8939997e3f00dacb630`。

## 方法與限制

沿用三組 frozen workloads：8192 points、seed 12345、k=10、四種 filter 模式、
原 oracle、更新／刪除資料與固定 ef。資料身份：

| Corpus | Metric | Workload SHA-256 |
|---|---|---|
| uniform-128 | dot | `9cf402d6b6917046a9422f0800dddf740ecc9e50505abb41c11a25a2cd8e97a0` |
| uniform-1536 | dot | `7b23e99079bb26134339ac2866df5ad6042776b2bc8f09a035198ce7d77d5c41` |
| real-1536 | cosine | `1d1572212d5f703e74cc842dcc44693f198680594eab9438e72e9d014143b091` |

Qdrant Edge 0.8.0 使用 pinned 真實 engine；Mac native binary SHA-256 為
`746ce4acdbb56db68aaba805bddf52961a083c5ed5da19f16b5ba500114c788d`。
每資料集三次 serial triple，次序 before/after/Q、after/Q/before、Q/before/after。
雙方資料庫各自複製再 reopen。門檻不變：Recall@10 ≥ .95、QPS ≥ Qdrant、
p95 ≤ Qdrant，使用未四捨五入值判定，不設 tolerance，不跨格抵銷。

| Corpus | Warm Akasha ef | Warm Qdrant ef | Mixed Akasha ef | Mixed Qdrant ef |
|---|---|---|---|---|
| uniform-128 | 128,32,32,10 | 96,256,256,10 | 128,32,32,32 | 128,256,256,32 |
| uniform-1536 | 512,128,128,10 | 512,512,512,10 | 512,128,128,32 | 512,512,512,32 |
| real-1536 | 16,32,40,10 | 24,128,128,10 | 32,32,64,32 | 32,128,128,32 |

ef 順序為 all、correlated、independent、selective。Warm 各 mode 3 warmups +
64 timed queries；baseline／candidate 共 2,304 paired timed responses 與 108
paired warmups 的 IDs、Float32 score bits、execution stats 一致。三版本 27
worker 共 7,236 exact oracle checks；重複固定 queries 不是新增獨立品質樣本。

Mixed 每 worker 32 個固定 block，各 9 queries、8 points upsert、flush，
每 mode 72 queries。共 2,592 paired query 的 IDs、Float32 bits、stats、
execution 一致；三版本共 7,776 query audits、27 reopen oracle checks 通過，
18 個 Akasha snapshot lease 存活與釋放檢查通過。分數 bits 蒐集在計時之外。
120 秒 worker 界限內全部完成；runner 最終 exit 1 表示嚴格速度門檻 FAILED。

此為 M4 Pro／24 GiB 共享工作主機的 binding-only resident 工作負載，使用者
應用持續運行。量測前只對本任務 Docker volume 中的 fixtures/trials 執行
fsync／FADV_DONTNEED（5,054 files、13,691,178,673 bytes，無刪除／重寫），
然後停止任務容器；沒有全機 cache purge。主機仍約 21,956.5 MiB swap used，
`pmset` 未記錄 thermal／performance warning；不代表無干擾或 cold-cache。
Linux correctness 在 Mac 量測完成後執行，所有 build/test/benchmark 串行。
本報告不替代 memory-cap、雙方持續 non-resident 或 HTTP clients 的矩陣。

## 結果與仍存在的退步

real-1536 暖 ANN 九格 QPS 為 baseline 的 1.216–1.401 倍，p95 為 .685–.794
倍；mixed ANN 九格中八格 QPS 改善，另一格 .975 倍，九格 p95 均改善。
但 real correlated／independent 仍全數未達 Qdrant 雙門檻。

所有退步保留。例如暖 uniform-128 correlated trial 0 QPS .689 倍、p95
1.870 倍；mixed real selective trial 0／1 p95 4.144／1.450 倍，trial 2
.854 倍。這些 planned exact 查詢未使用新增四候選 kernel；波動原因尚未證實，
不可排除樣本或宣稱整體無回歸。trial 0 selective 的少數毫秒級樣本改變 p95
排名，原始每 query latency 均在附件中。

每 block 自身 write + flush 合計的嚴格速度門檻，前後皆 3/9 通過（只有
uniform-128 三次）；uniform-1536 及 real-1536 六次仍失敗。Akasha update
包含 WAL fsync，Qdrant update／flush 的同步邊界不同，個別 update 延遲不是
durability-equivalent；合計亦可能包含不同 maintenance 工作，未宣稱寫入改善。

下面 A/B 為 candidate/baseline，A/Q 為 candidate/Qdrant；QPS 越大越好，
p95 越小越好。格子狀態使用精確數值，表格只顯示三位小數。

### warm

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 0.946 | 1.069 | 0.798 | 1.249 | FAILED → FAILED |
| uniform-128 | 0 | correlated | 0.689 | 1.870 | 1.858 | 0.928 | PASSED → PASSED |
| uniform-128 | 0 | independent | 0.916 | 0.965 | 2.187 | 0.615 | PASSED → PASSED |
| uniform-128 | 0 | selective | 1.174 | 0.668 | 1.079 | 0.846 | FAILED → PASSED |
| uniform-128 | 1 | all | 1.001 | 1.025 | 0.845 | 1.214 | FAILED → FAILED |
| uniform-128 | 1 | correlated | 1.093 | 0.884 | 2.687 | 0.451 | PASSED → PASSED |
| uniform-128 | 1 | independent | 0.858 | 1.309 | 2.182 | 0.777 | PASSED → PASSED |
| uniform-128 | 1 | selective | 1.070 | 0.928 | 1.234 | 0.740 | PASSED → PASSED |
| uniform-128 | 2 | all | 0.983 | 1.203 | 0.761 | 1.605 | FAILED → FAILED |
| uniform-128 | 2 | correlated | 1.396 | 0.789 | 2.422 | 0.557 | PASSED → PASSED |
| uniform-128 | 2 | independent | 0.850 | 1.099 | 1.251 | 0.837 | PASSED → PASSED |
| uniform-128 | 2 | selective | 0.762 | 1.305 | 0.611 | 1.829 | FAILED → FAILED |
| uniform-1536 | 0 | all | 1.087 | 0.880 | 2.433 | 0.425 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 1.069 | 0.957 | 1.344 | 0.808 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 1.033 | 1.019 | 1.262 | 0.773 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 1.041 | 1.039 | 0.653 | 1.725 | FAILED → FAILED |
| uniform-1536 | 1 | all | 0.917 | 1.114 | 2.369 | 0.438 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 0.967 | 1.023 | 1.383 | 0.789 | PASSED → PASSED |
| uniform-1536 | 1 | independent | 0.978 | 0.977 | 1.250 | 0.800 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 1.053 | 0.919 | 0.893 | 1.114 | FAILED → FAILED |
| uniform-1536 | 2 | all | 0.988 | 1.015 | 2.581 | 0.381 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 1.039 | 0.975 | 1.387 | 0.801 | PASSED → PASSED |
| uniform-1536 | 2 | independent | 0.980 | 0.972 | 1.263 | 0.801 | PASSED → PASSED |
| uniform-1536 | 2 | selective | 1.169 | 0.805 | 0.928 | 0.849 | FAILED → FAILED |
| real-1536 | 0 | all | 1.216 | 0.780 | 0.903 | 1.142 | FAILED → FAILED |
| real-1536 | 0 | correlated | 1.401 | 0.685 | 0.862 | 1.029 | FAILED → FAILED |
| real-1536 | 0 | independent | 1.218 | 0.794 | 0.693 | 1.404 | FAILED → FAILED |
| real-1536 | 0 | selective | 1.001 | 1.042 | 0.861 | 1.118 | FAILED → FAILED |
| real-1536 | 1 | all | 1.247 | 0.763 | 1.041 | 1.000 | FAILED → PASSED |
| real-1536 | 1 | correlated | 1.242 | 0.773 | 0.853 | 1.060 | FAILED → FAILED |
| real-1536 | 1 | independent | 1.327 | 0.712 | 0.848 | 1.153 | FAILED → FAILED |
| real-1536 | 1 | selective | 0.937 | 1.018 | 0.815 | 1.186 | FAILED → FAILED |
| real-1536 | 2 | all | 1.290 | 0.737 | 1.129 | 0.871 | FAILED → PASSED |
| real-1536 | 2 | correlated | 1.269 | 0.757 | 0.815 | 1.102 | FAILED → FAILED |
| real-1536 | 2 | independent | 1.306 | 0.736 | 0.743 | 1.287 | FAILED → FAILED |
| real-1536 | 2 | selective | 0.998 | 1.006 | 0.867 | 1.108 | FAILED → FAILED |

### mixed

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 1.037 | 0.959 | 1.453 | 0.726 | PASSED → PASSED |
| uniform-128 | 0 | correlated | 0.993 | 0.954 | 2.655 | 0.756 | PASSED → PASSED |
| uniform-128 | 0 | independent | 0.900 | 1.778 | 2.714 | 0.752 | PASSED → PASSED |
| uniform-128 | 0 | selective | 1.376 | 0.149 | 0.971 | 0.867 | FAILED → FAILED |
| uniform-128 | 1 | all | 1.131 | 1.610 | 1.703 | 0.529 | PASSED → PASSED |
| uniform-128 | 1 | correlated | 1.081 | 0.846 | 2.458 | 0.860 | FAILED → PASSED |
| uniform-128 | 1 | independent | 1.318 | 0.528 | 2.564 | 0.487 | PASSED → PASSED |
| uniform-128 | 1 | selective | 0.867 | 1.977 | 1.496 | 2.711 | FAILED → FAILED |
| uniform-128 | 2 | all | 0.947 | 1.114 | 1.544 | 0.669 | PASSED → PASSED |
| uniform-128 | 2 | correlated | 1.176 | 0.713 | 2.342 | 0.996 | FAILED → PASSED |
| uniform-128 | 2 | independent | 0.894 | 1.527 | 2.359 | 0.549 | PASSED → PASSED |
| uniform-128 | 2 | selective | 1.190 | 0.488 | 1.134 | 1.565 | FAILED → FAILED |
| uniform-1536 | 0 | all | 1.025 | 0.849 | 2.300 | 0.433 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 1.004 | 1.039 | 1.449 | 0.785 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 1.018 | 0.966 | 1.264 | 0.842 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 1.051 | 0.972 | 0.875 | 1.067 | FAILED → FAILED |
| uniform-1536 | 1 | all | 0.983 | 1.100 | 2.244 | 0.481 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 0.962 | 0.994 | 1.411 | 0.810 | PASSED → PASSED |
| uniform-1536 | 1 | independent | 0.994 | 0.977 | 1.252 | 0.881 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 0.961 | 1.169 | 0.746 | 1.435 | FAILED → FAILED |
| uniform-1536 | 2 | all | 1.006 | 1.021 | 2.362 | 0.437 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 1.027 | 1.103 | 1.624 | 0.694 | PASSED → PASSED |
| uniform-1536 | 2 | independent | 1.056 | 0.674 | 1.350 | 0.826 | FAILED → PASSED |
| uniform-1536 | 2 | selective | 0.855 | 0.906 | 0.811 | 1.054 | FAILED → FAILED |
| real-1536 | 0 | all | 1.254 | 0.745 | 1.042 | 0.730 | FAILED → PASSED |
| real-1536 | 0 | correlated | 1.248 | 0.805 | 0.938 | 0.835 | FAILED → FAILED |
| real-1536 | 0 | independent | 1.248 | 0.722 | 0.621 | 1.338 | FAILED → FAILED |
| real-1536 | 0 | selective | 0.929 | 4.144 | 0.623 | 5.508 | FAILED → FAILED |
| real-1536 | 1 | all | 1.248 | 0.807 | 0.964 | 1.169 | FAILED → FAILED |
| real-1536 | 1 | correlated | 1.180 | 0.777 | 0.837 | 1.054 | FAILED → FAILED |
| real-1536 | 1 | independent | 1.199 | 0.812 | 0.559 | 1.772 | FAILED → FAILED |
| real-1536 | 1 | selective | 0.792 | 1.450 | 0.669 | 1.785 | FAILED → FAILED |
| real-1536 | 2 | all | 1.121 | 0.803 | 0.919 | 0.996 | FAILED → FAILED |
| real-1536 | 2 | correlated | 1.201 | 0.853 | 0.884 | 1.018 | FAILED → FAILED |
| real-1536 | 2 | independent | 0.975 | 0.931 | 0.479 | 1.764 | FAILED → FAILED |
| real-1536 | 2 | selective | 1.089 | 0.854 | 0.820 | 1.210 | FAILED → FAILED |

## 原始證據與失敗保留

[原始資料](2026-10-13-four-neighbor-port.json.gz) 包含來源 commit／source
identities、完整 paired reports、逐 query latency／bits／stats、固定 plans、
所有 worker job/log、驗證 commands/log、Python 子 compiler argv 及本任務
cache release。檔案清單與每項 SHA-256 內嵌，壓縮後重新解開全部核對。

第一次 warm preparation 漏複製 Python `distributed` 子 package；baseline
完成、candidate 在 import 時失敗。該 incomplete trial 全部保留，沒有混入
完整三次配對；完整複製 Python package 後在新目錄重新跑全部 warm triples，
candidate binary hash 未變。Linux preparation 的錯誤測試檔名，以及 promotion
時尚未建立 `.build/c` 的失敗亦保留；皆在執行對應 build/test 之前修正。
先前二候選草稿未編譯／未量測，發現既有四候選實作後停止，未採用。

Archive SHA-256：`0ff223ebad799a465b85b1500eb8978fe214ede9b894929d35a24634a4459e41`
（239 files，3,685,015 bytes）。
