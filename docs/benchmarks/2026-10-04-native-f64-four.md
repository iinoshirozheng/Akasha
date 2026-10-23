# Native dense F64 四候選 rerank

採用第二版：named ANN 最後的 native F64 rerank 每次處理四個候選，直接借用
read run 所持有的值；不足四個的尾端沿用 scalar 函式。兩個 engine 檔案變更，
沒有新配置或格式。第一版的 ordinal 暫存／重複 entry lookup 不採用。

這個工作包改善已量到的 native metric 成本，**M5/M6 仍未完成**。第二版原始
named 曲線有 7/36 選定格 QPS 或 p95 退步；原 Qdrant warm／mixed gates 仍
FAILED，不能跨格抵銷。採用局部優化不表示效能驗收完成。

## 實作與數值合約

起點 `f0572f5`，Mojo 1.0.0 (`ed45d567`)，Apple M4／Metal:4。
既有 profile 的高維 all 約 24.95% query samples 在 native F64 metric。
參考本地 Faiss `faiss/utils/simd_impl/distances_autovec-inl.h:96` 的四列獨立
accumulator 模式（reference HEAD `613e0acac507c7593ff14dee2c6204a83a539acb`）；
不採用它的 imprecise math 設定。

`field_metrics.mojo` 新 helper 以四個 F64 lanes 跨候選並行，每列仍按原 component
順序累加。支援 F32／F16／BF16／I8／U8 的 Dot／L2／cosine。保留各列維度、
zero-cosine 檢查與真正 owner；原 scalar helper 保留為尾端路徑及數值 oracle。
`field_ann.mojo` 保留每筆 control、visibility、field 檢查、候選次序、global budget、
Top-K tie semantics 與統計。HNSW 距離、圖 bytes、exact fallback、公開 schema
與持久化路徑不變。這與先前否決的 F32 prepared HNSW rerank 不同。

