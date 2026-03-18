# JMeter Web Console (Prototype)

這是 FastAPI + Jinja2 的雛型管理平台，提供：

- 透過網頁啟停 JMeter 分佈式測試
- 管理 Helm 環境 values 與專案 jmeter-system.properties
- 管理專案 `.env` / `report-meta.env` 與上傳 JMX
- 上傳 dataset CSV
- 瀏覽並下載報告（單份 ZIP 或依篩選條件整批 ZIP）
- 資料庫還原工作（模擬送出 API 預覽）
- 網站登入與使用者/群組管理

## 報告批次下載

- 報告頁（`/reports`）提供「下載篩選結果 ZIP」按鈕
- 下載內容會依目前篩選條件（專案、開始日期、結束日期）決定
- 單次最多下載 `100` 個報告；若超過會提示：`最大單次下載100個報告，請調整篩選範圍`

## 檔案覆蓋權限（JMX / Dataset）

- 上傳者資訊記錄於 `webapp/data/upload_owners.json`
- `Admin` 可覆蓋任意既有 JMX / Dataset
- 非 `Admin` 只能覆蓋自己上傳的 JMX / Dataset
- 非 `Admin` 嘗試覆蓋他人檔案時，API 會回 `403`

## Logs 頁面（JMeter Pod Logs）UX 優化

- JMeter Master/Slave Pod Logs 改為「左側 Pod 清單 + 右側單一 Pod 詳細 log」
- 支援 Pod 關鍵字搜尋，快速定位特定 slave pod
- 支援「只看異常 Pod（ERROR/WARN）」切換，排障時可先聚焦異常節點
- Pod 清單提供異常摘要（E/W 計數）與狀態標記（正常/異常）
- `WARN / INFO / ERROR` 三組忽略規則已改由 Kubernetes `ConfigMap` 注入，不再寫死在前端模板內
- 對應設定檔：`k8s/helm/environments/lab.webapp-log-filter-configmap.yaml`、`k8s/helm/environments/dr-prod.webapp-log-filter-configmap.yaml`
- 可設定的 key：`WEBAPP_IGNORED_JMETER_WARN_PATTERNS`、`WEBAPP_IGNORED_JMETER_INFO_PATTERNS`、`WEBAPP_IGNORED_JMETER_ERROR_PATTERNS`
- 格式為「每行一條 pattern」；更新後需重新啟動 `jmeter-webapp` Pod 才會讀到新 env

## 帳號與權限

- 帳號資料儲存在 `webapp/data/users.json`
- 密碼欄位使用 PBKDF2-SHA256 加鹽雜湊儲存（不存明碼）
- 首次部署（`users.json` 不存在或為空）需提供 bootstrap admin：
    - `WEBAPP_BOOTSTRAP_ADMIN_USERNAME`
    - `WEBAPP_BOOTSTRAP_ADMIN_PASSWORD`
    - `WEBAPP_BOOTSTRAP_ADMIN_GROUP`（可省略，預設 `Admin`）

> 建議在 Kubernetes 使用 Secret 注入環境變數，不要把帳密寫在 image 或原始碼裡。

群組權限：

- `Admin`：可使用全部功能（含使用者管理）
- `Executor`：除使用者管理外，其餘功能可用
- `Tester`：不可使用使用者管理，且不可使用測試驅動
- `Viewer`：僅可使用 **報告（/reports）** 與 **Logs（/logs）**；不可使用測試驅動、資料庫還原、設定管理、專案管理、Dataset、使用者管理

## 技術選型

- Backend: FastAPI
- Frontend: Jinja2 + Bootstrap
- 架構: routers / services / templates 分層

## 專案結構

```text
webapp/
├── Dockerfile
├── requirements.txt
├── README.md
└── app/
    ├── main.py
    ├── core/
    │   └── config.py
    ├── routers/
    │   ├── ui.py
    │   └── api.py
    ├── services/
    │   ├── process_service.py
    │   ├── file_service.py
    │   ├── auth_service.py
    │   ├── db_restore_service.py
    │   └── report_service.py
    ├── templates/
    │   ├── base.html
    │   ├── index.html
    │   ├── tests.html
    │   ├── configs.html
    │   ├── projects.html
    │   ├── datasets.html
    │   ├── db_restore.html
    │   └── reports.html
    └── static/
        └── app.css
```

## 每個檔案用途

