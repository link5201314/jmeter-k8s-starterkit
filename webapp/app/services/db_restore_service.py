from __future__ import annotations

import json
import re
from pathlib import Path
from urllib.parse import urljoin

_ENV_FILE_PATTERN = re.compile(r"^jmeter\.(.+)\.env$")


def list_restore_envs(config_dir: Path) -> list[str]:
    if not config_dir.exists() or not config_dir.is_dir():
        return []

    envs: list[str] = []
    for path in sorted(config_dir.glob("jmeter.*.env")):
        match = _ENV_FILE_PATTERN.match(path.name)
        if not match:
            continue
        env = match.group(1).strip()
        if env:
            envs.append(env)
    return envs


def _read_env_file(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists() or not path.is_file():
        return data

    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip().strip('"').strip("'")
    return data


def get_flashback_endpoint(config_dir: Path, env: str) -> str:
    env_name = env.strip()
    if not env_name:
        return ""
    env_file = config_dir / f"jmeter.{env_name}.env"
    values = _read_env_file(env_file)
    return values.get("JMETER_FLASHBACK_DB_API", "").strip()


def _mask_secret(secret: str) -> str:
    token = secret.strip()
    if not token:
        return "<MISSING>"
    if len(token) <= 8:
        return "*" * len(token)
    return f"{token[:4]}***{token[-4:]}"


def load_env_token(secret_file: Path, env: str) -> str:
    if not secret_file.exists() or not secret_file.is_file():
        return ""

    try:
        payload = json.loads(secret_file.read_text(encoding="utf-8"))
    except Exception:
        return ""

    if not isinstance(payload, dict):
        return ""

    value = payload.get(env, "")
    return value if isinstance(value, str) else ""


def build_preview_request(
    *,
    endpoint: str,
    token: str,
    action: str,
    task_id: str = "",
    project: str = "",
    note: str = "",
) -> dict:
    clean_endpoint = endpoint.strip()
    if not clean_endpoint:
        raise ValueError("JMETER_FLASHBACK_DB_API 尚未設定")

    action_name = action.strip().lower()
    if action_name not in {"create", "status", "list", "cancel"}:
        raise ValueError("不支援的動作")

    base = clean_endpoint.rstrip("/") + "/"

    if action_name == "create":
        method = "POST"
        url = urljoin(base, "api/v1/flashback/jobs")
        body = {
            "project": project.strip(),
            "note": note.strip(),
        }
    elif action_name == "status":
        if not task_id.strip():
            raise ValueError("查詢任務狀態需要 task_id")
        method = "GET"
        url = urljoin(base, f"api/v1/flashback/jobs/{task_id.strip()}")
        body = None
    elif action_name == "list":
        method = "GET"
        url = urljoin(base, "api/v1/flashback/jobs")
        body = None
    else:
        if not task_id.strip():
            raise ValueError("取消任務需要 task_id")
        method = "POST"
        url = urljoin(base, f"api/v1/flashback/jobs/{task_id.strip()}/cancel")
        body = {"reason": "cancel requested from jmeter web console"}

    return {
        "simulate_only": True,
        "method": method,
        "url": url,
        "headers": {
            "Authorization": f"Bearer {_mask_secret(token)}",
            "Content-Type": "application/json",
        },
        "body": body,
    }
