"""Exercise the VM night-light state transitions across the Hyprland IPC boundary."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


FILES = Path(__file__).resolve().parents[1] / "try-omarchy/files"
USR = FILES / "usr"


class NightlightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.helper = self.bin / "omarchy-native-nightlight"
        shutil.copy2(USR / "bin/omarchy-native-nightlight", self.helper)
        self.shader = self.root / "share/try-omarchy/nightlight.frag"
        self.shader.parent.mkdir(parents=True)
        shutil.copy2(USR / "share/try-omarchy/nightlight.frag", self.shader)
        self.state = self.root / "state.json"
        self.set_shader("[[EMPTY]]")
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        XDG_RUNTIME_DIR=str(self.root), HYPRLAND_INSTANCE_SIGNATURE="test-session",
                        NIGHTLIGHT_TEST_STATE=str(self.state))
        fake = self.bin / "hyprctl"
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
path = pathlib.Path(os.environ["NIGHTLIGHT_TEST_STATE"])
args = sys.argv[1:]
mode = os.environ.get("NIGHTLIGHT_TEST_MODE")
if mode == "unavailable": sys.exit(1)
if args[0] == "getoption":
    print("not json" if mode == "malformed" else "[]" if mode == "array" else path.read_text())
elif args[0] == "eval":
    if mode == "reject":
        print("error: rejected setting")
        sys.exit(0)
    time.sleep(0.02)
    prefix = "hl.config({ decoration = { screen_shader = "
    value = json.loads(args[1][len(prefix):-len(" } })")])
    path.write_text(json.dumps({"str": value}))
    print("ok")
else: sys.exit(2)
''')
        fake.chmod(0o755)
        for name in ("omarchy-shell", "notify-send"):
            command = self.bin / name
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o755)

    def set_shader(self, value):
        self.state.write_text(json.dumps({"str": value}))

    def run_helper(self, *args, code=0, mode=""):
        result = subprocess.run([str(self.helper), *args], capture_output=True, text=True,
                                env=dict(self.env, NIGHTLIGHT_TEST_MODE=mode))
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def status(self):
        return json.loads(self.run_helper("--status").stdout)

    def test_toggle_on_and_off_tracks_the_actual_renderer(self):
        self.assertEqual(self.status(), {"enabled": False, "temperature": 6500})
        self.run_helper()
        self.assertEqual(self.status(), {"enabled": True, "temperature": 4000})
        self.run_helper()
        self.assertEqual(self.status(), {"enabled": False, "temperature": 6500})

    def test_explicit_shell_requests_are_idempotent(self):
        for temperature, enabled in (("4000", True), ("4000", True), ("6500", False), ("6500", False)):
            self.run_helper("--temperature", temperature)
            self.assertEqual(self.status()["enabled"], enabled)

    def test_custom_shader_is_preserved_when_enabling_is_refused(self):
        self.set_shader("/home/user/custom.frag")
        result = self.run_helper(code=1)
        self.assertIn("custom screen shader", result.stderr)
        self.assertEqual(json.loads(self.state.read_text())["str"], "/home/user/custom.frag")

    def test_disable_does_not_clear_a_later_user_override(self):
        self.run_helper("--temperature", "4000")
        self.set_shader("/home/user/custom.frag")
        self.run_helper("--temperature", "6500")
        self.assertEqual(json.loads(self.state.read_text())["str"], "/home/user/custom.frag")

    def test_config_reload_is_not_reported_as_still_enabled(self):
        self.run_helper()
        self.set_shader("[[EMPTY]]")
        self.assertFalse(self.status()["enabled"])

    def test_missing_shader_does_not_change_the_renderer(self):
        self.shader.unlink()
        self.run_helper(code=1)
        self.assertFalse(self.status()["enabled"])

    def test_unavailable_or_malformed_ipc_does_not_report_success(self):
        for mode in ("unavailable", "malformed", "array"):
            with self.subTest(mode=mode):
                self.run_helper(code=1, mode=mode)
                state = json.loads(self.run_helper("--status", code=1, mode=mode).stdout)
                self.assertEqual(state, {"enabled": False, "temperature": None})

    def test_rejected_setting_is_not_reported_as_enabled(self):
        self.run_helper(code=1, mode="reject")
        self.assertFalse(self.status()["enabled"])

    def test_invalid_temperature_does_not_change_the_renderer(self):
        for args in (("--temperature", "0"), ("--temperature", "4000;exit"), ("--temperature",), ("--unknown",)):
            self.run_helper(*args, code=2)
        self.assertFalse(self.status()["enabled"])

    def test_two_concurrent_toggles_return_to_off(self):
        first = subprocess.Popen([str(self.helper)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = subprocess.Popen([str(self.helper)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for process in (first, second):
            _, error = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, error)
        self.assertFalse(self.status()["enabled"])

    def test_shell_refresh_failure_does_not_undo_applied_tint(self):
        (self.bin / "omarchy-shell").write_text("#!/bin/sh\nexit 1\n")
        self.run_helper()
        self.assertTrue(self.status()["enabled"])


if __name__ == "__main__":
    unittest.main()
