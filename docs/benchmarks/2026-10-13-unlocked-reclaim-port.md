# Compaction 檔案回收移出 writer lock

採用既有 `7dd864701a169c00feee36be8c3f0944c67751af` 的成功 compaction 回收流程，
移植至本輪 `d07fea9`，保留 maintenance shared-state 的 origin-bound `Pointer`
修正、mapped segment reader、四候選 HNSW 與 filtered exact pair scoring。
不是整個 feature branch 合併；三個檔案直接套用 patch，maintenance 的新增流程
改用現有 `state[]` 存取，沒有恢復整個 mutable state 的跨鎖借用。

同批暖查詢速度 **23/36 → 25/36**，mixed **17/36 → 28/36**；兩組前後品質
皆 **36/36**。暖與 mixed 各有 **1 格 pass→fail**，所有退步保留。
write + flush 合計速度前後仍為 **3/9**。**M5/M6 仍 FAILED**，不能跨格抵銷，
也不能將不同批次通過數相減當成配對效能差值。

## 回收與生命週期

成功 publication 在 writer lock 內將已過時輸入放入 queue。呼叫端在鎖內
開啟 directory、detach 一個有 owner 的 batch，鎖外執行既有 lease/flock/
unlink/directory-sync，最後在鎖內還原 deferred paths。新加入 queue 的路徑
保留；open 失敗不移走 shared queue，unlink/fsync 部分失敗則還原完整 retry
batch。directory handle 將已開始的回收 I/O 固定在其開啟的目錄。

前景 compaction 額外持有捕捉到的 source file-lock owner，直到回收成功或
錯誤返回。close 可在前景回收阻塞時完成，新 writer 仍須等 source owner 釋放。
背景 close 仍 join worker；前景 compact 仍等自己的回收嘗試完成。
job-pin release、失敗 output cleanup、flush 與 point-store 回收沿用原流程，
沒有聲稱移除所有鎖內 I/O。公共格式、檔案租約與 durability ordering 未變。

此流程符合本機 RocksDB `DBImpl::DeleteObsoleteFiles` 的 mutex 內收集、unlock
後 purge 模式（`reference/rocksdb/db/db_impl/db_impl_files.cc:853`）。
[ADR 0007](../adr/0007-generation-field-ownership.md) 同步更新當前回收與 owner 契約。

## 本輪驗證

| 範圍 | 結果 |
|---|---|
| Targeted Mojo | 103 個不同案例通過，含 7 個新增案例、shared-state regression、20 個 background publication 案例 |
| Crash | 全部 23 項通過，涵蓋 WAL tail、batch、checkpoint、compaction/rebase、HNSW、point/sparse、backup publication |
| Python | 完整 359 passed，3 個既有 warnings |
| C ABI | 隔離 shared library 與 `-Wall -Wextra -Werror` C client 重建通過 |
| 範例 | smoke、persistent_collection、configured_hnsw 編譯執行通過 |
| Linux x86-64 模擬 | publication 1、close/source owner 1、retired batch 5、maintenance 6，共 13 個不同案例通過 |

未改 baseline 上，publication-deferral 案例因檔案已刪除而失敗；blocked FIFO
回收案例觸發 5 秒 watchdog，close 無法在回收等待期間前進（案例 5,137.012 ms）。
隔離候選兩案例通過，後者案例時間 80.301 ms；這是 liveness handshake，
不是公開查詢延遲門檻。新 queue 案例檢查 concurrent enqueue、lease deferral
與 retry、partial unlink failure、open failure、directory replacement。

close 測試接受 FIFO flock 成功或拒絕兩種 disposition，並檢查 source owner
與 retry queue；測試本身沒有輸出分支 counter。Linux 另做 read-only FIFO 的
exclusive/nonblocking flock 能力診斷，結果成功，不混入 13 個 Mojo 案例計數。
該診斷第一次未透過 pixi 尋找 Python 而啟動失敗，已保留並在正確環境補做。

第一輪 file-retirement 9 案例通過，但其獨立 child 使用 `mojo run -I src`，
未導向隔離樹，因此完整保留初次紀錄，另以 wrapper 單獨重跑這個檔案。
child effective argv 確認使用隔離 source 和 Mac target flags，9 案例再次通過，
只計一次。其餘成功檢查沿用；另補 ADR 指定的 background publication 20 案例。
Python 衍生 compiler 也使用同一 wrapper，original/effective argv 均保存。

