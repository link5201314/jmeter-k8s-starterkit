from __future__ import annotations

import csv
import posixpath
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from xml.etree import ElementTree as ET

BIN_DATASET_DIR = "/opt/jmeter/apache-jmeter/bin"
_ALLOWED_FILTERS = {"All", "Unattached"}
_PROP_PATTERN = re.compile(r"\$\{__P\(\s*([^,\)]+)\s*,\s*(.*?)\)\}")
_VAR_PATTERN = re.compile(r"\$\{([^{}]+)\}")


@dataclass
class CsvReference:
    dataset_name: str
    raw_path: str
    resolved_path: str
    path_valid: bool
    source_jmx: str


def normalize_filter(filter_value: str, projects: list[str]) -> str:
    selected = (filter_value or "All").strip() or "All"
    if selected in _ALLOWED_FILTERS:
        return selected
    if selected in projects:
        return selected
    return "All"


def build_filter_options(projects: list[str]) -> list[str]:
    return ["All", "Unattached", *projects]


def list_dataset_files(dataset_dir: Path) -> list[Path]:
    if not dataset_dir.exists() or not dataset_dir.is_dir():
        return []
    return sorted(path for path in dataset_dir.glob("*.csv") if path.is_file())


def count_csv_rows(file_path: Path) -> Optional[int]:
    """
    計算 CSV 檔案的行數（包含表頭）。
    若計算失敗則返回 None。
    """
    if not file_path.exists() or not file_path.is_file():
        return None

    try:
        with open(file_path, 'r', encoding='utf-8', errors='replace') as f:
            reader = csv.reader(f)
            return sum(1 for _ in reader)
    except Exception:
        return None


def read_project_env(project_dir: Path) -> dict[str, str]:
    env_path = project_dir / ".env"
    if not env_path.exists() or not env_path.is_file():
        return {}

    result: dict[str, str] = {}
    for raw_line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            continue
        result[key] = value.strip()
    return result


def _parse_jmx_variables(root: ET.Element) -> dict[str, str]:
    values: dict[str, str] = {}
    for element in root.findall(".//elementProp[@elementType='Argument']"):
        key_node = element.find("./stringProp[@name='Argument.name']")
        val_node = element.find("./stringProp[@name='Argument.value']")
        if key_node is None or val_node is None:
            continue
        key = (key_node.text or "").strip()
        if not key:
            continue
        values[key] = (val_node.text or "").strip()
    return values


def _resolve_text(text: str, variables: dict[str, str], env_vars: dict[str, str], depth: int = 0) -> str:
    if depth > 12:
        return text

    def replace_prop(match: re.Match[str]) -> str:
        key = (match.group(1) or "").strip()
        default_value = (match.group(2) or "").strip()
        if key in env_vars and env_vars[key] != "":
            return env_vars[key]
        return _resolve_text(default_value, variables, env_vars, depth + 1)

    def replace_var(match: re.Match[str]) -> str:
        key = (match.group(1) or "").strip()
        if key in env_vars and env_vars[key] != "":
            return env_vars[key]
        if key in variables:
            return _resolve_text(variables[key], variables, env_vars, depth + 1)
        return match.group(0)

    updated = _PROP_PATTERN.sub(replace_prop, text)
    updated = _VAR_PATTERN.sub(replace_var, updated)

    if updated == text:
        return updated
    return _resolve_text(updated, variables, env_vars, depth + 1)


def _to_posix(path_text: str) -> str:
    return (path_text or "").replace("\\", "/").strip()


def _normalize_against_bin(path_text: str) -> str:
    if not path_text:
        return ""
    normalized = _to_posix(path_text)
    if normalized.startswith("/"):
        return posixpath.normpath(normalized)
    return posixpath.normpath(posixpath.join(BIN_DATASET_DIR, normalized))


def _extract_dataset_name(path_text: str) -> str:
    candidate = posixpath.basename(_to_posix(path_text))
    return candidate.strip()


def _is_valid_dataset_mapping(dataset_name: str, resolved_path: str) -> bool:
    if not dataset_name.lower().endswith(".csv"):
        return False
    target = posixpath.normpath(f"{BIN_DATASET_DIR}/{dataset_name}")
    return _normalize_against_bin(resolved_path) == target


