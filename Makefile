PYTHON ?= python3

.PHONY: prepare

prepare:
	$(PYTHON) -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -r requirements.txt
	.venv/bin/python -c "import torch; torch.hub.load('snakers4/silero-vad', 'silero_vad', verbose=False, onnx=False, trust_repo=True)"
	.venv/bin/python -c "from pywhispercpp.model import Model; Model('large-v3', print_progress=True)"
