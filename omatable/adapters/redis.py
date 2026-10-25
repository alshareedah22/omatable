"""Redis and Valkey through redis-py.

Keys and values travel as text when they are UTF-8 and as
{"$t": "bytes", "v": base64} otherwise, and come back the same way, so binary
keys survive a round trip. Collections show their first LIMIT items.
"""

import base64
import contextlib
import shlex
import time

from ..protocol import Error

LIMIT = 1000
STRING_LIMIT = 1024 * 1024
TYPES = ("string", "hash", "list", "set", "zset", "stream")
# Commands that block the connection or change it under the browser.
REFUSED = {"SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "SYNC", "PSYNC", "WAIT", "WAITAOF",
           "BLPOP", "BRPOP", "BLMOVE", "BRPOPLPUSH", "BLMPOP", "BZPOPMIN", "BZPOPMAX", "BZMPOP",
           "MULTI", "EXEC", "DISCARD", "WATCH", "UNWATCH", "CLIENT", "RESET", "QUIT", "HELLO", "AUTH"}
# Compare the item the window saw before changing a list (indexes move).
LIST_SET = """
if redis.call('LINDEX', KEYS[1], ARGV[1]) ~= ARGV[2] then return 0 end
redis.call('LSET', KEYS[1], ARGV[1], ARGV[3])
return 1
"""
LIST_DELETE = """
if redis.call('LINDEX', KEYS[1], ARGV[1]) ~= ARGV[2] then return 0 end
redis.call('LSET', KEYS[1], ARGV[1], ARGV[3])
redis.call('LREM', KEYS[1], 1, ARGV[3])
return 1
"""
TOMBSTONE = b"\x00omatable-deleted\x00"


def wire(data):
    """bytes from Redis -> what the window gets."""
    if isinstance(data, (bytes, bytearray)):
        try:
            return bytes(data).decode("utf-8")
        except UnicodeDecodeError:
            return {"$t": "bytes", "v": base64.b64encode(bytes(data)).decode()}
    return data


def raw(value, what="value"):
    """What the window sent -> bytes for Redis."""
    if isinstance(value, dict) and value.get("$t") == "bytes":
        try:
            return base64.b64decode(value.get("v") or "", validate=True)
        except ValueError as e:
            raise Error("invalid", f"{what} is not valid base64") from e
    if isinstance(value, bool) or value is None or isinstance(value, (dict, list)):
        raise Error("invalid", f"{what} must be text")
    return str(value).encode("utf-8")


def reply(value):
    """A command reply as JSON."""
    if isinstance(value, (list, tuple, set)):
        return [reply(v) for v in value]
    if isinstance(value, dict):
        return [reply(x) for kv in value.items() for x in kv]
    if isinstance(value, float):  # RESP3 doubles; JSON would make 120.0 look like an integer
        return {"$t": "double", "v": repr(value) if value == value and abs(value) != float("inf") else str(value)}
    return wire(value)


def to_score(value):
    try:
        out = float(value)
    except (TypeError, ValueError):
        raise Error("invalid", f"score {value!r} is not a number") from None
    if out != out:
        raise Error("invalid", "score cannot be NaN")
    return out


