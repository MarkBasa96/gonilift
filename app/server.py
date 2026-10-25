"""Gonilift: a local vocal/backing separator for singing practice.

Runs only on this PC (127.0.0.1). Upload a song, the AI model splits it into
vocals and backing, and the browser page plays them with mute/solo, volume,
speed, key and loop. Key-shifted copies are rendered with ffmpeg's Rubber Band
filter and cached, so each key is only rendered once.
"""

import hashlib
import json
import os
import queue
import shutil
import subprocess
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

import numpy as np
import soundfile as sf
from fastapi import FastAPI, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

ROOT = Path(__file__).resolve().parent.parent

# ffmpeg: the copy the installer put in tools\ffmpeg if there is one, else the
# one on PATH. Put first on PATH because audio-separator calls it too.
_bundled_ffmpeg = ROOT / "tools" / "ffmpeg" / "bin"
if (_bundled_ffmpeg / "ffmpeg.exe").exists():
    os.environ["PATH"] = str(_bundled_ffmpeg) + os.pathsep + os.environ.get("PATH", "")
FFMPEG = shutil.which("ffmpeg") or "ffmpeg"
FFPROBE = shutil.which("ffprobe") or "ffprobe"

SONGS = ROOT / "songs"
MODELS = ROOT / "models"
STATIC = Path(__file__).resolve().parent / "static"
SONGS.mkdir(exist_ok=True)
MODELS.mkdir(exist_ok=True)

# Kimberley Jensen's MelBand RoFormer vocal model: vocals SDR 12.6 (vs 10.5
# for the model used before), tagged MIT on Hugging Face, and 41 s instead of
# 76 s for a 3:14 song on an RTX 3050. Commercial use still to be confirmed in
# writing by the author before any paid edition ships.
MODEL = "vocals_mel_band_roformer.ckpt"
# overlap 2 + half precision: about 4x faster than the defaults, and the vocal
# differs from full precision by -68.7 dB (inaudible; measured on the old model).
MDXC_PARAMS = {"segment_size": 256, "override_model_segment_size": False, "batch_size": 1, "overlap": 2, "pitch_shift": 0}
STEMS = ("vocals", "backing")
AUDIO_TYPES = {".mp3", ".wav", ".m4a", ".flac", ".ogg", ".aac", ".opus", ".wma", ".webm", ".mp4"}

@asynccontextmanager
async def lifespan(_app):
    # Runs when a server actually starts, not when this file is imported, so the
    # desktop app can borrow helpers from here without a second worker
    # splitting the same songs.
    purge_removed()  # songs removed last session: safe to delete now
    upgrade_old_songs()
    resume_interrupted()
    threading.Thread(target=worker, daemon=True).start()
    # Load the AI into memory while the app opens, so the first split does not
    # spend ~20 s on "Loading the AI model".
    threading.Thread(target=load_separator, daemon=True, name="warm-up").start()
    yield


app = FastAPI(lifespan=lifespan)
app.mount("/static", StaticFiles(directory=STATIC), name="static")
jobs: "queue.Queue[str]" = queue.Queue()
live: dict[str, dict] = {}  # progress of queued/running songs, kept in memory
cancelled: set[str] = set()
running = {"id": None}
_separator = None


class Cancelled(Exception):
    pass


# ---------- metadata ----------

def meta_path(song_id: str) -> Path:
    return SONGS / song_id / "meta.json"


def read_meta(song_id: str) -> dict:
    p = meta_path(song_id)
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}


def write_meta(song_id: str, **fields) -> None:
    meta = read_meta(song_id) | fields
    meta_path(song_id).write_text(json.dumps(meta, indent=2), encoding="utf-8")


def set_state(song_id: str, state: str, stage: int, message: str, progress: float | None = None) -> None:
    """stage: 0 uploaded, 1 loading model, 2 separating, 3 preparing tracks, 4 done."""
    live[song_id] = {"state": state, "stage": stage, "message": message, "progress": progress}
    write_meta(song_id, state=state, stage=stage, message=message)


def public(song_id: str) -> dict:
    meta = read_meta(song_id)
    meta.pop("peaks", None)
    info = {"id": song_id, **meta, **live.get(song_id, {})}
    info["cover"] = (SONGS / song_id / "cover.jpg").exists()
    return info


DELETED_MARK = ".deleted"


def is_deleted(folder: Path) -> bool:
    return (folder / DELETED_MARK).exists()


