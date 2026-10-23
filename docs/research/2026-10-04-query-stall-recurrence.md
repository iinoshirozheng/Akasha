# 查詢停滯再現診斷與 native 取證

正式 engine `1318457`、source、Python kernel 與 native worker **未修改**。
原 mixed timeout 仍是失敗，原因未解；本工作包沒有新的性能達標主張，M5/M6 保持未完成。
原失敗與資料庫複本 recovery 見
[bounded named partitions 報告](../benchmarks/2026-10-04-named-bounded-partitions.md)，
本次按[取證方案](../plans/2026-10-04-query-stall-recurrence.md)執行。

## 原 binary 重現結果

保留原 template、plan、query/filter/K/ef 與 production binary hashes，各 worker
使用自己的資料庫複本。這是獨立診斷，不替換原矩陣的超時 trial，也不使用其 timings
宣稱速度改善。

| 診斷 | Workers | Query audits | Reopen exact oracle | Retained Arrow lease |
|---|---:|---:|---:|---:|
| 原 scheduling；一半記錄 Python 操作進出 | 30 | 8,640 | 30 | 30 |
| Flush 後 scheduling 擾動 | 24 | 6,912 | 24 | 24 |

24 個 scheduling workers 分為無 sleep、`sleep(0)`、10 µs、1 ms 四組，各六次；
每組一半記錄操作進出。全部完成，所有記錄的 enter/exit 配對，沒有 exception 或
未完成操作；**都沒有重現停滯**。這不能證明問題消失，也不合併成原 54-job 性能矩陣。

## Native 取證已在本機驗證

Mojo 1.0.0 (`ed45d567`)、Apple M4／Metal:4。獨立探針刻意把 lock counter 設為
`1234`，再等待同一把鎖。這個預期阻塞不是 Akasha 重現。

`sample` 與 LLDB 都成功取得資料並正常 detach。第一版驗證已知位址讀取；第二版
透過 all-thread stack frame 自動找 `BlockingScopedLock.__enter__`，讀出 guard、
counter 與 owner，均與探針寫出的位址和 `1234` 相符。

目前 production kernel 與探針的 generated assembly 都以 `x19` 保存 guard、
`x21` 保存 counter。`capture_locks.py` 先檢查該組語樣式，再解讀暫存器；不符合則
只保留原始 frames/registers。這是目前 compiler/binary 的事實，不是可移植 ABI。

版本相符的[官方 lock source](https://raw.githubusercontent.com/modular/modular/mojo/v1.0.0/mojo/stdlib/std/utils/lock.mojo)
使用 scoped guard 位址作 owner；enter/exit 已有 `@no_inline`，exit 忽略 unlock 的 Bool。
這些事實沒有證明 stdlib 或 compiler 是停滯原因。

另編譯獨立 native-worker 探針：兩個執行緒各執行一百萬次巢狀 writer/status context，
涵蓋 return、raise、break、continue。**200 萬次操作、50 萬次預期例外**的計數與
最終兩把鎖的 unlocked counter 都正確。這是單一 compiled probe，不是新增兩百萬項
測試，也沒有覆蓋整個 collection 或證明它沒有 race。

## 超時流程的四個控制案例

`owned_watchdog.py` 在原 deadline 到達時先寫下失敗，再取 native 證據，最後有界
終止自己啟動的程序。Worker 在量測區域外寫自己的 PID；supervisor 核對 process
group，避免把 RTK launcher 誤認為 Python worker，或 attach 到不屬於本次工作的程序。
sample／LLDB 本身亦有 deadline 與 cleanup。

四個案例全部通過：

1. 刻意阻塞探針保持 exit 124，native capture 正確讀出 owner `1234`。
2. Worker 在取證期間正常 exit 0，原 timeout 結果仍是 exit 124。
3. PID 指向 owned process group 以外，拒絕 capture 並清理自己啟動的 child。
4. Worker 在 deadline 前 exit 7，保留 exit 7，不啟動 timeout capture。

24 個 scheduling workers 已接入這個 supervisor；因沒有停滯，其 native capture
沒有觸發。不能把控制案例的成功當成取得了真實 Akasha 停滯的 lock owner。

## 查核範圍與後續

讀取 writer／maintenance status／compaction／pin／retirement 與 root destructor
路徑，尚未找到可證明的循環依賴。Native C worker 在呼叫 Mojo callback 前釋放
自己的 pthread mutex；status 方法不取得 writer；file lease 使用 nonblocking flock。
這些查核不能排除未觀測的 race、重入或 compiler/runtime 問題，故未猜測性改鎖。

本次未跑新的 Qdrant gate、完整 Mojo/Python/crash、C ABI、HTTP performance、Linux、
ASan、GPU、持續 nonresident 或 memory-limit gate。先前仍適用的結果沿用；沒有
Linux runner，不重新詢問或自行建立付費資源。

接續回到 production 失敗格的可量測成本；後續 worker 必須保留原 deadline，並接入
已驗證的 native capture。若再現，先看各 thread 的 counter/owner 與呼叫位置再改動。
不要原樣重複未重現迴圈，也不要把已否決 bundle／repair 原型再次當作新方案。

## 凍結證據與重現

OUT：`.build/2026-10-04-query-stall-recurrence`，**已凍結，不原地重跑 driver**。

[Archive](../benchmarks/results/2026-10-04-query-stall-recurrence.json.gz)：
542 text entries、3,109,934 bytes，逐項 embedded SHA-256 均已核對。
Archive SHA-256：
`6c5d965d6c56273325f203b7287d42d60389c57b7dc4e856892e555a923947af`。

Production kernel SHA-256：
`eb3bebdea9ea4f9d8050d965af1625003d7aec9d841f02fbc9bf101c05f73945`。
Worker SHA-256：
`bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6`。

Archive 保存完整 source/package 文字、identity、每次 worker report/audit/操作記錄、
兩個 probe source/build commands/logs、sample/LLDB 原始輸出、production lock 組語、
supervisor 及控制案例。資料庫與 native binaries 不嵌入，來源 identity/hashes 保留。

重現時先複製 `identity.json`、`mixed-bench.py`、drivers、capture helpers、probe sources
及 `baseline-src`／`baseline-python` 到新的 OUT，保留原 template/plan。不要複製既有
`runs`、`schedule-runs`、控制結果或 `frozen.json`。在 repository root 串行執行：

```sh
rtk proxy .pixi/envs/default/bin/python NEW_OUT/diagnose.py
rtk proxy .pixi/envs/default/bin/python NEW_OUT/schedule-diagnose.py
```

Probe build 按各 `*-build.json` 的 compiler/wrapper/PATH/flags，將輸入／輸出改成
NEW_OUT；完成兩個 build 後才執行 `run-contended.py`、`test-watchdog.py`。所有 shell
命令以 RTK 開頭，不與其他 benchmark/build/test/compression 重疊。
