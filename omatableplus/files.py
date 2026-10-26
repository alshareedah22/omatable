"""Files the window opens and saves: folder listings for the picker, and SQL
files read into or written from the editor.
"""

import os
import tempfile

from . import transfer
from .protocol import Error

MAX_EDITOR_BYTES = 4 * 1024 * 1024
MAX_SCRIPT_BYTES = 512 * 1024 * 1024


def listing(path="", extensions=None):
    """Folders and matching files in path: {dir, parent, entries: [{name, dir, size, mtime}]}."""
    path = os.path.abspath(os.path.expanduser(str(path or "~")))
    if os.path.isfile(path):
        path = os.path.dirname(path)
    if not os.path.isdir(path):
        raise Error("notfound", f"no folder at {path}")
    exts = tuple(e.lower() for e in extensions or ())
    entries = []
    try:
        names = os.listdir(path)
    except PermissionError as e:
        raise Error("denied", f"cannot read {path}") from e
    for name in names:
        if name.startswith("."):
            continue
        full = os.path.join(path, name)
        try:
            st = os.stat(full)
        except OSError:
            continue
        is_dir = os.path.isdir(full)
        if not is_dir and exts and not name.lower().endswith(exts):
            continue
        entries.append({"name": name, "dir": is_dir, "size": 0 if is_dir else st.st_size, "mtime": int(st.st_mtime)})
    entries.sort(key=lambda e: (not e["dir"], e["name"].lower()))
    parent = os.path.dirname(path)
    return {"dir": path, "parent": parent if parent != path else "", "entries": entries}


def read_text(path, limit=MAX_EDITOR_BYTES):
    path = os.path.abspath(os.path.expanduser(str(path or "").strip()))
    if not os.path.isfile(path):
        raise Error("notfound", f"no file at {path}")
    size = os.path.getsize(path)
    if size > limit:
        raise Error("toolarge", f"{os.path.basename(path)} is {size // (1024 * 1024)} MB; "
                    "use Run SQL file to run it without opening it")
    with open(path, "rb") as f:
        data = f.read()
    if b"\0" in data[:8192]:
        raise Error("invalid", f"{os.path.basename(path)} is not a text file")
    return {"path": path, "text": data.decode("utf-8", "replace")}


def write_text(path, text, overwrite=False):
    path = transfer.target_path(path, overwrite)
    # A fresh, exclusively created name (mode 600): in a folder others can write to, a
    # guessable one could be planted as a link to another file.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".omatableplus-", suffix=".part")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(str(text))
        os.replace(tmp, path)
    except BaseException:
        if os.path.lexists(tmp):
            os.unlink(tmp)
        raise
    return {"path": path, "bytes": os.path.getsize(path)}
