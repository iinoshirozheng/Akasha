# AkashaDB 交接狀態與測試文件

記錄日期：2026-10-02。依使用者要求先完成交接，停止新的效能實驗。
使用者另已授權 commit、push、merge 本分支全部交付變更到 main；目前 Git 寫入
受環境阻擋，見 [Git 交接](2026-10-02-git-delivery.md)。

## 目標與不可更改的驗收門檻

原任務是完成 named/native vector、更新後重開、效能問題及
[tasks/todo.md](../../tasks/todo.md) 全部項目，並完成驗證與提交。
唯一未勾選的工作包是 **M5/M6 效能矩陣與最終交付**。

使用者已明確定案：**完整矩陣在相同 recall 下，各格 QPS 與 p95 都至少達到 Qdrant
水準**，即 QPS ≥ Qdrant、p95 ≤ Qdrant；無容許差距，不能用其他格或中位數抵銷失敗。
目前選定暖查詢的共同目標為 Recall@10 ≥ .95，.99 曲線是診斷。
固定 corpus、seed、filter、K、service boundary、trial 和已選 ef，不依最快樣本調參。
Qdrant 無對應 dtype／metric 的功能保留獨立 oracle 驗收。

## 工作目錄與現行產物

| 項目 | 值 |
|---|---|
| Worktree | `/Users/ray/Projects/Akasha/.worktrees/production-hnsw-plan` |
| Branch | `feat/48-bounded-generation-head` |
| HEAD | `31f27e5e7f919d748f5e87ba3bdf600c387dac01` |
| Local main | `b0dd667`，主 checkout `/Users/ray/Projects/Akasha`，交接檢查時乾淨 |
| Remote | `https://github.com/iinoshirozheng/Akasha.git` |
| 環境 | macOS ARM64／Apple M4 Pro，Mojo 1.0.0 (ed45d567)／MAX 26.5 |
| Python | 3.11，PyArrow 21，NumPy 2.4.6 |
| 執行狀態 | 無正在執行的 benchmark、build 或 test |
| 交付狀態 | 大量 tracked／untracked 修改尚未提交；不可 reset／整批 checkout 覆蓋 |

現行 `python/akashadb/_kernel.so` SHA-256：
`3ccdc28c64b16c26277649c1d890c552b437ad357fde30b02067f03a115b3401`。
它與最新測量的 exact-only candidate 相同，production Mojo source 也逐檔相符。
先前 ARM CRC baseline binary SHA：
`c2e0a6399b07d7a3ba34e4d7a6a993082b4ed73787c172a29c4bbbc892edb127`。
來源核對在 `.build/prepared-query-probe/production-identity.json`，已收入凍結證據。

## 已完成的實作

- Named/typed schema、point ownership、catalog v2、WAL/segment v4、migration
  preflight/recovery、原子 batch、查詢、Python／Arrow 已串接。
- F32/F16/BF16/I8/U8、Binary Hamming/Jaccard、MaxSim 有原生資料與獨立數值 oracle；
  named dense HNSW、sparse F64、同一 captured root 的 RRF、IVF-flat 與候選重排已串接。
  IVF 低 probe、MaxSim 小候選集仍有 recall 失敗，未宣稱那些設定達效能門檻。
- Named/native NDJSON logical export/import 保留全部 fields、named-only points、
  source sequence／catalog；匯入先驗證再單次提交，匯出原子發布，保留 legacy fixture。
  詳見 [logical export 驗證](../research/2026-10-02-named-logical-export.md)。
- Retained base HNSW、manifest v5、delta checkpoint cache、publication/recovery 已驗證；
  snapshots／leases／backup／retirement、background compaction、SQ8/PQ root cache 已串接。
  Named field graph 仍是每個 root 的記憶體 artifact，首次 query 建圖成本仍屬效能範圍。
- Bounded batch staging、borrowed WAL decode、bulk F32 decode、mapped read、stream
  fingerprint、標準 metadata sort、鄰接範圍重用、小 delta exact scan 已採用。
- AArch64 CRC 依實際 target feature 啟用，ISO-HDLC 與持久化 bytes 不變；其他 target
  保留 portable implementation。[CRC 報告](../benchmarks/2026-10-02-arm-crc.md)。

