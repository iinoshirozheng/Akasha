# Bounded Top-K admission 拆分：未採用

**在 machine-code gate 停止，未採用；没有新效能達標主張。** 正式引擎維持
`8ba04ce` 的 checked visit，M5/M6 仍未完成。本包只保留三項獨立 oracle 測試與
實驗證據，沒有更換正式 source、Python/C binaries 或 worker。

## 假設與結果

沿用 [frontier profile](2026-10-04-heap-shifts.md) 中 uniform-128 all 的結果：
BoundedTopK 占 main-thread samples 7.74%。該分母包含 Python/audit 工作，不是
query latency 的精確分解；本包核對相關 Top-K／collection／SIMD／MemTable 來源
未變。這格走 planned exact。

[方案](../plans/2026-10-04-topk-admission.md)只在隔離來源中拆開 `offer` 的原 admission
比較與 private insertion method；保留 append、sift、root replacement、capacity、
F32/F64、分數方向、ID ties、bounds checks 與 owner。不使用 inline annotations，
也不改 heap 演算法、快取 threshold 或增加 unsafe view。

Mojo 1.0.0 (`ed45d567`)／Apple M4／Metal:4 的 copied binding 成功編譯後，compiler
將新 insertion method 展回 `offer`。公開 exact caller 仍有四個靜態 offer 呼叫點：

| 整個編譯函式 | Before | Candidate |
|---|---:|---:|
| F32 offer 指令／bytes | 223／892 | 223／892 |
| F64 offer 指令／bytes | 219／876 | 219／876 |
| F32 offer 靜態 stores | 22 | 22 |
| F64 offer 靜態 stores | 24 | 24 |
| Exact caller 指令／bytes | 1,114／4,456 | 1,114／4,456 |

兩版 offer 的主要 stack allocation 仍是 `0x830`，另有相同 prologue saves。
沒有獨立 insertion symbol；拒絕候選仍進入原大小的函式。這些是靜態證據，包含
錯誤路徑，不能推論兩版 latency 必然相等。未達方案的擴測條件，因此沒有啟動
Qdrant／named curves，也沒有為了這個候選重跑完整整合。

## 正確性與失敗紀錄

兩版各 **8 targeted Mojo passed**：既有 Top-K 5 項，以及新增獨立 insertion-sorted
oracle 3 項。新測試保留於 `tests/mojo/test_topk_oracle.mojo`，沒有使用 production
comparator 或 heap 實作產生期待值。覆蓋兩種分數型別／方向、六種容量、滿／未滿、
拒絕／替換、負 ID、ties、signed zero、最大有限值、正負 infinity、重複 drain/reuse，
另核對相同 ID/score 與 NaN 的既有底層行為。這不代表公開向量 API 接受 NaN。

每版新 oracle 有 **18,528 offers／6,708 ID 與 score-bit comparisons／72 empty
drains**。正式來源另跑新增 3 項通過；不把重複執行加總成 unique tests。
TestSuite 時間為毫秒。初稿 generic scalar 轉型 compile errors 已保存，改用
comptime branch 內的 `rebind[Scalar[T]]` 後才取得上述成功結果。

第一次 assembly reader 在 build 結束前讀到複製的 baseline binary，該輸出已移至
`premature-assembly`，明確排除為候選證據。正式 reader 先要求 build exit 0，再核對
兩版 binary hashes，重新擷取的 disassembly 才用於上表。候選 binary 與 baseline
不同，不以早期讀到的相同 binary 冒充比較。

沒有新完整 Mojo／Python／crash／C ABI／examples／HTTP／Linux／GPU／ASan／
持續 nonresident 或 controlled-memory gate。最近正式性能仍是
[checked visit cohort](2026-10-04-visit-arguments.md)：warm 19/36、mixed 27/36、
write+flush 3/9，整體 FAILED；不與其他 cohort 合併。

## 凍結與重現

正式 kernel SHA-256：
`3ec07dc3c9711ccdb024311831a86c3ed844556c383f7b5de9dcbae535d893c1`。
未採用候選 SHA-256：
`f9cbf05048f8ee1c164b8f6913950eeb4dbcf17893aa5c51995b102a0ff345a0`。

[Frozen archive](results/2026-10-04-topk-admission.json.gz)：**304 entries／617,799
bytes**，SHA-256
`bc15b1d4e66bd3320cd494a23865a66ec55fe17f9d843d178ea0b109f56fb5ff`。
已解壓回讀所有 entry hashes，保存兩版來源、patch、build／tests／disassembly、
原始失敗、修正後 guards、commands 與 identities。Binaries 只記 SHA。
`.build/2026-10-04-topk-admission` 已凍結，不原地重跑 writing drivers。

可直接重跑正式 oracle：

```sh
rtk proxy pixi run env PATH="$PWD/.build/compiler-bin:$PWD/.pixi/envs/default/bin:$PATH" mojo run -I src tests/mojo/test_topk_oracle.mojo
```

下一步仍是原 ANN／selective 距離成本與 M5 更新後重開生命週期；本次不擴大
Top-K 改寫，也不重跑已否決的圖修復／分區快取方案。Linux runner 仍不可用。
