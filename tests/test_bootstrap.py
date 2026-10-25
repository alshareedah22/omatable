import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
VERSION = re.search(r'__version__ = "([^"]+)"', open(os.path.join(ROOT, "omatable", "__init__.py")).read()).group(1)
CTL = os.path.join(ROOT, "tablectl")
NET = os.environ.get("OMATABLE_TEST_NET") == "1"


def run(env_extra, stdin=""):
    env = {**os.environ, "OMATABLE_NO_KEYRING": "1", **env_extra}
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


@unittest.skipUnless(NET, "set OMATABLE_TEST_NET=1 to download drivers")
class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_install_then_reuse(self):
        data = os.path.join(self.tmp, "data")
        env = {"OMATABLE_DATA": data, "OMATABLE_CONFIG": os.path.join(self.tmp, "cfg")}
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
        code, msgs, _ = run({"OMATABLE_DATA": data, "OMATABLE_LOCK": lock})
        self.assertEqual(code, 1)
        self.assertEqual(msgs[-1]["event"], "fatal")
        self.assertEqual(msgs[-1]["code"], "drivers")
        self.assertFalse(os.path.exists(os.path.join(data, "venv")))
        self.assertFalse(os.path.exists(os.path.join(data, "venv.new")))


if __name__ == "__main__":
    unittest.main()