最新 exact scan 改動只涉及 `src/akasha/compute/simd.mojo`、
`src/akasha/index/flat.mojo`、`src/akasha/api/collection.mojo`：每次掃描準備一次 query
finite check／cosine norm，保留 candidate 驗證、浮點累加順序、score bits、空集合與
zero norm 行為。Prepared scalar 沒有跨操作 pointer 或 owner；HNSW rerank 維持 checked
pair 評分。未改 format、planner threshold、public API 或依賴。
[設計](../plans/2026-10-02-prepared-exact.md)／[量測](../benchmarks/2026-10-02-prepared-exact.md)。

## 已有測試證據：不要混淆驗證範圍

| Checkpoint | 已跑結果 | 證據與限制 |
|---|---|---|
| ARM CRC 後完整 CPU 整合 | 957 Mojo／131 files、23 crash／8 files、344 Python、C ABI、3 examples | [完整報告](../research/2026-10-02-cpu-integration-arm-crc.md)；不是 exact-query 改動後重跑全套 |
| 最新 exact-query 改動 | 88 targeted Mojo／8 files | 先跑 87，再以 9-test SIMD 取代原 8-test SIMD；不宣稱跑過 961 項完整 Mojo |
| 最新完整 Python | 349 passed，0 failed/error，3 warnings | `.build/prepared-query-probe/python.xml`；後續增加 benchmark 測試後未重跑 352 項全套 |
| 後續共用 warm/mixed gate | 16 targeted benchmark tests passed | `.build/prepared-query-probe/parity-both-tests.xml`；含 3 個新增 mixed failure cases |
| 最新 C／examples | 9 個 build/run steps 全部 exit 0 | `.build/prepared-query-probe/delivery-builds.json`；C ABI/client 加 smoke、persistent_collection、configured_hnsw |
| 最新 warm comparison | 27 workers、6,912 timed audits、7,236 exact oracle checks、108 quality cells 通過 | 9 triples；candidate 的嚴格速度 gate 僅 16/36 |
| Latest mixed before/after | 9 pairs、5,184 audits、72 quality cells、18 reopen、18 leases 通過 | 保留 p95 慢樣本，不宣稱全格無退步 |
| Latest mixed Akasha/Qdrant | 9 pairs、5,184 audits、72 quality cells、18 reopen、9 Akasha leases 通過 | 36 matched quality 通過；嚴格速度 gate 僅 23/36 |

TestSuite 顯示的時間單位是 **毫秒**，不要重複早期誤讀為秒的高維測試敘述。
本次整理交接只核對文件、現有測試報告、source/binary/archive identity 與 diff；沒有
重新執行完整測試。之後修改了引擎才依受影響範圍補跑，已有仍適用結果沿用。

### 最新 Qdrant 逐格狀態

每格是 3 次獨立配對中，同時達 QPS 與 p95 的次數。所有選定對照均達 recall 目標。

| Corpus | Filter | Warm 通過 | Mixed 通過 |
|---|---|---:|---:|
| uniform-128 | all | 0/3 | 3/3 |
| uniform-128 | correlated | 3/3 | 3/3 |
| uniform-128 | independent | 3/3 | 3/3 |
| uniform-128 | selective | 0/3 | 2/3 |
| uniform-1536 | all | 3/3 | 3/3 |
| uniform-1536 | correlated | 3/3 | 3/3 |
| uniform-1536 | independent | 3/3 | 3/3 |
| uniform-1536 | selective | 0/3 | 0/3 |
| real-1536 | all | 0/3 | 1/3 |
| real-1536 | correlated | 0/3 | 1/3 |
| real-1536 | independent | 0/3 | 0/3 |
| real-1536 | selective | 1/3 | 1/3 |

暖查詢 uniform-1536 all 的 before/after QPS 中位比為 1.490；real selective 為
1.124。ANN control path 未變，不能把 timing variation 算成 ANN 改善。
Warm before/after 都是 16/36，包含一格 pass→fail 與一格 fail→pass，不能互相抵銷。
Mixed before/after 保留 uniform-128 independent p95 2.663×、real all 2.252× 的慢 trial。

Fresh mixed 的 update+flush p95，Akasha/Qdrant 分別為 25.337/39.023 ms（128D）、
57.460/35.656 ms（uniform 1536D）、47.411/38.962 ms（real 1536D）；post-write
open 中位數為 92.675/60.775、147.045/53.551、159.349/60.562 ms。
Akasha batch acceptance fsync 與 Qdrant update/flush 的 durability boundary 不同，
write-only latency 不能直接當成同語意對照。這次 query preparation 沒改 write/open。

