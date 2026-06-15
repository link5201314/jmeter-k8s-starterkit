---
name: lab-webapp-redeploy
description: 'Build 與 push webapp image，然後部署或重新部署 lab 環境的 performance-test、performance-test2。當 prompt 提到 lab deployment、全新部署、既有 namespace 升版、webapp build and push、重新部署兩個 namespaces、rollout 驗證、保留 ingress hosts 時使用。'
argument-hint: '描述這次是全新 lab 部署，還是既有 namespaces 重新部署，以及目標 namespaces。'
user-invocable: true
---

# Lab Webapp 重新部署

當任務是 build 並 push webapp image，接著部署或重新部署 lab 環境的一個或多個 namespace 時，使用這份 skill。

## 適用範圍
- 環境：lab
- 常見 namespace：performance-test、performance-test2
- 部署入口：[deploy_perf_stack.sh](../../../deploy_perf_stack.sh)
- lab values：[k8s/helm/environments/values/lab.yaml](../../../k8s/helm/environments/values/lab.yaml)
- 操作參考：[references/lab-deploy-reference.md](./references/lab-deploy-reference.md)

## 依 Prompt 判斷模式

### 模式 A：全新部署 Full new deployment
如果 prompt 出現以下語意，使用這個模式：
- 全新部署
- 首次部署
- 新 namespace
- create namespace
- from scratch

處理方式：
- 預期會建立 namespace。
- 如果使用者沒有提供目標 namespace，就先詢問。
- 如果使用者沒有提供 host，則：
  - 從 `--base-domain` 推導，或請使用者提供明確 host。
- 在多 namespace 的 lab 部署中，第一個 namespace 使用 `--telegraf-cluster-rbac true`。
- 其他 namespace 使用 `--telegraf-cluster-rbac false`。
- `--apply-env-resources` 只適合第一次 bootstrap namespace，不適合日常升版。
- 除非使用者明確要求，否則保留 `--create-namespace`。

### 模式 B：部署既有 namespace Deploy existing namespace
如果 prompt 出現以下語意，使用這個模式：
- 重新部署
- 升版
- 更新既有 namespace
- redeploy existing namespace
- build & push 然後更新

處理方式：
- 如果 namespace 已存在，不要直接假設 values file 裡的 host 仍然正確。
- 先讀取目標 namespace 現有的 ingress hosts，再回填到部署參數。
- 除非 chart dependencies 有變動，否則預設使用 `--skip-dependency-build`。
- 除非使用者明確要求，否則不要用 `--apply-env-resources`。
- 在 lab 環境中，除非使用者明確要求，否則避免依賴 image pull secrets。
- 使用 deploy script 內建的 `--reset-values` 行為。

## 標準流程

1. 確認目標 namespaces。
2. 判斷這次是全新部署，還是既有 namespace 重新部署。
3. 如果是重新部署既有 namespace，部署前先讀取現有 ingress hosts。
4. 使用 Podman build 並 push webapp image。
5. 依序部署 namespaces：
   - 先 primary namespace，通常是 `performance-test`
   - 再 secondary namespace，通常是 `performance-test2`
6. 部署後驗證 rollout 與 ingress。

## Build 與 Push
- 優先使用 Podman，不使用 Docker，除非環境明確支援 Docker 且使用者要求。
- 產生帶時間戳記的 tag，例如 `YYYY.MM.DD-HHMMSS-short-suffix`。
- 除非使用者另有指定，標準 image repository 為 `docker.io/isaac0815/jmeter-webapp`。
- 從 repo root 使用 `webapp/Dockerfile` 進行 build。

## 部署規則
- lab 的 `performance-test` 使用 `--telegraf-cluster-rbac true`。
- lab 的 `performance-test2` 使用 `--telegraf-cluster-rbac false`。
- 重新部署時要重用目前的 ingress hosts。
- 使用 `--webapp-image-repository` 與 `--webapp-image-tag` 鎖定新的 image。
- 日常重新部署優先使用 `--skip-dependency-build`。

## 驗證清單
- `kubectl -n <ns> rollout status deploy/jmeter-webapp --timeout=180s`
- `kubectl -n <ns> get deploy jmeter-webapp -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'`
- `kubectl -n <ns> get ingress -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.rules[0].host}{"\n"}{end}'`
- 如果使用者要求兩個 namespaces，都要驗證。

## 回報內容
最後回報時要包含：
- push 上去的 image tag
- 部署了哪些 namespaces
- 這次是視為全新部署，還是既有 namespace 重新部署
- 每個 namespace 的 rollout 結果
- 每個 namespace 最終的 ingress hosts

## 安全注意事項
- 不要覆蓋不相關的 namespaces。
- 不要假設第二個 namespace 需要建立 cluster-scoped telegraf RBAC。
- 如果 prompt 無法明確判斷是全新部署還是重新部署，先檢查 namespace 是否已存在再決定。
- 如果 namespace 已存在，但使用者仍說要全新部署，要先確認他要的是全新 namespace 名稱，還是重建既有 namespace。