def remove_song_folder(path: Path) -> None:
    """Remove a song: it leaves the library now, its files go at next start.

    Antivirus ransomware shields (Trend Micro, measured on Joe's PC) end a
    program that deletes audio files it created itself in the same session,
    the "encrypt a copy, delete the original" signature. Deleting files made
    by an earlier session is not flagged. So a removed song is only marked
    here, and purge_removed() deletes the files when the app next starts.
    Only ever a folder directly inside SONGS.
    """
    path = Path(path).resolve()
    if path.parent != SONGS.resolve() or not path.is_dir():
        return
    (path / DELETED_MARK).touch()


def purge_removed() -> None:
    """Delete the files of songs removed (or half-deleted) in earlier sessions."""
    for folder in SONGS.iterdir():
        if folder.is_dir() and (is_deleted(folder) or not (folder / "meta.json").exists()):
            shutil.rmtree(folder, ignore_errors=True)


def ffmpeg(*args: str) -> None:
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *args], check=True,
                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def probe(path: Path) -> dict:
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries", "format=duration:format_tags=title,artist",
         "-of", "json", str(path)], capture_output=True, text=True,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    fmt = json.loads(out.stdout or "{}").get("format", {})
    tags = {k.lower(): v for k, v in fmt.get("tags", {}).items()}
    return {"duration": float(fmt.get("duration", 0) or 0), "tag_title": tags.get("title"), "artist": tags.get("artist")}


def peaks(path: Path, n: int) -> list[float]:
    # Loudness (RMS) per slice rather than the single loudest sample, so quiet
    # verses and loud choruses look different instead of all hitting the top.
    data, _ = sf.read(path, dtype="float32", always_2d=True)
    mono = data.mean(axis=1)
    usable = len(mono) - len(mono) % n
    if usable <= 0:
        return [0.0] * n
    p = np.sqrt((mono[:usable].reshape(n, -1) ** 2).mean(axis=1))
    top = float(p.max()) or 1.0
    return [round(float(v) / top, 3) for v in p]


# ---------- separation ----------

_separator_lock = threading.Lock()


def load_separator():
    with _separator_lock:  # the warm-up and the first split may both ask at once
        return _load_separator()


def _load_separator():
    global _separator
    if _separator is None:
        from audio_separator.separator import Separator
        from audio_separator.separator.architectures import mdxc_separator

        # The model loops over its chunks with tqdm; swapping it for this
        # wrapper turns each chunk into a real progress update and a place
        # to stop when the user cancels.
        class ProgressLoop:
            def __init__(self, iterable, *args, **kwargs):
                self.items = list(iterable)

            def __iter__(self):
                song_id, total = running["id"], max(len(self.items), 1)
                for i, item in enumerate(self.items):
                    if song_id in cancelled:
                        raise Cancelled()
                    set_state(song_id, "working", 2, "Separating vocals", round(i / total * 100))
                    yield item

        mdxc_separator.tqdm = ProgressLoop
        import torch
        # Half precision is the big speed-up on NVIDIA cards; on CPU it is not
        # supported, so it is switched off there (slower, same result).
        sep = Separator(model_file_dir=str(MODELS), output_format="WAV",
                        use_autocast=torch.cuda.is_available(), mdxc_params=MDXC_PARAMS)
        sep.load_model(model_filename=MODEL)
        _separator = sep
    return _separator


def separate(song_id: str) -> None:
    folder = SONGS / song_id
    shutil.rmtree(folder / "work", ignore_errors=True)  # left by older versions
    for s in STEMS:
        (folder / f"{s}.wav").unlink(missing_ok=True)

    set_state(song_id, "working", 1, "Loading the AI model", 0)
    sep = load_separator()
    if song_id in cancelled:
        raise Cancelled()
    # The tracks are written straight to their final names in the song's own
    # folder. Writing big files and then renaming/moving them is what
    # antivirus "ransomware" protection watches for: on a PC with Trend Micro
    # that pattern got the app frozen and closed right after every split.
    sep.output_dir = str(folder)
    sep.model_instance.output_dir = str(folder)

    started = time.time()
    # Kim's model names its second track "Other"; older models say "Instrumental".
    sep.separate(str(folder / "source.wav"),
                 custom_output_names={"Vocals": "vocals", "Other": "backing", "Instrumental": "backing"})

    set_state(song_id, "working", 3, "Preparing tracks", 100)
    if not all((folder / f"{s}.wav").exists() for s in STEMS):
        raise RuntimeError(f"Model returned unexpected files: {[p.name for p in folder.glob('*.wav')]}")
    write_meta(song_id, model=MODEL, seconds=round(time.time() - started, 1),
               finished=time.strftime("%Y-%m-%d %H:%M"),
               peaks={s: peaks(folder / f"{s}.wav", 1000) for s in STEMS})
    set_state(song_id, "ready", 4, "Split complete", 100)
    live.pop(song_id, None)