初版用 SIMD multiply/add 時，F32／dim2／seed5／L2／lane1 出現 1 ULP 差異：
`26.51136922792407` 對 `26.511369227924074`。保留的 assembly 顯示既有 scalar
累加使用 `fmadd`，初版 SIMD 分開 `fmul`／`fadd`。改用明確 `.fma` 後逐 bit 相同；
不是放寬比較精度。已核對 installed compiler 預設 `--fp-mode contract=fast`
與 [Mojo 1.0 SIMD API](https://mojolang.org/1.0.0/docs/std/builtin/simd/SIMD/)。
這是目前 M4 compiler 的證據，沒有新增 Linux／其他 CPU 浮點位元驗收。

先前的 Bool `.reduce_or()`、Int→SIMD lane 隱式轉型編譯失敗、zero-length 測試
fixture 被 constructor 拒絕，以及未 fused 版本的失敗／原碼／測試 hashes 均保留。

## 正確性與整合

第二版通過 **30 unique targeted Mojo、506 完整 Python、C ABI/client、3 個重建範例**。
Mojo 範圍為新 helper 3、named HNSW 6、field metrics 6、query control 2、field cache 9、
generation fields 3、field rerank 1。新 helper 有 **53,776 次 F64 bit 比較**，涵蓋
五型別、三 metric、14 dimensions、64 seeds、極值／cancellation／signed zero，
以及各 lane 的維度與 zero-cosine 錯誤。

另外 **5,400 組公開 API 成對查詢**的 IDs／F64 bits／全部 stats 完全相同：五型別、
三 metric、三 dimensions、filters、10 種含 batch/tail 的候選 budgets、initial/reopened。
原三 corpus／三 trial 的完整 named 曲線另有 **14,472 paired queries** 完全相同，
共 **28,944 ANN audits／4,824 exact checks**。fixed-ef 品質 **132→132/216**，
原有 84 個 low-recall 格全部保留，沒有新增或移除。

Saved-package pytest 使用 `-o pythonpath=`、Python 3.11、import path/hash guards，
child compiler 重導到 copied source 並繼承 Metal wrapper。採用時核對全部 source
hashes，複製已驗證 binary；正式路徑再通過 **3 Mojo／151 Python**、實際載入正式
C library 的 client 與三個範例。這些是重複檢查，不加總為更多 unique tests。

第一版為 17 targeted Mojo，並非第二版的完整整合。沒有新的完整 Mojo／crash／
HTTP performance／distributed／Linux／GPU／ASan／sustained nonresident 或
controlled memory-limit gate；既有完整 suite 僅對應其先前版本。Native worker 未改，
測試期間沒有覆寫。TestSuite 時間單位是毫秒，driver wall time 是秒。

## 原始 named 曲線

兩版各 18 serial workers，沿用相同原始 corpus／seed／filters／K／efs／trials，
以 byte-identical merged kind-4 graph 比較，trial 順序 AB／BA／AB。沒有 build、
test 或 compression 與 benchmark 重疊。下表為第二版各三個 trial 的完整範圍；
QPS ratio 大於 1 較快、p95 ratio 小於 1 較快，不能用範圍或中位數掩蓋失敗 trial。

| Corpus | Filter | Selected ef | QPS after/before | p95 after/before |
| --- | --- | ---: | ---: | ---: |
| uniform-128 | all | 128 | 1.125–1.174 | 0.785–0.878 |
| uniform-128 | correlated | 256 | 1.076–1.345 | 0.649–1.081 |
| uniform-128 | independent | 128 | 0.854–1.241 | 0.693–1.436 |
| uniform-128 | selective | 128 | 0.965–1.050 | 0.942–1.144 |
| uniform-1536 | all | 512 | 1.182–1.248 | 0.735–0.846 |
| uniform-1536 | correlated | 512 | 1.158–1.206 | 0.821–0.869 |
| uniform-1536 | independent | 512 | 1.136–1.164 | 0.844–0.893 |
| uniform-1536 | selective | 256 | 0.983–1.039 | 0.969–1.006 |
| real-1536 | all | 32 | 1.044–1.143 | 0.857–1.025 |
| real-1536 | correlated | 64 | 1.072–1.178 | 0.832–0.933 |
| real-1536 | independent | 64 | 1.078–1.241 | 0.758–0.958 |
| real-1536 | selective | 128 | 1.037–1.065 | 0.941–0.982 |

第一版有 9/36 選定 timing 退步，其中 uniform-128 selective 三次 QPS ratio
0.865–0.872。第二版消除 entry 的重複取得，剩 7/36 timing 退步；這兩次是獨立
cohorts，不將全部差異歸因於該修改。兩版所有固定格與原始慢 samples 都在 archive。

微量測三 metric ×128/1536D ×7 alternating pairs，**42 pairs／84 samples** 全部
checksum 相同，四列版本快 **2.165–2.473×**。這不是公開 API 或 Qdrant gate。

第一版另有六個 native sampling profiles、75,264 次重複結果／bits／stats audits：
F64 metric samples 在 u128 all 8.45→4.19%、u128 selective 4.66→2.51%、u1536 all
24.54→11.95%。u128 selective 仍以 HNSW 為主，mean thread CPU 556.66→588.93 μs。
因此不能把該格全部退步歸因於 rerank wrapper。核對該版 owned F32 search-layer
1,280 條指令，解析所有 PC-relative constants 後只差 debug source path 與長度。
這是單一 hot function 的證據，並非全 binary 相等或 timing 原因的證明。

## 原 default warm／mixed／write+flush：FAILED

第二版另完成 **54 serial workers** 的 before／after／Qdrant 原始 resident 矩陣。
順序 B/A/Q、Q/A/B、B/A/Q；使用原 efs、fresh cloned fixtures 與 service boundaries。

| Gate | 同一 cohort baseline | 採用版本 |
| --- | ---: | ---: |
| Warm matched recall ≥ .95 | 36/36 | 36/36 |
| Warm QPS 與 p95 strict parity | 18/36 | 20/36 |
| Mixed matched recall ≥ .95 | 36/36 | 36/36 |
| Mixed QPS 與 p95 strict parity | 24/36 | 23/36 |
| Mixed durable write+flush parity | 3/9 | 3/9 |

四個 performance pass→fail：warm real-1536/trial1/all；mixed uniform-1536/trial1/
selective、real-1536/trial1/correlated、real-1536/trial2/selective。A/B timing 退步為
warm 19/36、mixed 26/36，均保留。與其他日期或其他 cohort 的數量不可拼接。

Warm 有 7,236 三方 audits／7,236 exact checks，2,412 A/B IDs／stats 相同及
24,120 F32 bit 比較；mixed 有 7,776 三方 audits，2,592 A/B IDs／stats 相同及
25,920 bit 比較。全部 mixed workers 通過 reopen oracle、32 writes/flushes；
兩個 Akasha 版本的 Arrow lease 均跨 close 存活。Assessment **exit 1 是完整執行
後的 FAILED gate**，不是量測中止。任何改善都不能抵銷上述失敗。

## Artifacts 與重現

| Artifact | SHA-256 |
| --- | --- |
| 正式 Python kernel | `80ddc239bc711b5b5c52acc44e9f705825cabac31b4d646503597ba1aa3e2155` |
| 正式 C library | `a39abcd2abc3aea84e736aa4126f96bb856038792286b22fc0780019a137c92b` |
| 正式 C client | `ad1b7402586f852b4fb15b8cbaad4fe2d903bf883a3fd96b9dd99edf54ae4f55` |
| Worker（未改） | `bc064bc84fcc5dba1fba1f1f8bc1e7a19a3938dc88e24f865a6c4158fbffe0a6` |
| Baseline kernel | `780e8aaf3d7db9423251a4090fd069382d148d783451a91b6eb972893f5f74d6` |
| 第一版 kernel（未採用） | `188c91b69391a84b3fe45134bee09aaadc477fcb480e8a2560401d63547f2178` |

Immutable archives，gzip readback 與每個 embedded file hash 均已核對：

- [第一版、全部失敗、微量測、profile 與 assembly](results/2026-10-04-native-f64-four.json.gz)：
  932 entries／7,619,536 bytes；SHA `f7b9058aed8b9aca498666ddf4b287217f0cbfba5c52c12516566ee38e6870dd`。
- [第二版、完整 named 與原 Qdrant 矩陣、整合驗證](results/2026-10-04-native-f64-borrow.json.gz)：
  715 entries／24,449,510 bytes；SHA `bccad8c5e6f9349cf11d056abd878e9652f9de262bc2098a8d6e4ed1d58656ba`。
- [正式路徑採用檢查](results/2026-10-04-native-f64-promotion.json.gz)：
  11 entries／31,253 bytes；SHA `a6b25a6a5027bc6b1513840536d3eda29fb4b05af810c6bcf40d8db6286c0d2c`。

`.build/2026-10-04-native-f64-{four,borrow,promotion}` 是暫存；archives 保存原始碼、
tests、drivers、commands、logs、全部樣本與 identities。不要在這些目錄重跑會
覆寫產物的 driver。Isolated binding 必須由 copied source 的 binding 編譯。

正式三個新增 Mojo regressions：

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run --target-cpu=apple-m4 -I src tests/mojo/test_native_dense_four.mojo
```

原 Qdrant 報告重新 assessment（保留 FAILED／exit 1）：

```sh
rtk proxy env PYTHONPATH=.:.build/qdrant-compare/deps .pixi/envs/default/bin/python .build/2026-10-04-native-f64-borrow/summarize-matrix.py
```

後續以原失敗格的 HNSW 搜尋／候選 heap 實際成本和 named 更新生命週期繼續。
無 Linux runner；持續 nonresident／受控 memory-limit 仍未跑，不能勾選 M5/M6。
