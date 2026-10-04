# Named scalar callable 呼叫成本與例外參照

正式基線：`a293037`，engine `1318457`，Mojo 1.0.0 (ed45d567)，Apple M4。
唯一 checklist 仍為 [tasks/todo.md](../../tasks/todo.md)；本文件不新增完成門檻。

既有 named real profile 的 `builtin_isinstance` 約占 22% samples。版本相符的
Mojo PythonObject.__call__ 每次建立 argument tuple 與 kwargs dict。隔離候選使用
CPython PyObject_Vectorcall 呼叫同一 callable，每個 component 的兩次型別檢查、
bool 排除、數值轉換與順序保持；不加 exact-type 捷徑／global cache。

新增 callable、truth、__class__、close reentry 與弱參照測試。正式版與第一版候選
共同重現例外 traceback 參照保留；Mojo 1.0 unsafe_get_error/PyErr_Fetch 僅消費 value。
候選在此兩條 type-check 錯誤路徑使用既有 PyErr_FetchTriple，消費所有 owned refs。
其他 binding 路徑未宣稱一併修復。

隔離目錄 `.build/2026-10-04-instance-capi` 使用完整 copied entry/include/packages；
先 narrow，再 full saved-package Python，child compiler remap 相對／絕對 src。
效能沿用原 18 named workers、六個 fixed ef、三 corpus／trial／filter／K／oracle，
以及原 54 warm/mixed/Qdrant workers。Native timeout capture 在原 deadline 之後觸發；
不重跑替換失敗樣本。Bench、build、test、compression 串行。

是否採用依 correctness、實際成本證據與完整退步紀錄判斷；不另設每個 A/B 必須改善
規則。M5/M6 仍需原逐格 recall ≥ .95、QPS ≥ Qdrant、p95 ≤ Qdrant 全通過，
不能跨格抵銷。沒有 Linux runner，nonresident/memory-limit 保留未驗收。

結果：已採用，隔離 543 完整 Python 與正式 95 targeted Python 通過。
Named 14,472 pairs 完全一致；原 Qdrant gate 仍 FAILED。
[全部結果、退步、已修與未修參照問題](../benchmarks/2026-10-04-instance-capi.md)。
