"""JSON-lines protocol: one request, reply or event per line.

  request  {"id": 7, "method": "conn.list", "params": {...}}
  reply    {"id": 7, "result": ...}  or  {"id": 7, "error": {"code": ..., "message": ...}}
  event    {"event": "progress", ...}

Requests run on a thread pool so a slow query never blocks the others;
replies are written whole under a lock, so lines never interleave.
"""

import base64
import datetime
import decimal
import json
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor


class Error(Exception):
    """An error the window shows to the user: a stable code plus a message."""

    def __init__(self, code, message, detail=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail


def encode(value):
    """JSON fallback for values databases hand back."""
    if isinstance(value, (bytes, bytearray, memoryview)):
        return {"$t": "bytes", "v": base64.b64encode(bytes(value)).decode()}
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, datetime.timedelta):
        return str(value)
    if isinstance(value, (decimal.Decimal, uuid.UUID)):
        return str(value)
    if isinstance(value, (set, frozenset)):
        return sorted(value, key=str)
    return str(value)


class Server:
    def __init__(self, out=None, workers=8):
        self.out = out or sys.stdout
        self.methods = {}
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=workers)

    def method(self, name):
        def register(fn):
            self.methods[name] = fn
            return fn
        return register

    def send(self, obj):
        line = json.dumps(obj, default=encode, ensure_ascii=False)
        with self.lock:
            self.out.write(line + "\n")
            self.out.flush()

    def event(self, name, **fields):
        self.send({"event": name, **fields})

    def reply_error(self, rid, code, message, detail=None):
        error = {"code": code, "message": message}
        if detail:
            error["detail"] = detail
        self.send({"id": rid, "error": error})

    def handle(self, line):
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                raise ValueError
        except ValueError:
            self.reply_error(None, "protocol", "invalid JSON")
            return
        rid = req.get("id")
        fn = self.methods.get(req.get("method"))
        if fn is None:
            self.reply_error(rid, "notfound", f"unknown method {req.get('method')!r}")
            return
        params = req.get("params") or {}
        if not isinstance(params, dict):
            self.reply_error(rid, "invalid", "params must be an object")
            return
        self.pool.submit(self.call, rid, fn, params)

    def call(self, rid, fn, params):
        try:
            result = fn(**params)
        except Error as e:
            self.reply_error(rid, e.code, e.message, e.detail)
        except TypeError as e:
            self.reply_error(rid, "invalid", str(e))
        except Exception as e:  # noqa: BLE001 - every failure must reach the window
            self.reply_error(rid, "internal", f"{type(e).__name__}: {e}")
        else:
            self.send({"id": rid, "result": result})

    def serve(self, inp=None):
        for line in inp or sys.stdin:
            if line.strip():
                self.handle(line)
        self.close()

    def close(self):
        self.pool.shutdown(wait=True)
