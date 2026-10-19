# 排除：只對通過篩選的候選預取第一個位址

原型不採用。uniform-1536 correlated／independent 的 QPS 在兩種執行順序中都比 deferred-ID parent 低；real-correlated 的 p95 也兩次變差。保留 parent，產品 `src/` 沒有變動，嚴格 mixed 結果仍為 **25/36**。

## 動機與實作

[完整 mixed 存取追蹤](2026-10-20-immutable-point-access-trace.md)顯示 mapped 候選大多不符合 Qdrant 的 sequential heuristic。舊 [HNSW prefetch 實驗](../benchmarks/results/2026-10-01-hnsw-prefetch.json)在 visited／filter 之前處理所有鄰居；本輪則遵循 pinned Qdrant `PointScorer` 先篩選、cap 再批次讀取的順序，測試更少的提示是否能改善讀取等待。

從 `immutable-point-deferred-id` 完整複製 132 份 source，只改三個檔案：

- `hnsw_search.mojo`：F32 backend 對至少兩筆的已 compact/cap 候選呼叫一次 storage hint。
- `hnsw_storage.mojo`：trait 預設不發出提示，owned storage 行為維持原樣。
- `hnsw_view.mojo`：檢查 mapping 開啟、F32 型別、列寬與 offset；用減法／除法避免 overflow，僅對完整有效列的第一個位址發出讀取提示。

提示不傳回 pointer，也不改變 scorer 的驗證順序；無效 descriptor／slot 不發出提示，原有計分路徑仍負責錯誤。沒有新 cache、欄位、依賴、配置、維度門檻、格式、ef 或算術變更。Qdrant 同步 mmap 程式並沒有被描述成使用同一個硬體提示，這是 Akasha 的實驗。

Parent native SHA-256 為 `64e6db6f4be40a10bd772c442a5bafce19d3a7f0b8e1158e790f75a2c880afde`；candidate 為 `7e944b6ae59a7a6389425078c3aa974d7327d68bb3d519957ec9dbdec28ae22b`。對實際測量 binary 反組譯，確認 helper 中存在 `prfm pldl1keep`。指令存在本身不證明有效能收益。

## 正確性驗證

新增的五個 scorer hook/order 案例在 parent 上有兩個 runtime failure：預期呼叫 hint 一次，實際零次。實作後五個全通過，確認 hint 收到的只有通過 inactive／source／filter 與 cap 的 slots，順序不變，也沒有增加 public ID 讀取。

總計 **71 個獨立 Mojo 案例、九個 module** 通過：新增五個、four-distance 3、filtered 8、search layer 17、control 2、mapped view 9、mapped vectors 4、segmented 21、filtered delta ID 2。

擴充的 four-distance matrix 覆蓋 dot／L2／cosine、14 種維度（1 至 1,536）、owned／mapped 的分數位元、重複與不連續 slot、filter compaction、cap、tail、buffer reuse、錯誤維度與關閉 mapping。另直接傳入無效 slot、零／負／極端 dimension，以及負／檔案尾端／極端 offset，確認提示不引入錯誤或改變後續有效計分。

shared library 編譯成功。每個 screen worker 的 Python package 與明確載入的 native 都使用選定的版本，並驗證 Python facade 實際使用該 module。

## 固定輸入的兩種執行順序

三個 corpus 各跑 parent→candidate、candidate→parent，共 **12 個 worker**。每個從相同 frozen 初始資料庫的新副本重播完整 mixed 計畫；build、測試、worker、反組譯及壓縮均依序執行。

**3,456 筆**回應的 IDs、F32 score bits、stats、execution、recall 與 oracle 逐筆符合 parent；12 次 exact reopen、12 次 retained Arrow lease 檢查通過。36 次 warmup 回傳未比對，不算進這些筆數。這是實作 screen，沒有新增 Qdrant 比較或達標判定。

下表為兩個順序的 candidate／parent 比值中位數；QPS 大於 1、p95 小於 1 才是改善。所有個別順序的值保留於 archive。

| Corpus / mode | QPS 比值 | p95 比值 |
| --- | ---: | ---: |
| uniform-128 / all | 1.0033 | 0.9812 |
| uniform-128 / correlated | 1.0022 | 1.0161 |
| uniform-128 / independent | 1.0084 | 0.9730 |
| uniform-128 / selective | 1.0263 | 0.9466 |
| uniform-1536 / all | 1.0007 | 0.9936 |
| uniform-1536 / correlated | 0.9914 | 0.9967 |
| uniform-1536 / independent | 0.9926 | 1.0055 |
| uniform-1536 / selective | 0.9867 | 1.0035 |
| real-1536 / all | 1.0179 | 0.9706 |
| real-1536 / correlated | 1.0164 | 1.0311 |
| real-1536 / independent | 1.0152 | 0.9691 |
| real-1536 / selective | 1.0139 | 0.9586 |

uniform-1536 correlated QPS 為 0.9931／0.9898，independent 為 0.9921／0.9931；real-correlated p95 為 1.0288／1.0333。目標 cell 沒有穩定改善，因此不採用。這不表示已證明所有 prefetch 策略都無效，也沒有加入維度例外來排除退步值。

## 保留狀態與可重現產物

保留 deferred-ID source 與 native；本輪沒有 production 修改。因 screen 沒有支持採用，沒有為此原型新增完整 Python、crash、C、GPU 或 Linux 驗證。既有結果與所有未達標項目繼續依[原計畫](../plans/2026-10-13-mapped-numeric-ownership.md)處理，沒有放寬品質、速度或平台要求。

下一步回到 parent 的 metadata／admission 路徑，對照 Qdrant 的直接 bitmap 檢查，先確認可保留 current、closed mapping 與統計語意的實作。已排除的全鄰居 prefetch、兩列 tail 與複製 node metadata 不作為新的 parent。

- 本機：`.build/qdrant-alignment/immutable-point-admitted-prefetch/`。
- [Archive](2026-10-20-immutable-point-admitted-prefetch.json.gz)：279 份文字產物，946,267 bytes。
- SHA-256：`b357a051aa824315973bdfef390a2964f05ee282649a57db687ad0ee194298af`。
- 包含完整 candidate source、Python runtime source、實際測試與 helper 快照、RED/GREEN、全部 screen、命令、native symbols、hint 組合語言及來源／封存檢查。沒有把 binary 或資料庫複本寫入 archive。
