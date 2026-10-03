# Named HNSW 的 retained-base／delta 接合

M5/M6 仍未完成。正式 source 保持 `cc15f37`；本方案接續
[既有 primitives 成本探針](../benchmarks/2026-10-04-named-overlay-cost.md)，
已完成 [隔離實作與驗證](../benchmarks/2026-10-04-named-overlay.md)，**未採用**：
單次高維首查改善，但 3/4 選定暖格退步。空 delta 以零長度省略，保留 graph
allocation guard；全部失敗與修復證據已凍結。以下為該候選的設計，所有原需求、
固定矩陣與既有授權持續適用。

## 選擇與限制

採用現有 `SegmentedHnsw` 作下一個隔離候選。初始 named run 建出普通 HNSW 後，
成為 immutable owned base；變更向量只進 delta，source map 抑制 stale base 結果。
保留原 rebuild thresholds，達到原門檻時仍依目前 cache-miss/full-build 路徑重建。
這不新增公開設定、背景排程器或第三套 graph 演算法。

替代方案的實測：完整重建冷成本仍高；append reconciliation 暖查詢有退步；
逐點一／二跳修復雖減少 slots，首查變成 53.58 秒。現有 base／delta primitives
將原更新成本降至約 1.33 秒，值得先接合驗證，但總 physical slots 沒有減少，
暖效能與 recall 是必須實測的風險。

## 最小接合順序

1. **保留候選 graph score。** 在既有 segmented collectors 增加編譯期選定的 scored
   輸出，既有 default caller 保留 ID-only specialization。兩種輸出共用同一次搜尋、
   順序、source admission 與 widening，不重新算候選距離。新增窄 boundary 供 named
   caller 使用；不改 default native-F32 rerank 或其既有候選 union 契約。
2. **Named 使用既有 segmented graph。** `FieldHnswIndex` 持有 segmented owner 與
   current native rows／ID→ordinal domain。Filter／shadowing 以既有 `HnswEligibility`
   按 public ID 處理，不能把 native row ordinal 當 base/delta slot。各 run 回傳 scored
   candidates 後，維持原全域 `max(k, ef)`／explicit rerank budget，再做原 native F64
   rerank；不得把兩個 sources 的 union 全部 rerank，藉此擴大召回預算。
3. **一個原子 optional cache envelope。** 在現有 AKIC 新 kind 內保存獨立 field
   identity、base snapshot 與可選 delta snapshot；兩個 blobs 綁同一 envelope／CRC，
   不新增 authority schema 或獨立檔案發布競態。未認得的舊 optional cache 是 miss。
   保留現有 read-only query、writer/query lock、busy skip、tmp/fsync/rename 發布規則。
4. **從 authority 重建 source map。** 完整核對 field ID/name/native scalar/metric/
   graph config；依目前 live field rows、prepared-vector bits／I8 scale，決定目前
   ID 來自 base 或 delta。缺值／刪除不得留在 current sources；新增／修改才進 delta。
   Saved delta 可含歷史 slots，僅採用匹配目前 authority 的 current slots，其餘刪除或
   upsert。驗證 source counts、全部 current native coverage 與圖結構後才發布。
   Exact source-checksum 命中但 graph/vector 不符仍為 miss，不能悄悄修正 malformed hit。
5. **保存完整已驗證狀態。** 在 ready-base 帶 later run/head 的既有隔離 publication
   改動上接合上述 envelope；重新開啟同一 authority 應直接採用完整 base/delta。
   舊 snapshot／Arrow lease 繼續擁有原 artifact；不在共享已發布 graph 上 mutation。

每個步驟在複製 source／binding 的隔離目錄完成；原 point-refresh sources、binary、
失敗 logs 與 frozen archives 不修改。只將通過完整相關 gates 的最終候選帶回正式樹。

## 驗證與停止條件

先測 scored boundary 的 owned/mapped、base-only/delta-only/mixed、filter、負 ID/
ties、quantized graph scalar；ID 次序／stats 必須與原 ID-only 搜尋相符，score 必須
來自原 graph metric。Default 原結果 bits／budget／準備次數不變。

接著驗證 named/native 全 codec 組合、missing field、replace/delete/reinsert、同 ID
跨 source shadowing、舊 snapshot、cancel/deadline、busy／failure retry、rebuild
threshold、cache corruption／wrong identity／torn publish 與兩次 reopen。保留原小
候選集的 recall failures，不用 exact fallback 把 ANN-only gate 掩蓋。

整合後先跑最窄 Mojo，再完整 saved-package Python、相關 crash/C/examples；compiler
與 import/hash guards 依 task.md。先做一個完整原高維 curve 的成本/品質診斷；若不
通過就保留失敗並停止擴大。若有實測依據，再跑全部原三 corpus／三 trial named
生命週期及受影響的三方 default gates。第一查詢變快或三次 primitive probe 都不能
替代每格 QPS/p95／recall 門檻，也不能算 Linux/nonresident 已完成。
