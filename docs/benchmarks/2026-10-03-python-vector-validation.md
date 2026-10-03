# Python 向量轉換的型別檢查成本

採用每次向量轉換只查找一次 Python 驗證函式與類別的改動，保留每個 component 的
`numbers.Real`／`Integral`、排除 bool、數值轉換及範圍檢查。三資料集各三次完整
曲線的 36 個選定格 QPS 全提高，其中 30 格同時改善 p95；另 6 格 p95 退步全部保留。
這是 named Python 邊界的改善，**M5/M6 尚未完成，也不是 Qdrant parity 驗收**。

基線 commit `8d70abb`，Mojo 1.0.0 (`ed45d567`)，Apple M4 / Metal:4。
基線 Python SHA-256：
`843186a731ceefaa38e6e5780a0eb13c180dcdc9525191d53f5c8ba0d89d79ba`。
採用 Python SHA-256：
`53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6`。

## 同 binary 的快取診斷

先以基線同一個 binary，在同一份完整 database 的新複本中比較保留 named cache 與
僅移除衍生 cache 後現場建圖。三資料集 × 三 trial × 兩種狀態，順序 AB／BA／AB；
每組沿用前次共同達 .95 的四個 ef，67 queries／filter（3 warmup、64 timed）。
這是縮小範圍的診斷，不替代六個 ef 的正式曲線或前次失敗樣本。

18 workers 通過 4,824 ANN audits；2,412 組配對的 ID／F64 score bits／stats／recall
相同。18 個 close 後的 cache 檔都與 template 逐位元相同；兩組使用相同 binary、
authority 檔及圖內容。36 個選定格仍有 25 格 QPS 或 p95 較差，全部列在下表。
比值為載入 cache／現場建圖；F 表示任一速度指標退步，依未四捨五入的數值判斷。

| Corpus/trial | all（QPS / p95） | correlated | independent | selective |
|---|---|---|---|---|
| uniform-128/0 | 0.9017 / 1.3179 F | 1.0883 / 0.8349 P | 0.9985 / 0.9696 F | 0.8538 / 1.3706 F |
| uniform-128/1 | 0.8470 / 1.3734 F | 0.8237 / 1.6218 F | 0.8481 / 1.4325 F | 0.9465 / 1.0831 F |
| uniform-128/2 | 0.9058 / 1.1594 F | 0.9244 / 1.3282 F | 1.0257 / 0.9382 P | 0.9539 / 1.1002 F |
| uniform-1536/0 | 1.0117 / 0.9742 P | 0.9842 / 1.1027 F | 1.0012 / 0.9544 P | 1.0411 / 0.9350 P |
| uniform-1536/1 | 0.9698 / 1.1125 F | 1.0140 / 1.0015 F | 1.0180 / 0.9830 P | 0.9896 / 1.0429 F |
| uniform-1536/2 | 1.0003 / 1.0301 F | 0.9860 / 0.9719 F | 1.0269 / 0.9400 P | 1.0011 / 0.9893 P |
| real-1536/0 | 1.0255 / 0.9192 P | 1.0756 / 0.9236 P | 0.9792 / 1.0481 F | 1.1618 / 0.8531 P |
| real-1536/1 | 0.9499 / 1.0742 F | 0.9226 / 1.1021 F | 0.8980 / 1.2924 F | 0.9889 / 0.9964 F |
| real-1536/2 | 1.0093 / 1.0587 F | 0.9939 / 1.0373 F | 0.9757 / 1.0991 F | 0.9937 / 1.0228 F |

另做四個獨立十秒持續查詢，每個前五秒以 `/usr/bin/sample` 採樣；67 個查詢輪流重複，
逐筆比對既有 ID／bits／stats，記錄 wall/thread CPU 時間及 GC。採樣不作 acceptance
latency，也不刪除 GC 或等待樣本。總計 79,596 查詢通過身份比對。

