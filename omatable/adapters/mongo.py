"""MongoDB through pymongo.

Documents reach the window twice: as grid rows (top-level fields as columns)
and as relaxed Extended JSON text for the editor. Each _id also travels as
canonical Extended JSON, so an edit or delete matches exactly that document.
"""

import contextlib
import time

from .. import mongojs
from ..protocol import Error

MAX_DOCS = 1000
MAX_TIME_MS = 60000


class Mongo:
    engine = "mongodb"

    def __init__(self, conn):
        self.conn = conn
        self.database = conn.get("database") or ""
        self.client = None
        self._version = ""

    @contextlib.contextmanager
    def guard(self):
        try:
            yield
        except Error:
            raise
        except Exception as e:  # noqa: BLE001 - every driver error becomes an Error
            raise self.translate(e) from e

    def translate(self, exc):
        errors = getattr(self, "errors", None)
        msg = str(exc).strip() or type(exc).__name__
        if errors is None:
            return Error("query", msg)
        if isinstance(exc, errors.OperationFailure):
            details = exc.details or {}
            msg = details.get("errmsg") or msg
            if exc.code in (18, 11, 13) and "auth" in msg.lower():
                return Error("auth", msg)
            if exc.code == 50:
                return Error("query", f"stopped after {MAX_TIME_MS // 1000} s: {msg}")
            return Error("query", msg)
        if isinstance(exc, (errors.ServerSelectionTimeoutError, errors.ConnectionFailure)):
            return Error("network", msg.split(", Timeout:")[0].split(" (configured timeouts")[0])
        if isinstance(exc, errors.InvalidName):
            return Error("invalid", msg)
        if isinstance(exc, errors.PyMongoError):
            return Error("query", msg)
        if isinstance(exc, (TypeError, ValueError)):
            return Error("invalid", msg)
        return Error("query", msg)

    def connect(self):
        import pymongo
        from pymongo import errors
        self.errors = errors
        c = self.conn
        kwargs = {"host": c.get("host") or "127.0.0.1", "port": int(c.get("port") or 27017),
                  "directConnection": True, "serverSelectionTimeoutMS": 8000, "connectTimeoutMS": 10000,
                  "appname": "OmaTable", "tls": c.get("tls") == "require", "tz_aware": False}
        if c.get("user"):
            kwargs.update(username=c["user"], password=c.get("password") or "",
                          authSource=c.get("auth_source") or "admin")
        client = pymongo.MongoClient(**kwargs)
        with self.guard():
            try:
                info = client.server_info()
            except BaseException:
                client.close()
                raise
        self.close()
        self.client = client
        self._version = info.get("version", "")
        if not self.database or self.database == "admin":
            names = [d for d in self.databases() if d not in ("admin", "config", "local")]
            self.database = names[0] if names else (self.database or "test")

    def close(self):
        if self.client is not None:
            with contextlib.suppress(Exception):
                self.client.close()
            self.client = None

    def cancel(self):
        """Queries stop themselves after MAX_TIME_MS."""

    def forget(self):
        pass

    def version(self):
        return f"MongoDB {self._version}".strip()

    def databases(self):
        try:
            names = self.client.list_database_names()
        except Exception:  # noqa: BLE001 - users without listDatabases still see their own
            names = []
        if self.database and self.database not in names:
            names.append(self.database)
        return sorted(names)

    def use(self, database):
        name = str(database or "").strip()
        if not name or any(ch in name for ch in '/\\. "$\0'):
            raise Error("invalid", f"{database!r} is not a valid database name")
        self.database = name

    @property
    def db(self):
        return self.client[self.database]

    def coll(self, name):
        if not isinstance(name, str) or not name:
            raise Error("invalid", "pick a collection")
        return self.db[name]

    def tree(self):
        tables, views = [], []
        with self.guard():
            for c in self.db.list_collections(authorizedCollections=True, nameOnly=True):
                name = c.get("name", "")
                if name.startswith("system."):
                    continue
                (views if c.get("type") == "view" else tables).append(name)
        return [{"name": self.database, "tables": sorted(tables), "views": sorted(views)}]

    # documents ---------------------------------------------------------------
    @staticmethod
    def _doc(text, what):
        value = mongojs.parse(text, what)
        if not isinstance(value, dict):
            raise Error("invalid", f"{what} must be an object like {{field: value}}")
        return value

    def _page(self, docs, start, skip, limit):
        columns = []
        seen = set()
        for d in docs:
            for k in d:
                if k not in seen:
                    seen.add(k)
                    columns.append(k)
        if "_id" in seen:
            columns.remove("_id")
            columns.insert(0, "_id")
        return {"columns": columns,
                "rows": [[mongojs.cell(d.get(k)) for k in columns] for d in docs],
                "docs": [mongojs.dumps(d, indent=2) for d in docs],
                "ids": [mongojs.ident(d["_id"]) if "_id" in d else None for d in docs],
                "skip": skip, "limit": limit, "ms": round((time.monotonic() - start) * 1000)}

    def find(self, collection, filter="", sort="", projection="", skip=0, limit=100):  # noqa: A002
        query = self._doc(filter, "filter")
        order = self._doc(sort, "sort")
        fields = self._doc(projection, "projection") or None
        skip = max(0, int(skip or 0))
        limit = max(1, min(int(limit or 100), MAX_DOCS))
        start = time.monotonic()
        with self.guard():
            cur = self.coll(collection).find(query, fields, skip=skip, limit=limit,
                                             sort=list(order.items()) or None, max_time_ms=MAX_TIME_MS)
            docs = list(cur)
        return self._page(docs, start, skip, limit)

    def aggregate(self, collection, pipeline, limit=100):
        stages = mongojs.parse(pipeline, "pipeline") if str(pipeline or "").strip() else []
        if not isinstance(stages, list) or not all(isinstance(s, dict) for s in stages):
            raise Error("invalid", "pipeline must be a list of stages like [{$match: {...}}]")
        limit = max(1, min(int(limit or 100), MAX_DOCS))
        writes = stages and next(iter(stages[-1]), "") in ("$out", "$merge")
        if not writes:
            stages = stages + [{"$limit": limit}]
        start = time.monotonic()
        with self.guard():
            docs = list(self.coll(collection).aggregate(stages, maxTimeMS=MAX_TIME_MS))
        return self._page(docs, start, 0, limit)

    def count(self, collection, filter=""):  # noqa: A002
        query = self._doc(filter, "filter")
        with self.guard():
            c = self.coll(collection)
            if not query:
                with contextlib.suppress(Exception):
                    return {"count": c.estimated_document_count(maxTimeMS=10000), "estimated": True}
            return {"count": c.count_documents(query, maxTimeMS=MAX_TIME_MS), "estimated": False}

    def insert(self, collection, text):
        value = mongojs.parse(text, "document")
        docs = value if isinstance(value, list) else [value]
        if not docs or not all(isinstance(d, dict) for d in docs):
            raise Error("invalid", "insert an object, or a list of objects")
        with self.guard():
            c = self.coll(collection)
            ids = [c.insert_one(docs[0]).inserted_id] if len(docs) == 1 else c.insert_many(docs).inserted_ids
        return {"inserted": len(ids), "ids": [mongojs.ident(i) for i in ids]}

    def update(self, collection, id, text):  # noqa: A002 - protocol name
        key = mongojs.parse(id, "_id")
        doc = self._doc(text, "document")
        if "_id" in doc:
            if mongojs.ident(doc["_id"]) != mongojs.ident(key):
                raise Error("invalid", "the _id cannot change; insert a copy and delete this one instead")
            del doc["_id"]
        with self.guard():
            r = self.coll(collection).replace_one({"_id": key}, doc)
        if r.matched_count == 0:
            raise Error("notfound", "the document no longer exists; reload")
        return {"modified": r.modified_count}

    def delete(self, collection, ids):
        keys = [mongojs.parse(i, "_id") for i in ids or () if i]
        if not keys:
            return {"deleted": 0}
        with self.guard():
            return {"deleted": self.coll(collection).delete_many({"_id": {"$in": keys}}).deleted_count}

    # indexes and collections ---------------------------------------------------
    def indexes(self, collection):
        out = []
        with self.guard():
            for ix in self.coll(collection).list_indexes():
                out.append({"name": ix.get("name"), "keys": mongojs.dumps(ix.get("key", {})),
                            "unique": bool(ix.get("unique")), "sparse": bool(ix.get("sparse")),
                            "ttl": ix.get("expireAfterSeconds"),
                            "partial": mongojs.dumps(ix["partialFilterExpression"]) if "partialFilterExpression" in ix else None})
        return out

    def create_index(self, collection, keys, unique=False, name=""):
        spec = self._doc(keys, "index keys")
        if not spec:
            raise Error("invalid", "an index needs at least one field, like {name: 1}")
        opts = {"unique": bool(unique)}
        if name:
            opts["name"] = str(name)
        with self.guard():
            return {"name": self.coll(collection).create_index(list(spec.items()), **opts)}

    def drop_index(self, collection, name):
        if name == "_id_":
            raise Error("invalid", "the _id index cannot be dropped")
        with self.guard():
            self.coll(collection).drop_index(name)
        return {"ok": True}

    def create_collection(self, name):
        name = str(name or "").strip()
        if not name or "$" in name or "\0" in name or name.startswith("system."):
            raise Error("invalid", f"{name!r} is not a valid collection name")
        with self.guard():
            self.db.create_collection(name)
        return {"ok": True}

    def drop_collection(self, name):
        with self.guard():
            self.coll(name)
            self.db.drop_collection(name)
        return {"ok": True}

    def command(self, text):
        cmd = self._doc(text, "command")
        if not cmd:
            raise Error("invalid", "type a command like {ping: 1}")
        start = time.monotonic()
        with self.guard():
            out = self.db.command(cmd)
        return {"reply": mongojs.dumps(out, indent=2), "ms": round((time.monotonic() - start) * 1000)}
