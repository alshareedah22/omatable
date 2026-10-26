"""MongoDB values as text: read mongosh-style input, write Extended JSON.

`parse` accepts plain JSON, Extended JSON and what people type into mongosh:
unquoted keys, single quotes, trailing commas, // comments, /regex/flags and
the usual constructors (ObjectId, ISODate, new Date, NumberLong, NumberInt,
NumberDecimal, UUID, Timestamp, BinData). The shell syntax is rewritten to
Extended JSON first, then bson.json_util reads it.
"""

import base64
import datetime
import json
import math
import re

from bson import json_util
from bson.binary import Binary
from bson.decimal128 import Decimal128
from bson.json_util import CANONICAL_JSON_OPTIONS, RELAXED_JSON_OPTIONS
from bson.objectid import ObjectId
from bson.regex import Regex

from .protocol import Error

IDENT = re.compile(r"[A-Za-z_$][\w$]*")
NUMBER = re.compile(r"-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
LITERALS = {"true": "true", "false": "false", "null": "null", "undefined": "null",
            "NaN": '{"$numberDouble": "NaN"}', "Infinity": '{"$numberDouble": "Infinity"}'}
MAX_CELL = 2000
SAFE_INT = 2 ** 53
RE_FLAGS = ((re.I, "i"), (re.M, "m"), (re.S, "s"), (re.X, "x"))


class _Reader:
    def __init__(self, text, what):
        self.s = text
        self.i = 0
        self.what = what

    def fail(self, msg):
        near = self.s[self.i:self.i + 20]
        raise Error("invalid", f"{self.what}: {msg}" + (f" near {near!r}" if near else " at the end"))

    def space(self):
        s = self.s
        while self.i < len(s):
            if s[self.i].isspace():
                self.i += 1
            elif s.startswith("//", self.i):
                end = s.find("\n", self.i)
                self.i = len(s) if end < 0 else end
            elif s.startswith("/*", self.i):
                end = s.find("*/", self.i + 2)
                self.i = len(s) if end < 0 else end + 2
            else:
                break

    def peek(self):
        self.space()
        return self.s[self.i] if self.i < len(self.s) else ""

    def expect(self, ch):
        if self.peek() != ch:
            self.fail(f"expected {ch!r}")
        self.i += 1

    def string(self):
        quote = self.s[self.i]
        self.i += 1
        out = []
        while self.i < len(self.s):
            c = self.s[self.i]
            if c == quote:
                self.i += 1
                return "".join(out)
            if c == "\\" and self.i + 1 < len(self.s):
                n = self.s[self.i + 1]
                if n == "u" and re.fullmatch(r"[0-9a-fA-F]{4}", self.s[self.i + 2:self.i + 6]):
                    out.append(chr(int(self.s[self.i + 2:self.i + 6], 16)))
                    self.i += 6
                    continue
                out.append({"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "0": "\0"}.get(n, n))
                self.i += 2
                continue
            out.append(c)
            self.i += 1
        self.fail("unterminated string")

    def value(self):
        c = self.peek()
        if c == "{":
            return self.obj()
        if c == "[":
            return self.arr()
        if c in "\"'":
            return json.dumps(self.string(), ensure_ascii=False)
        if c == "/":
            return self.regex()
        m = NUMBER.match(self.s, self.i)
        if m:
            self.i = m.end()
            text = m.group()
            if text.startswith((".", "-.")):
                text = text.replace(".", "0.", 1)
            if text.endswith("."):
                text += "0"
            return text
        m = IDENT.match(self.s, self.i)
        if not m:
            self.fail("expected a value")
        name = m.group()
        self.i = m.end()
        if name == "new":
            self.space()
            m = IDENT.match(self.s, self.i)
            if not m:
                self.fail("expected a constructor after new")
            name = m.group()
            self.i = m.end()
        if self.peek() == "(":
            return self.call(name)
        if name in LITERALS:
            return LITERALS[name]
        self.i = m.start()
        self.fail(f"unknown name {name!r} (quote text values)")

    def obj(self):
        self.expect("{")
        parts = []
        while True:
            c = self.peek()
            if c == "}":
                self.i += 1
                return "{" + ", ".join(parts) + "}"
            if c in "\"'":
                key = self.string()
            else:
                m = IDENT.match(self.s, self.i) or re.compile(r"\d+").match(self.s, self.i)
                if not m:
                    self.fail("expected a field name")
                key = m.group()
                self.i = m.end()
            self.expect(":")
            parts.append(json.dumps(key, ensure_ascii=False) + ": " + self.value())
            if self.peek() == ",":
                self.i += 1
            elif self.peek() != "}":
                self.fail("expected ',' or '}'")

    def arr(self):
        self.expect("[")
        parts = []
        while True:
            if self.peek() == "]":
                self.i += 1
                return "[" + ", ".join(parts) + "]"
            parts.append(self.value())
            if self.peek() == ",":
                self.i += 1
            elif self.peek() != "]":
                self.fail("expected ',' or ']'")

    def regex(self):
        start = self.i
        self.i += 1
        out = []
        in_class = False
        while self.i < len(self.s):
            c = self.s[self.i]
            if c == "\\" and self.i + 1 < len(self.s):
                out.append(self.s[self.i:self.i + 2])
                self.i += 2
                continue
            if c == "[":
                in_class = True
            elif c == "]":
                in_class = False
            elif c == "/" and not in_class:
                self.i += 1
                m = re.compile(r"[a-z]*").match(self.s, self.i)
                self.i = m.end()
                return json.dumps({"$regularExpression": {"pattern": "".join(out), "options": "".join(sorted(m.group()))}})
            elif c == "\n":
                break
            out.append(c)
            self.i += 1
        self.i = start
        self.fail("unterminated regular expression")

    def args(self):
        self.expect("(")
        out = []
        while self.peek() != ")":
            c = self.peek()
            if c in "\"'":
                out.append(self.string())
            else:
                m = NUMBER.match(self.s, self.i)
                if not m:
                    self.fail("constructor arguments must be text or numbers")
                out.append(m.group())
                self.i = m.end()
            if self.peek() == ",":
                self.i += 1
            elif self.peek() != ")":
                self.fail("expected ',' or ')'")
        self.i += 1
        return out

    def call(self, name):
        args = self.args()
        one = args[0] if args else None

        def need(n):
            if len(args) != n:
                self.fail(f"{name}() takes {n} argument{'s' if n != 1 else ''}")

        if name == "ObjectId":
            if not args:
                return json.dumps({"$oid": str(ObjectId())})
            need(1)
            if not ObjectId.is_valid(str(one)):
                self.fail(f"{one!r} is not a valid ObjectId")
            return json.dumps({"$oid": one})
        if name in ("ISODate", "Date"):
            if not args:
                now = datetime.datetime.now(datetime.timezone.utc)
                return json.dumps({"$date": now.isoformat(timespec="milliseconds").replace("+00:00", "Z")})
            need(1)
            if NUMBER.fullmatch(str(one)):
                return json.dumps({"$date": {"$numberLong": str(int(float(one)))}})
            text = str(one)
            if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
                text += "T00:00:00Z"
            elif not re.search(r"(Z|[+-]\d{2}:?\d{2})$", text):
                text += "Z"
            return json.dumps({"$date": text})
        if name in ("NumberLong", "Long"):
            need(1)
            return json.dumps({"$numberLong": str(int(float(one)))})
        if name in ("NumberInt", "Int32"):
            need(1)
            return json.dumps({"$numberInt": str(int(float(one)))})
        if name in ("NumberDecimal", "Decimal128"):
            need(1)
            return json.dumps({"$numberDecimal": str(one)})
        if name == "UUID":
            need(1)
            return json.dumps({"$uuid": str(one).replace("-", "")})
        if name == "Timestamp":
            need(2)
            return json.dumps({"$timestamp": {"t": int(args[0]), "i": int(args[1])}})
        if name == "BinData":
            need(2)
            return json.dumps({"$binary": {"base64": args[1], "subType": format(int(args[0]), "02x")}})
        self.fail(f"unknown constructor {name}()")


def parse(text, what="filter"):
    """Shell or Extended JSON text -> a Python/BSON value; empty text is {}."""
    text = str(text or "").strip()
    if not text:
        return {}
    r = _Reader(text, what)
    converted = r.value()
    if r.peek():
        r.fail("unexpected text after the value")
    try:
        return json_util.loads(converted)
    except (ValueError, TypeError, KeyError) as e:
        raise Error("invalid", f"{what}: {e}") from None


def dumps(value, indent=None):
    """Relaxed Extended JSON, the form documents are edited in."""
    return json_util.dumps(value, json_options=RELAXED_JSON_OPTIONS, indent=indent, ensure_ascii=False)


def ident(value):
    """Canonical Extended JSON for an _id, so it matches exactly when sent back."""
    return json_util.dumps(value, json_options=CANONICAL_JSON_OPTIONS)


def cell(value):
    """A top-level field as the grid shows it."""
    if value is None or isinstance(value, (bool, str)):
        return value
    if isinstance(value, int):  # Int64 included
        return int(value) if abs(value) < SAFE_INT else str(value)
    if isinstance(value, float):
        return value if math.isfinite(value) else ("NaN" if value != value else ("Infinity" if value > 0 else "-Infinity"))
    if isinstance(value, ObjectId):
        return f"ObjectId('{value}')"
    if isinstance(value, datetime.datetime):
        if value.tzinfo is not None:
            value = value.astimezone(datetime.timezone.utc).replace(tzinfo=None)
        return value.isoformat(timespec="milliseconds") + "Z"
    if isinstance(value, Decimal128):
        return str(value)
    if isinstance(value, Binary) and value.subtype not in (3, 4) or isinstance(value, bytes):
        return {"$t": "bytes", "v": base64.b64encode(bytes(value)).decode()}
    if isinstance(value, Regex):
        flags = value.flags if isinstance(value.flags, int) else 0
        return f"/{value.pattern}/" + "".join(ch for flag, ch in RE_FLAGS if flags & flag)
    text = dumps(value)
    return text if len(text) <= MAX_CELL else text[:MAX_CELL] + "…"

