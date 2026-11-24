"""Cross-platform CLI runner for VCam Sync Studio desktop server."""

from __future__ import annotations

import os
import socket
import sys
import threading
import time
import webbrowser
from pathlib import Path

import uvicorn

BASE_DIR = Path(__file__).resolve().parent
os.chdir(BASE_DIR)
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

from config import ConfigManager  # noqa: E402
from discovery import resolve_active_host  # noqa: E402


def _find_free_port(start_port: int) -> int:
    for port in range(start_port, min(start_port + 25, 65535)):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("0.0.0.0", port))
                return port
            except OSError:
                continue
    return start_port


def main() -> None:
    cfg_mgr = ConfigManager()
    cfg = cfg_mgr.get_config()
    port = _find_free_port(cfg.server_port)
    os.environ["VCAM_SERVER_PORT"] = str(port)
    host_ip = resolve_active_host(cfg.preferred_host)

    print("======================================================")
    print("  虚拟相机同步工作台 · VCam Sync Studio")
    print(f"  本地桌面界面: http://127.0.0.1:{port}")
    print(f"  局域网地址:   http://{host_ip}:{port}")
    print(f"  UDP 发现端口: {cfg.discovery_port}")
    print("======================================================")

    def _open_browser() -> None:
        time.sleep(1.0)
        webbrowser.open(f"http://127.0.0.1:{port}")

    threading.Thread(target=_open_browser, daemon=True).start()
    uvicorn.run("main:app", host="0.0.0.0", port=port, log_level="info")


if __name__ == "__main__":
    main()