Mac 使用 Mojo 1.0.0、`metal:4`／`apple-m4`；完整 120 個 Mojo 檔案與 binding
entry 在隔離樹編譯。Linux 使用既有 pinned Docker emulated Westmere/SSE4.2，
不是 native Linux／AVX performance 驗收。GPU 未改，沒有重跑 GPU suite。
native worker library 未改。採用時 root／Mac 隔離樹／Linux 隔離樹全部 source
hashes 一致，root 使用已測過的同一 Python／C binary。

Python candidate SHA-256：
`0bf644c16b119dbec1c41b5098a01ac3d7dbd6b036e65a8263c5e7e6c51879c3`。
baseline：`71c6d8c05c64d8c256364c06885bd6cc8230250407cb20449cef2ab659787cb8`。

## 配對量測與採用依據

沿用 [固定 workload 與方法](2026-10-13-four-neighbor-port.md)：三個 8192-point
corpora、seed 12345、k=10、四 modes、原 oracle/ef/timing boundary、真實
Qdrant Edge 0.8.0，每 corpus 三次 BAQ/AQB/QBA serial triples，各自複製關閉
資料庫再 reopen。build、test、benchmark、archive compression 串行。
門檻仍逐格 Recall@10 ≥ .95、QPS ≥ Qdrant、p95 ≤ Qdrant，使用完整精度，
不設 tolerance、不跨格抵銷。沒有為改善結果改 workload、ef 或移除慢樣本。

Warm 共 7,236 exact checks、6,912 timed response checks、324 warmups；
baseline/candidate 的 2,304 paired timed responses 與 108 paired warmups
之 IDs、Float32 bits、stats 一致。Mixed 使用三份原 frozen 32-block plans，
共 7,776 query audits、27 reopen checks、18 Akasha leases 通過；2,592 paired
queries 的 IDs、Float32 bits、stats、execution 相同。全部 worker 完成，
mixed runner exit 1 表示整體速度門檻 FAILED。固定 query 重複不是新獨立樣本。

mixed uniform-128 all 三次 QPS 提高 7.4–13.4%；uniform-1536 selective 三次
QPS 為 1.279–1.497 倍、p95 為 .312–.893 倍；real correlated 三次 QPS 為
1.078–1.223 倍、p95 為 .629–.867 倍。採用依據為移出明確的鎖內回收 I/O、
close/source-owner 行為改善、完整 correctness 驗證與這些重複收益。
本輪未重做 instrumented publication timing，不沿用舊 branch 的時間作新證據。

退步仍存在：warm real selective trial 0 QPS .956 倍、p95 1.067 倍，從 pass
轉 fail；mixed uniform-128 selective trial 1 QPS .961 倍、p95 3.474 倍，
也從 pass 轉 fail。其他退步格同樣列於下表，未排除為雜訊。Warm 沒有此 mixed
回收工作，不能將暖查詢通過格增加歸因於鎖外回收。

write + flush 前後皆 3/9 通過，只在 uniform-128 三次達標。雙方個別 update
的 durability 邊界不同：Akasha 包含 WAL fsync，Qdrant 有獨立 flush；合計亦
可能包含不同 maintenance 工作，未宣稱寫入改善。
主機為共享 M4 Pro／24 GiB，量測前 swap used 約 22,252.81 MiB，無已記錄的
thermal/performance warning，不代表沒有干擾。此為 binding-only 結果，不替代
memory-cap、持續 non-resident、並行 HTTP 或 native Linux 矩陣。

A/B 是 candidate/baseline，A/Q 是 candidate/Qdrant；QPS 越大越好，p95
越小越好。表格顯示三位小數，狀態使用原始精度。

