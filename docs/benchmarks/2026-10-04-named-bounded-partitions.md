# Named bundle＋bounded partition scan：未採用（2026-10-04）

正式 engine `1318457` 與 production kernel 保持不變。候選版通過功能整合，並完成完整 named 生命週期；原矩陣 54 次嘗試中 53 完成、1 超時。候選不採用：重開首查大幅縮短，暖查詢仍有 35/36 格 QPS 退步，以及三個新增 fixed-ef recall 失敗。原矩陣另發生一次未修改 baseline 查詢超時，原因未解。**M5/M6 未完成**。

這不是「任何 A/B 退步就自動否決」的額外門檻。判斷依據是保留舊主圖後，全部 36 個共同 recall 格的 distance work 仍高於現行重建單圖，範圍 1.0285–1.8957 倍；有界小分區掃描不足以改善此架構的整體暖查詢成本與品質。

## 實作與驗證範圍

依[已定方案](../plans/2026-10-04-named-bounded-partitions.md)，把先前 kind-5/version-1 bundle 的七檔差異三方合併到最新 source，保留後續 close 修復、F64 四候選 rerank、checked visit、combined cache encoding 與 delta live/history policy。既有受檢查 scan 移到 HNSW owner，由 segmented delta 和 additional named partitions 共用；沒有移除每個候選的數值、身分或 admission 檢查。

主圖以第一個仍有 current members 的 partition 決定，與 query filter 無關。額外小分區使用原 live／physical／component／ef 限額。sealed/head 遮蔽列表合併時重複 ordinal 只計一次；全被遮蔽的分區可省略，重開前後路徑與候選預算一致。authority 格式不變，舊 kind-4 optional cache 明確失效，kind-5 維持 bounded decode、完整 membership/vector 驗證、atomic publish 與 busy-lock retry。這些更動僅在隔離 tree，正式格式文件未改。

| 驗證 | 結果 |
|---|---|
| Unique targeted Mojo | **230 passed** |
| Related crash | **11 passed**；checkpoint／backup publication |
| 完整 saved-package Python | **506 passed** |
| C ABI/client、重建 examples | 通過；3 examples |
| 子程序 compiler audit | 45 invocations；12 次 absolute/relative root include remap |

新增四項 test cases 包含 55 native authority／graph backend 組合、奇數維度、同分排序、660 組重開前後結果／工作量比較、220 組 full-budget exact checks，以及重疊遮蔽、零 current 的舊主圖、主圖 filter 全空。TestSuite 時間單位是毫秒。驗證不是新版完整 Mojo 或完整 crash suite。

## Named public 生命週期

三個原 corpora × 三個 trials × before/after，共 **18 serial workers**。保留原 seeds、filters、K、六個 efs、3 warmups＋64 samples、公開 binding 邊界、原更新／刪除、flush／close／首次與二次重開；沒有更動 gate 或重新挑樣本。

**28,944 ANN audits、4,824 exact oracle checks**。14,472 成對查詢中 9,483 組 IDs 相同，130,263 個 common-ID F64 score bits 相同；不同 IDs 及低 recall 全保留。每組候選更新後與 unchanged reopen 的 ID／bits／aggregate work 相同，第二次重開亦相同。九個 candidate cache 與原 bundle bytes 完全相同；14,472 個實際 public candidate queries 的 IDs／recall／distance counts 全符合先前 native hybrid 診斷，不把舊 native 時間加到本輪 public samples。

Fixed-ef quality **132→141/216**，候選保留 75 個低 recall 格；12 個改善、3 個新失敗。新失敗均為 uniform-128 independent／ef128，三個 trials 都是 **.95000→.94375**。以下列的是雙方皆過 .95 的首個原 ef，不取代這三個失敗，也沒有把提高 ef 當修復。

QPS ratio 是 candidate/baseline，越大越好；p95 ratio 越小越好。36 格中 **35 QPS 退步、33 p95 退步**，35 格至少一項退步。

