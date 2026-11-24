"""Automated test suite for VCam Sync Studio desktop server and modules."""

from __future__ import annotations

import hashlib
import io
import json
import socket
import struct
import sys
import tempfile
import unittest
from pathlib import Path

from fastapi.testclient import TestClient
from PIL import Image
from starlette.websockets import WebSocketDisconnect

DESKTOP_DIR = Path(__file__).resolve().parents[1]
if str(DESKTOP_DIR) not in sys.path:
    sys.path.insert(0, str(DESKTOP_DIR))

from config import ConfigManager  # noqa: E402
from discovery import DiscoveryServer  # noqa: E402
from main import create_app  # noqa: E402
from media_utils import (  # noqa: E402
    natural_sort_key,
    parse_mp4_metadata,
    process_image_bytes,
    process_video_bytes,
)
from qr_generator import encode_qr_matrix, generate_qr_svg  # noqa: E402
from storage import StorageManager  # noqa: E402


def _make_jpeg_bytes(width: int = 80, height: int = 40, exif_orientation: int | None = None) -> bytes:
    img = Image.new("RGB", (width, height), (37, 99, 235))
    buf = io.BytesIO()
    if exif_orientation is not None:
        exif = img.getexif()
        exif[274] = exif_orientation
        img.save(buf, format="JPEG", exif=exif)
    else:
        img.save(buf, format="JPEG")
    return buf.getvalue()


