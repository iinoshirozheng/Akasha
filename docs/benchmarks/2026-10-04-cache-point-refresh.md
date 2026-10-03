# Private named-cache point refresh：未採用

依 [已定案的隔離實驗](../plans/2026-10-04-cache-point-refresh.md)，只在 decoded
private cache 內更新同 ID 的原 slot，修復鄰接；公開 `HnswIndex.upsert` 仍追加
replacement slot。**候選未採用，M5/M6 未完成**。

113 unique targeted Mojo／388 完整 Python 通過。但 uniform-1536 的更新後重開
首查由 **4,895.14 ms 增至 53,583.19 ms**。減少歷史 slot 的暖查詢收益不足以
解決生命週期成本；停止擴大此候選，不因暖查詢變快宣稱驗收完成。

## 版本與範圍

- 工作樹基線 `b264c5e`；正式 engine 保持 `cc15f37`。
- 正式 Python SHA-256：
  `609aeb2b0d721cbc1d84f6aec1bd325a360484cfa72d207600313b342c5cd8d9`。
- `before` 是**尚未採用的 append reconciliation + live-radius 修正**：
  `d439f24396e3e9a6b6963ae4c361e80820d6a37fadf62c0c348cd6d1df2dc5df`。
- `after` 是本次 private point-refresh 候選：
  `de2dda85327ff6211fd0f807dfc479c8ba5a1456aaac847513870d797bd255d3`。
- 隔離資料在 `.build/2026-10-04-cache-point-refresh`；binding 從各自完整 source
  與 `bindings/python_module.mojo` 編譯。Mojo 1.0.0 (`ed45d567`)，Apple M4／Metal:4。
- **本次是一組 uniform-1536 trial，完整原 ef/filter/query grid 的成本診斷**。
  沒有 Qdrant、其他 corpus 或三次 trial 驗收；不得套用完整矩陣的通過說法。

## 實作與正確性

四個隔離檔案改動：storage 抽出原 prepared-byte encoding，完整驗證後覆寫原向量
tape；index 增加 private refresh boundary；core 對 current 一／二跳候選依原
construction ef／neighbor heuristic 修復；cache reconciliation 對既有 ID 使用
refresh，新增 ID 仍用 upsert。移除邊同步移除反向邊，新增邊使用原 symmetric
bounded linking。既有 inactive navigation bridges 保留，sole-live point 不修邊。
任何寫入後錯誤都 quarantine private graph，不發布部分修復結果。

基線回歸測試實際得到 98 slots，而新需求是 97，首輪 1 pass／1 fail 保留。
腳本第一次產生 source 時搜尋了錯誤的 generic signature，留下 storage-only
中間狀態；其後 1 pass／1 expected fail 也保留，並記為 harness error，不冒稱
完整修復演算法的失敗。最終 113 項 unique targeted Mojo 分布：

| 範圍 | 通過 |
|---|---:|
| cache publication／原 slot 回歸 | 2 |
| private refresh：entry／重複更新、前置拒絕、quarantine、sole live、公開 upsert | 5 |
| storage／links／mutation／neighbor selection／store | 69 |
| extended reconciliation／55 種 native × metric × graph codec 組合 | 7 |
| quantized／index cache／field cache／query control | 30 |
| 合計 | 113 |

55 種組合保留先前完整 K 候選不足的基線案例，要求不增加 exhaustion；K=7
不走 exact fallback，native F64 結果與 oracle 相符。save/reopen、舊 snapshot、
錯誤 cache identity、rebuild threshold、取消、busy／failed publication／retry 通過。
Mojo TestSuite 時間單位是毫秒。

完整 Python **388 passed**，使用 saved package import-path／SHA guard 與
`-o pythonpath=`；child compile 繼承隔離 wrapper／Metal wrapper PATH。正式 kernel
與 native worker 前後 SHA 未變。本次未重跑 C ABI、crash、examples、完整 Mojo、
Qdrant 矩陣、Linux、GPU、ASan、持續 nonresident／memory-limit。

## 完整高維診斷

