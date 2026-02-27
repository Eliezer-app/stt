"""
Mock STT listener.

Connects to the audio socket, detects voice activity,
prints '*' for each active 1s chunk. Exits after 5s silence.

Usage:
  python listen.py --audio-source /tmp/speech-audio.sock
"""

import argparse
import socket
import sys
import time

import numpy as np

SAMPLE_RATE = 16000
CHUNK_1S = SAMPLE_RATE  # 1 second of float32 samples
RMS_THRESHOLD = 0.005


def audio_from_socket(sock_path, step_samples):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(sock_path)
    step_bytes = step_samples * 4
    buf = b""
    try:
        while True:
            while len(buf) < step_bytes:
                data = sock.recv(step_bytes - len(buf))
                if not data:
                    return
                buf += data
            yield np.frombuffer(buf[:step_bytes], dtype=np.float32)
            buf = buf[step_bytes:]
    finally:
        sock.close()


def main():
    parser = argparse.ArgumentParser(description="Mock STT listener")
    parser.add_argument("--audio-source", required=True)
    parser.add_argument("--silence-timeout", type=float, default=5.0)
    args = parser.parse_args()

    last_activity = time.time()

    print("STT listening: ", end="", flush=True)

    for chunk in audio_from_socket(args.audio_source, CHUNK_1S):
        rms = np.sqrt(np.mean(chunk ** 2))
        if rms > RMS_THRESHOLD:
            print("*", end="", flush=True)
            last_activity = time.time()

        if time.time() - last_activity > args.silence_timeout:
            print("\nSTT silence timeout", flush=True)
            break


if __name__ == "__main__":
    main()
