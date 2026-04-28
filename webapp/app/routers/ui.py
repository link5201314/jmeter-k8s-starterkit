import csv
import json
import os
from datetime import datetime, timedelta
from typing import Optional

from fastapi import APIRouter, Form, Request
from fastapi.responses import RedirectResponse, Response
from fastapi.templating import Jinja2Templates

from pathlib import Path

from webapp.app.core.config import (
    CONFIG_DIR,
    HELM_ENV_VALUES_DIR,
    HELM_ENV_LEGACY_DIR,
    REPORT_DIR,
    SCENARIO_DIR,
)
from webapp.app.services.auth_service import (
    GROUPS,
    can_drive_tests,
    can_manage_configs,
    can_manage_projects,
    can_manage_users,
    change_password,
    create_user,
    current_user_from_request,
    delete_user,
    group_permissions,
    list_users,
    authenticate_user,
    reset_user_password,
    update_user_group,
)
from webapp.app.services.file_service import ensure_subpath
from webapp.app.services.report_service import discover_reports
from webapp.app.services.db_restore_service import list_restore_envs

router = APIRouter()
templates = Jinja2Templates(directory="webapp/app/templates")


def _is_selectable_helm_env_file(path) -> bool:
    if not path.is_file() or path.suffix != ".yaml":
        return False
    # Only show helm values env files; hide operational manifests like Secret/ConfigMap.
    blocked_tokens = ("-secret", "-configmap")
    return not any(token in path.stem for token in blocked_tokens)


def _helm_env_dir() -> Path:
    if HELM_ENV_VALUES_DIR.exists() and HELM_ENV_VALUES_DIR.is_dir():
        return HELM_ENV_VALUES_DIR
    return HELM_ENV_LEGACY_DIR


def _env_list(name: str) -> list[str]:
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return []

    if raw.startswith("["):
        try:
            data = json.loads(raw)
            if isinstance(data, list):
                return [str(item).strip() for item in data if str(item).strip()]
        except json.JSONDecodeError:
            pass

    values: list[str] = []
    for chunk in raw.replace("\r\n", "\n").split("\n"):
        for part in chunk.split(","):
            text = part.strip()
            if text:
                values.append(text)
    return values


def _read_csv_preview(csv_path, max_rows: int = 200) -> tuple[list[str], list[list[str]], bool]:
    text = csv_path.read_text(encoding="utf-8-sig")
    sample = text[:8192]

    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=",;\t|")
    except csv.Error:
        dialect = csv.get_dialect("excel")

    reader = csv.reader(text.splitlines(), dialect=dialect)
    headers: list[str] = []
    rows: list[list[str]] = []
    truncated = False

    for row in reader:
        if not row or not any((cell or "").strip() for cell in row):
            continue
        if not headers:
            headers = row
            continue
        if len(rows) >= max_rows:
            truncated = True
            break
        if len(row) < len(headers):
            row = row + [""] * (len(headers) - len(row))
        rows.append(row)

    return headers, rows, truncated


def _list_projects() -> list[str]:
    if not SCENARIO_DIR.exists():
        return []
    result: list[str] = []
    for p in sorted(SCENARIO_DIR.iterdir()):
        if not p.is_dir():
            continue
        if p.name.startswith("_"):
            continue
        if p.name in {"dataset", "module"}:
            continue
        result.append(p.name)
    return result


def _template_context(request: Request, extra: Optional[dict] = None) -> dict:
    user = current_user_from_request(request)
    permissions = group_permissions(str(user.get("group", ""))) if user else {
        "manage_users": False,
        "drive_tests": False,
        "manage_configs": False,
        "manage_projects": False,
        "manage_project_files": False,
        "view_reports_logs": False,
    }
    data = {
        "request": request,
        "current_user": user,
        "can_manage_users": permissions.get("manage_users", False),
        "can_drive_tests": permissions.get("drive_tests", False),
        "can_manage_configs": permissions.get("manage_configs", False),
        "can_manage_projects": permissions.get("manage_projects", False),
        "can_manage_project_files": permissions.get("manage_project_files", False),
        "can_view_reports_logs": permissions.get("view_reports_logs", False),
    }
    if extra:
        data.update(extra)
    return data


