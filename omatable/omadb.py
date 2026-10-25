"""Servers run by OmaDB (blackcode.omadb), read live from `dbctl state`."""

import json
import os
import subprocess

from .protocol import Error
from .store import ENGINE_COLORS

DEFAULT_DATABASE = {"postgresql": "postgres", "redis": "0", "valkey": "0", "mongodb": "admin"}


def dbctl_path():
    path = os.environ.get("OMATABLE_DBCTL") or os.path.expanduser(
        "~/.config/omarchy/plugins/blackcode.omadb/dbctl")
    return path if os.access(path, os.X_OK) else None


def _state():
    ctl = dbctl_path()
    if not ctl:
        return []
    try:
        r = subprocess.run([ctl, "state"], capture_output=True, text=True, timeout=20)
        services = json.loads(r.stdout).get("services") or []
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError):
        return []
    return [s for s in services if isinstance(s, dict) and s.get("name")]


def _entry(s, secrets):
    engine = s.get("engine", "")
    out = {"id": "omadb:" + s["name"], "name": s["name"], "engine": engine,
           "version": str(s.get("version", "")), "host": "127.0.0.1", "port": int(s.get("port") or 0),
           "user": s.get("user") or "", "database": DEFAULT_DATABASE.get(engine, ""),
           "tag": "local", "color": ENGINE_COLORS.get(engine, "#888888"), "mode": s.get("mode", ""),
           "running": bool(s.get("running")), "source": "omadb", "path": "", "tls": "prefer",
           "ssh": None, "has_password": bool(s.get("password"))}
    if secrets:
        out["password"] = s.get("password") or ""
    return out


def servers(secrets=False):
    return [_entry(s, secrets) for s in _state()]


def server(name):
    for s in _state():
        if s["name"] == name:
            return _entry(s, True)
    raise Error("notfound", f"OmaDB server {name!r} not found")
