# 篩選 exact scan 雙候選移植

採用既有 `a57f11a80bf8c09bf3771fd740a32570466e1034` 的 checked F32 pair kernel，
套用至本輪四候選 HNSW 基線（engine `bd43789`，量測時 HEAD `75411bc`）。
只修改 `compute/simd.mojo` 與 `api/collection.mojo`；來源 branch 的 compaction
reclamation 改動不在此 port 中，既有 maintenance shared-state 修正保留。

本輪暖查詢速度 **19/36 → 24/36**，mixed **17/36 → 17/36**；前後兩組品質
皆 **36/36**。暖查詢無 pass→fail，mixed 有 **3 格 pass→fail**。
**M5/M6 仍 FAILED。** 採用的是局部計分改善，並未用其他格收益抵銷退步或
達成逐格 Qdrant 門檻；mixed 尾延遲及 ANN 差距仍需後續處理。

## 實作及決策依據

對 live ordinals 的 proper subset，每次處理相鄰兩個有 default dense field
的候選，共用 query loads，保留每列獨立 score、finite mask、cosine norm
accumulator，以及相同 SIMD 寬度、reduction 和 tail 次序。完整 live-set 掃描
保留逐筆路徑；missing first／second field、odd tail 及 top-k admission 順序
保持一致。query 沿用既有單次 preparation；每列 candidate 的有限值、維度、
cosine zero-norm 與第一筆錯誤優先序仍檢查。沒有新增 cache、依賴、unsafe view、
inline directive 或 durable format。來源實驗曾拒絕的 universal pairing 未重做。

uniform-1536 correlated／independent 在本輪暖與 mixed 合計 12 格 QPS 均改善
（1.020–1.327 倍），11 格 p95 改善；real-1536 selective 的三次 mixed QPS
為 1.042–1.423 倍，p95 為 .545–.952 倍。這些重複的高維 filtered exact 收益
及行為一致性支持採用。

限制同樣列入決策：warm uniform-1536 selective trial 0 QPS .779 倍、p95
1.558 倍；mixed uniform-128 selective trial 0／1 QPS .673／.710 倍、p95
3.240／3.068 倍，兩格由 pass 轉 fail。mixed uniform-1536 independent trial
2 的 QPS 1.020 倍、p95 1.885 倍，也由 pass 轉 fail。其他 ANN 格亦有退步。
這些原因尚未隔離，不能標為已排除的雜訊；原始每 query latency 全保留。

## 本輪驗證

| 範圍 | 結果 |
|---|---|
| Mojo | 66 個不同案例通過：新增 pair kernel 5，加 SIMD distance、persistent filters/documents、snapshot、point-store search、incremental collection |
| Python | 356 個既有案例加 3 個新增 metric 案例，359 passed |
| C ABI | 隔離 shared library 與 `-Wall -Wextra -Werror` C client 重建通過 |
| 範例 | smoke、persistent_collection、configured_hnsw 編譯執行通過 |
| Linux x86-64 模擬 | pair kernel 5 與 SIMD distance 9，共 14 個不同案例通過 |

先在未改 source 編譯新增 Mojo 測試，確認缺少 `_prepared_pair_score` 的預期
失敗，再編譯隔離候選。五個 Mojo 案例涵蓋 dot／L2／cosine、16 種維度、
不同尺度、每個非有限 lane、兩筆的維度錯誤、空值、錯誤優先序、有限極值及
signed zero；逐 Float32 bit 比對既有單筆 kernel。
Python 三種 metric 用獨立 snapshot single-row 路徑比對 planned exact，涵蓋
named-only points、missing fields、ties、odd dimension、all/subset/empty
filters、兩種 K、delete、default-field 增減、flush 與 reopen。

