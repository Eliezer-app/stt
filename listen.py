"""
STT listener using Apple's on-device speech recognition (hear).

Waits for START on stdin, spawns `hear` for each listening session,
forwards incremental transcription lines to stdout. Each line from
hear is the full transcription so far (replaces previous, not additive).
Prints END when hear exits (silence timeout) or on STOP.

When --audio-source is a socket path, reads audio from the socket and
pipes it to hear's stdin (16kHz mono float32 PCM). This ensures the
orchestrator's audio muting works for STT too.

When --audio-source is "mic" (default), hear captures directly from
the system microphone.

Protocol (stdin/stdout):
  stdin:  {"cmd":"START"} — begin listening (spawn hear)
  stdin:  {"cmd":"STOP"}  — stop current session
  stdout: transcription lines (each line = full text so far)
  stdout: "END"           — session over, back to idle

Usage:
  python listen.py --audio-source /tmp/speech-audio.sock
  python listen.py --auto-start  # standalone (mic)
"""

import argparse
import json
import os
import select
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import yaml

_DIR = Path(__file__).resolve().parent

SAMPLE_RATE = 16000
CHUNK_SAMPLES = 1280  # 80ms
CHUNK_BYTES = CHUNK_SAMPLES * 4  # float32


def load_config():
    with open(_DIR / "config.yaml") as f:
        return yaml.safe_load(f)


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
            return (line, {})
    return None


running = True
_sigcount = 0


def _handle_signal(*_):
    global running, _sigcount
    _sigcount += 1
    running = False
    if _sigcount >= 2:
        os._exit(1)


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


def spawn_hear(timeout=None, locale="en-US", pipe_stdin=False):
    """Spawn hear subprocess. Returns Popen object."""
    cmd = [str(_DIR / "eli-stt"), "-d", "-p", "-l", locale]
    if timeout:
        cmd.extend(["-t", str(timeout)])
    stdin = subprocess.PIPE if pipe_stdin else None
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stdin=stdin)


def kill_hear(proc):
    """Terminate hear subprocess."""
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def socket_to_stdin(sock_path, proc):
    """Read audio from unix socket and write to proc's stdin.
    Runs in a background thread. Stops when proc exits or socket closes."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(sock_path)
    except (ConnectionRefusedError, FileNotFoundError) as e:
        print(f"STT: socket connect failed: {e}", file=sys.stderr, flush=True)
        return
    sock.settimeout(0.5)
    buf = b""
    try:
        while proc.poll() is None:
            while len(buf) < CHUNK_BYTES:
                try:
                    data = sock.recv(CHUNK_BYTES - len(buf))
                except socket.timeout:
                    if proc.poll() is not None:
                        return
                    continue
                if not data:
                    return
                buf += data
            try:
                proc.stdin.write(buf[:CHUNK_BYTES])
                proc.stdin.flush()
            except BrokenPipeError:
                return
            buf = buf[CHUNK_BYTES:]
    finally:
        sock.close()
        try:
            proc.stdin.close()
        except Exception:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-source", default="mic",
                        help="'mic' or path to unix socket for audio input")
    parser.add_argument("--auto-start", action="store_true",
                        help="Start listening immediately, no silence timeout")
    args = parser.parse_args()

    cfg = load_config()
    model_cfg = cfg.get("model", {})
    silence_timeout = model_cfg.get("silence_timeout", 2.0)
    use_socket = args.audio_source != "mic"

    print("STT: ready", file=sys.stderr, flush=True)

    active = args.auto_start
    hear_proc = None
    feeder = None

    if active:
        if use_socket:
            hear_proc = spawn_hear(pipe_stdin=True)
            feeder = threading.Thread(target=socket_to_stdin,
                                      args=(args.audio_source, hear_proc),
                                      daemon=True)
            feeder.start()
        else:
            hear_proc = spawn_hear()  # mic, no timeout
        print("STT: active", file=sys.stderr, flush=True)

    while running:
        if not active:
            # Idle — wait for START
            time.sleep(0.05)
            result = read_stdin_cmd()
            if result and result[0] == "EOF":
                break
            if result and result[0] == "START":
                active = True
                if use_socket:
                    hear_proc = spawn_hear(timeout=silence_timeout,
                                           pipe_stdin=True)
                    feeder = threading.Thread(target=socket_to_stdin,
                                              args=(args.audio_source, hear_proc),
                                              daemon=True)
                    feeder.start()
                else:
                    hear_proc = spawn_hear(timeout=silence_timeout)
                print("STT: active", file=sys.stderr, flush=True)
            continue

        # Active — check for STOP
        result = read_stdin_cmd()
        if result and result[0] in ("STOP", "EOF"):
            kill_hear(hear_proc)
            hear_proc = None
            active = False
            print("END", flush=True)
            print("STT: idle", file=sys.stderr, flush=True)
            continue

        if hear_proc is None:
            active = False
            continue

        # Check if hear exited (silence timeout)
        if hear_proc.poll() is not None:
            # Drain remaining output
            for raw in hear_proc.stdout:
                line = raw.decode().strip()
                if line:
                    print(line, flush=True)
            hear_proc = None
            active = False
            print("END", flush=True)
            print("STT: idle (timeout)", file=sys.stderr, flush=True)
            continue

        # Non-blocking read from hear stdout
        ready, _, _ = select.select([hear_proc.stdout], [], [], 0.05)
        if ready:
            line = hear_proc.stdout.readline().decode().strip()
            if line:
                print(line, flush=True)

    kill_hear(hear_proc)


if __name__ == "__main__":
    main()
