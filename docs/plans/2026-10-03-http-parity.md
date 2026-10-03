# HTTP 與並行查詢驗收

補 M6 的獨立 HTTP 邊界：Akasha FastAPI／uvicorn 與 pinned Qdrant 原生 REST server，
均跑 macOS ARM64。Qdrant 使用既有 commit `21db2f3ff95d50de3a2b88a741312c056fd1762d`，
隔離 Rust 1.97 release build／Cargo.lock，不拿 Edge wrapper 代替 production server。
同一時間只有一個 server 被量測；不得與 build／test／archive compression 重疊。

沿用三組 8192-point corpus、更新／刪除、payload、seed、filters、K=10、64 timed queries
與原三 warmup，三個 fresh trials。HTTP 是新增邊界；既有 binding 矩陣完全保留。
固定新增 client concurrency=1/2/4，各 server 一個 API worker，Qdrant 一個 search thread、
一個 indexing thread。Akasha 使用現有 native path；不新增 GIL release 或改 ownership。
Akasha server 明確選用已安裝、也是 uvicorn 自動選擇的 uvloop／httptools，記錄版本；
client 共用 asyncio／httpx。兩邊關閉 access log，原始 server logs 仍保存。
先使用原矩陣已固定的各引擎 ef；若 HTTP server 的圖導致 recall 未達 .95，保留該失敗，
再另跑原完整 ef curves 查明，不能把失敗移除或用 exact 掩蓋。

HTTP request 的 JSON serialization、loopback transport、server parsing／search／response
與 client JSON decode 包含在 latency；oracle、結果 audit、檔案寫入在計時外。
每 client 最多一個 outstanding request，以同一事件起跑，逐 client 固定輪流分配
64 個原始 query。這是 closed-loop concurrency，不聲稱涵蓋固定 arrival-rate 負載。
每 client 先用 health 建 connection，再執行原三個 sequential query warmups。
全部 timed queries 一次各用一個原 ordinal，不增刪 query，也不丟棄失敗／慢 request。
並行 QPS 使用完成總數／整格 wall time，不能用各 request latency 總和。

每個回應保留 IDs、scores、latency、HTTP status／exception，逐筆驗證 live IDs、filters、
重複 ID、finite scores、獨立 oracle recall。Akasha last_search_stats 是共享最後值，
只在串行 preflight 讀取；不得把並行時讀到的值當成各 request 的 counters。
串行 exact preflight 驗證已載入完整最終資料；測量前確認 Qdrant HNSW 已建成且 optimizer idle。

每個 trial/filter/concurrency 都必須兩邊 quality 通過，再判 QPS ≥ Qdrant 且 p95 ≤ Qdrant。
缺少格、request error、無效結果、低 recall 均失敗；不跨 trial/filter/concurrency 抵銷。
先驗證 harness 的 concurrent wall-time／錯誤保存／strict gate，再以實際 server smoke
確認公開 API，最後跑固定矩陣。這份 gate 不取代 cold/open、nonresident、memory-limit，
也不等同於 mixed writes／maintenance 已通過。
