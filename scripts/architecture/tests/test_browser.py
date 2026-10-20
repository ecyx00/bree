"""check_svg finds a browser without /Applications/Google Chrome.app. Run: python3 -I -m unittest discover -s tests -p test_browser.py (from scripts/architecture)"""
import os, subprocess, sys, unittest

D = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, D)
import check_svg


class T(unittest.TestCase):
    def test_env_wins(self):
        os.environ[check_svg.ENV] = sys.executable
        try:
            self.assertEqual(check_svg.find_browser(), sys.executable)
        finally:
            del os.environ[check_svg.ENV]

    def test_bad_env_names_var(self):
        env = dict(os.environ, **{check_svg.ENV: "/nonexistent"})
        r = subprocess.run([sys.executable, "-I", os.path.join(D, "check_svg.py"), "/nonexistent.html"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn(check_svg.ENV, r.stderr)

    def test_env_browser_is_the_one_launched(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            stub = os.path.join(td, "stub")
            open(stub, "w").write(f"#!/bin/sh\necho launched > {td}/hit\n")
            os.chmod(stub, 0o755)
            open(os.path.join(td, "current.html"), "w").write("<html><body></body></html>")
            open(os.path.join(td, "current.architecture.json"), "w").write('{"boards": [], "nodes": [], "edges": []}')
            env = dict(os.environ, **{check_svg.ENV: stub})
            subprocess.run([sys.executable, "-I", os.path.join(D, "check_svg.py"), os.path.join(td, "current.html")], env=env, capture_output=True, text=True)
            self.assertTrue(os.path.exists(os.path.join(td, "hit")), "the BREE_ARCHITECTURE_BROWSER executable was never launched")

    def test_found_without_env(self):
        env = {k: v for k, v in os.environ.items() if k != check_svg.ENV}
        r = subprocess.run([sys.executable, "-I", "-c", "import sys;sys.path.insert(0,sys.argv[1]);import check_svg;p=check_svg.find_browser();print(p);sys.exit(p is None)", D], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
