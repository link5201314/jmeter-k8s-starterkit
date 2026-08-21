from __future__ import annotations

import json
import subprocess
import threading
from datetime import datetime
from pathlib import Path

from webapp.app.core.config import REPO_ROOT


_jobs: dict[str, subprocess.Popen] = {}
_lock = threading.Lock()
_START_STATE_PATH = REPO_ROOT / "webapp" / "data" / "start_test_state.json"


def _now_text() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _write_json_atomic(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(".tmp")
    with tmp_path.open("w", encoding="utf-8") as fp:
        json.dump(data, fp, ensure_ascii=False, indent=2)
    tmp_path.replace(path)


def save_start_test_state(
    *,
    cmd: list[str],
    namespace: str,
    project: str,
    startup_grace_seconds: int = 180,
) -> None:
    """儲存啟動測試命令狀態，供頁面重整後讀取。"""
    state = {
        "active": True,
        "namespace": namespace,
        "project": project,
        "cmd": cmd,
        "cmd_text": " ".join(cmd),
        "created_at": _now_text(),
        "startup_grace_seconds": max(10, startup_grace_seconds),
        "observed_running_once": False,
    }
    _write_json_atomic(_START_STATE_PATH, state)


def load_start_test_state() -> dict | None:
    """讀取啟動測試命令狀態，若不存在或格式錯誤則回傳 None。"""
    if not _START_STATE_PATH.exists() or not _START_STATE_PATH.is_file():
        return None
    try:
        with _START_STATE_PATH.open("r", encoding="utf-8") as fp:
            data = json.load(fp)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def update_start_test_state(data: dict) -> None:
    """覆寫啟動測試命令狀態。"""
    if not isinstance(data, dict):
        return
    _write_json_atomic(_START_STATE_PATH, data)


def clear_start_test_state() -> None:
    """清除啟動測試命令狀態。"""
    _START_STATE_PATH.unlink(missing_ok=True)


def run_background(name: str, cmd: list[str], cwd: Path, log_path: Path) -> None:
    with _lock:
        if name in _jobs and _jobs[name].poll() is None:
            raise RuntimeError(f"{name} is still running")

        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_file = open(log_path, "a", encoding="utf-8")
        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )
        _jobs[name] = proc

        def _wait_and_close() -> None:
            proc.wait()
            log_file.close()

        threading.Thread(target=_wait_and_close, daemon=True).start()


def get_jobs_status() -> dict[str, str]:
    with _lock:
        result: dict[str, str] = {}
        for name, proc in _jobs.items():
            if proc.poll() is None:
                result[name] = "running"
            else:
                result[name] = f"exit:{proc.returncode}"
        return result
