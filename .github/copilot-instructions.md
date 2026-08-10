# GitHub Copilot Project Instructions

## 1. 語言與溝通規範 (Language & Communication)
- **強制回答語言**：所有對話、解釋、程式碼註解與說明，一律使用**繁體中文**（Traditional Chinese）回答。
- **名詞處理**：程式碼專有名詞（如 `async/await`、`Type Hinting`、`Decorator`、`Pytest`）保留英文原名即可，無需刻意硬翻。
- **回答風格**：說明請保持簡潔精準、直擊重點，避免過多的冗長客套話。

## 2. Python 語言規範與風格 (Python Coding Standards)
- **Python 版本與語法**：遵循 Python 3.10+ 的現代語法規範。
- **類型標註 (Type Hints)**：
  - 所有函式的參數與傳回值**必須明確標註 Type Hints**。
  - 使用 Python 3.10+ 原生語法（如 `list[str]` 代替 `List[str]`，`int | None` 代替 `Optional[int]`）。
- **Docstring 規範**：
  - 主要函式與類別必須附帶 Google 風格或 NumPy 風格的 Docstring（請用中文說明）。
- **程式碼風格**：
  - 嚴格遵守 PEP 8 命名規範（變數/函式使用 `snake_case`，類別使用 `PascalCase`，常數使用 `UPPER_SNAKE_CASE`）。
  - 優先使用 `pathlib.Path` 處理檔案路徑，避免使用舊式的 `os.path`。

## 3. 錯誤處理與日誌錄 (Error Handling & Logging)
- **例外處理**：
  - 捕捉例外時必須精確，嚴禁使用裸露的 `except:` 或過於寬鬆的 `except Exception:`。
  - 重複發生的業務邏輯錯誤應定義自訂例外類別（Custom Exceptions）。
- ** Logging 規範**：
  - 嚴禁使用 `print()` 輸出除錯資訊。
  - 請統一使用 `logging` 模組（或專案指定的 `loguru`），並適當設定日誌層級（`logger.info` / `logger.error`）。

## 4. 效能與安全性 (Performance & Security)
- **非同步處理**：涉及 I/O 密集型任務（如 HTTP 請求、資料庫查詢）時，優先採用 `async/await` 異步模式。
- **資源管理**：開啟檔案、網路連線或資料庫 Transaction 時，必須使用 `with` 上下文管理器 (Context Manager) 確保資源正確釋放。
- **資安防護**：
  - 絕對不要在程式碼或測試檔中寫死 (Hardcode) 任何 API Key、密碼或敏感憑證。
  - 敏感設定請一律改用 `pydantic-settings` 或 `python-dotenv` 讀取環境變數。

## 5. 單元測試規範 (Testing Standards)
- **測試框架**：預設採用 `pytest` 撰寫單元測試。
- **測試命名**：測試檔案命名為 `test_*.py`，測試函式命名為 `test_<function_name>_<scenario>()`。
- **Mock 機制**：測試外部 API 連線或資料庫時，一律使用 `unittest.mock` 或 `pytest-mock` 進行模擬，嚴禁直接發起實際網路請求。

## 6. 文件維護規範 (Documentation Rules)
- **README 同步檢查**：在協助新增、修改程式碼或改動專案架構後，請主動確認相關 `README.md` 文件是否需要同步更新（如 API 指令、環境變數需求、套件依賴等）。
- **重大變更更新**：若涉及**重大功能新增**或**架構調整**，必須同步對 `README.md` 文件進行相應的修訂或新增說明區塊。