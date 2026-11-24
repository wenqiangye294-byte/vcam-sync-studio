"""VCam Sync Studio - 无黑框桌面 App 启动器。

功能：
1. 双击桌面图标无黑框静默启动本地服务；
2. 若服务已在运行，直接弹出独立桌面 App 窗口；
3. 优先以 Edge / Chrome 的 `--app` 独立应用窗口模式打开（无浏览器地址栏）；
4. 监听 `--host 0.0.0.0`，让同一局域网下的 iPhone 扫码或自动发现连接。
"""

from __future__ import annotations

import ctypes
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
import webbrowser
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
os.chdir(BASE_DIR)
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

LOG_DIR = BASE_DIR / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)
STATE_FILE = LOG_DIR / "launcher_state.json"

RESTART_EXIT_CODE = 42
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)


def _msgbox(title: str, text: str, icon: int = 0x10) -> None:
    try:
        ctypes.windll.user32.MessageBoxW(0, text, title, icon)
    except Exception:
        pass


def _probe_health(port: int, timeout: float = 1.0) -> bool:
    url = f"http://127.0.0.1:{port}/health"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(url, timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


def _is_port_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.2)
        if probe.connect_ex(("127.0.0.1", port)) == 0:
            return False
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            except OSError:
                pass
        try:
            sock.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def _find_free_port(start_port: int = 18760) -> int:
    for port in range(start_port, min(start_port + 25, 65535)):
        if _is_port_free(port):
            return port
    raise RuntimeError(f"端口 {start_port}-{start_port + 24} 均被占用")


def _find_existing_port(preferred_port: int) -> int | None:
    candidates = [preferred_port]
    if STATE_FILE.exists():
        try:
            saved = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            p = int(saved.get("port", 0))
            if p and p not in candidates:
                candidates.insert(0, p)
        except Exception:
            pass
    for p in candidates:
        if _probe_health(p, timeout=0.8):
            return p
    return None


def _open_as_app_window(url: str) -> None:
    browser_candidates = [
        shutil.which("msedge"),
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        shutil.which("chrome"),
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
    ]
    for exe in browser_candidates:
        if exe and os.path.exists(exe):
            try:
                subprocess.Popen(
                    [exe, f"--app={url}", "--window-size=1420,880"],
                    creationflags=CREATE_NO_WINDOW,
                )
                return
            except Exception:
                continue
    webbrowser.open(url)


def _python_has_deps(py_path: str) -> bool:
    try:
        res = subprocess.run(
            [py_path, "-c", "import fastapi, uvicorn, websockets, PIL, pydantic"],
            capture_output=True,
            timeout=8,
            creationflags=CREATE_NO_WINDOW,
        )
        return res.returncode == 0
    except Exception:
        return False


def _get_python_executable() -> str:
    venv_py = BASE_DIR / "venv" / "Scripts" / "python.exe"
    if venv_py.exists() and _python_has_deps(str(venv_py)):
        return str(venv_py)
    cur = Path(sys.executable)
    if cur.name.lower() == "pythonw.exe":
        sibling = cur.with_name("python.exe")
        if sibling.exists():
            return str(sibling)
    return sys.executable


def _wait_for_ready(port: int, proc: subprocess.Popen, timeout_sec: int = 30) -> bool:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        if _probe_health(port, timeout=1.0):
            return True
        time.sleep(0.35)
    return False


def main() -> None:
    preferred_port = 18760
    try:
        from config import ConfigManager

        preferred_port = ConfigManager().get_config().server_port
    except Exception:
        pass

    running_port = _find_existing_port(preferred_port)
    if running_port is not None:
        _open_as_app_window(f"http://127.0.0.1:{running_port}")
        return

    py_exe = _get_python_executable()
    opened_once = False

    while True:
        try:
            port = _find_free_port(preferred_port)
        except RuntimeError as exc:
            _msgbox("虚拟相机同步工作台 - 启动失败", str(exc))
            sys.exit(1)

        STATE_FILE.write_text(
            json.dumps({"port": port, "started_at": time.time()}),
            encoding="utf-8",
        )
        server_log_path = LOG_DIR / "server_stdio.log"
        log_fp = open(server_log_path, "a", encoding="utf-8", errors="replace")

        env = os.environ.copy()
        env["VCAM_SERVER_PORT"] = str(port)

        cmd = [
            py_exe,
            "-m",
            "uvicorn",
            "main:app",
            "--host",
            "0.0.0.0",
            "--port",
            str(port),
        ]
        proc = subprocess.Popen(
            cmd,
            cwd=str(BASE_DIR),
            env=env,
            stdout=log_fp,
            stderr=subprocess.STDOUT,
            creationflags=CREATE_NO_WINDOW,
        )

        if not _wait_for_ready(port, proc, timeout_sec=30):
            log_fp.close()
            _msgbox(
                "虚拟相机同步工作台 - 启动失败",
                f"后端服务未能启动，请查看日志：\n{server_log_path}",
            )
            sys.exit(1)

        if not opened_once:
            _open_as_app_window(f"http://127.0.0.1:{port}")
            opened_once = True

        exit_code = proc.wait()
        log_fp.close()
        if exit_code == RESTART_EXIT_CODE:
            time.sleep(0.4)
            continue
        break


if __name__ == "__main__":
    main()
