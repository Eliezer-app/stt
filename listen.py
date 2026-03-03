"""
STT listener: Silero VAD + pywhispercpp (Metal GPU).

Loads models once at startup, then waits for START on stdin.
Accumulates audio while speech is detected, transcribes complete
utterances after silence. Prints END when silence timeout expires,
then waits for next START. Drains audio while idle so the socket
doesn't back up.

Protocol (stdin/stdout):
  stdin:  "START\n" — begin listening
  stdout: transcribed text lines
  stdout: "END\n"   — silence timeout, back to idle

Usage:
  python listen.py --audio-source /tmp/speech-audio.sock
  python listen.py  # mic (default)
"""

import argparse
import collections
import json
import select
import socket
import sys
import time

from pathlib import Path

import numpy as np
import torch
import yaml
from pywhispercpp.model import Model

_DIR = Path(__file__).resolve().parent

SAMPLE_RATE = 16000
CHUNK_MS = 80
CHUNK_SAMPLES = int(SAMPLE_RATE * CHUNK_MS / 1000)
SILERO_CHUNK = 512


def load_config():
    with open(_DIR / "config.yaml") as f:
        return yaml.safe_load(f)


def check_models(whisper_model):
    """Fail fast if models aren't pre-downloaded. Run make prepare."""
    from pathlib import Path
    hub_dir = Path(torch.hub.get_dir())
    silero = list(hub_dir.glob("snakers4_silero-vad*"))
    if not silero:
        print("ERROR: Silero VAD not found. Run: make prepare",
              file=sys.stderr, flush=True)
        sys.exit(1)
    # pywhispercpp stores models in platform-specific app support dir
    home = Path.home()
    whisper_paths = [
        home / "Library" / "Application Support" / "pywhispercpp" / "models" / f"ggml-{whisper_model}.bin",
        home / ".local" / "share" / "pywhispercpp" / "models" / f"ggml-{whisper_model}.bin",
    ]
    if not any(p.exists() for p in whisper_paths):
        print(f"ERROR: Whisper model '{whisper_model}' not found. Run: make prepare",
              file=sys.stderr, flush=True)
        sys.exit(1)


def load_silero():
    model, _ = torch.hub.load("snakers4/silero-vad", "silero_vad",
                              verbose=False, onnx=False, trust_repo=True)
    return model


def vad_speech_prob(model, audio_chunk):
    t = torch.from_numpy(audio_chunk)
    return model(t, SAMPLE_RATE).item()


def audio_from_mic():
    import sounddevice as sd
    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                        blocksize=CHUNK_SAMPLES) as stream:
        while True:
            chunk, _ = stream.read(CHUNK_SAMPLES)
            yield chunk[:, 0]