### warm

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 1.012 | 0.958 | 0.822 | 1.175 | FAILED → FAILED |
| uniform-128 | 0 | correlated | 1.091 | 0.923 | 3.217 | 0.388 | PASSED → PASSED |
| uniform-128 | 0 | independent | 0.988 | 1.078 | 3.122 | 0.514 | PASSED → PASSED |
| uniform-128 | 0 | selective | 1.027 | 0.924 | 1.088 | 0.946 | FAILED → PASSED |
| uniform-128 | 1 | all | 0.985 | 1.040 | 0.839 | 1.151 | FAILED → FAILED |
| uniform-128 | 1 | correlated | 1.038 | 0.942 | 3.038 | 0.362 | PASSED → PASSED |
| uniform-128 | 1 | independent | 0.613 | 1.815 | 1.751 | 0.762 | PASSED → PASSED |
| uniform-128 | 1 | selective | 1.198 | 0.672 | 1.136 | 0.828 | FAILED → PASSED |
| uniform-128 | 2 | all | 0.968 | 1.108 | 0.814 | 1.277 | FAILED → FAILED |
| uniform-128 | 2 | correlated | 1.262 | 0.478 | 2.850 | 0.396 | PASSED → PASSED |
| uniform-128 | 2 | independent | 0.993 | 0.980 | 3.255 | 0.318 | PASSED → PASSED |
| uniform-128 | 2 | selective | 1.115 | 0.871 | 1.172 | 0.912 | FAILED → PASSED |
| uniform-1536 | 0 | all | 1.000 | 0.995 | 2.540 | 0.378 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 1.016 | 0.972 | 1.511 | 0.725 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 0.995 | 0.991 | 1.609 | 0.678 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 0.998 | 1.047 | 1.045 | 0.913 | PASSED → PASSED |
| uniform-1536 | 1 | all | 1.005 | 0.988 | 2.621 | 0.369 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 0.999 | 0.991 | 1.511 | 0.726 | PASSED → PASSED |
| uniform-1536 | 1 | independent | 0.976 | 1.034 | 1.546 | 0.722 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 0.992 | 1.034 | 1.069 | 0.925 | PASSED → PASSED |
| uniform-1536 | 2 | all | 0.971 | 1.037 | 2.450 | 0.413 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 0.973 | 1.056 | 1.546 | 0.740 | PASSED → PASSED |
| uniform-1536 | 2 | independent | 0.981 | 1.002 | 1.560 | 0.689 | PASSED → PASSED |
| uniform-1536 | 2 | selective | 1.012 | 1.031 | 1.204 | 0.760 | PASSED → PASSED |
| real-1536 | 0 | all | 0.983 | 0.976 | 1.064 | 0.934 | PASSED → PASSED |
| real-1536 | 0 | correlated | 0.989 | 1.017 | 0.842 | 1.105 | FAILED → FAILED |
| real-1536 | 0 | independent | 1.020 | 0.944 | 0.760 | 1.270 | FAILED → FAILED |
| real-1536 | 0 | selective | 0.956 | 1.067 | 1.036 | 1.020 | PASSED → FAILED |
| real-1536 | 1 | all | 0.989 | 1.008 | 1.060 | 0.973 | PASSED → PASSED |
| real-1536 | 1 | correlated | 0.946 | 1.057 | 0.765 | 1.228 | FAILED → FAILED |
| real-1536 | 1 | independent | 0.960 | 1.096 | 0.714 | 1.379 | FAILED → FAILED |
| real-1536 | 1 | selective | 0.987 | 1.008 | 0.951 | 1.057 | FAILED → FAILED |
| real-1536 | 2 | all | 0.983 | 1.023 | 1.057 | 0.992 | PASSED → PASSED |
| real-1536 | 2 | correlated | 1.008 | 0.971 | 0.842 | 1.073 | FAILED → FAILED |
| real-1536 | 2 | independent | 0.995 | 0.994 | 0.746 | 1.329 | FAILED → FAILED |
| real-1536 | 2 | selective | 0.973 | 1.057 | 1.007 | 0.929 | PASSED → PASSED |

### mixed