隔離 source 含完整 binding entry 和 120 個 Mojo 檔案，Python package 完整複製。
Python 測試衍生 compiler 的 include／entry 均導向隔離 source，original/effective
argv 保存。Mac 使用 Mojo 1.0.0、`metal:4`／`apple-m4`；Linux 為既有 pinned
Docker emulated Westmere/SSE4.2，沒有 native Linux／AVX 成功聲明。
未觸及 storage transitions／GPU，本輪未重跑完整 crash／GPU suites。

採用時核對 root、隔離 Mac／Linux 的全部 source hashes 一致；root binary
直接使用已驗證的同一產出，沒有以未測 binary 代替。Python SHA-256：
`71c6d8c05c64d8c256364c06885bd6cc8230250407cb20449cef2ab659787cb8`。
baseline 為四候選版
`9009e41a9653079a667546e9dea06386c0c52fbe9094c958e7d82ea25bebf1b4`。

## 固定方法與完整矩陣

沿用 [四候選配對方法](2026-10-13-four-neighbor-port.md)：相同三個 8192-point
workloads、seed 12345、k=10、四 modes、oracle、ef、計時邊界、真實 Qdrant
Edge 0.8.0，三次 BAQ/AQB/QBA rotating triples，從各 engine 關閉資料庫複製
後 reopen。build、tests、benchmark、archive compression 串行。
門檻為 Recall@10 ≥ .95、QPS ≥ Qdrant、p95 ≤ Qdrant；逐格用完整精度判定，
不設 tolerance，不跨格抵銷。新批次不能與前一批次通過數直接相減作效能差值。

Warm 每 mode 3 warmups + 64 timed queries。27 workers 共 7,236 exact checks、
6,912 timed response checks、324 warmups；baseline/candidate 共 2,304 paired
timed responses 和 108 paired warmups 的 IDs／F32 bits／stats 相同。
Mixed 使用原 frozen 32-block plan（每 block 9 queries／8 upserts／flush），
27 workers 共 7,776 query audits、27 reopen checks、18 Akasha leases 通過；
2,592 paired responses 的 IDs／F32 bits／stats／execution 一致。
重複固定 queries 不新增獨立 recall 樣本。所有 worker 在既有 120 秒 mixed
界限內完成，最終 exit 1 是嚴格速度驗收 FAILED。

write + flush 合計速度前後皆 **3/9** 通過，只有 uniform-128 三次，其他六次
仍失敗。個別 update 的持久化邊界不同：Akasha 包含 WAL fsync，Qdrant 另有
flush；合計亦可能有不同 maintenance 工作，不宣稱寫入改善。

主機為共享 M4 Pro／24 GiB，使用者應用持續運行；量測前 swap used 約
20,279.38 MiB，無已記錄 thermal／performance warning，這不表示無干擾。
此為 binding-only warm／mixed 結果，不取代 memory-cap、持續 non-resident
或並行 HTTP 矩陣。沒有因為慢樣本更換 workload、ef、查詢次數或重跑挑選結果。

下表 A/B 是 candidate/baseline，A/Q 是 candidate/Qdrant；QPS 越大越好，
p95 越小越好。顯示三位小數，狀態使用完整精度。