def _box(box_type: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", 8 + len(payload)) + box_type + payload


def _make_synthetic_mp4(width: int = 1080, height: int = 1920, duration_sec: float = 4.5) -> bytes:
    timescale = 1000
    dur_units = int(duration_sec * timescale)
    # mvhd version 0 (100 bytes payload)
    mvhd_payload = bytearray(100)
    struct.pack_into(">I", mvhd_payload, 12, timescale)
    struct.pack_into(">I", mvhd_payload, 16, dur_units)

    # tkhd version 0 (84 bytes payload)
    tkhd_payload = bytearray(84)
    struct.pack_into(">I", tkhd_payload, 76, width << 16)
    struct.pack_into(">I", tkhd_payload, 80, height << 16)

    # hdlr box with 'vide' at payload offset 8..12
    hdlr_payload = bytearray(24)
    hdlr_payload[8:12] = b"vide"
    mdia = _box(b"mdia", _box(b"hdlr", bytes(hdlr_payload)))
    trak = _box(b"trak", _box(b"tkhd", bytes(tkhd_payload)) + mdia)
    moov = _box(b"moov", _box(b"mvhd", bytes(mvhd_payload)) + trak)
    ftyp = _box(b"ftyp", b"isom\x00\x00\x02\x00isommp41")
    mdat = _box(b"mdat", b"\x00" * 32)
    return ftyp + moov + mdat


class QRGeneratorTests(unittest.TestCase):
    def test_qr_matrix_finder_and_versions(self) -> None:
        for payload in [
            "vcamsync://pair?host=192.168.1.5&port=18760&token=abc123",
            "vcamsync://pair?host=192.168.100.200&port=18760&token=LongToken_1234567890&name=Desktop-Workstation",
            "vcamsync://pair?host=192.168.31.88&port=18760&token=VeryLongToken_0123456789ABCDEF&name=" + ("测试电脑" * 6),
        ]:
            matrix = encode_qr_matrix(payload)
            n = len(matrix)
            self.assertGreaterEqual(n, 25)
            # Top-left 7x7 finder corners & center
            self.assertTrue(matrix[0][0])
            self.assertTrue(matrix[0][6])
            self.assertTrue(matrix[6][0])
            self.assertTrue(matrix[3][3])
            self.assertFalse(matrix[1][1])
            # Top-right & bottom-left finders
            self.assertTrue(matrix[0][n - 1])
            self.assertTrue(matrix[n - 1][0])
            # Separator light modules
            self.assertFalse(matrix[7][0])
            self.assertFalse(matrix[0][7])

            svg = generate_qr_svg(payload)
            self.assertTrue(svg.startswith("<svg"))
            self.assertIn("</svg>", svg)
            self.assertIn("<path ", svg)


class MediaUtilsTests(unittest.TestCase):
    def test_natural_sort_key(self) -> None:
        names = ["10.jpg", "2.jpg", "1.jpg", "item_20.png", "item_3.png"]
        sorted_names = sorted(names, key=natural_sort_key)
        self.assertEqual(
            sorted_names, ["1.jpg", "2.jpg", "10.jpg", "item_3.png", "item_20.png"]
        )

    def test_exif_transposition_and_sha256(self) -> None:
        raw = _make_jpeg_bytes(width=120, height=60, exif_orientation=6)
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            dest = tmp_dir / "out.jpg"
            thumb = tmp_dir / "thumb.jpg"
            meta = process_image_bytes(raw, dest, thumb)
            # Orientation 6 rotates 120x60 into 60x120 upright
            self.assertEqual(meta["width"], 60)
            self.assertEqual(meta["height"], 120)
            self.assertTrue(dest.exists())
            self.assertTrue(thumb.exists())
            self.assertEqual(
                meta["sha256"],
                hashlib.sha256(dest.read_bytes()).hexdigest(),
            )

    def test_mp4_metadata_parser(self) -> None:
        mp4 = _make_synthetic_mp4(width=1080, height=1920, duration_sec=6.25)
        meta = parse_mp4_metadata(mp4)
        self.assertEqual(meta["width"], 1080)
        self.assertEqual(meta["height"], 1920)
        self.assertAlmostEqual(meta["duration"], 6.25, places=2)

        with tempfile.TemporaryDirectory() as tmp:
            out_mp4 = Path(tmp) / "clip.mp4"
            res = process_video_bytes(mp4, out_mp4)
            self.assertEqual(res["width"], 1080)
            self.assertEqual(res["height"], 1920)
            self.assertEqual(res["size"], len(mp4))


class StorageManagerTests(unittest.TestCase):
    def test_product_reorder_cursor_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            cfg_mgr = ConfigManager(data_dir=tmp_dir, log_dir=tmp_dir / "logs")
            storage = StorageManager(tmp_dir)

            default_prod = storage.get_active_product()
            self.assertEqual(default_prod["name"], "默认商品包")

            prod = storage.create_product("卫衣拍摄组", note="共3张")
            rev_before = storage.get_revision()

            ids = []
            for idx in range(3):
                mid = f"p{idx}"
                ids.append(mid)
                storage.add_media(
                    media_id=mid,
                    product_id=prod["id"],
                    kind="photo",
                    filename=f"{mid}.jpg",
                    thumb_filename=f"{mid}_t.jpg",
                    original_name=f"{idx}.jpg",
                    sha256=f"sha{idx}",
                    size=100,
                    width=800,
                    height=800,
                    duration=0.0,
                )

            storage.reorder_media(prod["id"], "photo", ["p2", "p0", "p1"])
            manifest = storage.build_manifest(cfg_mgr.get_config())
            self.assertGreater(manifest["revision"], rev_before)
            self.assertEqual(
                [p["id"] for p in manifest["product"]["photos"]],
                ["p2", "p0", "p1"],
            )

            # Step forward, clamp at end when loop=False, wrap when loop=True
            storage.step_cursor(prod["id"], "photo", delta=2, loop=False)
            self.assertEqual(storage.get_active_product()["photo_cursor"], 2)
            storage.step_cursor(prod["id"], "photo", delta=1, loop=False)
            self.assertEqual(storage.get_active_product()["photo_cursor"], 2)
            storage.step_cursor(prod["id"], "photo", delta=1, loop=True)
            self.assertEqual(storage.get_active_product()["photo_cursor"], 0)


class FastAPISyncAndWSTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp_dir = Path(self._tmp.name)
        self.app = create_app(
            data_dir=self.tmp_dir / "data",
            log_dir=self.tmp_dir / "logs",
            enable_discovery=False,
        )
        self.client = TestClient(self.app)
        self.client.__enter__()

    def tearDown(self) -> None:
        self.client.__exit__(None, None, None)
        self._tmp.cleanup()

    def test_full_http_workflow_and_token_auth(self) -> None:
        # Health & UI & Network Info
        r = self.client.get("/health")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["ok"])

        net = self.client.get("/api/network/info").json()
        self.assertIn("pair_url", net)
        self.assertIn("<svg", net["qr_svg"])
        token = net["token"]

        # Create product
        cr = self.client.post(
            "/api/products", json={"name": "陶瓷杯SKU1", "note": "测试"}
        )
        self.assertEqual(cr.status_code, 200)
        pid = cr.json()["product"]["id"]

        # Upload 2 photos + 1 video + 1 invalid file
        jpg1 = _make_jpeg_bytes(100, 100)
        jpg2 = _make_jpeg_bytes(200, 150)
        mp4 = _make_synthetic_mp4()
        up = self.client.post(
            f"/api/products/{pid}/media",
            files=[
                ("files", ("01.jpg", jpg1, "image/jpeg")),
                ("files", ("02.jpg", jpg2, "image/jpeg")),
                ("files", ("demo.mp4", mp4, "video/mp4")),
                ("files", ("readme.txt", b"ignored", "text/plain")),
            ],
        )
        self.assertEqual(up.status_code, 200)
        up_json = up.json()
        self.assertEqual(len(up_json["added"]), 3)
        self.assertEqual(up_json["skipped"], ["readme.txt"])

        photos = up_json["state"]["manifest"]["product"]["photos"]
        videos = up_json["state"]["manifest"]["product"]["videos"]
        self.assertEqual(len(photos), 2)
        self.assertEqual(len(videos), 1)

        # Import from local folder in natural order
        folder = self.tmp_dir / "batch_import"
        folder.mkdir()
        (folder / "10.jpg").write_bytes(_make_jpeg_bytes(90, 90))
        (folder / "2.jpg").write_bytes(_make_jpeg_bytes(90, 90))
        imp = self.client.post(
            f"/api/products/{pid}/import-folder",
            json={"folder_path": str(folder), "recursive": False},
        )
        self.assertEqual(imp.status_code, 200)
        imported_names = [item["original_name"] for item in imp.json()["added"]]
        self.assertEqual(imported_names, ["2.jpg", "10.jpg"])

        # Range streaming on video file
        vid_url = videos[0]["url"]
        range_resp = self.client.get(vid_url, headers={"Range": "bytes=0-15"})
        self.assertEqual(range_resp.status_code, 206)
        self.assertEqual(len(range_resp.content), 16)

        # Auth check on /api/sync/manifest
        self.assertEqual(self.client.get("/api/sync/manifest").status_code, 401)
        self.assertEqual(
            self.client.get("/api/sync/manifest?token=wrong").status_code, 401
        )
        sync_manifest = self.client.get(f"/api/sync/manifest?token={token}")
        self.assertEqual(sync_manifest.status_code, 200)
        self.assertEqual(len(sync_manifest.json()["product"]["photos"]), 4)

        # Device HTTP telemetry event updates cursor
        ev_resp = self.client.post(
            f"/api/sync/device/event?token={token}",
            json={
                "device_id": "iphone-162",
                "device_name": "测试iPhone",
                "ios_version": "16.2",
                "event_type": "photo_captured",
                "product_id": pid,
                "photo_cursor": 2,
                "sync_revision": sync_manifest.json()["revision"],
            },
        )
        self.assertEqual(ev_resp.status_code, 200)
        state = self.client.get("/api/queue/state").json()
        self.assertEqual(state["manifest"]["product"]["photo_cursor"], 2)
        self.assertEqual(state["devices"][0]["device_name"], "测试iPhone")

    def test_websocket_bidirectional_sync(self) -> None:
        token = self.client.get("/api/network/info").json()["token"]

        # Invalid WS token rejected
        with self.assertRaises(WebSocketDisconnect):
            with self.client.websocket_connect("/ws/device?token=invalid"):
                pass

        with self.client.websocket_connect("/ws/ui") as ui_ws:
            init_msg = ui_ws.receive_json()
            self.assertEqual(init_msg["event"], "state_updated")

            with self.client.websocket_connect(
                f"/ws/device?token={token}&device_id=ios1&device_name=MyPhone&ios_version=16.2"
            ) as dev_ws:
                manifest_msg = dev_ws.receive_json()
                self.assertEqual(manifest_msg["event"], "manifest_updated")

                # UI receives device connected update
                ui_connected = ui_ws.receive_json()
                self.assertEqual(ui_connected["event"], "state_updated")
                self.assertTrue(ui_connected["state"]["devices"][0]["connected"])

                # Upload a photo from PC & verify device receives manifest_updated
                pid = manifest_msg["manifest"]["product"]["id"]
                self.client.post(
                    f"/api/products/{pid}/media",
                    files=[("files", ("shot1.jpg", _make_jpeg_bytes(), "image/jpeg"))],
                )
                dev_update = dev_ws.receive_json()
                self.assertEqual(dev_update["event"], "manifest_updated")
                self.assertEqual(len(dev_update["manifest"]["product"]["photos"]), 1)

                # Upload second photo and let mock iPhone report capture_event
                self.client.post(
                    f"/api/products/{pid}/media",
                    files=[("files", ("shot2.jpg", _make_jpeg_bytes(), "image/jpeg"))],
                )
                dev_ws.receive_json()  # manifest_updated
                dev_ws.send_json(
                    {
                        "type": "capture_event",
                        "event_type": "photo_captured",
                        "product_id": pid,
                        "photo_cursor": 1,
                        "sync_revision": dev_update["manifest"]["revision"] + 1,
                    }
                )

                # Drain UI messages until we see photo_cursor == 1
                seen_cursor_one = False
                for _ in range(5):
                    ui_msg = ui_ws.receive_json()
                    if ui_msg["state"]["manifest"]["product"]["photo_cursor"] == 1:
                        seen_cursor_one = True
                        break
                self.assertTrue(seen_cursor_one)


class DiscoveryServerTests(unittest.TestCase):
    def test_udp_discovery_reply(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            cfg_mgr = ConfigManager(data_dir=tmp_dir, log_dir=tmp_dir / "logs")
            server = DiscoveryServer(cfg_mgr, port=0)
            server.start()
            try:
                self.assertIsNotNone(server.bound_port)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as cli:
                    cli.settimeout(2.0)
                    cli.sendto(
                        b'{"type":"vcamsync_discover","v":1}',
                        ("127.0.0.1", server.bound_port),
                    )
                    resp_bytes, _ = cli.recvfrom(4096)
                    resp = json.loads(resp_bytes.decode("utf-8"))
                    self.assertEqual(resp["type"], "vcamsync_announce")
                    self.assertEqual(resp["token"], cfg_mgr.get_config().pairing_token)
                    self.assertEqual(resp["port"], cfg_mgr.get_config().server_port)
            finally:
                server.stop()


if __name__ == "__main__":
    unittest.main()
