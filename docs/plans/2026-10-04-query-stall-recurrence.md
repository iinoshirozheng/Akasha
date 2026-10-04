# 查詢超時再次出現：先取證再修復

正式 engine `1318457`、kernel `eb3bebdea9ea4f9d8050d965af1625003d7aec9d841f02fbc9bf101c05f73945`。
在 named bounded-partition 候選的原矩陣中，未修改 baseline 的 uniform-128／trial2
mixed worker 查詢超過 40 秒；Python watchdog 在 20 秒記錄 `database._call` →
`_search_raw` → `search`，runner 隨後終止程序。沒有 native sample，不能直接認定
和[先前鎖停滯](../benchmarks/2026-10-04-baseline-lock-stall.md)同因。

原失敗 job／database／log 在
`.build/2026-10-04-named-bounded-partitions/matrix/mixed-uniform-128-2-before/`。
原資料庫保持不動；複本恢復為 sequence 9336，原 template 是 9216，對應已完成
15 個 8-point write blocks。第 16 個 block 寫入前的九個 exact oracle 全通過。
先前停滯停在 9424；不同序號不足以排除同一競爭問題。

先建立新的診斷目錄，重用目前 source、binary、原 template／plan／filters／efs／K，
全部核對 hash。不要修改已凍結 evidence 或重跑 failed acceptance worker 取代失敗。
完整記錄診斷 repeats，與原性能 cohort 分開；不能把未重現寫成已修復。

第一步用未修改 production binary 的 fresh-process／fresh-copy 重現，讓 worker
寫下自己的 PID 與 query／write／flush 的進入退出位置。診斷 logging 不算效能證據。
若超過原正常工作時間，先取得 native `/usr/bin/sample`，再有界嘗試 LLDB 的
all-thread backtrace／register／lock owner 觀察，最後才終止自己啟動的程序。
保留 timeout、attach 被拒或失敗、每個 repeat，以及原失敗資料庫的 recovery 證據。
不得在 benchmark 期間並行進行 profile、build、tests 或壓縮。

從實際阻塞 thread 與操作追查 writer／maintenance／publication／pin 鎖與 owner
生命週期；對照現在 compiler／官方 stdlib lock 原始碼。先前 100 baseline 加
100 owner-diagnostic repeats 沒有重現，不能原樣重跑後就宣稱問題消失。
只有 native 證據或可失敗測試支持時，才針對單一根因改動。若需要重接先前隔離
owner instrumentation，先比對最新 source，不把旧 source 整份覆蓋現行 engine。

修復後用原失敗條件、相關 close／maintenance／crash／Python 邊界驗證，並保留
最初失敗；回到原完整性能矩陣。M5/M6 checklist 保持未完成，Linux 持續 nonresident／
memory-limit 仍沒有可用 runner，不重新詢問或自行建立付費資源。
