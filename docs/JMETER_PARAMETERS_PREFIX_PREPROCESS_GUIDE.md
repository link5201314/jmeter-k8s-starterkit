# JMeter 參數配置指南 - 前綴預處理方案

## 概述
此方案在 `source` 之前先把設定檔內容轉成「帶前綴的暫存檔」，避免 `.env` 與 `report-meta.env` 變數污染主腳本環境。

## 工作原理

1. `.env` 先預處理為 `JMETERTEST_` 前綴變數（寫入暫存檔）
2. `report-meta.env` 先預處理為 `JMETERREPORT_` 前綴變數（寫入暫存檔）
3. `source` 暫存檔後立即刪除暫存檔
4. 原始 `.env` 與 `report-meta.env` **不會被改寫**
5. JMeter 全域參數只由 `JMETERTEST_` 變數轉為 `-Gkey=value`

## 前綴規則

- `.env` 變數：`key=value` → `JMETERTEST_key=value`
- `report-meta.env` 變數：`REPORT_ENV=prod` → `JMETERREPORT_REPORT_ENV=prod`

## 範例

### 原始 `.env`
```bash
host=sbdemo.example.com
port=443
protocol=https
threads=10
duration=300
rampup=60
```

### 轉換後（暫存檔內容）
```bash
JMETERTEST_host=sbdemo.example.com
JMETERTEST_port=443
JMETERTEST_protocol=https
JMETERTEST_threads=10
JMETERTEST_duration=300
JMETERTEST_rampup=60
```

### 原始 `report-meta.env`
```bash
REPORT_ENV=prod
REPORT_VERSIONS='tip-web=1.0.1, gemfire=2.2.3'
REPORT_NOTE=報告註解測試
```

### 轉換後（暫存檔內容）
```bash
JMETERREPORT_REPORT_ENV=prod
JMETERREPORT_REPORT_VERSIONS='tip-web=1.0.1, gemfire=2.2.3'
JMETERREPORT_REPORT_NOTE=報告註解測試
```

## 自動產生的 JMeter 參數

腳本會把 `JMETERTEST_` 變數轉成：

```bash
-Ghost=sbdemo.example.com -Gport=443 -Gprotocol=https -Gthreads=10 -Gduration=300 -Grampup=60
```

## 新增參數方式

### 新增 JMeter 測試參數
1. 在 `scenario/<project>/.env` 直接加變數（不用前綴）
2. 重新執行 `./start_test.sh ...`

例如：
```bash
connectionTimeout=5000
authType=BASIC
```

會自動變成：
```bash
-GconnectionTimeout=5000 -GauthType=BASIC
```

### 新增報表 metadata
1. 在 `report-meta.env` 直接加 `REPORT_*` 變數
2. 重新執行測試

## 變數作用域

- `JMETERTEST_*`：測試參數，會送到所有 remote server（`-G`）
- `JMETERREPORT_*`：報表 metadata，供報表注入使用
- 其他變數：維持原用途，不參與上述轉換

## 優點

1. 不修改使用者原始設定檔
2. 清楚隔離測試參數與報表參數
3. 避免 `source` 污染既有腳本變數
4. 新增參數只改 `.env` / `report-meta.env`，不用改主流程