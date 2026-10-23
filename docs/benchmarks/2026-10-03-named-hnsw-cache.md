# Named HNSW 完整 run 的持久快取

基線為 `8e744d1`，native binary 為 `2d5e8e09…`。本次保存已建好的完整 named HNSW，
讓內容未變的 run 在重開後重用圖。**M5/M6 仍未完成**：多 run 更新後重開、首次建圖、
原 Qdrant 全效能矩陣及持續 nonresident／受控 memory-limit 尚未全數完成。使用者沒有
原生 Linux runner；本報告沒有新的 Linux／GPU／ASan 通過聲明。

## 實作與語意

沿用 AKIC 的有界 CRC envelope（新 kind 4）及現有 HNSW v1/v2 codec。欄位名稱、ID、
原生 dtype、metric、dimension、完整圖設定及排序後的 ID／向量內容都屬快取 identity。
讀取時完整驗證圖，逐列核對其 prepared vector 與目前 authority，重新綁定 ordinal／ID
lookup；不保存舊 root 的 ordinal，不改圖拓撲、原生 F64 rerank 或 filter／visibility。

只在 flush／close 保存已 ready、代表完整現況的單一 run。查詢只讀快取；held snapshot
在 close 後不會寫檔。每欄一個 committed cache 加一個暫存檔，原子 replace/fsync；
cache 損壞或 publication 失敗不影響權威資料，missing/stale 是重建而非錯誤結果。
Backup 仍只需權威檔案。多 run 不在這個路徑合併或重建；此限制仍屬 M5。

[設計](../plans/2026-10-03-named-hnsw-cache.md)／[格式與 identity](../../formats/field-hnsw-cache.md)。

Review 發現第一版會在 writer lock 下等待正在建圖／查詢的 artifact lock。新增回歸在
同一執行緒持有該鎖，第一版測試於 5 秒 timeout；最終版一次嘗試取得鎖，忙碌便略過，
後續 flush／close 可重試。使用已安裝 Mojo 1.0 的公開 atomic owner counter，遵循
[官方 lock owner／unlock 協定](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/utils/lock.mojo)，
沒有另設 lock 類型。第一版的量測和 timeout 全部保留，未當成最終版證據。

## 驗證範圍

| 階段 | 結果 |
|---|---|
| 第一版 | 77 targeted Mojo、1 point-checkpoint crash、376 完整 Python、C ABI／client、3 examples |
| 第一版補並行讀取 | 7 cache tests，含 55 dtype／metric／codec 組合與八個 concurrent first readers |
| 最終鎖修正 | 47 targeted Mojo：9 cache、6 named HNSW、5 close、20 background publication、7 persisted cache |
| 最終隔離 package | 376 完整 Python、C ABI／client、3 examples |
| 正式產物核對 | 125 targeted Python、重建正式 C ABI／client；source/binary identity 核對 |

新測試涵蓋 WAL-only hit、metadata 更新、ordinal 重新排序、向量／presence／ID 改變、
錯誤欄位設定、corruption/truncation、CRC 正確但向量／ID 錯誤、publication 失敗後重試、
多 run 不保存、close 後 snapshot、同時載入，以及 busy builder/query 不阻塞 writer。
這些是不同階段的範圍，沒有重跑完整 Mojo 或完整 crash suite；TestSuite 時間為毫秒。

## 最終版完整配對

三組原 corpus／seed／filters／K=10／六個 ef（32–1024）／67 queries（3 warmup + 64 timed）
維持不變。從既有替換／刪除串流的 seed WAL 複製，每組三次 AB／BA／AB。兩邊都先
建立單一完整圖、flush、close、reopen，然後量測第一個查詢與完整曲線。來源檔與 binary
在每個 worker 核對 hash。這是 **resident named-field 診斷**，不是 nonresident 或 Qdrant parity。