| Corpus / filter | Ef | QPS ratios，trial 0 / 1 / 2 | p95 ratios，trial 0 / 1 / 2 |
|---|---:|---|---|
| uniform-128 / all | 128 | 0.8583 / 0.8146 / 0.8305 | 1.1079 / 1.2618 / 1.1734 |
| uniform-128 / correlated | 256 | 1.0398 / 0.8529 / 0.9424 | 0.8109 / 1.3180 / 1.1163 |
| uniform-128 / independent | 256 | 0.9473 / 0.9630 / 0.9962 | 1.0009 / 1.0520 / 1.1161 |
| uniform-128 / selective | 128 | 0.6640 / 0.9325 / 0.9531 | 1.6247 / 0.9468 / 0.9737 |
| uniform-1536 / all | 512 | 0.9257 / 0.9084 / 0.9101 | 1.0724 / 1.1015 / 1.1071 |
| uniform-1536 / correlated | 512 | 0.9866 / 0.9898 / 0.9840 | 1.0289 / 1.0329 / 1.0358 |
| uniform-1536 / independent | 512 | 0.9680 / 0.9619 / 0.9799 | 1.0275 / 1.0291 / 1.0065 |
| uniform-1536 / selective | 256 | 0.9920 / 0.9840 / 0.9241 | 1.0086 / 1.0018 / 1.1247 |
| real-1536 / all | 32 | 0.8627 / 0.8351 / 0.8636 | 1.1835 / 1.2210 / 1.1399 |
| real-1536 / correlated | 64 | 0.9006 / 0.8983 / 0.9175 | 1.1314 / 1.1493 / 1.0745 |
| real-1536 / independent | 64 | 0.9132 / 0.8820 / 0.9028 | 1.0814 / 1.1587 / 1.1195 |
| real-1536 / selective | 128 | 0.8557 / 0.7873 / 0.8137 | 1.2233 / 1.3663 / 1.3418 |

重開首查毫秒（依 trial 列出，before→after），不包含 open；warm QPS 已另列，不能互相抵銷：

| Corpus | trial 0 | trial 1 | trial 2 |
|---|---|---|---|
| uniform-128 | 6623.5→104.6 | 6596.8→103.8 | 6608.3→102.6 |
| uniform-1536 | 32697.4→364.8 | 32862.7→343.9 | 32718.8→343.7 |
| real-1536 | 17024.7→393.4 | 17114.4→405.5 | 17142.6→397.9 |

更新 flush 也有代價：uniform-128 約 24–25→89–98 ms；uniform-1536 約 64–70→243–254 ms；real-1536 約 59–98→294–302 ms。Cache 約由 5.95→6.81 MB、50.94→57.57 MB、50.91→57.53 MB。完整操作時間與各 trial 均在 archive。

## 原 Qdrant gate 與 baseline 超時

原 54 個 warm/mixed jobs **全部嘗試，53 完成、1 baseline 超時**。warm 完整完成；mixed uniform-128／trial2／before 在查詢停滯，20 秒 Python traceback 指向 `database._call` → `_search_raw` → `search`，40.0168 秒後被 runner 終止。沒有取得 native sample，不能宣稱已證明是先前 `BlockingScopedLock` 問題。

原 driver 在第 34 次嘗試退出；續跑只執行剩餘 20 jobs。失敗的 database、job、log 保留，沒有重跑替換。四個 baseline mode 缺結果，沒有虛構 recall 或延遲；A/B mixed 只有 32 格。Candidate 與 Qdrant 的 36 格均有完整結果。

| Boundary | baseline | candidate | recall |
|---|---|---|---|
| warm strict parity | 21/36 | 22/36 | 雙方各 36/36 |
| mixed strict parity | 24/32 已完成格；另 4 格缺失 | 27/36 | baseline 32 個已完成格全過；candidate 36/36 |
| write+flush strict parity | 4/8 已完成 trials；另 1 缺失 | 5/9 | 同固定 durability 邊界 |