def _login_required(request: Request) -> dict | RedirectResponse:
    user = current_user_from_request(request)
    if not user:
        return RedirectResponse(url="/login", status_code=303)
    return user


def _drive_tests_required(request: Request) -> dict | Response:
    user = _login_required(request)
    if isinstance(user, RedirectResponse):
        return user
    if not can_drive_tests(user):
        return templates.TemplateResponse(
            "forbidden.html",
            _template_context(
                request,
                {
                    "message": "Tester 群組不可使用測試驅動功能。",
                },
            ),
            status_code=403,
        )
    return user


def _admin_required(request: Request) -> dict | Response:
    user = _login_required(request)
    if isinstance(user, RedirectResponse):
        return user
    if not can_manage_users(user):
        return templates.TemplateResponse(
            "forbidden.html",
            _template_context(
                request,
                {
                    "message": "你沒有使用者管理權限。",
                },
            ),
            status_code=403,
        )
    return user


def _config_manage_required(request: Request) -> dict | Response:
    user = _login_required(request)
    if isinstance(user, RedirectResponse):
        return user
    if not can_manage_configs(user):
        return templates.TemplateResponse(
            "forbidden.html",
            _template_context(
                request,
                {
                    "message": "你沒有設定管理權限。",
                },
            ),
            status_code=403,
        )
    return user


def _project_manage_required(request: Request) -> dict | Response:
    user = _login_required(request)
    if isinstance(user, RedirectResponse):
        return user
    if not can_manage_projects(user):
        return templates.TemplateResponse(
            "forbidden.html",
            _template_context(
                request,
                {
                    "message": "Viewer 群組僅可使用報告與 Logs 功能。",
                },
            ),
            status_code=403,
        )
    return user


@router.get("/login")
def login_page(request: Request):
    if current_user_from_request(request):
        return RedirectResponse(url="/", status_code=303)
    return templates.TemplateResponse(
        "login.html",
        _template_context(
            request,
            {
                "error": request.query_params.get("error", ""),
            },
        ),
    )


@router.post("/login")
def login_submit(request: Request, username: str = Form(...), password: str = Form(...)):
    user = authenticate_user(username, password)
    if not user:
        return RedirectResponse(url="/login?error=帳號或密碼錯誤", status_code=303)
    request.session["username"] = user["username"]
    return RedirectResponse(url="/", status_code=303)


@router.post("/logout")
def logout_submit(request: Request):
    request.session.clear()
    return RedirectResponse(url="/login", status_code=303)


@router.get("/")
def index(request: Request):
    user = _login_required(request)
    if isinstance(user, RedirectResponse):
        return user
    return templates.TemplateResponse("index.html", _template_context(request))


@router.get("/tests")
def tests_page(request: Request):
    user = _drive_tests_required(request)
    if isinstance(user, Response):
        return user
    projects = _list_projects()
    env_dir = _helm_env_dir()
    helm_envs = (
        sorted([p.stem for p in env_dir.glob("*.yaml") if _is_selectable_helm_env_file(p)])
        if env_dir.exists()
        else []
    )
    return templates.TemplateResponse("tests.html", _template_context(request, {"projects": projects, "helm_envs": helm_envs}))


@router.get("/db-restore")
def db_restore_page(request: Request):
    user = _drive_tests_required(request)
    if isinstance(user, Response):
        return user

    envs = list_restore_envs(CONFIG_DIR)
    return templates.TemplateResponse(
        "db_restore.html",
        _template_context(request, {"envs": envs}),
    )


@router.get("/oracle-flashback")
def oracle_flashback_page(request: Request):
    user = _drive_tests_required(request)
    if isinstance(user, Response):
        return user

    return templates.TemplateResponse(
        "oracle_flashback.html",
        _template_context(request),
    )


