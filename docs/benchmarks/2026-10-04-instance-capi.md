# Named scalar vectorcall 與 callback 參照釋放

2026-10-04。**已採用局部改動；M5/M6 尚未完成，原完整效能 gate FAILED。**
基線 `a293037`，kernel 核心 engine `1318457`；本次只改 Python binding 的
`point_values.mojo` 與 37 個 Python regression cases。沒有改搜尋策略、格式、
C API、worker、GPU 或 ndarray fast path。

## 實作與版本證據

Mojo 1.0.0 (`ed45d567`)，Python 3.11，Apple M4 / Metal:4。
既有 named real profile 的 builtin_isinstance 約占 22% samples。版本相符的
[PythonObject 原始碼](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/python/python_object.mojo)
顯示一般 callable 呼叫建立 tuple／kwargs dict，且參數走 `steal_data` 後又加引用。
這次用 [CPython Vectorcall](https://docs.python.org/3.11/c-api/call.html#c.PyObject_Vectorcall)
呼叫同一個 `builtins.isinstance`，一次操作載入 symbol，兩個 borrowed argument
slots 放在 stack Array，owners 活到呼叫返回；不設定 ARGUMENTS_OFFSET、不傳 kwargs。

每個 component 的 numeric／bool 兩次檢查、短路順序、ABC／__class__ 回呼與
數值轉換均保留；仍接受原 Fraction／NumPy scalar／IntEnum，拒絕 bool 等既有
非法值。可覆寫的 callable 仍被呼叫；沒有 bypass、exact-float shortcut、global
cache、GIL release 或泛用新呼叫層。使用 pinned stdlib 的 `_cpython.ExternalFunction`、
PyObjectPtr／_obj_ptr；Mojo 升版時必須重新編譯驗證這個私有依賴。

新增測試亦重現正式版的 callback exception 參照保留。
[Mojo CPython wrapper](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/python/_cpython.mojo)
的 Python 3.11 `unsafe_get_error` 只消費 PyErr_Fetch 的 value。
候選在 type-check call／truth 失敗時使用既有 PyErr_FetchTriple，消費 type、value、
traceback 的 owned references；遵循 [PyErr_Fetch ownership](https://docs.python.org/3.11/c-api/exceptions.html#c.PyErr_Fetch)。
原錯誤文字與 batch atomicity 保留。其他 Python 呼叫路徑未宣稱一起修復。

## 精確驗證範圍

- 初版與正式基線各 **20 failed／72 passed**：20 個新增 call/truth exception
  弱參照案例皆失敗；一般 callable、close reentry 與既有 protocol tests 通過。
- 改正例外參照後，三個新增 __class__ 案例的 scalar 仍被 query list 保留。
  獨立 probe 確認這是仍使用一般 callable 的 `hasattr` 路徑。測試改由 caller
  清空自己持有的 query container，再檢查 callback/exception 額外參照；原失敗全保留。
- 最終隔離 **95 targeted Python／543 完整 Python** 通過；完整 suite 含原 506
  與 37 新增案例。正式 source/kernel 安裝後再 **95 targeted Python** 通過，
  與完整 suite 重複的測試不加總。包含 dense/integer/multivector/sparse/binary、
  function callable／tp_call object、truth errors、__class__、close reentry、
  failed-batch WAL／sequence／restart 以及 weakref 回收。
- Binding 由 copied entry＋copied includes 編譯。Saved-package pytest 使用
  `-o pythonpath=`，驗證 import 路徑／hash；child compiler wrapper remap 相對
  `-I src` 與絕對 src，並繼承 Metal wrapper PATH。
- 獨立 compiled ownership probe：32 次普通 callable 呼叫多留 **32** 個 scalar
  references，vectorcall 為 **0**；普通 `hasattr` 多留 **32** 個 list references。
  第一輪 probe 因 Mojo 提早釋放最後使用的 local owner 得到 -1；保留原失敗，
  明確延長 owner 到 snapshot 後再驗證，未改 candidate。
- 四次編譯失敗（Array constructor、pointer origin、CPython copy／raises Error
  aliasing）與兩次成功 build 都保留。最終完整 Python 有一項既有 Starlette warning。
- 這不是新版完整 Mojo TestSuite／crash／C ABI／examples／HTTP performance／Linux／
  GPU／ASan gate。C API、engine、worker 未變，沿用相關成功證據；不重跑未變範圍。

## 原 named 曲線

18 workers，原三 corpus／seeds／authority graph bytes、三 trials、四 filters、K=10、
六個 ef（32–1024）、每格 3 warmup＋64 measured queries，未調參。
28,944 ANN audits、4,824 exact checks；14,472 pairs 的 IDs、F64 score bits、
stats 全一致。品質 **132→132/216**，每版 84 個低 recall 格全保留。
選定 36 格有 **9 格 timing 退步**，不是全面 parity。

以下是三 trials 的 candidate/baseline 範圍，QPS >1／p95 <1 表示改善；
所有單一 trial 與原始樣本在 archive，範圍不能取代逐 trial 判定。

| Corpus | Filter | ef | QPS ratio | p95 ratio |
|---|---|---:|---:|---:|
| uniform-128 | all | 128 | 1.001–1.076 | 0.855–1.054 |
| uniform-128 | correlated | 256 | 0.809–0.945 | 1.145–1.426 |
| uniform-128 | independent | 128 | 0.779–1.049 | 0.985–1.394 |
| uniform-128 | selective | 128 | 1.013–1.033 | 0.877–0.962 |
| uniform-1536 | all | 512 | 1.039–1.119 | 0.804–0.968 |
| uniform-1536 | correlated | 512 | 1.041–1.062 | 0.916–0.972 |
| uniform-1536 | independent | 512 | 1.040–1.062 | 0.873–0.964 |
| uniform-1536 | selective | 256 | 1.010–1.026 | 0.962–1.024 |
| real-1536 | all | 32 | 1.180–1.201 | 0.867–0.891 |
| real-1536 | correlated | 64 | 1.113–1.145 | 0.890–0.912 |
| real-1536 | independent | 64 | 1.128–1.263 | 0.809–0.950 |
| real-1536 | selective | 128 | 1.042–1.105 | 0.930–1.005 |

uniform-128 correlated 三個 trials 的 QPS/p95 都退步，independent trial0/1 也退步；
不刪除或歸零。Real named QPS 四 filter 各改善約 4–26%；selective trial2 p95
退步約 0.5%。採用依據是已證實的 reference ownership 修正與 real／高維成本降低，
不是另設「每個 A/B 必須改善」門檻，也不等同 M5/M6 達標。

## 原 Qdrant resident 矩陣

54/54 jobs 完成；原 before/after/Qdrant ordering、workload、fixed ef、filters、K、
service boundary、trials、mixed writes/flush/reopen/lease 全保留。
新 supervisor 沿用原 40 秒 deadline，超時後才 sample／LLDB；本次無超時，
**不能宣稱先前 mixed 停滯已修復**。

| 邊界 | Baseline strict pass | Candidate strict pass | Recall |
|---|---:|---:|---:|
| warm | 20/36 | 25/36 | 兩版各 36/36 |
| mixed | 30/36 | 27/36 | 兩版各 36/36 |
| write+flush | 3/9 | 3/9 | 不適用 |

三個 mixed pass→fail：uniform-1536 selective trials1/2、real-1536 selective trial1。
原始 warm 17 格／mixed 22 格 A/B timing 退步全部保留。
Warm 2,412 paired queries／24,120 common F32 bits、mixed 2,592 pairs／25,920 bits
均一致；兩者 stats 全一致。三引擎合計 warm 7,236 audits＋7,236 exact checks，
mixed 7,776 audits；所有 Akasha reopen 與 retained lease checks 通過。
`summarize-matrix.py` assessment exit **1** 是正確的 FAILED 判定，不是量測未完成。
沒有跨格抵銷、容許差距、slow-sample 刪除或 median 覆蓋失敗 trial。

## 身分、重現與剩餘工作

正式 kernel SHA-256：
`b3f2b57565f4b129752df07a865931863365d03c8a6950d958dc152872779a73`。
前版 kernel：`eb3bebdea9ea4f9d8050d965af1625003d7aec9d841f02fbc9bf101c05f73945`。
Worker 未改：`bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`。

[凍結 archive](results/2026-10-04-instance-capi.json.gz)：625 entries，8,906,191 bytes，
所有 embedded text SHA-256 已驗證；archive SHA-256：
`58c03ff6c85af5c04dff748d4013231cf8b996c1ecd37bfc596d2cb03530cd3d`。
`.build/2026-10-04-instance-capi` 已凍結，禁止重跑會寫入此目錄的 driver。
Archive 含兩版完整 source／Python text、official source hashes、build/test failures、
全部 curves/matrix raw reports、owned watchdog/native capture、identity 與 promotion。
Binary／authority payload 以 SHA 表示；下一批必須複製 driver 到新 OUT 後改所有輸出與 guard。

正式 targeted 重現：

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD/python:$PWD" python -m pytest -o pythonpath= -q tests/python/test_vector_callable_protocols.py tests/python/test_vector_component_protocols.py tests/python/test_binding_conversion_close.py
```

接續優先確認並修復已重現的普通 callable／hasattr container retention，範圍依
最小獨立 probe 與現有呼叫路徑決定；不只在測試清空 list 後宣稱產品不洩漏。
仍須完成原 performance 失敗格、named 更新後重開 artifact 成本與最終整合；
先前 mixed 停滯根因未解。沒有 Linux runner，持續 nonresident／memory-limit 未驗收，
不重新詢問 runner；唯一 [M5/M6 checklist](../../tasks/todo.md) 保持未勾選。