**整體 FAILED**；assessment exit 1 是正確 gate 結果。Warm A/B 的 15/36 timing 退步、mixed 已完成 A/B 的 21/32 timing 退步都保留。Performance pass→fail：warm 的 uniform-1536 trial1 selective、real-1536 trial1 selective；mixed 的 uniform-128 trial0 selective、uniform-1536 trial0 selective、real-1536 trial2 correlated。缺失 baseline 格不列成改善。

Warm 的 2,412 paired query IDs／stats 與 24,120 F32 bits 相同；mixed 有效配對的 2,304 query IDs／stats 與 23,040 F32 bits 相同。全部成功 workers：warm 7,236 query audits／exact checks，mixed 7,488 query audits、26 reopens、17 Akasha lease checks。這些數字不包含超時 worker 未輸出的中間結果。

原失敗資料庫僅在複本恢復：template sequence 9216，恢復為 **9336**，對應 15 個完成的八點寫入 blocks；第 16 block 寫入前的 **9 個 exact oracle 全過**。原檔逐一 SHA 再核對未變。恢復成功不代表停滯已修復。[下一步取證方案](../plans/2026-10-04-query-stall-recurrence.md)先對未修改 binary 取得 native stack／操作位置，再決定修復。

## 失敗、凍結與重現

保留原 baseline multi-run cache miss 行為重現；新增測試先因 Int64 顯式轉型、不可複製 VectorValue／DocumentField 編譯失敗，修正後四項通過，原兩版 source/log/hash 留存。另保留 source-edit guard 在 field_ann 寫入前失敗的說明。第一次 timeout recovery helper 誤把 sequence 當作 info dict 欄位，KeyError、script、log、複本均保留；第二版從 verified template 複本讀取 property 後成功。

Production kernel：`eb3bebdea9ea4f9d8050d965af1625003d7aec9d841f02fbc9bf101c05f73945`。Candidate：`6eeadd2040243f4c42238b9834a0a7562944cf6662f6b14087aa6827cf3db609`。Worker 未改。環境 Mojo 1.0.0 (`ed45d567`)、Apple M4／Metal:4。候選從複製的 `after-src/bindings/python_module.mojo` 編譯；Python 用 import/SHA guard 與 `-o pythonpath=`；Metal wrapper 同時 remap absolute/relative source include。

[Immutable archive](results/2026-10-04-named-bounded-partitions.json.gz)：**909 text entries／9,699,734 bytes**，SHA-256 `a2f3e0a311b152e39488ecce944b1cb230db35a494b1dbc2a11d7f96a39724ae`。解壓逐 entry hash 全核對。包含兩版 source/package code、候選初版、全部新測試及失敗版本、build/test/worker logs、原始 jobs/queries/latencies/scores/stats、缺失狀態、recovery、來源與產物 hashes、決策及下一步方案；大型 binary/database/workload 由 hash 表示。

暫存 evidence `.build/2026-10-04-named-bounded-partitions` 已凍結，不能直接重跑會寫入它的 drivers。重現需還原到新目錄、沿用原 inputs 並核對 source/binary：`run_mojo.py` → `build.py` → `test.py after full` → `postvalidate.py` → `lifecycle.py`／`summarize.py` → `matrix.py`。所有 shell 以 `rtk` 開頭；benchmark 與 build/test/profile/compression 串行。`continue-matrix.py` 是此次既有 34-job checkpoint 的續跑紀錄，不是忽略任意 timeout 的一般 retry。

沒有新完整 Mojo/crash、HTTP performance、Linux、GPU、ASan、持續 nonresident 或受控 memory-limit 驗收；沒有可用 Linux runner。M5/M6 唯一 checklist 項目維持未勾選，這份未採用候選與資料恢復都不代表原任務完成。
