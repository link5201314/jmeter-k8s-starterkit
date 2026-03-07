from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
from datetime import datetime
from pathlib import Path

from fastapi import HTTPException, Request

from webapp.app.core.config import REPO_ROOT

GROUP_ADMIN = "Admin"
GROUP_EXECUTOR = "Executor"
GROUP_TESTER = "Tester"
GROUP_VIEWER = "Viewer"
GROUPS = (GROUP_ADMIN, GROUP_EXECUTOR, GROUP_TESTER, GROUP_VIEWER)

_USERNAME_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{3,64}$")
_USER_STORE_PATH = REPO_ROOT / "webapp" / "data" / "users.json"


def _now_text() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _hash_password(password: str, iterations: int = 260000) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return f"pbkdf2_sha256${iterations}${salt.hex()}${digest.hex()}"


def _verify_password(password: str, stored: str) -> bool:
    try:
        algo, iter_text, salt_hex, digest_hex = stored.split("$", 3)
    except ValueError:
        return False
    if algo != "pbkdf2_sha256":
        return False
    try:
        iterations = int(iter_text)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(digest_hex)
    except ValueError:
        return False

    actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return hmac.compare_digest(actual, expected)


def _read_store() -> dict:
    if not _USER_STORE_PATH.exists():
        return {"users": []}
    with _USER_STORE_PATH.open("r", encoding="utf-8") as fp:
        data = json.load(fp)
    if not isinstance(data, dict):
        return {"users": []}
    users = data.get("users")
    if not isinstance(users, list):
        data["users"] = []
    return data


def _write_store(data: dict) -> None:
    _USER_STORE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = _USER_STORE_PATH.with_suffix(".tmp")
    with tmp_path.open("w", encoding="utf-8") as fp:
        json.dump(data, fp, ensure_ascii=False, indent=2)
    tmp_path.replace(_USER_STORE_PATH)


def _find_user(users: list[dict], username: str) -> tuple[int, dict] | tuple[None, None]:
    target = username.strip().lower()
    for idx, user in enumerate(users):
        name = str(user.get("username", "")).strip().lower()
        if name == target:
            return idx, user
    return None, None


def ensure_user_store() -> Path:
    _USER_STORE_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not _USER_STORE_PATH.exists():
        now = _now_text()
        data = {
            "users": [
                {
                    "username": "admin",
                    "group": GROUP_ADMIN,
                    "password": _hash_password("Admin123"),
                    "created_at": now,
                    "updated_at": now,
                }
            ]
        }
        _write_store(data)
        return _USER_STORE_PATH

    data = _read_store()
    users = data.get("users", [])
    _, admin = _find_user(users, "admin")
    if admin is None:
        now = _now_text()
        users.append(
            {
                "username": "admin",
                "group": GROUP_ADMIN,
                "password": _hash_password("Admin123"),
                "created_at": now,
                "updated_at": now,
            }
        )
        data["users"] = users
        _write_store(data)
    return _USER_STORE_PATH


def list_users() -> list[dict[str, str]]:
    data = _read_store()
    users = data.get("users", [])
    result: list[dict[str, str]] = []
    for user in users:
        result.append(
            {
                "username": str(user.get("username", "")),
                "group": str(user.get("group", GROUP_TESTER)),
                "created_at": str(user.get("created_at", "")),
                "updated_at": str(user.get("updated_at", "")),
            }
        )
    result.sort(key=lambda item: item["username"].lower())
    return result


def get_user(username: str) -> dict | None:
    data = _read_store()
    users = data.get("users", [])
    _, user = _find_user(users, username)
    if user is None:
        return None
    return {
        "username": str(user.get("username", "")),
        "group": str(user.get("group", GROUP_TESTER)),
        "created_at": str(user.get("created_at", "")),
        "updated_at": str(user.get("updated_at", "")),
    }


def authenticate_user(username: str, password: str) -> dict | None:
    data = _read_store()
    users = data.get("users", [])
    _, user = _find_user(users, username)
    if user is None:
        return None
    stored_password = str(user.get("password", ""))
    if not _verify_password(password, stored_password):
        return None
    return {
        "username": str(user.get("username", "")),
        "group": str(user.get("group", GROUP_TESTER)),
    }


def create_user(username: str, group: str, password: str) -> None:
    clean_username = username.strip()
    clean_group = group.strip()
    if not _USERNAME_PATTERN.fullmatch(clean_username):
        raise ValueError("使用者名稱格式不正確，僅允許英數與 . _ -，長度 3~64")
    if clean_group not in GROUPS:
        raise ValueError("群組不合法")
    if len(password) < 8:
        raise ValueError("密碼長度至少 8 碼")

    data = _read_store()
    users = data.get("users", [])
    _, existed = _find_user(users, clean_username)
    if existed is not None:
        raise ValueError("使用者已存在")

    now = _now_text()
    users.append(
        {
            "username": clean_username,
            "group": clean_group,
            "password": _hash_password(password),
            "created_at": now,
            "updated_at": now,
        }
    )
    data["users"] = users
    _write_store(data)