def audio_from_socket(sock_path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(sock_path)
    chunk_bytes = CHUNK_SAMPLES * 4
    buf = b""
    try:
        while True:
            while len(buf) < chunk_bytes:
                data = sock.recv(chunk_bytes - len(buf))
                if not data:
                    return
                buf += data
            yield np.frombuffer(buf[:chunk_bytes], dtype=np.float32)
            buf = buf[chunk_bytes:]
    finally:
        sock.close()


def read_stdin_cmd():
    """Non-blocking read of a JSON command from stdin. Returns (cmd, data) or None."""
    ready, _, _ = select.select([sys.stdin], [], [], 0)
    if ready:
        line = sys.stdin.readline()
        if not line:
            return ("EOF", {})
        line = line.strip()
        try:
            data = json.loads(line)
            return (data.get("cmd", ""), data)
        except json.JSONDecodeError:
            # Plain text fallback (e.g. "STOP")
            return (line, {})
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-source", default="mic")
    args = parser.parse_args()

    cfg = load_config()
    vad_cfg = cfg.get("voice_detection", {})
    model_cfg = cfg.get("model", {})

    model_name = model_cfg.get("name", "large-v3")
    silence_timeout = model_cfg.get("silence_timeout", 5.0)
    silero_threshold = vad_cfg.get("threshold", 0.5)
    pre_buffer_sec = vad_cfg.get("pre_buffer_sec", 1.0)
    post_silence_sec = vad_cfg.get("post_silence_sec", 0.6)
    min_speech_sec = vad_cfg.get("min_speech_sec", 0.3)

    check_models(model_name)

    # Load models once
    print("STT: loading Silero VAD...", file=sys.stderr, flush=True)
    vad = load_silero()
    print(f"STT: loading whisper model '{model_name}'...", file=sys.stderr, flush=True)
    whisper = Model(model_name, print_progress=False, redirect_whispercpp_logs_to=None)
    print("STT: ready", file=sys.stderr, flush=True)

    # Audio source
    if args.audio_source == "mic":
        chunks = audio_from_mic()
    else:
        chunks = audio_from_socket(args.audio_source)

    active = False
    recording = False
    frames = []
    silence_start = None
    last_speech_time = 0
    context = ""
    silero_buf = np.zeros(0, dtype=np.float32)
    pre_buf_maxlen = int(pre_buffer_sec / (CHUNK_MS / 1000))
    pre_buffer = collections.deque(maxlen=pre_buf_maxlen)

    for chunk in chunks:
        if not active:
            # Idle — drain audio, wait for START
            result = read_stdin_cmd()
            if result and result[0] == "EOF":
                break
            if result and result[0] == "START":
                active = True
                recording = False
                frames = []
                transcript = []
                silence_start = None
                last_speech_time = time.time()
                context = result[1].get("context", "")
                silero_buf = np.zeros(0, dtype=np.float32)
                pre_buffer.clear()
                vad.reset_states()
                if context:
                    print(f"STT: active (context: {context[:80]})", file=sys.stderr, flush=True)
                else:
                    print("STT: active", file=sys.stderr, flush=True)
            continue

        # Active — check for STOP
        result = read_stdin_cmd()
        if result and result[0] in ("STOP", "EOF"):
            active = False
            print("END", flush=True)
            print("STT: idle", file=sys.stderr, flush=True)
            continue

        # Feed chunk to silero
        silero_buf = np.append(silero_buf, chunk)
        is_speech = False
        while len(silero_buf) >= SILERO_CHUNK:
            prob = vad_speech_prob(vad, silero_buf[:SILERO_CHUNK])
            silero_buf = silero_buf[SILERO_CHUNK:]
            if prob > silero_threshold:
                is_speech = True

        if not recording:
            if is_speech:
                recording = True
                silence_start = None
                frames = list(pre_buffer)
                frames.append(chunk)
                pre_buffer.clear()
                vad.reset_states()
                last_speech_time = time.time()
            else:
                pre_buffer.append(chunk)
                if silence_timeout > 0 and \
                   time.time() - last_speech_time > silence_timeout:
                    active = False
                    print("END", flush=True)
                    print("STT: idle (silence timeout)", file=sys.stderr, flush=True)
        else:
            frames.append(chunk)
            if is_speech:
                silence_start = None
                last_speech_time = time.time()
            else:
                if silence_start is None:
                    silence_start = time.time()
                elif time.time() - silence_start >= post_silence_sec:
                    audio = np.concatenate(frames)
                    duration = len(audio) / SAMPLE_RATE

                    if duration >= min_speech_sec:
                        prompt = " ".join([context] + transcript) if transcript else context
                        kwargs = {"language": "", "translate": False}
                        if prompt:
                            kwargs["initial_prompt"] = prompt
                        segments = whisper.transcribe(audio, **kwargs)
                        text = " ".join(seg.text.strip()
                                        for seg in segments).strip()
                        if text:
                            print(text, flush=True)
                            transcript.append(text)

                    recording = False
                    frames = []
                    silence_start = None
                    pre_buffer.clear()
                    vad.reset_states()
                    silero_buf = np.zeros(0, dtype=np.float32)
                    last_speech_time = time.time()


if __name__ == "__main__":
    main()
