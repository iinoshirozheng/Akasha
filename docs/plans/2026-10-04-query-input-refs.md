# Named query／write input container 生命週期修復

基線 `fa9e092`，Mojo 1.0.0，Python 3.11；唯一 checklist 是
[tasks/todo.md](../../tasks/todo.md)。延續前一 compiled refs probe 的已知失敗。

22 個最初的 weakref regression cases 在正式 binary 全部失敗，涵蓋五種 scalar、
dense/multivector、list/ndarray 與兩種拒絕查詢。以現有 private vectorcall helper
執行相同 builtins.hasattr／isinstance predicates，保持 dtype callback、錯誤及
close reentry；移除對容器的一般 Python callable 呼叫。Helper 只在原模組改名，
沒有新層／fallback／public API。

新增寫入案例再定位 `_is_python_none` 的一般 `type(value)` 呼叫也保留輸入。
使用現有 PythonObject identity 比較 `value is Python.none()`，確保只有 None
代表移除，並阻止自訂 metaclass equality 把合法輸入當作 None。
保留原資料複製、批次 atomicity、score、durable format 與 engine 策略。

隔離 copied entry/includes/packages，先 red/green narrow，再完整 saved-package
Python；相對與絕對 source remap＋Metal wrapper PATH。通過後才安裝 source/kernel，
核對hash並重跑正式窄測試。保留所有失敗與binary/source identities。
本包是正確性修復，不作新Qdrant／速度／RSS／nonresident宣稱；既有性能失敗繼續
保留，適用成功證據沿用，沒有Linux runner。其餘一般Python callable的refs問題
須按最小probe逐一辨識，不能把這次改動當作全binding無洩漏。

結果：最終28 cases由baseline全失敗到candidate全通過；571完整隔離Python與
正式123 targeted通過。已採用，未重跑效能矩陣。
[實作、失敗、範圍與凍結證據](../research/2026-10-04-query-input-refs.md)。