def scan_project_csv_references(project_dir: Path) -> list[CsvReference]:
    env_vars = read_project_env(project_dir)
    refs: list[CsvReference] = []

    for jmx_path in sorted(project_dir.glob("*.jmx")):
        try:
            root = ET.parse(jmx_path).getroot()
        except ET.ParseError:
            continue

        variables = _parse_jmx_variables(root)

        for filename_node in root.findall(".//CSVDataSet/stringProp[@name='filename']"):
            raw_path = (filename_node.text or "").strip()
            if not raw_path:
                continue

            resolved_path = _resolve_text(raw_path, variables, env_vars)
            dataset_name = _extract_dataset_name(resolved_path)
            if not dataset_name.lower().endswith(".csv"):
                dataset_name = _extract_dataset_name(raw_path)

            if not dataset_name.lower().endswith(".csv"):
                continue

            refs.append(
                CsvReference(
                    dataset_name=dataset_name,
                    raw_path=raw_path,
                    resolved_path=resolved_path,
                    path_valid=_is_valid_dataset_mapping(dataset_name, resolved_path),
                    source_jmx=jmx_path.name,
                )
            )

    return refs


def build_project_dataset_items(
    project_dir: Path,
    dataset_dir: Path,
    owner_section: dict,
) -> list[dict]:
    refs = scan_project_csv_references(project_dir)

    merged: dict[str, dict] = {}
    for ref in refs:
        current = merged.get(ref.dataset_name)
        if not current:
            merged[ref.dataset_name] = {
                "name": ref.dataset_name,
                "status": "已上傳" if (dataset_dir / ref.dataset_name).exists() else "尚未上傳",
                "path_valid": ref.path_valid,
                "raw_paths": [ref.raw_path],
                "resolved_paths": [ref.resolved_path],
                "sources": [ref.source_jmx],
            }
            continue

        current["raw_paths"].append(ref.raw_path)
        current["resolved_paths"].append(ref.resolved_path)
        current["sources"].append(ref.source_jmx)
        current["path_valid"] = bool(current["path_valid"]) and ref.path_valid

    items: list[dict] = []
    for name in sorted(merged.keys()):
        target = dataset_dir / name
        info = merged[name]
        exists = target.exists() and target.is_file()
        if not info["path_valid"]:
            status = "路徑不正確"
        elif exists:
            status = "已上傳"
        else:
            status = "尚未上傳"

        owner_key = name.strip().lower()
        owner_record = owner_section.get(owner_key) if isinstance(owner_section, dict) else None
        owner_updated_at = str((owner_record or {}).get("updated_at", "")).strip()
        file_mtime = (
            target.stat().st_mtime if exists else None
        )
        latest_upload_at = owner_updated_at
        if not latest_upload_at and file_mtime is not None:
            from datetime import datetime

            latest_upload_at = datetime.fromtimestamp(file_mtime).strftime("%Y-%m-%d %H:%M:%S")

        # 從 owner_record 讀取緩存的 row_count，而非即時計算
        row_count = (owner_record or {}).get("row_count") if owner_record else None

        items.append(
            {
                "name": name,
                "status": status,
                "latest_upload_at": latest_upload_at,
                "exists": exists,
                "path_valid": bool(info["path_valid"]),
                "can_upload": bool(info["path_valid"]),
                "show_delete": False,
                "source_jmx_files": sorted(set(info["sources"])),
                "row_count": row_count,
            }
        )

    return items


def build_all_dataset_items(dataset_dir: Path, owner_section: dict) -> list[dict]:
    items: list[dict] = []
    for path in list_dataset_files(dataset_dir):
        owner_key = path.name.strip().lower()
        owner_record = owner_section.get(owner_key) if isinstance(owner_section, dict) else None
        owner_updated_at = str((owner_record or {}).get("updated_at", "")).strip()
        latest_upload_at = owner_updated_at
        if not latest_upload_at:
            from datetime import datetime

            latest_upload_at = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")

        # 從 owner_record 讀取緩存的 row_count，而非即時計算
        row_count = (owner_record or {}).get("row_count") if owner_record else None

        items.append(
            {
                "name": path.name,
                "status": "已上傳",
                "latest_upload_at": latest_upload_at,
                "exists": True,
                "path_valid": True,
                "can_upload": True,
                "show_delete": False,
                "row_count": row_count,
            }
        )
    return items


