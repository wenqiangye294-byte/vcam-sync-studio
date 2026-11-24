"""Configuration management for VCam Sync Studio desktop server."""

from __future__ import annotations

import json
import os
import secrets
import socket
import threading
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_DATA_DIR = Path(os.environ.get("VCAM_DATA_DIR") or (BASE_DIR / "data")).resolve()
DEFAULT_LOG_DIR = Path(os.environ.get("VCAM_LOG_DIR") or (BASE_DIR / "logs")).resolve()


class AppConfig(BaseModel):
    """Persisted configuration for VCam Sync Studio."""

    server_port: int = Field(default=18760, ge=1024, le=65535)
    discovery_port: int = Field(default=18766, ge=1024, le=65535)
    pairing_token: str = ""
    preferred_host: str = ""
    device_label: str = Field(default_factory=lambda: socket.gethostname() or "VCam-PC")
    enabled: bool = True
    show_hud: bool = True
    loop_photos: bool = False
    loop_videos: bool = True
    fill_mode: Literal["fill", "fit"] = "fill"
    rotation: Literal[0, 90, 180, 270] = 0
    mirror: bool = False
    video_replace_mode: Literal["full", "trim", "frames"] = "full"


class ConfigManager:
    """Thread-safe JSON config loader and updater."""

    def __init__(self, data_dir: Path | None = None, log_dir: Path | None = None) -> None:
        self.data_dir = (data_dir or DEFAULT_DATA_DIR).resolve()
        self.log_dir = (log_dir or DEFAULT_LOG_DIR).resolve()
        self.media_dir = self.data_dir / "media"
        self.thumbs_dir = self.data_dir / "thumbs"
        self.config_path = self.data_dir / "config.json"

        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.media_dir.mkdir(parents=True, exist_ok=True)
        self.thumbs_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)

        self._lock = threading.RLock()
        self._config = self._load_or_init()

    def _load_or_init(self) -> AppConfig:
        raw: dict[str, Any] = {}
        if self.config_path.exists():
            try:
                raw = json.loads(self.config_path.read_text(encoding="utf-8"))
            except Exception:
                raw = {}
        cfg = AppConfig(**raw)
        dirty = not self.config_path.exists()
        if not cfg.pairing_token:
            cfg.pairing_token = secrets.token_urlsafe(12)
            dirty = True
        if not cfg.device_label:
            cfg.device_label = socket.gethostname() or "VCam-PC"
            dirty = True
        if dirty:
            self._write(cfg)
        return cfg

    def _write(self, cfg: AppConfig) -> None:
        tmp = self.config_path.with_suffix(".json.tmp")
        tmp.write_text(cfg.model_dump_json(indent=2), encoding="utf-8")
        tmp.replace(self.config_path)

    def get_config(self) -> AppConfig:
        with self._lock:
            return self._config.model_copy()

    def update_config(self, patch: dict[str, Any]) -> AppConfig:
        with self._lock:
            merged = self._config.model_dump()
            for key, value in patch.items():
                if key in merged and value is not None:
                    merged[key] = value
            updated = AppConfig(**merged)
            if not updated.pairing_token:
                updated.pairing_token = self._config.pairing_token or secrets.token_urlsafe(12)
            self._config = updated
            self._write(updated)
            return updated.model_copy()

    def regenerate_token(self) -> AppConfig:
        return self.update_config({"pairing_token": secrets.token_urlsafe(12)})
