import os

from fastapi import FastAPI
from starlette.middleware.sessions import SessionMiddleware
from fastapi.staticfiles import StaticFiles

from webapp.app.core.config import REPORT_DIR
from webapp.app.routers import api, ui
from webapp.app.services.auth_service import ensure_user_store

app = FastAPI(title="JMeter Web Console", version="0.1.0")

app.add_middleware(
	SessionMiddleware,
	secret_key=os.getenv("WEBAPP_SESSION_SECRET", "replace-this-secret-key"),
	same_site="lax",
)

app.mount("/static", StaticFiles(directory="webapp/app/static"), name="static")
app.mount("/report-static", StaticFiles(directory=str(REPORT_DIR), check_dir=False), name="report-static")

app.include_router(ui.router)
app.include_router(api.router)


@app.on_event("startup")
def _startup_init_users():
	ensure_user_store()
