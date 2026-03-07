# TODO

## 使用方式（VS Code）

- 在此檔用 `- [ ]` / `- [x]` 管理任務
- 每天只把 1~3 件放到 **Today (Now)**
- 任務建議格式：`[範圍][P1|P2|P3] 動詞 + 產出（驗收條件）`

範例：
- `- [ ] [webapp][P1] 修正登入導向（驗收：未登入訪問 /users 會導到 /login）`

---

## Today (Now)

- [x] [webapp][P1] 測試報告整批下載（依 reports 篩選後可見項目打包下載，驗收：僅下載目前篩選結果） ✅ 已完成（新增篩選結果整批 ZIP 與 100 筆上限提示）
- [x] [auth][P1] 非 Admin 禁止覆蓋他人上傳的 JMX / Dataset（驗收：非本人覆蓋回應 403） ✅ 已完成（以上傳者紀錄做覆蓋限制）
- [ ] [webapp][P2] 將 JMX 上傳與 `.env` / `report-meta.env` 編輯分頁（驗收：頁面與權限可分開控管）

## Next (This Week)

- [x] [logs][P2] 優化 JMeter Slave Pod Logs 顯示（驗收：可讀性提升，查找單一 pod 更快） ✅ 已完成（左側 Pod 清單 + 搜尋 + 只看異常）
- [x] [auth][P3] 評估新增 Viewer 群組（驗收：權限矩陣與影響範圍文件化） ✅ 已完成（Viewer 僅允許 Reports/Logs）

## Later (Backlog)

- [ ] [report][P3] 報告批次下載加入檔名規則與大小限制評估（驗收：規則文件化）
- [ ] [ux][P3] Logs 頁面後續優化提案（驗收：列出 2~3 個低風險改善項）
- [ ] [webapp][P1] db-restore（目前模擬）待還原 API ready 後改為真實呼叫（驗收：四種操作可實際呼叫、顯示成功/失敗、保留 preview 模式開關）
- [ ] [security][P1] db_restore_tokens.json 改為 K8s Secret 掛載（驗收：repo 無明文 token，webapp 可正常讀取）
- [ ] 
---

## Done (Keep short)

- [x] [example][P2] 建立 TODO 模板（驗收：團隊可直接沿用）

---

## 週回顧（Weekly Review）

- 本週完成：
- 卡住事項（Blockers）：
- 下週 Top 3：
