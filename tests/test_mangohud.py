import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("gamercenter_mangohud", os.path.join(HERE, "..", "bin", "gamercenter-mangohud"))
spec = importlib.util.spec_from_loader(loader.name, loader)
mh = importlib.util.module_from_spec(spec)
loader.exec_module(mh)


class MangoHudConfig(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = tmp.name
        self.path = os.path.join(self.home, "MangoHud", "MangoHud.conf")

    def read(self):
        with open(self.path) as f:
            return f.read()

    def write(self, text):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "w") as f:
            f.write(text)

    def run_cli(self, *args):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": self.home}), redirect_stdout(out):
            code = mh.main(list(args))
        return code, json.loads(out.getvalue())

    def test_apply_to_a_missing_file(self):
        code, status = self.run_cli("apply", "--position", "top-right", "--font-size", "20")
        self.assertEqual(code, 0)
        self.assertTrue(status["managed"])
        self.assertEqual(status["position"], "top-right")
        self.assertEqual(status["fontSize"], 20)
        self.assertFalse(status["graph"])
        text = self.read()
        self.assertTrue(text.startswith(mh.BEGIN))
        self.assertIn("fps\n", text)
        self.assertNotIn("frame_timing", text)

    def test_user_lines_survive_and_block_moves_to_the_end(self):
        self.write("# mine\ngpu_stats\n" + mh.BEGIN + "\nposition=top-left\n" + mh.END + "\ncpu_temp\n")
        self.run_cli("apply", "--position", "bottom-left", "--graph")
        text = self.read()
        self.assertEqual(text.count(mh.BEGIN), 1)
        self.assertTrue(text.startswith("# mine\ngpu_stats\ncpu_temp\n\n" + mh.BEGIN))
        self.assertTrue(text.rstrip("\n").endswith(mh.END))
        self.assertIn("frame_timing", text)
        self.assertNotIn("position=top-left", text)

    def test_remove_keeps_user_lines(self):
        self.write("gpu_stats\n")
        self.run_cli("apply")
        code, status = self.run_cli("remove")
        self.assertEqual(code, 0)
        self.assertFalse(status["managed"])
        self.assertEqual(self.read(), "gpu_stats\n")

    def test_remove_deletes_a_file_that_was_only_ours(self):
        self.run_cli("apply")
        self.run_cli("remove")
        self.assertFalse(os.path.exists(self.path))

    def test_remove_without_a_block_changes_nothing(self):
        self.write("fps_only\n\n\n")
        self.run_cli("remove")
        self.assertEqual(self.read(), "fps_only\n\n\n")

    def test_unterminated_block_keeps_the_rest(self):
        outside, block = mh.split_block("a\n" + mh.BEGIN + "\nposition=top-left\nuser_line\n")
        self.assertIsNone(block)
        self.assertEqual(outside, ["a", "position=top-left", "user_line"])

    def test_symlinked_config_is_written_through(self):
        real = os.path.join(self.home, "dotfiles", "MangoHud.conf")
        os.makedirs(os.path.dirname(real))
        with open(real, "w") as f:
            f.write("gpu_stats\n")
        os.makedirs(os.path.dirname(self.path))
        os.symlink(real, self.path)
        self.run_cli("apply")
        self.assertTrue(os.path.islink(self.path))
        with open(real) as f:
            self.assertIn(mh.BEGIN, f.read())

    def test_bad_arguments_are_refused(self):
        for args in (["apply", "--position", "$(reboot)"], ["apply", "--font-size", "999"], ["explode"]):
            with self.assertRaises(SystemExit) as raised, redirect_stderr(io.StringIO()):
                self.run_cli(*args)
            self.assertEqual(raised.exception.code, 2)
        self.assertFalse(os.path.exists(self.path))


if __name__ == "__main__":
    unittest.main()
