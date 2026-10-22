#!/usr/bin/env python3
"""Exercise the real LibVLC audio path with a private, local WAV stream.

Uses the existing native pause/resume/EOF/replay/seek harness with audioOnly.
The player is muted before playback; no SSH, installed-app launch or user files.
"""
import io
import json
import math
from pathlib import Path
import re
import secrets
import struct
import subprocess
import tempfile
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    root = Path(__file__).resolve().parents[2]
    stream = io.BytesIO()
    with wave.open(stream, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(44100)
        audio.writeframes(b"".join(
            struct.pack("<h", int(1200 * math.sin(2 * math.pi * 220 * index / 44100)))
            for index in range(44100 * 8)
        ))
    payload = stream.getvalue()
    route = "/media/" + secrets.token_urlsafe(32)
    metrics = {"requests": 0, "payloadBytesSent": 0}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_HEAD(self):
            self.respond(False)

        def do_GET(self):
            self.respond(True)

        def respond(self, body):
            if self.path != route:
                self.send_error(404)
                return
            start, end = 0, len(payload) - 1
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
            if match:
                start = int(match[1])
                end = min(int(match[2]) if match[2] else end, end)
            if start > end:
                self.send_error(416)
                return
            part = payload[start:end + 1]
            self.send_response(206 if match else 200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(part)))
            self.send_header("Connection", "close")
            if match:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
            self.end_headers()
            metrics["requests"] += 1
            if body:
                try:
                    self.wfile.write(part)
                    metrics["payloadBytesSent"] += len(part)
                except (BrokenPipeError, ConnectionResetError):
                    pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="farshore-audio-smoke-") as folder:
            manifest = Path(folder) / "media.json"
            manifest.write_text(json.dumps({
                "streamUrl": f"http://127.0.0.1:{server.server_port}{route}",
                "audioOnly": True,
            }))
            manifest.chmod(0o600)
            result = subprocess.run(
                [str(root / "scripts/test-native-playback.sh"), str(manifest)],
                capture_output=True, text=True, timeout=120, cwd=root,
            )
            report = json.loads(result.stdout)
            no_video = all(state.get("width", 0) == 0 and state.get("height", 0) == 0
                           for state in report.get("states", []))
            report.update({"audioOnly": True, "noVideoFrames": no_video, **metrics})
            print(json.dumps(report, sort_keys=True))
            return 0 if result.returncode == 0 and report.get("passed") and no_video else 1
    except (ValueError, OSError, subprocess.TimeoutExpired):
        print(json.dumps({"passed": False, "message": "The isolated audio smoke did not finish successfully."}))
        return 1
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
