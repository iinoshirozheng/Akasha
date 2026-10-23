# HTTP 搜尋減少一次 worker 往返

已採用 search endpoint 的 async 排程：`collection.search` 仍透過 Starlette
`run_in_threadpool` 在 worker 執行，FastAPI 原有的小型 response validation 在
event loop 執行。保留 request／response 型別、JSON serializer、OpenAPI 與錯誤處理；
沒有繞過 validation、改動 GIL 或 native ownership。

**最新三方對照：前版 14/108 → 採用版 22/108 strict parity，兩版各 108/108 recall
通過，整體仍 FAILED。** 有兩格 pass→fail，全部保留；不能用新增通過格抵銷。
這個工作包完成局部排程改善，不代表 M5/M6 完成。

## 瓶頸證據與實作

基線 `adad4b1`。FastAPI 0.141.1 的 `routing.serialize_response` 對同步 endpoint
會再透過 worker 執行 `ModelField.validate`。完整 baseline profile 的每個 request
都有兩次 worker 往返：`search_points` 與 `ModelField.validate`。

| All filter | 驗證本身，1 client | 驗證往返等待，1 client | 驗證往返等待，4 clients |
|---|---:|---:|---:|
| uniform-128 | 2.6 µs | 68.4 µs | 348.8 µs |
| uniform-1536 | 4.4 µs | 74.0 µs | 904.1 µs |
| real-1536 | 2.7 µs | 69.1 µs | 441.4 µs |

這些是各格 64 timed requests 的平均分段時間，用來定位成本，不是性能驗收的
trial 中位數。所有 filters／1/2/4 clients 的完整分段保存在 archive。
驗證往返等候約占 client 延遲總和的 3–14%；native 計時包含 Mojo binding 與 kernel，
不能解讀成純 kernel 時間。ASGI 外的時間另含 client serialization／transport／protocol。

