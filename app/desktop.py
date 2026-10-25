"""Gonilift desktop app: the same page as the browser version, in its own window.

Starts the local server inside this process, opens a native window (Windows'
built-in Edge WebView2) with Gonilift's icon on the taskbar, and stops
everything when the window closes. A split that was running resumes the next
time the app starts.
"""

import ctypes
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import uvicorn
import webview

APP_DIR = Path(__file__).resolve().parent
ROOT = APP_DIR.parent
ICON = ROOT / "gonilift.ico"

# Started from the shortcut (pythonw) there is no console. Everything the app
# prints, plus any crash, goes to gonilift.log so problems can be traced.
# (The venv's launcher can hand over unusable output handles rather than None,
# so check how we were started, not just whether stdout exists.)
WINDOWLESS = sys.stdout is None or Path(sys.executable).name.lower().startswith("pythonw")
if WINDOWLESS:
    _log = open(ROOT / "gonilift.log", "a", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = _log
    import faulthandler
    faulthandler.enable(_log)  # even hard crashes leave a trace
    threading.excepthook = lambda a: print("Thread crashed:", a.thread.name,
                                           "".join(__import__("traceback").format_exception(a.exc_type, a.exc_value, a.exc_traceback)))
    print(f"\n--- Gonilift started {time.strftime('%Y-%m-%d %H:%M:%S')} ---")

    # The separation library starts ffmpeg itself (version check, saving the
    # tracks). From a windowless app each start got its own console window,
    # which flashed on screen. Give every program we start no window at all.
    _popen_init = subprocess.Popen.__init__

    def _hidden_popen(self, *args, **kwargs):
        if not kwargs.get("creationflags"):
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
        _popen_init(self, *args, **kwargs)

    subprocess.Popen.__init__ = _hidden_popen

sys.path.insert(0, str(APP_DIR))
import server  # noqa: E402  (needs APP_DIR on the path first)


def running_gonilift(port: int = 8765) -> bool:
    # Is Gonilift already being served here (another window, or start.bat)?
    import urllib.request
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/songs", timeout=1.5) as r:
            return r.status == 200 and r.headers.get("content-type", "").startswith("application/json")
    except Exception:
        return False


def free_port(preferred: int = 8765) -> int:
    for port in (preferred, 0):
        with socket.socket() as s:
            try:
                s.bind(("127.0.0.1", port))
                return s.getsockname()[1]
            except OSError:
                continue
    raise RuntimeError("No free port")


def start_server(port: int) -> None:
    config = uvicorn.Config(server.app, host="127.0.0.1", port=port, log_level="warning")
    srv = uvicorn.Server(config)
    threading.Thread(target=srv.run, daemon=True).start()
    for _ in range(200):  # up to 10 s
        if srv.started:
            return
        time.sleep(0.05)
    raise RuntimeError("The Gonilift server did not start")


def downloads_dir() -> Path:
    # The real Downloads folder, even if Windows moved it (e.g. into OneDrive).
    try:
        # FOLDERID_Downloads = {374DE290-123F-4565-9164-39C4925E467B}, as the bytes Windows expects
        fid = (ctypes.c_ubyte * 16)(*bytes.fromhex("90E24D373F126545916439C4925E467B"))
        path = ctypes.c_wchar_p()
        if ctypes.windll.shell32.SHGetKnownFolderPath(fid, 0, None, ctypes.byref(path)) == 0:
            found = Path(path.value)
            ctypes.windll.ole32.CoTaskMemFree(path)
            return found
    except Exception:
        pass
    return Path.home() / "Downloads"


class Api:
    """Called from the page as window.pywebview.api.<name>(...)."""

    def save(self, song_id: str, stems: list, pitch: int = 0) -> dict:
        target = downloads_dir()
        target.mkdir(parents=True, exist_ok=True)
        saved = []
        for stem in stems:
            src = server.stem_path(song_id, stem, int(pitch))
            name = server.download_name(song_id, stem, int(pitch), "wav")
            name = "".join("_" if c in '<>:"/\\|?*' else c for c in name)
            dest = target / name
            n = 2
            while dest.exists():  # never overwrite: "name (2).wav", "name (3).wav", ...
                dest = target / f"{Path(name).stem} ({n}).wav"
                n += 1
            shutil.copyfile(src, dest)
            saved.append(str(dest))
        return {"folder": str(target), "files": saved}

    def reveal(self, path: str) -> None:
        # Opens File Explorer with the saved file selected.
        subprocess.Popen(["explorer", "/select,", os.path.normpath(path)])


def main() -> None:
    # Our own taskbar identity, so Windows shows Gonilift's icon instead of Python's.
    try:
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("JoemarkBasa.Gonilift")
    except Exception:
        pass
    if running_gonilift():
        port = 8765  # share the running server: one worker, one queue
    else:
        port = free_port()
        start_server(port)
    webview.create_window("Gonilift", f"http://127.0.0.1:{port}/", js_api=Api(),
                          width=1600, height=900, min_size=(1000, 680), maximized=True,
                          background_color="#0a0b1c", text_select=True)
    webview.start(private_mode=False, storage_path=str(ROOT / "webview-data"),
                  icon=str(ICON) if ICON.exists() else None)
    print(f"Window closed {time.strftime('%H:%M:%S')}: stopping Gonilift", flush=True)
    os._exit(0)  # stop the server and worker threads with the window


if __name__ == "__main__":
    main()
