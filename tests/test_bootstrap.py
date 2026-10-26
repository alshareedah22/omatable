import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
VERSION = re.search(r'__version__ = "([^"]+)"', open(os.path.join(ROOT, "omatableplus", "__init__.py")).read()).group(1)
CTL = os.path.join(ROOT, "tablectl")
NET = os.environ.get("OMATABLEPLUS_TEST_NET") == "1"


def run(env_extra, stdin=""):
    env = {**os.environ, "OMATABLEPLUS_NO_KEYRING": "1", **env_extra}
    r = subprocess.run([CTL], input=stdin, capture_output=True, text=True, env=env, timeout=600)
    return r.returncode, [json.loads(l) for l in r.stdout.splitlines() if l.startswith("{")], r.stderr


class LockTest(unittest.TestCase):
    def test_every_requirement_is_pinned_with_hashes(self):
        with open(os.path.join(ROOT, "requirements.lock")) as f:
            text = f.read()
        reqs = re.findall(r"^([A-Za-z0-9_.-]+)==([^ ]+) \\\n((?:    --hash=sha256:[0-9a-f]{64}(?: \\\n|\n))+)", text, re.M)
        names = {r[0] for r in reqs}
        self.assertEqual(names, {"psycopg", "psycopg-binary", "PyMySQL", "redis", "pymongo", "dnspython",
                                 "typing-extensions"})


class MigrateTest(unittest.TestCase):
    """What OmaTable (the name before 1.6) left behind moves to the OmaTablePlus paths."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cfg, self.data = os.path.join(self.tmp, "config"), os.path.join(self.tmp, "data")

    def migrate(self):
        import importlib.machinery
        import importlib.util
        from unittest import mock
        env = {"XDG_CONFIG_HOME": self.cfg, "XDG_DATA_HOME": self.data}
        with mock.patch.dict(os.environ, env):
            os.environ.pop("OMATABLEPLUS_CONFIG", None)
            os.environ.pop("OMATABLEPLUS_DATA", None)
            loader = importlib.machinery.SourceFileLoader("tablectl_under_test", CTL)
            spec = importlib.util.spec_from_loader(loader.name, loader)
            mod = importlib.util.module_from_spec(spec)
            loader.exec_module(mod)
            mod.migrate()

    def make(self, *parts, text=""):
        path = os.path.join(self.tmp, *parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def test_moves_settings_and_drops_the_old_drivers(self):
        self.make("config", "omatable", "connections.json", text='[{"name": "x"}]')
        self.make("config", "omatable", "history.jsonl")
        self.make("data", "omatable", "venv", ".omatable-stamp")
        self.migrate()
        with open(os.path.join(self.cfg, "omatableplus", "connections.json")) as f:
            self.assertEqual(f.read(), '[{"name": "x"}]')
        self.assertTrue(os.path.exists(os.path.join(self.cfg, "omatableplus", "history.jsonl")))
        self.assertFalse(os.path.exists(os.path.join(self.cfg, "omatable")))
        self.assertFalse(os.path.exists(os.path.join(self.data, "omatable")))

    def test_leaves_alone_what_is_not_ours_or_already_moved(self):
        self.make("config", "omatableplus", "connections.json", text="[]")
        self.make("config", "omatable", "connections.json", text='[{"name": "old"}]')
        self.make("data", "omatable", "venv", "something-else")          # no stamp: not our venv
        self.migrate()
        with open(os.path.join(self.cfg, "omatableplus", "connections.json")) as f:
            self.assertEqual(f.read(), "[]")
        self.assertTrue(os.path.exists(os.path.join(self.cfg, "omatable", "connections.json")))
        self.assertTrue(os.path.exists(os.path.join(self.data, "omatable", "venv", "something-else")))


@unittest.skipUnless(NET, "set OMATABLEPLUS_TEST_NET=1 to download drivers")
class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_install_then_reuse(self):
        data = os.path.join(self.tmp, "data")
        env = {"OMATABLEPLUS_DATA": data, "OMATABLEPLUS_CONFIG": os.path.join(self.tmp, "cfg")}
        code, msgs, err = run(env, json.dumps({"id": 1, "method": "app.version"}) + "\n")
        self.assertEqual(code, 0, err)
        self.assertIn("progress", [m.get("event") for m in msgs])
        self.assertEqual(msgs[-1], {"id": 1, "result": {"version": VERSION}})
        py = os.path.join(data, "venv", "bin", "python")
        imports = "import psycopg, pymysql, redis, pymongo; print('ok')"
        self.assertEqual(subprocess.run([py, "-c", imports], capture_output=True, text=True).stdout.strip(), "ok")
        code, msgs, _ = run(env, "")
        self.assertEqual(code, 0)
        self.assertNotIn("progress", [m.get("event") for m in msgs])
        self.assertEqual(msgs[0]["event"], "ready")

    def test_tampered_lock_refuses_and_leaves_nothing(self):
        with open(os.path.join(ROOT, "requirements.lock")) as f:
            text = f.read()
        bad = re.sub(r"(PyMySQL==[^\n]+\n    --hash=sha256:)[0-9a-f]{64}", r"\g<1>" + "0" * 64, text)
        lock = os.path.join(self.tmp, "bad.lock")
        with open(lock, "w") as f:
            f.write(bad)
        data = os.path.join(self.tmp, "data")
        code, msgs, _ = run({"OMATABLEPLUS_DATA": data, "OMATABLEPLUS_LOCK": lock})
        self.assertEqual(code, 1)
        self.assertEqual(msgs[-1]["event"], "fatal")
        self.assertEqual(msgs[-1]["code"], "drivers")
        self.assertFalse(os.path.exists(os.path.join(data, "venv")))
        self.assertFalse(os.path.exists(os.path.join(data, "venv.new")))


if __name__ == "__main__":
    unittest.main()
