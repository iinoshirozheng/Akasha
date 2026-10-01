# Commit／push／merge 交接

使用者 2026-10-02 明確要求：**「順便 commit ＆ push ＆ merge all to main」**。
這已授權 Git 交付；不需要再詢問是否可以執行。
本次範圍是 `feat/48-bounded-generation-head` 的既有 commits 與全部待交付修改，
包含交接文件。歷史 backup／未採用原型分支不因「all」而重新納入。

## 已確認狀態

| 項目 | 交接時狀態 |
|---|---|
| HEAD | `31f27e5e7f919d748f5e87ba3bdf600c387dac01` |
| Local main | `b0dd667`，在 `/Users/ray/Projects/Akasha`，工作目錄乾淨 |
| Origin | `https://github.com/iinoshirozheng/Akasha.git` |
| Branch upstream | 本地分支比本地儲存的 `origin/feat/48-bounded-generation-head` ahead 9 |
| 相對 local main | 本分支已有 22 commits 尚未在 local main |
| 尚未提交 | 大量 source/tests/docs/fixtures/results；包含刪除舊 competitor adapter |
| 新 staging／commit／push／merge | **均未完成** |

上述 remote-tracking refs 是本地紀錄，尚未 fresh fetch；不可當作遠端目前狀態。
本輪可讀 Git，不能写它：`git rev-parse --git-dir --git-common-dir` 指向
`/Users/ray/Projects/Akasha/.git/worktrees/production-hnsw-plan` 與
`/Users/ray/Projects/Akasha/.git`，均不在目前 sandbox 可寫根目錄。
先前 `index.lock` 建立已被拒絕；目前 approval policy 是 never。
沒有把舊 HEAD 單獨 push 冒充全部交付，也沒有嘗試 alternate index／另建 repo 繞過。

這是執行環境限制，不是使用者授權不足，也不是等待再次確認。
在可寫主專案 Git 目錄及可連線 GitHub 的環境接續以下步驟。

## 接續步驟

1. 讀 [測試交接](2026-10-02-status-and-tests.md) 與 `tasks/todo.md`，確認仍是本次產物。
   保留所有既有修改，不用 reset／clean／整批 checkout。
2. Fresh fetch、核對 remote/main 和分支是否有人更新，再檢查完整 diff、untracked
   files 與 fixtures/results。既有文件要求按語意工作包獨立提交；共同修改同一檔時，
   需用 hunk staging 或將緊密相依功能視為完整工作包，避免拆出無法運作的提交。
3. 將所有交付 source/tests/docs/fixtures/results 和本次 handoff 文件納入 commits。
   `.build`、`.pixi`、local binaries 留作本地產物，不 force-add。
   建議工作包：named/native end-to-end、storage/recovery、效能與 benchmark gate、
   交接文件；實際拆分以 diff 相依性為準。每批 staged diff 核對後才 commit。
4. Push feature branch。若遠端前進，整合實際改動並補跑受影響測試，不 force-push。
5. 在乾淨 main checkout 更新 main，再合併已推送的 feature branch，push main。
   若 branch protection 要 PR，使用正式 PR 路徑；不繞過保護規則。
6. 核對 remote main SHA 與 feature branch ancestry，記錄 commit／merge SHA。
   更新 task/todo 的 Git 交付狀態；**M5/M6 的性能失敗仍保留**，merge 不代表達標。

只讀核對命令（可在現在環境執行）：

```bash
rtk proxy git -c core.fsmonitor=false status --short
rtk proxy git -c core.fsmonitor=false diff --check
rtk proxy git -c core.fsmonitor=false branch -vv
rtk proxy git -c core.fsmonitor=false log --oneline main..HEAD
rtk proxy git -c core.fsmonitor=false -C /Users/ray/Projects/Akasha status --short
```

下列是**環境允許且所有變更已完成分批提交後**的交付命令。逐步檢查結果，不連成
忽略失敗的批次；若 main 有使用者修改，先保留並處理，不覆蓋。

```bash
rtk proxy git -c core.fsmonitor=false fetch origin
rtk proxy git -c core.fsmonitor=false push origin feat/48-bounded-generation-head
rtk proxy git -c core.fsmonitor=false -C /Users/ray/Projects/Akasha switch main
rtk proxy git -c core.fsmonitor=false -C /Users/ray/Projects/Akasha pull --ff-only origin main
rtk proxy git -c core.fsmonitor=false -C /Users/ray/Projects/Akasha merge --no-ff feat/48-bounded-generation-head -m 'Merge named/native vector implementation and performance work'
rtk proxy git -c core.fsmonitor=false -C /Users/ray/Projects/Akasha push origin main
rtk proxy git -c core.fsmonitor=false -C /Users/ray/Projects/Akasha merge-base --is-ancestor feat/48-bounded-generation-head main
rtk proxy git -c core.fsmonitor=false -C /Users/ray/Projects/Akasha rev-parse main
rtk proxy git -c core.fsmonitor=false ls-remote origin refs/heads/main
```

若因合併衝突或後續編輯改變已驗證內容，先修復、跑受影響 gate 並完成新的 commit，
再 push。既有未受影響測試可沿用，不要無理由重跑全部效能矩陣。
