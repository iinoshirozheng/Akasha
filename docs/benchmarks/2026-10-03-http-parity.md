# 原生 HTTP 與並行 clients 對照

**完整量測已完成，整體效能 FAILED：108/108 matched-recall 格通過，16/108 strict
parity 格通過。** 每格要求 QPS ≥ Qdrant 且 p95 ≤ Qdrant；沒有容許差距、跨格抵銷或
以 trial 中位數取代失敗。這是新增的 HTTP resident 邊界，不能和舊 binding 通過格相加。

| Corpus | Trial 0 | Trial 1 | Trial 2 | 合計 | Recall |
|---|---:|---:|---:|---:|---:|
| uniform-128 | 1/12 | 0/12 | 1/12 | 2/36 | 36/36 |
| uniform-1536 | 5/12 | 4/12 | 5/12 | 14/36 | 36/36 |
| real-1536 | 0/12 | 0/12 | 0/12 | 0/36 | 36/36 |

按 client concurrency 分開，依序是 1／2／4 clients 的通過格：uniform-128
為 **1/12、1/12、0/12**，uniform-1536 為 **8/12、3/12、3/12**，real-1536
均為 **0/12**。Real QPS 比值範圍 .529–.904；128D correlated／4 clients／trial 2
的 p95 比值達 5.128，該慢樣本及全部原始延遲均保留。不能宣稱提高並行度即可補齊差距。

## 固定邊界與資料

依 [量測前計畫](../plans/2026-10-03-http-parity.md) 執行。Apple M4／macOS ARM64；
Akasha production engine `d38bffa`，文件 HEAD `888905b`，Python binary：
`2d5e8e0910d4d81d84699e5bc023ba9824a5f9ab867b613cc6bcefcc7bcc0463`。
本工作包新增 harness／測試／證據，沒有修改 production engine 或 server routes。

Qdrant 原生 REST server 由既有 pinned commit
`21db2f3ff95d50de3a2b88a741312c056fd1762d` 建置，版本 `1.19.1-dev`。
使用隔離 Rust 1.97.0 (`2d8144b78`)、Cargo 1.97.0、protoc 22.2；`--locked --release`，
保留 upstream fat LTO／codegen-units=1，`RUSTFLAGS=-C target-cpu=apple-m4`。
正式量測 binary SHA-256：`ee0ddd031084b22be0bb7fd95a90c5b0a521b0d506fedc16034b90f5504b0b28`。
Cargo.lock SHA-256：`31fba6c44c6c90aea044bdfdeb00c7de5f08d894eb2ec4ab4d477299b0ea2a4a`。
九個 trial/server 均核對 HTTP `/` 回報的完整 commit；這不是 Edge 包一層 Python HTTP。

兩個 server 每次只有一個接受量測，一個 API worker；Qdrant max_search_threads=1、
max_indexing_threads=1、optimizer_cpu_budget=1。Akasha 使用已安裝的 FastAPI 0.141.1、
uvicorn 0.52.4、uvloop 0.22.1、httptools 0.8.0；共同 client 是 asyncio／httpx 0.28.1。
client 與 server 為不同 process。這是 resident、無受控 memory limit 的量測。

沿用原 `cost-plan-{uniform-128,uniform-1536,real-1536}` 三組 8,192-point corpus、
seed=12345、10% replacement、205 deletes、payload、四種 filter、K=10、oracle；
每個 filter 3 warmup + 64 timed query，固定三次 trial，兩引擎先後為 AB／BA／AB。
Akasha 使用各原 trial database 的新副本並以現行 binary 重開；Qdrant 各自新建 REST
collection，先建 base HNSW 再套用相同 replacements／deletes。測量前須 optimizer
green、running／queued 為空；更新可以留在 appendable delta，原 base 須仍有索引。
Setup、index build 與新副本 copy 不包含在 warm HTTP QPS 中。

| Corpus | Akasha ef（all/correlated/independent/selective） | Qdrant ef |
|---|---|---|
| uniform-128 | 128 / 32 / 32 / 10 | 96 / 256 / 256 / 10 |
| uniform-1536 | 512 / 128 / 128 / 10 | 512 / 512 / 512 / 10 |
| real-1536 | 16 / 32 / 40 / 10 | 24 / 128 / 128 / 10 |

