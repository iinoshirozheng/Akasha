# Segment F32 整段寫入：候選未採用

正式 source／binary 未改。候選將 `segment.mojo` 的逐值 `write_f32` 迴圈改成既有
`BinaryWriter.write_f32s` 一次呼叫。編碼微量測較快，但完整負載沒有穩定收益：
三方 warm、mixed strict parity 都是 19→18/36，durable write+flush 維持 3/9。
M5/M6 仍未完成；沒有以編碼速度或其他格改善抵銷失敗。

## 變動與驗證範圍

[现行 profile](2026-10-04-payload-buffer.md) 的背景 compaction 包含 segment 編碼。
專案已有經位元測試的 `write_f32s`：little-endian 使用 `List.extend(Span)`，其他
端序沿用逐值 little-endian 編碼。候選只改 caller，沒有新 API／套件，不更動驗證、
payload、CRC、WAL、manifest 或 durability 順序。Before/after 各 120 個 Mojo files，
逐檔核對只有 `segment.mojo` 不同。環境 Mojo 1.0.0 (`ed45d567`)、Apple M4／Metal:4。

正式 binding SHA-256 保持
`53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6`；候選為
`d6ddb0eaaf2ea068c93e441918104f2cefb5c0ecc1ec0408bd39ce871258c793`。

- **73 targeted Mojo**：checksum、segment v2/v3、v1 compatibility、persistent
  collection/documents、compaction、conditional/background publication。
- **8 related crash**：7 checkpoint/compaction durability 邊界、1 torn batch。
- **388 完整 Python**；1 個既有 Starlette/httpx deprecation warning。從 copied
  entry/source 編譯，pytest 使用 `-o pythonpath=`、import 路徑／SHA guard，child
  compile 繼承 remapped Metal wrapper。Native worker 未覆寫。
- 六組微量測完整 segment bytes／SHA 相同：128D 5,103,656 bytes，SHA
  `2e99f660c9cdfb6abb84f18f2e2886a0132b2bcd4d0b6bfa615e0adebead886e`；
  1536D 51,241,000 bytes，SHA
  `21def474241d638039576d3e96e80ee0983e85d4657b873e99b42c3ba9f70e3c`。
- 18-worker A/B：5,184 audits、18 reopens、18 leases；2,592 paired query 的
  ID／F32 bits／stats／execution 相同，metadata cache payload/source checksum 相同。
- 54-worker 三方矩陣：warm 6,912 timed audits、324 warmups、7,236 exact checks、
  27 first queries；mixed 7,776 audits、27 reopens、18 Akasha leases。另核對
  2,304 warm／2,592 mixed paired identities。所有品質檢查通過。

不是新版完整 Mojo／crash 整合，沒有新 C ABI、examples、HTTP、Linux、GPU 或 ASan
gate。Archive 中 `postvalidate.py` 未執行，不把 script 存在當成驗證通過。先前鎖
停滯仍[原因未解](2026-10-04-baseline-lock-stall.md)，本次未發生不代表修復。
所有 workers exit 0；summary exit 1 是正確的效能 FAILED gate。

## 全部 trial

Micro 固定 8,192 rows／四欄 payload，每 trial 每版 10 次編碼，順序 AB／BA／AB。
資料建立、output file sync 不計時；計時後逐次核對完整 bytes。時間是 mean ms：

| Dimension | Trial | Before | After | After/before |
|---|---:|---:|---:|---:|
| 128 | 0 | 5.540 | 4.707 | .850 |
| 128 | 1 | 5.592 | 4.171 | .746 |
| 128 | 2 | 5.360 | 4.044 | .755 |
| 1536 | 0 | 29.311 | 14.561 | .497 |
| 1536 | 1 | 27.206 | 14.687 | .540 |
| 1536 | 2 | 26.786 | 14.375 | .537 |

Public mixed 固定原 32-block plan、corpora、seed、filters、K、efs、durability
boundary。以下 p95 after/before，大於 1 即較慢；23/36 query cells 另有 QPS 或
p95 退步。Micro whole-base encoding 收益沒有穩定轉換成 public flush 收益。