@router.get("/configs")
def configs_page(request: Request):
    user = _config_manage_required(request)
    if isinstance(user, Response):
        return user
    env_dir = _helm_env_dir()
    helm_envs = (
        sorted([p.stem for p in env_dir.glob("*.yaml") if _is_selectable_helm_env_file(p)])
        if env_dir.exists()
        else []
    )
    return templates.TemplateResponse(
        "configs.html",
        _template_context(request, {"helm_envs": helm_envs}),
    )


@router.get("/projects")
def projects_page(request: Request):
    user = _project_manage_required(request)
    if isinstance(user, Response):
        return user
    return templates.TemplateResponse("projects.html", _template_context(request, {"projects": _list_projects()}))


@router.get("/datasets")
def datasets_page(request: Request, file: Optional[str] = None, project: Optional[str] = "Others"):
    user = _project_manage_required(request)
    if isinstance(user, Response):
        return user

    projects = _list_projects()
    selected_project = (project or "Others").strip() or "Others"
    if selected_project != "Others" and selected_project not in projects:
        selected_project = "Others"

    def _matches_project_prefix(filename: str) -> bool:
        if selected_project == "Others":
            return not any(filename.startswith(f"{name}_") for name in projects)
        return filename.startswith(f"{selected_project}_")

    datasets: list[str] = []
    dataset_dir = SCENARIO_DIR / "dataset"
    selected_dataset = ""
    preview_headers: list[str] = []
    preview_rows: list[list[str]] = []
    preview_error = ""
    preview_truncated = False

    if dataset_dir.exists():
        datasets = sorted([p.name for p in dataset_dir.glob("*.csv") if _matches_project_prefix(p.name)])

    if file:
        selected_dataset = file
        try:
            selected_path = ensure_subpath(dataset_dir, dataset_dir / file)
            if selected_path.suffix.lower() != ".csv":
                preview_error = "只支援瀏覽 .csv 檔案"
            elif not selected_path.exists() or not selected_path.is_file():
                preview_error = f"找不到檔案：{file}"
            elif file not in datasets:
                preview_error = "目前專案篩選下無法瀏覽此檔案，請切換專案後再試"
            else:
                preview_headers, preview_rows, preview_truncated = _read_csv_preview(selected_path, max_rows=200)
        except ValueError:
            preview_error = "不合法的檔案路徑"
        except Exception as exc:
            preview_error = f"CSV 讀取失敗：{exc}"

    return templates.TemplateResponse(
        "datasets.html",
        _template_context(
            request,
            {
                "datasets": datasets,
                "projects": projects,
                "selected_project": selected_project,
                "selected_dataset": selected_dataset,
                "preview_headers": preview_headers,
                "preview_rows": preview_rows,
                "preview_error": preview_error,
                "preview_truncated": preview_truncated,
            },
        ),
    )


@router.get("/reports")
def reports_page(
    request: Request,
    project: Optional[str] = "all",
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
):
    user = _login_required(request)
    if isinstance(user, RedirectResponse):
        return user

    start_at = None
    end_at = None
    selected_start_date = (start_date or "").strip()
    selected_end_date = (end_date or "").strip()

    if selected_start_date:
        try:
            start_at = datetime.strptime(selected_start_date, "%Y-%m-%d")
        except ValueError:
            selected_start_date = ""

    if selected_end_date:
        try:
            end_at = datetime.strptime(selected_end_date, "%Y-%m-%d") + timedelta(days=1) - timedelta(seconds=1)
        except ValueError:
            selected_end_date = ""

    reports = discover_reports(REPORT_DIR, project=project, start_at=start_at, end_at=end_at)
    projects = sorted({r["project"] for r in discover_reports(REPORT_DIR)})
    if not projects:
        projects = []

    return templates.TemplateResponse(
        "reports.html",
        _template_context(
            request,
            {
                "reports": reports,
                "projects": projects,
                "selected_project": project or "all",
                "selected_start_date": selected_start_date,
                "selected_end_date": selected_end_date,
            },
        ),
    )


