#!/usr/bin/env python3
"""The display sync's optional refresh cap from monitors.lua."""

import os
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1] / "try-omarchy"
SYNC = PACKAGE / "files/usr/bin/omarchy-native-display-sync"


def edid_120hz_1080p() -> bytes:
    # One detailed timing: 1920x1080, htotal 2200, vtotal 1125, 297 MHz (120 Hz).
    width, hblank, hfront, hsync = 1920, 280, 88, 44
    height, vblank, vfront, vsync = 1080, 45, 4, 5
    dtd = struct.pack("<H", 29700) + bytes([
        width & 0xFF, hblank & 0xFF, (width >> 8) << 4 | hblank >> 8,
        height & 0xFF, vblank & 0xFF, (height >> 8) << 4 | vblank >> 8,
        hfront & 0xFF, hsync & 0xFF, (vfront & 0xF) << 4 | (vsync & 0xF),
        (hfront >> 8) << 6 | (hsync >> 8) << 4 | (vfront >> 4) << 2 | vsync >> 4,
        0x40, 0x1A, 0x10,  # 320 x 186 mm
        0, 0, 0x1E,  # digital separate sync, both positive
    ])
    edid = bytearray(128)
    edid[:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    edid[18:20] = b"\x01\x04"
    edid[54:72] = dtd
    edid[127] = -sum(edid[:127]) % 256
    return bytes(edid)


class RefreshCapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.edid = root / "edid"
        self.edid.write_bytes(edid_120hz_1080p())
        self.config = root / "monitors.lua"
        # The script's EDID parser is its embedded Python program.
        source = SYNC.read_text()
        start = source.index("<<'PY'\n") + len("<<'PY'\n")
        self.program = source[start:source.index("\nPY\n", start)]

    def tearDown(self):
        self.tmp.cleanup()

    def mode(self, config: str) -> str:
        self.config.write_text(config)
        result = subprocess.run(
            ["python3", "-c", self.program, str(self.edid), str(self.config)],
            check=True, capture_output=True, text=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        return result.stdout.split("\t")[0]

    def test_without_a_cap_the_host_rate_is_kept(self):
        self.assertEqual(self.mode("local omarchy_monitor_scale = 1\n"),
                         "modeline 297 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync")

    def test_a_cap_lowers_the_pixel_clock_and_keeps_the_timings(self):
        self.assertEqual(self.mode("local omarchy_monitor_refresh_hz = 60 -- VirGL\n"),
                         "modeline 149 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync")

    def test_a_cap_above_the_host_rate_changes_nothing(self):
        self.assertEqual(self.mode("local omarchy_monitor_refresh_hz = 144\n"),
                         self.mode(""))

    def test_a_nonsense_cap_is_ignored(self):
        self.assertEqual(self.mode("local omarchy_monitor_refresh_hz = 0\n"), self.mode(""))


if __name__ == "__main__":
    unittest.main()
