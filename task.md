# AkashaDB 工作入口

**2026-10-30 使用者啟動完整功能實作：先功能，全部完成後再優化。**
本次完整範圍涵蓋先前列出的 Qdrant、LanceDB、一般 DB、前端、叢集與維運缺口。
演算法先固定上游來源、移植為 Mojo 並對照驗證；HTTP／SDK／前端保持薄邊界。

- 最新 D01c4g：JSONB 條件已接上 collection 搜尋、掃描、公式、Arrow、現有 HTTP 與條件式 payload 更新。重用來源 predicate／exists／布林取值／陣列包含函式；111,100 組原始來源結果在直接與 metadata bitmap 路徑一致，並修正 bitmap 提前執行應被短路略過分支的錯誤。
  59 項相關 Mojo、23 項新增 Python、完整 Python **3,739 通過／1 跳過**，最終模組建置通過。[驗證](docs/research/2026-10-30-jsonb-condition-validation.md)／[用法](docs/native-jsonb.md#collection-jsonb-filters)。下一步為計算投影、專用索引及剩餘介面；完整 49 大項及效能門檻仍開放，尚未優化。

- D01c4f 已完成 Lance 的 11 個 JSON 值／Arrow 操作：第一筆與多筆取值、型別標籤、exists、key/index get、nullable 轉型與陣列函式；全部由 Mojo 執行，公開 `akashadb.json_functions` 可直接使用。47,223 組情境／216,337 組來源結果對照，25 項 Mojo、18 項新增 Python、178 項邊界回歸與完整 Python **3,716 通過／1 跳過**；來源可逐 byte 重現。兩組來源包裝輸入超過既有深度限制，保留原始結果並驗證明確拒絕。
  [驗證](docs/research/2026-10-30-lance-json-functions-validation.md)／[用法](docs/native-jsonb.md#lance-json-functions)。下一步為 collection JSONB 過濾／投影與索引整合；完整 49 大項及效能門檻仍開放，尚未優化。

- D01c4e：jsonb Number 的五種精確／四捨五入轉型、RawJsonb 五種 scalar cast 及 ethnum 完整無號 256 位除法已移植；Python 可用 `JsonbValue.cast(...)`，所有轉型由 Mojo 執行。
  96,744 組數值、19,975 組 JSONB 值與 22,188 組來源除法對照通過；25 項相關 Mojo、17 項新增 Python、完整 Python **3,698 通過／1 跳過**，來源產物可重現。
  [驗證](docs/research/2026-10-30-jsonb-cast-validation.md)／[Lance 整合計畫](docs/plans/2026-10-30-lance-json-functions-source-port.md)。下一步為實際 Lance 取值／型別／nullable Arrow consumer，再接 collection 過濾／投影／索引；完整 49 大項與效能門檻仍開放，尚未優化。

- D01c4d：Number／完整已解析 JSONB AST 的原生 Display 已依 jsonb／ethnum 來源移植，保留精確 Decimal 文字、路徑原始輸出規則與上游邊界行為；查詢及格式化共用 AST 驗證。
  88,716 組數值、8,525 組路徑與 11,692 組來源除法對照通過；21 項相關 Mojo、重建 Python 模組與完整 Python **3,681 通過／1 跳過**，來源產物可重現。
  [驗證](docs/research/2026-10-30-jsonb-display-validation.md)／[用法](docs/native-jsonb.md#native-source-display)。下一步為 Lance consumer、完整轉型與 collection 過濾／投影／索引整合；完整 49 大項與效能門檻仍開放，尚未優化。

- D01c4c：完整已解析 JSONB 語法的六種 selector 模式已移植到 Mojo，公開 Python `JsonbValue.query` 可直接查詢值；保留來源排序、重複、unknown、數值序列化及錯誤行為。
  64,856 組來源案例、389,100 組模式結果完成對照；1 組超過既有 codec 深度限制的來源成功結果明確拒絕。22 項相關 Mojo、52 項新增 Python 及完整 Python **3,681 通過／1 跳過**，fixture／metadata／lock 可逐 byte 重現。
  [驗證](docs/research/2026-10-30-jsonb-selector-validation.md)／[用法](docs/native-jsonb.md#jsonb-value-queries)。下一步為來源 Display、Lance consumer 與 collection 過濾／投影／索引整合；完整 49 大項與效能門檻仍開放，尚未優化。

- D01c4b：原生 JSONB Number 的六種型別比較／算術已依 jsonb、ethnum、Arrow 與 ordered-float 來源移植，保留原始型別、溢位、尺度與 NaN 規則。8,495 組單值、94,213 組雙值、2,404 組 256 位乘法、256 組尺度冪次及 4,709 組含舊格式的數值 body 全部對齊；17 項相關原生測試通過，來源可逐 byte 重現。
  [驗證](docs/research/2026-10-30-jsonb-number-validation.md)／[用法](docs/native-jsonb.md#native-jsonb-expression-numbers)。下一步為完整 selector 六種輸出模式、Display 及公開 query／索引；完整 49 大項與未達標項目仍開放，尚未優化。

- 最新 D01c4a：已依 jsonb／nom 原始碼移植完整 JSONB 路徑／運算式語法與 owned AST，與 Qdrant 路徑分開。8,525 組原始來源案例包含 4,238 組 AST、4,275 組拒絕與 12 組來源 panic，Mojo 皆一致；7 項相關原生測試通過，來源可重現。
  [驗證](docs/research/2026-10-30-jsonb-path-parser-validation.md)／[完整執行計畫](docs/plans/2026-10-30-jsonb-path-source-port.md)。這是原生 parser 依賴，尚未完成選取執行／數值運算／公開 query／索引；下一步依來源補齊 Number 與完整 selector。完整 49 大項範圍不變，尚未優化。
- D01c3j：`arrow.json`／`lance.json` 已接上兩種 Arrow 匯入與原生 C Data scanner，包含 StringView、Map、巢狀／切片、metadata，以及 storage null／JSON null 區分。20,757 組來源文字、28,901 組 binary／text 與 12 組 Lance 原始碼巢狀轉換對照通過；來源產物逐 byte 可重現。
  24 項相關 Mojo、183 項指定 Python、完整 Python **3,629 通過／1 跳過**。[驗證與範圍](docs/research/2026-10-30-arrow-json-validation.md)／[用法](docs/native-jsonb.md#arrow-json-interchange)。下一步為 JSONB 路徑查詢／索引、任意頂層鍵與剩餘 C／分散式值邊界；完整產品與 M5/M6 仍未完成，尚未優化。
- D01c3i：完整既有 JSONB 型別已接上 Mojo `format_jsonb` 與 Python `to_json(pretty=...)`，採 RawJsonb／serde_json 路徑；含 Decimal、Binary、日期／時間／interval、舊編碼及原始鍵順序。29,003 組來源 body 的兩種輸出／錯誤一致；3 項 Mojo、74 項指定 Python、完整 Python **3,485 通過／1 跳過**。
  [文字輸出驗證](docs/research/2026-10-30-jsonb-writer-validation.md)。下一步完成 Arrow JSON nullable slots／巢狀 metadata 的匯入匯出；JSONB 查詢／索引及完整產品／效能清單仍開放，尚未優化。
- D01c3h：已依 zmij 1.0.21 原始碼移植 F64 文字格式化，保留快速路徑、Schubfach 邊界與原始 portable BCD 寫出。70,662 組文字、70,640 組兩條中間轉換結果及 70,642 組有限值位元往返一致；4 項 Mojo 通過，來源與查表資料可重現。
  [格式化驗證](docs/research/2026-10-30-zmij-validation.md)。這是 RawJsonb／serde_json writer 的數值依賴；完整 writer、Arrow JSON 及產品／效能清單仍開放，未開始優化。
- D01c3g：jsonb 0.5.6 標準／擴充文字 parser 已移植至 Mojo，並提供 Python `JsonbValue.from_json`。20,757 組來源輸入在 Mojo／Python 的接受結果與二進位 body 一致；29 項相關 Mojo、61 項指定 Python 與完整 Python **3,472 通過／1 跳過**。
  [文字解析驗證](docs/research/2026-10-30-jsonb-reader-validation.md)。下一步為 Lance 實際使用的 RawJsonb／serde_json serializer 與數字格式化，再完成 Arrow JSON；完整產品清單及效能門檻維持開放，尚未優化。
- D01c3f：已依 fast-float2 0.2.3 原始碼移植 F64 數字解析，保留短路徑、128 位乘法與 768 位長尾數捨入。15,191 組來源輸入的位元／完整與前綴解析一致，含 801 組長尾數分支與 12,162 組強制長尾數對照；3 個相關 Mojo 模組／18 項通過，來源與查表資料可重現。
  [數字解析驗證](docs/research/2026-10-30-fast-float-validation.md)。這是 jsonb 文字功能的依賴；下一步移植完整 grammar／serializer 並串接 Arrow JSON，完整產品及未達標清單維持開放，未開始優化。
- D01c3e：JSONB 已接上 Python 值／批次／payload 更新、HTTP 與 NDJSON v3；使用明確的 bytes carrier／typed encoding，保留一般物件鍵及 storage null／JSONB null 差異。v1／v2 邏輯匯入持續支援。
  全部 6,331 組來源 body 通過公開寫讀與邏輯往返；新增 46 項 Python、17 項相關 Mojo、120 項指定回歸通過；完整 Python **3,457 通過、1 跳過**。
  [公開邊界驗證](docs/research/2026-10-30-jsonb-boundary-validation.md)。下一步依來源移植 jsonb 文字 parser／fast-float／serializer，再完成 Arrow JSON；完整 C／分散式值介面、JSONB 查詢／索引與所有產品待辦仍開放，尚未優化。
- D01c3d：原生 JSONB 已接入 payload v3 與 collection；保留 v1／v2 讀取，更新／checkpoint／compaction 沿既有原子流程轉寫，不增加資料序號或 schema revision。
  21 個 Mojo 模組／130 項測試通過，包含 6,331 組來源 body 的 payload 往返、巢狀資源限制、混合版本恢復、快照、壓縮、實體備份與損毀／torn WAL。
  [持久化驗證](docs/research/2026-10-30-jsonb-storage-validation.md)／[格式契約](docs/formats/payload-format.md)。完整 Python **3,411 通過、1 跳過**，crash **9 模組／24 項**與 C ABI 通過；公開 Python／HTTP／NDJSON／Arrow JSON、文字解析與序列化仍需完成。未優化，完整任務清單持續開放。
- D01c3c：原生 `JsonbValue` 二進位值／codec 已依 jsonb 0.5.6 databend 來源移植，包含 JSON 基本型別、NaN／Infinity、三種 Decimal、Binary、日期／時間區間與容器；儲存 null 保持獨立。
  6,246 組來源 byte／typed tree 對照與 85 組舊格式對照、24 項相關 Mojo、模組建置及完整 Python **3,411 通過、1 跳過**；fixture／metadata／lock 逐位元重現。
  [驗證](docs/research/2026-10-30-jsonb-codec-validation.md)／[原生 API](docs/native-jsonb.md)。當時是 binary-value 依賴；原生持久化已由 D01c3d 接續，公開值邊界／Arrow JSON 與文字解析／序列化仍待完成。完整產品與效能清單仍開放，尚未優化。
- D01c3b：StringView 已依 Arrow 來源接上兩個匯入 API 與原生 C Data 匯出，涵蓋巢狀／切片／null、inline／外部 buffer、UTF-8、所有權與資源限制。
  26 項新增 Python、17 項相關原生、212 項 Arrow 回歸及完整 Python **3,411 通過、1 跳過**；來源資料／IPC／metadata／lock 逐位元重現。
  Lance 原始模組與 jsonb 的 5,641 組輸入已實際執行；和 serde_json 共用的輸入有 695 組接受結果不同，也確認 storage null 與 JSON null 必須分開保存。
  [驗證](docs/research/2026-10-30-lance-json-stringview-validation.md)。下一步為獨立 JSONB 邏輯值／來源二進位 codec 與持久遷移，再完成 jsonb 解析／序列化及 Arrow JSON extension；這批來源刻畫不是 Akasha JSONB 功能驗收，完整產品與效能清單持續開放。
- D01c3a：原生 JSON 讀取基礎已移植並驗證，採固定 serde_json 1.0.151 default numeric profile，保留 UTF-8／surrogate、數字位元、負零、重複鍵順序與原生資源限制。
  5,630 組來源案例（3,063 接受並通過 codec 往返，2,567 拒絕）、18 項相關原生測試與完整 Python **3,385 通過、1 跳過**；build 與 fixture／數字表重現通過。
  [驗證](docs/research/2026-10-30-json-reader-validation.md)。這是 D01c3 的原生依賴；Lance/jsonb 來源對照已由 D01c3b 補入，JSONB 表示與完整 Arrow JSON 仍待完成。未宣稱 Lance 等價、完整 D01 或任何全產品／效能門檻完成。
- D01c2：巢狀 typed Arrow 匯出已完成，接受 PyArrow 型別／欄位、保留指定 nullability／metadata，以原生 C Data 輸出；舊純量分支已移除，共用同一匯出路徑。
  2,126 組來源輸入各驗證 F16／F32，修正來源所需的 F32 中間捨入；55 項新增 Python、14 項相關原生及完整 Python **3,385 通過、1 跳過**。來源 fixture／metadata／lock 可逐位元重現。
  [驗證](docs/research/2026-10-30-rich-arrow-export-validation.md)。下一步為動態 `arrow.json` extension 與 missing／null／任意鍵互通；D01、Lance schema／歷史版本與完整產品清單仍未完成，尚未優化。
- D01c1：巢狀 typed Arrow 匯入已移植到 Mojo，涵蓋 struct／list／UInt64／null、所有整數寬度及有限浮點，兩個 upsert API 共用原生 buffer traversal。
  固定 Arrow／Lance 來源產生 88 個 cell 對照，15 項原生與完整 Python **3,330 通過、1 跳過**；82 項新增公開測試。
  [驗證](docs/research/2026-10-30-rich-arrow-ingress-validation.md)。巢狀 typed Arrow 匯出已由 D01c2 補入；JSON extension、D01 與完整產品清單未完成，尚未優化。
- D03f：已移植 Qdrant 點 ID／向量存在／固定分片條件、獨立路徑空值條件，
  以及 siphasher 的固定 SipHash-2-4；nested 範圍依來源清除點身分與向量資訊。
  搜尋／公式／掃描／條件更新、Python／Arrow／現有 HTTP 已串接。
  12,656 組來源案例、2,187 組精確雜湊、45 項原生與新增 36 項 Python 測試通過；
  完整 Python **3,248 項通過、1 項既有跳過**。
  [驗證與範圍](docs/research/2026-10-30-point-filter-validation.md)。
  完整 UInt64／UUID 點 ID、rich Arrow、專用索引／全文搜尋及其餘產品待辦仍開放。
- D03e：Qdrant／GeoRust polygon 與 robust 自適應精度已移植到 Mojo，
  保留外框／孔洞／邊界、EPSILON 閉合與來源退化幾何行為。
  17,060 組 polygon 與 31,167 組精確位元來源對照、33 項原生與 24 項新增
  Python 測試通過；完整 Python **3,212 項通過、1 項既有跳過**。
  [驗證與範圍](docs/research/2026-10-30-polygon-validation.md)。
  下一步為專用索引、剩餘條件與 rich Arrow；完整產品待辦持續保留，尚未優化。
- D03d：已接入來源對照的 JSON-path／巢狀同元素／至少 N 條件、集合與
  純文字比對、數值／日期範圍、空值／數量、地理矩形／半徑過濾，可用於
  Mojo／Python／Arrow 搜尋、現有 HTTP 與條件式 payload 更新。
  10,781 組來源案例、101 項原生與完整 Python 3,188 項通過，1 項既有跳過。
  [驗證與範圍](docs/research/2026-10-30-payload-filter-validation.md)。
  polygon 已由後續 D03e 補入；專用日期／地理／巢狀／全文索引、剩餘條件、rich Arrow；
  LanceDB、SQL／交易、UI／安全／叢集與全產品清單仍未完成，尚未進入優化。
- Q04f／D03c：Qdrant／chrono 日期解析、微秒時間戳及日期常數／payload
  日期公式已接入 Mojo／Python／Arrow，保留時區、負年份、閏秒與來源格式行為。
  20,861 組日期、315 組時間戳、3,624 組公式對照，21 項原生、1,013 項指定
  Python 與完整 Python 3,172 項通過，1 項跳過。
  [驗證與範圍](docs/research/2026-10-30-datetime-validation.md)。
  日期範圍、地理矩形／半徑與巢狀條件由後續 D03d 補入；專用索引與其餘完整
  產品待辦見最新進度，LanceDB、SQL／交易、UI／安全／叢集仍未完成。
- Q04e／D03b：Qdrant 座標驗證及固定 GeoRust 來源的地理距離已接入
  Mojo／Python／Arrow 公式，可組合路徑、預設值與衰減。30 組座標驗證、
  796 組距離、1,064 組公式來源對照，16 項原生、979 項指定 Python 與
  完整 Python 3,138 項通過，1 項跳過。
  [驗證與範圍](docs/research/2026-10-30-geo-formula-validation.md)。
  日期型別／公式已由後續 Q04f 補入，其餘待辦見最新進度與完整清單。
- Q04d：巢狀／陣列路徑、來源單層攤平、缺值與 null 區分、UInt64 與
  JSON 預設值已接上 Mojo／Python／Arrow 公式查詢。1,068 組原始來源案例、
  12 項原生、933 項指定 Python 與完整 Python 3,092 項通過，1 項選配跳過。
  [驗證與範圍](docs/research/2026-10-30-formula-payload-validation.md)。
  地理公式已由後續 Q04e 補入，其餘待辦見最新進度與完整清單。
- D05a：payload set／overwrite／delete／clear 已接上 Mojo／Python／現有 HTTP，
  支援 IDs／既有條件選取與 JSON 路徑，保留所有向量；同一寫入鎖內選取與原子提交。
  1,644 組來源對照、3 項原生、完整 Python 3,078 項通過，1 項選配跳過；
  18 項新增公開 API 測試涵蓋恢復、快照、限制與轉換重入。
  [驗證與語義邊界](docs/research/2026-10-30-payload-mutations-validation.md)。
  rich Arrow、任意頂層鍵、巢狀／日期／地理索引、混合批次與完整產品清單仍未完成。
- D01b：物件／陣列／null／UInt64 已接上原生持久化、Python、現有 HTTP、
  備份與 NDJSON v2，保留 payload v1 讀取與原子遷移。依 Qdrant 原始碼移植
  owned-value 路徑 get/set/remove/merge 與單層陣列／null 條件行為。
  2,088 組值操作、110 組條件來源對照，27 模組／171 項原生測試、完整 Python
  3,060 項通過，1 項選配跳過；9 個 crash 模組／24 項及 C ABI 也通過。
  [驗證與剩餘範圍](docs/research/2026-10-30-rich-payload-validation.md)。
  collection 路徑更新與巢狀數值公式已由 D05a／Q04d 補入；rich Arrow、
  日期／地理公式由後續 Q04e/Q04f 補入；巢狀索引與完整協定仍待完成；
  LanceDB 歷史版本／格式、SQL／交易、UI／安全／叢集等完整清單仍開放。
- [功能差異報告](docs/research/2026-10-30-product-capability-report.md)
- [完整任務清單與驗收](docs/plans/2026-10-30-feature-completion.md)
- [第一批：Qdrant DBSF 移植](docs/plans/2026-10-30-dbsf-source-port.md)
- 已固定 7 份來源與 69 個 Qdrant REST 待驗收操作。DBSF 已移植並接上 Mojo／Python／Arrow；
  114 組上游 fixture、15 項原生案例與 254 項 Python 案例通過。
  [驗證紀錄](docs/research/2026-10-30-dbsf-validation.md)。
- Q01b weighted RRF 已依上游 position_score／rrf_scoring 移植並接上 Mojo／Python／Arrow；
  300 組位置計分、50 組融合參考案例，19 項原生與 315 項不同 Python 案例通過。
  [驗證紀錄](docs/research/2026-10-30-weighted-rrf-validation.md)。Q01 的完整協定暴露仍待完成。
- Q02a 查詢既有點 ID、來源 collection／欄位 lookup 與候選前 ID 排除已接上
  Mojo／Python／Arrow；52 組上游參考、18 項原生與 410 項不同 Python 案例通過。
  [驗證紀錄](docs/research/2026-10-30-point-query-validation.md)。目前沿用原生同型別查詢契約。
- 推薦系列：[Q02b 三種推薦策略](docs/plans/2026-10-30-recommendation-source-port.md)。
  Q02 與完整協定相容仍未完成。
- Q02b 三種推薦的 exact 路徑已接上 Mojo／Python／Arrow；包含混合 ID／向量、
  lookup／排除、篩選與來源前處理。336 組 F32 上游查詢與 24 組 reducer fixture 已建立。
  [驗證與限制](docs/research/2026-10-30-recommendation-validation.md)。接續完成各索引的 ANN scorer、
  完整 F16/U8 oracle、低精度 canonical storage 審核與協定暴露；Q02 尚未完成。
- Q02c dense HNSW 推薦已使用真正的 composite scorer 遍歷，並接上 Mojo／Python／Arrow。
  [ANN 驗證與召回限制](docs/research/2026-10-30-recommendation-ann-validation.md)。
  重複向量的召回缺口保留；sparse／multivector 索引推薦、型別／儲存及協定驗收仍待完成。
- Q02d 稀疏推薦已接上來源的 plain／批次索引路徑，自訂 best/sum 採來源的完整計分。
  138 組上游對照、6 項原生與 1094 項不同 Python 案例通過。
  [零分規則更正與驗證](docs/research/2026-10-30-sparse-recommendation-validation.md)。
  稀疏推薦 exact／approx 已統一依來源分派；舊 native nearest 契約的完整遷移、
  稀疏設定／IDF、multivector HNSW、
  型別／儲存與協定工作仍未完成。
- Q02e 一般稀疏查詢已共用來源搜尋核心：命名／預設、point lookup、hybrid、
  candidate rerank、PointStore 與可變索引；移除舊評分與重複 run 索引。
  214 組上游 fixture、87 項原生與 1693 項不同 Python 案例及 C ABI 檢查通過；
  含 168 個新增 Python 案例，1 個選配 Qdrant Edge 案例跳過。
  [共用稀疏驗證](docs/research/2026-10-30-sparse-nearest-validation.md)。
- M5/M6 保留未達標，功能驗收完成前不恢復效能實驗；原生 Linux 驗收仍依先前指示暫緩。
- Q03a MMR 多樣性選擇已接上命名／ID nearest 的 Mojo、Python、Arrow；
  192 組選擇與 112 組向量來源案例、26 項原生、1743 項不同 Python 案例通過；
  1 項選配 Qdrant Edge 跳過。最後參數修正另通過 50 項 MMR 與 521 項查詢回歸。
  [MMR 驗證與範圍](docs/research/2026-10-30-mmr-validation.md)。
  探索／context、nested prefetch 與完整協定等缺口仍保留。
- Q03b discovery/context 已接上 Mojo／Python／Arrow：exact dense/sparse/MaxSim、
  dense 兩階段 HNSW、context-only、自訂入口、raw／ID／lookup／排除／snapshot。
  336 組來源案例、42 項原生與完整 Python 2005 項通過，1 項選配 Qdrant Edge 跳過；
  含 262 項新增 Python 案例。來源對照修正了 signed-zero 造成的排名差異。
  [discovery 計畫](docs/plans/2026-10-30-discovery-source-port.md)／
  [驗證與限制](docs/research/2026-10-30-discovery-validation.md)。
  接續 Q04 universal／nested prefetch 與 Q03 完整整合；batch／offset／projection、
  multivector HNSW、datatype／storage、完整協定及其餘產品功能仍列為未完成。

- Q04a 通用查詢樹已接上 Mojo／Python／Arrow：nested prefetch、候選聯集重排、
  來源 filter／全域 ID 排除、融合、root／nested／leaf MMR、offset 與 ID 順序查詢。
  103 組上游 planner 案例、14 項原生及完整 Python 2115 項通過，1 項選配跳過；
  含 110 項新增 Python 案例。[驗證與限制](docs/research/2026-10-30-universal-query-validation.md)。
  Q04 公式／抽樣／feedback、Q05 完整讀取操作、rich payload 與其餘產品功能仍待完成；
  所有功能完成前不恢復效能調校。

- Q04b 數值公式已接上 Mojo／Python／Arrow：來源 F32/F64 運算、短路、預設值、
  純量條件與三種衰減函數，對同一快照的 prefetch 候選聯集重排。
  309 組來源案例（57 組預期錯誤）、9 項相關原生測試與完整 Python
  2461 項通過，1 項選配跳過；包含 346 項新增公式案例。
  [驗證與限制](docs/research/2026-10-30-formula-validation.md)。
  完整 JSON-path／日期／地理／rich defaults 仍待 D01/D03；Q04 抽樣／feedback
  及其餘完整產品範圍持續保留。所有功能完成前不做效能優化。

- D01a／Q04c 共用 JSON-path 已依來源移植：完整語法、路徑操作、Unicode 17
  分類、引號字面欄位及 UInt64 分數索引，並取代公式暫用名稱解析器。
  548 組來源輸入、81 組操作、Unicode 全範圍分類與 8 項原生測試通過；
  完整 Python 3034 項通過、1 項選配跳過，含 573 項新增路徑案例。
  [驗證與限制](docs/research/2026-10-30-json-path-validation.md)。
  下一個資料層工作為 rich payload 的物件／陣列／null、持久格式遷移與恢復；
  完整產品與既有品質／效能缺口仍保留，尚未開始效能調校。

以下為先前工作與效能歷史，原失敗、參數例外及封存候選全部保留。

**2026-10-23 使用者暫停效能優化，改為合併分支與清理。**
目前僅保留本機 `main` 分支與主工作樹；下方「下一步」與舊路徑是歷史紀錄，暫不執行。
M5/M6 尚未達標，原生 Linux x86_64 驗收仍依指示暫緩。
最後未提交原型與原主工作樹研究檔已封存，見 [暫停工作快照](docs/research/2026-10-23-paused-work-snapshot.md)。

更新：2026-10-23。**整體工作尚未完成**，M5/M6 效能矩陣仍未達標。
以下為暫停前 `feat/qdrant-alignment` 的工作紀錄；使用者核准僅將 Qdrant 的
real-1536／correlated ef 改為 128，並暫緩原生 Linux x86_64 驗收。
最新九組固定圖計分量診斷完成：扣除 base 分數重用，real correlated 仍多算約 33%，
real independent 多約 11%。54 workers／24,120 筆引擎回應完整留存並核對；
4,824 個 Qdrant exact 計數控制通過。現有熱點已用 NEON FMA；下一步針對
real independent 每次 128 個重複 delta 計分擴充分數證明。correlated 的 delta
已只算一次，需另行處理遍歷成本。本輪沒有引擎優化或速度驗收，所有失敗仍保留。
[最新計分量與機器碼證據](docs/research/2026-10-23-immutable-point-work-audit.md)。
最新 List.shrink 實驗未採用：同批完整 mixed 29 → 32／36，無 pass→fail；
完整 warm 11 → 10／36，兩格改善、三格 selective 退步。135 項相關測試及
124,416 筆量測回應通過。完整 driver 的 GC 診斷另核對 12,288 筆，發現雙方
相同查詢的回收尖峰，但 p95 查詢沒有 GC，仍不能解釋正式失敗。四次原生取樣與
九份圖檔對齊檢查已封存；正式引擎與下述 weak-certificate 保留候選均不變。
[最新取樣、實驗與完整證據](docs/research/2026-10-23-immutable-point-list-shrink.md)。
最新 immutable-value 分數證明候選：同批完整 mixed 保留版本 24 → 候選 28／36，
無 pass→fail；完整固定圖 warm 12 → 12／36，一格改善、一格 selective 退步。
品質皆 36／36，mixed write＋flush 皆 9／9。135 項相關案例通過，84 workers／
124,416 筆量測回應保持 IDs／F32 bits／stats／路徑一致。利用標準庫 WeakPointer
驗證相同不可變 owner，安全重用已證明相等的 F32 Dot/L2 圖分數；不延長映射檔壽命。
保留此隔離候選；正式 `src` 不變，real correlated、低維 selective 與其他未達標項目
仍需處理。[最新實作與完整證據](docs/research/2026-10-23-immutable-point-score-certificate.md)。
後續 selective 診斷：8 workers／8,192 筆量測，在 ANN 前後均未重現一致退步；
個別退步與正式失敗仍保留。此診斷未重現完整 driver 的逐格報表序列化，原因尚未
確定，不改引擎或驗收結果。[完整補充診斷](docs/research/2026-10-23-immutable-point-certificate-selective.md)。
前次診斷排除兩條路徑：逐 byte 核對後重用分數耗時為重算的 1.38–1.68 倍；
paired SIMD 範圍檢查簡化在 1536 維沒有穩定收益。22 項相關案例通過，
原始量測與失敗紀錄已封存，兩者皆未採用，正式及保留候選不變。
[診斷與決策](docs/research/2026-10-23-immutable-point-score-reuse-proof.md)。
前一版同步鄰接遍歷候選：同批完整 mixed 保留版本 21 → 候選 26／36，無 pass→fail；
完整固定圖 warm 11 → 12／36，含一個 selective exact pass→fail。品質皆 36／36，
mixed write＋flush 皆 9／9。104 項相關測試、98 組搜尋與 24 組建圖 oracle 通過。
96 workers／127,488 筆量測回應保持預期結果、F32 bits、stats 與路徑一致。
保留隔離候選繼續診斷，正式 `src` 不變；外部客戶端、容量與整體驗收仍待完成。
[最新實作、全部對照與證據](docs/research/2026-10-23-immutable-point-neighbor-gather.md)。
前一版完整客戶端矩陣為 1 client 8／36、4 clients 12／36；不能當成新候選驗收。

2026-10-13 歷史紀錄：在 `main` 的 `a710aa5` 上繼續 profiling，發現並修正 maintenance deadlock
（`be3be53`）。前次 Git 交付的 push／merge 紀錄屬於 10/02，不能視為本次已 push。

## 最新修復（2026-10-04）：Python 回傳容器參照釋放

1. [Mapped descriptor 與 8,192 列控制](docs/research/2026-10-13-mapped-hot-descriptor.md)、
   [Mapped SIMD prefix](docs/research/2026-10-13-mapped-kernel-prefix.md)、
   [Mapped exact 原生取樣](docs/research/2026-10-13-mapped-native-sample.md)、
   [Query-level metric／width 分派](docs/research/2026-10-13-mapped-query-dispatch.md)、
   [Exact 欄位位置重用](docs/research/2026-10-13-mapped-exact-field-lookup.md)、
   [Kernel reader factory 內聯](docs/research/2026-10-13-mapped-kernel-inline.md)、
   [Mapped reader 後續效能實驗](docs/research/2026-10-13-mapped-reader-followups.md)、
   [Mapped owner 容量與暖查詢](docs/research/2026-10-13-mapped-numeric-owner.md)、
   [Numeric reader 三版實驗](docs/research/2026-10-13-numeric-read-view.md)、
   [Mapped numeric 所有權實作計畫](docs/plans/2026-10-13-mapped-numeric-ownership.md)、
   [F32 compiler proof](docs/research/2026-10-13-mapped-list-probe.md)、
   [Open 記憶體分段診斷](docs/benchmarks/2026-10-13-open-memory-phases.md)、
   [未採用 visit 參數縮減](docs/benchmarks/2026-10-13-visit-args-port.md)、
   [Filtered HNSW live radius 修正](docs/benchmarks/2026-10-13-live-radius-port.md)、
   [Compaction 鎖外回收](docs/benchmarks/2026-10-13-unlocked-reclaim-port.md)、
   [篩選 exact 雙候選移植](docs/benchmarks/2026-10-13-paired-exact-port.md)、
   [四候選 HNSW 移植與配對驗證](docs/benchmarks/2026-10-13-four-neighbor-port.md)、
   [三資料集受控記憶體矩陣](docs/benchmarks/2026-10-13-memory-cap-matrix.md) 與
   [mapped segment 恢復修正](docs/benchmarks/2026-10-13-mapped-segment-read.md)
2. [本次修正、驗證與 mixed 原始結果](docs/research/2026-10-12-maintenance-shared-state.md)
3. [本次 profiling、暖查詢與未採用原型](docs/benchmarks/2026-10-12-mapped-probes.md)
4. [外部並行客戶端矩陣](docs/benchmarks/2026-10-13-concurrent-clients.md)
5. [Linux runtime／Metal device 驗證](docs/research/2026-10-13-linux-gpu-validation.md)
6. [前次交接狀態、測試證據與重現指令](docs/handoff/2026-10-02-status-and-tests.md)
7. [前次 Git 交付紀錄](docs/handoff/2026-10-02-git-delivery.md)
8. [唯一工作項目 checklist](tasks/todo.md) 與 [驗收計畫](tasks/plan.md)

新增 24 cases：修正 fixture/assertion 後基線 23 failed／1 passed，候選全通過；
**595 完整隔離 Python／147 正式 targeted** 通過，重複不加總。第一版失敗全部保留。
原矩陣 warm21→24/36、mixed21→20/36、write+flush3→3/9；recall各36/36，
四個performance pass→fail保留，**整體FAILED，M5/M6未完成**。
Named 14,472 pairs IDs/F64 bits/stats一致、品質132/216；25/36選定格timing退步。
[完整實作、全部失敗與凍結證據](docs/benchmarks/2026-10-04-output-list-refs.md)。正式kernel SHA-256：
`0088e118e5723f9a30cdef9c5a99ac3b3d6503fe4c67b09afb50ba4ef76b6c1c`。

Named/native vector 的遷移、原子提交、查詢、Python／Arrow、F16／BF16／I8／U8、
Binary／MaxSim、NDJSON 已串接並驗證；retained base／delta cache 已改善更新後重開。
前次已採用 exact scan query preparation；詳細數據見
[最新量測報告](docs/benchmarks/2026-10-02-prepared-exact.md)。

本次 maintenance 修正：44 項相關 Mojo 通過；完整 Python 351 passed／1 skipped，
跳過的 Qdrant adapter 使用既有 pinned 套件補跑 1 passed。本機 distributed suite
在修正前的重建 baseline 通過 10 項。前次完整 CPU／crash／C ABI 結果見歷史報告；
這些不同範圍的驗證不能加總為新一輪完整整合。

已補齊指定 Linux x86-64 runtime 測試（Docker 模擬執行）：45 個不同 Mojo 案例、
350 個不同 Python 案例與 C ABI 通過，保留環境失敗及補跑紀錄；完整 native Linux
CI 仍未驗證。Metal snapshot／cache 9 項通過，含實機路徑與故障 fallback。

外部客戶端採用雙方相同 HTTP shim 與單一 engine handle：1 client 控制組 21/36、
4 clients 14/36 達速度門檻，72 格配對品質皆通過。此為獨立服務邊界，不能與
binding-only 矩陣合併；完整結果仍為 FAILED。相關 19 項 Python 測試通過。

[首輪受控記憶體診斷](docs/benchmarks/2026-10-13-memory-cap-probe.md) 的 open OOM
促成 [mapped segment 讀取修正](docs/benchmarks/2026-10-13-mapped-segment-read.md)：
移除整份 encoded segment 副本，real-1536 現在可於 224／192 MiB 下完成恢復與查詢；
128 MiB 仍 OOM。192 MiB 的三個 ANN 模式具持續非駐留證據，selective exact 不具此證據。
完整暖查詢前後品質皆 36/36、速度皆 16/36；包含退步格，不宣稱查詢速度改善。
相關驗證為 105 Mojo、23 crash、完整 Python 355 項加 1 項新編譯檢查，以及 C ABI；
Linux 原型另有 22 targeted Mojo 通過。這些診斷仍不代表全效能矩陣通過。

三資料集受控記憶體矩陣已執行完成：128／192／256 MiB 各三次對照，54 個受限
worker 中 48 完成、6 次 Akasha 初始化 OOM，無逾時；配對品質 84/108、速度
57/108，整體 FAILED。另有 6 個 6 GiB 控制 worker。所有完成者共 14,472 exact
checks／110,592 timed response checks 通過。Akasha 9 格、Qdrant 28 格各自具
持續壓力證據，但同一 cap／trial 雙方皆符合者為 0/108；owned exact 向量仍無
非駐留證據。這是 emulated Linux 結果，不能列為 native Linux performance。

未完成：M5/M6 逐格速度與記憶體容量門檻、雙方持續 non-resident 對照，以及尚未
執行的環境／整合 gate。Qdrant 門檻已定案：相同 recall 下，
**每格 QPS ≥ Qdrant 且 p95 ≤ Qdrant**，不能跨格抵銷。

先採用既有 `c00494f` 的四候選 F32 HNSW 實作，只移植三個來源檔與兩個測試。
同批暖查詢速度 16/36 → 19/36、mixed 15/36 → 19/36，前後品質皆 36/36，無
通過轉失敗格；real-1536 九格暖 ANN QPS 提高 21.6–40.1%、p95 皆降低。
所有 exact 波動、mixed selective 尾延遲退步均保留；write + flush 仍僅 3/9。
97 Mojo、完整 Python 356、C ABI、三個範例通過；Linux 模擬另通過 31 Mojo。
此結果不能與其他批次直接計算效能差值，完整 M5/M6 仍 FAILED。

後續移植既有 `a57f11a` 的 filtered exact 雙候選計分。該批暖查詢速度
19/36 → 24/36，mixed 17/36 → 17/36，前後品質皆 36/36；mixed 有 3 格
通過轉失敗，已完整保留，未用其他格改善抵銷。uniform-1536 correlated／independent
的 12 格暖／mixed QPS 均改善；real selective 三次 mixed QPS 與 p95 皆改善。
66 Mojo、完整 Python 359、C ABI、三個範例與 Linux 模擬 14 Mojo 通過。
此為局部改善，mixed 尾延遲、ANN 差距與整體 M5/M6 仍未完成。

接著移植 `7dd8647` 的 compaction 鎖外回收，保留本輪 shared-state `Pointer`
修正。新同批暖查詢速度 23/36 → 25/36、mixed 17/36 → 28/36，前後品質皆
36/36；兩組各有 1 格通過轉失敗，已保留，write + flush 仍僅 3/9。
103 項不同 Mojo、23 crash、完整 Python 359、C ABI、三個範例，以及 Linux
模擬 13 Mojo 通過。原版 blocked reclaim 阻止 close 前進的案例已修正，source
owner 仍保護新 writer 排他；ADR 已更新。M5/M6 每格速度與容量門檻仍未達標。

最新移植 `cc15f37` 的 filtered HNSW live-radius 正確性修正：inactive 節點
仍可當通路，但不占 retained radius。三個漏查 regression 已在 generic／專用
F32 L2 通過；共 100 Mojo、完整 Python 359、C ABI、三個範例與 Linux 模擬
25 Mojo 通過。同批暖速度 23/36 → 22/36、mixed 24/36 → 26/36，品質皆 36/36，
兩組各有 1 格通過轉失敗，write + flush 仍 3/9；採用不代表速度改善。
配對 IDs／score bits 相同，mixed 120 組 traversal stats 差異完整保留。
整體 M5/M6 仍 FAILED。

後續試移植 `8ba04ce` 的 visit 參數縮減，**本輪未採用**。候選 107 Mojo／
359 Python 通過，編譯產物縮小且配對行為相同，但同批暖速度 21/36 → 19/36、
mixed 23/36 → 18/36，共 7 格 pass→fail。Real ANN QPS 雖在 15/18 格改善，
收益仍不足以支持採用；全部原始結果保存。正式引擎仍為 `6d01819`，未以候選
取代正式 binary，亦未把未執行的 Linux／C／範例準備列為成功。

最新完成七個隔離 open-memory diagnostics：五個成功、兩個高維 128 MiB OOM，
失敗縮小到第二個 segment 的讀取／解碼區間。五個成功者通過 1,340 exact checks
與 1,340 ANN／planned-exact audits；未量測效能。Real-1536 的 6 GiB 控制組
recovery 後約 134 MiB anonymous，HNSW 後約 155 MiB，open 後約 163 MiB；
這是包含 Python／allocator／QEMU 的程序用量，不是純引擎配置。持續持有量仍需
處理，不能只縮減解碼峰值就宣稱修復容量。正式 source／binary 未改。

工作目錄：`/Users/ray/Projects/Akasha`，分支 `main`。
`.build/m5-resume/` 保留重建資料庫、隔離 binary 與所有實驗。
本檔僅作入口，不另設與 `tasks/todo.md` 重複的 checklist。
