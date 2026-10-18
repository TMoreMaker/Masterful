#!/usr/bin/env python3
"""Record an answer in the browser, hear it back from both engines.

Serves a page on http://localhost:8791 that records from the microphone and
posts the audio here. This runs Apple's recogniser exactly as Masterful does
(`masterful-asr-eval file`) and Whisper through WhisperKit — once on its own,
once primed with the vocabulary Masterful has learned — and returns all three.

Everything runs on this Mac. Recordings are kept in Eval/recordings/spontaneous/
(gitignored: they are the user's voice) so a later engine can be measured
against the same speech.

    WHISPERKIT_CLI=/path/to/whisperkit-cli WHISPER_MODEL=/path/to/model \\
        python3 Tools/engine-compare/server.py
"""

import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAGE = Path(__file__).with_name("index.html")
RECORDINGS = ROOT / "Eval" / "recordings" / "spontaneous"
APPLE_CLI = ROOT / ".build" / "debug" / "masterful-asr-eval"
WHISPER_CLI = os.environ.get("WHISPERKIT_CLI")
WHISPER_MODEL = os.environ.get("WHISPER_MODEL")
STORE = Path.home() / "Library" / "Application Support" / "default.store"
PORT = int(os.environ.get("PORT", "8791"))

# One Whisper at a time: two copies of a large model on the Neural Engine at
# once only slow each other down and muddy the timings.
whisper_lock = threading.Lock()


def masterful_settings():
    """Locale and typed vocabulary, read from the app's own preferences."""
    raw = subprocess.run(
        ["defaults", "export", "com.tlotliso.masterful", "-"], capture_output=True
    ).stdout
    try:
        settings = json.loads(plistlib.loads(raw).get("settings.v1", "{}"))
    except Exception:
        settings = {}
    return settings.get("localeIdentifier", "en_ZA"), settings.get("vocabulary", [])


def learned_vocabulary():
    """Terms in the history store, read from a copy so the app is never locked."""
    if not STORE.exists():
        return []
    with tempfile.TemporaryDirectory() as tmp:
        for suffix in ("", "-wal", "-shm"):
            source = Path(str(STORE) + suffix)
            if source.exists():
                shutil.copy(source, Path(tmp) / ("default.store" + suffix))
        try:
            with sqlite3.connect(Path(tmp) / "default.store") as db:
                return [row[0] for row in db.execute("select ZTERM from ZVOCABULARYTERM")]
        except sqlite3.Error:
            return []


def timed(command):
    start = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True)
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    text = lines[-1].strip() if lines else ""
    if result.returncode != 0 and not text:
        text = f"(failed: {result.stderr.strip()[-200:]})"
    return {"text": text, "seconds": round(time.monotonic() - start, 1)}


def apple(path, locale, vocabulary):
    return timed([str(APPLE_CLI), "file", str(path), "--locale", locale,
                  "--vocabulary", ",".join(vocabulary)])


def whisper(path, prompt=None):
    if not (WHISPER_CLI and WHISPER_MODEL):
        return {"text": "(Whisper not configured: set WHISPERKIT_CLI and WHISPER_MODEL)", "seconds": 0}
    command = [WHISPER_CLI, "transcribe", "--model-path", WHISPER_MODEL, "--language", "en",
               "--without-timestamps", "--audio-path", str(path)]
    if prompt:
        command += ["--prompt", prompt]
    with whisper_lock:
        return timed(command)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/index.html"):
            self.send_error(404)
            return
        body = PAGE.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/compare":
            self.send_error(404)
            return
        audio = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        RECORDINGS.mkdir(parents=True, exist_ok=True)
        path = RECORDINGS / time.strftime("%Y-%m-%d-%H%M%S.wav")
        path.write_bytes(audio)

        locale, typed = masterful_settings()
        vocabulary = sorted(set(typed) | set(learned_vocabulary()))
        prompt = ", ".join(vocabulary) + "." if vocabulary else None

        with ThreadPoolExecutor() as pool:
            jobs = {
                "apple": pool.submit(apple, path, locale, vocabulary),
                "whisper": pool.submit(whisper, path),
                "whisperPrimed": pool.submit(whisper, path, prompt),
            }
            results = {name: job.result() for name, job in jobs.items()}

        payload = json.dumps({
            "recording": str(path.relative_to(ROOT)),
            "locale": locale,
            "vocabulary": vocabulary,
            **results,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    if not APPLE_CLI.exists():
        raise SystemExit("Build the Apple side first: swift build --product masterful-asr-eval")
    # Bound to this machine only. The page records a microphone; nothing else
    # on the network has any business reaching it.
    print(f"Engine comparison on http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
