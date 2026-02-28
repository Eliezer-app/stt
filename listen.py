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
import select
import socket
import sys
import time

import numpy as np
import torch
from pywhispercpp.model import Model

SAMPLE_RATE = 16000
CHUNK_MS = 80
CHUNK_SAMPLES = int(SAMPLE_RATE * CHUNK_MS / 1000)

# VAD
SILERO_THRESHOLD = 0.6
PRE_BUFFER_SEC = 1.0
POST_SILENCE_SEC = 0.6
MIN_SPEECH_SEC = 0.3
SILERO_CHUNK = 512


def load_silero():
    model, _ = torch.hub.load("snakers4/silero-vad", "silero_vad",
                              verbose=False, onnx=False)
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


def check_stdin(target):
    """Non-blocking check if a specific command arrived on stdin."""
    ready, _, _ = select.select([sys.stdin], [], [], 0)
    if ready:
        line = sys.stdin.readline()
        if not line:
            return "EOF"
        if line.strip() == target:
            return target
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-source", default="mic")
    parser.add_argument("--silence-timeout", type=float, default=5.0)
    parser.add_argument("--model", default="large-v3")
    args = parser.parse_args()

    # Load models once
    print("STT: loading Silero VAD...", file=sys.stderr, flush=True)
    vad = load_silero()
    print(f"STT: loading whisper model '{args.model}'...", file=sys.stderr, flush=True)
    whisper = Model(args.model, print_progress=False, redirect_whispercpp_logs_to=None)
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
    silero_buf = np.zeros(0, dtype=np.float32)
    pre_buf_maxlen = int(PRE_BUFFER_SEC / (CHUNK_MS / 1000))
    pre_buffer = collections.deque(maxlen=pre_buf_maxlen)

    for chunk in chunks:
        if not active:
            # Idle — drain audio, wait for START
            cmd = check_stdin("START")
            if cmd == "EOF":
                break
            if cmd == "START":
                active = True
                recording = False
                frames = []
                silence_start = None
                last_speech_time = time.time()
                silero_buf = np.zeros(0, dtype=np.float32)
                pre_buffer.clear()
                vad.reset_states()
                print("STT: active", file=sys.stderr, flush=True)
            continue

        # Active — check for STOP
        cmd = check_stdin("STOP")
        if cmd in ("STOP", "EOF"):
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
            if prob > SILERO_THRESHOLD:
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
                if args.silence_timeout > 0 and \
                   time.time() - last_speech_time > args.silence_timeout:
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
                elif time.time() - silence_start >= POST_SILENCE_SEC:
                    audio = np.concatenate(frames)
                    duration = len(audio) / SAMPLE_RATE

                    if duration >= MIN_SPEECH_SEC:
                        segments = whisper.transcribe(audio, language="auto",
                                                     translate=False)
                        text = " ".join(seg.text.strip()
                                        for seg in segments).strip()
                        if text:
                            print(text, flush=True)

                    recording = False
                    frames = []
                    silence_start = None
                    pre_buffer.clear()
                    vad.reset_states()
                    silero_buf = np.zeros(0, dtype=np.float32)
                    last_speech_time = time.time()


if __name__ == "__main__":
    main()
