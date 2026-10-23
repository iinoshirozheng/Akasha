# HTTP 搜尋的回應驗證排程

`adad4b1` 的 HTTP gate 為 16/108 strict parity。隔離 profile 顯示每個 search request
有 `search_points` 與 `ModelField.validate` 兩次 worker 往返；後者實作約 2–4 µs，
單 client 往返等候約 67–84 µs，四 clients 約 199–904 µs。4,020 筆 traces／quality
通過，其中 2,304 timed IDs／F32 score bits 與正式 HTTP trial-0 相同。
這是 instrumentation 診斷，不能當成 Qdrant parity；native 計時包含 binding 與 kernel。

最小候選：將 search endpoint 改為 async，明確用既有 Starlette `run_in_threadpool`
執行 `collection.search`。FastAPI 對 async endpoint 仍執行原 response validation，
但在 event loop 直接完成這段短工作，減少一次 thread handoff。Kernel 繼續留在 worker；
不改輸入／輸出型別、response schema、JSON serializer、錯誤處理、資料庫 ownership。
不新增套件或繞過 response validation。

先在 copied apps package 實作，驗證公開 HTTP 回歸、kernel 不在 event loop 執行、
OpenAPI schema 相同，並複核 profile 的 response-validation handoff 消失。之後跑三資料、
三 trial、四 filters、1/2/4 clients 的固定 A/B，保留全部 samples／failures。
有穩定改善才採用並重跑獨立 Qdrant HTTP gate；原 binding gate 不合併。

參考：已安裝 FastAPI 0.141.1 `routing.serialize_response` 的 is_coroutine 分支，及
[FastAPI async 說明](https://fastapi.tiangolo.com/async/)。原同步 native call 的排程沿用
Starlette 的既有 `run_in_threadpool`，不直接在 async handler 中執行阻塞搜尋。