使用先前已選定 ef，沒有根據本次速度重新挑參數。Target mean Recall@10 ≥ .95。
本次不是新的 ef／.99 curves；原曲線及其中失敗保持有效。

每 client 一個 connection、一個 outstanding request；共同事件起跑，按原 ordinal
固定分配 query。每格前先以 health 暖連線，再執行原三個 query warmups。
計時包含 JSON serialization、transport、server parse/search/response 與 client JSON
decode；oracle、結果 audit 與保存檔案在計時外。這是 closed-loop concurrency。
QPS 用 64 requests／整格 wall time；p50/p95/p99 用全部 64 個 request latency。

## 正確性與驗證

共 **24,120** 筆查詢回應通過 audit：4,824 exact preflight、4,824 approx preflight、
13,824 timed、648 warmup；沒有 HTTP／transport 或 audit error。逐筆驗證 finite score、
live ID、filter、重複 ID 與 independent oracle recall，全部 exact preflight recall=1。
並行／warmup 結果與各自串行 preflight 的 IDs／F32 score bits 一致。
Akasha 在串行 preflight 驗證 execution_kind；並行時不把共享 last_search_stats 當成
每 request 的 counters。Qdrant public query 的 candidate／fallback counters 未提供。

**33 targeted Python tests passed**（17 HTTP harness／16 既有 compare tests），包含
實際 Akasha HTTP adapter；另兩個真實 server 的 1／2／4 clients smoke 通過。
最初 smoke 暴露 Qdrant REST 的 full_scan_threshold 最小值 10，以及 info key 為
`optimizer_status`；已修正 harness 並保留失敗 logs。正式 corpus threshold 為 512／6144，
從未調低。初次 native build 誤用外層 repo commit 作 banner，正式量測前透過 upstream
`GIT_COMMIT_ID` 重建；兩次 build logs／SHA 均保留，只有修正後 binary 用於矩陣。

沒有重新跑完整 Mojo／Python／crash／GPU；既有 engine 驗證範圍仍見
[native metric 報告](2026-10-03-native-metric-loops.md)。Matrix assessment exit **1** 是
完整量測後的正確失敗 gate，report 沒有 infrastructure error 或缺格。

## 證據與重現

[凍結 archive](results/2026-10-03-http-parity.json.gz)：209 個文字檔，4,804,666 bytes；
已逐檔核對解壓 SHA-256。Archive SHA-256：
`4543d4eef7d54375e2e459526cb30c7e6b6440fa3da06f8e039aa47e50fcc971`。
內容包含全部 server configs／version responses／index readiness／raw samples／stats、
失敗 smoke logs、工具鏈與 source provenance、build/test logs、driver／harness source。
Corpus NPZ 沿用既有固定來源，各 report 記錄 SHA-256。

```sh
rtk proxy env PATH="$PWD/.build/compiler-bin:$PATH" \
  PYTHONPATH="python:.:.build/qdrant-compare/deps" \
  pixi run pytest -q tests/python/test_qdrant_http.py tests/python/test_qdrant_compare.py

rtk proxy env PATH="$PWD/.build/compiler-bin:$PATH" PYTHONPATH=python:. \
  OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 \
  pixi run python -m benchmarks.qdrant_http_matrix \
  --qdrant-binary .build/2026-10-03-qdrant-http/target/release/qdrant \
  --qdrant-build .build/2026-10-03-qdrant-http/build-identity.json \
  --output .build/http-parity-fresh
```

輸出目錄必須是全新的；需要重建 Qdrant 時，先從 archive 提取 bootstrap／build-identity
drivers，使用獨立目錄及所附官方工具鏈 SHA，待建置完成才跑矩陣。不要重跑會碰既有
產物的舊 driver。正式 `_kernel.so` 與 worker 未覆寫。

M5/M6 保持未完成。此工作補齊 resident HTTP 並行量測及可重現 gate，尚未達到速度目標；
下一步拆解 HTTP dispatch／binding／kernel 成本。Named 首次重開建圖、原 binding 全格
parity、持續 nonresident／controlled-memory 與最終整合仍需完成。