兩個 worker 串行完成，保留原 8,192 initial points、819 updates、205 deletes、
四種 filters、六 ef、每格 3 warmups + 64 measured queries、K=10 與 seeds。
保留所有低 recall 格與全部 latency samples，沒有以重跑或平均掩蓋失敗。

| 指標 | append reconciliation | 原 slot 修復 |
|---|---:|---:|
| final slots／live | 9,011／7,987 | 8,192／7,987 |
| cache bytes | 57,467,597 | 52,250,533 |
| 更新後重開首查 ms | 4,895.14 | 53,583.19 |
| 保存後第二次重開首查 ms | 334.15 | 310.01 |
| fixed-ef quality passes | 9/24 | 9/24 |

沒有 fixed-ef quality pass→fail；四個 modes 都在原 grid 達 Recall@10 ≥ .95。
3,216 ANN audits、536 exact oracle checks 通過；709/1,608 配對 query 的 ID list
相同，13,326 個 common-ID F64 score bits 相同。各版第二次重開的 ID／bits／stats
與自己的第一次重開相同。不同拓撲的 stats 不要求相同，實際 0/1,608 相同。

以下均使用相同 ef；這些 A/B 比例**不是 Qdrant parity**：

| Mode | ef | QPS after/before | p95 after/before | mean distance count after/before |
|---|---:|---:|---:|---:|
| all | 512 | 1.0434 | 0.9446 | 0.9105 |
| correlated | 512 | 1.0304 | 0.9905 | 0.9105 |
| independent | 512 | 1.0577 | 0.9381 | 0.9102 |
| selective | 256 | 1.0917 | 0.8591 | 0.9097 |

## 修復 profile 與決定

另開 fresh worker 重現同一資料／更新，在重開查詢做五秒 macOS native sample。
初始 graph cache SHA 與未 profile run 相同；initial、updated、reopened query 的
ID／F64 bits／stats 全相同。Profile 時間含取樣干擾，沒有併入上表。

解析主執行緒 sample tree，以父計數扣除子計數避免重複加總；3,784 個 query
boundary samples 中，checked pair distance 占 **55.50%**、其他 private refresh
工作 **34.41%**、heap **6.32%**、reciprocal linking **0.53%**、其他 **3.25%**。
這支持重新評估逐點鄰域修復的工作量；不能將所有成本歸因於距離函式本身。

本次首查約慢 10.95 倍；連初始完整建圖的 34.29 秒也低於 53.58 秒修復成本。
因此不做此候選的完整三次／三 corpus 矩陣，也不改正式 source/binary。
下一步先查既有 retained-base／delta 路徑及參考產品，再決定 named lifecycle
方案；不刪除 checks、不調 ef 或降低 gate，也不盲目重跑本次修復。

## 凍結證據與重現

[Frozen text evidence](results/2026-10-04-cache-point-refresh.json.gz)：
**1,431,519 bytes／491 entries**，SHA-256：
`30503689228cc094f64226a32c2994cab63998412308756d169579ab8fc45cfd`。
包含兩版 source、tests、drivers、全部失敗 logs、Python JUnit、完整曲線與 profile；
gzip 與每筆 text SHA 已核對。收錄 tests source 供重現，不表示所有收錄測試都跑過。
大型 corpus／database／binary 不在 text archive，來源與產物 hash 留在 identity/job。

現存 `.build` 的結果可重新評估：

```sh
rtk proxy python3 .build/2026-10-04-cache-point-refresh/summarize-highdim.py
rtk proxy python3 .build/2026-10-04-cache-point-refresh/summarize-repair-profile.py
```

`highdim-summary.status=TARGET_REACHED` 僅指本次原 ef grid 的 recall；整體決定見
`decision.json` 的 **NOT_ADOPTED**，M5/M6 仍 FAILED／未完成。測試／build／worker
完整命令在各 validation/job JSON。重新執行須先建立新的隔離目錄、更新相應 guard，
不要原地重跑會寫入產物的 drivers，不改凍結 archive。所有量測與 build/test/壓縮串行。
