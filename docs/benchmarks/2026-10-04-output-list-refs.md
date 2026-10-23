# Python 回傳容器參照釋放

2026-10-04，基線 `ba33618`，核心 engine 仍 `1318457`。
**已採用正確性修復；原 performance gate FAILED，M5/M6 尚未完成。**

## 問題與實作

正式 binding 的 12 個輸出路徑 probe 均看到 child 額外 reference。版本匹配的
Mojo 1.0.0 (`ed45d567`) stdlib 普通 Python callable 會多保留 argument reference；
`PythonObject.__setitem__` 對不接收 ownership 的 `PyObject_SetItem` 傳入已轉移
value，也留下 key/value reference。weakref markers 證實 caller 丟棄結果後容器
仍存活，而非僅 refcount 計算差異。

兩個 binding files 的新建輸出改以 local `List[PythonObject]` owner 組裝，再用
既有 stdlib `Python.list(Span(owner))` 交回 Python；涵蓋 search/batch、schema、
get/projected/point、export、storage report、native numeric/sparse/multivector。
Named vectors、export sparse、scanner metadata 的三處 dictionary assignment
改用既有 CPython `PyDict_SetItem`，private helper 借用 target/key/value owners
至呼叫返回。Binary output 沿用相同 `builtins.bytes` callable，以既有 vectorcall
機制呼叫並在成功／例外後釋放 temporary list。

