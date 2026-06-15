from __future__ import annotations

import json

from webapp.app.core.config import REPO_ROOT

_META_STORE_PATH = REPO_ROOT / "webapp" / "data" / "report_meta.json"


def _read_meta_store() -> dict:
    if not _META_STORE_PATH.exists():
        return {"reports": {}}
    try:
        with _META_STORE_PATH.open("r", encoding="utf-8") as fp:
            data = json.load(fp)
    except (OSError, json.JSONDecodeError):
        return {"reports": {}}

    if not isinstance(data, dict):
        return {"reports": {}}
    reports = data.get("reports")
    if not isinstance(reports, dict):
        data["reports"] = {}
    return data


def _write_meta_store(data: dict) -> None:
    _META_STORE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = _META_STORE_PATH.with_suffix(".tmp")
    with tmp_path.open("w", encoding="utf-8") as fp:
        json.dump(data, fp, ensure_ascii=False, indent=2)
    tmp_path.replace(_META_STORE_PATH)


def get_report_meta(rel_path: str) -> dict:
    store = _read_meta_store()
    reports = store.get("reports", {})
    meta = reports.get(rel_path, {})
    return {
        "is_important": bool(meta.get("is_important", False)),
        "notes": str(meta.get("notes", "") or ""),
    }


def set_report_important(rel_path: str, value: bool) -> None:
    store = _read_meta_store()
    reports = store.setdefault("reports", {})
    meta = reports.get(rel_path, {})
    meta["is_important"] = bool(value)
    meta.setdefault("notes", "")
    reports[rel_path] = meta
    _write_meta_store(store)


def set_report_notes(rel_path: str, notes: str) -> None:
    store = _read_meta_store()
    reports = store.setdefault("reports", {})
    meta = reports.get(rel_path, {})
    meta.setdefault("is_important", False)
    meta["notes"] = str(notes)
    reports[rel_path] = meta
    _write_meta_store(store)


def delete_report_meta(rel_path: str) -> None:
    store = _read_meta_store()
    reports = store.get("reports", {})
    if rel_path in reports:
        reports.pop(rel_path, None)
        _write_meta_store(store)