最終版與基線 14,472 組查詢的 ID／F64 bits／stats 相同；
28,944 ANN audits、4,824 exact oracle checks 通過。
兩版各有 84／84 個低 recall 曲線格，皆保留。
36 組 corpus/filter/trial 可在既有 grid 找到共同 Recall@10 ≥ .95；這不代表每個 ef 通過。

下表逐 trial 顯示成本，單位為 ms；沒有用中位數移除慢樣本。

| Corpus | Trial | 首查前版 → 最終版 | Flush 前版 → 最終版 | Reopen 前版 → 最終版 |
|---|---:|---:|---:|---:|
| uniform-128 | 0 | 6921.569 → 87.162 | 25.615 → 75.653 | 28.239 → 28.241 |
| uniform-128 | 1 | 6906.964 → 86.863 | 23.945 → 74.583 | 27.680 → 27.638 |
| uniform-128 | 2 | 6914.468 → 87.077 | 23.790 → 74.268 | 28.347 → 27.886 |
| uniform-1536 | 0 | 32246.122 → 273.730 | 59.763 → 181.386 | 98.039 → 105.064 |
| uniform-1536 | 1 | 32456.777 → 273.213 | 67.361 → 167.496 | 109.061 → 96.589 |
| uniform-1536 | 2 | 32226.938 → 274.013 | 56.767 → 187.862 | 96.379 → 98.725 |
| real-1536 | 0 | 17963.358 → 314.641 | 56.540 → 191.450 | 100.226 → 101.820 |
| real-1536 | 1 | 17052.337 → 335.754 | 63.287 → 184.007 | 103.069 → 104.658 |
| real-1536 | 2 | 17726.886 → 338.671 | 64.392 → 211.316 | 123.929 → 102.539 |

保存快取增加首次 flush 的編碼／fsync 成本；查詢忙碌時則略過保存。重開和第一個
query 分開計時，並未把整個建圖成本移到 open。Archive 同時保留 initial build、兩次
close、repeat flush 的逐次時間與 cache bytes。

下表為各組第一個共同達 .95 的 ef，其暖查詢前後比值（最終版／前版）；24 / 36
格的 QPS 或 p95 退步。`F` 表示任一指標未達前版，使用未四捨五入的數值判斷。
這是 Akasha 前後診斷，不取代固定 ef 的 Qdrant gate。所有六個 ef 的結果在 archive。

| Corpus/trial | all（ef / QPS / p95） | correlated | independent | selective |
|---|---|---|---|---|
| uniform-128/0 | 128 / 0.9896 / 1.0390 F | 256 / 0.9499 / 1.0964 F | 128 / 1.0334 / 0.8604 P | 128 / 1.1771 / 0.5924 P |
| uniform-128/1 | 128 / 1.0105 / 0.9459 P | 256 / 0.9456 / 1.1615 F | 128 / 1.0831 / 0.8202 P | 128 / 1.0289 / 1.0303 F |
| uniform-128/2 | 128 / 0.9709 / 1.0634 F | 256 / 0.9810 / 1.0640 F | 128 / 0.9906 / 0.9997 F | 128 / 1.0015 / 1.0340 F |
| uniform-1536/0 | 512 / 0.9804 / 0.9906 F | 512 / 0.9647 / 1.0160 F | 512 / 0.9597 / 1.0506 F | 256 / 0.9619 / 1.0415 F |
| uniform-1536/1 | 512 / 1.1536 / 0.6365 P | 512 / 1.0055 / 1.0003 F | 512 / 1.0264 / 0.9007 P | 256 / 1.0233 / 0.9780 P |
| uniform-1536/2 | 512 / 0.9536 / 1.0911 F | 512 / 0.9319 / 1.1520 F | 512 / 0.9584 / 1.0595 F | 256 / 0.9517 / 1.0341 F |
| real-1536/0 | 32 / 1.0351 / 0.9247 P | 64 / 0.9766 / 1.0313 F | 64 / 0.9833 / 1.0131 F | 128 / 1.0799 / 0.8617 P |
| real-1536/1 | 32 / 0.9894 / 0.9739 F | 64 / 1.1024 / 0.8719 P | 64 / 1.1044 / 0.8917 P | 128 / 1.0690 / 0.9344 P |
| real-1536/2 | 32 / 1.0113 / 1.0291 F | 64 / 0.9117 / 1.1071 F | 64 / 0.9788 / 1.0134 F | 128 / 0.9082 / 1.1225 F |

