# Qdrant 逐格效能驗收門檻

2026-10-02 使用者確認：目前完整矩陣在相同 recall 目標下，每格 **Akasha QPS ≥ Qdrant、
p95 ≤ Qdrant**。不設容許差距，不以其他格的改善抵銷未過項目。保留既定資料、
seeds、filters、K、service 邊界及 repeated trials；目前暖查詢矩陣的 recall 目標為 .95，
.99 曲線仍作診斷。無直接對應的型別／metric 以獨立 oracle 驗收。

`benchmarks/qdrant_compare.py:matched_summary` 仍選各引擎達 recall 的最小 ef，
不挑噪音中最快的 ef；先記錄 `quality_status`，再以 QPS 與 p95 的雙門檻設定
`status`。任一配對未過，完整 runner 回傳失敗。保留兩個比值及個別結果；缺少或
未過品質的資料不能產生速度對照。這修正了舊報表 `PASSED` 僅表示品質可比的歧義。

以下將**已凍結的細化 ef 暖查詢原始量測**套入新門檻，未重跑計時、修改 ef、刪除
樣本，也不是後續 CRC／prepared-query 改動的新效能驗收。原先 36/36 配對皆達 recall，
其中僅 **16/36** 同時達速度門檻，整體仍為 **FAILED**。表中比值為三次配對的中位數，
最後一欄列逐次通過數；中位數不抵銷失敗的配對。

| 資料 | filter | QPS A/Q | p95 A/Q | 雙門檻通過 |
|---|---|---:|---:|---:|
| uniform-128 | all | 0.714 | 1.376 | 0/3 |
| uniform-128 | correlated | 2.176 | 0.698 | 3/3 |
| uniform-128 | independent | 2.430 | 0.619 | 3/3 |
| uniform-128 | selective | 0.997 | 0.999 | 1/3 |
| uniform-1536 | all | 1.761 | 0.548 | 3/3 |
| uniform-1536 | correlated | 1.214 | 0.897 | 3/3 |
| uniform-1536 | independent | 1.156 | 0.893 | 3/3 |
| uniform-1536 | selective | 0.801 | 1.220 | 0/3 |
| real-1536 | all | 0.844 | 1.266 | 0/3 |
| real-1536 | correlated | 0.675 | 1.418 | 0/3 |
| real-1536 | independent | 0.573 | 1.711 | 0/3 |
| real-1536 | selective | 0.698 | 1.480 | 0/3 |

新增五個驗收案例涵蓋相等、雙項較快、只有 QPS 較慢、只有 p95 較慢與 1% 落差；
另一格通過也不能改變失敗格的結果。既有缺失／recall／fallback／reopen 和 adapter
oracle 一併驗證，**13 passed**。未修改引擎、資料格式或 query 選擇策略。

[完整 gate、來源與驗證](results/2026-10-02-qdrant-parity-gate.json)，
SHA-256 `a2d3a91a1409f812e84d2344e337fb9498d44b28d4d58c2c6270517ce1dc4c1e`；原始 timings 與失敗 recall cells 沿用
[細化 ef 報告](2026-10-02-refined-ef-warm.md) 的已凍結 artifact。

後續暖查詢與 mixed runner 已共用 `latency_parity`，mixed 也會檢查完整四個 mode，
缺格／recall 不足／無效 fallback 不產生速度比值，任一格失敗會保留全部結果並退出 1。
Mixed 報表的速度比值欄位統一為 `qps_ratio_akasha_over_qdrant` 與
`p95_ratio_akasha_over_qdrant`。共 **16 項** targeted tests 通過；上述 13-test artifact
保持凍結，新版本與驗證記錄在 [prepared exact 報告](2026-10-02-prepared-exact.md)。
