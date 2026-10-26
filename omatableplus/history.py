"""Query history (history.jsonl) and saved queries (queries.json).

Both live next to connections.json with mode 600: the SQL people run can
hold secrets (ALTER USER … PASSWORD), so it is treated like the passwords file.
"""

import datetime
import json
import os
import threading
import uuid

from .protocol import Error


def _private_open(path, mode):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | (os.O_APPEND if mode == "a" else os.O_TRUNC), 0o600)
    return os.fdopen(fd, mode)


def _ensure_dir(directory):
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)


class History:
    def __init__(self, directory, keep=1000):
        self.dir = directory
        self.path = os.path.join(directory, "history.jsonl")
        self.keep = keep
        self.lock = threading.Lock()

    def _read(self):
        try:
            with open(self.path) as f:
                lines = f.read().splitlines()
        except FileNotFoundError:
            return []
        out = []
        for line in lines:
            try:
                item = json.loads(line)
            except ValueError:
                continue
            if isinstance(item, dict):
                out.append(item)
        return out

    def _rewrite(self, items):
        _ensure_dir(self.dir)
        tmp = self.path + ".tmp"
        with _private_open(tmp, "w") as f:
            for item in items:
                f.write(json.dumps(item, ensure_ascii=False) + "\n")
        os.replace(tmp, self.path)

    def add(self, entry):
        item = {"id": uuid.uuid4().hex[:12],
                "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), **entry}
        with self.lock:
            _ensure_dir(self.dir)
            with _private_open(self.path, "a") as f:
                f.write(json.dumps(item, ensure_ascii=False) + "\n")
            items = self._read()
            if len(items) > self.keep * 1.2:
                self._rewrite(items[-self.keep:])
        return item

    def list(self, conn=None, search="", limit=200):
        with self.lock:
            items = self._read()
        needle = (search or "").lower()
        out = []
        for item in reversed(items):
            if conn and item.get("conn") != conn:
                continue
            if needle and needle not in str(item.get("sql", "")).lower():
                continue
            out.append(item)
            if len(out) >= max(1, int(limit)):
                break
        return out

    def clear(self, conn=None):
        with self.lock:
            items = [i for i in self._read() if conn and i.get("conn") != conn]
            self._rewrite(items)


class Saved:
    def __init__(self, directory):
        self.dir = directory
        self.path = os.path.join(directory, "queries.json")
        self.lock = threading.Lock()

    def _load(self):
        try:
            with open(self.path) as f:
                data = json.load(f)
        except FileNotFoundError:
            return []
        except ValueError:
            raise Error("internal", f"{self.path} is not valid JSON") from None
        return [q for q in data if isinstance(q, dict)] if isinstance(data, list) else []

    def _write(self, items):
        _ensure_dir(self.dir)
        tmp = self.path + ".tmp"
        with _private_open(tmp, "w") as f:
            json.dump(items, f, indent=2, ensure_ascii=False)
        os.replace(tmp, self.path)

    def list(self):
        with self.lock:
            return sorted(self._load(), key=lambda q: str(q.get("name", "")).lower())

    def save(self, name, sql, id=None):  # noqa: A002 - protocol field name
        name = str(name or "").strip()
        if not name or len(name) > 120:
            raise Error("invalid", "give the query a name (up to 120 characters)")
        if not str(sql or "").strip():
            raise Error("invalid", "there is no SQL to save")
        now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        with self.lock:
            items = self._load()
            for q in items:
                if (id and q.get("id") == id) or (not id and q.get("name") == name):
                    q.update(name=name, sql=sql, updated=now)
                    self._write(items)
                    return q
            if id:
                raise Error("notfound", "that saved query no longer exists")
            item = {"id": uuid.uuid4().hex[:12], "name": name, "sql": sql, "updated": now}
            items.append(item)
            self._write(items)
            return item

    def delete(self, id):  # noqa: A002
        with self.lock:
            items = self._load()
            kept = [q for q in items if q.get("id") != id]
            if len(kept) == len(items):
                raise Error("notfound", "that saved query no longer exists")
            self._write(kept)
