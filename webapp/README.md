# JMeter Web Console

這是 FastAPI + Jinja2 的Jmeter in K8S分佈式壓測管理平台，提供：

- [1) 透過網頁啟停 JMeter 分佈式測試](#1-測試驅動)
- [2) 資料庫還原（API 預覽與 Oracle Flashback）](#2-資料庫還原)
- [3) 管理 Helm 環境 values 與 jmeter config](#3-設定管理)
- [4) 管理專案 `.env` / `report-meta.env` / `jmeter-system.properties` 與上傳 JMX](#4-專案管理)
- [5) 上傳 dataset CSV](#5-dataset)
- [6) 管理 JMeter Fragment 模組](#6-管理模組)
- [7) 瀏覽並下載報告（單份 ZIP 或依篩選條件整批 ZIP）](#7-報告)
- [8) 檢視測試執行與 JMeter Master/Slave Pod Log](#8-logs)
- [9) 網站登入與使用者/群組管理](#9-使用者管理)

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
kubectl apply -f k8s/helm/environments/resources/lab/webapp-bootstrap-admin-secret.yaml
```

dr-prod 可用：

```bash
kubectl -n performance-test apply -f k8s/helm/environments/resources/dr-prod/webapp-bootstrap-admin-secret.yaml
```

若要啟用 Logs 頁面的 JMeter log 忽略規則，也請在 Helm 部署前先建立對應的 `ConfigMap`：

```bash
kubectl apply -f k8s/helm/environments/resources/lab/webapp-log-filter-configmap.yaml
```

dr-prod 可用：

```bash
kubectl -n performance-test apply -f k8s/helm/environments/resources/dr-prod/webapp-log-filter-configmap.yaml
```

> 因為 webapp deployment 會透過 `envFrom.configMapRef` 讀取 `jmeter-webapp-log-filter`，若先 `helm upgrade`、但 `ConfigMap` 尚未存在，Pod 建立時可能失敗。

部署（lab）範例：

```bash
helm dependency build k8s/helm
helm upgrade --install perf-stack k8s/helm \
        -n performance-test --create-namespace \
        -f k8s/helm/environments/values/lab.yaml
```

> 每次你有修改 `k8s/helm/charts/*` 子 chart（例如 webapp template / values）後，請先執行 `helm dependency build k8s/helm` 再 `helm upgrade`，避免實際部署仍套用舊版子 chart 內容。

若之後只是調整忽略規則內容，而沒有修改 Helm chart / template，通常不需要再做 `helm upgrade`，只要：

```bash
kubectl apply -f k8s/helm/environments/resources/lab/webapp-log-filter-configmap.yaml
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

## Webapp 功能說明

### 1) 測試驅動

- 選擇專案、Helm 環境與 release，啟動或停止 JMeter 分佈式測試。
- 可選擇同步 CSV、Module 與產生測試報告。
- 顯示背景程序、Master/Slave Job、Pod 與執行時間等狀態，並定期自動更新。

### 2) 資料庫還原

- 由環境設定列出可用的資料庫還原操作。

#### 2.1 資料庫還原 API（尚未實作）

> **目前狀態：僅模擬送出，功能頁面暫時隱藏，不會真的呼叫對接服務。**

此功能預計透過外部 API 執行資料庫還原工作，目前只會預覽即將送出的請求內容：

- 頁面路徑：`/db-restore`
- 可選環境來源：`config/jmeter.<env>.env`
- API 端點設定：各環境檔的 `JMETER_FLASHBACK_DB_API=<endpoint-url>`
- API Token：`webapp/data/secrets/db_restore_tokens.json`

預計支援的操作：

1. 建立 Flashback 任務
2. 查詢任務狀態
3. 查詢所有任務
4. 取消任務

Token 檔案範例：

```json
{
    "lab": "your-lab-token",
    "dr-prod": "your-dr-prod-token"
}
```

#### 2.2 Oracle Flashback 資料庫還原（目前已實作）

Webapp 目前可透過 SSH 連接 Oracle 伺服器，執行以下五項還原操作：

1. **建立還原點**（`create_rp.sh`）：為 PDB 建立 Oracle Flashback 還原點
2. **查詢還原點**（`current_rp.sh`）：列出指定 PDB 的所有可用還原點
3. **刪除還原點**（`delete_rp.sh`）：刪除指定 PDB 的還原點
4. **查詢還原進度**（`fb_process.sh`）：查詢 Oracle 是否正在執行 Flashback Restore
5. **執行還原**（`restore_rp.sh`）：將 PDB 還原到指定的還原點

##### SSH 連接配置

SSH 連接設定透過 Kubernetes Secret 管理。LAB 與 DR-Prod 環境各需建立一份 Secret。

**LAB 環境：**

```bash
kubectl -n performance-test apply -f k8s/helm/environments/resources/lab/oracle-flashback-secret.yaml
```

或手動建立：

```bash
kubectl -n performance-test create secret generic oracle-flashback-ssh \
    --from-literal=host=10.1.36.31 \
    --from-literal=port=22 \
    --from-literal=username=oracle \
    --from-literal=password=<YOUR_PASSWORD> \
    --from-literal=script_path=/home/oracle/scripts
```

**DR-Prod 環境：**

```bash
kubectl -n performance-test apply -f k8s/helm/environments/resources/dr-prod/oracle-flashback-secret.yaml
```

若部署至第二個 namespace：

```bash
kubectl -n performance-test2 apply -f k8s/helm/environments/resources/dr-prod/oracle-flashback-secret.yaml
```

##### 前置要求

1. 遠端 Oracle 伺服器的 `/home/oracle/scripts` 目錄中需存放以下 shell scripts：
     - `create_rp.sh`
     - `current_rp.sh`
     - `delete_rp.sh`
     - `fb_process.sh`
     - `restore_rp.sh`
2. Webapp 需要 `paramiko` 套件建立 SSH 連線（已列於 `webapp/requirements.txt`）。
3. Oracle 帳號必須具備執行 SQL Plus 及管理 restore points 的權限。

##### 使用方式

1. 登入 Webapp 管理平台（`http://<webapp-host>/`）。
2. 點擊導航列的「資料庫還原」。
3. 選擇環境（LAB 或 DR-Prod）。
4. 輸入 PDB 名稱（例如 `CDBC1`）。
5. 依需求執行建立、查詢、刪除還原點、查詢還原進度或執行還原。

執行還原前請確認還原點與 PDB 名稱正確；此操作會關閉 PDB 並執行 Flashback Restore。

##### API 端點

| 操作 | 方法 | 端點 | 說明 |
|------|------|------|------|
| 建立還原點 | POST | `/api/oracle-flashback/create-rp` | 建立新的還原點 |
| 查詢還原點 | POST | `/api/oracle-flashback/list-rp` | 列出可用的還原點 |
| 刪除還原點 | POST | `/api/oracle-flashback/delete-rp` | 刪除指定還原點 |
| 查詢進度 | POST | `/api/oracle-flashback/check-process` | 檢查還原進度狀態 |
| 執行還原 | POST | `/api/oracle-flashback/restore-rp` | 執行 Flashback Restore |

##### 請求參數

所有 API 端點都使用 `application/x-www-form-urlencoded` 格式：

| 參數 | 必需 | 說明 |
|------|------|------|
| `env` | 是 | 環境名稱（`lab` 或 `dr-prod`） |
| `pdb_name` | 是 | PDB 名稱 |
| `restore_point` | 部分 | 建立、刪除及執行還原時必需 |

##### 響應格式

API 會回傳 JSON：

```json
{
    "ok": true,
    "env": "lab",
    "pdb": "CDBC1",
    "restore_point": "RP_20260327_153000",
    "output": "...",
    "error": "",
    "exit_code": 0
}
```

| 欄位 | 說明 |
|------|------|
| `ok` | 操作是否成功 |
| `env` | 使用的環境 |
| `pdb` | PDB 名稱 |
| `restore_point` | 還原點名稱（如果適用） |
| `output` | 命令執行的標準輸出 |
| `error` | 命令執行的錯誤輸出 |
| `exit_code` | Shell 命令的終止碼 |

##### 故障排查

- **連接失敗：** 檢查 Kubernetes Secret、網路連線、防火牆規則與 SSH 帳密。
- **腳本執行失敗：** 確認遠端 scripts 存在且具備執行權限，並檢查 API 回應的 `error` 與 `output`。
- **Oracle 權限問題：** 確認 Oracle 使用者可執行 SQL Plus、讀取 scripts 並管理 restore points。

##### 相關文件

- K8s Secret：`k8s/helm/environments/resources/lab/oracle-flashback-secret.yaml`、`k8s/helm/environments/resources/dr-prod/oracle-flashback-secret.yaml`
- Service：`webapp/app/services/oracle_flashback_service.py`
- API 路由：`webapp/app/routers/api.py`
- Web UI：`webapp/app/templates/oracle_flashback.html`

### 3) 設定管理

- 依環境讀取及編輯 Helm `values` 與 JMeter 設定檔。
- 提供內容預覽、複製、下載與儲存功能。

### 4) 專案管理

- 建立及選擇 `scenario/<project>/` 專案。
- 上傳、下載 JMX，並編輯專案的 `.env`、`jmeter-system.properties` 與 `report-meta.env`。
- 建立新專案時，會優先從 `/workspace/scenario/_template` 複製模板；沒有模板時使用 webapp 內建的 fallback。

### 5) Dataset

- 依專案或篩選條件維護 CSV Dataset，提供上傳、檢視、重新整理與 ZIP 下載。
- 上傳既有檔案時，`Admin` 可覆蓋任意檔案；其他使用者只能覆蓋自己最初上傳的檔案，否則 API 回傳 `403`。
- 上傳者與最近編輯者記錄於 `webapp/data/upload_owners.json`。

### 6) 管理模組

- 維護共用的 JMeter JMX Fragment 模組，檔案存放於 `scenario/module/`。
- 支援上傳、確認覆蓋、檢視模組清單與重新整理，測試驅動頁可選擇同步使用 Module。

### 7) 報告

- 依專案及日期篩選、瀏覽與下載測試報告。
- 支援下載單份 ZIP 或目前篩選結果的批次 ZIP；單次最多下載 `100` 個報告。

### 8) Logs

- 查看 JMeter Master/Slave Pod Logs，並以 Pod 清單搭配單一 Pod 詳細內容進行排查。
- 支援 Pod 關鍵字搜尋及只顯示含 `ERROR`/`WARN` 的異常 Pod，清單也會顯示異常摘要。
- `WARN`、`INFO`、`ERROR` 忽略規則由 Kubernetes `ConfigMap` 注入；每行設定一個 pattern，更新後需重啟 `jmeter-webapp` Pod。

### 9) 使用者管理

- 管理登入帳號、群組與功能權限；帳號資料儲存在 `webapp/data/users.json`。
- 密碼以 PBKDF2-SHA256 加鹽雜湊儲存，不保存明碼。
- 群組權限：`Admin` 可使用全部功能；`Executor` 除使用者管理外皆可用；`Tester` 不可使用測試驅動；`Viewer` 僅可查看報告與 Logs。
- 首次部署若沒有帳號，需透過 `WEBAPP_BOOTSTRAP_ADMIN_USERNAME`、`WEBAPP_BOOTSTRAP_ADMIN_PASSWORD` 建立 bootstrap admin；群組可用 `WEBAPP_BOOTSTRAP_ADMIN_GROUP` 指定，預設為 `Admin`。
- 建議以 Kubernetes Secret 注入 bootstrap 帳密，且為避免 PVC 重建造成帳號遺失，應備份 `users.json`。