def worker() -> None:
    # One song at a time: the GPU has 6 GB and two jobs would fight over it.
    while True:
        song_id = jobs.get()
        try:
            if song_id in cancelled or not meta_path(song_id).exists():
                continue
            running["id"] = song_id
            separate(song_id)
        except Cancelled:
            remove_song_folder(SONGS / song_id)
            live.pop(song_id, None)
        except Exception as e:
            set_state(song_id, "failed", 0, str(e)[:300])
        finally:
            running["id"] = None
            cancelled.discard(song_id)
            jobs.task_done()


def resume_interrupted() -> None:
    # Songs that were queued or mid-split when the app was closed start again.
    pending = []
    for p in SONGS.glob("*/meta.json"):
        meta = json.loads(p.read_text(encoding="utf-8"))
        if meta.get("state") in ("queued", "working"):
            pending.append((meta.get("added", ""), p.parent.name))
    for _, song_id in sorted(pending):
        set_state(song_id, "queued", 0, "Waiting in line")
        jobs.put(song_id)


PEAKS_VERSION = 2


def upgrade_old_songs() -> None:
    # Songs split by an earlier version: fill in missing details and redraw
    # their waveforms with the current method.
    for p in SONGS.glob("*/meta.json"):
        song_id, folder = p.parent.name, p.parent
        meta = json.loads(p.read_text(encoding="utf-8"))
        if meta.get("peaks_version") == PEAKS_VERSION or not (folder / "source.wav").exists():
            continue
        fields = {"peaks_version": PEAKS_VERSION, "thumb": peaks(folder / "source.wav", 48)}
        original = next(folder.glob("original.*"), None)
        if original and not meta.get("duration"):
            info = probe(original)
            fields |= {"duration": round(info["duration"], 2), "artist": meta.get("artist") or info["artist"],
                       "format": original.suffix.lstrip(".").upper(), "size": original.stat().st_size,
                       "filename": meta.get("filename") or f"{meta.get('title', song_id)}{original.suffix}"}
        if all((folder / f"{s}.wav").exists() for s in STEMS):
            fields["peaks"] = {s: peaks(folder / f"{s}.wav", 1000) for s in STEMS}
        write_meta(song_id, **fields)




# ---------- routes ----------

@app.get("/", response_class=HTMLResponse)
def index():
    return (STATIC / "index.html").read_text(encoding="utf-8")


@app.post("/api/split")
async def split(file: UploadFile):
    name = Path(file.filename or "song")
    suffix = name.suffix.lower()
    if suffix not in AUDIO_TYPES:
        raise HTTPException(400, f"Unsupported file type: {suffix or 'none'}")
    data = await file.read()
    song_id = hashlib.sha1(data).hexdigest()[:12]
    folder = SONGS / song_id

    if is_deleted(folder):
        # Removed earlier this session (files wait for the next start): the
        # same song added again simply comes back, with its tracks if done.
        (folder / DELETED_MARK).unlink(missing_ok=True)
        if read_meta(song_id).get("state") == "ready":
            return {"id": song_id, "existing": True}
    if read_meta(song_id).get("state") in ("ready", "queued", "working"):
        return {"id": song_id, "existing": True}

    folder.mkdir(exist_ok=True)
    original = folder / f"original{suffix}"
    original.write_bytes(data)
    info = probe(original)
    write_meta(song_id, filename=name.name, title=info["tag_title"] or name.stem, artist=info["artist"],
               format=suffix.lstrip(".").upper(), size=len(data), duration=round(info["duration"], 2),
               added=time.strftime("%Y-%m-%d %H:%M"))
    try:
        ffmpeg("-i", str(original), "-ac", "2", "-ar", "44100", str(folder / "source.wav"))
    except subprocess.CalledProcessError:
        set_state(song_id, "failed", 0, "This file could not be read as audio.")
        raise HTTPException(400, "This file could not be read as audio.")
    try:  # embedded album art, if the file has any
        ffmpeg("-i", str(original), "-an", "-frames:v", "1", "-vf", "scale=300:300:force_original_aspect_ratio=increase,crop=300:300", str(folder / "cover.jpg"))
    except subprocess.CalledProcessError:
        pass
    write_meta(song_id, thumb=peaks(folder / "source.wav", 48), peaks_version=PEAKS_VERSION)

    # The same file deleted earlier and added again gets the same id; drop any
    # old "skip this one" mark so the worker really splits it this time.
    cancelled.discard(song_id)
    set_state(song_id, "queued", 0, "Waiting in line")
    jobs.put(song_id)
    return {"id": song_id, "existing": False}