改動僅是 async endpoint 加上明確的既有 worker call。根據已安裝 FastAPI 的
is_coroutine 分支，response validation 仍走原方法，只省去其 worker 往返；
[FastAPI 的 async 說明](https://fastapi.tiangolo.com/async/) 及本地 runtime source
SHA 記錄於 plan／archive。沒有新增套件或 response wrapper。

採用版完整 profile 共 4,020 requests，各自只有一次 worker 往返；和完整 baseline
profile 的 4,020 組 IDs／F32 score bits 相同。Baseline 中另有 2,304 timed 結果與
上一份正式 HTTP trial-0 相同。Instrumentation 是獨立診斷，不納入 Qdrant 速度 gate。

## 獨立 A/B 與三方矩陣

沿用 [HTTP gate](2026-10-03-http-parity.md) 的三個 corpus、seed、updates／deletes、
K、四種 filters、固定各引擎 ef、64 timed + 3 warmup、三 trials、1/2/4 clients、
server／client 邊界及資源設定。全部循序執行，沒有與 build／test／compression 重疊。
前後版使用 copied apps package，以 `--app-dir` 選定，startup assertion 核對實際
route source；native binary 一致。

第一份 A/B：各 corpus 的三次順序為 before→after／after→before／before→after。
**12,060 配對查詢 IDs／F32 bits 相同，24,120 audits 通過**；九份 OpenAPI 前後相同。
86/108 格 QPS 與 p95 同時改善；其餘 22 格保留。例如 uniform-128 correlated／trial 1
三種 concurrency 的 QPS 比值為 .636／.687／.725，不能宣稱每格加速。

第二份三方對照：三次順序固定為 before→after→Qdrant、after→Qdrant→before、
Qdrant→before→after。每次重建 Qdrant REST collection；前後版各使用相同原 trial
database 的新副本。兩版對照同一 trial／filter／concurrency 的 Qdrant cell。

| Corpus | Trial 0，前→後 | Trial 1，前→後 | Trial 2，前→後 | 合計，前→後 |
|---|---|---|---|---|
| uniform-128 | 0→2 /12 | 0→3 /12 | 0→0 /12 | 0→5 /36 |
| uniform-1536 | 4→6 /12 | 5→5 /12 | 5→6 /12 | 14→17 /36 |
| real-1536 | 0→0 /12 | 0→0 /12 | 0→0 /12 | 0→0 /36 |

三方共 **36,180 query audits**：7,236 exact preflight、7,236 approx preflight、
20,736 timed、972 warmup；全部 valid，exact preflight recall=1。前後版的另外
12,060 配對 IDs／F32 bits 相同。兩版各 108 格符合 recall，81/108 格前後兩項速度
均改善；strict Qdrant gate 為 14→22/108。以下兩個新失敗不能忽略：

| Pass→fail cell | 採用版／前版 QPS | 採用版／前版 p95 |
|---|---:|---:|
| uniform-1536 independent，trial 1，1 client | .944 | 1.134 |
| uniform-1536 all，trial 2，4 clients | 1.097 | 1.273 |

採用理由是移除已確認的額外排程、維持公開合約，且兩份完整獨立對照都有廣泛改善。
上述退步仍是 M6 缺口。初次正式 HTTP 的 16/108、此三方的 14/108 baseline 是不同
實驗，不能相加或挑選最好 trial；本次 assessment exit 1 是完整矩陣 FAILED。

## 驗證與產物

隔離 candidate 與 promotion 後的正式 package 各通過 **41 targeted Python tests**：
8 server、17 HTTP harness、16 compare tests。新增測試驗證公開 HTTP 搜尋的 native
operation 使用 worker thread。沒有新完整 Mojo／Python／crash／C ABI／GPU 驗收；
native engine 未改，沿用既有範圍。

正式 route SHA-256：`497da8534c983040f2f5cd6278c56fc60c0e89f54175889e444dde24b3f9a7db`。
Python native binary 保持 `2d5e8e0910d4d81d84699e5bc023ba9824a5f9ab867b613cc6bcefcc7bcc0463`。
Qdrant binary 保持 `ee0ddd031084b22be0bb7fd95a90c5b0a521b0d506fedc16034b90f5504b0b28`；
同一 pinned commit／Rust release 設定見前份 HTTP 報告。

[完整 frozen archive](results/2026-10-03-http-dispatch.json.gz)：338 個文字檔、
14,816,118 bytes，逐檔解壓 SHA 已核對。SHA-256：
`42b21711eac46062476f9fd87130b0f9014a2c1177292e3c3869f8e211678c3b`。
包含全部有效／失敗 profile setup、前後 app source、完整 A/B／三方樣本、OpenAPI、
server logs、測試、source guards、runtime hashes 與 transition 表。

早期 profile 假設只有一次 worker call，assertion 揭露實際兩次；首次 candidate profile
又因 `python -m uvicorn` 的 cwd 優先順序載入 production apps，source selection 已改成
明確 `--app-dir` 並加 runtime assertion。這兩次 logs 保留，但不當成有效 candidate
量測；有效路徑是 `http-profile-complete` 與 `http-dispatch/profile-after-verified`。

```sh
rtk proxy env PATH="$PWD/.build/compiler-bin:$PATH" \
  PYTHONPATH="python:.:.build/qdrant-compare/deps" pixi run pytest -q \
  tests/python/test_server.py tests/python/test_qdrant_http.py tests/python/test_qdrant_compare.py
```

重現 profile／A/B／三方比較時，先從 archive 提取對應 driver／apps 到新目錄，核對
source hashes，調整所有 output／app-dir 指向新位置。Saved apps pytest 要 `-o pythonpath=`
並核對實際 import source；benchmark 維持串行。不可直接重跑原 driver 覆寫證據。

M5/M6 尚有 named 首次重開建圖、原 binding／HTTP 全格 parity、持續 nonresident／
controlled-memory 與最終整合；使用者目前沒有原生 Linux runner。下一步回到 named
artifact 的持久化生命週期，避免只在 HTTP 層反覆量測。