@router.get("/logs")
def logs_page(request: Request):
    user = _login_required(request)
    if isinstance(user, RedirectResponse):
        return user
    return templates.TemplateResponse(
        "logs.html",
        _template_context(
            request,
            {
                "projects": _list_projects(),
                "ignored_jmeter_warn_patterns": _env_list("WEBAPP_IGNORED_JMETER_WARN_PATTERNS"),
                "ignored_jmeter_info_patterns": _env_list("WEBAPP_IGNORED_JMETER_INFO_PATTERNS"),
                "ignored_jmeter_error_patterns": _env_list("WEBAPP_IGNORED_JMETER_ERROR_PATTERNS"),
            },
        ),
    )


@router.get("/users")
def users_page(request: Request):
    user = _admin_required(request)
    if isinstance(user, Response):
        return user

    return templates.TemplateResponse(
        "users.html",
        _template_context(
            request,
            {
                "users": list_users(),
                "groups": GROUPS,
                "message": request.query_params.get("message", ""),
                "error": request.query_params.get("error", ""),
            },
        ),
    )


@router.post("/users/create")
def users_create(
    request: Request,
    username: str = Form(...),
    group: str = Form(...),
    password: str = Form(...),
):
    user = _admin_required(request)
    if isinstance(user, Response):
        return user
    try:
        create_user(username=username, group=group, password=password)
        return RedirectResponse(url="/users?message=使用者建立成功", status_code=303)
    except ValueError as exc:
        return RedirectResponse(url=f"/users?error={exc}", status_code=303)


@router.post("/users/update-group")
def users_update_group(request: Request, username: str = Form(...), group: str = Form(...)):
    user = _admin_required(request)
    if isinstance(user, Response):
        return user
    try:
        update_user_group(username, group)
        return RedirectResponse(url="/users?message=群組更新成功", status_code=303)
    except ValueError as exc:
        return RedirectResponse(url=f"/users?error={exc}", status_code=303)


@router.post("/users/delete")
def users_delete(request: Request, username: str = Form(...)):
    user = _admin_required(request)
    if isinstance(user, Response):
        return user

    if str(user.get("username", "")).lower() == username.strip().lower():
        return RedirectResponse(url="/users?error=不可刪除目前登入中的帳號", status_code=303)

    try:
        delete_user(username)
        return RedirectResponse(url="/users?message=使用者刪除成功", status_code=303)
    except ValueError as exc:
        return RedirectResponse(url=f"/users?error={exc}", status_code=303)


@router.post("/users/reset-password")
def users_reset_password(
    request: Request,
    username: str = Form(...),
    new_password: str = Form(...),
):
    user = _admin_required(request)
    if isinstance(user, Response):
        return user

    current_username = str(user.get("username", "")).strip().lower()
    target_username = username.strip().lower()
    if current_username == target_username:
        return RedirectResponse(url="/users?error=不可在此重設自己的密碼，請使用右上角變更密碼", status_code=303)

    try:
        reset_user_password(username, new_password)
        return RedirectResponse(url="/users?message=密碼重設成功", status_code=303)
    except ValueError as exc:
        return RedirectResponse(url=f"/users?error={exc}", status_code=303)


@router.get("/change-password")
def change_password_page(request: Request):
    user = _login_required(request)
    if isinstance(user, RedirectResponse):
        return user
    return templates.TemplateResponse(
        "change_password.html",
        _template_context(
            request,
            {
                "message": request.query_params.get("message", ""),
                "error": request.query_params.get("error", ""),
            },
        ),
    )


@router.post("/change-password")
def change_password_submit(
    request: Request,
    old_password: str = Form(...),
    new_password: str = Form(...),
    confirm_password: str = Form(...),
):
    user = _login_required(request)
    if isinstance(user, RedirectResponse):
        return user

    if new_password != confirm_password:
        return RedirectResponse(url="/change-password?error=新密碼與確認密碼不一致", status_code=303)

    try:
        change_password(str(user.get("username", "")), old_password, new_password)
        return RedirectResponse(url="/change-password?message=密碼更新成功", status_code=303)
    except ValueError as exc:
        return RedirectResponse(url=f"/change-password?error={exc}", status_code=303)
