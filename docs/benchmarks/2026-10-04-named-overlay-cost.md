# Named lifecycle：既有 retained-base／delta 成本探針

[Private point-refresh 未採用](2026-10-04-cache-point-refresh.md)後，先使用現行
`cc15f37` 的 `SegmentedHnsw` 量測建置 primitives，**沒有修改引擎或接合 named query**。
相同初始 graph、819 updates／205 deletes，三次 append 更新為 4.42–4.46 秒，
segmented delta 更新為 1.33–1.34 秒。這支持接續隔離整合，但不代表 M5/M6 達標。

## 固定輸入與驗證

使用原 uniform-1536 corpus／seed=12345、F32 Dot、m=24、m0=48、construction ef=192，
8,192 初始點及原更新／刪除。起始 graph 取自上一實驗 profile 在首次 repair 前
保留的 `pre-repair.cache`；驗證外層 AKIC 與內層 AKHG CRC 後取出同一 graph。
對照完整 append graph 取自該實驗未 profile 的 `before` worker。

六次執行順序為 A/B、B/A、A/B，沒有 build/test／壓縮重疊。每次都重新 decode
相同 snapshot，不重新建初始圖。解碼、採用 base、更新與驗證分開計時；更新時間
只含原 delete／upsert primitives，**未包含 named source checksum、全量向量比對、
公開開庫／query／傳輸**。因此不能直接把它當成 public cold-open 改善倍數。

每次結束驗證所有 7,987 個 current IDs／vectors 的逐 component F32 bits、205 個
刪除，以及圖結構。合計 47,922 個 current-vector audits／73,608,192 個 component
bit checks／1,230 個 deletion checks。三個 append 圖都與先前完整生命週期的 graph
**逐 byte 相同**；三個 segmented base 也與輸入 snapshot **逐 byte 相同**。
這些是探針內 assertions，不計入 Mojo unit-test 數。

## 各次結果

| Variant | Trial | Decode ms | Adopt ms | Updates/deletes ms | Audit ms | Build distance evaluations |
|---|---:|---:|---:|---:|---:|---:|
| append | 0 | 132.825 | 0 | 4423.335 | 77.544 | 30,917,040 |
| segmented | 0 | 118.989 | 43.992 | 1325.355 | 79.561 | 9,577,325 |
| segmented | 1 | 116.489 | 38.005 | 1334.382 | 78.754 | 9,577,325 |
| append | 1 | 119.096 | 0 | 4432.729 | 77.899 | 30,917,040 |
| append | 2 | 117.345 | 0 | 4456.138 | 78.953 | 30,917,040 |
| segmented | 2 | 117.543 | 38.925 | 1343.941 | 78.940 | 9,577,325 |

兩者總 physical slots 都是 9,011、inactive/stale 共 1,024。Segmented 的優點在
819-point delta 的建置量，**並沒有消除歷史向量或證明暖查詢更快**。無 query／recall
結果，也沒有 Qdrant、HTTP、memory-limit、Linux 或 GPU gate。

## 現有 API 與參考查核

`SegmentedHnsw.from_owned`／`upsert`／source admission 已具備 immutable base 與
有界 delta；現有 `restore_hnsw_overlay` 綁 default dense／document sequence，不能
直接套用 named field presence 與 native vectors。其 collector 回傳 ID union，最多
是每 source 的 ef；named 路徑則先依 graph score 做一次全域 budget，再做 native
F64 rerank。直接換呼叫會改變已定案的候選預算，必須先補 scored-candidate 輸出。

本機 Qdrant reference commit `74f3e85b9473c62560006c043e13737ce6b48412` 的
`hnsw/old_index.rs` 以 ID/version 映射可重用的點；`graph_layers_healer.rs` 找 deleted
子圖邊界作 shortcut，再插入 changed/new points。其 adjacency 契約與 Akasha 的
強制 reciprocal bounded links 不同，這次沒有移植。查核來源 SHA 在 `research.json`。

接續方案見 [named retained-base／delta 設計](../plans/2026-10-04-named-overlay-design.md)。
不修改固定 recall／ef／budget，也不因這個建置微量測就採用新架構。

## 證據與重現

OUT：`.build/2026-10-04-named-overlay-cost`，Mojo 1.0.0 (`ed45d567`)／Apple M4／Metal:4。
`probe.mojo` 編譯成功；六次 native runs 完整通過，正式 source 與 Python binary 未改。
沿用原 production validation；沒有宣稱本探針重跑 Python、C ABI 或完整 Mojo/crash。

[Frozen text archive](results/2026-10-04-named-overlay-cost.json.gz)：259,789 bytes／
130 entries，gzip 與逐 entry SHA 已核對。SHA-256：
`994d81ccc7e94971be1ea593991fdc7dd13c87c57ffa75e207e239d1f6f2a7b1`。
包含 probe、原 source、完整命令、六次 CSV、輸入 hashes 與研究結果；binary、database
與 corpus 不在 text archive。輸入圖可依上一報告的固定流程重建，必須核對 hash。

現有隔離輸入可單獨重現此探針（輸出至 terminal，不覆寫凍結樣本）：

```sh
rtk proxy .build/2026-10-04-named-overlay-cost/probe
```

重新編譯的完整 wrapper PATH／flags 見 `build.json`，執行的 binary／source hash
見 `run.json`。禁止與其他 build/test/benchmark／壓縮重疊。