### warm

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 1.066 | 0.884 | 0.804 | 1.286 | FAILED → FAILED |
| uniform-128 | 0 | correlated | 2.432 | 0.491 | 2.891 | 0.393 | PASSED → PASSED |
| uniform-128 | 0 | independent | 1.087 | 0.933 | 1.931 | 0.737 | PASSED → PASSED |
| uniform-128 | 0 | selective | 1.303 | 0.604 | 1.244 | 0.649 | FAILED → PASSED |
| uniform-128 | 1 | all | 0.983 | 1.006 | 1.078 | 0.635 | PASSED → PASSED |
| uniform-128 | 1 | correlated | 0.690 | 2.020 | 2.058 | 0.738 | PASSED → PASSED |
| uniform-128 | 1 | independent | 1.459 | 0.498 | 3.110 | 0.342 | PASSED → PASSED |
| uniform-128 | 1 | selective | 1.150 | 0.622 | 1.021 | 0.917 | FAILED → PASSED |
| uniform-128 | 2 | all | 1.015 | 0.985 | 1.144 | 0.544 | PASSED → PASSED |
| uniform-128 | 2 | correlated | 0.909 | 1.303 | 2.911 | 0.427 | PASSED → PASSED |
| uniform-128 | 2 | independent | 0.933 | 1.455 | 2.241 | 0.735 | PASSED → PASSED |
| uniform-128 | 2 | selective | 1.045 | 0.857 | 1.014 | 1.044 | FAILED → FAILED |
| uniform-1536 | 0 | all | 1.025 | 0.942 | 2.795 | 0.347 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 1.064 | 0.926 | 1.497 | 0.729 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 1.200 | 0.870 | 1.515 | 0.693 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 0.779 | 1.558 | 0.608 | 2.147 | FAILED → FAILED |
| uniform-1536 | 1 | all | 1.005 | 0.976 | 2.693 | 0.366 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 1.109 | 0.908 | 1.540 | 0.733 | PASSED → PASSED |
| uniform-1536 | 1 | independent | 1.245 | 0.867 | 1.580 | 0.693 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 1.144 | 0.880 | 0.970 | 1.054 | FAILED → FAILED |
| uniform-1536 | 2 | all | 0.985 | 1.034 | 2.577 | 0.396 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 1.113 | 0.924 | 1.535 | 0.746 | PASSED → PASSED |
| uniform-1536 | 2 | independent | 1.253 | 0.849 | 1.588 | 0.687 | PASSED → PASSED |
| uniform-1536 | 2 | selective | 1.250 | 0.774 | 1.044 | 0.929 | FAILED → PASSED |
| real-1536 | 0 | all | 1.013 | 0.999 | 1.087 | 0.977 | PASSED → PASSED |
| real-1536 | 0 | correlated | 0.858 | 1.229 | 0.731 | 1.328 | FAILED → FAILED |
| real-1536 | 0 | independent | 0.878 | 1.171 | 0.654 | 1.500 | FAILED → FAILED |
| real-1536 | 0 | selective | 1.168 | 0.895 | 0.960 | 1.011 | FAILED → FAILED |
| real-1536 | 1 | all | 1.022 | 0.969 | 1.115 | 0.957 | PASSED → PASSED |
| real-1536 | 1 | correlated | 0.981 | 1.017 | 0.818 | 1.109 | FAILED → FAILED |
| real-1536 | 1 | independent | 0.906 | 1.259 | 0.649 | 1.675 | FAILED → FAILED |
| real-1536 | 1 | selective | 0.999 | 0.987 | 0.916 | 1.230 | FAILED → FAILED |
| real-1536 | 2 | all | 1.151 | 0.885 | 1.073 | 0.973 | FAILED → PASSED |
| real-1536 | 2 | correlated | 0.858 | 1.167 | 0.763 | 1.171 | FAILED → FAILED |
| real-1536 | 2 | independent | 1.041 | 0.934 | 0.751 | 1.294 | FAILED → FAILED |
| real-1536 | 2 | selective | 1.154 | 0.850 | 1.029 | 0.990 | FAILED → PASSED |