### Cold 與環境限制

- **File-data cold-open 已完成**：27 次 fresh inode copy，F_NOCACHE、fsync、mincore
  證明計時前各檔 0% resident。864 exact checks 通過；另行未計時的完整品質驗證有
  2,304 audits／36 recall cells 通過。原低 ef ANN sanity 的 recall 失敗保留。
  三組 before CRC／after CRC／Qdrant open 中位數為 120.560/98.633/246.123、
  291.545/229.781/383.271、330.271/242.904/373.370 ms。
  這不是持續 nonresident 查詢，也不控制 runtime/code/controller caches 或等量 IO。
- 持續 non-resident query、受控 memory limit、concurrent-client parity 尚未完成。
- 分散式 gate 先前是 3 passed／7 failed；7 項在 `socket.bind(127.0.0.1)` 被 sandbox
  阻擋，服務尚未啟動。不能宣稱本輪 network／HTTP 驗收通過。
- ASan 缺少執行期符號，未通過；Linux 僅有 target assembly 檢查，沒有本輪 Linux
  runtime gate；沒有新 GPU device gate。BF16 native/Arrow bits 已驗證，選用的
  `ml_dtypes` producer 未安裝，不列為已驗收。
- Git index/objects/refs 在主 checkout `.git`，超出可寫範圍；目前 approval=never。
  不用 alternate index、另建 repo 或其他方式繞過；環境不變時不反覆重試。

## 可重現的測試指令

所有 shell command 依 `/Users/ray/.codex/RTK.md` 以 `rtk` 開頭。
修改 `.mojo` 前讀 `/Users/ray/dotfiles/agent/skills/mojo-syntax/SKILL.md` 並確認安裝版本。
下列指令從 worktree root 執行。輸出目錄用新的名稱，不覆寫凍結結果。

```bash
rtk proxy pixi run mojo --version
rtk proxy git -c core.fsmonitor=false diff --check
rtk proxy pixi run mojo run --target-accelerator=metal:4 --target-cpu=apple-m4 -I src tests/mojo/test_simd_distance.mojo
rtk proxy pixi run mojo run --target-accelerator=metal:4 --target-cpu=apple-m4 -I src tests/mojo/test_flat_index.mojo
rtk proxy pixi run env PYTHONPATH=python:.:.build/qdrant-compare/deps pytest tests/python/test_qdrant_compare.py -q --tb=short
```

完整 Python 需要 child compiler 繼承既有 Metal wrapper PATH：

```bash
rtk proxy pixi run env PATH=/Users/ray/Projects/Akasha/.worktrees/production-hnsw-plan/.build/compiler-bin:/Users/ray/Projects/Akasha/.worktrees/production-hnsw-plan/.pixi/envs/default/bin:/usr/bin:/bin PYTHONPATH=python:.:.build/qdrant-compare/deps pytest tests/python -q --tb=short --junitxml=.build/handoff-next-python.xml
```

專案一般 gate 為 `pixi run test-mojo`、`test-crash`、`test-python`、`build`、`test`，
執行時同樣加 `rtk proxy`。本機完整 native runner 曾因 child compiler 未繼承 Metal
target 失敗；已修正 wrapper 並保留原始失敗。原 runner 與命令收在 CRC archive，
`.build/cpu-integration-arm-crc/report.json` 是其本地工作副本。
不要直接重跑會覆寫 production artifacts 或硬編碼舊 source identity 的歷史 driver。

測試／建置注意事項：

- Benchmark 必須串行，且不與 compiler、test 或壓縮同時執行。保留全部 trials。
- 測試執行中不可覆寫 `.build/native/libakasha_worker.so`；C maintenance worker 未變，
  不因 query/CRC 改動順手重建它。
- Isolated binding 必須編譯複製後的 `PROBE/variant-src/bindings/python_module.mojo`；
  只替換 `-I` 而仍用原入口不算 isolated build。
- Saved-package pytest 要加 `-o pythonpath=`，避免 repo pytest 設定注入 production。
- C library 為 `.build/c/libakasha_c.dylib`，client runtime 設定
  `DYLD_LIBRARY_PATH=.build/c`。最新 9 個 build/run 命令見 delivery-builds.json。
- Compiler Crashpad stderr 可能出現 sandbox permission 訊息；是否成功以真實 exit
  status／產物與執行結果判斷，不能只看 stderr。

