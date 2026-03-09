PYTHON ?= python3

.PHONY: prepare listen build

prepare:
	$(PYTHON) -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -r requirements.txt

build: eli-stt eli-tts listen-stop

eli-stt: eli-stt.swift
	swiftc eli-stt.swift -o eli-stt -O
	codesign -s - --entitlements eli-stt.entitlements --options runtime -f eli-stt

eli-tts: eli-tts.swift
	swiftc eli-tts.swift -o eli-tts -O

listen-stop: listen-stop.swift
	swiftc listen-stop.swift -o listen-stop -O
	codesign -s - --entitlements eli-stt.entitlements --options runtime -f listen-stop

listen:
	.venv/bin/python listen.py --auto-start
