# JMeter Web Console (Prototype)

這是 FastAPI + Jinja2 的雛型管理平台，提供：

- 透過網頁啟停 JMeter 分佈式測試
- 管理 Helm 環境 values 與專案 jmeter-system.properties
- 管理專案 `.env` / `report-meta.env` 與上傳 JMX
- 上傳 dataset CSV
- 瀏覽並下載報告（index 或 ZIP）
- 資料庫還原工作（模擬送出 API 預覽）
- 網站登入與使用者/群組管理

## 帳號與權限

- 帳號資料儲存在 `webapp/data/users.json`
- 密碼欄位使用 PBKDF2-SHA256 加鹽雜湊儲存（不存明碼）
- 預設帳號：`admin`（群組 `Admin`，預設密碼 `Admin123`）

群組權限：

- `Admin`：可使用全部功能（含使用者管理）
- `Executor`：除使用者管理外，其餘功能可用
- `Tester`：不可使用使用者管理，且不可使用測試驅動

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

部署（lab）範例：

```bash
helm dependency build k8s/helm
helm upgrade --install perf-stack k8s/helm \
        -n performance-test --create-namespace \
        -f k8s/helm/environments/lab.yaml
```

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