- `app/main.py`: FastAPI 入口與 router 掛載
- `app/core/config.py`: 專案路徑設定（scenario/config/report/start_test.sh）
- `app/routers/ui.py`: 每個工具頁面
- `app/routers/api.py`: 啟停、編輯、上傳、下載 API
- `app/services/process_service.py`: 背景執行 shell 腳本與狀態追蹤
- `app/services/file_service.py`: 安全檔案讀寫
- `app/services/auth_service.py`: 使用者檔案儲存、密碼雜湊驗證與群組權限
- `app/services/db_restore_service.py`: 還原 API 目標端點讀取與請求預覽組裝
- `app/services/report_service.py`: 報告列舉與 ZIP 打包
- `app/templates/*`: UI 頁面
- `app/static/app.css`: 基本樣式
- `Dockerfile`: 容器化（內建 kubectl/helm）
- `requirements.txt`: Python 套件

## 資料庫還原頁面（模擬送出）

- 頁面路徑：`/db-restore`
- 依 `config/jmeter.<env>.env` 自動列出可選環境
- 每個按鈕都只顯示「將發送的 API 內容」，不會真的呼叫對接服務

按鈕功能：

1. 建立 Flashback 任務
2. 查詢任務狀態
3. 查詢所有任務
4. 取消任務

環境檔需設定：

- `JMETER_FLASHBACK_DB_API=<endpoint-url>`

API Key / Token 存放位置（已加到 `.gitignore`）：

- `webapp/data/secrets/db_restore_tokens.json`

範例：

```json
{
    "lab": "your-lab-token",
    "dr-prod": "your-dr-prod-token"
}
```

## 本機啟動

在 repo 根目錄執行：

```bash
python3.12 -m venv .venv312
source .venv312/bin/activate
pip install -r webapp/requirements.txt
uvicorn webapp.app.main:app --reload --host 0.0.0.0 --port 8080
```

開啟：`http://localhost:8080`

也可以使用 Makefile（在 repo 根目錄）：

```bash
make webapp-dev
```

常用目標：

- `make install`：預設建立 `.venv312` 並安裝依賴（若系統有 `python3.12` 會優先使用）
- `make webapp-run`：啟動 webapp（非 reload）
- `make webapp-dev`：啟動 webapp（含 reload）
- `make check`：做基本語法檢查

### Makefile 用途（補充）

`Makefile` 的角色是把「常用且固定的操作流程」封裝成簡短指令，避免每次手動輸入長命令。

除了開發啟動，也包含 image 流程相關目標：

- `make webapp-image-build`：用 Podman 建立 webapp image
- `make webapp-image-load-k3s`：把 image 匯入 k3s/containerd
- `make webapp-image-build-load-k3s`：先 build 再匯入（兩步驟合併）

可用變數覆寫預設值（臨時指定，不需改 `Makefile`）：

```bash
# 指定不同 venv 路徑
make install VENV_DIR=.venv

# 指定 image 名稱（含 registry/repo/tag）
make webapp-image-build WEBAPP_IMAGE=docker.io/isaac0815/jmeter-webapp:latest

# 指定匯出 tar 位置
make webapp-image-load-k3s WEBAPP_IMAGE_TAR=/tmp/my-webapp.tar
```

若想快速查看有哪些目標，建議直接閱讀 repo 根目錄 `Makefile`。

## Docker 啟動

在 repo 根目錄執行：

```bash
docker build -f webapp/Dockerfile -t jmeter-webapp:prototype .
docker run --rm -p 8080:8080 jmeter-webapp:prototype
```

## Kubernetes（Helm 管理）

webapp 現在由 umbrella chart 管理（`k8s/helm/charts/webapp`），不再使用 `k8s/webapp-*.yaml`。

### A. 打包 image 並 push 到 Docker Hub

以下以 `docker.io/isaac0815/jmeter-webapp:latest` 為例：

```bash
podman build -f webapp/Dockerfile -t docker.io/isaac0815/jmeter-webapp:latest .
podman push docker.io/isaac0815/jmeter-webapp:latest
```

> 若尚未登入 Docker Hub：先執行 `podman login docker.io`

### B. 驗證遠端 digest（Docker Hub）

```bash
skopeo inspect docker://docker.io/isaac0815/jmeter-webapp:latest | sed -n '1,20p'
```

輸出中的 `Digest` 會是這次 `latest` 的遠端實際 digest，例如：

```text
"Digest": "sha256:xxxxxxxx..."
```

### C. 啟動 / 更新 k8s（Helm）

首次部署（且 `webapp/data` PVC 是空的）請先建立 bootstrap admin Secret：

```bash
kubectl apply -f k8s/helm/environments/lab.webapp-bootstrap-admin-secret.yaml
```

dr-prod 可用：

```bash
kubectl -n performance-test apply -f k8s/helm/environments/dr-prod.webapp-bootstrap-admin-secret.yaml
```