| Corpus | Trial | Mode | A/B QPS | A/B p95 | A/Q QPS | A/Q p95 | Before → after |
|---|---:|---|---:|---:|---:|---:|---|
| uniform-128 | 0 | all | 1.134 | 0.548 | 1.754 | 0.562 | FAILED → PASSED |
| uniform-128 | 0 | correlated | 1.025 | 1.052 | 3.598 | 0.384 | PASSED → PASSED |
| uniform-128 | 0 | independent | 1.478 | 0.273 | 3.860 | 0.362 | FAILED → PASSED |
| uniform-128 | 0 | selective | 0.923 | 1.089 | 1.673 | 0.590 | PASSED → PASSED |
| uniform-128 | 1 | all | 1.074 | 0.904 | 1.850 | 0.426 | PASSED → PASSED |
| uniform-128 | 1 | correlated | 1.451 | 0.331 | 3.745 | 0.407 | FAILED → PASSED |
| uniform-128 | 1 | independent | 1.031 | 1.327 | 3.541 | 0.561 | PASSED → PASSED |
| uniform-128 | 1 | selective | 0.961 | 3.474 | 1.045 | 2.847 | PASSED → FAILED |
| uniform-128 | 2 | all | 1.105 | 1.083 | 1.636 | 0.826 | PASSED → PASSED |
| uniform-128 | 2 | correlated | 1.100 | 1.618 | 3.191 | 0.659 | PASSED → PASSED |
| uniform-128 | 2 | independent | 1.373 | 0.307 | 3.539 | 0.309 | FAILED → PASSED |
| uniform-128 | 2 | selective | 1.649 | 0.149 | 1.239 | 0.852 | FAILED → PASSED |
| uniform-1536 | 0 | all | 1.023 | 0.891 | 2.483 | 0.399 | PASSED → PASSED |
| uniform-1536 | 0 | correlated | 1.114 | 1.002 | 1.849 | 0.664 | PASSED → PASSED |
| uniform-1536 | 0 | independent | 1.078 | 0.855 | 1.932 | 0.553 | PASSED → PASSED |
| uniform-1536 | 0 | selective | 1.303 | 0.547 | 1.135 | 0.985 | FAILED → PASSED |
| uniform-1536 | 1 | all | 0.989 | 0.983 | 2.435 | 0.393 | PASSED → PASSED |
| uniform-1536 | 1 | correlated | 1.106 | 0.446 | 1.800 | 0.627 | FAILED → PASSED |
| uniform-1536 | 1 | independent | 0.990 | 1.071 | 1.867 | 0.663 | PASSED → PASSED |
| uniform-1536 | 1 | selective | 1.497 | 0.312 | 1.101 | 1.410 | FAILED → FAILED |
| uniform-1536 | 2 | all | 1.006 | 0.961 | 2.418 | 0.394 | PASSED → PASSED |
| uniform-1536 | 2 | correlated | 1.041 | 1.066 | 1.797 | 0.690 | PASSED → PASSED |
| uniform-1536 | 2 | independent | 0.985 | 1.014 | 1.860 | 0.600 | PASSED → PASSED |
| uniform-1536 | 2 | selective | 1.279 | 0.893 | 1.030 | 1.682 | FAILED → FAILED |
| real-1536 | 0 | all | 1.024 | 0.947 | 1.105 | 0.951 | FAILED → PASSED |
| real-1536 | 0 | correlated | 1.087 | 0.867 | 1.004 | 0.930 | FAILED → PASSED |
| real-1536 | 0 | independent | 1.057 | 0.795 | 0.654 | 1.461 | FAILED → FAILED |
| real-1536 | 0 | selective | 1.029 | 1.011 | 1.069 | 1.266 | FAILED → FAILED |
| real-1536 | 1 | all | 1.103 | 0.909 | 1.156 | 0.755 | PASSED → PASSED |
| real-1536 | 1 | correlated | 1.223 | 0.796 | 1.029 | 0.838 | FAILED → PASSED |
| real-1536 | 1 | independent | 1.112 | 0.865 | 0.670 | 1.408 | FAILED → FAILED |
| real-1536 | 1 | selective | 1.296 | 0.752 | 1.256 | 0.752 | FAILED → PASSED |
| real-1536 | 2 | all | 1.032 | 1.030 | 1.108 | 0.939 | PASSED → PASSED |
| real-1536 | 2 | correlated | 1.078 | 0.629 | 0.981 | 1.051 | FAILED → FAILED |
| real-1536 | 2 | independent | 0.993 | 1.062 | 0.645 | 1.528 | FAILED → FAILED |
| real-1536 | 2 | selective | 1.096 | 0.768 | 1.155 | 0.909 | FAILED → PASSED |

## 不可變證據

[原始資料](2026-10-13-unlocked-reclaim-port.json.gz) 包含 port patch、原維護
函式與 pointer-preserving 轉換、reference 摘錄、方法、全套 worker reports/
jobs/logs、三份 frozen mixed plans、逐 query latency/bits/stats、所有驗證
commands/logs、baseline 失敗、child compiler 初次與補驗紀錄、host/binary/source
identities、ADR 前後內容及採用紀錄。解壓後全部檔案 SHA-256 及 27 mixed worker
plan hashes 重新核對通過。

Archive SHA-256：`f19162600965aab56eb06fb96c4480a4b64e7e839280661a446dfa69a2b81182`
（250 files，18,789,330 bytes）。
