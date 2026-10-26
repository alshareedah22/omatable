"""Runs the editor's autocomplete checks (tests/js/complete.test.js) with node, when node is installed."""

import os
import shutil
import subprocess
import unittest

HERE = os.path.dirname(__file__)
NODE = shutil.which("node")


@unittest.skipUnless(NODE, "node is not installed")
class CompleteTest(unittest.TestCase):
    def test_complete_js(self):
        out = subprocess.run([NODE, os.path.join(HERE, "js", "complete.test.js")], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), "ok")


if __name__ == "__main__":
    unittest.main()
