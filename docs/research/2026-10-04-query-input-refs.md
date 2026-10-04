# Named query／write 輸入容器參照釋放

2026-10-04，基線 `fa9e092`。**已採用正確性修復；M5/M6 尚未完成。**
本包沒有新效能量測，不把前版的 Qdrant 數字套到本版 binary。

## 問題與實作

前一 [vectorcall 工作包](../benchmarks/2026-10-04-instance-capi.md) 的 compiled probe
已證實普通 Python callable 呼叫會留下 argument reference。`hasattr(query, "dtype")`
與 ndarray `isinstance` 都會保留 query，涵蓋成功及拒絕查詢。

沿用 `point_values.mojo` 的 private vectorcall helper，改名為 `_call_predicate`，
呼叫相同 builtins.hasattr／isinstance；numeric conversion 每次只載入一次 symbol。
保留 callable、dtype property callback、truth／error、close reentry、ndarray fast
copy、fallback numeric conversion 與所有 component checks，沒有新增 API 層。

新增寫入測試再定位 `python_module.mojo::_is_python_none`：舊的
`type(value) == type(None)` 也經普通 callable 保留 value；若 value 的 metaclass
自訂 equality，還可能把合法向量當成移除。改用 stdlib 現有 PythonObject identity
比較 `value is Python.none()`，只有 None 表示移除。helper 不再 raises。
其他 type validation helpers、一般 Python callable 與輸出建構路徑未一起改動，
**未宣稱整個 binding 已無參照保留**。

採用 Mojo 1.0.0 (`ed45d567`)／Python 3.11／Apple M4。沿用前一工作包已查驗的
官方版本 source 與 CPython ownership 合約；不新增依賴。只改上述兩個 binding files，
沒有 engine 搜尋策略／score／format／WAL／worker／C API／GPU 變動。

## Red／green 與完整驗證

| 階段 | 結果 | 範圍 |
|---|---|---|
| 初始基線 | 22 failed | 20 dtype/kind/representation combinations＋2 rejected queries |
| 只改 predicates | 25 passed、2 failed | query／dtype callbacks通過；新增2寫入案例仍保留input |
| 完整 regression 對基線 | 28 failed | 包含新增3 callbacks、2 writes與1 None spoofing |
| 完整 regression 對候選 | 28 passed | 未清空 query 容器、未放寬 weakref assertions |
| 隔離完整 Python | 571 passed | 既有543＋新增28，1項既有Starlette warning |
| 正式路徑驗證 | 123 passed | 新28＋既有95，與完整suite重複，不加總 |

兩版候選皆由 copied entry／matching copied includes 編譯成功。初版 kernel SHA：
`4367876c98264ce097a6698b3cafd96400eb8522519cd18e59f01d24592ad932`；
其 source 可由 before source＋最終 point_values 檔重建，python_module 當時未改。

新案例涵蓋 F32/F16/BF16/I8/U8、dense／multivector、list／NumPy array；BF16 array
使用原 float32 conversion path，未加新 optional dependency。每一合法 query case
連續8次操作後檢查所有 weakrefs 已釋放，不只在close後檢查；IDs／scores仍符合
oracle。非法dimension／bool query也釋放容器。dtype property接受、拋例外、close
各有案例。兩種寫入輸入在 commit 後被 caller 修改，DB值保持不變，input可回收，
flush/reopen後內容仍正確。自訂metaclass equality不能把合法vector當成None。

Saved-package pytest 有 import path/hash guard、`-o pythonpath=`；child compiler
wrapper remap 相對與絕對 src 並繼承Metal PATH。正式安裝時驗證source/kernel/test/worker
hash，再跑窄測試。沒有新完整Mojo/crash、C ABI、examples、HTTP performance、Linux、
GPU、ASan、RSS或nonresident/memory-limit證據；未變動範圍沿用既有成功結果。

## 產物與重現

現行正式 kernel SHA-256：
`87717b0d2ffc31b46a9c92ed5069135fe6125977c07804c22be04a85fd082fda`。
前版 `b3f2b57565f4b129752df07a865931863365d03c8a6950d958dc152872779a73`。
Worker未改：`bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`。
核心engine仍 `1318457`，C API／examples source未改。

[凍結 archive](../benchmarks/results/2026-10-04-query-input-refs.json.gz)：299 entries、
597,382 bytes，全部embedded SHA已驗證；SHA-256：
`97040c7b66fffbbc01fec4719ddb807948af37afdb16c1422d61fd1cee94ae1b`。
包含完整兩版source/Python text、所有red/green logs/XML、build metadata、guards、
compiler wrappers及promotion。`.build/2026-10-04-query-input-refs` 已凍結，不重跑
寫入此目錄的driver；後續實驗需新OUT。沒有覆寫舊archive。

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD/python:$PWD" python -m pytest -o pythonpath= -q tests/python/test_query_input_lifetime.py tests/python/test_vector_callable_protocols.py tests/python/test_vector_component_protocols.py tests/python/test_binding_conversion_close.py
```

## 尚未完成

上一版 `fa9e092` 的完整performance gate為warm25/36、mixed27/36、write+flush3/9，
整體FAILED；本版尚無新performance驗收。原逐格 Recall@10≥.95、QPS≥Qdrant、
p95≤Qdrant標準不變，沒有替換任何原試次。舊mixed停滯根因仍未解。

接續依已證實的普通call refs問題，從實際輸出建構／其餘typed helpers做最小
ownership probe，再選有證據的修復；不先全域替換或新增泛用抽象層。
Named更新後重開成本、原效能失敗格與最終整合仍待完成。沒有Linux runner，持續
nonresident／memory-limit未驗收；唯一[checklist](../../tasks/todo.md)維持未勾選。
