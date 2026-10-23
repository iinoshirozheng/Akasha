# Private point-refresh 的實際重複工作

M5/M6 仍未完成，正式 source/binary 不變。接續
[named base/delta 未採用結果](../benchmarks/2026-10-04-named-overlay.md)，本次只對
先前被否決的 [point-refresh](../benchmarks/2026-10-04-cache-point-refresh.md)
加入計數輸出，沒有再次測試或採用同一效能候選。

819 個原更新產生 38,256 次 one-hop neighbor repair jobs，但只有 **8,210 個不同的
(center, level)**，其中 30,046 次為重複處理，占 **78.54%**。Level 0 有 37,499
jobs／7,908 centers；單一 center 最多修復 19 次。這不表示 pools／向量版本相同，
也不能推論可以直接省下 78.54% 時間。

| 距離計算階段 | 次數 | 占總數 |
|---|---:|---:|
| 每個鄰居掃描 candidate pool | 71,004,529 | 25.02% |
| neighbor heuristic selection | 46,868,626 | 16.52% |
| reciprocal connect／overflow pruning | 134,592,058 | 47.43% |
| updated point 的全域 reconnect | 31,275,841 | 11.02% |
| 合計 | 283,741,054 | 100% |

854 個 point/level pools 平均 1,819.08 candidates，範圍 15–1,981。各階段增量總和
與原 `build_distance_evaluations()` 完全相符；沒有把 sample 百分比當距離計數。
`_adjacency_with_candidate` 已在既有邊不 overflow 時避免距離計算，因此不能把
connect 成本誤判成只缺少一個「已存在邊就跳過」的簡單檢查。

## 等價性與限制

隔離目錄 `.build/2026-10-04-refresh-work` 從前一 frozen point-refresh source 複製。
唯一 core 差異是在 `refresh_cached_connections` 的既有階段前後記錄 counters，
沒有改排序、candidate pool、metric、heuristic、連邊或 public upsert。

使用既有成本探針的同一 initial graph、819 updates、205 deletes 與完整 final
native authority。最終 graph 結構通過，7,987 個 current points 的 **12,268,032
component bits**、205 個已刪 ID 均通過；52,250,404-byte graph snapshot 與先前
frozen point-refresh 最終 graph **逐 byte 相同**。輸入 final cache 的 SHA 也與
原報告記錄相同，不只核對目前 `.build` 檔案。

共保留 40,749 行 trace。Compiler build 與 standalone run 分別 exit 0；build
6.15 秒、含 instrumentation／audits 的 run 56.17 秒，**不是 acceptance latency**。
沒有新 query／recall／Qdrant gate，也沒有新完整測試或 production mutation。

## 參考與下一步

本機 Qdrant reference 為 `74f3e85b9473c62560006c043e13737ce6b48412`。
其 [GraphLayersHealer](https://github.com/qdrant/qdrant/blob/74f3e85b9473c62560006c043e13737ce6b48412/lib/segment/src/index/hnsw_index/graph_layers_healer.rs)
會先收集每個受影響 point/level，再逐中心修復；刪除修復保留 valid links，沿 deleted
components 尋找 live boundary shortcuts，填補容量後加入 backlinks。

可採用的是一次處理每個中心的排程方式。Updated-vector repair 與 deletion healing
不同，而且 Akasha 要求 bounded **symmetric** links，不能直接移植 Qdrant 的獨立
endpoint pruning。依 [下一個隔離方案](../plans/2026-10-04-batched-cache-repair.md)
驗證，不能直接加 pair-score memoization：相同 slot pair 的向量版本可能已變。

## 證據與重現

Archive：`../benchmarks/results/2026-10-04-refresh-work.json.gz`，576,580 bytes、
131 text entries；gzip 與全部 entry hashes 已核對。
SHA-256：`2787e8b4324dbd6cd6df35586b92692c9c148ee7dd2861a26df3ca1e5d3bdfe7`。
包含 source、instrumented probe、原 trace、summary、命令與 inputs hashes。
大圖／binary inputs 延用前一成本探針，不嵌入文字 archive。

```sh
rtk proxy python .build/2026-10-04-refresh-work/run.py
rtk proxy python .build/2026-10-04-refresh-work/summarize.py
```

`run.py` logs 使用 exclusive create。重現時另建 OUT，不能覆寫原 trace 或任何
frozen archive；編譯繼承 Metal wrapper。此診斷與所有 build/test/benchmarks 串行。