@app.get("/api/songs")
def list_songs():
    # A cancelled split disappears from the list at once, even while the
    # worker is still stopping it in the background.
    songs = [public(p.parent.name) for p in SONGS.glob("*/meta.json")
             if p.parent.name not in cancelled and not is_deleted(p.parent)]
    return sorted(songs, key=lambda s: s.get("added") or "", reverse=True)


@app.get("/api/song/{song_id}")
def song(song_id: str):
    if not meta_path(song_id).exists() or is_deleted(SONGS / song_id):
        raise HTTPException(404, "Unknown song")
    return public(song_id)


@app.get("/api/song/{song_id}/peaks")
def song_peaks(song_id: str):
    found = read_meta(song_id).get("peaks")
    if not found:
        raise HTTPException(404, "No peaks yet")
    return found


@app.get("/api/song/{song_id}/cover")
def cover(song_id: str):
    path = SONGS / song_id / "cover.jpg"
    if not path.exists():
        raise HTTPException(404, "No cover")
    return FileResponse(path, media_type="image/jpeg")


@app.post("/api/song/{song_id}/cancel")
def cancel(song_id: str):
    state = read_meta(song_id).get("state")
    if song_id in cancelled:
        return {"cancelled": song_id}  # a second click is fine, not an error
    if state not in ("queued", "working"):
        raise HTTPException(400, "Nothing to cancel")
    cancelled.add(song_id)
    if running["id"] != song_id:  # still waiting in line: remove it now
        remove_song_folder(SONGS / song_id)
        live.pop(song_id, None)
    return {"cancelled": song_id}


@app.post("/api/song/{song_id}/retry")
def retry(song_id: str):
    if read_meta(song_id).get("state") != "failed":
        raise HTTPException(400, "Only failed songs can be retried")
    cancelled.discard(song_id)
    set_state(song_id, "queued", 0, "Waiting in line")
    jobs.put(song_id)
    return {"queued": song_id}


@app.delete("/api/song/{song_id}")
def delete_song(song_id: str):
    if not meta_path(song_id).exists():
        raise HTTPException(404, "Unknown song")
    if running["id"] == song_id:
        raise HTTPException(409, "Cancel the split first")
    if read_meta(song_id).get("state") == "queued":
        cancelled.add(song_id)  # still in the queue: make the worker skip it
    remove_song_folder(SONGS / song_id)
    live.pop(song_id, None)
    return {"deleted": song_id}


def stem_path(song_id: str, stem: str, pitch: int) -> Path:
    if stem not in STEMS or not -12 <= pitch <= 12:
        raise HTTPException(400, "Bad stem or pitch")
    folder = SONGS / song_id
    base = folder / f"{stem}.wav"
    if not base.exists():
        raise HTTPException(404, "Stem not found")
    if not pitch:
        return base
    path = folder / f"{stem}_p{pitch:+d}.wav"
    # Rendered straight to its final name: a temp file plus rename is what
    # antivirus ransomware protection (Trend Micro) froze and closed the app
    # for. A render that was cut off leaves a short file (a finished one is the
    # same size as the original track), so that one is thrown away and redone.
    if path.exists() and path.stat().st_size < base.stat().st_size * 0.95:
        path.unlink(missing_ok=True)
    if not path.exists():
        # Rubber Band changes the key but keeps the speed; formant
        # preservation keeps the voice from sounding chipmunky.
        ratio = 2 ** (pitch / 12)
        try:
            ffmpeg("-i", str(base), "-af", f"rubberband=pitch={ratio}:formant=preserved", str(path))
        except Exception:
            path.unlink(missing_ok=True)
            raise
    return path


def download_name(song_id: str, label: str, pitch: int, ext: str) -> str:
    title = read_meta(song_id).get("title", song_id)
    key = f" ({pitch:+d} st)" if pitch else ""
    return f"{title} - {label}{key}.{ext}"


@app.get("/api/stem/{song_id}/{stem}")
def stem(song_id: str, stem: str, pitch: int = 0, download: bool = False):
    path = stem_path(song_id, stem, pitch)
    name = download_name(song_id, stem, pitch, "wav")
    return FileResponse(path, media_type="audio/wav", filename=name if download else None)