若要啟用 Logs 頁面的 JMeter log 忽略規則，也請在 Helm 部署前先建立對應的 `ConfigMap`：

```bash
kubectl apply -f k8s/helm/environments/lab.webapp-log-filter-configmap.yaml
```

dr-prod 可用：

```bash
kubectl -n performance-test apply -f k8s/helm/environments/dr-prod.webapp-log-filter-configmap.yaml
```

> 因為 webapp deployment 會透過 `envFrom.configMapRef` 讀取 `jmeter-webapp-log-filter`，若先 `helm upgrade`、但 `ConfigMap` 尚未存在，Pod 建立時可能失敗。

部署（lab）範例：

```bash
helm dependency build k8s/helm
helm upgrade --install perf-stack k8s/helm \
        -n performance-test --create-namespace \
        -f k8s/helm/environments/lab.yaml
```

> 每次你有修改 `k8s/helm/charts/*` 子 chart（例如 webapp template / values）後，請先執行 `helm dependency build k8s/helm` 再 `helm upgrade`，避免實際部署仍套用舊版子 chart 內容。

若之後只是調整忽略規則內容，而沒有修改 Helm chart / template，通常不需要再做 `helm upgrade`，只要：

```bash
kubectl apply -f k8s/helm/environments/lab.webapp-log-filter-configmap.yaml
kubectl -n performance-test rollout restart deploy/jmeter-webapp
kubectl -n performance-test rollout status deploy/jmeter-webapp --timeout=240s
```

也就是說：

- **首次導入機制**：先 `apply Secret` → `apply ConfigMap` → `helm upgrade --install`
- **只更新規則內容**：`apply ConfigMap` → `rollout restart`

若首次部署後 `scenario` PVC 為空，可把 repo 內既有資料拷貝到 webapp 掛載路徑：

```bash
# 1) 取得 webapp pod
WEBAPP_POD=$(kubectl -n performance-test get pod -l app=jmeter-webapp -o jsonpath='{.items[0].metadata.name}')

# 2) 建立目錄（若已存在可忽略）
kubectl -n performance-test exec "$WEBAPP_POD" -- mkdir -p /workspace/scenario/dataset

# 3) 拷貝單一 JMeter 專案目錄（例：demoweb）
kubectl -n performance-test cp scenario/demoweb "$WEBAPP_POD":/workspace/scenario/

# 4) 拷貝 JMeter 共用模組目錄目錄（例：module）
kubectl -n performance-test cp scenario/module "$WEBAPP_POD":/workspace/scenario/module

# 5) 拷貝單一 dataset 檔案（例：test-dataset.csv）
kubectl -n performance-test cp scenario/dataset/demoweb_login-user.csv "$WEBAPP_POD":/workspace/scenario/dataset/demoweb_login-user.csv

# 6) 驗證檔案已存在
kubectl -n performance-test exec "$WEBAPP_POD" -- ls -lah /workspace/scenario
kubectl -n performance-test exec "$WEBAPP_POD" -- ls -lah /workspace/scenario/dataset
```

若你要一次同步整個 `scenario` 目錄（包含多個專案與 dataset），可改用：

```bash
WEBAPP_POD=$(kubectl -n performance-test get pod -l app=jmeter-webapp -o jsonpath='{.items[0].metadata.name}')
kubectl -n performance-test cp scenario/. "$WEBAPP_POD":/workspace/scenario/
```

### 專案管理頁：建立新專案（含模板自動帶入）

在「專案管理」頁可直接輸入新專案名稱並建立。

建立成功時會自動建立 `scenario/<project>/`，並複製：

- `.env`
- `jmeter-system.properties`
- `report-meta.env`

模板來源優先序：

1. `/workspace/scenario/_template`（PVC 內模板）
2. `webapp/app/project_template_defaults`（webapp 內建 fallback）

建立完成後，前端會立即切換到新專案，並自動讀取三個檔案到編輯器。

若你有在環境內新增帳號（例如 `test1`），建議在升版前先備份 `users.json`：

```bash
# 備份 users.json 到本機
WEBAPP_POD=$(kubectl -n performance-test get pod -l app=jmeter-webapp -o jsonpath='{.items[0].metadata.name}')
kubectl -n performance-test cp "$WEBAPP_POD":/workspace/webapp/data/users.json ./users.backup.json
```

若因 PVC 重建或設定異動導致帳號遺失，可回寫：

```bash
WEBAPP_POD=$(kubectl -n performance-test get pod -l app=jmeter-webapp -o jsonpath='{.items[0].metadata.name}')
kubectl -n performance-test cp ./users.backup.json "$WEBAPP_POD":/workspace/webapp/data/users.json
kubectl -n performance-test rollout restart deploy/jmeter-webapp
kubectl -n performance-test rollout status deploy/jmeter-webapp --timeout=240s
```

