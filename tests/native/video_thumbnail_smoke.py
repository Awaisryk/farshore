#!/usr/bin/env python3
"""Exercise the production AVFoundation helper against one private HTTP resource.

Run scripts/test-native-video-thumbnail.sh [LOCAL_VIDEO]. Without an argument,
ffmpeg is used only to create a synthetic MP4 fixture; it is not a product dependency.
No capability URL, token, decoded source bytes, or HTTP request path is logged.
"""

import argparse
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import urllib.parse


class Fixture:
    budget = 8 * 1024 * 1024
    response_cap = 2 * 1024 * 1024

    def __init__(self, path):
        self.path = path
        self.route = "/media/" + secrets.token_urlsafe(32)
        self.requests = []
        self.served = 0
        self.mode = "video"
        self.busy_remaining = 0
        self.lock = threading.Lock()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, body):
        fixture = self.server.fixture
        if self.path != fixture.route:
            self.send_error(404)
            return
        with fixture.lock:
            denial = 503 if fixture.mode == "busy" or fixture.busy_remaining else 410 if fixture.mode == "expired" else None
            if fixture.busy_remaining:
                fixture.busy_remaining -= 1
            if denial:
                fixture.requests.append({"method": self.command, "range": self.headers.get("Range"),
                                         "offset": 0, "bytes": 0, "status": denial})
        if denial:
            self.send_response(denial)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            return
        if fixture.mode == "stall":
            time.sleep(3)
        length = fixture.path.stat().st_size if fixture.mode != "invalid" else 16
        requested = self.headers.get("Range")
        status = 200
        start, end = 0, length - 1
        if requested:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested)
            if not match:
                self.send_error(416)
                return
            start = int(match[1])
            end = min(int(match[2]) if match[2] else end, end)
            if start > end:
                self.send_error(416)
                return
            end = min(end, start + fixture.response_cap - 1)
            status = 206
        count = end - start + 1
        with fixture.lock:
            if body and fixture.served + count > fixture.budget:
                self.send_error(429)
                return
            if body:
                fixture.served += count
            fixture.requests.append({"method": self.command, "range": requested,
                                     "offset": start, "bytes": count if body else 0,
                                     "status": status})
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(count))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start + (1 if fixture.mode == 'bad-range' else 0)}-{end}/{length}")
        self.end_headers()
        if not body:
            return
        try:
            if fixture.mode == "invalid":
                self.wfile.write(b"not a video file"[start:end + 1])
            else:
                with fixture.path.open("rb") as source:
                    source.seek(start)
                    remaining = count
                    while remaining:
                        chunk = source.read(min(64 * 1024, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass


def run_helper(binary, url, output, *options):
    process = subprocess.run([str(binary), "video-thumbnail", "--url", url,
                              "--output", str(output), *options],
                             capture_output=True, timeout=14, check=False)
    # Assert diagnostic privacy before parsing or printing anything derived from it.
    token = urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1]
    assert url.encode() not in process.stdout + process.stderr, "URL leaked in diagnostics"
    assert token.encode() not in process.stdout + process.stderr, "Token leaked in diagnostics"
    assert not process.stderr, "Decoder wrote unexpected diagnostics"
    result = json.loads(process.stdout)
    assert result.get("version") == 1
    assert (process.returncode == 0) == result.get("ok")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("fixture", nargs="?", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="video-thumbnail-", dir=Path(__file__).resolve().parents[2] / ".build") as directory:
        scratch = Path(directory)
        fixture_path = args.fixture
        if fixture_path is None:
            encoder = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
            fixture_path = scratch / "fixture.mp4"
            subprocess.run([encoder, "-v", "error", "-f", "lavfi", "-i",
                            "testsrc2=size=320x240:rate=10", "-t", "4", "-an",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                            str(fixture_path)], check=True, capture_output=True)
            # A valid MP4 free atom makes the source large without moving its
            # metadata. Thumbnail extraction must still fit the HTTP byte budget.
            padding = 32 * 1024 * 1024
            with fixture_path.open("r+b") as source:
                source.seek(0, os.SEEK_END)
                source.write(struct.pack(">I4s", padding, b"free"))
                source.seek(padding - 9, os.SEEK_CUR)
                source.write(b"\0")
        fixture = Fixture(fixture_path.resolve())
        with Server(("127.0.0.1", 0), Handler) as server:
            server.fixture = fixture
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            url = f"http://127.0.0.1:{server.server_port}{fixture.route}"
            try:
                started = time.monotonic()
                output = scratch / "thumbnail.png"
                result = run_helper(args.helper, url, output, "--size", "384")
                if not result["ok"]:
                    print(json.dumps({"ok": False, "code": result.get("error", {}).get("code"),
                                      "sourceBytes": fixture.path.stat().st_size,
                                      "requestedBytes": fixture.served, "requests": fixture.requests}, sort_keys=True))
                assert result["ok"], f"Extraction failed: {result.get('error', {}).get('code')}"
                png = output.read_bytes()
                assert png[:8] == b"\x89PNG\r\n\x1a\n"
                width, height = struct.unpack(">II", png[16:24])
                assert 0 < width <= 384 and 0 < height <= 384
                assert result["result"]["width"] == width
                assert result["result"]["height"] == height
                assert result["result"]["decoder"] == "AVFoundation"
                success_metrics = {"width": width, "height": height,
                                   "elapsedSeconds": round(time.monotonic() - started, 3),
                                   "sourceBytes": fixture.path.stat().st_size,
                                   "requestedBytes": fixture.served,
                                   "requests": list(fixture.requests)}
                count = len(fixture.requests)
                existing = run_helper(args.helper, url, output)
                assert existing["error"]["code"] == "output-exists"
                assert len(fixture.requests) == count
                bad_urls = [url.replace("http:", "https:"), url.replace("127.0.0.1", "localhost"),
                            url.replace("127.0.0.1", "user@127.0.0.1"), url + "?q=1", url + "#fragment",
                            url.replace("/media/", "/media/%41"), url.replace(fixture.route, "/media/short")]
                for bad in bad_urls:
                    response = run_helper(args.helper, bad, scratch / "rejected.png")
                    assert response["error"]["code"] == "invalid-media-url"
                assert len(fixture.requests) == count
                fixture.served = 0
                fixture.busy_remaining = 2
                retry_start = len(fixture.requests)
                retried = run_helper(args.helper, url, scratch / "retried.png")
                assert retried["ok"], "Two brief admission denials did not recover"
                retry_requests = fixture.requests[retry_start:]
                assert [entry["status"] for entry in retry_requests[:3]] == [503, 503, 200]
                assert len(retry_requests) <= 12 and fixture.served <= fixture.budget
                fixture.mode = "busy"
                started = time.monotonic()
                busy = run_helper(args.helper, url, scratch / "busy.png")
                assert busy["error"]["code"] == "thumbnail-resource-busy"
                assert busy["error"]["details"]["httpStatuses"] == [503, 503, 503]
                assert busy["error"]["details"]["requests"] == 3
                assert time.monotonic() - started < 3, "Busy resource lingered until decoder timeout"
                fixture.mode = "expired"
                expired = run_helper(args.helper, url, scratch / "expired.png")
                assert expired["error"]["code"] == "thumbnail-resource-http"
                assert expired["error"]["details"]["httpStatuses"] == [410]
                fixture.mode = "bad-range"
                fixture.served = 0
                mismatch = run_helper(args.helper, url, scratch / "mismatch.png")
                assert mismatch["error"]["code"] == "thumbnail-resource-response"
                assert mismatch["error"]["details"]["stage"] == "resource"
                fixture.served = 0
                fixture.mode = "invalid"
                invalid = run_helper(args.helper, url, scratch / "invalid.png", "--timeout", "3")
                assert not invalid["ok"] and not (scratch / "invalid.png").exists()
                fixture.served = 0
                fixture.mode = "stall"
                started = time.monotonic()
                timeout = run_helper(args.helper, url, scratch / "timeout.png", "--timeout", "1")
                elapsed = time.monotonic() - started
                assert timeout["error"]["code"] == "thumbnail-timeout"
                assert elapsed < 2.5, "Cancellation failed to bound helper completion"
                assert not (scratch / "timeout.png").exists()
                print(json.dumps({"ok": True, "decoder": "AVFoundation", "extraction": success_metrics,
                                  "validationCases": len(bad_urls), "existingOutputRejected": True,
                                  "busyRetryRecovered": True, "busyAndExpiredClassified": True,
                                  "rangeMismatchClassified": True,
                                  "unsupportedRejected": True, "timeoutSeconds": round(elapsed, 3)}, sort_keys=True))
            finally:
                server.shutdown()


if __name__ == "__main__":
    main()
