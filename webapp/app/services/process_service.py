from __future__ import annotations

import subprocess
import threading
from pathlib import Path


_jobs: dict[str, subprocess.Popen] = {}
_lock = threading.Lock()


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
