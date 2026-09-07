# #46：Generation ownership 成本與落地邊界

2026-09-07；engine `234547a`，Apple M4 Pro／macOS、Mojo 1.0.0 (`ed45d567`)、
MAX 26.5.0。設計定案見 [ADR 0007](../adr/0007-generation-field-ownership.md)，
下一批切片見 [todo.md](../../tasks/todo.md)。本項交付設計、量測和可編譯 owner 探針，
**沒有把 shared generations、鎖外 compaction 或 scanner 實作進引擎**。

## Snapshot 實際成本

修正 `phase11_bench.mojo` 過時的 `ReadSnapshot.capture(dimension, ...)` 呼叫，改用
目前的 CollectionConfig 合約；保留原 snapshot／concurrent batch／maintenance cells。
新增固定 4,096 points × 128 F32、每點 256-byte string、2 sparse elements 的成本 cell。

資料在計時前以 MemTable/SparseIndex 建好，不含開庫／磁碟／compiler。每個 capture
前更新 0 或 16 points 的 dense、payload、sparse；固定 manifest G=7，每更新一點有
兩個 accepted operations。16-point cell 的 sequences 是 8,224、8,256…8,448，舊
snapshot 持續存活，逐份檢查其 sequence、dense、payload 與 sparse 值不受後續更新影響。

以 `snapshot_cost.py` 跑各 cell 三次新程序；Mojo 內 `ps` 取該 Mojo process 的 current
RSS，Python/measurement imports 先暖機。RSS 在建立資料後／持有全部 snapshots／
close handles／drop structs 各取一次，不在 capture timer 裡執行。

| 每 capture 更新點數 | 同時存活 snapshots | Capture 總計中位數 ms | 複製的 authoritative content MiB | Held RSS 增量中位數 MiB |
|---:|---:|---:|---:|---:|
| 0 | 1 | 2.863 | 3.094 | 5.438 |
| 16 | 1 | 2.756 | 3.094 | 5.438 |
| 0 | 8 | 20.866 | 24.750 | 38.906 |
| 16 | 8 | 20.029 | 24.750 | 38.938 |

Copy ledger 的 `authoritative_copy_bytes` 是已查證 capture clone 路徑所複製的 logical
field content：`4096 * (128*4 + 256 + 2*(8+4)) = 3,244,032 bytes/snapshot`。
它是根據實際 workload／clone 路徑計算的下限，不是 malloc instrumentation：不含
field names、SparseElement padding、Dict/capacity、額外 clone/metadata index/postings。
例如 SparseIndex.clone 目前會先 records() clone 再 upsert copy；metadata 也另複製
payload，均使總搬移量大於此數字。RSS 的測量則包含這些配置及 runtime/allocator。

0 delta repeated snapshots 仍各複製全量。16 個點只佔 0.39%，capture 成本仍相同量級。
這是 #47 共享 root 與 #48/#49 有界 head、分欄 owner 的優先依據，不是未來實作的加速承諾。

本次 close/drop 後 RSS 沒有明顯下降：目前 `ReadSnapshot.close` 只 release GPU state／
unpin／mark closed，owned MemTable/SparseIndex 要到 struct 析構才銷毀；析構後 allocator
也可能保留 pages。不能把未降低的 RSS 判定為 pin leak。Harness 確認 final pin count=0。
後續設計要求 snapshot close drop 自己的 root，而已取得的 export/operation 持獨立 owner。

完整 `pixi run bench-phase11` 通過，原 10,000×16 snapshot cell capture 116.9 ns/point，
exact search 202,000 ns；concurrent 64 mutations 和 background maintenance 正確性檢查通過。
完整進程前面會啟動其他 runtime/索引工作，後面 cell 的 RSS 帶有 allocator 歷史，因此
上表使用獨立程序的成本 cell；不把完整進程的數字當單份 snapshot retained heap。

```sh
pixi run bench-phase11
pixi run mojo build -I src benchmarks/mojo/phase11_bench.mojo -o .build/official-primitives-43-46/phase11-bench
pixi run python benchmarks/snapshot_cost.py --binary .build/official-primitives-43-46/phase11-bench --output docs/benchmarks/results/2026-09-07-snapshot-cost.json
```

[逐次原始數據](../benchmarks/results/2026-09-07-snapshot-cost.json)。固定原碼與 workload
可重現，但這只是本機資料量，沒有 extrapolate 為 production/Qdrant 效能。

## Mojo owner／borrow 編譯探針

[generation-owner-probe.mojo](2026-09-07-generation-owner-probe.mojo) 在鎖定工具鏈通過：

- List 移入 FrozenField/ArcPointer 後 data address 不變。
- Copy root/field handles 共享 base；新 delta buffer 也透過 move 保留指標。
- 不同 accepted sequence root 各自保存 delta list；舊 root 不見新 delta。
- 結束所有模擬 collection/snapshot root owners 後，輸出 field lease 仍能讀原值／原指標，
  且其強引用 count=1。同步 accessor 持有 operation owner，Span 不從 accessor 逃逸。

```sh
pixi run mojo run -I src docs/research/2026-09-07-generation-owner-probe.mojo
```

官方 [ArcPointer](https://mojolang.org/docs/std/memory/arc_pointer/ArcPointer/) 能共享
allocation，但不替 pointee 加鎖。唯讀借用使用 immutable helper 參數；不存造出的
UntrackedOrigin 裸 Span，也不自己實作引用計數。

額外 compile-only 反例顯示，Mojo 1.0 接受以下形式的「借用後主動 close／move」：

```mojo
# Counterexample only: do not execute.
# raw_span() returns Span[Float32, ImmOrigin(origin_of(self._owner.value()[].values))].
var borrowed = field.raw_span()
field.close()  # or: _ = field^
print(borrowed[0])
```

這兩個變體只執行 `mojo build`，均 exit 0，沒有執行可能已失效的指標。
因此 probe／ADR 不宣稱「加 origin 就能防止任何 use-after-close」。選定的介面只在
同步操作中使用 Span，每個操作或輸出另持 strong owner；C Data consumer 的真實
release state 負責 export owner，snapshot close 不會拿走那份 owner。這也與 #45
的同步 readonly PythonObject/NumPy borrow 邊界一致。

## 已定案與尚未實作

ADR 決定 immutable base + sealed runs + bounded mutable head descriptors、全點
shadowing、field owner、root/layout cache identity、strict generation compare-and-publish、
captured manifest backup、pin/retire、operation/export close，以及未來 dtype 的欄位界線。

#47–#58 拆出 shared snapshots、delta、metadata/sparse、close/GPU、compaction、worker、
backup、SQ8/PQ/HNSW lifecycle、直接 Arrow result 與 leased scanner。每項有依賴與失敗／
crash 驗收；#59 是提前建立的 Qdrant matched-recall 基線，#60/#61 官方 sort/heap，
#62 WAL borrowed decode，#63 fingerprint/existence owned-clone 清理。

Native scalar、named vectors、binary、multivector/MaxSim 仍需獨立 durable migration 與
write/read/search/reopen slices。沒有把本份設計當成支援所有向量型別或 Qdrant parity。
