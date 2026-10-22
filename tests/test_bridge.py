import json
import io
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
from unittest.mock import Mock, patch

from backend.farshore_bridge import Bridge, BridgeError, MAX_VIDEO_THUMB_BYTES, MAX_VIDEO_THUMB_RANGE, MAX_PREVIEW_IMAGE, MAX_PREVIEW_DOCUMENT, MAX_PREVIEW_TEXT, THEME_IDS, MIN_THUMB_BUDGET, MAX_THUMB_BUDGET, BROWSER_DEFAULTS, byte_range, connection_error, host_aliases, remote_path, response, ssh_args


class PathAndIdentityTests(unittest.TestCase):
    def test_special_names_are_literal_arguments(self):
        path = "Videos/été's $movie; $(touch bad) [01].mp4"
        self.assertEqual(remote_path(path), path)
        args = ssh_args("studio-server")
        self.assertEqual(args[-1], "studio-server")
        self.assertIn("StrictHostKeyChecking=yes", args)
        self.assertIn("ControlPath=none", args)
        for alias in ["-oProxyCommand=bad", "host; touch /tmp/bad", "bad\nname"]:
            with self.assertRaises(BridgeError):
                ssh_args(alias)

    def test_paths_cannot_escape_relative_mount_scope(self):
        for path in ["../private", "a/../../etc/passwd", "x\x00y", "a/../b"]:
            with self.assertRaises(BridgeError):
                remote_path(path)
        self.assertEqual(remote_path("/home/Été"), "/home/Été")

    def test_host_aliases_preserve_identity_and_skip_patterns(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config"
            included = Path(directory) / "extra.conf"
            included.write_text("Host server\n HostKeyAlias linux-at-shared-ip\nInclude " + str(config) + "\n")
            config.write_text("Host linux windows !excluded *.local\nInclude " + str(included) + "\nHost=linux\n")
            self.assertEqual(host_aliases(config), ["linux", "windows", "server"])

    def test_changed_identity_is_not_treated_as_authentication(self):
        error = connection_error("REMOTE HOST IDENTIFICATION HAS CHANGED!", "windows")
        self.assertEqual(error.code, "host_identity_changed")
        self.assertIn("preserved", error.message)


class BridgeProtocolTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.state_patch = patch("backend.farshore_bridge.STATE", Path(self.directory.name))
        self.state_patch.start()
        self.bridge = Bridge()
        self.host = {"id": "linux", "alias": "test-linux", "hostname": "example", "user": "u", "port": 22}
        self.bridge.hosts = {"linux": self.host}

    def tearDown(self):
        self.bridge.release_all_previews()
        if self.bridge.media_server:
            self.bridge.media_server.shutdown()
            self.bridge.media_server.server_close()
        self.state_patch.stop()
        self.directory.cleanup()

    @staticmethod
    def preview_child(data):
        process = Mock()
        process.returncode = 0
        process.poll.return_value = 0
        process.communicate.return_value = (data, None)
        process.stdout = io.BytesIO(data)
        return process

    def assert_no_preview_files(self):
        root = Path(self.directory.name) / "previews"
        self.assertFalse(root.exists() and any(root.iterdir()))
        self.assertEqual(self.bridge.preview_leases, {})

    def test_image_preview_is_private_separate_snapshot_protects_host_and_releases_idempotently(self):
        content = b"small image snapshot"
        metadata = {"Size": len(content), "ModTime": "one", "IsDir": False}
        before = json.loads(json.dumps(self.bridge.preferences))
        child = self.preview_child(content)
        with patch.object(self.bridge, "_preview_metadata", return_value=metadata) as stat, patch("backend.farshore_bridge.subprocess.Popen", return_value=child) as read, patch.object(self.bridge, "mount") as mount:
            prepared = self.bridge.prepare_preview("linux", "/data/picture.heic", "image-request")
        snapshot = Path(prepared["localPath"])
        self.assertEqual(prepared["kind"], "image")
        self.assertEqual(prepared["sourceBytes"], len(content))
        self.assertTrue(snapshot.is_relative_to(Path(self.directory.name) / "previews"))
        self.assertEqual(snapshot.read_bytes(), content)
        self.assertEqual(snapshot.stat().st_mode & 0o777, 0o600)
        self.assertEqual(snapshot.parent.stat().st_mode & 0o777, 0o700)
        self.assertFalse((Path(self.directory.name) / "thumbnails").exists())
        self.assertEqual(self.bridge.status()["activePreviews"], 1)
        self.assertEqual(stat.call_count, 2)
        args = read.call_args.args[0]
        self.assertEqual(args[1:3], ["cat", ":sftp:/data/picture.heic"])
        self.assertEqual(args[args.index("--count") + 1], str(len(content) + 1))
        self.assertIn("StrictHostKeyChecking=yes", args[args.index("--sftp-ssh") + 1])
        mount.assert_not_called()
        with self.assertRaises(BridgeError) as blocked:
            self.bridge.unmount("linux")
        self.assertEqual(blocked.exception.code, "internal_access_active")
        self.assertEqual(self.bridge.release_preview(previewId=prepared["previewId"]), {"released": True})
        self.assertEqual(self.bridge.release_preview(previewId=prepared["previewId"]), {"released": True})
        self.assertEqual(self.bridge.release_preview(requestId="image-request"), {"released": True})
        self.assert_no_preview_files()
        self.assertEqual(self.bridge.status()["activePreviews"], 0)
        self.assertEqual(self.bridge.preferences, before)

    def test_preview_whitelist_and_source_size_limits_prevent_fetches(self):
        for path in ["movie.mp4", "audio.mp3", "archive.zip", "program.exe", "unknown.bin"]:
            with self.subTest(path=path), patch.object(self.bridge, "_preview_metadata") as stat, patch("backend.farshore_bridge.subprocess.Popen") as read:
                with self.assertRaises(BridgeError) as failure:
                    self.bridge.prepare_preview("linux", path, path)
                self.assertEqual(failure.exception.code, "preview_unsupported")
                stat.assert_not_called()
                read.assert_not_called()
        for path, size in [("huge.png", MAX_PREVIEW_IMAGE + 1), ("huge.pdf", MAX_PREVIEW_DOCUMENT + 1)]:
            with self.subTest(path=path), patch.object(self.bridge, "_preview_metadata", return_value={"Size": size}), patch("backend.farshore_bridge.subprocess.Popen") as read:
                with self.assertRaises(BridgeError) as failure:
                    self.bridge.prepare_preview("linux", path, path)
                self.assertEqual(failure.exception.code, "preview_too_large")
                read.assert_not_called()
                self.assert_no_preview_files()

    def test_text_preview_is_bounded_truncated_unicode_safe_and_html_inert(self):
        content = b"a" * (MAX_PREVIEW_TEXT - 1) + "€".encode()
        metadata = {"Size": len(content), "ModTime": "one"}
        child = self.preview_child(content[:MAX_PREVIEW_TEXT + 1])
        with patch.object(self.bridge, "_preview_metadata", return_value=metadata), patch("backend.farshore_bridge.subprocess.Popen", return_value=child) as read:
            result = self.bridge.prepare_preview("linux", "huge.log", "text-prefix")
        self.assertEqual(result["kind"], "text")
        self.assertTrue(result["truncated"])
        self.assertEqual(result["text"], "a" * (MAX_PREVIEW_TEXT - 1))
        self.assertEqual(read.call_args.args[0][4], str(MAX_PREVIEW_TEXT + 1))
        self.assertLessEqual(Path(result["localPath"]).stat().st_size, MAX_PREVIEW_TEXT)
        self.bridge.release_preview(previewId=result["previewId"])
        content = b"<script>never execute this</script>"
        with patch.object(self.bridge, "_preview_metadata", return_value={"Size": len(content)}), patch("backend.farshore_bridge.subprocess.Popen", return_value=self.preview_child(content)):
            html = self.bridge.prepare_preview("linux", "page.html", "html-source")
        self.assertEqual(html["text"], content.decode())
        self.assertEqual(html["mimeType"], "text/plain")
        self.assertEqual(Path(html["localPath"]).suffix, ".txt")
        self.assertFalse(html["truncated"])

    def test_text_preview_accepts_utf8_and_bom_utf16_and_rejects_binary(self):
        for content in ["Snow 雪".encode("utf-8-sig"), "Snow 雪".encode("utf-16"), b"\xfe\xff" + "Snow 雪".encode("utf-16-be")]:
            with self.subTest(content=content), patch.object(self.bridge, "_preview_metadata", return_value={"Size": len(content)}), patch("backend.farshore_bridge.subprocess.Popen", return_value=self.preview_child(content)):
                result = self.bridge.prepare_preview("linux", "README", secrets_id := str(len(self.bridge.preview_requests)))
            self.assertEqual(result["text"], "Snow 雪")
            self.bridge.release_preview(requestId=secrets_id)
        for index, content in enumerate([b"a\x00b", b"\x89PNG\r\n", b"\xffbad", b"a\x1bb"]):
            with self.subTest(content=content), patch.object(self.bridge, "_preview_metadata", return_value={"Size": len(content)}), patch("backend.farshore_bridge.subprocess.Popen", return_value=self.preview_child(content)):
                with self.assertRaises(BridgeError) as failure:
                    self.bridge.prepare_preview("linux", "fake.txt", "binary-" + str(index))
                self.assertEqual(failure.exception.code, "preview_binary_text")
                self.assert_no_preview_files()

    def test_changed_or_overshooting_preview_is_discarded(self):
        before = {"Size": 8, "ModTime": "one"}
        after = {"Size": 8, "ModTime": "two"}
        with patch.object(self.bridge, "_preview_metadata", side_effect=[before, after]), patch("backend.farshore_bridge.subprocess.Popen", return_value=self.preview_child(b"12345678")):
            with self.assertRaises(BridgeError) as failure:
                self.bridge.prepare_preview("linux", "changed.pdf", "changed")
            self.assertEqual(failure.exception.code, "preview_source_changed")
        self.assert_no_preview_files()
        with patch("backend.farshore_bridge.MAX_PREVIEW_IMAGE", 8), patch.object(self.bridge, "_preview_metadata", return_value=before), patch("backend.farshore_bridge.subprocess.Popen", return_value=self.preview_child(b"0123456789")):
            with self.assertRaises(BridgeError) as failure:
                self.bridge.prepare_preview("linux", "growth.png", "growth")
            self.assertEqual(failure.exception.code, "preview_too_large")
        self.assert_no_preview_files()

    def test_release_before_prepare_prevents_late_remote_work_and_tombstones_expire(self):
        self.assertTrue(self.bridge.release_preview(requestId="cancel-before")["released"])
        with patch.object(self.bridge, "_preview_metadata") as stat, patch("backend.farshore_bridge.subprocess.Popen") as read:
            with self.assertRaises(BridgeError) as failure:
                self.bridge.prepare_preview("linux", "file.pdf", "cancel-before")
            self.assertEqual(failure.exception.code, "preview_cancelled")
            stat.assert_not_called()
            read.assert_not_called()
        self.bridge.preview_requests["cancel-before"]["finishedAt"] = time.monotonic() - 601
        with self.bridge.lock:
            self.bridge._purge_preview_requests()
        self.assertNotIn("cancel-before", self.bridge.preview_requests)
        for index in range(2048):
            self.bridge.release_preview(requestId="bounded-" + str(index))
        with self.assertRaises(BridgeError) as failure:
            self.bridge.release_preview(requestId="over-capacity")
        self.assertEqual(failure.exception.code, "preview_limit")
        self.assertEqual(len(self.bridge.preview_requests), 2048)

    def test_cancel_during_metadata_or_read_cannot_publish_a_late_snapshot(self):
        for phase in ["metadata", "read"]:
            entered, finish = threading.Event(), threading.Event()
            failures = []
            child = self.preview_child(b"data")
            def metadata(record):
                if phase == "metadata":
                    entered.set()
                    finish.wait(3)
                return {"Size": 4}
            def communicate(**kwargs):
                entered.set()
                finish.wait(3)
                return b"data", None
            if phase == "read":
                child.communicate.side_effect = communicate
            def prepare():
                try:
                    self.bridge.prepare_preview("linux", "cancel.pdf", phase)
                except BridgeError as error:
                    failures.append(error.code)
            def stop(process):
                finish.set()
            with self.subTest(phase=phase), patch.object(self.bridge, "_preview_metadata", side_effect=metadata), patch("backend.farshore_bridge.subprocess.Popen", return_value=child), patch.object(self.bridge, "stop_stream_process", side_effect=stop) as stopped:
                worker = threading.Thread(target=prepare)
                worker.start()
                try:
                    self.assertTrue(entered.wait(3))
                    ack = self.bridge.release_preview(requestId=phase)
                    self.assertTrue(ack["released"])
                    finish.set()
                finally:
                    finish.set()
                    worker.join(3)
                self.assertFalse(worker.is_alive())
                self.assertEqual(failures, ["preview_cancelled"])
                if phase == "read":
                    self.assertGreaterEqual(stopped.call_count, 1)
                self.assert_no_preview_files()

    def test_preview_leases_and_disk_reservations_are_bounded_and_cleanup_can_retry(self):
        content = b"1234"
        with patch.object(self.bridge, "_preview_metadata", return_value={"Size": len(content)}), patch("backend.farshore_bridge.subprocess.Popen", side_effect=lambda *a, **k: self.preview_child(content)):
            first = self.bridge.prepare_preview("linux", "one.pdf", "one")
            second = self.bridge.prepare_preview("linux", "two.pdf", "two")
            with self.assertRaises(BridgeError) as limit:
                self.bridge.prepare_preview("linux", "three.pdf", "three")
            self.assertEqual(limit.exception.code, "preview_limit")
            with patch("backend.farshore_bridge.shutil.rmtree"):
                self.assertFalse(self.bridge.release_preview(previewId=first["previewId"])["released"])
            self.assertIn(first["previewId"], self.bridge.preview_leases)
            self.assertTrue(Path(first["localPath"]).exists())
            self.assertTrue(self.bridge.release_preview(previewId=first["previewId"])["released"])
            self.bridge.release_preview(previewId=second["previewId"])
            with patch("backend.farshore_bridge.MAX_PREVIEW_DISK", 3):
                with self.assertRaises(BridgeError) as disk:
                    self.bridge.prepare_preview("linux", "disk.pdf", "disk-budget")
                self.assertEqual(disk.exception.code, "preview_limit")
        self.assert_no_preview_files()

    def test_foreground_file_preview_preempts_background_video_and_shutdown_cleans_files(self):
        with patch.object(self.bridge, "stat", return_value={"Size": 10}):
            background = self.bridge._prepare_media("linux", "video.mp4", purpose="thumbnail")
        with patch.object(self.bridge, "_preview_metadata", return_value={"Size": 4}), patch("backend.farshore_bridge.subprocess.Popen", return_value=self.preview_child(b"data")):
            prepared = self.bridge.prepare_preview("linux", "document.docx", "foreground")
        self.assertNotIn(background["leaseId"], self.bridge.media_leases)
        self.assertEqual(prepared["kind"], "document")
        with patch.object(self.bridge, "stat") as stat:
            result = self.bridge.thumbnail("linux", "video.mp4")
            self.assertEqual(result["status"], "deferred")
            stat.assert_not_called()
        self.bridge.release_all_previews()
        self.assert_no_preview_files()

    def test_preview_metadata_reads_are_owned_scoped_and_checked_before_and_after(self):
        content = b"%PDF-local-fixture"
        metadata = json.dumps({"Size": len(content), "ModTime": "one", "IsDir": False}).encode()
        children = [self.preview_child(metadata), self.preview_child(content), self.preview_child(metadata)]
        with patch("backend.farshore_bridge.subprocess.Popen", side_effect=children) as run:
            result = self.bridge.prepare_preview("linux", "/data/document.pdf", "owned-metadata")
        self.assertEqual(result["kind"], "document")
        self.assertEqual(Path(result["localPath"]).read_bytes(), content)
        self.assertEqual([call.args[0][1] for call in run.call_args_list], ["lsjson", "cat", "lsjson"])
        for call, child in zip(run.call_args_list, children):
            self.assertEqual(call.args[0][2], ":sftp:/data/document.pdf")
            self.assertTrue(call.kwargs["start_new_session"])
            self.assertLessEqual(child.communicate.call_args.kwargs["timeout"], 30)

    def test_preview_timeout_and_invalid_metadata_clean_all_temporary_state(self):
        child = self.preview_child(b"data")
        child.communicate.side_effect = subprocess.TimeoutExpired("bounded preview", 30)
        with patch.object(self.bridge, "_preview_metadata", return_value={"Size": 4}), patch("backend.farshore_bridge.subprocess.Popen", return_value=child), patch.object(self.bridge, "stop_stream_process", side_effect=PermissionError("Denied group cleanup")):
            with self.assertRaises(BridgeError) as timeout:
                self.bridge.prepare_preview("linux", "timeout.pdf", "timeout")
        self.assertEqual(timeout.exception.code, "preview_timeout")
        self.assert_no_preview_files()
        with patch("backend.farshore_bridge.subprocess.Popen", return_value=self.preview_child(b"[]")):
            with self.assertRaises(BridgeError) as invalid:
                self.bridge.prepare_preview("linux", "bad.pdf", "bad-metadata")
        self.assertEqual(invalid.exception.code, "preview_metadata_invalid")
        self.assert_no_preview_files()

    def test_preview_filetype_policy_is_extension_based_and_matches_document_and_source_families(self):
        for extension in ["svg", "heic", "heif", "tiff", "avif", "psd"]:
            self.assertEqual(self.bridge.preview_kind("file." + extension)[0], "image")
        for extension in ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "pages", "numbers", "key", "rtf"]:
            self.assertEqual(self.bridge.preview_kind("file." + extension)[0], "document")
        for name in ["README", "Dockerfile", "Makefile", ".env", ".gitignore", "data.ipynb", "page.html", "settings.toml", "source.swift"]:
            self.assertEqual(self.bridge.preview_kind(name), ("text", "text/plain", "txt"))

    def test_protocol_rejects_unknown_versions(self):
        result = response(self.bridge, {"version": 2, "id": "42", "method": "hosts"})
        self.assertEqual(result["id"], "42")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "protocol_version")

    def test_status_keeps_one_session_snapshot_while_thumbnails_are_evicted(self):
        cache = Path(self.directory.name) / "thumbnails"
        cache.mkdir()
        evicted = cache / "evicted.png"
        evicted.write_bytes(b"old")
        (cache / "remaining.png").write_bytes(b"12345")
        process = Mock()
        process.poll.return_value = None
        session = {"hostId": "linux", "path": "/data", "state": "mounted",
                   "external": True, "process": process, "log": str(cache / "missing.log")}
        self.bridge.mounts["one"] = session
        self.bridge.activity = [{"kind": "playback", "message": "Opened a file."}]
        self.bridge.media_leases = {"preview": {"purpose": "playback"}, "thumbnail": {"purpose": "thumbnail"}}
        original_stat = Path.stat
        raced = False
        def racing_stat(path, *args, **kwargs):
            nonlocal raced
            if path == evicted and not raced:
                raced = True
                path.unlink()
                self.bridge.media_leases.clear()
                self.bridge.mounts.clear()
                self.bridge.activity.append({"kind": "later", "message": "New activity."})
            return original_stat(path, *args, **kwargs)
        with patch.object(Path, "stat", racing_stat):
            result = self.bridge.status()
        self.assertTrue(raced)
        self.assertEqual(result["cache"]["bytesUsed"], 5)
        self.assertEqual(result["activePreviews"], 1)
        self.assertEqual(len(result["mounts"]), 1)
        self.assertTrue(result["mounts"][0]["externalAccess"])
        self.assertEqual(result["activity"], [{"kind": "playback", "message": "Opened a file."}])
        self.assertIsNone(result["readBytes"])
        result["activity"][0]["message"] = "Caller mutation"
        self.assertEqual(self.bridge.activity[0]["message"], "Opened a file.")

    def test_listing_keeps_special_filenames_without_shell(self):
        name = "new $clip; '雪'.mp4"
        listing = [{"Name": name, "Path": name, "Size": 123, "IsDir": False, "ModTime": "2026-10-22T00:00:00Z"}]
        p = subprocess.CompletedProcess([], 0, json.dumps(listing).encode(), b"")
        with patch.object(self.bridge, "preflight"), patch.object(self.bridge, "run", return_value=p) as run:
            result = self.bridge.listing("linux", "Videos")
        self.assertEqual(result["entries"][0]["path"], "Videos/" + name)
        self.assertEqual(run.call_args.args[0][2], ":sftp:Videos")
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_oversized_images_are_not_fetched(self):
        with patch.object(self.bridge, "stat", return_value={"Size": 1024**3, "IsDir": False}), patch.object(self.bridge, "run") as run:
            result = self.bridge.thumbnail("linux", "large.png")
        self.assertIsNone(result["path"])
        run.assert_not_called()

    def test_large_video_thumbnail_uses_scoped_range_lease_and_cache(self):
        metadata = {"Size": 4 * 1024**3, "ModTime": "one", "IsDir": False}
        def native(command, *args):
            self.assertEqual(command, "video-thumbnail")
            self.assertIn("--url", args)
            self.assertNotIn("--file", args)
            self.assertEqual(len(self.bridge.media_leases), 1)
            record = next(iter(self.bridge.media_leases.values()))
            self.assertEqual(record["purpose"], "thumbnail")
            Path(args[args.index("--output") + 1]).write_bytes(b"test PNG")
            return {}
        with patch.object(self.bridge, "stat", return_value=metadata), patch.object(self.bridge, "native_call", side_effect=native) as decoder, patch.object(self.bridge, "run") as download:
            result = self.bridge.thumbnail("linux", "/data/movie.mp4")
            cached = self.bridge.thumbnail("linux", "/data/movie.mp4")
        self.assertEqual(result["path"], cached["path"])
        self.assertEqual(result["status"], "ready")
        self.assertFalse(result["cached"])
        self.assertTrue(cached["cached"])
        self.assertTrue(Path(result["path"]).exists())
        self.assertEqual(decoder.call_count, 1)
        download.assert_not_called()
        self.assertEqual(self.bridge.media_leases, {})

    def test_cached_video_is_available_during_playback_only_for_verified_listing_identity(self):
        metadata = {"Size": 100, "ModTime": "unchanged", "IsDir": False}
        def native(command, *args):
            Path(args[args.index("--output") + 1]).write_bytes(b"cached PNG")
            return {}
        with patch.object(self.bridge, "stat", return_value=metadata), patch.object(self.bridge, "native_call", side_effect=native):
            created = self.bridge.thumbnail("linux", "/data/movie.mp4")
        self.bridge.list_cache[("linux", "/data")] = {"entries": [
            {"path": "/data/movie.mp4", "size": 100, "modified": "unchanged", "isDirectory": False}]}
        self.bridge.media_leases["playing"] = {"purpose": "playback"}
        with patch.object(self.bridge, "stat") as stat, patch.object(self.bridge, "native_call") as decoder:
            hit = self.bridge.thumbnail("linux", "/data/movie.mp4", size=100, modified="unchanged")
            forged = self.bridge.thumbnail("linux", "/data/movie.mp4", size=101, modified="unchanged")
            omitted = self.bridge.thumbnail("linux", "/data/movie.mp4")
            self.bridge.list_cache.clear()
            unlisted = self.bridge.thumbnail("linux", "/data/movie.mp4", size=100, modified="unchanged")
        self.assertEqual(hit["path"], created["path"])
        self.assertEqual(hit["status"], "ready")
        self.assertTrue(hit["cached"])
        for deferred in (forged, omitted, unlisted):
            self.assertEqual(deferred, {"path": None, "status": "deferred", "reason": "playback_active", "retryAfterMs": 1000})
        stat.assert_not_called()
        decoder.assert_not_called()

    def test_busy_thumbnail_worker_defers_without_remote_metadata_or_queued_blocking(self):
        self.bridge.video_thumb_slots.acquire()
        try:
            with patch.object(self.bridge, "stat") as stat:
                result = self.bridge.thumbnail("linux", "movie.mp4")
            self.assertEqual(result["status"], "deferred")
            self.assertEqual(result["reason"], "worker_busy")
            stat.assert_not_called()
            self.assertEqual(self.bridge.thumbnail_inflight, set())
        finally:
            self.bridge.video_thumb_slots.release()

    def test_concurrent_duplicate_thumbnail_uses_one_decoder_and_cleans_inflight(self):
        metadata = {"Size": 100, "ModTime": "one", "IsDir": False}
        entered, finish = threading.Event(), threading.Event()
        results, failures = [], []
        def native(command, *args):
            entered.set()
            if not finish.wait(3):
                raise AssertionError("The duplicate test did not release the decoder.")
            Path(args[args.index("--output") + 1]).write_bytes(b"deduplicated PNG")
            return {}
        def first_request():
            try:
                results.append(self.bridge.thumbnail("linux", "movie.mp4"))
            except BaseException as error:
                failures.append(error)
        with patch.object(self.bridge, "stat", return_value=metadata) as stat, patch.object(self.bridge, "native_call", side_effect=native) as decoder:
            worker = threading.Thread(target=first_request)
            worker.start()
            try:
                self.assertTrue(entered.wait(3))
                duplicate = self.bridge.thumbnail("linux", "movie.mp4")
                self.assertEqual(duplicate["status"], "deferred")
                self.assertEqual(duplicate["reason"], "thumbnail_in_progress")
                self.assertEqual(stat.call_count, 1)
            finally:
                finish.set()
                worker.join(3)
            self.assertFalse(worker.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(results[0]["status"], "ready")
            self.assertEqual(decoder.call_count, 1)
        self.assertEqual(self.bridge.thumbnail_inflight, set())
        self.assertEqual(self.bridge.media_leases, {})

    def test_thumbnail_errors_distinguish_transient_failures_and_explicit_limits(self):
        metadata = {"Size": 100, "ModTime": "one", "IsDir": False}
        cases = [("thumbnail-timeout", "retryable", "thumbnail_timeout"),
                 ("unsupported-video", "retryable", "thumbnail_failed"),
                 ("thumbnail-resource-http", "retryable", "thumbnail_failed"),
                 ("thumbnail-resource-transport", "retryable", "source_unavailable"),
                 ("thumbnail-resource-response", "retryable", "thumbnail_failed"),
                 ("thumbnail-resource-busy", "deferred", "worker_busy"),
                 ("thumbnail-byte-budget", "retryable", "resource_budget"),
                 ("thumbnail-request-budget", "retryable", "resource_budget"),
                 ("thumbnail-pixel-budget", "unsupported", "pixel_budget"),
                 ("unsupported-video-codec", "unsupported", "unsupported_video"),
                 ("unsupported-container", "unsupported", "unsupported_video")]
        with patch.object(self.bridge, "stat", return_value=metadata):
            for code, status, reason in cases:
                with self.subTest(code=code), patch.object(self.bridge, "native_call", side_effect=BridgeError(code, "Sanitized failure")):
                    result = self.bridge.thumbnail("linux", "movie.mp4")
                self.assertEqual(result["status"], status)
                self.assertEqual(result["reason"], reason)
                self.assertIsNone(result["path"])
                self.assertEqual(self.bridge.thumbnail_inflight, set())
                self.assertEqual(self.bridge.media_leases, {})
        with patch.object(self.bridge, "stat", side_effect=BridgeError("source_unavailable", "Refresh the folder.")):
            result = self.bridge.thumbnail("linux", "movie.mp4")
        self.assertEqual(result["status"], "retryable")
        self.assertEqual(result["reason"], "source_unavailable")
        self.assertEqual(self.bridge.thumbnail_inflight, set())

    def test_thumbnail_timeout_does_not_negative_cache_later_success(self):
        metadata = {"Size": 100, "ModTime": "one", "IsDir": False}
        def native(command, *args):
            Path(args[args.index("--output") + 1]).write_bytes(b"retried PNG")
            return {}
        with patch.object(self.bridge, "stat", return_value=metadata):
            with patch.object(self.bridge, "native_call", side_effect=BridgeError("thumbnail-timeout", "Timed out.")):
                first = self.bridge.thumbnail("linux", "movie.mp4")
            with patch.object(self.bridge, "native_call", side_effect=native):
                retried = self.bridge.thumbnail("linux", "movie.mp4")
        self.assertEqual(first["status"], "retryable")
        self.assertEqual(retried["status"], "ready")
        self.assertTrue(Path(retried["path"]).exists())

    def test_playback_preemption_defers_thumbnail_without_final_stat_or_partial_cache(self):
        metadata = {"Size": 100, "ModTime": "one", "IsDir": False}
        def native(command, *args):
            self.bridge.prepare_media("linux", "playing.mp4")
            raise BridgeError("unsupported-video", "The revoked URL could not be read.")
        with patch.object(self.bridge, "stat", return_value=metadata) as stat, patch.object(self.bridge, "native_call", side_effect=native):
            result = self.bridge.thumbnail("linux", "movie.mp4")
        self.assertEqual(result["status"], "deferred")
        self.assertEqual(result["reason"], "playback_active")
        self.assertEqual(stat.call_count, 2)  # Initial thumbnail and new foreground metadata only.
        self.assertEqual(list((Path(self.directory.name) / "thumbnails").glob("*")), [])

    def test_preemption_before_thumbnail_captures_lease_is_an_explicit_defer(self):
        metadata = {"Size": 100, "ModTime": "one", "IsDir": False}
        prepare = self.bridge._prepare_media
        def immediately_revoked(*args, **kwargs):
            media = prepare(*args, **kwargs)
            self.bridge.release_media(leaseId=media["leaseId"])
            return media
        with patch.object(self.bridge, "stat", return_value=metadata), patch.object(self.bridge, "_prepare_media", side_effect=immediately_revoked), patch.object(self.bridge, "native_call") as decoder:
            result = self.bridge.thumbnail("linux", "movie.mp4")
        self.assertEqual(result["status"], "deferred")
        self.assertEqual(result["reason"], "playback_active")
        decoder.assert_not_called()
        self.assertEqual(self.bridge.media_leases, {})
        self.assertEqual(self.bridge.thumbnail_inflight, set())

    def test_failed_or_changed_video_thumbnail_releases_and_discards(self):
        before = {"Size": 100, "ModTime": "one", "IsDir": False}
        after = {**before, "ModTime": "two"}
        def native(command, *args):
            Path(args[args.index("--output") + 1]).write_bytes(b"partial PNG")
            return {}
        with patch.object(self.bridge, "stat", side_effect=[before, after]), patch.object(self.bridge, "native_call", side_effect=native):
            self.assertIsNone(self.bridge.thumbnail("linux", "movie.mp4")["path"])
        self.assertEqual(self.bridge.media_leases, {})
        self.assertEqual(list(Path(self.directory.name).glob("thumbnails/*")), [])
        with patch.object(self.bridge, "stat", return_value=before), patch.object(self.bridge, "native_call", side_effect=BridgeError("timeout", "Timed out")):
            self.assertIsNone(self.bridge.thumbnail("linux", "movie.mp4")["path"])
        self.assertEqual(self.bridge.media_leases, {})

    def test_evicted_cached_thumbnail_is_regenerated_without_an_empty_hit(self):
        metadata = {"Size": 100, "ModTime": "one", "IsDir": False}
        def native(command, *args):
            Path(args[args.index("--output") + 1]).write_bytes(b"nonempty PNG")
            return {}
        with patch.object(self.bridge, "stat", return_value=metadata), patch.object(self.bridge, "native_call", side_effect=native) as decoder:
            cached = Path(self.bridge.thumbnail("linux", "movie.mp4")["path"])
            original_stat = Path.stat
            evicted = False
            def racing_stat(path, *args, **kwargs):
                nonlocal evicted
                result = original_stat(path, *args, **kwargs)
                if path == cached and not evicted:
                    evicted = True
                    path.unlink()
                return result
            with patch.object(Path, "stat", racing_stat):
                result = self.bridge.thumbnail("linux", "movie.mp4")
            self.assertTrue(evicted)
            self.assertEqual(result["path"], str(cached))
            self.assertEqual(cached.read_bytes(), b"nonempty PNG")
            self.assertEqual(decoder.call_count, 2)

    def test_favorites_migrate_legacy_preferences_and_survive_reopen(self):
        self.bridge.preferences_path.write_text(json.dumps({"version": 1, "handlers": {".mp4": "player"}, "otherSetting": "keep"}))
        self.bridge.preferences = self.bridge.load_preferences()
        self.assertEqual(self.bridge.preferences["favoriteHostIds"], [])
        result = self.bridge.set_favorite("linux", True)
        self.assertEqual(result["favoriteHostIds"], ["linux"])
        reopened = Bridge()
        self.assertEqual(reopened.preferences["favoriteHostIds"], ["linux"])
        self.assertEqual(reopened.preferences["handlers"], {".mp4": "player"})
        self.assertEqual(reopened.preferences["otherSetting"], "keep")
        self.bridge.set_favorite("linux", True)
        self.assertEqual(self.bridge.preferences["favoriteHostIds"], ["linux"])
        self.bridge.set_favorite("linux", False)
        self.assertEqual(self.bridge.load_preferences()["favoriteHostIds"], [])

    def test_favorite_save_failure_keeps_confirmed_state(self):
        self.bridge.save_preferences()
        with patch.object(self.bridge, "save_preferences", side_effect=BridgeError("preferences_write", "Could not save")):
            with self.assertRaises(BridgeError):
                self.bridge.set_favorite("linux", True)
        self.assertEqual(self.bridge.preferences["favoriteHostIds"], [])
        self.assertEqual(self.bridge.load_preferences()["favoriteHostIds"], [])
        with self.assertRaises(BridgeError):
            self.bridge.set_favorite("linux", "yes")
        with patch.object(self.bridge, "discover"):
            with self.assertRaises(BridgeError):
                self.bridge.set_favorite("missing-host", True)

    def test_workspace_restores_logical_locations_and_browser_settings_without_connections(self):
        workspace = {"version": 1, "tabs": [{"hostId": "linux", "path": "/data"},
                                                {"hostId": "removed-host", "path": ""}], "activeTab": 1, "isHome": True}
        settings = {"view": "gallery", "tileSize": 220, "sort": "largest", "showHidden": True,
                    "inspector": False, "restoreWorkspace": False, "futureSetting": "keep"}
        self.bridge.preferences["unrelated"] = {"preserve": True}
        with patch.object(self.bridge, "run") as run, patch.object(self.bridge, "listing") as listing:
            result = self.bridge.save_workspace(workspace, settings)
            self.assertEqual(result["workspace"], workspace)
            self.assertEqual(result["browserSettings"], settings)
            reopened = Bridge()
            with patch("backend.farshore_bridge.host_aliases", return_value=[]):
                discovered = reopened.dispatch("hosts", {})
        run.assert_not_called()
        listing.assert_not_called()
        self.assertEqual(discovered["workspace"], workspace)
        self.assertEqual(discovered["browserSettings"], settings)
        discovered["workspace"]["tabs"].clear()
        self.assertEqual(reopened.preferences["workspace"], workspace)
        self.assertEqual(reopened.preferences["unrelated"], {"preserve": True})
        self.bridge.save_workspace(workspace, {"sort": "newest"})
        self.assertEqual(self.bridge.preferences["browserSettings"], {**settings, "sort": "newest"})

    def test_new_preference_fields_migrate_and_invalid_saved_values_do_not_rewrite_file(self):
        base = {"version": 1, "handlers": {".txt": "editor"}, "unrelated": {"keep": [1]}}
        malformed = {"workspace": {"version": 99, "tabs": [{"hostId": "a", "path": "../private"}]},
                     "browserSettings": {"tileSize": False}, "favoritePaths": [{"hostId": "a", "path": "../private"}],
                     "cacheSettings": {"thumbnailBudgetBytes": 2**50}}
        for extra in [{}, malformed]:
            with self.subTest(extra=extra):
                original = json.dumps({**base, **extra})
                self.bridge.preferences_path.write_text(original)
                prefs = self.bridge.load_preferences()
                self.assertEqual(prefs["workspace"], {"version": 1, "tabs": [], "activeTab": 0, "isHome": True})
                self.assertEqual(prefs["browserSettings"], BROWSER_DEFAULTS)
                self.assertEqual(prefs["favoritePaths"], [])
                self.assertEqual(prefs["cacheSettings"]["thumbnailBudgetBytes"], 512 * 1024**2)
                self.assertEqual(prefs["unrelated"], base["unrelated"])
                self.assertEqual(self.bridge.preferences_path.read_text(), original)

    def test_invalid_workspace_settings_and_folder_favorites_do_not_save(self):
        workspace = {"version": 1, "tabs": [], "activeTab": 0, "isHome": True}
        requests = [("save_workspace", {"workspace": value}) for value in [None, {}, {**workspace, "version": True},
                    {**workspace, "activeTab": -1}, {**workspace, "tabs": [{"hostId": "a", "path": "../private"}]},
                    {**workspace, "tabs": [{"hostId": "a", "path": "/"}] * 33}]]
        requests += [("save_workspace", {"workspace": workspace, "browserSettings": value}) for value in [[],
                     {"view": "future"}, {"tileSize": True}, {"tileSize": 124}, {"tileSize": float("nan")}, {"showHidden": 1}]]
        requests += [("set_cache_settings", {"thumbnailBudgetBytes": value}) for value in [None, True, 128.0, MIN_THUMB_BUDGET - 1, MAX_THUMB_BUDGET + 1]]
        requests += [("set_favorite_path", params) for params in [{"hostId": "a", "path": "/", "favorite": 1},
                     {"hostId": "bad\nserver", "path": "/", "favorite": True}, {"hostId": "a", "path": "../x", "favorite": True}]]
        before = json.loads(json.dumps(self.bridge.preferences))
        with patch.object(self.bridge, "save_preferences") as save:
            for method, params in requests:
                with self.subTest(method=method, params=params):
                    result = response(self.bridge, {"version": 1, "id": "invalid", "method": method, "params": params})
                    self.assertFalse(result["ok"])
                    self.assertNotEqual(result["error"]["code"], "internal_error")
            save.assert_not_called()
        self.assertEqual(self.bridge.preferences, before)

    def test_favorite_folders_are_host_scoped_deduplicated_and_removable_after_alias_disappears(self):
        with patch.object(self.bridge, "discover") as discover:
            self.bridge.set_favorite_path("linux", "/data/", True)
            self.bridge.set_favorite_path("removed-host", "/data", True)
            self.bridge.set_favorite_path("linux", "/data", True)
            self.assertEqual(len(self.bridge.preferences["favoritePaths"]), 2)
            self.bridge.set_favorite_path("removed-host", "/data", False)
        discover.assert_not_called()
        self.assertEqual(Bridge().preferences["favoritePaths"], [{"hostId": "linux", "path": "/data"}])
        self.bridge.preferences["favoritePaths"] = [{"hostId": "a", "path": f"/folder{i}"} for i in range(50)]
        with self.assertRaises(BridgeError):
            self.bridge.set_favorite_path("a", "/extra", True)
        self.assertEqual(len(self.bridge.preferences["favoritePaths"]), 50)

    def test_new_preference_write_failures_keep_all_confirmed_fields(self):
        self.bridge.save_preferences()
        original = self.bridge.preferences_path.read_bytes()
        confirmed = self.bridge.preferences
        actions = [lambda: self.bridge.save_workspace({"version": 1, "tabs": [], "activeTab": 0, "isHome": False}),
                   lambda: self.bridge.set_favorite_path("missing", "/data", True),
                   lambda: self.bridge.set_cache_settings(MIN_THUMB_BUDGET)]
        with patch.object(Path, "replace", side_effect=PermissionError("read-only disk")):
            for action in actions:
                with self.assertRaises(BridgeError) as failure:
                    action()
                self.assertEqual(failure.exception.code, "preferences_write")
                self.assertIs(self.bridge.preferences, confirmed)
                self.assertEqual(self.bridge.preferences_path.read_bytes(), original)

    def test_concurrent_workspace_folder_cache_and_existing_preferences_preserve_all_changes(self):
        self.bridge.preferences["unrelated"] = {"keep": True}
        workspace = {"version": 1, "tabs": [{"hostId": "missing", "path": "/data"}], "activeTab": 0, "isHome": False}
        actions = [lambda: self.bridge.save_workspace(workspace, {"view": "list"}),
                   lambda: self.bridge.set_favorite_path("missing", "/data", True),
                   lambda: self.bridge.set_cache_settings(MIN_THUMB_BUDGET),
                   lambda: self.bridge.set_theme("orchid"), lambda: self.bridge.set_favorite("linux", True)]
        start, errors = threading.Barrier(len(actions)), []
        def update(action):
            try:
                start.wait(timeout=3)
                action()
            except BaseException as error:
                errors.append(error)
        workers = [threading.Thread(target=update, args=(action,)) for action in actions]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(3)
        self.assertEqual(errors, [])
        self.assertFalse(any(worker.is_alive() for worker in workers))
        reopened = Bridge()
        self.assertEqual(reopened.preferences, self.bridge.preferences)
        self.assertEqual(reopened.preferences["workspace"], workspace)
        self.assertEqual(reopened.preferences["browserSettings"]["view"], "list")
        self.assertEqual(reopened.preferences["favoritePaths"], [{"hostId": "missing", "path": "/data"}])
        self.assertEqual(reopened.preferences["cacheSettings"]["thumbnailBudgetBytes"], MIN_THUMB_BUDGET)
        self.assertEqual(reopened.preferences["themeId"], "orchid")
        self.assertEqual(reopened.preferences["favoriteHostIds"], ["linux"])
        self.assertEqual(reopened.preferences["unrelated"], {"keep": True})

    def test_cache_budget_applies_lru_pressure_and_safe_clear_preserves_preview_mount_and_temporary_data(self):
        cache = Path(self.directory.name) / "thumbnails"
        cache.mkdir()
        for index in range(2):
            path = cache / f"{index}.png"
            with path.open("wb") as file:
                file.truncate(80 * 1024**2)
            os.utime(path, (index + 1, index + 1))
        part = cache / "active.part.png"
        part.write_bytes(b"in progress")
        source = cache / "active.source"
        source.write_bytes(b"source")
        preview = Path(self.directory.name) / "previews" / "snapshot.pdf"
        preview.parent.mkdir()
        preview.write_bytes(b"protected preview")
        mount = Path(self.directory.name) / "mounts" / "volume"
        mount.mkdir(parents=True)
        external = cache / "unrelated-target"
        external.write_bytes(b"symlink target")
        (cache / "link.png").symlink_to(external)
        self.bridge.preview_leases["protected"] = {"host": self.host}
        self.bridge.mounts["protected"] = {"hostId": "linux", "external": True}
        result = self.bridge.set_cache_settings(MIN_THUMB_BUDGET)
        self.assertFalse(result["cacheCleanupPending"])
        self.assertFalse((cache / "0.png").exists())
        self.assertTrue((cache / "1.png").exists())
        self.assertEqual(result["cache"]["bytesUsed"], 80 * 1024**2)
        result = self.bridge.clear_thumbnail_cache()
        self.assertTrue(result["cleared"])
        self.assertEqual(result["removedFiles"], 1)
        self.assertEqual(result["cache"], {"bytesUsed": 0, "budgetBytes": MIN_THUMB_BUDGET})
        for path in [part, source, preview, mount, external, cache / "link.png"]:
            self.assertTrue(path.exists())
        self.assertIn("protected", self.bridge.mounts)
        self.assertIn("protected", self.bridge.preview_leases)
        self.bridge.preview_leases.clear()  # Fixture has no materialized lease.
        self.assertEqual(Bridge().preferences["cacheSettings"]["thumbnailBudgetBytes"], MIN_THUMB_BUDGET)

    def test_cache_clear_failure_is_explicit_and_budget_save_stays_confirmed_if_cleanup_fails(self):
        cache = Path(self.directory.name) / "thumbnails"
        cache.mkdir()
        target = cache / "one.png"
        target.write_bytes(b"123")
        original_unlink = Path.unlink
        def deny(path, *args, **kwargs):
            if path == target:
                raise PermissionError("busy")
            return original_unlink(path, *args, **kwargs)
        with patch.object(Path, "unlink", deny):
            result = self.bridge.clear_thumbnail_cache()
        self.assertFalse(result["cleared"])
        self.assertEqual(result["failedFiles"], 1)
        self.assertEqual(result["cache"]["bytesUsed"], 3)
        with patch.object(self.bridge, "evict_thumbnails", side_effect=PermissionError("busy")):
            result = self.bridge.set_cache_settings(MIN_THUMB_BUDGET)
        self.assertTrue(result["cacheCleanupPending"])
        self.assertEqual(Bridge().preferences["cacheSettings"]["thumbnailBudgetBytes"], MIN_THUMB_BUDGET)

    def test_diagnostics_allowlist_never_exports_connection_paths_capabilities_or_unknown_preferences(self):
        secret = "private-user-host-file-key-token"
        self.bridge.preferences.update({"handlers": {secret: secret}, "favoriteHostIds": [secret],
                                        "favoritePaths": [{"hostId": secret, "path": secret}],
                                        "recentPaths": [{"hostId": secret, "path": secret}], "future": secret})
        self.bridge.preferences["workspace"]["tabs"] = [{"hostId": secret, "path": secret}]
        self.bridge.preferences["browserSettings"]["future"] = secret
        self.bridge.activity = [{"kind": secret, "message": secret}]
        self.bridge.media_leases[secret] = {"purpose": "playback", "token": secret, "remotePath": secret}
        self.bridge.hosts[secret] = {"alias": secret, "hostname": secret, "user": secret}
        process = Mock()
        process.poll.return_value = None
        self.bridge.mounts[secret] = {"hostId": secret, "alias": secret, "path": secret, "state": secret,
                                      "external": True, "process": process, "log": secret}
        result = self.bridge.dispatch("diagnostics", {})
        self.assertNotIn(secret, json.dumps(result))
        self.assertEqual(result["version"], 1)
        self.assertEqual(result["sessions"]["externalProtectedCount"], 1)
        self.assertEqual(result["sessions"]["mediaPreviewCount"], 1)
        self.assertEqual(result["preferences"]["favoriteFolderCount"], 1)
        self.assertEqual(result["cache"]["bytesUsed"], 0)

    def test_portable_helper_overrides_and_cache_root_preserve_state_preview_scope(self):
        cache_root = Path(self.directory.name) / "separate-cache"
        with patch.dict(os.environ, {"FARSHORE_NATIVE": "/bundle/runtime/native", "FARSHORE_RCLONE": "/bundle/runtime/rclone", "RCLONE": "/ignored"}), patch("backend.farshore_bridge.CACHE", cache_root):
            bridge = Bridge()
            self.assertEqual(bridge.native, "/bundle/runtime/native")
            self.assertEqual(bridge.rclone, "/bundle/runtime/rclone")
            cache = bridge.thumbnail_directory()
            self.assertEqual(cache, cache_root / "thumbnails")
            cache.mkdir(parents=True)
            (cache / "cached.png").write_bytes(b"PNG")
            self.assertEqual(bridge.cache_snapshot()["bytesUsed"], 3)
            bridge.clear_thumbnail_cache()
            self.assertFalse((cache / "cached.png").exists())
            self.assertEqual(bridge.preferences_path, Path(self.directory.name) / "preferences.json")

    def test_explicit_private_legacy_registry_is_adopted_conservatively_without_relocating_mounts(self):
        legacy = (Path(self.directory.name) / "legacy").resolve()
        legacy.mkdir(mode=0o700)
        mounted = legacy / "mounts" / "old" / "volume"
        mounted.mkdir(parents=True)
        registry = {"version": 1, "mounts": [
            {"key": "old", "hostId": "removed-host", "alias": "old-server", "path": str(mounted), "pid": 1234, "external": False, "state": "mounted"},
            {"key": "escape", "hostId": "removed-host", "path": str(legacy / "mounts-elsewhere"), "pid": 1234}]}
        original = json.dumps(registry)
        (legacy / "mount-registry.json").write_text(original)
        with patch.dict(os.environ, {"FARSHORE_LEGACY_STATES": str(legacy)}), patch("backend.farshore_bridge.os.path.ismount", return_value=True), patch("backend.farshore_bridge.DetachedProcess.poll", return_value=None), patch("backend.farshore_bridge.os.kill") as kill:
            bridge = Bridge()
            self.assertEqual(list(bridge.mounts), ["old"])
            self.assertEqual(bridge.mounts["old"]["path"], str(mounted))
            self.assertTrue(bridge.mounts["old"]["external"])
            with self.assertRaises(BridgeError) as blocked:
                bridge.unmount("removed-host")
            self.assertEqual(blocked.exception.code, "external_access_active")
            saved = json.loads((Path(self.directory.name) / "mount-registry.json").read_text())
            self.assertEqual(saved["mounts"][0]["path"], str(mounted))
            self.assertEqual((legacy / "mount-registry.json").read_text(), original)
            kill.assert_not_called()
            self.assertIn("old", Bridge().mounts)

    def test_legacy_registry_rejects_untrusted_roots_stale_pids_and_unmounted_paths(self):
        legacy = (Path(self.directory.name) / "legacy").resolve()
        legacy.mkdir(mode=0o755)
        record = {"key": "old", "hostId": "a", "path": str(legacy / "mounts" / "volume"), "pid": 1234}
        (legacy / "mount-registry.json").write_text(json.dumps({"version": 1, "mounts": [record]}))
        with patch.dict(os.environ, {"FARSHORE_LEGACY_STATES": str(legacy)}), patch("backend.farshore_bridge.os.path.ismount", return_value=True), patch("backend.farshore_bridge.DetachedProcess.poll", return_value=None):
            self.assertEqual(Bridge().mounts, {})
        legacy.chmod(0o700)
        with patch.dict(os.environ, {"FARSHORE_LEGACY_STATES": str(legacy)}), patch("backend.farshore_bridge.os.path.ismount", return_value=False):
            self.assertEqual(Bridge().mounts, {})
        with patch.dict(os.environ, {"FARSHORE_LEGACY_STATES": str(legacy)}), patch("backend.farshore_bridge.os.path.ismount", return_value=True), patch("backend.farshore_bridge.DetachedProcess.poll", return_value=1):
            self.assertEqual(Bridge().mounts, {})

    def test_all_theme_ids_persist_reopen_and_are_returned_by_hosts_rpc(self):
        self.bridge.preferences.update({"handlers": {".txt": "editor"}, "favoriteHostIds": ["linux"],
                                        "recentPaths": [{"hostId": "linux", "path": "/data"}],
                                        "unrelated": {"nested": ["keep"]}})
        for theme in THEME_IDS:
            with self.subTest(theme=theme):
                result = response(self.bridge, {"version": 1, "id": "theme", "method": "set_theme", "params": {"themeId": theme}})
                self.assertTrue(result["ok"])
                self.assertEqual(result["result"], {"themeId": theme})
                reopened = Bridge()
                self.assertEqual(reopened.preferences["themeId"], theme)
                self.assertEqual(reopened.preferences["handlers"], {".txt": "editor"})
                self.assertEqual(reopened.preferences["favoriteHostIds"], ["linux"])
                self.assertEqual(reopened.preferences["recentPaths"], [{"hostId": "linux", "path": "/data"}])
                self.assertEqual(reopened.preferences["unrelated"], {"nested": ["keep"]})
                with patch("backend.farshore_bridge.host_aliases", return_value=[]):
                    hosts = response(reopened, {"version": 1, "id": "hosts", "method": "hosts"})
                self.assertEqual(hosts["result"]["themeId"], theme)

    def test_legacy_and_unknown_saved_themes_normalize_without_rewriting_preferences(self):
        self.assertEqual(self.bridge.preferences["themeId"], "shore")
        legacy = {"version": 1, "handlers": {".txt": "editor"}, "favoriteHostIds": ["linux"],
                  "recentPaths": [{"hostId": "linux", "path": "/data"}], "unrelated": {"preserve": True}}
        for extra in [{}, *[{"themeId": value} for value in ["future-theme", None, 3, [], {}, True]]]:
            with self.subTest(extra=extra):
                original = json.dumps({**legacy, **extra})
                self.bridge.preferences_path.write_text(original)
                normalized = self.bridge.load_preferences()
                self.assertEqual(normalized["themeId"], "shore")
                for key, value in legacy.items():
                    self.assertEqual(normalized[key], value)
                self.assertEqual(self.bridge.preferences_path.read_text(), original)

    def test_invalid_theme_rpc_never_mutates_or_saves_preferences(self):
        self.bridge.set_theme("orchid")
        original = self.bridge.preferences_path.read_bytes()
        invalid = [None, "unknown", "Shore", " shore", "shore\n", "", 1, True, [], {}]
        for params in [{}, *[{"themeId": theme} for theme in invalid]]:
            with self.subTest(params=params), patch.object(self.bridge, "save_preferences") as save:
                result = response(self.bridge, {"version": 1, "id": "invalid", "method": "set_theme", "params": params})
                self.assertFalse(result["ok"])
                self.assertEqual(result["error"]["code"], "invalid_theme")
                save.assert_not_called()
                self.assertEqual(self.bridge.preferences["themeId"], "orchid")
                self.assertEqual(self.bridge.preferences_path.read_bytes(), original)

    def test_theme_atomic_write_failure_retains_confirmed_theme_and_other_fields(self):
        self.bridge.preferences["unrelated"] = {"preserve": [1, 2]}
        self.bridge.set_theme("frost")
        confirmed = self.bridge.preferences
        original = self.bridge.preferences_path.read_bytes()
        with patch.object(Path, "replace", side_effect=PermissionError("Read-only preferences")):
            result = response(self.bridge, {"version": 1, "id": "write", "method": "set_theme", "params": {"themeId": "midnight"}})
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "preferences_write")
        self.assertIs(self.bridge.preferences, confirmed)
        self.assertEqual(self.bridge.preferences["themeId"], "frost")
        self.assertEqual(self.bridge.preferences["unrelated"], {"preserve": [1, 2]})
        self.assertEqual(self.bridge.preferences_path.read_bytes(), original)
        self.assertEqual(list(Path(self.directory.name).glob("preferences.*.tmp")), [])

    def test_concurrent_theme_favorite_recent_and_handler_saves_preserve_every_update(self):
        self.bridge.preferences.update({"handlers": {".txt": "editor"}, "unrelated": {"preserve": [1, 2]}})
        self.bridge.list_cache[("linux", "/data")] = {"path": "/data"}
        start = threading.Barrier(5)
        errors = []
        session = {"external": False}
        def update(action):
            try:
                start.wait(timeout=3)
                action()
            except BaseException as error:
                errors.append(error)
        actions = [lambda: self.bridge.set_theme("deep-shore"),
                   lambda: self.bridge.set_favorite("linux", True),
                   lambda: self.bridge.record_path_visit("linux", "/data"),
                   lambda: self.bridge.open_file("linux", "movie.mp4", applicationId="player", remember=True)]
        workers = [threading.Thread(target=update, args=(action,)) for action in actions]
        with patch.object(self.bridge, "mount", return_value=(session, Path("/private/tmp/movie.mp4"))), patch.object(self.bridge, "save_mounts"), patch.object(self.bridge, "native_call", return_value={"accepted": True}):
            for worker in workers:
                worker.start()
            start.wait(timeout=3)
            for worker in workers:
                worker.join(3)
        self.assertFalse(any(worker.is_alive() for worker in workers))
        self.assertEqual(errors, [])
        reopened = Bridge()
        self.assertEqual(reopened.preferences["themeId"], "deep-shore")
        self.assertEqual(reopened.preferences["favoriteHostIds"], ["linux"])
        self.assertEqual(reopened.preferences["recentPaths"], [{"hostId": "linux", "path": "/data"}])
        self.assertEqual(reopened.preferences["handlers"], {".txt": "editor", ".mp4": "player"})
        self.assertEqual(reopened.preferences["unrelated"], {"preserve": [1, 2]})
        self.assertEqual(reopened.preferences, self.bridge.preferences)

    def test_recent_paths_keep_five_unique_destinations_and_survive_reopen(self):
        self.bridge.preferences["handlers"][".mp4"] = "chosen.player"
        self.bridge.preferences["favoriteHostIds"] = ["linux"]
        self.bridge.preferences["otherSetting"] = "keep"
        listing = subprocess.CompletedProcess([], 0, b"[]", b"")
        with patch.object(self.bridge, "preflight"), patch.object(self.bridge, "run", return_value=listing):
            for index in range(7):
                path = "/folder" + str(index)
                self.bridge.listing("linux", path)
                result = self.bridge.record_path_visit("linux", path)
            self.assertEqual([row["path"] for row in result["recentPaths"]], ["/folder6", "/folder5", "/folder4", "/folder3", "/folder2"])
            result = self.bridge.record_path_visit("linux", "/folder3")
        self.assertEqual([row["path"] for row in result["recentPaths"]], ["/folder3", "/folder6", "/folder5", "/folder4", "/folder2"])
        reopened = Bridge()
        self.assertEqual(reopened.recent_paths(), result)
        self.assertEqual(reopened.preferences["handlers"], {".mp4": "chosen.player"})
        self.assertEqual(reopened.preferences["favoriteHostIds"], ["linux"])
        self.assertEqual(reopened.preferences["otherSetting"], "keep")
        # Responses are snapshots, not aliases into persisted preference state.
        result["recentPaths"][0]["path"] = "changed by caller"
        self.assertEqual(self.bridge.recent_paths()["recentPaths"][0]["path"], "/folder3")

    def test_recent_paths_separate_hosts_home_root_and_literal_names(self):
        self.bridge.hosts["other-alias"] = {**self.host, "id": "other-alias", "alias": "other-alias"}
        listing = subprocess.CompletedProcess([], 0, b"[]", b"")
        destinations = [("linux", ""), ("linux", "/"), ("linux", "/data"), ("other-alias", "/data"), ("linux", "/data/  été's $movie; [01]  ")]
        with patch.object(self.bridge, "preflight"), patch.object(self.bridge, "run", return_value=listing):
            for host, path in destinations:
                self.bridge.listing(host, path)
                self.bridge.record_path_visit(host, path)
        self.assertEqual(self.bridge.recent_paths()["recentPaths"], [{"hostId": host, "path": path} for host, path in reversed(destinations)])

    def test_listing_alone_or_failed_path_does_not_enter_launcher_history(self):
        listing = subprocess.CompletedProcess([], 0, b"[]", b"")
        with patch.object(self.bridge, "preflight"), patch.object(self.bridge, "run", return_value=listing):
            self.bridge.listing("linux", "/data")
        self.assertEqual(self.bridge.recent_paths()["recentPaths"], [])
        missing = subprocess.CompletedProcess([], 1, b"", b"directory not found")
        with patch.object(self.bridge, "preflight"), patch.object(self.bridge, "run", return_value=missing):
            with self.assertRaises(BridgeError):
                self.bridge.listing("linux", "/missing")
        with self.assertRaises(BridgeError) as error:
            self.bridge.record_path_visit("linux", "/missing")
        self.assertEqual(error.exception.code, "path_not_visited")
        self.assertEqual(self.bridge.recent_paths()["recentPaths"], [])

    def test_recent_path_save_failure_preserves_confirmed_history(self):
        self.bridge.list_cache[("linux", "/data")] = {"path": "/data"}
        self.bridge.save_preferences()
        with patch.object(self.bridge, "save_preferences", side_effect=BridgeError("preferences_write", "Could not save")):
            with self.assertRaises(BridgeError):
                self.bridge.record_path_visit("linux", "/data")
        self.assertEqual(self.bridge.recent_paths()["recentPaths"], [])
        self.assertEqual(self.bridge.load_preferences()["recentPaths"], [])
        self.assertIn(("linux", "/data"), self.bridge.list_cache)

    def test_recent_path_migration_and_invalid_preferences_preserve_original(self):
        legacy = {"version": 1, "handlers": {".txt": "editor"}, "favoriteHostIds": ["linux"]}
        self.bridge.preferences_path.write_text(json.dumps(legacy))
        self.assertEqual(self.bridge.load_preferences()["recentPaths"], [])
        duplicate_history = [{"hostId": "linux", "path": "/data"}] * 2 + [{"hostId": "linux", "path": "/folder" + str(i)} for i in range(6)]
        self.bridge.preferences_path.write_text(json.dumps({**legacy, "recentPaths": duplicate_history}))
        normalized = self.bridge.load_preferences()
        self.assertEqual(len(normalized["recentPaths"]), 5)
        self.assertEqual(normalized["recentPaths"][0]["path"], "/data")
        for invalid in [None, [{}], [{"hostId": 1, "path": "/data"}], [{"hostId": "linux", "path": "../data"}], [{"hostId": "linux", "path": None}]]:
            original = json.dumps({**legacy, "recentPaths": invalid})
            self.bridge.preferences_path.write_text(original)
            with self.assertRaises(BridgeError) as error:
                self.bridge.load_preferences()
            self.assertEqual(error.exception.code, "preferences_invalid")
            self.assertEqual(self.bridge.preferences_path.read_text(), original)

    def test_absolute_listing_preserves_root_and_missing_path_error(self):
        listing = [{"Name": "video.mp4", "Size": 12, "IsDir": False}]
        for path, child in [("", "video.mp4"), ("/", "/video.mp4"), ("/data2", "/data2/video.mp4")]:
            p = subprocess.CompletedProcess([], 0, json.dumps(listing).encode(), b"")
            with patch.object(self.bridge, "preflight"), patch.object(self.bridge, "run", return_value=p) as run:
                result = self.bridge.listing("linux", path)
            self.assertEqual(result["path"], path)
            self.assertEqual(result["entries"][0]["path"], child)
            self.assertEqual(run.call_args.args[0][2], ":sftp:" + path)
        missing = subprocess.CompletedProcess([], 1, b"", b"directory not found")
        with patch.object(self.bridge, "preflight"), patch.object(self.bridge, "run", return_value=missing):
            with self.assertRaises(BridgeError) as error:
                self.bridge.listing("linux", "/data2")
        self.assertEqual(error.exception.code, "path_not_found")

    def test_active_external_reads_block_disconnect(self):
        self.bridge.mounts["mount"] = {"hostId": "linux", "external": True}
        with self.assertRaises(BridgeError) as e:
            self.bridge.unmount("linux")
        self.assertEqual(e.exception.code, "external_access_active")

    def test_preference_schema_unknown_is_preserved(self):
        self.bridge.preferences_path.write_text('{"version":999,"important":"keep"}')
        with self.assertRaises(BridgeError):
            self.bridge.load_preferences()
        self.assertIn("keep", self.bridge.preferences_path.read_text())

    def test_chooser_cancellation_is_a_normal_result(self):
        with patch.object(self.bridge, "native_call", return_value={"application": None, "cancelled": True}):
            with self.assertRaises(BridgeError) as error:
                self.bridge.choose_application("linux", "movie.mp4")
        self.assertEqual(error.exception.code, "selection_cancelled")

    def test_system_default_bypasses_farshore_rule(self):
        self.bridge.preferences["handlers"][".mp4"] = "chosen.player"
        process = unittest.mock.Mock()
        process.pid = 123
        process.poll.return_value = None
        session = {"hostId": "linux", "path": "/private/tmp/mount", "process": process, "external": False, "state": "mounted"}
        self.bridge.mounts["test"] = session
        with patch.object(self.bridge, "mount", return_value=(session, Path("/private/tmp/mount/movie.mp4"))), patch.object(self.bridge, "native_call", return_value={"accepted": True}) as native:
            self.bridge.open_file("linux", "movie.mp4", systemDefault=True, remember=True)
        self.assertNotIn("--app", native.call_args.args)
        self.assertNotIn(".mp4", self.bridge.preferences["handlers"])
        self.assertTrue(session["external"])

    def test_embedded_media_lease_blocks_disconnect_until_released(self):
        session = {"hostId": "linux", "external": False, "path": "/private/tmp/mount"}
        self.bridge.mounts["test"] = session
        with patch.object(self.bridge, "stat", return_value={"Size": 10, "IsDir": False}), patch.object(self.bridge, "mount", return_value=(session, Path("/private/tmp/mount/movie.mp4"))):
            media = self.bridge.prepare_media("linux", "movie.mp4")
        self.assertEqual(media["sourceBytes"], 10)
        self.assertFalse(session["external"])
        with self.assertRaises(BridgeError) as error:
            self.bridge.unmount("linux")
        self.assertEqual(error.exception.code, "internal_access_active")
        self.assertTrue(self.bridge.release_media(leaseId=media["leaseId"])["released"])
        self.assertEqual(len(self.bridge.media_leases), 0)
        self.assertFalse(self.bridge.release_media(leaseId=media["leaseId"])["released"])

    def test_read_metrics_come_only_from_structured_stats(self):
        process = unittest.mock.Mock()
        process.poll.return_value = None
        log = Path(self.directory.name) / "engine.jsonl"
        log.write_text('partial invalid JSON\n' + json.dumps({"stats": {"bytes": 65536}}) + '\n' + json.dumps({"msg": "Transferred: 99999"}) + '\n')
        self.bridge.mounts["test"] = {"hostId": "linux", "external": False, "path": "/private/tmp/mount", "process": process, "state": "mounted", "log": log}
        self.assertEqual(self.bridge.status()["readBytes"], 65536)

    def test_http_range_parser_boundaries(self):
        self.assertEqual(byte_range("bytes=2-5", 10), (2, 5, True))
        self.assertEqual(byte_range("bytes=-3", 10), (7, 9, True))
        self.assertEqual(byte_range("bytes=8-", 10), (8, 9, True))
        for value in ["bytes=10-", "bytes=-0", "bytes=5-2", "bytes=0-1,4-5", "nonsense"]:
            with self.assertRaises(ValueError):
                byte_range(value, 10)

    def test_protected_media_head_ranges_and_revocation(self):
        metadata = {"Size": 10, "ModTime": "unchanged", "IsDir": False}
        content = b"0123456789"
        def process(args, **kwargs):
            start = int(args[args.index("--offset") + 1])
            count = int(args[args.index("--count") + 1])
            p = unittest.mock.Mock()
            p.stdout = io.BytesIO(content[start:start+count])
            p.poll.return_value = 0
            return p
        with patch.object(self.bridge, "stat", return_value=metadata), patch("backend.farshore_bridge.subprocess.Popen", side_effect=process) as popen:
            media = self.bridge.prepare_media("linux", "video.mp4")
            with urllib.request.urlopen(urllib.request.Request(media["streamUrl"], method="HEAD")) as head:
                self.assertEqual(head.headers["Content-Length"], "10")
                self.assertEqual(head.read(), b"")
            with urllib.request.urlopen(urllib.request.Request(media["streamUrl"], method="HEAD", headers={"Range": "bytes=2-5"})) as head:
                self.assertEqual(head.status, 200)
                self.assertEqual(head.headers["Content-Length"], "10")
                self.assertIsNone(head.headers.get("Content-Range"))
            popen.assert_not_called()
            for header, expected in [("bytes=0-2", b"012"), ("bytes=4-6", b"456"), ("bytes=-2", b"89")]:
                with urllib.request.urlopen(urllib.request.Request(media["streamUrl"], headers={"Range": header})) as read:
                    self.assertEqual(read.status, 206)
                    self.assertEqual(read.read(), expected)
            with self.assertRaises(urllib.error.HTTPError) as denied:
                urllib.request.urlopen(media["streamUrl"] + "/other-file")
            self.assertEqual(denied.exception.code, 404)
            self.bridge.release_media(leaseId=media["leaseId"])
            with self.assertRaises(urllib.error.HTTPError) as revoked:
                urllib.request.urlopen(media["streamUrl"])
            self.assertEqual(revoked.exception.code, 404)

    def test_media_source_change_rejects_resumed_request(self):
        with patch.object(self.bridge, "stat", return_value={"Size": 10, "ModTime": "one", "IsDir": False}):
            media = self.bridge.prepare_media("linux", "video.mp4")
        with patch.object(self.bridge, "stat", return_value={"Size": 10, "ModTime": "two", "IsDir": False}), patch("backend.farshore_bridge.subprocess.Popen") as read:
            with self.assertRaises(urllib.error.HTTPError) as changed:
                urllib.request.urlopen(media["streamUrl"])
            self.assertEqual(changed.exception.code, 409)
            read.assert_not_called()

    def test_failed_http_child_cleanup_never_leaks_background_or_playback_read_permits(self):
        metadata = {"Size": 10, "ModTime": "unchanged", "IsDir": False}
        def process(args, **kwargs):
            child = Mock()
            child.stdout = io.BytesIO(b"0123456789")
            child.poll.return_value = 0
            return child
        with patch.object(self.bridge, "stat", return_value=metadata), patch("backend.farshore_bridge.subprocess.Popen", side_effect=process), patch.object(self.bridge, "stop_stream_process", side_effect=PermissionError("Denied group signal")):
            media = self.bridge._prepare_media("linux", "video.mp4", purpose="thumbnail")
            for _ in range(3):
                request = urllib.request.Request(media["streamUrl"], headers={"Range": "bytes=0-9"})
                with urllib.request.urlopen(request, timeout=3) as read:
                    self.assertEqual(read.read(), b"0123456789")
                with urllib.request.urlopen(urllib.request.Request(media["streamUrl"], method="HEAD"), timeout=3) as head:
                    self.assertEqual(head.status, 200)
            self.assertTrue(self.bridge.thumbnail_stream_slots.acquire(timeout=1))
            self.bridge.thumbnail_stream_slots.release()
            self.assertTrue(self.bridge.stream_slots.acquire(timeout=1))
            self.assertTrue(self.bridge.stream_slots.acquire(timeout=1))
            self.bridge.stream_slots.release()
            self.bridge.stream_slots.release()
            self.assertEqual(self.bridge.media_leases[media["leaseId"]]["processes"], set())

    def test_sequential_decoder_range_waits_briefly_for_previous_child_cleanup(self):
        metadata = {"Size": 10, "ModTime": "unchanged", "IsDir": False}
        def process(args, **kwargs):
            child = Mock()
            child.stdout = io.BytesIO(b"0123456789")
            child.poll.return_value = 0
            return child
        cleanup_started = threading.Event()
        clean = self.bridge.stop_stream_process
        calls = []
        def delayed_cleanup(child):
            calls.append(child)
            if len(calls) == 1:
                cleanup_started.set()
                time.sleep(0.15)
            clean(child)
        with patch.object(self.bridge, "stat", return_value=metadata), patch("backend.farshore_bridge.subprocess.Popen", side_effect=process), patch.object(self.bridge, "stop_stream_process", side_effect=delayed_cleanup):
            media = self.bridge._prepare_media("linux", "video.mp4", purpose="thumbnail")
            request = urllib.request.Request(media["streamUrl"], headers={"Range": "bytes=0-9"})
            with urllib.request.urlopen(request, timeout=3) as read:
                self.assertEqual(read.read(), b"0123456789")
            self.assertTrue(cleanup_started.wait(1))
            with urllib.request.urlopen(request, timeout=3) as resumed:
                self.assertEqual(resumed.status, 206)
                self.assertEqual(resumed.read(), b"0123456789")
            self.assertEqual(len(calls), 2)

    def test_stream_child_signaling_denial_uses_bounded_owned_process_fallback_and_closes_pipe(self):
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired("owned child", 0.25)
        process.terminate.side_effect = PermissionError("Denied child termination")
        process.kill.side_effect = PermissionError("Denied child kill")
        process.stdout.close.side_effect = PermissionError("Denied pipe close")
        with patch("backend.farshore_bridge.os.killpg", side_effect=PermissionError("Denied process group")) as group:
            self.bridge.stop_stream_process(process)
        self.assertEqual([call.kwargs["timeout"] for call in process.wait.call_args_list], [0.05, 0.25, 0.25])
        self.assertEqual(group.call_count, 2)
        process.terminate.assert_called_once_with()
        process.kill.assert_called_once_with()
        process.stdout.close.assert_called_once_with()

    def test_thumbnail_ranges_have_aggregate_budget_and_deadline(self):
        metadata = {"Size": 32 * 1024**2, "ModTime": "unchanged", "IsDir": False}
        def process(args, **kwargs):
            count = int(args[args.index("--count") + 1])
            p = unittest.mock.Mock()
            p.stdout = io.BytesIO(b"x" * count)
            p.poll.return_value = 0
            return p
        with patch.object(self.bridge, "stat", return_value=metadata), patch("backend.farshore_bridge.subprocess.Popen", side_effect=process) as popen:
            media = self.bridge._prepare_media("linux", "video.mp4", purpose="thumbnail")
            with self.assertRaises(urllib.error.HTTPError) as whole_file:
                urllib.request.urlopen(media["streamUrl"], timeout=3)
            self.assertEqual(whole_file.exception.code, 413)
            popen.assert_not_called()
            for _ in range(MAX_VIDEO_THUMB_BYTES // MAX_VIDEO_THUMB_RANGE):
                request = urllib.request.Request(media["streamUrl"], headers={"Range": "bytes=0-"})
                with urllib.request.urlopen(request, timeout=3) as read:
                    self.assertEqual(read.status, 206)
                    self.assertEqual(read.headers["Content-Range"], f"bytes 0-{MAX_VIDEO_THUMB_RANGE - 1}/{metadata['Size']}")
                    self.assertEqual(len(read.read()), MAX_VIDEO_THUMB_RANGE)
            record = self.bridge.media_leases[media["leaseId"]]
            self.assertEqual(record["reservedBytes"], MAX_VIDEO_THUMB_BYTES)
            with self.assertRaises(urllib.error.HTTPError) as exhausted:
                urllib.request.urlopen(request, timeout=3)
            self.assertEqual(exhausted.exception.code, 429)
            self.assertEqual(popen.call_count, 4)
            record["expiresAt"] = time.monotonic() - 1
            with self.assertRaises(urllib.error.HTTPError) as expired:
                urllib.request.urlopen(request, timeout=3)
            self.assertEqual(expired.exception.code, 410)

    def test_thumbnail_request_limit_includes_metadata_only_requests(self):
        with patch.object(self.bridge, "stat", return_value={"Size": 100, "IsDir": False}), patch("backend.farshore_bridge.subprocess.Popen") as popen:
            media = self.bridge._prepare_media("linux", "video.mp4", purpose="thumbnail")
            request = urllib.request.Request(media["streamUrl"], method="HEAD")
            for _ in range(12):
                with urllib.request.urlopen(request, timeout=3) as head:
                    self.assertEqual(head.status, 200)
            with self.assertRaises(urllib.error.HTTPError) as exhausted:
                urllib.request.urlopen(request, timeout=3)
            self.assertEqual(exhausted.exception.code, 429)
            popen.assert_not_called()

    def test_playback_preempts_background_thumbnail_and_does_not_wait_for_it(self):
        with patch.object(self.bridge, "stat", return_value={"Size": 100, "IsDir": False}), patch.object(self.bridge, "stop_stream_process") as stop:
            background = self.bridge._prepare_media("linux", "video.mp4", purpose="thumbnail")
            process = unittest.mock.Mock()
            self.bridge.media_leases[background["leaseId"]]["processes"].add(process)
            playback = self.bridge.prepare_media("linux", "video.mp4")
            stop.assert_called_once_with(process)
            self.assertNotIn(background["leaseId"], self.bridge.media_leases)
            self.assertIn(playback["leaseId"], self.bridge.media_leases)
            self.assertEqual(self.bridge.playback_pending, 0)
            with self.assertRaises(urllib.error.HTTPError) as revoked:
                urllib.request.urlopen(background["streamUrl"], timeout=3)
            self.assertEqual(revoked.exception.code, 404)
        with patch.object(self.bridge, "stat") as stat:
            self.assertIsNone(self.bridge.thumbnail("linux", "another.mp4")["path"])
            stat.assert_not_called()


if __name__ == "__main__":
    unittest.main()