| Corpus / 狀態 | 查詢數 | 平均 wall µs | 平均 thread CPU µs | Main-thread samples |
|---|---:|---:|---:|---:|
| real-1536 / cached | 7437 | 1324.45 | 1284.96 | 4187 |
| real-1536 / rebuilt | 7571 | 1300.71 | 1264.09 | 4195 |
| uniform-128 / cached | 32361 | 289.85 | 282.55 | 4227 |
| uniform-128 / rebuilt | 32227 | 290.90 | 283.06 | 4199 |

持續查詢下兩種圖的成本接近，尚未建立「cache 載入方式造成暖查詢退步」的因果證據，
因此未改圖的配置或解碼。Real cached 主執行緒 756/4,187 個 inclusive samples 位於
`builtin_isinstance`；呼叫樹還顯示逐座標解析 `builtins.isinstance`、`numbers.Real`、
`builtins.bool` 的 Python 屬性與 runtime 呼叫。這是下一個改動的直接線索。

## 實作與驗證

唯一引擎樹改動為 `src/bindings/point_values.mojo`。將驗證 callable/type 的 PythonObject
handle 留在單次轉換中，傳給現有 component helpers；dense、multivector、sparse 與
binary 路徑使用相同規則。每個值仍逐一 `isinstance`，接受的 Python numeric protocols、
拒絕 bool、range/finite 檢查與原子批次語意不變。沒有全域 Python handle cache、
新依賴、C API 快速路徑或圖／持久化格式改動，既有 NumPy array 路徑保持原樣。

新增 12 項相容性測試，涵蓋五種 native scalar、dense/multivector、Fraction、NumPy
scalar、IntEnum、拒絕 bool/complex/Decimal/string/僅提供 `__float__` 的物件，以及失敗
批次不提交 prefix；另覆蓋 sparse 與 binary。基線也通過這 12 項，驗證原有契約。

隔離 binding 從複製 source 及其 binding entry 編譯，12 targeted 與 **388 完整 Python**
通過。正式採用後另有 **129 targeted Python** 通過；兩階段不相加成 unique test 數。
Saved package 的 import path 與 SHA 有 assertion，pytest 使用 `-o pythonpath=`，
完整 Python／child compile 繼承 Metal wrapper。C ABI、native worker 與引擎來源未變，
沿用前一工作包的相關成功結果；未重新跑完整 Mojo／crash／C ABI／examples／Linux／GPU。

## 完整配對結果

18 workers 在三組原 corpus／seed／authority／filter／K=10／六個 ef 32–1024／67 queries
上完成 AB／BA／AB。兩邊都從相同已完成的 resident named graph cache 重開；查詢
邊界都是 `Collection.search_field`，每筆測量不含後續 oracle 計算。每個 worker 另做
268 個 exact ID oracle checks。來源、binary、template 與 workload identities 留在 archive。

**14,472 paired queries** 的 ID／F64 bits／stats／recall 相同；**28,944 ANN audits**
與 **4,824 exact oracle checks** 通過。兩版各有 **84 個低 recall 曲線格**，未刪除；
36 組皆在相同第一個 ef 達到 Recall@10 ≥ .95。下表列出這些 ef 的比值，所有曲線
與慢樣本保留。這裡的 P/F 只比較本次前後版本，不代表 Qdrant 速度門檻。