## 證據保存與查找

`.build` 是本地暫存，不保證新 checkout 存在；下面的凍結 archive 才是可攜交接證據。
不要改寫 archive 或把整個巨大 JSON 印到終端；只抽取需要的欄位。

| 證據 | SHA-256 |
|---|---|
| [Latest prepared exact，19,639,625 bytes](../benchmarks/results/2026-10-02-prepared-exact.json.gz) | `c6822b3054fe404e043e04ae5a47f48f68fc8a3b3a436abc7c8282bb7a559567` |
| [CRC 完整整合／cold，17,070,506 bytes](../benchmarks/results/2026-10-02-arm-crc.json.gz) | `8019f4ab9c46557c569cdb4a36934cb45179e91ba661fdab735c1d66510016fa` |
| [早期 strict gate snapshot](../benchmarks/results/2026-10-02-qdrant-parity-gate.json) | `a2d3a91a1409f812e84d2344e337fb9498d44b28d4d58c2c6270517ce1dc4c1e` |

Latest archive 包含 baseline source、variant deltas、拒絕的原型、warm/mixed 全部數據、
source/binary identity、測試與 C build logs。Gate snapshot 保留較早 13-test 版本；
後來共用 mixed/warm helper 的 16-test 證據在 latest archive，不能覆寫舊 snapshot。

本地診斷位置：

| 位置 | 內容 |
|---|---|
| `.build/prepared-exact-final/report.json`、`assessment.json` | Latest 三方暖查詢，assessment exit 1 是速度未達標，不是量測中途失敗 |
| `.build/prepared-exact-mixed/report.json` | Saved-before/current-after resident mixed |
| `.build/qdrant-mixed-prepared-exact/report.json` | Fresh Qdrant mixed，9 pairs 完成，strict gate exit 1 |
| `.build/prepared-query-probe/` | Source variants、saved Python packages、JUnit、C logs、identity |
| `.build/crc-cold-open/report.json`、`.build/crc-cold-quality/report.json` | Cold-open residency 與另行完整 recall follow-up |

`benchmarks/qdrant_compare.py` 的 `latency_parity` 已由 warm/mixed 共用。
新 mixed ratio key 是 `qps_ratio_akasha_over_qdrant` 及
`p95_ratio_akasha_over_qdrant`；舊 frozen report 的 `qps_ratio` 留原樣，不新增相容 fallback。

## 已拒絕的方向與下一步

以下已有量測，不要無新假說重做：

- HNSW prepared rerank 與 forced-inline：targeted correctness 通過但公開 ANN／tail
  無穩定收益或退步，已還原。最新採用的是 exact-only。10-pass repetition diagnostic
  在完成 6 workers 後遇 strict zip mismatch；原失敗／driver 已保留，重複 query 不是
  新的獨立 recall samples。
- [HNSW Dict.get probes](../benchmarks/2026-10-02-hnsw-lookup-probes.md)：native gain
  未轉為 public gain，均撤回；negative ID／ordinal 0 回歸保留。
- [Validation prefix bases](../benchmarks/2026-10-02-hnsw-validation-level-bases.md)：
  真實資料 8 balanced pairs reopen 比值 1.011，未採用。
- [官方 heap](../benchmarks/2026-10-01-official-heap.md)：k=1 退步、缺少所需 API；
  raw Span adjacency 原型可在 owner 關閉後被 compiler 接受，未執行不安全程式、未採用。
- Python list→F32 邊界已量測約 1.036 µs（128D）／11.823 µs（1536D），不是未查過的猜測。

下一輪先完成已授權的 Git 交付（環境允許時），保留 M5/M6 未完成狀態；接著以失敗格
為起點做 profile，再決定最小改動，並補齊剩餘矩陣／環境 gates。

可供調查但**尚未驗證的假說**：prepared query 雖已跨 base/delta 共用，
`compute/metric.mojo` 的 `_validate_prepared_values`、`index/hnsw_core.mojo`
prepared entry 與 `index/segmented_hnsw.mojo` delta scan 可能重複做 finite／cosine
norm 驗證。先查實際呼叫次數及占比，不能直接刪掉校驗或引入無 owner 的 unchecked
borrow。`hnsw_view.mojo` 的類似檢查是載入 graph vectors，不能混算成 query hot path。
這只是接手線索，沒有選定設計，也沒有寫入 production。
