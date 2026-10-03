# 現行來源的 CPU 整合驗證（2026-10-03–04）

現行 `3a5ad04` 的完整 **141 檔／1,001 Mojo tests** 與 **8 檔／23 crash tests**
全部通過，無 skip；三個範例重新編譯並執行成功，既有 C ABI client 也通過。
本工作包沒有修改引擎、binding 或測試。**M5/M6 仍未完成**，功能整合成功不代表
Qdrant 全效能矩陣或 nonresident／memory-limit 達標。

| 驗證範圍 | 結果與來源 |
|---|---|
| 本次完整 Mojo | 141 檔、1,001 passed；每檔重新編譯 |
| 本次完整 crash | 8 檔、23 passed；每檔重新編譯 |
| 本次 examples | smoke／persistent_collection／configured_hnsw，3 個重建並執行成功 |
| 本次 C client | 既有 validated library/client 執行成功；本次沒有重建 C ABI |
| 沿用同來源完整 Python | 前一工作包 388 passed，binary/source identity 不變 |
| 沿用正式 package targeted Python | 前一工作包 129 passed；不與 388 相加 |

編譯器 Mojo 1.0.0 (`ed45d567`)，Apple M4／Metal:4；所有 parent／child compilation
繼承 `.build/compiler-bin` 的 Metal wrapper。TestSuite 方括號時間為 **毫秒**；
runner 的 build/process durations 為秒，沒有把它們當作 benchmark。

## 保留的 launcher 失敗與修正

初始 launcher 先 build 再執行 native executable。`test_file_retirement.mojo` 的獨立
reader 案例以 `argv()[0]` 再呼叫 `mojo run`，因此取得 executable path，而非 `.mojo`
來源；該檔首次為 **8 pass／1 fail**，child 在編譯入口即停止，未執行 reader 驗收。

改用專案規定的 `mojo run -I src tests/mojo/test_file_retirement.mojo`，並保留原 Metal
wrapper PATH 後，該檔 **9/9 passed**。沒有修改測試或引擎。前面已成功的 34 檔沿用，
只重跑失敗檔並接續未跑檔；原始 command、failure log、初版與 resume launcher 均凍結。
統計依各檔最終有效結果計算，沒有把重跑的 9 項重複加總。所有後續檔均通過。

## 產物與範圍

Python `_kernel.so`：
`53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6`。
C ABI：`158364853ea2ac943f5d90e15a521c9d70804c868483511c97bd9e5405d1e40b`。
Native worker：`bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`。

前後逐一核對 120 個 source、149 個 test source、compiler wrapper 與既有 native
產物 hash；全部不變。測試期間沒有覆寫 native worker，沒有 benchmark 或 archive
compression 重疊。每個成功執行的 command、exit、duration 及編譯產物 hash 均留存。

完整 Python 證據沿用 [Python vector validation 工作包](../benchmarks/2026-10-03-python-vector-validation.md)
的同一套 388 項結果；本 archive 亦帶入其 log／XML／identities，清楚標示為沿用。
CPU 中的 GPU planner／fallback 測試不是實機 GPU gate；沒有新 Linux／GPU／ASan
或 distributed suite 通過聲明。先前 distributed 10/10 功能結果仍是獨立既有證據。

執行區間（UTC）：`2026-10-03T15:35:21.892656+00:00` 至 `2026-10-03T16:10:43.848455+00:00`。

## 證據與重現

[Frozen archive](../benchmarks/results/2026-10-04-cpu-integration.json.gz)：
574,392 bytes、596 text entries，SHA-256：
`5b02346d8b6693dfc69855e611fbaf1c46717f21d81f1ac6b259784859f11043`。

格式為 `akashadb-text-evidence-v1`；解碼後的每個 entry SHA 已核對。包含所有 source/test
snapshots、commands、成功／失敗 logs、compiler wrapper、產物 identities 與沿用 Python
證據。大型 native binaries 未收入；舊 archive 未改寫。

單檔（包含會自行啟動 reader 的測試）應使用來源模式：

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_file_retirement.mojo
```

完整來源模式可在沒有其他 build/test/benchmark 的時候執行：

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" python - <<'PYTHON'
from pathlib import Path
import subprocess
for directory in (Path("tests/mojo"), Path("tests/crash")):
    for source in sorted(directory.glob("test_*.mojo")):
        subprocess.run(["rtk", "proxy", "mojo", "run", "--target-cpu=apple-m4",
                        "-I", "src", str(source)], check=True)
PYTHON
```

本次 archive 的 `run-initial.py` 是保留的原始失敗證據；`run.py` 是續跑 driver，依賴
當時的 identity/run records。不要把舊輸出目錄當作新一輪驗證原地覆寫。