| Corpus/trial | all（ef / QPS / p95） | correlated | independent | selective |
|---|---|---|---|---|
| uniform-128/0 | 128 / 1.1817 / 0.6761 P | 256 / 1.0419 / 1.0746 F | 128 / 1.2050 / 0.8150 P | 128 / 1.0228 / 1.0673 F |
| uniform-128/1 | 128 / 1.1294 / 0.7927 P | 256 / 1.0274 / 0.9361 P | 128 / 1.1007 / 0.8485 P | 128 / 1.0220 / 1.0249 F |
| uniform-128/2 | 128 / 1.1503 / 0.7362 P | 256 / 1.0395 / 0.9885 P | 128 / 1.1178 / 0.8163 P | 128 / 1.0914 / 0.8129 P |
| uniform-1536/0 | 512 / 1.1274 / 0.8808 P | 512 / 1.0739 / 0.9405 P | 512 / 1.0505 / 1.0205 F | 256 / 1.0451 / 0.9819 P |
| uniform-1536/1 | 512 / 1.0809 / 0.9540 P | 512 / 1.0636 / 0.9670 P | 512 / 1.0728 / 0.9540 P | 256 / 1.0191 / 1.0043 F |
| uniform-1536/2 | 512 / 1.0966 / 0.9231 P | 512 / 1.0940 / 0.9254 P | 512 / 1.1220 / 0.8345 P | 256 / 1.0865 / 0.9066 P |
| real-1536/0 | 32 / 1.4301 / 0.7092 P | 64 / 1.3484 / 0.7124 P | 64 / 1.3692 / 0.6960 P | 128 / 1.0923 / 0.9089 P |
| real-1536/1 | 32 / 1.5171 / 0.6436 P | 64 / 1.3057 / 0.7881 P | 64 / 1.2976 / 0.7799 P | 128 / 1.0538 / 0.9713 P |
| real-1536/2 | 32 / 1.3773 / 0.7694 P | 64 / 1.3327 / 0.7618 P | 64 / 1.3471 / 0.7331 P | 128 / 1.0709 / 1.0016 F |

六個 p95 退步格為 128D trial 0 correlated/selective、trial 1 selective；1536D uniform
trial 0 independent、trial 1 selective；real trial 2 selective。不能用其餘格或中位數抵銷。
採用依據是移除重複屬性解析、完整正確性、36 格 QPS 改善和大幅減少 real 查詢成本，
而非宣稱每格延遲都改善。First-query/reopen 原始時間也保留，沒有宣稱其成本改善。

採用版另有一次 real-1536 十秒診斷，9,849 筆 ID／bits／stats 一致。平均 wall/thread CPU
995.25/962.56 µs；基線 cached 的獨立診斷為 1324.45/1284.96 µs。`isinstance` 仍在
主執行緒 944/4,176 inclusive samples 中，驗證工作並未移除。這些 instrumented 數據
僅作成本佐證，效能結論以上述未採樣的三次完整配對為準。

## 凍結證據與重現

[Frozen archive](results/2026-10-03-python-vector-validation.json.gz)：
7,115,790 bytes，394 text entries，SHA-256：
`de892118a0f539d3e0439a53ca261ddda53751d19080148b19078c80e2a87c57`。

格式為 `akashadb-text-evidence-v1`，所有解碼後 entry hash 已重新核對。包含 same-binary
全部樣本、CPU/GC profiles、前後 sources/packages（不含大型 binary）、18 組完整曲線、
測試 logs/XML、drivers、compiler wrappers 及 input/binary identities。未覆寫任何舊 archive。

```sh
rtk proxy pixi run mojo --version
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD/python:$PWD" python -m pytest tests/python/test_vector_component_protocols.py -q -o pythonpath=
```

實驗 drivers 位於 archive 的 `.build/2026-10-03-python-vector-validation/`：
`validate.py` → `paired.py` → `summarize.py` → `profile-after.py` → `promote.py`。
重現時使用新 OUT、複製 baseline/after source 與 package，並從上一個 named-cache
archive 的固定 workload／seed stream 重建 template，核對記錄的 hash。編譯必須使用
該複本的 `bindings/python_module.mojo` 和相同 include tree。上述 driver 保留原絕對路徑，
須先指向新 output；不可原地重跑或盲跑 promotion。Benchmark、build、test、compression
全程串行。Mojo TestSuite 歷史時間單位為 ms，本報告 public samples 為 ns。

原 binding warm/mixed 與 HTTP Qdrant gate 未重跑，不能用本輪 named 診斷取代。
多 run／更新後重開、首次建圖、全矩陣 parity 與 nonresident／memory-limit 仍未完成；
使用者沒有原生 Linux runner，沒有新增 Linux／GPU／ASan 通過聲明。
