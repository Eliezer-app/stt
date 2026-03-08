"""Thin launcher: reads config.yaml and execs eli-stt with the right flags."""

import os
import sys
from pathlib import Path

import yaml

_DIR = Path(__file__).resolve().parent

with open(_DIR / "config.yaml") as f:
    cfg = yaml.safe_load(f)

model = cfg.get("model", {})

cmd = [str(_DIR / "eli-stt"), "-d", "-p"]

timeout = model.get("silence_timeout")
if timeout:
    cmd.extend(["-t", str(timeout)])

stop_word = model.get("stop_word")
if stop_word:
    cmd.extend(["-s", str(stop_word)])

os.execv(cmd[0], cmd)
