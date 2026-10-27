import json
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omatableplus import history, tunnel
from omatableplus.protocol import Error
from omatableplus.store import Store


def ssh(**kw):
    return {"host": "db.example.com", "user": "deploy", "auth": "agent", **kw}


class TunnelValidationTest(unittest.TestCase):
    def test_accepts_normal_targets(self):
        for host in ("db.example.com", "localhost", "10.0.0.5", "::1", "2001:db8::1", "fe80::1%eth0", "[::1]", "my-host_1"):
            tunnel.check_target(ssh(host=host))
        for user in ("deploy", "john.doe", "svc_db", "a-b", "user@corp", "_x"):
            tunnel.check_target(ssh(user=user))
        tunnel.check_target(ssh(auth="key", key_path="/home/me/.ssh/id_ed25519"))

    def test_rejects_bad_hosts(self):
        for host in ("", "-oProxyCommand=x", "-h", "a b", "a\nb", "a\x00b", "host;rm", "a\tb", "$(id)"):
            with self.assertRaises(Error, msg=repr(host)):
                tunnel.check_target(ssh(host=host))

    def test_rejects_bad_users(self):
        for user in ("", "-oProxyCommand=x", "-l", "a b", "a\nb", "a\x1bb", "x;y"):
            with self.assertRaises(Error, msg=repr(user)):
                tunnel.check_target(ssh(user=user))

    def test_rejects_bad_keys(self):
        for key in ("", "-oProxyCommand=x", "-F/etc/passwd", "a\nb"):
            with self.assertRaises(Error, msg=repr(key)):
                tunnel.check_target(ssh(auth="key", key_path=key))

    def test_key_not_checked_for_other_auth(self):
        tunnel.check_target(ssh(auth="agent", key_path="-bad"))

    def test_command_uses_double_dash_and_absolute_key(self):
        argv = tunnel.Tunnel(ssh(auth="key", key_path="rel/key"), "127.0.0.1", 5432).command(1234)
        self.assertEqual(argv[-2:], ["--", "deploy@db.example.com"])
        self.assertTrue(os.path.isabs(argv[argv.index("-i") + 1]))

    def test_start_rejects_before_running_ssh(self):
        t = tunnel.Tunnel(ssh(host="-oProxyCommand=touch /tmp/x"), "127.0.0.1", 5432)
        with mock.patch.object(tunnel.subprocess, "Popen") as popen:
            with self.assertRaises(Error) as cm:
                t.start()
        popen.assert_not_called()
        self.assertIn("invalid SSH host", cm.exception.args[-1] if cm.exception.args else str(cm.exception))


class AtomicWriteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self.tmp.name, "cfg")
        self.addCleanup(self.tmp.cleanup)

    def test_store_write_private_and_no_leftovers(self):
        store = Store(self.dir, keyring=mock.Mock())
        store._write([{"id": "a"}])
        store._write([{"id": "b"}])
        self.assertEqual(json.load(open(store.path)), [{"id": "b"}])
        self.assertEqual(stat.S_IMODE(os.stat(store.path).st_mode), 0o600)
        self.assertEqual(os.listdir(self.dir), ["connections.json"])

    def test_store_write_failure_keeps_old_file_and_cleans_up(self):
        store = Store(self.dir, keyring=mock.Mock())
        store._write([{"id": "a"}])
        with self.assertRaises(TypeError):
            store._write([{"bad": object()}])
        self.assertEqual(json.load(open(store.path)), [{"id": "a"}])
        self.assertEqual(os.listdir(self.dir), ["connections.json"])

    def test_history_rewrite_and_saved_private(self):
        h = history.History(self.dir)
        h.add({"conn": "c", "sql": "select 1"})
        h._rewrite([{"id": "x"}])
        self.assertEqual(stat.S_IMODE(os.stat(h.path).st_mode), 0o600)
        s = history.Saved(self.dir)
        s.save("q", "select 1")
        self.assertEqual(stat.S_IMODE(os.stat(s.path).st_mode), 0o600)
        self.assertEqual(sorted(os.listdir(self.dir)), ["history.jsonl", "queries.json"])

    def test_history_failure_cleans_up(self):
        os.makedirs(self.dir)
        path = os.path.join(self.dir, "f.json")
        with open(path, "w") as f:
            f.write("old")

        def boom(f):
            f.write("partial")
            raise RuntimeError("x")
        with self.assertRaises(RuntimeError):
            history._atomic_write(path, boom)
        self.assertEqual(open(path).read(), "old")
        self.assertEqual(os.listdir(self.dir), ["f.json"])


if __name__ == "__main__":
    unittest.main()