## 第一版與未採用行為

第一版 blocking publication 的獨立三次配對同樣有 14,472 paired queries、28,944 ANN
audits 與 4,824 exact checks，ID／F64 bits／stats 一致；各 84 個低 recall 格保留。
其選定暖查詢有 25/36 格 QPS 或 p95 退步，且另有 writer 等候問題，未採用該鎖行為。
下面保留其逐 trial 首查／flush，完整暖曲線及額外時間仍在初版 summary/raw reports。

| Corpus/trial | 首查前版 → 初版（ms） | Flush 前版 → 初版（ms） |
|---|---:|---:|
| uniform-128/0 | 7621.585 → 94.317 | 26.027 → 80.210 |
| uniform-128/1 | 13419.552 → 90.763 | 44.130 → 78.998 |
| uniform-128/2 | 7146.234 → 89.980 | 25.970 → 77.967 |
| uniform-1536/0 | 34111.977 → 290.954 | 62.999 → 174.465 |
| uniform-1536/1 | 34985.218 → 303.261 | 58.952 → 210.778 |
| uniform-1536/2 | 36571.109 → 295.359 | 66.673 → 177.456 |
| real-1536/0 | 18639.589 → 320.271 | 63.864 → 190.049 |
| real-1536/1 | 19692.361 → 340.270 | 68.374 → 199.575 |
| real-1536/2 | 18436.937 → 345.841 | 79.655 → 203.524 |

## 產物與重現

正式 Python `_kernel.so` SHA-256：`843186a731ceefaa38e6e5780a0eb13c180dcdc9525191d53f5c8ba0d89d79ba`。
Native C worker 未改動（`bc064bc8…`）；最終 binding 從複製的 `final-src/bindings/python_module.mojo`
和 `-I final-src` 編譯。完整 Python 及 child compile 繼承 Metal wrapper PATH；saved-package
pytest 使用 `-o pythonpath=`，執行前 assert 實際 `_kernel` 來源。

本輪依序執行（舊輸出目錄不可原地重跑；重跑需新目錄、原 fixed workload／seed WAL、
獨立 before/final packages）：

```sh
rtk proxy pixi run python .build/2026-10-03-named-hnsw-cache/final-run.py
rtk proxy pixi run mojo run -I src tests/mojo/test_field_hnsw_cache.mojo
```

`final-run.py` 依序執行最終 targeted/full Python、C/examples、18 個 benchmark workers
與完整逐樣本核對。18 workers 全部 exit 0；彙整腳本曾把顯示用的 reopen key 誤改，
導致 KeyError。修正後單獨重跑 final-summarize.py，全部資料核對通過，沒有重新量測或刪樣本。
初版和最終版各有獨立 source/binary identities、完整 logs／drivers／
所有 raw samples；失敗的測試與原型也保留。Benchmark 與 build/test/compression 不重疊。

[Frozen archive](results/2026-10-03-named-hnsw-cache.json.gz)（9,911,012 bytes），SHA-256：
`8677fec577201dbef6d184f47d6255871f2c98ccd12a46ac676d9dbe75a73356`。Gzip JSON 格式為 `akashadb-text-evidence-v1`，每個 `files` entry
包含 path／sha256／text，解碼後逐檔驗證；archive 不含大型 binary／database copies，
保留其 hash 及固定 input identity。

本次採用的是已驗證的 single-run cache 與非等待式保存。最終 M5/M6 checklist 保持未勾選；
首次建圖、多 run 更新後重開、完整 Qdrant 速度與缺少 runner 的記憶體驗證仍須繼續。
