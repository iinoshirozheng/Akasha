# Mapped row 與公開 List 借用的 compiler probe

這是隔離 F32 機制驗證，**未接入資料庫，也沒有容量／效能改善聲明**。
正式引擎仍為 `6d01819`。背景是 [open 記憶體診斷](../benchmarks/2026-10-13-open-memory-phases.md)：
不能只移除 encoded tape 或縮小解碼峰值，還需檢查 immutable numeric owners。

[可重跑的完整 probe](2026-10-13-mapped-list-probe.mojo) 使用 `ArcPointer` 持有
mapping 與一次性的 List materialization。內部 checked loads 直接讀 mapping；
公開 List 借用形狀的 accessor 在鎖內建立一份 owned List，完成後永不替換。
getter 保留 legacy `_legacy_values`／`MemTableEntry.values` 的 non-raising 契約：
私有 owner 建立時先驗證整段範圍，之後從 immutable mapping 複製；沒有捕捉並
忽略錯誤，也沒有把外部 buffer 偽裝成 List。
更新只經 origin-bound Pointer 修改個別欄位，避免整個 mutable state 跨鎖等待的
copy-back 問題。沒有新增套件或改動正式 API。

本輪 Mac Mojo **1.0.0 (`ed45d567`)**、Metal:4／Apple M4：

- 未對齊 F32 loads 保留 signed-zero bits，越界／負數／極端索引被拒絕，List 配置數仍為零。
- 一個 independently acquired owner 在原 wrapper 釋放後仍保護 mapping 與 List 借用；重讀使用同一地址。
- 八個並行 workers 各讀 100 次，首次 materialization 注入 50 ms 等待；全部結果相同，僅建立一次且地址相同。
- 零長度 mapping 可建立空 List，不會解參考不存在的 base pointer；讀取仍拒絕越界。
- compile-only 負例 `values[0] = Float32(99.0)` 被拒絕：`expression must be mutable in assignment`，沒有執行負例。

最終 **4 個不同 runtime cases 無警告通過**，另有預期的編譯拒絕。第一次 compile 因為
使用舊式 `@parameter` closure 搭配 runtime parallelize 而失敗，已保存原 source／
log，改成 repository 現用 explicit capture 語法後通過。首次成功但含 warning、
未注入等待的版本也保留，不與最終四案例重複加總。先前 raising getter 及改成 non-raising 後含不可達
except warning 的版本也保留；最終移除不再需要的例外處理。TestSuite 顯示時間為 ms。

這個 probe 沒有測 Linux、實際 segment lease、corruption／recovery、Arrow、
其他 scalar types 或 nonresident performance。Mojo 1.0 的 explicit-close／borrow
限制仍適用，不能只靠 origin annotation 取代 operation owner，見
[ADR 0007](../adr/0007-generation-field-ownership.md#leases-close-and-typed-borrows)。
下一步是按 [所有權實作計畫](../plans/2026-10-13-mapped-numeric-ownership.md) 接入並驗證。

查證從 [官方索引](https://mojolang.org/llms.txt) 開始；live index 已為 1.1.0，
因此使用 [Mojo 1.0.0 ArcPointer 原始碼](https://github.com/modular/modular/blob/mojo/v1.0.0/mojo/stdlib/std/memory/arc_pointer.mojo)
核對 subscripting 回傳 mutable pointee reference，且不提供 pointee 的並行同步。
同步仍由 probe 的 lock 負責。未套用較新版本的 API。

重跑：

```sh
rtk proxy pixi run mojo run --target-accelerator=metal:4 --target-cpu=apple-m4 -I src docs/research/2026-10-13-mapped-list-probe.mojo
```

[凍結紀錄](2026-10-13-mapped-list-probe.json.gz) 保存初次失敗、所有中間及最終
來源與 logs、負例、drivers、120-file source hashes、官方來源 URL／hash 與 scope。
Archive SHA-256：`2d8969ab7587aa139917d51d67f221b1ba6cee81e14e4c2dda0a0c001b351c9c`
（26 files，13,178 bytes）。
