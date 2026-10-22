#!/usr/bin/env python3
"""Farshore's read-only local bridge. No remote commands or shell interpolation.

Protocol v1: newline-delimited request/response JSON, maximum 64 KiB requests.
The SFTP engine delegates authentication and identity checks to system OpenSSH.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import glob
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
import platform
from pathlib import Path, PurePosixPath
import re
import secrets
import signal
import stat as stat_module
import shlex
import shutil
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
STATE = Path(os.environ.get("FARSHORE_STATE", str(ROOT / ".runtime")))
CACHE = Path(os.environ["FARSHORE_CACHE"]) if os.environ.get("FARSHORE_CACHE") else None
ALIAS = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:@-]{0,127}\Z")
THUMB_BUDGET = 512 * 1024**2
MAX_IMAGE = 32 * 1024**2
MAX_VIDEO_THUMB_BYTES = 8 * 1024**2
MAX_VIDEO_THUMB_RANGE = 2 * 1024**2
VIDEO_THUMB_SECONDS = 14
RECENT_PATH_LIMIT = 5
THEME_IDS = ("shore", "deep-shore", "frost", "sand", "midnight", "orchid")
MIN_THUMB_BUDGET = 128 * 1024**2
MAX_THUMB_BUDGET = 2 * 1024**3
BROWSER_DEFAULTS = {"view": "grid", "tileSize": 166, "sort": "name", "showHidden": False,
                    "inspector": True, "restoreWorkspace": True}
MAX_PREVIEW_IMAGE = 64 * 1024**2
MAX_PREVIEW_DOCUMENT = 32 * 1024**2
MAX_PREVIEW_TEXT = 512 * 1024
MAX_PREVIEW_DISK = 128 * 1024**2
PREVIEW_SECONDS = 30
PREVIEW_IMAGES = frozenset("jpg jpeg png gif webp heic heif tif tiff bmp avif ico icns svg psd".split())
PREVIEW_DOCUMENTS = frozenset("pdf doc docx xls xlsx ppt pptx odt ods odp pages numbers key rtf".split())
PREVIEW_TEXT = frozenset(("txt md markdown json jsonl ndjson csv tsv log yaml yml toml ini conf config cfg env xml html htm "
                          "css scss sass less js jsx ts tsx py pyi dart swift java kt kts go rs c cc cpp h hpp m mm cs rb php "
                          "sh bash zsh fish ps1 bat cmd sql r vue svelte tex gitignore gitattributes editorconfig lock properties ipynb").split())
PREVIEW_TEXT_NAMES = frozenset("readme license licence changelog notice dockerfile makefile gemfile procfile jenkinsfile .env .gitignore .gitattributes .editorconfig".split())


def byte_range(value, size):
    """Resolve one HTTP byte range. Multipart ranges are deliberately rejected."""
    if not value:
        return (0, size - 1, False)
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
    if not match or size <= 0 or not any(match.groups()):
        raise ValueError("invalid range")
    first, last = match.groups()
    if not first:
        suffix = int(last)
        if suffix <= 0:
            raise ValueError("invalid suffix")
        return (max(0, size - suffix), size - 1, True)
    start = int(first)
    end = min(int(last), size - 1) if last else size - 1
    if start >= size or start > end:
        raise ValueError("unsatisfiable range")
    return (start, end, True)


class MediaHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False
    request_queue_size = 4

    def __init__(self, *args):
        self.request_slots = threading.BoundedSemaphore(8)
        super().__init__(*args)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address

    def process_request(self, request, client_address):
        if not self.request_slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.request_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.request_slots.release()


class MediaRequest(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "Farshore"

    def log_message(self, *_):
        pass  # Never log scoped media tokens or file paths.

    def send_empty(self, status, **headers):
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name.replace("_", "-"), str(value))
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_HEAD(self):
        self.media(head=True)

    def do_GET(self):
        self.media(head=False)

    def do_POST(self):
        self.send_empty(405, Allow="GET, HEAD")

    do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_POST

    def media(self, head):
        bridge = self.server.bridge
        expected_host = "127.0.0.1:" + str(self.server.server_port)
        if self.headers.get("Host") != expected_host or self.headers.get("Origin"):
            self.send_empty(403)
            return
        record = None
        with bridge.lock:
            for candidate in bridge.media_leases.values():
                if hmac.compare_digest(self.path.encode("utf-8"), ("/media/" + candidate["token"]).encode("ascii")):
                    record = candidate
                    break
        if record is None or record["closed"]:
            self.send_empty(404)
            return
        background = record.get("purpose") == "thumbnail"
        if background:
            with bridge.lock:
                denial = 410 if time.monotonic() >= record["expiresAt"] else 429 if record["requests"] >= 12 else None
                if denial is None:
                    record["requests"] += 1
            if denial:
                self.send_empty(denial)
                return
            # A background decoder can never occupy both playback read slots.
            # The previous response can be fully received just before its
            # rclone child exits. Wait briefly for that same read's cleanup;
            # rejecting the decoder's next sequential range loses the preview.
            if not bridge.thumbnail_stream_slots.acquire(timeout=1):
                self.send_empty(503, Retry_After="1")
                return
        if not bridge.stream_slots.acquire(blocking=False):
            if background:
                bridge.thumbnail_stream_slots.release()
            self.send_empty(503, Retry_After="1")
            return
        process = None
        sent_headers = False
        try:
            if record["closed"]:
                self.send_empty(404)
                return
            if background and time.monotonic() >= record["expiresAt"]:
                self.send_empty(410)
                return
            # Thumbnail identity is checked before and after the entire decode.
            # Avoid repeated metadata connections for every small decoder read.
            if not background:
                metadata = bridge.stat(record["host"], record["remotePath"])
                if (metadata.get("Size"), metadata.get("ModTime")) != record["identity"]:
                    self.send_empty(409)
                    return
            size = record["identity"][0]
            try:
                start, end, partial = byte_range(None if head else self.headers.get("Range"), size)
            except ValueError:
                self.send_empty(416, Content_Range="bytes */" + str(size))
                return
            count = max(0, end - start + 1)
            if not head and count:
                if background:
                    with bridge.lock:
                        available = MAX_VIDEO_THUMB_BYTES - record["reservedBytes"]
                        denial = 429 if available <= 0 else 413 if not partial and count > available else None
                        if denial is None:
                            count = min(count, available, MAX_VIDEO_THUMB_RANGE) if partial else count
                            end = start + count - 1
                            # Reserve the full SFTP request, even if the decoder
                            # disconnects early. Refunding would bypass the cap.
                            record["reservedBytes"] += count
                    if denial:
                        self.send_empty(denial)
                        return
                args = [bridge.rclone, "cat", ":sftp:" + record["remotePath"], "--offset", str(start), "--count", str(count),
                        "--sftp-concurrency", "4"] + bridge.engine_args(record["host"])
                process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                           stderr=subprocess.DEVNULL, start_new_session=True)
                with bridge.lock:
                    closed = record["closed"]
                    if not closed:
                        record["processes"].add(process)
                if closed:
                    self.send_empty(404)
                    return
            self.send_response(206 if partial else 200)
            self.send_header("Content-Length", str(count))
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Type", record["mimeType"])
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            sent_headers = True
            if head or not process:
                return
            remaining = count
            self.connection.settimeout(10)
            while (remaining and not record["closed"]
                   and (not background or time.monotonic() < record["expiresAt"])):
                chunk = process.stdout.read1(min(65536, remaining))
                if not chunk:
                    break  # Closing early makes Content-Length mismatch visible.
                self.wfile.write(chunk)
                remaining -= len(chunk)
                with bridge.lock:
                    bridge.stream_bytes_served += len(chunk)
        except (BridgeError, OSError, ValueError, subprocess.SubprocessError):
            if not sent_headers:
                try:
                    self.send_empty(502)
                except OSError:
                    pass
        finally:
            try:
                if process:
                    try:
                        bridge.stop_stream_process(process)
                    except (OSError, subprocess.SubprocessError):
                        # Cleanup failure must never exhaust all future reads.
                        pass
                    finally:
                        with bridge.lock:
                            record["processes"].discard(process)
            finally:
                self.close_connection = True
                try:
                    bridge.stream_slots.release()
                finally:
                    if background:
                        bridge.thumbnail_stream_slots.release()


class BridgeError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message
        super().__init__(message)


class DetachedProcess:
    """Recovered mounts are observed conservatively and never killed by PID."""
    def __init__(self, pid):
        self.pid = pid

    def poll(self):
        try:
            os.kill(self.pid, 0)
            return None
        except ProcessLookupError:
            return 1
        except PermissionError:
            return None

    def terminate(self):
        pass  # Recovered sessions are released through normal disk unmount only.


def private_dir(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def remote_path(value):
    if not isinstance(value, str) or len(value.encode()) > 8192 or "\x00" in value:
        raise BridgeError("invalid_path", "The remote path is invalid or too long.")
    # Keep case, Unicode, quotes, backslashes, and shell metacharacters literal.
    if ".." in PurePosixPath(value).parts:
        raise BridgeError("invalid_path", "Parent traversal is not a valid location.")
    return str(PurePosixPath(value)) if value else ""


def logical_host_id(value):
    if not isinstance(value, str) or not 0 < len(value) <= 128 or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise BridgeError("invalid_workspace", "A saved location has an invalid server identifier.")
    return value


def workspace_value(value):
    if (not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] != 1
            or not isinstance(value.get("tabs"), list) or len(value["tabs"]) > 32
            or type(value.get("activeTab")) is not int or not isinstance(value.get("isHome"), bool)):
        raise BridgeError("invalid_workspace", "The saved workspace is invalid.")
    tabs = []
    for item in value["tabs"]:
        if not isinstance(item, dict):
            raise BridgeError("invalid_workspace", "A saved tab is invalid.")
        tabs.append({"hostId": logical_host_id(item.get("hostId")), "path": remote_path(item.get("path"))})
    if not 0 <= value["activeTab"] < max(1, len(tabs)):
        raise BridgeError("invalid_workspace", "The active workspace tab is invalid.")
    return {"version": 1, "tabs": tabs, "activeTab": value["activeTab"], "isHome": value["isHome"]}


def browser_settings(value):
    if not isinstance(value, dict):
        raise BridgeError("invalid_browser_settings", "Browser settings must be an object.")
    settings = {**BROWSER_DEFAULTS, **value}
    if (settings["view"] not in ("grid", "list", "gallery") or settings["sort"] not in ("name", "newest", "largest")
            or type(settings["tileSize"]) not in (int, float) or not 125 <= settings["tileSize"] <= 240
            or any(type(settings[key]) is not bool for key in ("showHidden", "inspector", "restoreWorkspace"))):
        raise BridgeError("invalid_browser_settings", "Choose supported browser settings.")
    return settings


def cache_settings(value):
    if not isinstance(value, dict):
        raise BridgeError("invalid_cache_settings", "Cache settings must be an object.")
    settings = {"thumbnailBudgetBytes": THUMB_BUDGET, **value}
    budget = settings["thumbnailBudgetBytes"]
    if type(budget) is not int or not MIN_THUMB_BUDGET <= budget <= MAX_THUMB_BUDGET:
        raise BridgeError("invalid_cache_settings", "Choose a thumbnail budget from 128 MiB to 2 GiB.")
    return settings


def empty_workspace():
    return {"version": 1, "tabs": [], "activeTab": 0, "isHome": True}


def favorite_paths(value):
    if not isinstance(value, list) or len(value) > 50:
        raise BridgeError("invalid_favorite_path", "Save at most 50 favorite folders.")
    result, seen = [], set()
    for item in value:
        if not isinstance(item, dict):
            raise BridgeError("invalid_favorite_path", "A favorite folder is invalid.")
        host_id, path = logical_host_id(item.get("hostId")), remote_path(item.get("path"))
        if (host_id, path) not in seen:
            result.append({"hostId": host_id, "path": path})
            seen.add((host_id, path))
    return result


def host_aliases(config=Path.home() / ".ssh/config"):
    seen, aliases = set(), []

    def visit(path, depth=0):
        path = Path(path).expanduser()
        if depth > 12 or path in seen or len(seen) >= 128:
            return
        seen.add(path)
        try:
            lines = path.read_text().splitlines()
        except (OSError, UnicodeError):
            return
        for line in lines:
            try:
                words = shlex.split(re.sub(r"^(\s*[A-Za-z]+)\s*=\s*", r"\1 ", line), comments=True)
            except ValueError:
                continue
            if not words:
                continue
            if words[0].lower() == "include":
                for pattern in words[1:]:
                    p = Path(pattern).expanduser()
                    if not p.is_absolute():
                        p = Path.home() / ".ssh" / p
                    for name in sorted(glob.glob(str(p))):
                        visit(name, depth + 1)
            if words[0].lower() == "host":
                for alias in words[1:]:
                    if ALIAS.fullmatch(alias) and alias not in aliases:
                        aliases.append(alias)
    visit(config)
    return aliases


def ssh_args(alias):
    if not ALIAS.fullmatch(alias):
        raise BridgeError("invalid_host", "Choose a valid SSH host alias.")
    return ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "UpdateHostKeys=no", "-o", "CheckHostIP=no", "-o", "ControlMaster=no",
            "-o", "ControlPath=none", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=3", alias]


def connection_error(stderr, alias):
    text = stderr.lower()
    if "host identification has changed" in text or "host key verification failed" in text:
        return BridgeError("host_identity_changed", f"SSH could not verify {alias}. The server may be presenting another machine's identity. Existing trusted keys were preserved. Verify the destination in your SSH terminal before retrying.")
    if "permission denied" in text or "authentication" in text:
        return BridgeError("authentication_unavailable", f"Authentication for {alias} is unavailable. Unlock your existing SSH key or agent and retry.")
    return BridgeError("connection_failed", f"Could not connect to {alias} using the existing SSH configuration. Check the host and network, then retry.")


class Bridge:
    def __init__(self):
        private_dir(STATE)
        self.lock = threading.RLock()
        self.mounts = {}
        self.media_leases = {}
        self.media_server = None
        self.playback_pending = 0
        self.stream_slots = threading.Semaphore(2)
        self.thumbnail_stream_slots = threading.Semaphore(1)
        self.stream_bytes_served = 0
        self.hosts = {}
        self.checked = {}
        self.activity = []
        self.list_cache = {}
        self.thumb_slots = threading.Semaphore(2)
        self.video_thumb_slots = threading.Semaphore(1)
        self.thumbnail_inflight = set()
        self.preview_leases = {}
        self.preview_requests = {}
        self.preview_slots = threading.BoundedSemaphore(2)
        self.preferences_path = STATE / "preferences.json"
        self.preferences = self.load_preferences()
        self.rclone = os.environ.get("FARSHORE_RCLONE") or os.environ.get("RCLONE") or str(ROOT / ".tools/rclone-v1.75.2-osx-arm64/rclone")
        self.native = os.environ.get("FARSHORE_NATIVE") or str(ROOT / ".build/farshore-native")
        self.restore_mounts()

    def restore_mounts(self):
        # Migration can copy preferences, but live NFS mount directories stay
        # in their original state tree. Only explicitly supplied, private,
        # same-user roots are eligible; recovered processes are never killed.
        roots = [STATE]
        for value in os.environ.get("FARSHORE_LEGACY_STATES", "").split(os.pathsep)[:8]:
            if not value:
                continue
            root = Path(value)
            try:
                info = root.lstat()
                if (not root.is_absolute() or root.resolve() != root or not stat_module.S_ISDIR(info.st_mode)
                        or info.st_uid != os.getuid() or info.st_mode & 0o077):
                    continue
            except OSError:
                continue
            if root not in roots:
                roots.append(root)
        adopted = False
        for root in roots:
            try:
                file = root / "mount-registry.json"
                info = file.lstat()
                if not stat_module.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 1024 * 1024:
                    continue
                registry = json.loads(file.read_text())
                if not isinstance(registry, dict) or registry.get("version") != 1 or not isinstance(registry.get("mounts"), list):
                    continue
            except (ValueError, OSError):
                continue
            for record in registry["mounts"][:64]:
                try:
                    path = Path(record["path"])
                    # The current registry may retain previously adopted roots.
                    allowed = roots if root == STATE else [root]
                    if (not path.is_absolute() or ".." in path.parts or not any(path.is_relative_to(item / "mounts") for item in allowed)
                            or not os.path.ismount(path) or type(record["pid"]) is not int or record["pid"] <= 1):
                        continue
                    key = record["key"]
                    host_id = logical_host_id(record["hostId"])
                    if not isinstance(key, str) or not 0 < len(key) <= 128:
                        continue
                    proc = DetachedProcess(record["pid"])
                    if proc.poll() is not None or any(item["path"] == str(path) for item in self.mounts.values()):
                        continue
                    if key in self.mounts:
                        key = hashlib.sha256((key + str(path)).encode()).hexdigest()[:32]
                    self.mounts[key] = {"key": key, "hostId": host_id,
                                        "alias": record.get("alias") if isinstance(record.get("alias"), str) else "SSH host",
                                        "path": str(path), "process": proc, "external": True,
                                        "state": "mounted", "log": path.parent / "engine.jsonl"}
                    adopted |= root != STATE
                except (BridgeError, ValueError, OSError, KeyError, TypeError):
                    continue
        if adopted:
            try:
                self.save_mounts()
            except OSError:
                pass  # Preserve the in-memory protection even on read-only disk.

    def save_mounts(self):
        records = [{"key": key, "hostId": m["hostId"], "alias": m.get("alias", "SSH host"),
                    "path": m["path"], "pid": m["process"].pid, "external": m["external"], "state": m["state"]}
                   for key, m in self.mounts.items() if m["process"].poll() is None]
        temp = STATE / "mount-registry.tmp"
        temp.write_text(json.dumps({"version": 1, "mounts": records}))
        temp.chmod(0o600)
        temp.replace(STATE / "mount-registry.json")

    def load_preferences(self):
        try:
            data = json.loads(self.preferences_path.read_text())
            if not isinstance(data, dict) or data.get("version") != 1:
                raise BridgeError("preferences_version", "Preferences use an unsupported schema; the file was preserved.")
            if (not isinstance(data.get("handlers", {}), dict)
                    or not all(isinstance(k, str) and isinstance(v, str) for k, v in data.get("handlers", {}).items())
                    or not isinstance(data.get("favoriteHostIds", []), list)
                    or len(data.get("favoriteHostIds", [])) > 4096
                    or not all(isinstance(value, str) and 0 < len(value) <= 128 for value in data.get("favoriteHostIds", []))
                    or not isinstance(data.get("recentPaths", []), list)
                    or len(data.get("recentPaths", [])) > 1024):
                raise BridgeError("preferences_invalid", "Preferences could not be read. The original file was preserved.")
            data.setdefault("handlers", {})
            data["favoriteHostIds"] = list(dict.fromkeys(data.get("favoriteHostIds", [])))
            recent, seen = [], set()
            for item in data.get("recentPaths", []):
                if (not isinstance(item, dict) or not isinstance(item.get("hostId"), str)
                        or not 0 < len(item["hostId"]) <= 128):
                    raise BridgeError("preferences_invalid", "Recent folder preferences are invalid. The original file was preserved.")
                try:
                    path = remote_path(item.get("path"))
                except BridgeError:
                    raise BridgeError("preferences_invalid", "Recent folder preferences are invalid. The original file was preserved.")
                key = (item["hostId"], path)
                if key not in seen:
                    seen.add(key)
                    recent.append({"hostId": item["hostId"], "path": path})
            data["recentPaths"] = recent[:RECENT_PATH_LIMIT]
            theme = data.get("themeId")
            data["themeId"] = theme if isinstance(theme, str) and theme in THEME_IDS else "shore"
            # These additive version-1 fields were absent in earlier builds.
            # Invalid future/corrupt values cannot trigger network work during
            # restoration. Preserve unrelated data and do not rewrite on load.
            for key, validate, default in (("workspace", workspace_value, empty_workspace()),
                                           ("browserSettings", browser_settings, dict(BROWSER_DEFAULTS)),
                                           ("favoritePaths", favorite_paths, []),
                                           ("cacheSettings", cache_settings, {"thumbnailBudgetBytes": THUMB_BUDGET})):
                try:
                    data[key] = validate(data[key]) if key in data else default
                except BridgeError:
                    data[key] = default
            return data
        except FileNotFoundError:
            return {"version": 1, "handlers": {}, "favoriteHostIds": [], "recentPaths": [], "themeId": "shore",
                    "workspace": empty_workspace(), "browserSettings": dict(BROWSER_DEFAULTS), "favoritePaths": [],
                    "cacheSettings": {"thumbnailBudgetBytes": THUMB_BUDGET}}
        except (ValueError, OSError):
            raise BridgeError("preferences_invalid", "Preferences could not be read. The original file was preserved.")

    def save_preferences(self, preferences=None):
        temp = self.preferences_path.with_suffix("." + secrets.token_hex(8) + ".tmp")
        try:
            temp.write_text(json.dumps(self.preferences if preferences is None else preferences, indent=2))
            temp.chmod(0o600)
            temp.replace(self.preferences_path)
        except OSError:
            raise BridgeError("preferences_write", "Your preferences could not be saved. Check local storage and retry.")
        finally:
            try:
                temp.unlink(missing_ok=True)
            except OSError:
                pass

    def set_favorite(self, hostId, favorite, **_):
        if not isinstance(favorite, bool):
            raise BridgeError("invalid_favorite", "Choose whether this server is a favorite.")
        self.host(hostId)
        with self.lock:
            favorites = list(self.preferences["favoriteHostIds"])
            if favorite and hostId not in favorites:
                favorites.append(hostId)
            elif not favorite:
                favorites = [value for value in favorites if value != hostId]
            if len(favorites) > 4096:
                raise BridgeError("favorite_limit", "The favorite server limit has been reached.")
            updated = {**self.preferences, "favoriteHostIds": favorites}
            self.save_preferences(updated)
            self.preferences = updated
            return {"favoriteHostIds": favorites}

    def set_theme(self, themeId=None, **_):
        if not isinstance(themeId, str) or themeId not in THEME_IDS:
            raise BridgeError("invalid_theme", "Choose an available Farshore theme.")
        with self.lock:
            updated = {**self.preferences, "themeId": themeId}
            self.save_preferences(updated)
            self.preferences = updated
            return {"themeId": themeId}

    def save_workspace(self, workspace=None, browserSettings=None, **_):
        value = workspace_value(workspace)
        with self.lock:
            settings = browser_settings({**self.preferences["browserSettings"], **browserSettings}) if isinstance(browserSettings, dict) else self.preferences["browserSettings"]
            if browserSettings is not None and not isinstance(browserSettings, dict):
                raise BridgeError("invalid_browser_settings", "Browser settings must be an object.")
            updated = {**self.preferences, "workspace": value, "browserSettings": settings}
            self.save_preferences(updated)
            self.preferences = updated
            return {"workspace": json.loads(json.dumps(value)), "browserSettings": dict(settings)}

    def set_favorite_path(self, hostId=None, path=None, favorite=None, **_):
        host_id, path = logical_host_id(hostId), remote_path(path)
        if type(favorite) is not bool:
            raise BridgeError("invalid_favorite_path", "Choose whether this folder is a favorite.")
        with self.lock:
            folders = [dict(item) for item in self.preferences["favoritePaths"]]
            folders = [item for item in folders if (item["hostId"], item["path"]) != (host_id, path)]
            if favorite:
                folders.append({"hostId": host_id, "path": path})
            folders = favorite_paths(folders)
            updated = {**self.preferences, "favoritePaths": folders}
            self.save_preferences(updated)
            self.preferences = updated
            return {"favoritePaths": [dict(item) for item in folders]}

    def recent_paths(self, **_):
        with self.lock:
            return {"recentPaths": [dict(item) for item in self.preferences["recentPaths"]]}

    def record_path_visit(self, hostId, path, **_):
        # The UI calls this only after it accepts a successful listing. Keeping
        # this separate from list prevents canceled/stale requests from changing
        # the most-recent destination. Recording never opens another connection.
        self.host(hostId)
        path = remote_path(path)
        with self.lock:
            if (hostId, path) not in self.list_cache:
                raise BridgeError("path_not_visited", "Open this folder successfully before adding it to recent paths.")
            recent = [{"hostId": hostId, "path": path}] + [
                dict(item) for item in self.preferences["recentPaths"]
                if (item["hostId"], item["path"]) != (hostId, path)
            ]
            updated = {**self.preferences, "recentPaths": recent[:RECENT_PATH_LIMIT]}
            self.save_preferences(updated)
            self.preferences = updated
            return {"recentPaths": [dict(item) for item in updated["recentPaths"]]}

    def run(self, args, timeout=25, input=None):
        try:
            p = subprocess.run(args, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            raise BridgeError("timeout", "The operation timed out. Retry when the connection is available.")
        except FileNotFoundError:
            raise BridgeError("dependency_missing", "A local helper is missing. Run scripts/bootstrap.sh and scripts/build-native.sh.")
        return p

    def discover(self):
        hosts = []
        for alias in host_aliases():
            p = self.run(["/usr/bin/ssh", "-G", alias], timeout=5)
            if p.returncode:
                continue
            config = dict(line.split(" ", 1) for line in p.stdout.decode(errors="replace").splitlines() if " " in line)
            host_id = hashlib.sha256(("openssh:" + alias).encode()).hexdigest()[:20]
            h = {"id": host_id, "alias": alias, "hostname": config.get("hostname", alias),
                 "user": config.get("user", ""), "port": int(config.get("port", 22)),
                 "hostKeyAlias": config.get("hostkeyalias")}
            hosts.append(h)
        with self.lock:
            self.hosts = {h["id"]: h for h in hosts}
            favorites = list(self.preferences["favoriteHostIds"])
            recent = [dict(item) for item in self.preferences["recentPaths"]]
            theme = self.preferences["themeId"]
            stored = json.loads(json.dumps({key: self.preferences[key] for key in ("workspace", "browserSettings", "favoritePaths", "cacheSettings")}))
        return {"hosts": hosts, "favoriteHostIds": favorites, "recentPaths": recent, "themeId": theme, **stored}

    def host(self, host_id):
        if host_id not in self.hosts:
            self.discover()
        try:
            return self.hosts[host_id]
        except KeyError:
            raise BridgeError("unknown_host", "The SSH alias is no longer available. Refresh the host list.")

    def preflight(self, host):
        # Ask OpenSSH to start the SFTP subsystem and close stdin. No remote shell.
        # Unlike rclone's external-SSH path, capture SSH stderr for identity errors.
        alias = host["alias"]
        args = ssh_args(alias)
        p = self.run(args[:-1] + ["-s", alias, "sftp"], timeout=12, input=b"")
        if p.returncode:
            raise connection_error(p.stderr.decode(errors="replace"), alias)

    def engine_args(self, host):
        # SFTP internal known-host options do not apply to external SSH. OpenSSH
        # performs mandatory strict checks on every fresh engine connection.
        return ["--config", "/dev/null", "--sftp-ssh", shlex.join(ssh_args(host["alias"])),
                "--sftp-disable-hashcheck", "--sftp-connections", "4", "--checkers", "1", "--transfers", "1", "--contimeout", "10s",
                "--timeout", "20s", "--retries", "1", "--low-level-retries", "1"]

    def listing(self, host_id, path="", **_):
        path = remote_path(path)
        h = self.host(host_id)
        self.preflight(h)
        p = self.run([self.rclone, "lsjson", ":sftp:" + path, "--max-depth", "1"] + self.engine_args(h))
        if p.returncode:
            detail = p.stderr.decode(errors="replace").lower()
            if "permission denied" in detail:
                raise BridgeError("permission_denied", f"You do not have permission to read {path or 'the home folder'} on {h['alias']}.")
            if any(value in detail for value in ["directory not found", "no such file", "does not exist", "file not found"]):
                raise BridgeError("path_not_found", f"The folder {path or 'Home'} does not exist on {h['alias']}. Go back or choose another path.")
            raise connection_error(detail, h["alias"])
        try:
            raw = json.loads(p.stdout)
            entries = [{"name": x["Name"], "path": str(PurePosixPath(path) / x["Name"]),
                        "isDirectory": x["IsDir"], "size": max(0, x["Size"]),
                        "modified": x.get("ModTime", ""), "mimeType": x.get("MimeType") or mimetypes.guess_type(x["Name"])[0] or "application/octet-stream"}
                       for x in raw]
        except (ValueError, KeyError, TypeError):
            raise BridgeError("protocol_error", "The filesystem engine returned an invalid listing.")
        result = {"path": path, "entries": entries, "fresh": True}
        with self.lock:
            self.list_cache[(host_id, path)] = result
        return result

    def stat(self, host, path):
        p = self.run([self.rclone, "lsjson", ":sftp:" + path, "--stat"] + self.engine_args(host))
        if p.returncode:
            raise BridgeError("source_unavailable", "The source file is no longer available. Refresh the folder.")
        return json.loads(p.stdout)

    def native_call(self, command, *args):
        p = self.run([self.native, command] + list(args), timeout=300 if command == "choose-application" else 18)
        try:
            result = json.loads(p.stdout)
        except ValueError:
            raise BridgeError("native_error", "The macOS helper returned an invalid response.")
        if not result.get("ok"):
            error = result.get("error", {})
            raise BridgeError(error.get("code", "native_error"), error.get("message", "The macOS operation failed."))
        return result["result"]

    @staticmethod
    def thumbnail_outcome(status, reason=None, *, path=None, retry_after=None, cached=None):
        result = {"path": path, "status": status}
        if reason is not None:
            result["reason"] = reason
        if retry_after is not None:
            result["retryAfterMs"] = retry_after
        if cached is not None:
            result["cached"] = cached
        return result

    @staticmethod
    def thumbnail_key(host, path, metadata, video):
        identity = [host, path, metadata["Size"], metadata.get("ModTime")]
        if video:
            identity.append("video-avfoundation-v1")
        return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()

    def listed_thumbnail_metadata(self, host_id, path, size, modified):
        # A caller's claimed size/time alone cannot authorize a stale cache hit.
        # Reuse only the identity from our successful containing-directory list.
        if type(size) is not int or size <= 0 or not isinstance(modified, str):
            return None
        parent = str(PurePosixPath(path).parent)
        parent = "" if parent == "." else parent
        with self.lock:
            listing = self.list_cache.get((host_id, parent))
            for entry in (listing or {}).get("entries", []):
                if (entry.get("path") == path and not entry.get("isDirectory")
                        and (entry.get("size"), entry.get("modified")) == (size, modified)):
                    return {"Size": size, "ModTime": modified, "IsDir": False}
        return None

    def cached_thumbnail(self, output):
        with self.lock:
            try:
                if output.stat().st_size > 0:
                    # utime never recreates an evicted file as an empty PNG.
                    os.utime(output, None)
                    return self.thumbnail_outcome("ready", path=str(output), cached=True)
                output.unlink(missing_ok=True)
            except FileNotFoundError:
                pass
        return None

    def thumbnail_failure(self, error):
        code = error.code if isinstance(error, BridgeError) else "thumbnail_failed"
        if code in {"preview_busy", "thumbnail-preempted", "thumbnail-revoked"}:
            return self.thumbnail_outcome("deferred", "playback_active", retry_after=1000)
        if code == "thumbnail-resource-busy":
            return self.thumbnail_outcome("deferred", "worker_busy", retry_after=1000)
        terminal = {"unsupported-image": "unsupported_image",
                    "unsupported-video-codec": "unsupported_video", "unsupported-container": "unsupported_video",
                    "thumbnail-pixel-budget": "pixel_budget"}
        if code in terminal:
            return self.thumbnail_outcome("unsupported", terminal[code])
        reason = {"timeout": "thumbnail_timeout", "thumbnail-timeout": "thumbnail_timeout",
                  "source_unavailable": "source_unavailable", "thumbnail-network": "source_unavailable",
                  "thumbnail-resource-transport": "source_unavailable",
                  "thumbnail-resource-budget": "resource_budget", "thumbnail-byte-limit": "resource_budget",
                  "thumbnail-request-limit": "resource_budget", "thumbnail-byte-budget": "resource_budget",
                  "thumbnail-request-budget": "resource_budget"}.get(code, "thumbnail_failed")
        # Legacy unsupported-video also represented HTTP/time/byte failures.
        # It must not permanently suppress a file that could decode on retry.
        return self.thumbnail_outcome("retryable", reason, retry_after=2000)

    def thumbnail(self, hostId, path, size=None, modified=None, **_):
        h, path = self.host(hostId), remote_path(path)
        mime = mimetypes.guess_type(path)[0] or ""
        video = mime.startswith("video/") or PurePosixPath(path).suffix.lower() in {".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v"}
        if not video and not mime.startswith("image/"):
            return self.thumbnail_outcome("unsupported", "unsupported_type")
        try:
            cache = private_dir(self.thumbnail_directory())
            listed = self.listed_thumbnail_metadata(hostId, path, size, modified)
            if listed is not None:
                output = cache / (self.thumbnail_key(h, path, listed, video) + ".png")
                hit = self.cached_thumbnail(output)
                if hit:
                    return hit
        except OSError as error:
            return self.thumbnail_failure(error)
        request_key = (hostId, path)
        slots = self.video_thumb_slots if video else self.thumb_slots
        with self.lock:
            if video:
                if self.playback_pending or self.preview_leases or any(r.get("purpose") != "thumbnail" for r in self.media_leases.values()):
                    return self.thumbnail_outcome("deferred", "playback_active", retry_after=1000)
            if request_key in self.thumbnail_inflight:
                return self.thumbnail_outcome("deferred", "thumbnail_in_progress", retry_after=1000)
            if not slots.acquire(blocking=False):
                return self.thumbnail_outcome("deferred", "worker_busy", retry_after=500)
            self.thumbnail_inflight.add(request_key)
        source = partial = None
        try:
            meta = self.stat(h, path)
            if meta.get("IsDir"):
                return self.thumbnail_outcome("unsupported", "unsupported_type")
            if type(meta.get("Size")) is not int:
                raise BridgeError("protocol_error", "The source metadata was invalid.")
            if meta["Size"] <= 0:
                return self.thumbnail_outcome("unsupported", "empty_source")
            if not video and meta["Size"] > MAX_IMAGE:
                return self.thumbnail_outcome("unsupported", "source_too_large")
            key = self.thumbnail_key(h, path, meta, video)
            output = cache / (key + ".png")
            hit = self.cached_thumbnail(output)
            if hit:
                return hit
            # Concurrent requests must never overwrite/delete another worker's
            # temporary input or output. Only final PNGs enter the LRU budget.
            suffix = secrets.token_hex(8)
            source = cache / (key + "." + suffix + ".source")
            partial = cache / (key + "." + suffix + ".part.png")
            if video:
                media = self._prepare_media(hostId, path, purpose="thumbnail", metadata=meta)
                with self.lock:
                    thumbnail_record = self.media_leases.get(media["leaseId"])
                try:
                    if thumbnail_record is None:
                        raise BridgeError("preview_busy", "Background previews wait for playback.")
                    try:
                        self.native_call("video-thumbnail", "--url", media["streamUrl"], "--output", str(partial),
                                         "--size", "384", "--timeout", "10")
                    except BridgeError:
                        if thumbnail_record["closed"]:
                            raise BridgeError("preview_busy", "Background previews wait for playback.")
                        raise
                    if thumbnail_record["closed"]:
                        raise BridgeError("preview_busy", "Background previews wait for playback.")
                finally:
                    self.release_media(leaseId=media["leaseId"])
            else:
                # Images may need a complete input, but never exceed this cap.
                p = self.run([self.rclone, "cat", ":sftp:" + path, "--count", str(MAX_IMAGE + 1)] + self.engine_args(h))
                if p.returncode or len(p.stdout) != meta["Size"] or len(p.stdout) > MAX_IMAGE:
                    return self.thumbnail_outcome("retryable", "source_unavailable", retry_after=2000)
                source.write_bytes(p.stdout)
                self.native_call("thumbnail", "--file", str(source), "--output", str(partial), "--size", "384")
            # Validate source identity again before persisting the result.
            after = self.stat(h, path)
            if (after.get("Size"), after.get("ModTime")) != (meta["Size"], meta.get("ModTime")):
                return self.thumbnail_outcome("retryable", "source_changed", retry_after=1000)
            with self.lock:
                if partial.stat().st_size <= 0:
                    return self.thumbnail_outcome("retryable", "thumbnail_failed", retry_after=2000)
                partial.replace(output)
                self.evict_thumbnails()
                if not output.is_file():
                    return self.thumbnail_outcome("retryable", "cache_evicted", retry_after=1000)
            return self.thumbnail_outcome("ready", path=str(output), cached=False)
        except (BridgeError, OSError, ValueError, TypeError) as error:
            return self.thumbnail_failure(error)
        finally:
            for temporary in (source, partial):
                if temporary is not None:
                    try:
                        temporary.unlink(missing_ok=True)
                    except OSError:
                        pass
            with self.lock:
                self.thumbnail_inflight.discard(request_key)
                slots.release()

    def evict_thumbnails(self):
        with self.lock:
            files = self.thumbnail_files()
            total = sum(size for _, _, size in files)
            for _, path, size in sorted(files):
                if total <= self.preferences["cacheSettings"]["thumbnailBudgetBytes"]:
                    break
                path.unlink(missing_ok=True)
                total -= size

    @staticmethod
    def thumbnail_directory():
        return (CACHE if CACHE is not None else STATE) / "thumbnails"

    def thumbnail_files(self):
        files = []
        for path in self.thumbnail_directory().glob("*.png"):
            if path.name.endswith(".part.png") or path.is_symlink():
                continue
            try:
                info = path.stat()
            except FileNotFoundError:
                continue
            if stat_module.S_ISREG(info.st_mode):
                files.append((info.st_mtime, path, info.st_size))
        return files

    def cache_snapshot(self):
        with self.lock:
            budget = self.preferences["cacheSettings"]["thumbnailBudgetBytes"]
            try:
                return {"bytesUsed": sum(item[2] for item in self.thumbnail_files()), "budgetBytes": budget}
            except OSError:
                return {"bytesUsed": None, "budgetBytes": budget}

    def set_cache_settings(self, thumbnailBudgetBytes=None, **_):
        with self.lock:
            settings = cache_settings({**self.preferences["cacheSettings"], "thumbnailBudgetBytes": thumbnailBudgetBytes})
            updated = {**self.preferences, "cacheSettings": settings}
            self.save_preferences(updated)
            self.preferences = updated
            pending = False
            try:
                self.evict_thumbnails()
            except OSError:
                pending = True
            return {"cacheSettings": dict(settings), "cache": self.cache_snapshot(), "cacheCleanupPending": pending}

    def clear_thumbnail_cache(self, **_):
        # Share the publish/hit/eviction lock. Never remove an in-progress
        # source, file-preview snapshot, media stream, or mount directory.
        with self.lock:
            removed_files = removed_bytes = failed_files = 0
            try:
                files = self.thumbnail_files()
            except OSError:
                files, failed_files = [], 1
            for _, path, size in files:
                try:
                    path.unlink()
                    removed_files += 1
                    removed_bytes += size
                except FileNotFoundError:
                    continue
                except OSError:
                    failed_files += 1
            return {"cleared": failed_files == 0, "removedFiles": removed_files, "removedBytes": removed_bytes,
                    "failedFiles": failed_files, "cache": self.cache_snapshot()}

    def diagnostics(self, **_):
        # Construct an allowlist instead of redacting status/preferences. That
        # prevents newly added path, alias, activity or capability fields from
        # leaking into copied support reports in later versions.
        snapshot = self.status()
        with self.lock:
            prefs = self.preferences
            settings = prefs["browserSettings"]
            media = list(self.media_leases.values())
            return {"version": 1, "product": "Farshore", "generatedAtUnix": int(time.time()),
                    "runtime": {"pythonVersion": platform.python_version(), "platform": sys.platform,
                                "architecture": platform.machine(), "macOSVersion": platform.mac_ver()[0]},
                    "dependencies": {"nativeAvailable": Path(self.native).is_file(), "rcloneAvailable": Path(self.rclone).is_file()},
                    "preferences": {"schemaVersion": 1, "themeId": prefs["themeId"],
                                    "tabCount": len(prefs["workspace"]["tabs"]),
                                    "favoriteServerCount": len(prefs["favoriteHostIds"]),
                                    "favoriteFolderCount": len(prefs["favoritePaths"]),
                                    "recentPathCount": len(prefs["recentPaths"]),
                                    "browserSettings": {key: settings[key] for key in BROWSER_DEFAULTS}},
                    "sessions": {"mountCount": len(snapshot["mounts"]),
                                 "disconnectedCount": sum(item["state"] == "disconnected" for item in snapshot["mounts"]),
                                 "externalProtectedCount": sum(item["externalAccess"] for item in snapshot["mounts"]),
                                 "mediaPreviewCount": sum(item.get("purpose") != "thumbnail" for item in media),
                                 "backgroundPreviewCount": sum(item.get("purpose") == "thumbnail" for item in media),
                                 "filePreviewCount": len(self.preview_leases)},
                    "cache": snapshot["cache"],
                    "io": {"streamBytesServed": snapshot["streamBytesServed"], "filesystemPayloadBytes": snapshot["readBytes"]}}

    @staticmethod
    def preview_request_id(value):
        if not isinstance(value, str) or not 0 < len(value.encode("utf-8")) <= 128 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise BridgeError("invalid_preview_request", "The preview request identifier is invalid.")
        return value

    @staticmethod
    def preview_kind(path):
        name = PurePosixPath(path).name.lower()
        extension = PurePosixPath(path).suffix.lower().lstrip(".")
        if extension in PREVIEW_IMAGES:
            return "image", mimetypes.guess_type(path)[0] or "application/octet-stream", extension
        if extension in PREVIEW_TEXT or name in PREVIEW_TEXT_NAMES:
            # HTML/XML/Markdown are source text, never a browser or web view.
            return "text", "text/plain", "txt"
        if extension in PREVIEW_DOCUMENTS:
            return "document", mimetypes.guess_type(path)[0] or "application/octet-stream", extension
        raise BridgeError("preview_unsupported", "This file type has no supported in-app preview. Use Open With.")

    def _purge_preview_requests(self):
        cutoff = time.monotonic() - 600
        for key, value in list(self.preview_requests.items()):
            if value.get("finishedAt", float("inf")) < cutoff:
                del self.preview_requests[key]

    def _preview_check(self, record):
        with self.lock:
            if record["cancelled"]:
                raise BridgeError("preview_cancelled", "The preview was cancelled.")
            remaining = record["deadline"] - time.monotonic()
        if remaining <= 0:
            raise BridgeError("preview_timeout", "Preparing the preview timed out. Retry or use Open With.")
        return remaining

    def _preview_process(self, record, args, maximum):
        self._preview_check(record)
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        with self.lock:
            record["process"] = process
        try:
            remaining = self._preview_check(record)
            data, _ = process.communicate(timeout=remaining)
            self._preview_check(record)
            if process.returncode:
                raise BridgeError("preview_source_unavailable", "The source could not be read. Refresh the folder or use Open With.")
            if len(data) > maximum:
                raise BridgeError("preview_too_large", "The source exceeded the preview read budget. Use Open With.")
            return data
        except subprocess.TimeoutExpired:
            raise BridgeError("preview_timeout", "Preparing the preview timed out. Retry or use Open With.")
        except (OSError, ValueError):
            self._preview_check(record)
            raise BridgeError("preview_read_failed", "The preview could not be read. Retry or use Open With.")
        finally:
            try:
                self.stop_stream_process(process)
            except (OSError, subprocess.SubprocessError):
                pass
            finally:
                with self.lock:
                    if record["process"] is process:
                        record["process"] = None

    def _preview_metadata(self, record):
        raw = self._preview_process(record, [self.rclone, "lsjson", ":sftp:" + record["remotePath"], "--stat"] + self.engine_args(record["host"]), 128 * 1024)
        try:
            metadata = json.loads(raw)
            if not isinstance(metadata, dict) or type(metadata.get("Size")) is not int or metadata["Size"] < 0:
                raise ValueError()
            return metadata
        except (ValueError, TypeError):
            raise BridgeError("preview_metadata_invalid", "The source returned invalid preview metadata. Refresh and retry.")

    @staticmethod
    def preview_text(data, truncated):
        encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
        try:
            try:
                text = data.decode(encoding)
            except UnicodeDecodeError as error:
                # A bounded prefix may end partway through a Unicode codepoint.
                if not truncated or error.end != len(data) or error.reason != "unexpected end of data":
                    raise
                text = data[:error.start].decode(encoding)
        except UnicodeError:
            raise BridgeError("preview_binary_text", "This file is binary or uses an unsupported text encoding. Use Open With.")
        if any((ord(c) < 32 and c not in "\t\n\r\f") or 127 <= ord(c) < 160 for c in text):
            raise BridgeError("preview_binary_text", "This file contains binary data and cannot be displayed as text. Use Open With.")
        return text

    def _finish_preview(self, record):
        directory = record.get("directory")
        if directory is not None:
            shutil.rmtree(directory, ignore_errors=True)
            if directory.exists():
                with self.lock:
                    record["preparing"] = False
                    record["cancelled"] = True
                return False  # Retain the reservation until cleanup succeeds.
        with self.lock:
            if self.preview_leases.get(record["previewId"]) is record:
                del self.preview_leases[record["previewId"]]
                self.preview_requests[record["requestId"]] = {"cancelled": True, "finishedAt": time.monotonic()}
        return True

    @staticmethod
    def _reap_preview_directories(root):
        for entry in root.iterdir():
            match = re.fullmatch(r"([1-9][0-9]*)-[a-f0-9]{32}", entry.name)
            if not match or entry.is_symlink() or not entry.is_dir():
                continue
            try:
                os.kill(int(match[1]), 0)
            except ProcessLookupError:
                shutil.rmtree(entry, ignore_errors=True)
            except PermissionError:
                pass

    def prepare_preview(self, hostId, path, requestId=None, **_):
        path = remote_path(path)
        kind, mime, extension = self.preview_kind(path)
        h = self.host(hostId)
        request_id = self.preview_request_id(requestId) if requestId is not None else secrets.token_urlsafe(24)
        with self.lock:
            self._purge_preview_requests()
            previous = self.preview_requests.get(request_id)
            if previous is not None:
                if previous["cancelled"]:
                    raise BridgeError("preview_cancelled", "The preview was cancelled.")
                raise BridgeError("preview_busy", "This preview request is already active.")
            if len(self.preview_leases) >= 2 or len(self.preview_requests) >= 2048 or not self.preview_slots.acquire(blocking=False):
                raise BridgeError("preview_limit", "Close an existing preview before opening another.")
            preview_id = secrets.token_hex(16)
            record = {"previewId": preview_id, "requestId": request_id, "host": h, "remotePath": path,
                      "cancelled": False, "preparing": True, "process": None, "directory": None,
                      "reservedBytes": 0, "deadline": time.monotonic() + PREVIEW_SECONDS}
            self.preview_requests[request_id] = self.preview_leases[preview_id] = record
            background = [key for key, value in self.media_leases.items() if value.get("purpose") == "thumbnail"]
        prepared = False
        try:
            for lease_id in background:
                self.release_media(leaseId=lease_id)
            metadata = self._preview_metadata(record)
            self._preview_check(record)
            if metadata.get("IsDir"):
                raise BridgeError("preview_unsupported", "Choose a regular file to preview.")
            source_bytes = metadata["Size"]
            maximum = MAX_PREVIEW_IMAGE if kind == "image" else MAX_PREVIEW_DOCUMENT if kind == "document" else MAX_PREVIEW_TEXT
            if kind != "text" and source_bytes > maximum:
                raise BridgeError("preview_too_large", "This file exceeds the in-app preview size limit. Use Open With.")
            reserved = min(source_bytes, maximum)
            with self.lock:
                self._preview_check(record)
                if sum(value["reservedBytes"] for value in self.preview_leases.values()) + reserved > MAX_PREVIEW_DISK:
                    raise BridgeError("preview_limit", "Close an existing preview to free its temporary storage.")
                record["reservedBytes"] = reserved
                root = private_dir(STATE / "previews")
                self._reap_preview_directories(root)
                record["directory"] = private_dir(root / (str(os.getpid()) + "-" + preview_id))
            count = min(source_bytes, maximum) + 1
            data = self._preview_process(record, [self.rclone, "cat", ":sftp:" + path, "--count", str(count)] + self.engine_args(h), maximum + 1)
            self._preview_check(record)
            if len(data) != min(source_bytes, count):
                raise BridgeError("preview_source_changed", "The file changed while its preview was being read. Refresh and retry.")
            truncated = kind == "text" and source_bytes > maximum
            payload = data[:maximum]
            text = self.preview_text(payload, truncated) if kind == "text" else None
            after = self._preview_metadata(record)
            if after.get("IsDir") or (after["Size"], after.get("ModTime")) != (source_bytes, metadata.get("ModTime")):
                raise BridgeError("preview_source_changed", "The file changed while its preview was being read. Refresh and retry.")
            self._preview_check(record)
            output = record["directory"] / ("preview." + extension)
            descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as file:
                file.write(payload)
            with self.lock:
                self._preview_check(record)
                record["preparing"] = False
                prepared = True
                result = {"previewId": preview_id, "localPath": str(output), "mimeType": mime,
                          "sourceBytes": source_bytes, "kind": kind}
                if kind == "text":
                    result.update(text=text, truncated=truncated)
                return result
        except OSError:
            self._preview_check(record)
            raise BridgeError("preview_storage_failed", "Temporary preview storage could not be prepared. Retry or use Open With.")
        finally:
            if not prepared:
                self._finish_preview(record)
            self.preview_slots.release()

    def release_preview(self, previewId=None, requestId=None, **_):
        if requestId is not None:
            requestId = self.preview_request_id(requestId)
        if previewId is not None and (not isinstance(previewId, str) or not re.fullmatch(r"[a-f0-9]{32}", previewId)):
            raise BridgeError("invalid_preview_request", "The preview identifier is invalid.")
        with self.lock:
            self._purge_preview_requests()
            by_preview = self.preview_leases.get(previewId) if previewId is not None else None
            by_request = self.preview_requests.get(requestId) if requestId is not None else None
            if by_preview is not None and requestId is not None and by_preview["requestId"] != requestId:
                raise BridgeError("invalid_preview_request", "The preview identifiers do not match.")
            record = by_preview or by_request
            if record is None:
                if requestId is not None:
                    if len(self.preview_requests) >= 2048:
                        raise BridgeError("preview_limit", "Preview cancellation tracking is full. Wait briefly and retry.")
                    self.preview_requests[requestId] = {"cancelled": True, "finishedAt": time.monotonic()}
                return {"released": True}
            if record["cancelled"] and record.get("preparing", True):
                return {"released": True, **({"pending": True} if "previewId" in record else {})}
            record["cancelled"] = True
            process = record["process"]
            preparing = record["preparing"]
        if process is not None:
            try:
                self.stop_stream_process(process)
            except (OSError, subprocess.SubprocessError):
                pass
        if not preparing:
            return {"released": self._finish_preview(record)}
        return {"released": True, "pending": True}

    def release_all_previews(self):
        for preview_id in list(self.preview_leases):
            self.release_preview(previewId=preview_id)

    def mount(self, host_id, path, purpose="external"):
        h = self.host(host_id)
        # Export only the containing directory, never the entire remote tree.
        parent = str(PurePosixPath(path).parent)
        scope = host_id + ":" + parent
        if purpose == "internal":
            scope = "internal:" + scope
        key = hashlib.sha256(scope.encode()).hexdigest()[:20]
        with self.lock:
            existing = self.mounts.get(key)
            if existing and existing["process"].poll() is None and os.path.ismount(existing["path"]):
                local = Path(existing["path"]) / PurePosixPath(path).name
                self.probe_mount_read(local)
                existing["state"] = "mounted"
                return existing, local
            if sum(m["process"].poll() is None for m in self.mounts.values()) >= 6:
                raise BridgeError("mount_limit", "Six filesystem sessions are already active. Close their external files and unmount unused volumes in Finder before opening another folder.")
            self.preflight(h)
            session_dir = private_dir(STATE / "mounts" / key)
            mountpoint = private_dir(session_dir / "files")
            log = session_dir / "engine.jsonl"
            args = [self.rclone, "nfsmount", ":sftp:" + parent, str(mountpoint)] + self.engine_args(h) + [
                "--addr", "127.0.0.1:0", "--read-only", "--option", "ro", "--option", "nobrowse",
                "--option", "soft", "--option", "nolocks", "--option", "timeo=10", "--option", "retrans=2",
                "--vfs-cache-mode", "off", "--buffer-size", "1Mi", "--vfs-read-chunk-size", "2Mi",
                "--vfs-read-chunk-size-limit", "2Mi", "--vfs-case-insensitive=false", "--dir-cache-time", "5s",
                "--poll-interval", "0", "--cache-dir", str(session_dir / "cache"),
                "--use-json-log", "--log-file", str(log), "--log-level", "INFO", "--stats", "2s", "--stats-log-level", "INFO",
                "--log-file-max-size", "4Mi", "--log-file-max-backups", "2"]
            proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True)
            for _ in range(100):
                if proc.poll() is not None:
                    raise BridgeError("mount_unavailable", "The read-only filesystem bridge could not mount. See the local technical-validation notes.")
                if os.path.ismount(mountpoint):
                    break
                time.sleep(0.1)
            else:
                proc.terminate()
                raise BridgeError("mount_unavailable", "Mounting timed out. No application was launched.")
            mounted_file = mountpoint / PurePosixPath(path).name
            try:
                self.probe_mount_read(mounted_file)
            except BridgeError:
                # Leave mounted process alive until explicit cleanup; don't force-unmount.
                self.mounts[key] = {"hostId": host_id, "alias": h["alias"], "path": str(mountpoint), "process": proc,
                                    "external": False, "log": log, "state": "access-blocked"}
                self.save_mounts()
                raise
            session = {"hostId": host_id, "alias": h["alias"], "path": str(mountpoint), "process": proc, "external": False,
                       "log": log, "state": "mounted"}
            self.mounts[key] = session
            self.save_mounts()
            return session, mounted_file

    def probe_mount_read(self, path):
        # Isolate the probe because a failing kernel filesystem read may block.
        # An argument array preserves every special character in the filename.
        p = self.run([sys.executable, "-c", "import sys; f=open(sys.argv[1], 'rb'); f.read(1); f.close()", str(path)], timeout=6)
        if p.returncode:
            raise BridgeError("mount_access_denied", "The volume is mounted, but macOS denied reading it. Check network-volume access for Farshore or the launching app in System Settings. The file was not opened or fully downloaded.")

    def applications(self, hostId, path, **_):
        path = remote_path(path)
        # NSWorkspace can resolve applications from an extension without reading
        # remote bytes or mounting; use a private, empty local placeholder.
        ext = PurePosixPath(path).suffix
        placeholder = private_dir(STATE / "discovery") / ("file" + ext)
        placeholder.touch(exist_ok=True)
        return self.native_call("applications", "--file", str(placeholder))

    def prepare_media(self, hostId, path, **_):
        # Foreground playback gets transport capacity before metadata lookup.
        # Block new background leases until the playback lease is registered.
        with self.lock:
            self.playback_pending += 1
            thumbnails = [key for key, value in self.media_leases.items() if value.get("purpose") == "thumbnail"]
        try:
            for lease in thumbnails:
                self.release_media(leaseId=lease)
            return self._prepare_media(hostId, path)
        finally:
            with self.lock:
                self.playback_pending -= 1

    def _prepare_media(self, hostId, path, purpose="playback", metadata=None):
        path = remote_path(path)
        h = self.host(hostId)
        metadata = metadata if metadata is not None else self.stat(h, path)
        if metadata.get("IsDir"):
            raise BridgeError("invalid_media", "Choose a media file to preview.")
        lease = secrets.token_urlsafe(32)
        with self.lock:
            playback_count = sum(record.get("purpose") != "thumbnail" for record in self.media_leases.values())
            if purpose == "thumbnail" and (self.playback_pending or self.media_leases or self.preview_leases):
                raise BridgeError("preview_busy", "Background previews wait while video playback is active.")
            if purpose != "thumbnail" and playback_count >= 2:
                raise BridgeError("preview_limit", "Close the current video preview before opening another.")
            if self.media_server is None:
                self.media_server = MediaHTTPServer(("127.0.0.1", 0), MediaRequest)
                self.media_server.bridge = self
                threading.Thread(target=self.media_server.serve_forever, daemon=True).start()
            mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
            self.media_leases[lease] = {"token": lease, "host": h, "remotePath": path,
                                       "identity": (metadata.get("Size", 0), metadata.get("ModTime")),
                                       "mimeType": mime, "closed": False, "processes": set(), "purpose": purpose,
                                       "expiresAt": time.monotonic() + VIDEO_THUMB_SECONDS,
                                       "reservedBytes": 0, "requests": 0}
            url = f"http://127.0.0.1:{self.media_server.server_port}/media/{lease}"
        return {"streamUrl": url, "leaseId": lease, "sourceBytes": metadata.get("Size", 0), "mimeType": mime}

    def release_media(self, leaseId=None, mountPath=None, **_):
        with self.lock:
            record = self.media_leases.pop(leaseId, None) if leaseId else None
            if record:
                record["closed"] = True
                processes = list(record["processes"])
            else:
                processes = []
        for process in processes:
            try:
                self.stop_stream_process(process)
            except (OSError, subprocess.SubprocessError):
                pass
        return {"released": record is not None}

    @staticmethod
    def stop_stream_process(process):
        try:
            if process.poll() is not None:
                return
            try:
                # A completed bounded read normally exits without a signal.
                process.wait(timeout=0.05)
                return
            except (OSError, subprocess.TimeoutExpired):
                pass
            for group_signal, direct_signal in ((signal.SIGTERM, process.terminate),
                                                (signal.SIGKILL, process.kill)):
                try:
                    os.killpg(process.pid, group_signal)
                except OSError:
                    # Some launch contexts deny process-group signaling while
                    # permitting termination of this exact owned Popen child.
                    try:
                        direct_signal()
                    except OSError:
                        pass
                try:
                    process.wait(timeout=0.25)
                    return
                except (OSError, subprocess.TimeoutExpired):
                    pass
        except OSError:
            pass
        finally:
            if process.stdout:
                try:
                    process.stdout.close()
                except OSError:
                    pass

    def open_file(self, hostId, path, applicationId=None, remember=False, systemDefault=False, **_):
        path = remote_path(path)
        with self.lock:
            app = None if systemDefault else applicationId or self.preferences["handlers"].get(PurePosixPath(path).suffix.lower())
        # Protect the mount before Launch Services can hand the file to an app.
        # On an ambiguous timeout we conservatively keep this protection.
        with self.lock:
            session, local = self.mount(hostId, path)
            session["external"] = True
            self.save_mounts()
        args = ["--file", str(local)] + (["--app", app] if app else [])
        result = self.native_call("open", *args)
        with self.lock:
            session["external"] = True
            if remember and app:
                self.preferences["handlers"][PurePosixPath(path).suffix.lower()] = app
                self.save_preferences()
            elif remember and systemDefault:
                self.preferences["handlers"].pop(PurePosixPath(path).suffix.lower(), None)
                self.save_preferences()
            self.activity = (self.activity + [{"kind": "playback", "message": "Opened a read-only mounted file. The bridge remains active for the external application."}])[-20:]
        return {"mountPath": str(local), "applicationId": app, **result}

    def choose_application(self, hostId, path, remember=False, **_):
        selected = self.native_call("choose-application")
        app = selected.get("application") or {}
        if not app.get("id"):
            raise BridgeError("selection_cancelled", "No application was selected.")
        return self.open_file(hostId, path, app["id"], remember)

    def status(self, **_):
        with self.lock:
            sessions = [dict(m) for m in self.mounts.values()]
            mounts = [{"hostId": m["hostId"], "path": m["path"], "state": m["state"] if m["process"].poll() is None else "disconnected",
                       "externalAccess": m["external"], "internalReaders": m.get("internalReaders", 0)} for m in sessions]
            activity = [dict(event) for event in self.activity]
            previews = sum(record.get("purpose") != "thumbnail" for record in self.media_leases.values()) + len(self.preview_leases)
            stream_bytes = self.stream_bytes_served
        cache = self.cache_snapshot()
        # rclone's structured stats count remote payload bytes, not encrypted
        # wire bytes. Read only a bounded log tail, never scrape human text.
        samples = []
        for session in sessions:
            try:
                with Path(session["log"]).open("rb") as log:
                    log.seek(0, 2)
                    end = log.tell()
                    log.seek(max(0, end - 65536))
                    lines = log.read(65536).splitlines()
                for line in reversed(lines):
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(event.get("stats", {}).get("bytes"), int):
                        samples.append(event["stats"]["bytes"])
                        break
            except OSError:
                continue
        return {"mounts": mounts, "activity": activity, "cache": cache,
                "readBytes": sum(samples) if samples else None, "readMetric": "SFTP payload bytes, current filesystem sessions",
                "streamBytesServed": stream_bytes,
                "activePreviews": previews,
                "mediaDiskCache": "off", "readBufferBytesPerHandle": 1024**2}

    def unmount(self, hostId, **_):
        with self.lock:
            targets = [(k, m) for k, m in self.mounts.items() if m["hostId"] == hostId]
            if any(m["external"] for _, m in targets):
                raise BridgeError("external_access_active", "An external application may still be reading this host. Close its files first, then unmount the volume explicitly in Finder. Closing a browser tab keeps playback alive.")
            if any(m.get("internalReaders", 0) for _, m in targets):
                raise BridgeError("internal_access_active", "Close the in-app preview before disconnecting this host.")
            if any(record["host"]["id"] == hostId for record in self.media_leases.values()):
                raise BridgeError("internal_access_active", "Close the in-app preview before disconnecting this host.")
            if any(record["host"]["id"] == hostId for record in self.preview_leases.values()):
                raise BridgeError("internal_access_active", "Close the in-app preview before disconnecting this host.")
            for key, m in targets:
                p = self.run(["/usr/sbin/diskutil", "unmount", m["path"]], timeout=8)
                if p.returncode:
                    raise BridgeError("mount_busy", "The volume is busy and was kept mounted.")
                m["process"].terminate()
                del self.mounts[key]
            self.save_mounts()
        return {"unmounted": True}

    def dispatch(self, method, params):
        functions = {"hosts": self.discover, "set_favorite": self.set_favorite, "set_theme": self.set_theme,
                     "save_workspace": self.save_workspace, "set_favorite_path": self.set_favorite_path,
                     "set_cache_settings": self.set_cache_settings, "clear_thumbnail_cache": self.clear_thumbnail_cache,
                     "diagnostics": self.diagnostics,
                     "recent_paths": self.recent_paths, "record_path_visit": self.record_path_visit,
                     "list": lambda **p: self.listing(p.pop("hostId"), **p),
                     "thumbnail": self.thumbnail, "applications": self.applications, "open": self.open_file,
                     "choose_application": self.choose_application, "prepare_media": self.prepare_media,
                     "prepare_preview": self.prepare_preview, "release_preview": self.release_preview,
                     "release_media": self.release_media, "status": self.status, "unmount": self.unmount}
        if method not in functions:
            raise BridgeError("unknown_method", "This operation is not supported by this bridge version.")
        return functions[method](**params)


def response(bridge, request):
    request_id = request.get("id") if isinstance(request, dict) else None
    result = {"version": 1, "id": request_id}
    try:
        if not isinstance(request, dict) or request.get("version") != 1 or not isinstance(request.get("params", {}), dict):
            raise BridgeError("protocol_version", "Expected a version 1 request with object parameters.")
        result.update(ok=True, result=bridge.dispatch(request.get("method"), request.get("params", {})))
    except BridgeError as e:
        result.update(ok=False, error={"code": e.code, "message": e.message})
    except Exception:
        result.update(ok=False, error={"code": "internal_error", "message": "The local bridge could not complete this operation. Refresh and retry."})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["serve", "call"])
    parser.add_argument("method", nargs="?", default="hosts")
    parser.add_argument("--params", default="{}")
    args = parser.parse_args()
    bridge = Bridge()
    if args.command == "call":
        output = response(bridge, {"version": 1, "id": "cli", "method": args.method, "params": json.loads(args.params)})
        print(json.dumps(output))
        return 0 if output["ok"] else 1
    output_lock = threading.Lock()

    def handle(line):
        try:
            request = json.loads(line)
            answer = response(bridge, request)
        except ValueError:
            answer = {"version": 1, "id": None, "ok": False, "error": {"code": "invalid_json", "message": "Invalid request JSON."}}
        encoded = json.dumps(answer, ensure_ascii=True)
        with output_lock:
            print(encoded, flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        # Limit queued work too: stdin backpressure prevents unbounded allocation.
        pending = set()
        while True:
            line = sys.stdin.buffer.readline(65537)
            if not line:
                break
            if len(line) > 65536:
                break  # Reject oversized messages; never execute a truncated request.
            if len(pending) >= 12:
                _, pending = concurrent.futures.wait(pending, return_when=concurrent.futures.FIRST_COMPLETED)
            pending.add(pool.submit(handle, line))
    for lease in list(bridge.media_leases):
        bridge.release_media(leaseId=lease)
    bridge.release_all_previews()
    if bridge.media_server:
        bridge.media_server.shutdown()
        bridge.media_server.server_close()
    # Foreground browser death does not terminate detached external-read mounts.
    # Deliberate lifecycle management is required before product release.
    return 0


if __name__ == "__main__":
    sys.exit(main())