沒有 engine、C API、worker、durable format、搜尋順序、驗證或 score 變動。
Arrow columns 保持原路徑；Arrow schema 與其他一般 callable 尚未普查，不能宣稱
整個 binding 無洩漏。dictionary helper 的 exceptional allocation path 沿用
stdlib error conversion，不宣稱本包驗收了 OOM 下所有 exception references。
官方 Mojo 1.0 source 與出處保留於 archive `official/`；
[CPython 3.11 dictionary ownership 合約](https://docs.python.org/3.11/c-api/dict.html#c.PyDict_SetItem)。

## 驗證與保留的失敗

| 階段 | 結果 | 範圍 |
|---|---|---|
| 修正測試後的基線 | 23 failed、1 passed | 24 新增 ownership／shape cases |
| 最終隔離候選 | 24 passed | 同一份測試、相同 assertions |
| 完整隔離 Python | 595 passed | 571 既有＋24 新增；既有 Starlette warning 1 項 |
| 正式套件窄驗證 | 147 passed | 新 24＋前批 123，與完整 suite 重複，不加總 |
| compiled stdlib ownership probe | exit 0 | 驗證 list/Span owner 釋放，不計為 Mojo TestSuite |

16 個 weakref marker cases 涵蓋 parent/child/nested containers；5 個 float cases
檢查 boxed values 無額外 native refs；1 個 empty shape；2 個相同 bytes callable
成功／失敗 cases。DB 尚開啟時就檢查回收，並確認修改輸出不會修改資料庫。

第一版只修 list，8 failed／16 passed：其中 nested named/export parent leaks
需再修 dictionary assignment；named ANN fixture 缺 HNSW 設定及 pytest assertion
rewriting 暫留 float 是測試缺陷，已更正。最初的 21 failed／1 passed 與
23 failed／1 passed logs、第一版 source/tests/build 全保留。修正 fixture 與
refcount 取值方式後重跑基線仍 23 failed／1 passed，最終全通過。

First-candidate kernel `b674ae7f7181fff1d0b922161c41022b2587c10dfc731c20934a83ee50e2241c`
的 child refcount probe 雖為 3，未證明整棵輸出樹能回收；最終 weakref cases 才涵蓋
parent ownership。兩次隔離 build 均成功。測試 wrapper remap 相對/絕對 src，
繼承 Metal wrapper PATH；saved package 有 path/hash guard 與 `-o pythonpath=`。

## 原矩陣結果

Original corpora/seeds/filters/K/ef/trials/service boundaries/40 秒 deadline 不變。
18 named workers 與 54 before/after/Qdrant workers 全完成，沒有 timeout；
先前 native 停滯原因仍未解，不能由這次無超時推論已修復。

| 門檻 | Before | After |
|---|---:|---:|
| Warm strict parity | 21/36 | 24/36 |
| Mixed strict parity | 21/36 | 20/36 |
| Warm matched recall | 36/36 | 36/36 |
| Mixed matched recall | 36/36 | 36/36 |
| Write＋flush strict parity | 3/9 | 3/9 |

Warm 17/36、mixed 21/36 個 A/B 格的 QPS 或 p95 退步，全部原 samples 保留。
Warm pass→fail：uniform-128/trial2/all。
Mixed pass→fail：uniform-128/trial0/selective、uniform-128/trial2/selective、
uniform-1536/trial0/selective。Assessment exit 1 是正確 FAILED gate。

Warm 2,412 與 mixed 2,592 paired queries 的 IDs、stats、50,040 個共同 F32 score
bits 全一致。三引擎 warm 7,236 query audits＋7,236 exact oracle checks；mixed
7,776 query audits，九個 trials 全有 reopen oracle，兩 Akasha 版本 lease/close 通過。

Named 28,944 ANN audits、4,824 exact checks；14,472 paired IDs/F64 bits/stats
全一致，品質仍 132/216，84 個 fixed-ef 低 recall 格完整保留。36 選定格中 25 格
QPS 或 p95 退步，不能宣稱本修復有全面速度收益；完整逐格 ratios 見 `summary.json`。

## Profile 與採用判斷

最終候選兩個 named selective profiles 共 3,584 repeat audits＋134 warmup audits，
每筆核對 IDs/F64 bits/stats。Uniform-1536 主執行緒 3,752 samples，其中兩個
HNSW distance kernels 2,165（57.70%）；real-1536 為 2,074/3,774（54.95%）。
Call tree 只有少量 Python dictionary construction/list destruction samples；collapsed
表會省略不足 5 個的 self samples，表中 0 不代表成本為零。這是診斷，非原 gate。

採用原因是修復可重現的回傳容器 ownership 缺陷；不因少數 A/B timing 改善就宣稱
M5/M6 通過。上述 profiles 不支持再投入新的 output-container 速度原型。後續回到
距離計算的具體成本與 named 更新後重開生命週期；不重做已否決的原型。

## 產物與重現

正式 kernel SHA-256：
`0088e118e5723f9a30cdef9c5a99ac3b3d6503fe4c67b09afb50ba4ef76b6c1c`。
Before `87717b0d2ffc31b46a9c92ed5069135fe6125977c07804c22be04a85fd082fda`。
Worker 未改：`bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`。

[凍結 archive](results/2026-10-04-output-list-refs.json.gz)：630 entries、9,041,092 bytes，
全部 embedded SHA 已驗證；SHA-256：
`8a209eb643a24b83b5ba706f385b61380cc084f38fb1085198d5f4c965b373df`。
包含兩版 source/package text、初版 source/tests、失敗/成功 logs/XML、完整矩陣、
profiles、supervisor/capture 與 promotion。`.build/2026-10-04-output-list-refs` 已凍結，
禁止重跑會寫入同 OUT 的 driver。重現矩陣需解出 scripts 至新 OUT，建立保存版本的
isolated packages 並重建 identity；不能直接重跑舊 driver 覆寫證據。

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" PYTHONPATH="$PWD/python:$PWD" python -m pytest -o pythonpath= -q tests/python/test_output_list_lifetime.py tests/python/test_query_input_lifetime.py tests/python/test_vector_callable_protocols.py tests/python/test_vector_component_protocols.py tests/python/test_binding_conversion_close.py
```

本包沒有新 full Mojo/crash、C ABI/examples、HTTP performance、Linux、GPU、ASan、
RSS 或 sustained nonresident/memory-limit 證據。沒有 Linux runner，不重問。
唯一 [M5/M6 checklist](../../tasks/todo.md) 保持未勾選。
