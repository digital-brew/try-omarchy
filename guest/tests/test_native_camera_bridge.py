#!/usr/bin/env python3
"""Protocol and V4L2 contract tests for the native macOS camera bridge."""

from __future__ import annotations

import ctypes
from importlib.machinery import SourceFileLoader
from pathlib import Path
import struct
import unittest
from unittest import mock


GUEST = Path(__file__).resolve().parents[1]
BRIDGE_PATH = GUEST / "native-overlay/usr/local/bin/omarchy-native-camera-bridge"
bridge = SourceFileLoader("omarchy_native_camera_bridge", str(BRIDGE_PATH)).load_module()


class NativeCameraBridgeTests(unittest.TestCase):
    def message(self, kind: int, payload: bytes, sequence: int = 0) -> bytes:
        return bridge.HEADER.pack(
            bridge.MAGIC,
            bridge.VERSION,
            kind,
            0,
            len(payload),
            sequence,
        ) + payload

    def test_fragmented_status_and_frame_messages_are_reassembled(self) -> None:
        status = b'{"status":"streaming"}'
        frame = bytes([37]) * bridge.FRAME_BYTES
        encoded = self.message(bridge.KIND_STATUS, status) + self.message(
            bridge.KIND_FRAME, frame, sequence=42
        )
        parser = bridge.MessageParser()
        messages = []
        for offset in range(0, len(encoded), 65537):
            messages.extend(parser.feed(encoded[offset : offset + 65537]))
        self.assertEqual(messages[0], (bridge.KIND_STATUS, 0, status))
        self.assertEqual(messages[1], (bridge.KIND_FRAME, 42, frame))
        self.assertEqual(parser.buffer, b"")

    def test_invalid_frame_size_is_rejected_before_buffering_payload(self) -> None:
        for payload_bytes in (0, bridge.MAX_FRAME_BYTES + 1):
            parser = bridge.MessageParser()
            header = bridge.HEADER.pack(
                bridge.MAGIC, bridge.VERSION, bridge.KIND_FRAME, 0, payload_bytes, 1
            )
            with self.assertRaisesRegex(ValueError, "invalid size"):
                parser.feed(header)

    def test_frames_of_another_geometry_parse_and_are_left_to_the_caller(self) -> None:
        # The host may still stream the old size while the guest switches.
        parser = bridge.MessageParser()
        frame = bytes([9]) * (640 * 480 * 3 // 2)
        messages = parser.feed(self.message(bridge.KIND_FRAME, frame, sequence=5))
        self.assertEqual(messages, [(bridge.KIND_FRAME, 5, frame)])
        self.assertNotEqual(len(frame), bridge.FRAME_BYTES)

    def test_control_messages_carry_the_loopback_geometry(self) -> None:
        self.assertEqual(bridge.control_message("status"), b'{"type":"status"}\n')
        self.assertEqual(bridge.control_message("stop"), b'{"type":"stop"}\n')
        self.assertEqual(
            bridge.control_message("start", height=bridge.HEIGHT, width=bridge.WIDTH),
            b'{"height":720,"type":"start","width":1280}\n',
        )

    def test_host_geometry_resizes_frames_and_is_applied_when_idle(self) -> None:
        original = (bridge.WIDTH, bridge.HEIGHT, bridge.FRAME_BYTES)
        try:
            geometry = bridge.handle_status(
                b'{"fps":30,"height":480,"pixelFormat":"NV12","status":"idle","width":640}'
            )
            self.assertEqual(geometry, (640, 480))
            # The same geometry as ours needs no reconfiguration.
            self.assertIsNone(
                bridge.handle_status(b'{"height":720,"status":"idle","width":1280}')
            )
            self.assertIsNone(bridge.handle_status(b'{"status":"idle"}'))
            # Adopting a geometry reopens the device: v4l2loopback pins the
            # format after the first write, so S_FMT alone would be ignored.
            poller = mock.Mock()
            with mock.patch.object(bridge, "os") as fake_os, mock.patch.object(
                bridge, "open_camera", return_value=9
            ) as open_camera, mock.patch.object(bridge, "configure_camera") as configure:
                self.assertEqual(bridge.adopt_format(7, geometry, poller), 9)
            poller.unregister.assert_called_once_with(7)
            fake_os.close.assert_called_once_with(7)
            open_camera.assert_called_once_with()
            configure.assert_called_once_with(9)
            poller.register.assert_called_once_with(9, bridge.select.POLLPRI)
            with mock.patch.object(bridge, "os"), mock.patch.object(
                bridge, "open_camera", return_value=11
            ), mock.patch.object(
                bridge, "configure_camera", side_effect=RuntimeError("rejected")
            ):
                with self.assertRaisesRegex(RuntimeError, "rejected"):
                    bridge.adopt_format(9, geometry, mock.Mock())
            self.assertEqual((bridge.WIDTH, bridge.HEIGHT), (640, 480))
            self.assertEqual(bridge.FRAME_BYTES, 640 * 480 * 3 // 2)
            self.assertEqual(len(bridge.black_frame()), bridge.FRAME_BYTES)
            parser = bridge.MessageParser()
            frame = bytes([37]) * bridge.FRAME_BYTES
            messages = parser.feed(self.message(bridge.KIND_FRAME, frame, sequence=3))
            self.assertEqual(messages, [(bridge.KIND_FRAME, 3, frame)])
            for bad in ((641, 480), (640, 481), (8, 8), (7680, 4320), (True, 480), ("640", 480)):
                with self.assertRaisesRegex(ValueError, "unusable camera geometry"):
                    bridge.apply_format(*bad)
            with self.assertRaisesRegex(ValueError, "pixel format"):
                bridge.handle_status(
                    b'{"height":480,"pixelFormat":"YUYV","status":"idle","width":640}'
                )
        finally:
            bridge.WIDTH, bridge.HEIGHT, bridge.FRAME_BYTES = original

    def test_black_frame_is_video_range_nv12(self) -> None:
        frame = bridge.black_frame()
        self.assertEqual(len(frame), bridge.FRAME_BYTES)
        luma_bytes = bridge.WIDTH * bridge.HEIGHT
        self.assertEqual(set(frame[:luma_bytes]), {16})
        self.assertEqual(set(frame[luma_bytes:]), {128})

    def test_v4l2_ioctl_layout_matches_linux_uapi(self) -> None:
        self.assertEqual(ctypes.sizeof(bridge.V4L2PixFormat), 48)
        self.assertEqual(ctypes.sizeof(bridge.V4L2Format), 208)
        self.assertEqual(ctypes.sizeof(bridge.V4L2EventSubscription), 32)
        self.assertEqual(ctypes.sizeof(bridge.V4L2Event), 136)
        self.assertEqual(bridge.V4L2Event.data.offset, 8)
        self.assertEqual(bridge.V4L2Event.pending.offset, 72)
        self.assertEqual(bridge.V4L2Event.sequence.offset, 76)
        self.assertEqual(bridge.V4L2Event.timestamp.offset, 80)
        self.assertEqual(bridge.VIDIOC_S_FMT, 0xC0D05605)
        self.assertEqual(bridge.VIDIOC_DQEVENT, 0x80885659)
        self.assertEqual(bridge.VIDIOC_SUBSCRIBE_EVENT, 0x4020565A)
        self.assertEqual(bridge.V4L2_EVENT_SUB_FL_SEND_INITIAL, 0x0001)

    def test_dequeue_client_count_reads_aligned_event_union(self) -> None:
        def fill_event(_descriptor, request, event, mutate) -> None:
            self.assertEqual(request, bridge.VIDIOC_DQEVENT)
            self.assertTrue(mutate)
            event.type = bridge.V4L2_EVENT_PRI_CLIENT_USAGE
            count = ctypes.c_uint32(1)
            ctypes.memmove(
                ctypes.addressof(event) + bridge.V4L2Event.data.offset,
                ctypes.byref(count),
                ctypes.sizeof(count),
            )

        with mock.patch.object(bridge.fcntl, "ioctl", side_effect=fill_event):
            self.assertEqual(bridge.dequeue_client_count(42), 1)

    def test_camera_subscription_requests_initial_client_usage(self) -> None:
        with (
            mock.patch.object(bridge.fcntl, "ioctl") as ioctl,
            mock.patch.object(bridge, "write_frame"),
        ):
            bridge.configure_camera(42)

        self.assertEqual(ioctl.call_count, 2)
        subscription_call = ioctl.call_args_list[1]
        self.assertEqual(subscription_call.args[1], bridge.VIDIOC_SUBSCRIBE_EVENT)
        subscription = subscription_call.args[2]
        self.assertEqual(subscription.type, bridge.V4L2_EVENT_PRI_CLIENT_USAGE)
        self.assertEqual(
            subscription.flags,
            bridge.V4L2_EVENT_SUB_FL_SEND_INITIAL,
        )

    def test_wire_header_is_little_endian_and_fixed_size(self) -> None:
        self.assertEqual(bridge.HEADER.size, 16)
        encoded = self.message(bridge.KIND_STATUS, b"ok", sequence=0x01020304)
        self.assertEqual(encoded[:4], b"TOCM")
        self.assertEqual(encoded[8:12], struct.pack("<I", 2))
        self.assertEqual(encoded[12:16], b"\x04\x03\x02\x01")


if __name__ == "__main__":
    unittest.main()
