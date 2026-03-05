PYTHON ?= $(shell if command -v python3.12 >/dev/null 2>&1; then echo python3.12; else echo python3; fi)
VENV_DIR ?= .venv312
VENV_BIN := $(VENV_DIR)/bin
PIP := $(VENV_BIN)/pip
UVICORN := $(VENV_BIN)/uvicorn
WEBAPP_IMAGE ?= jmeter-webapp:latest
WEBAPP_IMAGE_TAR ?= /tmp/jmeter-webapp_latest.tar

.PHONY: venv install webapp-run webapp-dev check clean clean-venv-old webapp-image-build webapp-image-load-k3s webapp-image-build-load-k3s

venv:
	$(PYTHON) -m venv $(VENV_DIR)
	$(PIP) install --upgrade pip

install: venv
	$(PIP) install -r webapp/requirements.txt

webapp-run: install
	$(UVICORN) webapp.app.main:app --host 0.0.0.0 --port 8080

webapp-dev: install
	$(UVICORN) webapp.app.main:app --reload --host 0.0.0.0 --port 8080

check: install
	$(VENV_BIN)/python -m compileall webapp/app

clean:
	rm -rf $(VENV_DIR)

clean-venv-old:
	rm -rf .venv

webapp-image-build:
	podman build -f webapp/Dockerfile -t $(WEBAPP_IMAGE) .

webapp-image-load-k3s:
	podman save -o $(WEBAPP_IMAGE_TAR) $(WEBAPP_IMAGE)
	sudo /usr/local/bin/k3s ctr images import $(WEBAPP_IMAGE_TAR)

webapp-image-build-load-k3s: webapp-image-build webapp-image-load-k3s