> 若 `webapp/data` PVC 被刪除重建，舊 `users.json` 不會保留；此時沒有備份就只能用 bootstrap admin 重新建立帳號。

如果你只要讓 webapp 重新拉取新版 `latest`，可直接重啟 deployment：

```bash
kubectl -n performance-test rollout restart deploy/jmeter-webapp
kubectl -n performance-test rollout status deploy/jmeter-webapp --timeout=240s
```

### D. 驗證 k8s 正在跑的 digest

```bash
kubectl -n performance-test get pod -l app=jmeter-webapp \
    -o jsonpath='{.items[0].metadata.name}{"\n"}{.items[0].spec.containers[0].image}{"\n"}{.items[0].status.containerStatuses[0].imageID}{"\n"}'
```

`imageID` 會顯示實際執行中的 digest（`@sha256:...`）。
請確認它與上一步 `skopeo inspect` 的 `Digest` 一致。

### E. 建議：避免 `latest` 漂移

- 若要保證版本不可變，建議在 values 使用固定 tag 或直接用 digest pinning。
- 若持續使用 `latest`，建議設定 `pullPolicy: Always`，並在每次 push 後執行 `rollout restart`。

> 重要：`jmeter-webapp` 必須掛載與 JMeter master 相同的 PVC（`jmeter-data-dir-pvc`）到 `/workspace/report`，否則網站看不到剛產生的報告。

此外，webapp 另外使用兩個持久化掛載：

- `/workspace/scenario`：保存 Scenario/JMX/Dataset
- `/workspace/webapp/data`：保存 `users.json`、`upload_owners.json`、`secrets/`

如此可避免重建 image 或 rollout 時覆蓋環境內既有資料。

若你的叢集是 `containerd`（例如 k3s），建議用以下流程（Podman build 後匯入 containerd）：

```bash
podman build -f webapp/Dockerfile -t jmeter-webapp:latest .
podman save -o /tmp/jmeter-webapp_latest.tar jmeter-webapp:latest
sudo ctr -n k8s.io images import /tmp/jmeter-webapp_latest.tar
```

或使用 Makefile 一鍵完成：

```bash
make webapp-image-build-load-k3s
```

若你已把 image push 到 registry，可在環境 values 設定：

```yaml
webapp:
    image:
        repository: docker.io/isaac0815/jmeter-webapp
        tag: "latest"
        pullPolicy: IfNotPresent
```

也可分步執行：

```bash
make webapp-image-build
make webapp-image-load-k3s
```

> 若只匯入單一節點，請將 webapp pod 固定排程到該節點，或改為推到 registry 讓所有節點可拉取。

> 提醒：prototype 階段先使用 namespace 內最小權限。若要升級成正式版，再補強認證、審計、操作白名單與審批流程。

## 常見問題排查（Troubleshooting）

### 1) 網站看起來卡住 / 功能和預期不一致

先確認目前連到的是哪個 webapp 進程：

```bash
pgrep -af 'uvicorn webapp.app.main:app'
curl -s http://127.0.0.1:8080/openapi.json | head -n 40
```

若 `openapi` 沒看到你剛新增的路由（例如 `/login`、`/users`），通常是舊進程還在跑。重啟後再測：

```bash
pkill -f 'uvicorn webapp.app.main:app'
.venv312/bin/python -m uvicorn webapp.app.main:app --host 0.0.0.0 --port 8080
```

### 2) push 完 image，但 k8s 還是舊版本

請依序確認三件事：

1. Docker Hub 遠端 digest（`skopeo inspect`）
2. deployment rollout 已完成（`kubectl rollout status`）
3. pod `imageID` 是否等於遠端 digest

若不一致，先執行：

```bash
kubectl -n performance-test rollout restart deploy/jmeter-webapp
kubectl -n performance-test rollout status deploy/jmeter-webapp --timeout=240s
```

### 3) 查不到 webapp pod（selector 為空）

不同 chart 的 label 可能不同，建議先列出 pod 再決定 selector：

```bash
kubectl -n performance-test get pods -o wide | grep -E 'jmeter-webapp|webapp'
```

常見 selector：

- `-l app=jmeter-webapp`
- `-l app.kubernetes.io/name=webapp`

### 4) Session 相關錯誤（如缺少套件）

若啟動時出現 `itsdangerous` 相關錯誤，請重新安裝依賴：

```bash
.venv312/bin/pip install -r webapp/requirements.txt
```