class Redis:
    engine = "redis"

    def __init__(self, conn):
        self.conn = conn
        self.database = str(conn.get("database") or "0")
        self.client = None
        self.product = "Redis"

    def guard(self):
        return _Guard(self)

    def _client(self, db):
        import redis
        self.redis = redis
        c = self.conn
        return redis.Redis(host=c.get("host") or "127.0.0.1", port=int(c.get("port") or 6379),
                           username=c.get("user") or None, password=c.get("password") or None,
                           db=db, ssl=c.get("tls") == "require", socket_timeout=15,
                           socket_connect_timeout=10, client_name="OmaTable", decode_responses=False)

    def connect(self):
        self._open(self.database)

    def _open(self, database):
        try:
            db = int(database)
        except (TypeError, ValueError):
            raise Error("invalid", f"database {database!r} must be a number") from None
        client = self._client(db)
        with self.guard():
            try:
                client.ping()
                info = client.info("server")
            except BaseException:
                client.close()
                raise
        self.close()
        self.client = client
        self.database = str(db)
        self.product = "Valkey" if info.get("valkey_version") or info.get("server_name") == "valkey" else "Redis"
        self._version = str(info.get("valkey_version") or info.get("redis_version") or "")

    def close(self):
        if self.client is not None:
            with contextlib.suppress(Exception):
                self.client.close()
            self.client = None

    def cancel(self):
        """Redis commands are short; nothing to stop."""

    def forget(self):
        pass

    def version(self):
        return f"{self.product} {self._version}".strip()

    def databases(self):
        n = 16
        with contextlib.suppress(Exception):
            got = self.client.config_get("databases")
            n = int(got.get(b"databases") or got.get("databases") or 16)
        return [str(i) for i in range(max(1, n))]

    def keyspace(self):
        """Key counts per database, from INFO keyspace."""
        with self.guard():
            info = self.client.info("keyspace")
        return {k[2:]: v.get("keys", 0) for k, v in info.items() if k.startswith("db") and isinstance(v, dict)}

    def use(self, database):
        if str(database) not in self.databases():
            raise Error("invalid", f"database {database!r} does not exist")
        self._open(database)

    def tree(self):
        raise Error("invalid", "Redis has no tables")

    # keys -----------------------------------------------------------------
    def scan(self, pattern="*", cursor="0", count=500, type=None):  # noqa: A002 - protocol name
        if type and type not in TYPES:
            raise Error("invalid", f"type must be one of {', '.join(TYPES)}")
        count = max(1, min(int(count), 5000))
        try:
            cur = int(cursor or 0)
        except ValueError:
            raise Error("invalid", "cursor must be a number") from None
        keys = []
        deadline = time.monotonic() + 3
        with self.guard():
            while True:
                cur, batch = self.client.scan(cur, match=raw(pattern or "*", "pattern"),
                                              count=max(count - len(keys), 100), _type=type or None)
                keys += batch
                if cur == 0 or len(keys) >= count or time.monotonic() > deadline:
                    break
            pipe = self.client.pipeline(transaction=False)
            for k in keys:
                pipe.type(k)
                pipe.ttl(k)
            info = pipe.execute()
            total = self.client.dbsize()
        out = []
        for i, k in enumerate(keys):
            kind = wire(info[2 * i])
            if kind == "none":
                continue  # gone since the scan
            out.append({"key": wire(k), "type": kind, "ttl": info[2 * i + 1]})
        return {"keys": out, "cursor": str(cur), "total": total}

    def _type(self, k):
        kind = wire(self.client.type(k))
        if kind == "none":
            raise Error("notfound", "the key no longer exists")
        return kind

    def get(self, key, limit=LIMIT):
        k = raw(key, "key")
        limit = max(1, min(int(limit), LIMIT))
        r = self.client
        with self.guard():
            kind = self._type(k)
            ttl = r.ttl(k)
            truncated, editable = False, True
            if kind == "string":
                size = r.strlen(k)
                truncated = size > STRING_LIMIT
                data = r.getrange(k, 0, STRING_LIMIT - 1) if truncated else r.get(k)
                value, editable = wire(data), not truncated
            elif kind == "hash":
                size = r.hlen(k)
                value = []
                for f, v in r.hscan_iter(k, count=500):
                    value.append([wire(f), wire(v)])
                    if len(value) >= limit:
                        break
            elif kind == "list":
                size = r.llen(k)
                value = [wire(v) for v in r.lrange(k, 0, limit - 1)]
            elif kind == "set":
                size = r.scard(k)
                members = []
                for m in r.sscan_iter(k, count=500):
                    members.append(m)
                    if len(members) >= limit:
                        break
                value = [wire(m) for m in sorted(members)]
            elif kind == "zset":
                size = r.zcard(k)
                value = [[wire(m), s if s == s and abs(s) != float("inf") else str(s)] for m, s in r.zrange(k, 0, limit - 1, withscores=True)]
            elif kind == "stream":
                size = r.xlen(k)
                value = [{"id": wire(i), "fields": [[wire(f), wire(v)] for f, v in fields.items()]}
                         for i, fields in r.xrange(k, count=limit)]
            else:
                size, value, editable = 0, None, False
        if kind != "string":
            truncated = size > len(value or ())
        return {"key": key, "type": kind, "ttl": ttl, "size": size, "value": value,
                "truncated": truncated, "editable": editable}

    def create(self, key, type, value, ttl=None):  # noqa: A002
        k = raw(key, "key")
        if not k:
            raise Error("invalid", "the key name is empty")
        if type not in TYPES:
            raise Error("invalid", f"type must be one of {', '.join(TYPES)}")
        if type != "string" and not value:
            raise Error("invalid", f"a new {type} needs at least one item")
        if type in ("hash", "zset", "stream") and any(not isinstance(p, (list, tuple)) or len(p) != 2 for p in value):
            raise Error("invalid", f"{type} items are [field, value] pairs")
        with self.guard():
            if self.client.exists(k):
                raise Error("exists", f"the key {wire(k)!r} already exists")
            pipe = self.client.pipeline(transaction=True)
            if type == "string":
                pipe.set(k, raw(value))
            elif type == "hash":
                pipe.hset(k, mapping={raw(f, "field"): raw(v) for f, v in value})
            elif type == "list":
                pipe.rpush(k, *[raw(v) for v in value])
            elif type == "set":
                pipe.sadd(k, *[raw(v) for v in value])
            elif type == "zset":
                pipe.zadd(k, {raw(m, "member"): to_score(s) for m, s in value})
            else:
                pipe.xadd(k, {raw(f, "field"): raw(v) for f, v in value})
            if ttl not in (None, "") and int(ttl) > 0:
                pipe.expire(k, int(ttl))
            pipe.execute()
        return {"ok": True}

    def edit(self, key, type, action, item=None, value=None, score=None, old=None):  # noqa: A002, C901
        k = raw(key, "key")
        r = self.client
        with self.guard():
            kind = self._type(k)
            if kind != type:
                raise Error("conflict", f"the key is now a {kind}, not a {type}; reload it")
            if type == "string" and action == "set":
                r.set(k, raw(value), keepttl=True)
            elif type == "hash" and action == "set":
                field = raw(item, "field")
                if old is not None and raw(old, "field") != field:
                    prev = raw(old, "field")
                    if not r.hexists(k, prev):
                        raise Error("conflict", f"the field {wire(prev)!r} no longer exists")
                    if r.hexists(k, field):
                        raise Error("exists", f"the field {wire(field)!r} already exists")
                    r.pipeline(transaction=True).hset(k, field, raw(value)).hdel(k, prev).execute()
                else:
                    r.hset(k, field, raw(value))
            elif type == "hash" and action == "delete":
                r.hdel(k, raw(item, "field"))
            elif type == "list" and action in ("set", "delete"):
                if old is None:
                    raise Error("invalid", "a list edit needs the item's current value")
                script = LIST_SET if action == "set" else LIST_DELETE
                args = [int(item), raw(old), raw(value) if action == "set" else TOMBSTONE]
                if not r.eval(script, 1, k, *args):
                    raise Error("conflict", "the list changed since it was loaded; reload it")
            elif type == "list" and action == "push":
                r.rpush(k, raw(value))
            elif type == "set" and action == "add":
                r.sadd(k, raw(value))
            elif type == "set" and action == "set":
                if not r.sismember(k, raw(old)):
                    raise Error("conflict", "the member no longer exists; reload it")
                r.pipeline(transaction=True).srem(k, raw(old)).sadd(k, raw(value)).execute()
            elif type == "set" and action == "delete":
                r.srem(k, raw(item))
            elif type == "zset" and action == "set":
                member = raw(item, "member")
                new_score = to_score(score)
                if old is not None and raw(old, "member") != member:
                    prev = raw(old, "member")
                    if r.zscore(k, prev) is None:
                        raise Error("conflict", f"the member {wire(prev)!r} no longer exists")
                    r.pipeline(transaction=True).zrem(k, prev).zadd(k, {member: new_score}).execute()
                else:
                    r.zadd(k, {member: new_score})
            elif type == "zset" and action == "delete":
                r.zrem(k, raw(item, "member"))
            elif type == "stream" and action == "add":
                if not value or any(not isinstance(p, (list, tuple)) or len(p) != 2 for p in value):
                    raise Error("invalid", "a stream entry needs [field, value] pairs")
                r.xadd(k, {raw(f, "field"): raw(v) for f, v in value})
            elif type == "stream" and action == "delete":
                r.xdel(k, raw(item, "id"))
            else:
                raise Error("invalid", f"cannot {action} a {type} item")
        return {"ok": True}

    def delete(self, keys):
        with self.guard():
            return {"deleted": self.client.delete(*[raw(k, "key") for k in keys]) if keys else 0}

    def rename(self, key, new):
        k, n = raw(key, "key"), raw(new, "key")
        if not n:
            raise Error("invalid", "the new key name is empty")
        with self.guard():
            self._type(k)
            if not self.client.renamenx(k, n):
                raise Error("exists", f"the key {wire(n)!r} already exists")
        return {"ok": True}

    def expire(self, key, ttl):
        k = raw(key, "key")
        with self.guard():
            self._type(k)
            if ttl is None or ttl == "" or int(ttl) < 0:
                self.client.persist(k)
            else:
                self.client.expire(k, int(ttl))
            return {"ttl": self.client.ttl(k)}

    def _raw_command(self, args):
        # Straight off the wire: execute_command would turn "OK" into True.
        pool = self.client.connection_pool
        conn = pool.get_connection()
        try:
            conn.send_command(*args)
            return conn.read_response()
        except BaseException:
            conn.disconnect()
            raise
        finally:
            pool.release(conn)

    def command(self, text):
        try:
            args = shlex.split(str(text or ""))
        except ValueError as e:
            raise Error("invalid", f"cannot read the command: {e}") from None
        if not args:
            raise Error("invalid", "type a command")
        name = args[0].upper()
        if name in REFUSED:
            raise Error("invalid", f"{name} is not available in the console")
        start = time.monotonic()
        if name == "SELECT":
            if len(args) != 2:
                raise Error("invalid", "SELECT takes one database number")
            self.use(args[1])
            out = "OK"
        else:
            with self.guard():
                out = self._raw_command(args)
        return {"reply": reply(out), "database": self.database, "ms": round((time.monotonic() - start) * 1000)}


class _Guard:
    """Driver errors -> Error with a code the window understands."""

    def __init__(self, adapter):
        self.a = adapter

    def __enter__(self):
        return self

    def __exit__(self, kind, exc, tb):
        if exc is None or isinstance(exc, Error) or not isinstance(exc, Exception):
            return False
        redis = getattr(self.a, "redis", None)
        msg = str(exc).strip() or type(exc).__name__
        if redis is not None:
            low = msg.lower()
            if isinstance(exc, redis.AuthenticationError) or "wrongpass" in low or "noauth" in low \
                    or "invalid username-password" in low:
                raise Error("auth", msg) from exc
            if isinstance(exc, (redis.ConnectionError, redis.TimeoutError)):
                raise Error("network", msg) from exc
            if isinstance(exc, redis.ResponseError):
                raise Error("query", msg) from exc
        raise Error("query", msg) from exc
