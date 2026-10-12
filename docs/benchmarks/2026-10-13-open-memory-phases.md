# Open 階段記憶體：第二個 segment 與持續 anonymous 用量

在正式 `6d01819` 引擎上加入隔離觀測點，七個串行診斷 中五個成功、
兩個 128 MiB 高維 worker OOM。兩者都已完成第一個 segment 的 decode/apply，
進入第二個 segment，最後留下 `segment.decode_row.0`，尚未回到
`recovery.after_segment_decode.1`。因此將原矩陣的「open 尚未完成」縮小到
第二個 segment 讀取／解碼區間；仍不能指出是哪一個 allocation 被拒絕。

成功控制組顯示，解碼之後還有 HNSW／metadata 的 anonymous 用量增加。
僅改成 streaming decode 不能據此宣稱解決 128 MiB 容量或 non-resident exact。
**正式來源及 binary 未改，M5/M6 仍 FAILED。** 此報告不是效能驗收。

## 方法與結果

以 `4c13932` 的完整 source（引擎仍 `6d01819`）及完整 Python package 建置
診斷 library，121 個 Mojo 檔案包含一個 private observer helper。三個 production
來源的複本加入 phase calls：collection open、legacy recovery、segment decoder。
每 1024 筆 segment record 觀測一次。正式 source、Python／C library 未覆寫。

使用既有 pinned Linux x86-64 Docker image，於 ARM Mac 模擬執行；每 worker
一 CPU、零 swap，cap 見下表。編譯容器停止後才執行七個診斷 worker，全部串行。
每次在 owned Linux volume 複製到新 inode，fsync／FADV_DONTNEED 一次，所有
initial vector-file mincore 為 0；查詢期間沒有 cache eviction。固定 query JSON、
oracle、ef、fixture 及 service boundary 沿用
[已完成記憶體矩陣](2026-10-13-memory-cap-matrix.md)，未重跑整個矩陣。

| Corpus | Cap MiB | 結果 | 最後觀測 |
|---|---:|---|---|
| real-1536 | 6144 | 完成，四模式品質通過 | worker.after_close |
| real-1536 | 192 | 完成，四模式品質通過 | worker.after_close |
| real-1536 | 128 | OOM／exit 137 | segment.decode_row.0 |
| uniform-1536 | 6144 | 完成，四模式品質通過 | worker.after_close |
| uniform-1536 | 192 | 完成，四模式品質通過 | worker.after_close |
| uniform-1536 | 128 | OOM／exit 137 | segment.decode_row.0 |
| uniform-128 | 128 | 完成，四模式品質通過 | worker.after_close |

五個成功 worker 共 **1,340 exact checks 與 1,340 ANN／planned-exact audits**，
所有 20 個品質 cells 通過。這些是固定 67 queries × 4 modes 的診斷重播，
不是新的獨立品質樣本。沒有 timed passes，也沒有採用診斷時間作 QPS／p95 結論。
兩個 partial reports 保持 `initializing`，Docker 的 `OOMKilled=true` 及 exit 137
是權威失敗紀錄；SIGKILL 無法執行 Python cleanup。所有失敗與完整 traces 保留。

每個觀測點 fsync 一筆 JSONL，包含 `/proc/self/status`、`smaps_rollup`、
resource faults／peak、cgroup current／peak／stat／events／pressure。觀測本身會
配置記憶體及做 I/O，可能移動 OOM 邊界；先前未插樁矩陣已獨立重現同一組
128 MiB 高維 OOM，這次用來定位區間，不能將 observer 視為零成本。

## 程序用量與推論限制

以下數字是 `RssAnon` MiB，包含 Python、allocator retention、QEMU 與引擎。
不是每個 owner 的 allocation census，也不能把 phase 差額全歸為 dense vectors。

| Corpus / cap | Before open | Recovery 後 | HNSW 後 | Metadata 後 | Open 完成 | Preflight 後 |
|---|---:|---:|---:|---:|---:|---:|
| real-1536/6144 | 67.87 | 134.39 | 154.55 | 162.56 | 162.62 | 177.54 |
| real-1536/192 | 67.86 | 131.10 | 151.61 | 157.88 | 157.94 | 166.88 |
| uniform-1536/6144 | 67.69 | 134.18 | 154.38 | 162.39 | 162.45 | 175.38 |
| uniform-1536/192 | 67.69 | 130.91 | 151.84 | 157.99 | 158.05 | 166.79 |
| uniform-128/128 | 52.92 | 68.05 | 72.50 | 87.64 | 87.70 | 97.33 |

Real-1536 的 6 GiB 控制組在載入 query input 前約 39.43 MiB anon，之後
54.52 MiB，載入 native module 後／呼叫 open 前 67.87 MiB。Recovery 後
134.39 MiB、HNSW 後 154.55 MiB、metadata 後 162.56 MiB。192 MiB case
open 完成仍約 157.94 MiB anon；query preflight 後約 166.88 MiB。
這些數字支持繼續檢查持續持有量，不能只聚焦 encoded segment 的短暫副本。

128 MiB 的 real／uniform 高維 worker 在第二段 decode 前分別約 123.67／
123.54 MiB anon，file RSS 已降至數 MiB。低維控制組同 cap 完成，open 後約
87.70 MiB anon。兩個高維 control 的形狀相近，但這裡沒有 native Linux allocator
量測，不能推算 native host 的精確容量下限。

Cgroup 數字另包含 fixture 複製讀取、Python／library 等 file cache；即使是
6 GiB control，也不能把 `memory.current` 全算為存活 engine bytes。
正式判斷持續 nonresident 仍需原本逐 pass major faults 與 vector mincore 證據，
本輪沒有取代 0/108 配對持續壓力的既有失敗結果。

## 下一個設計邊界

目前 `VectorValue` 公開回傳原生 List 借用，`MemTableEntry` 與 PointState 共享
這些 immutable owners；不能直接用 mapped Span 替換公開回傳型別。
現有 `MappedFile` 支援 checked unaligned loads 與 owned copies；`ArcPointer`、
操作 owner、檔案 lease 已足夠作為後續設計基礎，無須新增套件。

本機 Qdrant `AppendableMmapDenseVectorStorage` 以 mapped ChunkedVectors 提供
borrowed/Cow 讀取（`reference/qdrant/lib/segment/src/vector_storage/dense/appendable_dense_vector_storage.rs`）。
可參考其儲存 owner 與讀取邊界分離，但 Akasha 的 List API、immutable segment／
lease、原 scalar bits、錯誤順序、snapshot／Arrow lifetime 都必須保留。
Mapping 設計尚未實作或驗證；不把本次診斷記為容量修復。

## 不可變證據

[原始資料](2026-10-13-open-memory-phases.json.gz) 包含完整診斷 source/package
文字、baseline 三個檔案、所有 observer／worker／runner／summarizer、原 query
inputs、七個 jobs／reports／traces／container outcomes、compiler log、source／
binary identities 與方法。全部解壓後檔案 SHA-256 已核對。

Diagnostic Linux binary SHA-256：
`5f911a3989ac86eefa9b23a3ee9a4d5a10c837f05a5e8fa96f2f0bbf5a0f29b1`。
Image：`sha256:540414f50b96439a6ba1475b79b2e2dd2208e86ebef33e2fbf2a176a8f037d31`。
Archive SHA-256：`5fa11fc7f091a774bf09c8705f5070b70ae15b5348c28092eb967c2ac842479e`
（190 files，8,146,651 bytes）。所有本輪診斷容器已結束，build 容器已停止。
