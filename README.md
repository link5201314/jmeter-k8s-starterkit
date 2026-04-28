
You can follow the full tutorial here : https://romain-billon.medium.com/ultimate-jmeter-kubernetes-starter-kit-7eb1a823649b

If you enjoy and want to support my work :

<a href="https://www.buymeacoffee.com/rbill" target="_blank"><img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" alt="Buy Me A Coffee" style="height: 41px !important;width: 174px !important;box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;-webkit-box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;" ></a>

# JMeter k8s starterkit

This is a template repository from which you can start load testing faster when injecting load from a kubernetes cluster.

You will find inside it the necessary to organize and run your performance scenario. There is also a node monitoring tool which will monitor all your injection nodes. As well an embeded live monitoring with InfluxDB and Grafana

Thanks to [Kubernauts](https://github.com/kubernauts/jmeter-kubernetes) for the inspiration !

## 客製版重點（Helm 管理模式）

此客製版已將原本以 `kubectl create -R -f k8s/` 為主的部署方式，改為以 Helm 為主的管理模式。

- 基礎元件以 `perf-stack` release 管理（環境值檔：`k8s/helm/environments/values/*.yaml`）
- 測試執行期資源以 `jmeter-runtime` release 管理（由 `start_test.sh` 動態部署）
- 目的：分離「長駐基礎設施」與「每次測試工作負載」，降低資源 ownership 衝突並提升可維運性
- 目前 `metric-server`、`telegraf-operator` 仍維持非 Helm 管理（`kubectl apply -f`），主要因為這兩項元件在許多現有 K8s 平台環境中可能已經預先部署或由平台統一管理，為避免重複安裝或資源衝突，故獨立於本專案 Helm 管理之外，僅作參考，或本地乾淨的lab環境部署用。

## 重要架構說明：JMeter、Webapp、Report-Server 共用 PVC

本專案設計特性如下：

- JMeter（動態執行）、Webapp（管理介面）、Report-Server（報表瀏覽）三者共用同一個 PVC（jmeter-data-dir-pvc），以便測試報告能即時產生與瀏覽。
- JMeter 測試資源（master/slave/job）是動態建立、動態清除（由 cleanup job 自動移除），而 Webapp 與 Report-Server 則為長駐服務。
- 因此，**PVC 的建立必須交由 Helm umbrella chart（perf-stack release）統一管理**，避免多個 Helm release 在同一 PVC 上產生 ownership 衝突。

### 正確操作方式

- **安裝整體環境（perf-stack）時**，必須在 `k8s/helm/environments/values/lab.yaml` 設定：

  ```yaml
  global:
    mastere:
      enabled: false
    slave:
      enabled: false
    pvc:
      enabled: true
  ```
  這樣 umbrella chart 只會建立 PVC，不會建立 JMeter workload。
  mastere.enabled、slave.enabled需要放在global底下是為了helm install不論是對整個k8s/helm還是只安裝k8s/helm/charts/jmeter都能通用所必需的。

- **啟動測試（start_test.sh）時**，必須帶入 `--pvc-enabled false`，即 `global.pvc.enabled=false`，讓 runtime release 不會再建立 PVC，只動態建立/清除 JMeter master/slave/job 等資源，同時start_test.sh在啟動時會透過--set global.master.enabled=true與--set global.slave.enabled=true強制啟動jmeter。

### 為什麼要這樣設計？

- 若多個 Helm release（如 perf-stack、jmeter-runtime）同時管理同一 PVC，會造成 Helm ownership annotation 衝突，導致安裝/升級/移除時出現錯誤。
- 這種設計可確保 PVC 生命週期由 umbrella chart 統一管理，JMeter 測試可安全動態執行與清除。

> **重點：**
> - perf-stack 安裝時：global.pvc.enabled=true
> - start_test.sh 執行時：--pvc-enabled false

## Webapp 持久化補充（Scenario / Data）

為避免重建 image 或重新部署時覆蓋環境資料，webapp 另有兩個專用 PVC 掛載：

- `/workspace/scenario`：保存專案 JMX、`.env`、`report-meta.env` 與 `scenario/dataset`
- `/workspace/webapp/data`：保存 `users.json`、`upload_owners.json`、`webapp/data/secrets/*`

首次部署且 `webapp/data` PVC 為空時，webapp 需要 bootstrap admin（由 Secret 注入）：

```bash
kubectl apply -f k8s/helm/environments/resources/lab/webapp-bootstrap-admin-secret.yaml
```

dr-prod 可用：

```bash
kubectl -n performance-test apply -f k8s/helm/environments/resources/dr-prod/webapp-bootstrap-admin-secret.yaml
```

另外，webapp 的 Logs 頁面目前也支援透過 `ConfigMap` 注入 JMeter log 忽略規則，避免只為了調整過濾條件而重打 image。

- lab：`k8s/helm/environments/resources/lab/webapp-log-filter-configmap.yaml`
- dr-prod：`k8s/helm/environments/resources/dr-prod/webapp-log-filter-configmap.yaml`

目前支援以下三組設定（皆為「每行一條 pattern」）：

- `WEBAPP_IGNORED_JMETER_WARN_PATTERNS`
- `WEBAPP_IGNORED_JMETER_INFO_PATTERNS`
- `WEBAPP_IGNORED_JMETER_ERROR_PATTERNS`

首次部署或首次啟用這套機制時，建議順序如下：

```bash
# 1) 先建立 bootstrap admin secret
kubectl apply -f k8s/helm/environments/resources/lab/webapp-bootstrap-admin-secret.yaml

# 2) 再建立 log filter configmap
kubectl apply -f k8s/helm/environments/resources/lab/webapp-log-filter-configmap.yaml

# 3) 最後做 Helm upgrade/install
helm dependency build k8s/helm
helm upgrade --install perf-stack k8s/helm \
  -n performance-test --create-namespace \
  -f k8s/helm/environments/values/lab.yaml
```

> 原因：webapp deployment 會透過 `envFrom.configMapRef` 讀取 `jmeter-webapp-log-filter`。若先升版、`ConfigMap` 尚未存在，Pod 建立時可能因缺少參照來源而失敗。

若之後只是調整忽略規則內容，而沒有修改 Helm chart/template，通常不需要再做 `helm upgrade`；只要重新套用 `ConfigMap` 並重啟 webapp 即可：

```bash
kubectl apply -f k8s/helm/environments/resources/lab/webapp-log-filter-configmap.yaml
kubectl -n performance-test rollout restart deploy/jmeter-webapp
kubectl -n performance-test rollout status deploy/jmeter-webapp --timeout=240s
```

再執行 Helm：

```bash
helm dependency build k8s/helm
helm upgrade --install perf-stack k8s/helm \
  -n performance-test --create-namespace \
  -f k8s/helm/environments/values/lab.yaml
```

> 每次你有修改 `k8s/helm/charts/*` 子 chart（例如 webapp template / values）後，請先執行 `helm dependency build k8s/helm` 再 `helm upgrade`，避免實際部署仍套用舊版子 chart 內容。

若首次部署後 `scenario` PVC 為空，可把 repo 內既有資料拷貝到 webapp 掛載路徑：

```bash
# 1) 取得 webapp pod
WEBAPP_POD=$(kubectl -n performance-test get pod -l app=jmeter-webapp -o jsonpath='{.items[0].metadata.name}')

# 2) 建立目錄（若已存在可忽略）
kubectl -n performance-test exec "$WEBAPP_POD" -- mkdir -p /workspace/scenario/dataset

# 3) 拷貝單一 JMeter 專案目錄（例：demoweb）
kubectl -n performance-test cp scenario/demoweb "$WEBAPP_POD":/workspace/scenario/demoweb

# 4) 拷貝單一 dataset 檔案（例：test-dataset.csv）
kubectl -n performance-test cp scenario/dataset/test-dataset.csv "$WEBAPP_POD":/workspace/scenario/dataset/test-dataset.csv

# 5) 驗證檔案已存在
kubectl -n performance-test exec "$WEBAPP_POD" -- ls -lah /workspace/scenario
kubectl -n performance-test exec "$WEBAPP_POD" -- ls -lah /workspace/scenario/dataset
```

若你要一次同步整個 `scenario` 目錄（包含多個專案與 dataset），可改用：

```bash
WEBAPP_POD=$(kubectl -n performance-test get pod -l app=jmeter-webapp -o jsonpath='{.items[0].metadata.name}')
kubectl -n performance-test cp scenario/. "$WEBAPP_POD":/workspace/scenario/
```

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

`start_test.sh` 仍可維持現有 `scenario/...` 相對路徑，不需調整，只要掛載點保持 `/workspace/scenario`。

### 專案管理頁：建立新專案（含模板自動帶入）

在 webapp 的「專案管理」頁面可直接輸入新專案名稱並建立。

建立成功時會自動建立 `scenario/<project>/`，並複製以下三個檔案：

- `.env`
- `jmeter-system.properties`
- `report-meta.env`

模板來源優先序：

1. `/workspace/scenario/_template`（PVC 內模板）
2. `webapp/app/project_template_defaults`（webapp 內建 fallback）

建立完成後，頁面會立即切換到新專案並自動讀取上述檔案內容。

> 若你在 PVC 內沒有 `_template`，功能仍可透過 webapp 內建 fallback 模板正常建立。

請務必遵循此原則，才能避免 PVC 衝突與測試異常。

## Webapp 管理介面（FastAPI）

![Webapp 管理介面畫面](docs/images/webapp-ui.png)

本專案包含一個 `webapp` 子系統（`webapp/`），提供網頁化操作能力，與本 starterkit 的關係如下：

- `start_test.sh` / `stop_test.sh` 仍是核心執行腳本；webapp 是其 UI 管理入口
- webapp 透過 Helm / kubectl 操作同一套 k8s 資源（同 namespace）
- webapp 的報表與 master 共用 PVC，才能即時瀏覽測試報告
- 參數治理採三層覆蓋用詞：環境值檔（`k8s/helm/environments/values/*.yaml`）→ 專案覆寫值（`scenario/<project>/deploy.values.yaml`）→ 本次執行值（`start_test.sh`）
- Logs 頁面的 JMeter `WARN / INFO / ERROR` 忽略清單已改由 `ConfigMap` 注入，預設檔位於 `k8s/helm/environments/resources/*/webapp-log-filter-configmap.yaml`

常見流程（摘要）：

1. 打包並推送 `docker.io/isaac0815/jmeter-webapp:latest`
2. 用 `skopeo inspect` 確認遠端 `Digest`
3. 在 k8s 執行 `kubectl rollout restart deploy/jmeter-webapp`
4. 以 pod `imageID`（`@sha256:...`）比對遠端 digest

若只是調整 Logs 頁面的忽略規則，流程可再簡化為：

1. 編輯 `k8s/helm/environments/resources/*/webapp-log-filter-configmap.yaml`
2. `kubectl apply -f ...webapp-log-filter-configmap.yaml`
3. `kubectl rollout restart deploy/jmeter-webapp`

### Webapp 新增功能：資料庫還原（模擬送出）

- 新增頁面：`/db-restore`
- 可選環境來源：`config/jmeter.<env>.env`
- 需在各環境檔新增：`JMETER_FLASHBACK_DB_API=<endpoint-url>`
- 功能按鈕（目前僅預覽，不會真的發送）
  1. 建立 Flashback 任務
  2. 查詢任務狀態
  3. 查詢所有任務
  4. 取消任務

API Key / Token 請放在（已加入忽略規則）：

- `webapp/data/secrets/db_restore_tokens.json`

範例格式：

```json
{
  "lab": "your-lab-token",
  "dr-prod": "your-dr-prod-token"
}
```

完整 webapp 說明（含登入權限、image 推送、digest 驗證、k8s 啟動）請見：`webapp/README.md`

若遇到「頁面卡住 / 推版後仍舊版 / 找不到 webapp pod」等問題，可直接參考 `webapp/README.md` 的 **常見問題排查（Troubleshooting）** 章節。


## Features

<p align="center"><a href="https://ibb.co/ccM9RJp"><img src="https://i.ibb.co/0j8L1qW/jmeter-starterkit.jpg" alt="jmeter-starterkit" border="0" /></a></p>

| Feature     | Supported    | Comment    |
|-------------|:------------:|-------------
| Flexibility at run time      | Yes | With .env file (threads, duration, host) |
| Distributed testing      | Yes | Virtually unlimited with auto-scaling     |
| JMeter Plugin support | Yes | Modules are installed at run time by scanning the JMX needs      |
| JMeter Module support | Yes | JMeter include controller are supported if *path* is just the name of the file in the *Include Controler*
| JMeter CSV support | Yes | CSV files are splitted prior to launch the test and unique pieces copied to each pods, in the JMeter scenario, just put the name of the file in the *path* field |
| Node auto-scaling | Yes | By requesting ressources at deployment time, the cluster will scale automatically if needed |
| Reporting | Yes | The JMeter report is generated at the end of the test inside the master pod if the -r flag is used in the start_test.sh|
| Live monitoring | Yes | An InfluxDB instance and a Grafana are available in the stack |
| Report persistance | Yes | A persistence volume is used to store the reports and results |
| Injector nodes monitoring | Yes | Even if autoscaling, a Daemon Set will deploy a telegraf instance and persist the monitoring data to InfluxDB. A board is available in Grafana to show the Telegraf monitoring
| Multi thread group support | Not really | You can add multi thread groups, but if you want to use JMeter properties (like threads etc..) you need to add them in the .env and update the start_test.sh to update the "user_param" variable to add the desired variables |
| Mocking service | Yes | A deployment of Wiremock is done inside the cluster, the mappings are done inside the wiremock configmap. Also an horizontal pod autoscaler have been added
| JVM Monitoring | Yes | JMeter and Wiremock are both Java application. They have been packaged with Jolokia and Telegraf and are monitored
| Pre built Grafana Dashboards | Yes | 4 Grafana dashboards are shipped with the starter kit. Node monitoring, Kubernetes ressources monitoring, JVM monitoring and JMeter result dashboard.
| Ressource friendly | Yes | JMeter is deployed as batch job inside the cluster. Thus at the end  of the execution, pods are deleted and ressources freed



## Getting started

Prerequisites : 
- A kubernetes cluster (of course) (amd64 and arm64 architecture are supported)
- kubectl installed and a usable context to work with
- (Optionnal) A JMeter scenario (the default one attack Google.com)

### 1. Preparing the repository

You need to put your JMeter project inside the `scenario` folder, inside a folder named after the JMX (without the extension).
Put your CSV file inside the `dataset` folder, child of `scenario`
Put your JMeter modules (include controlers) inside the `module` folder, child of `scenario`

`dataset`and `module`are in `scenario` and not below inside the `<project>` folder because, in some cases, you can have multiple JMeter projects that are sharing the JMeter modules (that's the goal of using modules after all).


*Below a visual representation of the file structure*

```bash
+-- scenario
|   +-- dataset
|   +-- module
|   +-- my-scenario
|       +-- my-scenario.jmx
|       +-- .env
```

### 2. Deploying the Stack

#### From this repository

`kubectl create -R -f k8s/`

This will deploy all the needed applications :

- JMeter master and slaves
- Telegraf operator to automatically monitor the specified applications
- Telegraf as a DaemonSet on all the nodes
- InfluxDB to store the date (with a 5GB volume in a PVC)
- Grafana with a LB services and 4 included dashboard
- Wiremock

#### Using helm

> This helm project is at an very early stage, feel free to test it and open any issue for any feedbacks. Thanks you

```shell
helm repo add jmeter-k8s-starterkit-helm-charts https://rbillon59.github.io/jmeter-k8s-starterkit-helm-chart/
helm install jmeter-k8s-starterkit-helm-charts/jmeter-k8s-starterkit --generate-name
```



### 3. Starting the test

`./start_test.sh -j my-scenario.jmx -n default -c -m -i 20 -r`

Usage :
```sh
   -j <filename.jmx>
   -n <namespace>
   -c flag to split and copy csv if you use csv in your test
   -m flag to copy fragmented jmx present in scenario/project/module if you use include controller and external test fragment
   -i <injectorNumber> to scale slaves pods to the desired number of JMeter injectors
   -r flag to enable report generation at the end of the test
```


**The script will :**

- Delete and create again the JMeter jobs.
- Scale the JMeter slave deployment to the desired number of injectors
- Wait to all the slaves pods to be available. Here, available means that the filesystem is reacheable (liveness probe that cat a file inside the fs)
- If needed will split the CSV locally then copy them inside the slave pods
- If needed will upload the JMeter modules inside the slave pods
- Send the JMX file to each slave pods
- Generate and send a shell script to the slaves pods to download the necessary plugins and launch the JMeter server.
- Send the JMX to the controller 
- Generate a shell script and send it to the controller to wait for all pods to have their JMeter slave port listening (TCP 1099) and launch the performance test.



### 4. Gethering results from the master pod

After the test have been executed, the master pod job is in completed state and then, is deleted by the cleaner cronjob.

To be able to get your result, a jmeter master pod must be in ***running state*** (because the pod is mounting the persistantVolume with the reports inside).

*The master pod default behaviour is to wait until the load_test script is present in the pod*

You can run   

```sh
# If a master pod is not available, create one
helm upgrade --install jmeter-runtime k8s/helm/charts/jmeter \
  -n <namespace> --create-namespace \
  --set slaves.parallelism=0
# Wait for the pod is Running, then
kubectl cp -n <namespace> <master-pod-id>:/report/<result> ${PWD}/<local-result-name>
# To copy the content of the report from the pod to your local
```
You can do this for the generated report and the JTL for example.  


## 本專案新增功能與修改（客製版）

快速導覽：

- [1) 提供額外參數檔](#1-提供額外參數檔)
- [2) 參數前綴預處理（避免環境變數污染）](#2-參數前綴預處理避免環境變數污染)
- [3) 新增 CLI 參數](#3-新增-cli-參數)
- [4) 報表 metadata 自動注入（搭配 -r）](#4-報表-metadata-自動注入搭配--r)
- [5) jmeter-system.properties 自動帶入](#5-jmetersystemproperties-自動帶入)
- [6) CSV 分檔流程強化](#6-csv-分檔流程強化)
- [7) JMeter runtime 參數（建議改為環境分檔）](#7-jmeter-runtime-參數建議改為環境分檔)
- [8) 三層覆蓋優先序（環境值檔 / 專案覆寫值 / 本次執行值）](#8-三層覆蓋優先序環境值檔--專案覆寫值--本次執行值)

### 專案目錄結構描述

```text
jmeter-k8s-starterkit/
├── start_test.sh / stop_test.sh / reset_pvc.sh / cleanup_released_pv.sh  # 核心操作腳本
├── config/                # 環境層級參數（jmeter.<env>.env）
├── k8s/helm/              # Helm umbrella chart 與環境 values
├── scenario/              # 測試專案（JMX、.env、report-meta.env、deploy.values.yaml）
│   ├── _template/         # 專案模板
│   └── <project>/         # 實際測試專案（例如 demoweb、my-scenario）
├── report/                # 測試產出報表（HTML、statistics.json、內容資源）
├── webapp/                # FastAPI 管理介面（UI + API）
└── docs/                  # 文件與圖片資源
```

補充說明：

- `config/` 管「環境基線」，`scenario/<project>/` 管「專案與本次測試參數」。
- `k8s/helm/environments/values/*.yaml` 放環境值，`scenario/<project>/deploy.values.yaml` 放專案覆寫值。
- `webapp/` 透過同一套腳本與 Helm 資源操作測試流程，並讀取共用 PVC 中的報表。

### 1) 提供額外參數檔 

為了把「環境基線」與「專案參數」分離，本專案提供以下參數檔：

- `config/jmeter.<env>.env`
  - 用途：放環境層級設定（例如 lab / dr-prod 的 JVM heap 與共用參數）
  - 範例：`config/jmeter.lab.env`、`config/jmeter.dr-prod.env`
  - 讀取時機：`start_test.sh` 依 `--helm-env` 或 fallback 規則載入

- `scenario/<project>/.env`
  - 用途：放該專案測試參數（threads、duration、host、port…）
  - 作用：啟動時會轉成 JMeter `-G` 參數傳入 slave/master

- `scenario/<project>/jmeter-system.properties`
  - 用途：放 JMeter system properties（report granularity、apdex 等）
  - 作用：若存在，會自動複製到 master/slave 並以 `-S` 帶入

- `scenario/<project>/report-meta.env`
  - 用途：放報表 metadata（Environment / Versions / Notes）
  - 作用：搭配 `-r` 產報時注入到 HTML 報表

建議配置原則：

- 環境共用值放 `config/jmeter.<env>.env`
- 專案差異值放 `scenario/<project>/.env`
- 報表描述資訊放 `scenario/<project>/report-meta.env`


### 2) 參數前綴預處理（避免環境變數污染）
- 測試參數檔 `scenario/<project>/.env` 會先轉為 `JMETERTEST_*` 暫存變數，再轉成 JMeter `-G` 全域參數。
- 報表 metadata 檔（預設JMeter project目錄下 `report-meta.env`）會先轉為 `JMETERREPORT_*` 暫存變數，供報表注入使用。
- 原始 `.env` / `report-meta.env` 不會被改寫。

> 詳細說明請見：`docs/JMETER_PARAMETERS_PREFIX_PREPROCESS_GUIDE.md`

---

### 3) 新增 CLI 參數
`start_test.sh` 除了原本參數外，新增：

- `-E <env>`：測試環境（如 `prod/uat/sit/pt`）
- `-V <versions>`：版本資訊（建議以 `,` 分隔）
- `-N <note>`：備註
- `-F <file>`：指定 metadata 檔名（預設 `report-meta.env`，相對路徑會視為 `scenario/<project>/` 底下）
- `--helm-env <name>`：指定 Helm 環境值檔名稱（對應 `k8s/helm/environments/values/<name>.yaml`，預設 `lab`）
- `--helm-release <name>`：指定 jmeter runtime 的 Helm release 名稱（預設 `jmeter-runtime`）
- `--helm-chart <path>`：指定 jmeter runtime Helm chart 路徑（預設 `k8s/helm/charts/jmeter`）
- `--jmeter-env-file <path>`：明確指定 JMeter runtime env 檔（優先於 `config/jmeter.<helm-env>.env` / `config/jmeter.env`）

---

### 4) 報表 metadata 自動注入（搭配 `-r`）
啟用 `-r` 產報後，會將以下資訊注入 HTML 報表：
- Environment
- App Versions
- Notes

也會先做基本 HTML escape，降低特殊字元造成的版面問題。

---

### 5) `jmeter-system.properties` 自動帶入
若 `scenario/<project>/jmeter-system.properties` 存在：
- 會自動複製到 master/slave
- 執行時自動加上 `-S <path>/jmeter-system.properties`
- 並擷取部分 report 參數轉為 `-J...`（例如 granularity / apdex）

> 根目錄不再放 `jmeter-system.properties` 範例檔。請使用模板：
> `scenario/_template/jmeter-system.properties`

```bash
# 以 demoweb 專案為例
cp scenario/_template/jmeter-system.properties scenario/demoweb/jmeter-system.properties
```

---

### 6) CSV 分檔流程強化
啟用 `-c` 時：
- 先保留原始 CSV header
- 將資料列打散（shuffle）
- 依 injector 數切分後，每份再補回 header
- 分別上傳到各 slave pod

---

### 7) JMeter runtime 參數（建議改為環境分檔）
`start_test.sh` 會依序載入以下檔案（先找到先用）：

1. `--jmeter-env-file <path>`（手動指定）
2. `config/jmeter.<helm-env>.env`（例如 `config/jmeter.lab.env`、`config/jmeter.dr-prod.env`）
3. `config/jmeter.env`（fallback）

建議做法：
- `master/slave` **resources** 主要放 Helm values（`k8s/helm/environments/values/*.yaml` 或 `scenario/<project>/deploy.values.yaml`）
- `JMETER_MASTER_JVM_HEAP_ARGS` / `JMETER_SLAVE_JVM_HEAP_ARGS` 放在 `config/jmeter.<env>.env`

`config/jmeter.env` 可保留為共用 fallback，不再作為主要環境配置入口。

環境基線（建議）：

| 項目 | lab | dr-prod |
|---|---|---|
| JMeter Master Resources | 依 chart 預設或專案覆蓋 | requests: 1000m/2048Mi, limits: 2000m/4096Mi |
| JMeter Slave Resources | 依 chart 預設或專案覆蓋 | requests: 1000m/1024Mi, limits: 2000m/2048Mi |
| JVM Heap（Master） | `config/jmeter.lab.env` | `config/jmeter.dr-prod.env` |
| JVM Heap（Slave） | `config/jmeter.lab.env` | `config/jmeter.dr-prod.env` |

對應檔案：
- Helm resources：`k8s/helm/environments/values/lab.yaml`、`k8s/helm/environments/values/dr-prod.yaml`
- JVM heap：`config/jmeter.lab.env`、`config/jmeter.dr-prod.env`

可另外用 `scenario/<project>/deploy.values.yaml` 定義專案級部署參數，達成「環境（lab/dr-prod） + 專案 + 本次測試」三層覆蓋。

### 8) 三層覆蓋優先序（環境值檔 / 專案覆寫值 / 本次執行值）

延伸閱讀：[webapp/README.md 的同名章節](webapp/README.md#8-三層覆蓋優先序環境值檔--專案覆寫值--本次執行值)

三層覆蓋優先序（由低到高）如下：

| 層級 | 來源 | 作用 | 優先序 |
|---|---|---|---|
| 1 | `k8s/helm/environments/values/<env>.yaml` | 環境共用基線（lab/dr-prod） | 低 |
| 2 | `scenario/<project>/deploy.values.yaml` | 專案固定需求（例如 demoweb） | 中 |
| 3 | `start_test.sh` 本次執行產生的 run values | 本次測試動態參數（例如 `-i`） | 高 |

範例（同一個 key 衝突時誰生效）：
- `lab.yaml` 設 `slaves.parallelism: 1`
- `scenario/demoweb/deploy.values.yaml` 設 `slaves.parallelism: 4`
- 命令列帶 `-i 2`

最終會使用 `2`（因為本次執行層優先序最高）。

已提供範本：`scenario/_template/deploy.values.yaml`

```bash
# 以 demoweb 專案為例
cp scenario/_template/deploy.values.yaml scenario/demoweb/deploy.values.yaml
```

---

## 快速使用（建議）

```
# 建議部署至 performance-test namespace

# 1) 仍維持非 Helm 管理（不動）
kubectl apply -f k8s/metric-server.yaml
kubectl apply -f k8s/telegraf-operator.yaml

# 2) 建立 Helm 依賴並佈署整套資源（lab）
helm dependency build k8s/helm
helm upgrade --install perf-stack k8s/helm \
  -n performance-test --create-namespace \
  -f k8s/helm/environments/values/lab.yaml

# 3) 移除 Helm 管理資源
helm uninstall perf-stack -n performance-test
helm uninstall jmeter-runtime -n performance-test

# 4) 移除非 Helm 管理資源
kubectl delete -f k8s/telegraf-operator.yaml
kubectl delete -f k8s/metric-server.yaml
```

```bash
./start_test.sh -j my-scenario.jmx -n default -i 2 -c -m -r \
  --helm-env lab \
  --helm-release jmeter-runtime \
  -E prod \
  -V "tip-web=1.0.1,gemfire=2.2.3" \
  -N "壓測前驗證版" \
  -F report-meta.env
```

停止測試：
```bash
./stop_test.sh -n default

# 停測後一併卸載 jmeter runtime (helm)
./stop_test.sh -n default -u --helm-release jmeter-runtime
```

測試helm渲染：
(測試後pvc可能只能手動建立)
```bash
helm template jmeter-runtime k8s/helm/charts/jmeter -n performance-test --set pvc.enabled=true
helm template jmeter-runtime k8s/helm/charts/jmeter -n performance-test --set pvc.enabled=false

helm template jmeter-runtime k8s/helm -n performance-test -f k8s/helm/environments/values/lab.yaml
helm template perf-stack k8s/helm -n performance-test -f k8s/helm/environments/values/dr-prod.yaml

helm template jmeter-runtime k8s/helm -n performance-test -f k8s/helm/environments/values/lab.yaml -s charts/jmeter/templates/jmeter-master.yaml 
helm template jmeter-runtime k8s/helm -n performance-test -f k8s/helm/environments/values/lab.yaml -s charts/jmeter/templates/jmeter-pvc.yaml 

helm template jmeter-runtime k8s/helm -n performance-test -f k8s/helm/environments/values/lab.yaml -s charts/webapp/templates/webapp.yaml 


helm template jmeter-runtime k8s/helm/charts/jmeter -n performance-test -f k8s/helm/environments/values/dr-prod.yaml -f scenario/demoweb/deploy.values.yaml -s templates/jmeter-master.yaml 

helm template jmeter-runtime k8s/helm/charts/influxdb -n performance-test -f k8s/helm/environments/values/dr-prod.yaml -f scenario/demoweb/deploy.values.yaml -s templates/influxdb-deployment.yaml 

helm template jmeter-runtime k8s/helm/charts/jmeter -n performance-test -f k8s/helm/environments/values/dr-prod.yaml  -s templates/jmeter-master.yaml 

helm template jmeter-runtime k8s/helm/charts/influxdb -n performance-test -f k8s/helm/environments/values/dr-prod.yaml -s templates/influxdb-deployment.yaml 

helm template jmeter-runtime k8s/helm -n performance-test -f k8s/helm/environments/values/dr-prod.yaml -f scenario/demoweb/deploy.values.yaml -s charts/jmeter/templates/jmeter-master.yaml 

helm template jmeter-runtime k8s/helm -n performance-test -f k8s/helm/environments/values/dr-prod.yaml -f scenario/demoweb/deploy.values.yaml -s charts/jmeter/templates/jmeter-pvc.yaml

helm template jmeter-runtime k8s/helm -n performance-test -f k8s/helm/environments/values/lab.yaml -f scenario/demoweb/deploy.values.yaml -s charts/jmeter/templates/jmeter-master.yaml 

helm template jmeter-runtime k8s/helm -n performance-test -f k8s/helm/environments/values/lab.yaml -f scenario/demoweb/deploy.values.yaml -s charts/jmeter/templates/jmeter-pvc.yaml

helm template jmeter-runtime k8s/helm -n performance-test -f k8s/helm/environments/values/lab.yaml -f scenario/demoweb/deploy.values.yaml -s charts/jmeter/templates/jmeter-slave-service.yaml
```

> 建議：日常操作優先使用「僅 stoptest」；不要每次都 `-u`。在 `Retain` 類型 StorageClass 下，反覆刪除 PVC 會造成大量 `Released` PV 累積。
>
> 本專案 jmeter chart 預設已設定 `pvc.keepOnUninstall: true`，即使 `helm uninstall jmeter-runtime`，也會保留 `jmeter-data-dir-pvc`，以避免持續產生新 PV。

若未傳入 namespace，會自動使用 `default`，並輸出提示訊息。

```bash
./stop_test.sh
# [INFO] Namespace not provided, using default namespace: default
```

### PVC 整顆重置（含刪除 PVC 物件）

若你要直接重置 `jmeter-data-dir-pvc`（不是只清空內容），可用：

```bash
./reset_pvc.sh -n performance-test -r jmeter-runtime -p jmeter-data-dir-pvc

# 重置後自動把 report-server 拉回 1
./reset_pvc.sh -n performance-test -r jmeter-runtime -p jmeter-data-dir-pvc --restore-report-server

# 重置後自動重建 jmeter-runtime（會重建 PVC）
./reset_pvc.sh -n performance-test -r jmeter-runtime -p jmeter-data-dir-pvc --recreate-runtime --restore-report-server
```

腳本會自動執行：
- 卸載 runtime release（預設 `jmeter-runtime`）
-（可選）將 report-server scale 到 0
- 刪除 PVC
- 若卡 `Terminating`，自動 patch PVC/PV finalizers 後重試刪除

可用 `./reset_pvc.sh -h` 查看全部參數（如 `--skip-scale-report`）。

若歷史上已累積許多 `Released` PV（常見於 `Retain` StorageClass），可用以下腳本清理：

```bash
# 先 dry-run 看清單（不刪除）
./cleanup_released_pv.sh -n performance-test -c jmeter-data-dir-pvc --storage-class nfs-csi

# 確認後再實際刪除
./cleanup_released_pv.sh -n performance-test -c jmeter-data-dir-pvc --storage-class nfs-csi --execute
```

## 標準操作流程（建議）

`hostAliases` 環境策略：

- `lab`：保留 `jmeter.hostAliases`（用於無完整 DNS 的測試環境）
- `dr-prod`：不設定 `hostAliases`（使用環境既有 DNS）

### A) Lab 環境

```bash
# 啟動測試（Lab）
./start_test.sh -j demoweb.jmx -n performance-test -i 20 -c -m -r \
  --helm-env lab \
  --helm-release jmeter-runtime \
  -E lab \
  -V "tip-web=1.0.1,gemfire=2.2.3" \
  -N "lab smoke + baseline" \
  -F report-meta.env

# 停止測試（僅 stoptest）
./stop_test.sh -n performance-test

# 停止測試並卸載 jmeter runtime
./stop_test.sh -n performance-test -u --helm-release jmeter-runtime
```

### B) DR-Prod 環境

```bash
# 啟動測試（DR-Prod，使用私有 registry values）
./start_test.sh -j demoweb.jmx -n performance-test -i 20 -c -m -r \
  --helm-env dr-prod \
  --helm-release jmeter-runtime \
  -E dr-prod \
  -V "tip-web=1.0.1,gemfire=2.2.3" \
  -N "dr-prod full load" \
  -F report-meta.env

# 停止測試並卸載 jmeter runtime
./stop_test.sh -n performance-test -u --helm-release jmeter-runtime
```

> 參數說明可用：`./start_test.sh -h`、`./stop_test.sh -h`

## 最短指令（直接複製）

### Lab

```bash
# 佈署基礎元件
helm dependency build k8s/helm
helm upgrade --install perf-stack k8s/helm -n performance-test --create-namespace -f k8s/helm/environments/values/lab.yaml

# 執行測試（2 injectors）
./start_test.sh -j demoweb.jmx -n performance-test -i 2 -c -m -r --helm-env lab --helm-release jmeter-runtime

# 停測（保留 jmeter-runtime）
./stop_test.sh -n performance-test
```

### DR-Prod

```bash
# 佈署基礎元件
helm dependency build k8s/helm
helm upgrade --install perf-stack k8s/helm -n performance-test --create-namespace -f k8s/helm/environments/values/dr-prod.yaml

# 執行測試（2 injectors）
./start_test.sh -j demoweb.jmx -n performance-test -i 2 -c -m -r --helm-env dr-prod --helm-release jmeter-runtime

# 停測並清掉 jmeter-runtime
./stop_test.sh -n performance-test -u --helm-release jmeter-runtime
```

若 DR 環境中的 InfluxDB PVC 空間不足，可先臨時擴容，再執行 `helm upgrade` 套用固定值：

```bash
# 確認 storage class 是否支援 volume expansion(要先確認在哪個storageClass)
kubectl get sc nutanix-volume -o yaml | grep -i allowVolumeExpansion

# 臨時將 InfluxDB PVC 擴大到 30Gi
kubectl -n performance-test patch pvc influxdb-pvc -p '{"spec":{"resources":{"requests":{"storage":"30Gi"}}}}'

# 觀察 PVC 擴容狀態
kubectl -n performance-test get pvc influxdb-pvc -w

# 確認 Pod 內掛載空間已更新
kubectl -n performance-test exec -it deploy/influxdb -- df -h /var/lib/influxdb

# 將容量設定固定回 Helm values
helm dependency build k8s/helm
helm upgrade --install perf-stack k8s/helm -n performance-test --create-namespace -f k8s/helm/environments/values/dr-prod.yaml
```

若 `nfs-client` 不支援 volume expansion，則需要改走新建較大 PVC 並搬移資料的方式處理。

InfluxDB 目前可透過 Helm values 設定 retention：

```yaml
influxdb:
  retentionDays: 14
```

- `retentionDays` 會在 InfluxDB 啟動後自動建立對應的 retention policy，並設成 telegraf 資料庫的預設 RP。

## Oracle Flashback 資料庫還原功能

### 功能介紹

Webapp 提供 Oracle Flashback 資料庫還原功能，通過 SSH 連接到 Oracle 服務器執行還原操作。此功能支持以下 5 項操作：

1. **建立還原點** (`create_rp.sh`)：為 PDB 建立 Oracle Flashback 還原點
2. **查詢還原點** (`current_rp.sh`)：列出指定 PDB 的所有可用還原點
3. **刪除還原點** (`delete_rp.sh`)：刪除指定 PDB 的還原點
4. **查詢還原進度** (`fb_process.sh`)：查詢 Oracle 是否正在執行 Flashback Restore
5. **執行還原** (`restore_rp.sh`)：執行 Flashback Restore 將 PDB 還原到指定的還原點

### SSH 連接配置

SSH 連接配置通過 Kubernetes Secret 管理。需要為 LAB 和 DR-Prod 環境各創建一份 Secret 配置：

#### LAB 環境

```bash
kubectl apply -f k8s/helm/environments/resources/lab/oracle-flashback-secret.yaml
```

或手動創建：

```bash
kubectl -n performance-test create secret generic oracle-flashback-ssh \
  --from-literal=host=10.1.36.31 \
  --from-literal=port=22 \
  --from-literal=username=oracle \
  --from-literal=password=<YOUR_PASSWORD> \
  --from-literal=script_path=/home/oracle/scripts
```

#### DR-Prod 環境

```bash
kubectl -n performance-test apply -f k8s/helm/environments/resources/dr-prod/oracle-flashback-secret.yaml
```

### 前置要求

1. **遠端服務器**：需要在 `10.1.36.31` 上的 `/home/oracle/scripts` 目錄中存放以下 shell scripts：
   - `create_rp.sh`
   - `current_rp.sh`
   - `delete_rp.sh`
   - `fb_process.sh`
   - `restore_rp.sh`

2. **Python 依賴**：Webapp 需要 `paramiko` 庫來實現 SSH 連接：
   ```bash
   pip install paramiko
   ```

3. **SSH 認證**：需要有效的 Oracle 用戶帳號和密碼（或可配置密鑰認證）

### 使用方式

1. 登入 Webapp 管理平台（`http://<webapp-host>/`)
2. 點擊導航菜單中的「資料庫還原」
3. 選擇環境（LAB 或 DR-Prod）
4. 輸入 PDB 名稱（例：CDBC1）
5. 根據需要執行相應的操作：
   - **建立還原點**：輸入還原點名稱，點擊「建立還原點」按鈕
   - **查詢還原點**：點擊「查詢還原點」按鈕查看可用的還原點列表
   - **刪除還原點**：輸入要刪除的還原點名稱，點擊「刪除還原點」按鈕
   - **查詢還原進度**：點擊「查詢還原進度」按鈕查看當前是否有還原操作進行中
   - **執行還原**：輸入目標還原點名稱，點擊「執行還原」按鈕（此操作會關閉 PDB 並執行還原，需要確認）

### API 端點

| 操作 | 方法 | 端點 | 說明 |
|------|------|------|------|
| 建立還原點 | POST | `/api/oracle-flashback/create-rp` | 建立新的還原點 |
| 查詢還原點 | POST | `/api/oracle-flashback/list-rp` | 列出可用的還原點 |
| 刪除還原點 | POST | `/api/oracle-flashback/delete-rp` | 刪除指定還原點 |
| 查詢進度 | POST | `/api/oracle-flashback/check-process` | 檢查還原進程狀態 |
| 執行還原 | POST | `/api/oracle-flashback/restore-rp` | 執行 Flashback Restore |

### 請求參數

所有 API 端點都支持以下參數（使用 `application/x-www-form-urlencoded` 格式）：

| 參數 | 必需 | 說明 |
|------|------|------|
| `env` | 是 | 環境名稱（lab 或 dr-prod） |
| `pdb_name` | 是 | PDB 名稱 |
| `restore_point` | 部分 | 還原點名稱（建立、刪除、執行還原時必需） |

### 響應格式

所有 API 響應均返回 JSON 格式：

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

### 故障排查

#### 連接失敗
- 檢查 K8s Secret 中的 SSH 認證信息是否正確
- 確認遠端服務器是否可達（檢查網路連線和防火牆規則）
- 驗證 SSH 帳號和密碼是否有效

#### 腳本執行失敗
- 檢查遠端服務器上的 scripts 文件是否存在且有執行權限
- 查看 API 響應中的 `error` 和 `output` 欄位以了解具體的錯誤信息
- 確認 Oracle 環境變量設置是否正確（ORACLE_HOME、ORACLE_SID 等）

#### 權限問題
- 確保 Oracle 用戶有權執行 SQL Plus 命令並管理 restore points
- 確認 Oracle 用戶能夠讀取和執行 `/home/oracle/scripts` 目錄中的腳本

### 相關文件

- K8s Secret 配置：
  - [lab.oracle-flashback-secret.yaml](k8s/helm/environments/resources/lab/oracle-flashback-secret.yaml)
  - [dr-prod.oracle-flashback-secret.yaml](k8s/helm/environments/resources/dr-prod/oracle-flashback-secret.yaml)
- Webapp 服務模塊：[oracle_flashback_service.py](webapp/app/services/oracle_flashback_service.py)
- API 路由：[routers/api.py](webapp/app/routers/api.py)
- Web UI 模板：[templates/oracle_flashback.html](webapp/app/templates/oracle_flashback.html)