| Corpus | Trial | Write | Flush | Write+flush |
|---|---:|---:|---:|---:|
| uniform-128 | 0 | .977 | 1.019 | .996 |
| uniform-128 | 1 | .983 | .982 | .981 |
| uniform-128 | 2 | .983 | .965 | .952 |
| uniform-1536 | 0 | .965 | 1.050 | 1.015 |
| uniform-1536 | 1 | 1.042 | 1.041 | 1.047 |
| uniform-1536 | 2 | 1.041 | 1.081 | 1.033 |
| real-1536 | 0 | .997 | .911 | .929 |
| real-1536 | 1 | 1.058 | .582 | .700 |
| real-1536 | 2 | .967 | .995 | .998 |

三方矩陣每 trial 順序 B/A/Q、Q/A/B、B/A/Q，全部串行。固定 Recall@10 ≥ .95，
每格 QPS ≥ Qdrant 且 p95 ≤ Qdrant 才通過。P/F 分別是三個 trial 的 strict 結果：

| Corpus / filter | Warm before→after | Mixed before→after |
|---|---|---|
| uniform-128 / all | FFF→FFF | PPP→PPP |
| uniform-128 / correlated | PPP→PPP | PPP→PPP |
| uniform-128 / independent | PPP→PPP | PPP→PPP |
| uniform-128 / selective | FFP→PFP | FFF→FFF |
| uniform-1536 / all | PPP→PPP | PPP→PPP |
| uniform-1536 / correlated | PPP→PPP | PPP→PPP |
| uniform-1536 / independent | PPP→PPP | PPP→PPP |
| uniform-1536 / selective | FPP→FFF | FFP→FFF |
| real-1536 / all | FFF→FFF | FFF→FFF |
| real-1536 / correlated | FFF→FFF | FFF→FFF |
| real-1536 / independent | FFF→FFF | FFF→FFF |
| real-1536 / selective | FFP→FFP | FFF→FFF |

Warm 有 2 個 pass→fail、mixed 有 1 個 pass→fail，皆為 uniform-1536 selective。
兩組兩版各 36/36 recall；write+flush 兩版皆僅 uniform-128 三個 trial 通過。
這是獨立實驗，不取代[現行正式矩陣](2026-10-04-current-parity.md)，不合併歷史格。

## 證據與重現

[Frozen archive](results/2026-10-04-segment-bulk-write.json.gz)：4,800,501 bytes，
546 entries，SHA-256
`416067ecf9af13d60c7bb18bc3a08c209f156f8089b5b59b6eafc313dacc071b`。
已解壓回讀每個 entry SHA，包含全部來源、harness、tests/logs、raw reports/samples、
inputs/binary identities。`.build/2026-10-04-segment-bulk-write` 保存暫存產物。

重現需另建輸出目錄；scripts 使用 exclusive output creation，不要盲跑覆寫。
依序執行以下步驟，benchmark 不得與 build/test/archive compression 重疊：

```bash
rtk proxy pixi run python .build/2026-10-04-segment-bulk-write/build-probe.py
rtk proxy pixi run python .build/2026-10-04-segment-bulk-write/micro.py
rtk proxy pixi run python .build/2026-10-04-segment-bulk-write/validate.py
rtk proxy pixi run python .build/2026-10-04-segment-bulk-write/python-tests.py
rtk proxy pixi run python .build/2026-10-04-segment-bulk-write/paired.py
rtk proxy pixi run env PYTHONPATH=.:.build/qdrant-compare/deps python .build/2026-10-04-segment-bulk-write/matrix.py
rtk proxy pixi run python .build/2026-10-04-segment-bulk-write/summarize.py
```

下一步回到 real ANN／selective query 主要成本；沿用 profile，先定位實際耗時指令
或呼叫，再選新實驗。不無條件重試已否決的 prefetch、bounds、raw Span 或 query
validation 原型。