### mixed

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 1.055 | 0.629 | 1.446 | 0.564 | PASSED → PASSED |
| uniform-128 | 0 | correlated | 1.126 | 0.935 | 2.655 | 0.785 | PASSED → PASSED |
| uniform-128 | 0 | independent | 1.090 | 0.391 | 2.514 | 0.540 | FAILED → PASSED |
| uniform-128 | 0 | selective | 0.673 | 3.240 | 0.797 | 3.073 | PASSED → FAILED |
| uniform-128 | 1 | all | 1.005 | 1.035 | 1.681 | 0.639 | PASSED → PASSED |
| uniform-128 | 1 | correlated | 1.246 | 0.494 | 2.913 | 0.627 | FAILED → PASSED |
| uniform-128 | 1 | independent | 0.976 | 0.861 | 3.255 | 0.367 | PASSED → PASSED |
| uniform-128 | 1 | selective | 0.710 | 3.068 | 0.969 | 2.659 | PASSED → FAILED |
| uniform-128 | 2 | all | 0.942 | 1.159 | 1.502 | 0.745 | PASSED → PASSED |
| uniform-128 | 2 | correlated | 0.975 | 0.932 | 2.877 | 0.438 | PASSED → PASSED |
| uniform-128 | 2 | independent | 0.984 | 1.251 | 3.001 | 0.505 | PASSED → PASSED |
| uniform-128 | 2 | selective | 1.046 | 0.863 | 0.980 | 2.538 | FAILED → FAILED |
| uniform-1536 | 0 | all | 1.054 | 0.902 | 2.521 | 0.389 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 1.112 | 0.918 | 1.735 | 0.685 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 1.261 | 0.862 | 1.760 | 0.701 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 3.174 | 0.790 | 1.060 | 1.168 | FAILED → FAILED |
| uniform-1536 | 1 | all | 1.018 | 0.992 | 2.399 | 0.427 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 1.139 | 0.982 | 1.788 | 0.662 | PASSED → PASSED |
| uniform-1536 | 1 | independent | 1.327 | 0.786 | 1.754 | 0.635 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 1.033 | 1.391 | 0.868 | 1.638 | FAILED → FAILED |
| uniform-1536 | 2 | all | 1.022 | 0.901 | 2.392 | 0.412 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 1.277 | 0.385 | 1.794 | 0.614 | FAILED → PASSED |
| uniform-1536 | 2 | independent | 1.020 | 1.885 | 1.348 | 1.594 | PASSED → FAILED |
| uniform-1536 | 2 | selective | 1.089 | 1.178 | 0.839 | 1.623 | FAILED → FAILED |
| real-1536 | 0 | all | 1.135 | 0.886 | 0.924 | 1.154 | FAILED → FAILED |
| real-1536 | 0 | correlated | 0.972 | 1.041 | 0.810 | 1.144 | FAILED → FAILED |
| real-1536 | 0 | independent | 0.987 | 1.095 | 0.544 | 1.974 | FAILED → FAILED |
| real-1536 | 0 | selective | 1.352 | 0.628 | 0.869 | 1.069 | FAILED → FAILED |
| real-1536 | 1 | all | 0.895 | 1.197 | 0.872 | 1.205 | FAILED → FAILED |
| real-1536 | 1 | correlated | 1.035 | 0.996 | 0.864 | 1.202 | FAILED → FAILED |
| real-1536 | 1 | independent | 1.029 | 0.998 | 0.555 | 1.966 | FAILED → FAILED |
| real-1536 | 1 | selective | 1.042 | 0.952 | 0.749 | 1.497 | FAILED → FAILED |
| real-1536 | 2 | all | 0.926 | 1.071 | 0.839 | 1.289 | FAILED → FAILED |
| real-1536 | 2 | correlated | 0.985 | 0.983 | 0.844 | 1.212 | FAILED → FAILED |
| real-1536 | 2 | independent | 1.013 | 1.002 | 0.555 | 2.111 | FAILED → FAILED |
| real-1536 | 2 | selective | 1.423 | 0.545 | 0.908 | 0.944 | FAILED → FAILED |

## 不可變證據

[原始資料](2026-10-13-paired-exact-port.json.gz) 含來源 patch／原報告與計畫、
本輪 source identities、所有 worker reports/logs/jobs、逐 query bits/stats/
latency、三份實際 mixed write plans、Mojo/Python/C/example/Linux commands
與 logs、baseline 預期失敗、host 資訊及採用紀錄。每檔 hash 內嵌並重新解開
驗證；27 mixed worker 的 plan hash 亦與封存計畫逐一核對。

Archive SHA-256：`1c35edff990fd332f3a15f8b57be7f208ba3d86f26d986ba3975c8b6ee1f035e`
（217 files，18,741,222 bytes）。
