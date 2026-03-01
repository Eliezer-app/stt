PYTHON ?= python3

.PHONY: prepare

prepare:
	$(PYTHON) -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -r requirements.txt
