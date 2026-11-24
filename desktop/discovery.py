"""LAN IPv4 enumeration and UDP auto-discovery responder."""

from __future__ import annotations

import ipaddress
import json
import logging
import socket
import threading
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from config import ConfigManager

logger = logging.getLogger("vcam_desktop.discovery")


def _is_virtual_range(ip_str: str) -> bool:
    octets = ip_str.split(".")
    if len(octets) != 4:
        return False
    first, second = int(octets[0]), int(octets[1])
    if first == 198 and second in (18, 19):
        return True
    if first == 172 and 17 <= second <= 31:
        return True
    return False


def _ip_priority(ip_str: str, primary_ip: str | None) -> tuple[int, str]:
    if ip_str == primary_ip and not _is_virtual_range(ip_str):
        return (0, ip_str)
    try:
        addr = ipaddress.IPv4Address(ip_str)
    except ValueError:
        return (99, ip_str)
    if addr.is_loopback or addr.is_link_local:
        return (90, ip_str)
    # Deprioritize common virtual tunnel / Docker / WSL ranges when real LAN exists
    octets = ip_str.split(".")
    first, second = int(octets[0]), int(octets[1])
    if first == 198 and second in (18, 19):
        return (50, ip_str)
    if first == 172 and 17 <= second <= 31:
        return (35, ip_str)
    if first == 192 and second == 168:
        return (10, ip_str)
    if first == 10:
        return (15, ip_str)
    if addr.is_private:
        return (20, ip_str)
    return (40, ip_str)


def get_lan_ipv4_addresses() -> list[dict[str, Any]]:
    """Return sorted candidate LAN IPv4 addresses on this machine."""
    primary_ip: str | None = None
    for probe_target in (("192.168.1.1", 80), ("10.0.0.1", 80), ("8.8.8.8", 80)):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(probe_target)
                cand = s.getsockname()[0]
                if cand and not cand.startswith("127.") and not cand.startswith("169.254."):
                    primary_ip = cand
                    break
        except OSError:
            continue

    found: set[str] = set()
    if primary_ip:
        found.add(primary_ip)

    try:
        for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = item[4][0]
            if ip and not ip.startswith("127.") and not ip.startswith("169.254."):
                found.add(ip)
    except OSError:
        pass

    if not found:
        found.add("127.0.0.1")

    ordered = sorted(found, key=lambda ip: _ip_priority(ip, primary_ip))
    result: list[dict[str, Any]] = []
    for idx, ip in enumerate(ordered):
        tag = "推荐局域网" if idx == 0 else "备用网卡"
        if ip.startswith("198.18.") or ip.startswith("198.19."):
            tag = "代理虚拟网卡"
        elif ip.startswith("172."):
            second = int(ip.split(".")[1])
            if 17 <= second <= 31:
                tag = "虚拟/容器网段"
        result.append(
            {
                "ip": ip,
                "label": f"{ip}（{tag}）",
                "is_primary": idx == 0,
            }
        )
    return result


def resolve_active_host(preferred_host: str = "") -> str:
    """Resolve active host IP, respecting manual choice when still present or non-empty."""
    candidates = get_lan_ipv4_addresses()
    ips = [item["ip"] for item in candidates]
    if preferred_host and preferred_host in ips:
        return preferred_host
    if preferred_host and preferred_host != "127.0.0.1":
        return preferred_host
    return ips[0] if ips else "127.0.0.1"


class DiscoveryServer:
    """Background UDP listener that answers iOS LAN auto-discovery probes."""

    def __init__(self, config_manager: ConfigManager, port: int | None = None) -> None:
        self._config_manager = config_manager
        self._port = port if port is not None else config_manager.get_config().discovery_port
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._sock: socket.socket | None = None
        self.bound_port: int | None = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.bind(("0.0.0.0", self._port))
            sock.settimeout(0.5)
            self._sock = sock
            self.bound_port = sock.getsockname()[1]
        except OSError as exc:
            logger.warning("UDP 自动发现端口 %s 绑定失败（可仍使用扫码配对）: %s", self._port, exc)
            sock.close()
            self._sock = None
            self.bound_port = None
            return

        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._serve_loop,
            name="VCamDiscoveryUDP",
            daemon=True,
        )
        self._thread.start()
        logger.info("UDP 局域网发现服务已启动: 0.0.0.0:%s", self.bound_port)

    def stop(self) -> None:
        self._stop_event.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.5)
        self._thread = None

    def _serve_loop(self) -> None:
        assert self._sock is not None
        while not self._stop_event.is_set():
            try:
                data, addr = self._sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break

            text = data.decode("utf-8", errors="ignore").strip()
            if "vcamsync_discover" not in text.lower():
                continue

            cfg = self._config_manager.get_config()
            hosts = [item["ip"] for item in get_lan_ipv4_addresses()]
            active_host = resolve_active_host(cfg.preferred_host)
            reply = json.dumps(
                {
                    "type": "vcamsync_announce",
                    "v": 1,
                    "name": cfg.device_label,
                    "host": active_host,
                    "hosts": hosts,
                    "port": cfg.server_port,
                    "token": cfg.pairing_token,
                },
                ensure_ascii=False,
            ).encode("utf-8")
            try:
                self._sock.sendto(reply, addr)
            except OSError as exc:
                logger.debug("回复 UDP 发现请求失败 (%s): %s", addr, exc)