def build_unattached_dataset_items(
    dataset_dir: Path,
    projects: list[str],
    scenario_dir: Path,
    owner_section: dict,
) -> list[dict]:
    matched: set[str] = set()
    for project in projects:
        refs = scan_project_csv_references(scenario_dir / project)
        for ref in refs:
            if ref.path_valid:
                matched.add(ref.dataset_name)

    items: list[dict] = []
    for path in list_dataset_files(dataset_dir):
        if path.name in matched:
            continue

        owner_key = path.name.strip().lower()
        owner_record = owner_section.get(owner_key) if isinstance(owner_section, dict) else None
        owner_updated_at = str((owner_record or {}).get("updated_at", "")).strip()
        latest_upload_at = owner_updated_at
        if not latest_upload_at:
            from datetime import datetime

            latest_upload_at = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")

        # 從 owner_record 讀取緩存的 row_count，而非即時計算
        row_count = (owner_record or {}).get("row_count") if owner_record else None

        items.append(
            {
                "name": path.name,
                "status": "未被專案使用",
                "latest_upload_at": latest_upload_at,
                "exists": True,
                "path_valid": True,
                "can_upload": True,
                "show_delete": True,
                "row_count": row_count,
            }
        )

    return items


def pick_dataset_target_name(item_name: str, uploaded_filename: Optional[str]) -> str:
    expected = (item_name or "").strip()
    uploaded = (uploaded_filename or "").strip()

    if expected:
        return expected
    return uploaded


def scan_and_cache_all_csv_row_counts(dataset_dir: Path, owner_section: dict) -> dict:
    """
    掃描所有 CSV 檔案，並根據時間戳邏輯決定是否需要重新計算行數。
    
    時間戳比對邏輯：
    - 如果 owner_section 中記錄的 updated_at 與檔案的 mtime 不相符，
      即使已有 row_count 也要重新計算
    - 如果時間相符且已有 row_count，則跳過（無需重新計算）
    - 如果時間相符但無 row_count，則計算並記錄
    
    返回統計結果：
    {
        'recalculated': int,  # 重新計算的檔案數
        'skipped': int,        # 跳過的檔案數
        'failed': int          # 計算失敗的檔案數
    }
    """
    from datetime import datetime
    
    results = {'recalculated': 0, 'skipped': 0, 'failed': 0}
    
    if not dataset_dir.exists() or not dataset_dir.is_dir():
        return results
    
    for file_path in list_dataset_files(dataset_dir):
        owner_key = file_path.name.strip().lower()
        owner_record = owner_section.get(owner_key) if isinstance(owner_section, dict) else None
        
        if owner_record is None:
            owner_record = {}
            owner_section[owner_key] = owner_record
        
        # 獲取記錄中的 updated_at（如果存在）
        recorded_updated_at_str = str((owner_record or {}).get("updated_at", "")).strip()
        recorded_row_count = (owner_record or {}).get("row_count")
        
        # 獲取檔案的實際修改時間
        try:
            file_mtime = file_path.stat().st_mtime
            file_mtime_str = datetime.fromtimestamp(file_mtime).strftime("%Y-%m-%d %H:%M:%S")
        except Exception:
            results['failed'] += 1
            continue
        
        # 時間戳比對邏輯：比對格式化後的時間戳字符串
        # 注意：由於格式只精確到秒，所以用字符串比對是可以的
        # 如果需要更精確的比對，可以使用完整的 mtime 值
        needs_recalculation = (
            recorded_updated_at_str != file_mtime_str or  # 時間不相符
            recorded_row_count is None  # 或者沒有 row_count
        )
        
        if needs_recalculation:
            # 需要重新計算
            try:
                new_row_count = count_csv_rows(file_path)
                if new_row_count is not None:
                    owner_record['row_count'] = new_row_count
                    owner_record['updated_at'] = file_mtime_str
                    results['recalculated'] += 1
                else:
                    results['failed'] += 1
            except Exception:
                results['failed'] += 1
        else:
            # 跳過（時間相符且已有 row_count）
            results['skipped'] += 1
    
    return results
