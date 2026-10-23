# 現行引擎的 exact／ANN 路由複核

基線 `d38bffa`。正式 planner 未修改；診斷版只停用 `scan_cost` 判斷，其餘小集合、
metric、readiness 與 selectivity 防護保持原樣。這份結果支持 uniform 選 exact、
真實資料低 ef 選 ANN 的方向，沒有支持直接降低成本係數的證據。

正式 Python binary 為 `2d5e8e0910d4d81d84699e5bc023ba9824a5f9ab867b613cc6bcefcc7bcc0463`；
隔離診斷版為 `7c4fc808ec74e1bda1b11334a768b8161b8659e77910f2d7fc857398e52ccb34`。
Mojo 1.0.0 (`ed45d567`)，Apple M4／Metal:4。

## 方法與完整結果

複製原 `cost-plan-*` 的 trial-0 database，沿用三組原始 corpus、seed、filter、K=10、
oracle、67 個 query（3 warmup + 64 timed）及六個 ef：32/64/128/256/512/1024。
每格在同一 process/database 做三次 pass，每 query 交替 exact／approx 的先後。
這是 resident 配對診斷，不是三次全新 database trial，也不是 Qdrant 對照。
計時包含公開 request construction／search；stats、oracle audit 與保存樣本在計時外。

下表列每種 filter 在六點曲線中，三次 pass 均達 mean Recall@10 ≥ .95 且實際走 ANN
的第一個 ef。每欄依序為三個 pass；QPS 越高越好、p95 越低越好，分母皆是同 pass exact。

| Corpus／filter | ef | ANN/exact QPS | ANN/exact p95 |
|---|---:|---|---|
| uniform-128 all | 128 | .525 / .516 / .514 | 1.841 / 2.026 / 2.035 |
| uniform-128 correlated | 128 | .290 / .287 / .315 | 2.556 / 2.514 / 2.813 |
| uniform-128 independent | 128 | .309 / .287 / .314 | 2.335 / 2.345 / 2.446 |
| uniform-1536 all | 512 | .512 / .490 / .510 | 2.034 / 2.137 / 1.999 |
| uniform-1536 correlated | 512 | .250 / .214 / .258 | 4.277 / 4.323 / 3.591 |
| uniform-1536 independent | 512 | .296 / .250 / .297 | 3.195 / 4.069 / 3.095 |
| real-1536 all | 32 | 4.030 / 4.046 / 4.117 | .293 / .274 / .277 |
| real-1536 correlated | 32 | 1.901 / 1.749 / 2.001 | .509 / .501 / .532 |
| real-1536 independent | 64 | 1.352 / 1.242 / 1.358 | .750 / .788 / .800 |

Selective 保持 selectivity exact，共 54 個 planned-exact pass cells；不把它們標成 ANN。
三資料各 72 pass cells、各 4,824 exact 與 4,824 approx audits，總共各 14,472。
全部 exact 結果與獨立 oracle 相符；所有 approx 的 live ID／filter／recall 均已記錄。
低 recall pass cells 分別為 **18／36／3**，全部保留。三個 worker exit 0 表示量測完成，
不表示低 recall 曲線通過。最新正式 real fine-grid 的 ef=16/32/40 未全部涵蓋於此六點曲線，
因此不宣稱重新驗收全部已選定格。

## 保存與重現

凍結檔：[原始樣本、stats、IDs／F32 bits、driver 與隔離 planner](results/2026-10-03-planner-recheck.json.gz)。
SHA-256：`2b0c9736ecf861332f81ebd5adc38c936d8594c8e1b77fbedfa6b69c2228672e`。
22 個文字檔、2,282,598 bytes；已逐檔核對解壓後 SHA-256。
Workload NPZ 的 SHA-256 記錄在各 report；原 corpus 保持在既有 frozen workload。

Driver 是 `.build/2026-10-03-planner-recheck/measure.py`。重現須先從 archive 提取 driver、
planner 與 scope，使用新輸出目錄；複製當時 source/package，以所附 planner 覆蓋
**隔離 source**，從 copied `bindings/python_module.mojo` 編譯。不可直接重跑舊 driver
覆寫現有證據。執行形態如下，`<fresh>` 指向另建的隔離目錄：

```sh
rtk proxy env PATH="$PWD/.build/compiler-bin:$PATH" \
  PYTHONPATH="<fresh>/variant-python:$PWD:$PWD/.build/qdrant-compare/deps" \
  OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 \
  pixi run python <fresh>/measure.py
```

本次沒有改 production engine，也沒有重新跑完整 Mojo／Python／crash 整合；沿用
`d38bffa` 的驗證。M5/M6 的 Qdrant strict parity、named 首次重開、HTTP／並行與
持續 nonresident／controlled-memory gate 仍未完成。