def _admin_count(users: list[dict]) -> int:
    return sum(1 for user in users if str(user.get("group", "")) == GROUP_ADMIN)


def update_user_group(username: str, new_group: str) -> None:
    clean_group = new_group.strip()
    if clean_group not in GROUPS:
        raise ValueError("群組不合法")

    data = _read_store()
    users = data.get("users", [])
    idx, user = _find_user(users, username)
    if idx is None or user is None:
        raise ValueError("使用者不存在")

    current_group = str(user.get("group", GROUP_TESTER))
    if current_group == GROUP_ADMIN and clean_group != GROUP_ADMIN and _admin_count(users) <= 1:
        raise ValueError("至少需保留一位 Admin")

    user["group"] = clean_group
    user["updated_at"] = _now_text()
    users[idx] = user
    data["users"] = users
    _write_store(data)


def delete_user(username: str) -> None:
    data = _read_store()
    users = data.get("users", [])
    idx, user = _find_user(users, username)
    if idx is None or user is None:
        raise ValueError("使用者不存在")

    if str(user.get("group", GROUP_TESTER)) == GROUP_ADMIN and _admin_count(users) <= 1:
        raise ValueError("至少需保留一位 Admin")

    users.pop(idx)
    data["users"] = users
    _write_store(data)


def change_password(username: str, old_password: str, new_password: str) -> None:
    if len(new_password) < 8:
        raise ValueError("新密碼長度至少 8 碼")

    data = _read_store()
    users = data.get("users", [])
    idx, user = _find_user(users, username)
    if idx is None or user is None:
        raise ValueError("使用者不存在")

    stored_password = str(user.get("password", ""))
    if not _verify_password(old_password, stored_password):
        raise ValueError("舊密碼不正確")

    user["password"] = _hash_password(new_password)
    user["updated_at"] = _now_text()
    users[idx] = user
    data["users"] = users
    _write_store(data)


def reset_user_password(username: str, new_password: str) -> None:
    if len(new_password) < 8:
        raise ValueError("新密碼長度至少 8 碼")

    data = _read_store()
    users = data.get("users", [])
    idx, user = _find_user(users, username)
    if idx is None or user is None:
        raise ValueError("使用者不存在")

    user["password"] = _hash_password(new_password)
    user["updated_at"] = _now_text()
    users[idx] = user
    data["users"] = users
    _write_store(data)


def group_permissions(group: str) -> dict[str, bool]:
    if group == GROUP_ADMIN:
        return {
            "manage_users": True,
            "drive_tests": True,
            "manage_project_files": True,
            "view_reports_logs": True,
        }
    if group == GROUP_EXECUTOR:
        return {
            "manage_users": False,
            "drive_tests": True,
            "manage_project_files": True,
            "view_reports_logs": True,
        }
    if group == GROUP_TESTER:
        return {
            "manage_users": False,
            "drive_tests": False,
            "manage_project_files": True,
            "view_reports_logs": True,
        }
    if group == GROUP_VIEWER:
        return {
            "manage_users": False,
            "drive_tests": False,
            "manage_project_files": False,
            "view_reports_logs": True,
        }
    return {
        "manage_users": False,
        "drive_tests": False,
        "manage_project_files": False,
        "view_reports_logs": False,
    }


def can_manage_users(user: dict | None) -> bool:
    if not user:
        return False
    return group_permissions(str(user.get("group", ""))).get("manage_users", False)


def can_drive_tests(user: dict | None) -> bool:
    if not user:
        return False
    return group_permissions(str(user.get("group", ""))).get("drive_tests", False)


def can_manage_project_files(user: dict | None) -> bool:
    if not user:
        return False
    return group_permissions(str(user.get("group", ""))).get("manage_project_files", False)


def current_user_from_request(request: Request) -> dict | None:
    username = request.session.get("username")
    if not isinstance(username, str) or not username.strip():
        return None
    return get_user(username)


def require_authenticated(request: Request) -> dict:
    user = current_user_from_request(request)
    if not user:
        raise HTTPException(status_code=401, detail="請先登入")
    return user


def require_drive_tests(request: Request) -> dict:
    user = require_authenticated(request)
    if not can_drive_tests(user):
        raise HTTPException(status_code=403, detail="無測試驅動權限")
    return user


def require_admin(request: Request) -> dict:
    user = require_authenticated(request)
    if not can_manage_users(user):
        raise HTTPException(status_code=403, detail="無使用者管理權限")
    return user
