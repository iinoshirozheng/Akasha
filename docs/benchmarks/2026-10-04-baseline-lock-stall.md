# 原基線鎖停滯：未重現，原因未解

接續 [payload buffer 實驗](2026-10-04-payload-buffer.md) 首輪原基線停滯。
該程序在 124.97 秒後被終止，main 與 maintenance worker 的 sample 都停在
`BlockingScopedLock.__enter__`。這次沒有改正式程式碼，也沒有足夠證據提出鎖修復。

## 實際驗證

| 範圍 | 結果 |
|---|---|
| 原 binary、100 個獨立 fresh-process／template-copy workers | 28,800 query audits、100 reopens、100 leases 通過 |
| 隔離 owner 診斷版、100 個相同 workers | 28,800 query audits、100 reopens、100 leases 通過 |
| 每組維護操作 | 3,200 write batches、3,200 flushes，固定 32-block mixed plan |
| 隔離診斷版 `test_background_publication.mojo` | 20/20 通過；包含發布衝突、close、背壓與錯誤路徑 |
| 原停滯資料庫的複本恢復 | 9 個 exact ID oracle 通過；另確認 last sequence = 9424 |
| 診斷事件 | 0 次 `LOCK_WAIT`、0 次 `LOCK_UNLOCK_FAILED` |

兩組使用原 uniform-128 plan、原 ef/filter/K、同一 trial-0 closed template；沒有改
正式效能矩陣。每個 worker 均驗證 binary／plan／workload／template identity。
這是重現診斷，時間不作 Qdrant parity 或效能改善的證據；後續成功不能抵銷原停滯。
這 200 次另列於先前的 13 次診斷，不宣稱跑過完整 regression suite。

## 診斷範圍與限制

讀取目前 writer／compaction／status／generation-pin 鎖路徑，尚未找到明確循環依賴。
鎖順序是 compaction → writer；status 方法不反向取得 writer；native worker 在呼叫
Mojo callback 前釋放自己的 pthread mutex。此查核不證明沒有其他交錯或 compiler 問題。

依 [Mojo 1.0 官方 lock 原始碼](https://raw.githubusercontent.com/modular/modular/mojo/v1.0.0/mojo/stdlib/std/utils/lock.mojo)，
scoped lock 以自身位址作 owner，exit 呼叫 unlock，但不處理解鎖回傳的 false。
隔離版保留單一 pointer layout、owner 計算與 atomic acquisition／release 協定，
只在 4,096 次 acquisition retry 時及 unlock 回傳 false 時印出 thread／lock／owner。
14 個模組改為匯入診斷型別；沒有將這個型別加入正式 source。
這只是用來觀察異常的假設，**未證明 stdlib lock 是原因**。

每個 worker 超過 20 秒才啟動 sample／LLDB／終止流程；這次沒有觸發。
只確認本機有 LLDB executable，沒有實際 attach 成功的證據。15 秒 Python
faulthandler 也未觸發。診斷版可能改變排程；未重現不代表不存在 race。

原資料庫未改寫；恢復只使用複本。序號 9424 與 template 的 9216 相差 208，符合
26 個 8-row batches；使用第 27 個 block 寫入前的 9 個 query oracle 核對。
最初序號小工具把 Python property 當成 callable，TypeError 後改正，兩份 log 保留。
初次診斷 build 重複指定 wrapper 已加入的 Metal accelerator 而失敗；移除重複旗標
後編譯成功，原失敗 log 也保留。沒有把這些 harness 錯誤算成引擎失敗或測試通過。

## 來源、產物與重現

正式 binding SHA-256 保持
`53f630ffba1e6e91f20e3abd6e13cc34475797cfd8fa5f0511ff8e61fb013eb6`。
診斷 binding 為
`ab3f410597eb9e26f269f01f0cee6752aa7af77a5bca75e46f555680d53d60d5`。
已逐檔核對正式 Mojo source 未改。環境 Mojo 1.0.0 (`ed45d567`)、Apple M4／Metal:4。

凍結 [text evidence archive](results/2026-10-04-baseline-lock-stall.json.gz)：
7,108,819 bytes、764 entries，SHA-256
`d6d6c5ab6ae29d24311c3ded50a7774ac0c289373798d9aabb9e89232ad4b8e4`。
解壓回讀每個 entry 的 SHA-256 已核對。包含 scripts、copied sources、全部 reports／
logs、原停滯 stack、官方 lock source 與診斷 identity；不包含 shared libraries。

暫存目錄 `.build/2026-10-04-baseline-lock-stall`。重現需另建輸出目錄及保留原 inputs，
以下 scripts 拒絕覆寫既有輸出，不應直接在已完成目錄盲跑：

```bash
rtk proxy pixi run python .build/2026-10-04-baseline-lock-stall/stress.py
rtk proxy pixi run python .build/2026-10-04-baseline-lock-stall/build-diagnostic.py
rtk proxy pixi run python .build/2026-10-04-baseline-lock-stall/diagnostic-stress.py
rtk proxy pixi run python .build/2026-10-04-baseline-lock-stall/summarize.py
```

保留此未解失敗及診斷工具；若再出現停滯，優先取得 owner／call stack 才修改鎖。
獨立進行已由 profile 指向的高維 segment 編碼成本驗證。M5/M6 checklist 維持未勾選，
Linux 持續 nonresident／memory-limit gate 仍缺 runner。
