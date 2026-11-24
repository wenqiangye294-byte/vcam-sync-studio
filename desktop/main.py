"""FastAPI backend, WebSocket sync hub, and HTTP API for VCam Sync Studio."""

from __future__ import annotations

import asyncio
import hmac
import logging
import mimetypes
import os
import threading
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Literal
from urllib.parse import quote

from fastapi import (
    FastAPI,
    File,
    HTTPException,
    Request,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from config import ConfigManager
from discovery import DiscoveryServer, get_lan_ipv4_addresses, resolve_active_host
from media_utils import (
    detect_media_kind,
    natural_sort_key,
    process_image_bytes,
    process_video_bytes,
)
from qr_generator import generate_qr_svg
from storage import StorageManager

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

logger = logging.getLogger("vcam_desktop")


def _configure_logging(log_dir: Path) -> None:
    log_dir.mkdir(parents=True, exist_ok=True)
    root_logger = logging.getLogger("vcam_desktop")
    if root_logger.handlers:
        return
    root_logger.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    file_handler = logging.FileHandler(log_dir / "app.log", encoding="utf-8")
    file_handler.setFormatter(fmt)
    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(fmt)
    root_logger.addHandler(file_handler)
    root_logger.addHandler(stream_handler)


class ProductCreateRequest(BaseModel):
    name: str
    note: str = ""
    activate: bool = True


class ProductUpdateRequest(BaseModel):
    name: str | None = None
    note: str | None = None


class FolderImportRequest(BaseModel):
    folder_path: str
    recursive: bool = False


class ReorderRequest(BaseModel):
    kind: Literal["photo", "video"]
    ordered_ids: list[str]


class QueueSettingsRequest(BaseModel):
    enabled: bool | None = None
    show_hud: bool | None = None
    loop_photos: bool | None = None
    loop_videos: bool | None = None
    fill_mode: Literal["fill", "fit"] | None = None
    rotation: Literal[0, 90, 180, 270] | None = None
    mirror: bool | None = None
    video_replace_mode: Literal["full", "trim", "frames"] | None = None
    photo_cursor: int | None = None
    video_cursor: int | None = None


class QueueStepRequest(BaseModel):
    kind: Literal["photo", "video"] = "photo"
    delta: int = 1
    reset: bool = False


class NetworkUpdateRequest(BaseModel):
    host: str | None = None
    device_label: str | None = None


class DeviceEventRequest(BaseModel):
    device_id: str = "ios-device"
    device_name: str = "iPhone"
    ios_version: str = ""
    event_type: str = "cursor_changed"
    product_id: str | None = None
    photo_cursor: int | None = None
    video_cursor: int | None = None
    sync_revision: int | None = None
    sync_status: str | None = None
    target_apps: list[dict[str, Any]] | list[str] | None = None
    message: str = ""
    item_id: str | None = None


class ConnectionHub:
    """Manages connected desktop UI clients and iPhone sync devices."""

    def __init__(self) -> None:
        self.ui_clients: set[WebSocket] = set()
        self.device_sockets: dict[str, WebSocket] = {}
        self.devices: dict[str, dict[str, Any]] = {}
        self._lock = asyncio.Lock()

    async def register_ui(self, ws: WebSocket) -> None:
        async with self._lock:
            self.ui_clients.add(ws)

    async def unregister_ui(self, ws: WebSocket) -> None:
        async with self._lock:
            self.ui_clients.discard(ws)

    async def register_device(
        self,
        device_id: str,
        ws: WebSocket | None,
        *,
        device_name: str,
        ios_version: str,
        ip: str,
    ) -> None:
        now = time.time()
        async with self._lock:
            existing = self.devices.get(device_id, {})
            if ws is not None:
                self.device_sockets[device_id] = ws
            self.devices[device_id] = {
                "device_id": device_id,
                "device_name": device_name or existing.get("device_name") or "iPhone",
                "ios_version": ios_version or existing.get("ios_version") or "",
                "ip": ip or existing.get("ip") or "",
                "connected": ws is not None,
                "connected_at": existing.get("connected_at") or now,
                "last_seen": now,
                "sync_revision": existing.get("sync_revision", 0),
                "sync_status": existing.get("sync_status", "connecting" if ws else "online"),
                "target_apps": existing.get("target_apps", []),
            }

    async def update_device_state(
        self,
        device_id: str,
        *,
        device_name: str | None = None,
        ios_version: str | None = None,
        ip: str | None = None,
        sync_revision: int | None = None,
        sync_status: str | None = None,
        target_apps: list[Any] | None = None,
    ) -> None:
        now = time.time()
        async with self._lock:
            info = self.devices.setdefault(
                device_id,
                {
                    "device_id": device_id,
                    "device_name": device_name or "iPhone",
                    "ios_version": ios_version or "",
                    "ip": ip or "",
                    "connected": device_id in self.device_sockets,
                    "connected_at": now,
                    "last_seen": now,
                    "sync_revision": 0,
                    "sync_status": "idle",
                    "target_apps": [],
                },
            )
            info["last_seen"] = now
            if device_name:
                info["device_name"] = device_name
            if ios_version:
                info["ios_version"] = ios_version
            if ip:
                info["ip"] = ip
            if sync_revision is not None:
                info["sync_revision"] = int(sync_revision)
            if sync_status is not None:
                info["sync_status"] = sync_status
            if target_apps is not None:
                info["target_apps"] = target_apps

    async def unregister_device(self, device_id: str, ws: WebSocket) -> None:
        async with self._lock:
            cur = self.device_sockets.get(device_id)
            if cur is ws:
                self.device_sockets.pop(device_id, None)
                if device_id in self.devices:
                    self.devices[device_id]["connected"] = False
                    self.devices[device_id]["last_seen"] = time.time()
                    self.devices[device_id]["sync_status"] = "disconnected"

    async def list_devices(self) -> list[dict[str, Any]]:
        async with self._lock:
            return sorted(
                [dict(d) for d in self.devices.values()],
                key=lambda x: (0 if x.get("connected") else 1, -x.get("last_seen", 0.0)),
            )

    async def broadcast_ui(self, payload: dict[str, Any]) -> None:
        async with self._lock:
            clients = list(self.ui_clients)
        stale: list[WebSocket] = []
        for ws in clients:
            try:
                await ws.send_json(payload)
            except Exception:
                stale.append(ws)
        if stale:
            async with self._lock:
                for ws in stale:
                    self.ui_clients.discard(ws)

    async def broadcast_devices(self, payload: dict[str, Any]) -> None:
        async with self._lock:
            targets = list(self.device_sockets.items())
        stale: list[tuple[str, WebSocket]] = []
        for did, ws in targets:
            try:
                await ws.send_json(payload)
            except Exception:
                stale.append((did, ws))
        for did, ws in stale:
            await self.unregister_device(did, ws)


def _guess_video_media_type(filename: str) -> str:
    ext = Path(filename).suffix.lower()
    if ext == ".mov":
        return "video/quicktime"
    if ext == ".m4v":
        return "video/x-m4v"
    guessed, _ = mimetypes.guess_type(filename)
    return guessed or "video/mp4"


def create_app(
    *,
    data_dir: Path | None = None,
    log_dir: Path | None = None,
    discovery_port: int | None = None,
    enable_discovery: bool = True,
) -> FastAPI:
    config_manager = ConfigManager(data_dir=data_dir, log_dir=log_dir)
    _configure_logging(config_manager.log_dir)

    env_port = os.environ.get("VCAM_SERVER_PORT")
    if env_port and env_port.isdigit():
        config_manager.update_config({"server_port": int(env_port)})

    storage = StorageManager(config_manager.data_dir)
    hub = ConnectionHub()
    discovery_server = DiscoveryServer(config_manager, port=discovery_port)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        if enable_discovery:
            discovery_server.start()
        try:
            yield
        finally:
            if enable_discovery:
                discovery_server.stop()

    app = FastAPI(title="VCam Sync Studio", version="1.0.0", lifespan=lifespan)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

    if STATIC_DIR.exists():
        app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

    app.state.config_manager = config_manager
    app.state.storage = storage
    app.state.hub = hub
    app.state.discovery_server = discovery_server

    def _effective_port(request: Request | None = None) -> int:
        cfg = config_manager.get_config()
        if request is not None and request.url.port:
            return int(request.url.port)
        return int(cfg.server_port)

    def _build_network_payload(
        devices: list[dict[str, Any]], request: Request | None = None
    ) -> dict[str, Any]:
        cfg = config_manager.get_config()
        lan_ips = get_lan_ipv4_addresses()
        active_host = resolve_active_host(cfg.preferred_host)
        port = _effective_port(request)
        short_label = (cfg.device_label or "VCam-PC")[:24]
        pair_url = (
            f"vcamsync://pair?host={quote(active_host)}"
            f"&port={port}"
            f"&token={quote(cfg.pairing_token)}"
            f"&name={quote(short_label)}"
        )
        qr_svg = generate_qr_svg(pair_url)
        return {
            "lan_ips": lan_ips,
            "active_host": active_host,
            "port": port,
            "discovery_port": discovery_server.bound_port or cfg.discovery_port,
            "discovery_active": discovery_server.bound_port is not None,
            "device_label": cfg.device_label,
            "token": cfg.pairing_token,
            "pair_url": pair_url,
            "qr_svg": qr_svg,
            "devices": devices,
        }

    async def _build_full_state(request: Request | None = None) -> dict[str, Any]:
        cfg = config_manager.get_config()
        manifest = storage.build_manifest(cfg)
        devices = await hub.list_devices()
        return {
            "manifest": manifest,
            "config": cfg.model_dump(),
            "products": storage.list_products(),
            "devices": devices,
            "events": storage.list_events(limit=40),
            "network": _build_network_payload(devices, request=request),
        }

    async def _notify_manifest_change(*, force_sync: bool = False) -> None:
        cfg = config_manager.get_config()
        manifest = storage.build_manifest(cfg)
        event_name = "force_sync" if force_sync else "manifest_updated"
        await hub.broadcast_devices({"event": event_name, "manifest": manifest})
        state = await _build_full_state()
        await hub.broadcast_ui({"event": "state_updated", "state": state})

    async def _notify_ui_only() -> None:
        state = await _build_full_state()
        await hub.broadcast_ui({"event": "state_updated", "state": state})

    def _verify_token_value(token: str | None) -> None:
        expected = config_manager.get_config().pairing_token
        if not token or not hmac.compare_digest(token, expected):
            raise HTTPException(status_code=401, detail="无效的配对令牌 (token)")

    def _extract_token(request: Request) -> str:
        tok = request.query_params.get("token") or request.headers.get("X-VCam-Token")
        if not tok:
            auth = request.headers.get("Authorization", "")
            if auth.lower().startswith("bearer "):
                tok = auth[7:].strip()
        return tok or ""

    def _ingest_bytes(
        product_id: str, filename: str, raw: bytes, content_type: str = ""
    ) -> dict[str, Any] | None:
        kind = detect_media_kind(filename, content_type)
        if kind is None:
            return None
        media_id = uuid.uuid4().hex[:12]
        if kind == "photo":
            stored_name = f"{media_id}.jpg"
            thumb_name = f"{media_id}_thumb.jpg"
            meta = process_image_bytes(
                raw,
                storage.media_dir / stored_name,
                storage.thumbs_dir / thumb_name,
            )
        else:
            ext = Path(filename).suffix.lower()
            if ext not in {".mp4", ".mov", ".m4v"}:
                ext = ".mp4"
            stored_name = f"{media_id}{ext}"
            thumb_name = ""
            meta = process_video_bytes(raw, storage.media_dir / stored_name)

        return storage.add_media(
            media_id=media_id,
            product_id=product_id,
            kind=kind,
            filename=stored_name,
            thumb_filename=thumb_name,
            original_name=Path(filename).name,
            sha256=meta["sha256"],
            size=meta["size"],
            width=meta["width"],
            height=meta["height"],
            duration=meta["duration"],
        )

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return {"ok": True, "revision": storage.get_revision()}

    @app.get("/")
    async def index() -> FileResponse:
        index_path = STATIC_DIR / "index.html"
        if not index_path.exists():
            raise HTTPException(status_code=404, detail="index.html not found")
        return FileResponse(index_path)

    @app.get("/api/network/info")
    async def network_info(request: Request) -> dict[str, Any]:
        devices = await hub.list_devices()
        return _build_network_payload(devices, request=request)

    @app.patch("/api/network/host")
    async def update_network_host(
        body: NetworkUpdateRequest, request: Request
    ) -> dict[str, Any]:
        patch: dict[str, Any] = {}
        if body.host is not None:
            patch["preferred_host"] = body.host.strip()
        if body.device_label is not None and body.device_label.strip():
            patch["device_label"] = body.device_label.strip()
        if patch:
            config_manager.update_config(patch)
            storage.record_event("pc", "network_updated", "已更新局域网广播地址或设备名称", patch)
            await _notify_ui_only()
        devices = await hub.list_devices()
        return _build_network_payload(devices, request=request)

    @app.post("/api/network/regenerate-token")
    async def regenerate_token(request: Request) -> dict[str, Any]:
        config_manager.regenerate_token()
        storage.record_event("pc", "token_regenerated", "已刷新设备配对密钥")
        await _notify_ui_only()
        devices = await hub.list_devices()
        return _build_network_payload(devices, request=request)

    @app.get("/api/products")
    async def list_products() -> dict[str, Any]:
        active = storage.get_active_product()
        return {"products": storage.list_products(), "active_id": active["id"]}

    @app.post("/api/products")
    async def create_product(body: ProductCreateRequest) -> dict[str, Any]:
        prod = storage.create_product(body.name, body.note, activate=body.activate)
        storage.record_event("pc", "product_created", f"新建商品包：{prod['name']}")
        await _notify_manifest_change()
        return {"product": prod, "state": await _build_full_state()}

    @app.patch("/api/products/{product_id}")
    async def update_product(product_id: str, body: ProductUpdateRequest) -> dict[str, Any]:
        prod = storage.update_product(product_id, name=body.name, note=body.note)
        if prod is None:
            raise HTTPException(status_code=404, detail="商品包不存在")
        storage.record_event("pc", "product_updated", f"更新商品包：{prod['name']}")
        await _notify_manifest_change()
        return {"product": prod, "state": await _build_full_state()}

    @app.delete("/api/products/{product_id}")
    async def delete_product(product_id: str) -> dict[str, Any]:
        prod = storage.get_product(product_id)
        if not storage.delete_product(product_id):
            raise HTTPException(status_code=404, detail="商品包不存在")
        name = prod["name"] if prod else product_id
        storage.record_event("pc", "product_deleted", f"删除商品包：{name}")
        await _notify_manifest_change()
        return {"ok": True, "state": await _build_full_state()}

    @app.post("/api/products/{product_id}/activate")
    async def activate_product(product_id: str) -> dict[str, Any]:
        prod = storage.activate_product(product_id)
        if prod is None:
            raise HTTPException(status_code=404, detail="商品包不存在")
        storage.record_event("pc", "product_activated", f"切换当前商品：{prod['name']}")
        await _notify_manifest_change(force_sync=True)
        return {"product": prod, "state": await _build_full_state()}

    @app.post("/api/products/{product_id}/media")
    async def upload_media(
        product_id: str, files: list[UploadFile] = File(...)
    ) -> dict[str, Any]:
        prod = storage.get_product(product_id)
        if prod is None:
            raise HTTPException(status_code=404, detail="商品包不存在")

        added: list[dict[str, Any]] = []
        skipped: list[str] = []
        for upload in files:
            filename = upload.filename or "upload.bin"
            raw = await upload.read()
            if not raw:
                skipped.append(filename)
                continue
            try:
                item = _ingest_bytes(
                    product_id, filename, raw, content_type=upload.content_type or ""
                )
            except Exception as exc:
                logger.warning("处理上传文件 %s 失败: %s", filename, exc)
                skipped.append(filename)
                continue
            if item is None:
                skipped.append(filename)
            else:
                added.append(item)

        if added:
            storage.record_event(
                "pc",
                "media_uploaded",
                f"向「{prod['name']}」添加 {len(added)} 个素材",
                {"count": len(added), "skipped": skipped},
            )
            await _notify_manifest_change()

        return {"added": added, "skipped": skipped, "state": await _build_full_state()}

    @app.post("/api/products/{product_id}/import-folder")
    async def import_folder(
        product_id: str, body: FolderImportRequest
    ) -> dict[str, Any]:
        prod = storage.get_product(product_id)
        if prod is None:
            raise HTTPException(status_code=404, detail="商品包不存在")

        raw_path = body.folder_path.strip().strip('"').strip("'")
        folder = Path(raw_path).expanduser()
        if not folder.exists() or not folder.is_dir():
            raise HTTPException(status_code=400, detail=f"文件夹不存在或无法访问: {raw_path}")

        candidates = (
            [p for p in folder.rglob("*") if p.is_file()]
            if body.recursive
            else [p for p in folder.iterdir() if p.is_file()]
        )
        candidates = [p for p in candidates if detect_media_kind(p.name) is not None]
        candidates.sort(key=lambda p: natural_sort_key(p.name))

        added: list[dict[str, Any]] = []
        skipped: list[str] = []
        for file_path in candidates[:200]:
            try:
                item = _ingest_bytes(product_id, file_path.name, file_path.read_bytes())
                if item is not None:
                    added.append(item)
                else:
                    skipped.append(file_path.name)
            except Exception as exc:
                logger.warning("导入文件 %s 失败: %s", file_path, exc)
                skipped.append(file_path.name)

        if added:
            storage.record_event(
                "pc",
                "folder_imported",
                f"从文件夹导入 {len(added)} 个素材到「{prod['name']}」",
                {"folder": str(folder)},
            )
            await _notify_manifest_change()

        return {"added": added, "skipped": skipped, "state": await _build_full_state()}

    @app.post("/api/products/{product_id}/reorder")
    async def reorder_media(
        product_id: str, body: ReorderRequest
    ) -> dict[str, Any]:
        if storage.get_product(product_id) is None:
            raise HTTPException(status_code=404, detail="商品包不存在")
        items = storage.reorder_media(product_id, body.kind, body.ordered_ids)
        kind_label = "拍照图片" if body.kind == "photo" else "录制视频"
        storage.record_event("pc", "queue_reordered", f"已调整{kind_label}顺序")
        await _notify_manifest_change()
        return {"items": items, "state": await _build_full_state()}

    @app.delete("/api/media/{media_id}")
    async def delete_media(media_id: str) -> dict[str, Any]:
        item = storage.get_media(media_id)
        if not storage.delete_media(media_id):
            raise HTTPException(status_code=404, detail="素材不存在")
        storage.record_event(
            "pc",
            "media_deleted",
            f"移除素材：{item['original_name'] if item else media_id}",
        )
        await _notify_manifest_change()
        return {"ok": True, "state": await _build_full_state()}

    @app.get("/api/media/{media_id}/file")
    async def serve_media_file(media_id: str) -> FileResponse:
        item = storage.get_media(media_id)
        if item is None:
            raise HTTPException(status_code=404, detail="素材不存在")
        file_path = storage.media_dir / item["filename"]
        if not file_path.exists():
            raise HTTPException(status_code=404, detail="文件不存在")
        media_type = (
            "image/jpeg"
            if item["kind"] == "photo"
            else _guess_video_media_type(item["filename"])
        )
        return FileResponse(file_path, media_type=media_type)

    @app.get("/api/media/{media_id}/thumb")
    async def serve_media_thumb(media_id: str) -> FileResponse:
        item = storage.get_media(media_id)
        if item is None or not item["thumb_filename"]:
            raise HTTPException(status_code=404, detail="缩略图不存在")
        thumb_path = storage.thumbs_dir / item["thumb_filename"]
        if not thumb_path.exists():
            raise HTTPException(status_code=404, detail="缩略图文件不存在")
        return FileResponse(thumb_path, media_type="image/jpeg")

    @app.get("/api/queue/state")
    async def get_queue_state(request: Request) -> dict[str, Any]:
        return await _build_full_state(request=request)

    @app.patch("/api/queue/settings")
    async def update_queue_settings(body: QueueSettingsRequest) -> dict[str, Any]:
        patch = body.model_dump(exclude_none=True)
        photo_cursor = patch.pop("photo_cursor", None)
        video_cursor = patch.pop("video_cursor", None)

        if patch:
            config_manager.update_config(patch)
        active = storage.get_active_product()
        if photo_cursor is not None or video_cursor is not None:
            storage.set_cursors(
                active["id"],
                photo_cursor=photo_cursor,
                video_cursor=video_cursor,
                bump=False,
            )
        storage.bump_revision()
        storage.record_event("pc", "settings_updated", "已更新拍摄输出参数或序号游标")
        await _notify_manifest_change()
        return await _build_full_state()

    @app.post("/api/queue/step")
    async def step_queue(body: QueueStepRequest) -> dict[str, Any]:
        cfg = config_manager.get_config()
        active = storage.get_active_product()
        loop = cfg.loop_photos if body.kind == "photo" else cfg.loop_videos
        updated = storage.step_cursor(
            active["id"],
            body.kind,
            delta=body.delta,
            loop=loop,
            reset=body.reset,
        )
        label = "图片" if body.kind == "photo" else "视频"
        idx = (
            (updated["photo_cursor"] + 1)
            if body.kind == "photo" and updated
            else ((updated["video_cursor"] + 1) if updated else 1)
        )
        action_desc = "已重置到第 1 个" if body.reset else f"切换至第 {idx} 个"
        storage.record_event("pc", "cursor_stepped", f"电脑端将{label}队列{action_desc}")
        await _notify_manifest_change()
        return await _build_full_state()

    @app.post("/api/queue/push")
    async def push_queue() -> dict[str, Any]:
        rev = storage.bump_revision()
        storage.record_event("pc", "force_push", f"手动推送最新队列到手机 (v{rev})")
        await _notify_manifest_change(force_sync=True)
        return {"ok": True, "revision": rev, "state": await _build_full_state()}

    @app.get("/api/sync/manifest")
    async def get_sync_manifest(request: Request) -> dict[str, Any]:
        _verify_token_value(_extract_token(request))
        cfg = config_manager.get_config()
        return storage.build_manifest(cfg)

    async def _apply_device_event(
        payload: DeviceEventRequest, client_ip: str = ""
    ) -> dict[str, Any]:
        await hub.update_device_state(
            payload.device_id,
            device_name=payload.device_name,
            ios_version=payload.ios_version,
            ip=client_ip,
            sync_revision=payload.sync_revision,
            sync_status=payload.sync_status,
            target_apps=payload.target_apps,
        )
        active = storage.get_active_product()
        target_pid = payload.product_id or active["id"]
        if payload.photo_cursor is not None or payload.video_cursor is not None:
            storage.set_cursors(
                target_pid,
                photo_cursor=payload.photo_cursor,
                video_cursor=payload.video_cursor,
                bump=False,
            )

        msg = payload.message
        if not msg:
            if payload.event_type == "photo_captured":
                nxt = (payload.photo_cursor or 0) + 1
                msg = f"{payload.device_name} 完成点击拍摄，游标已推至第 {nxt} 张"
            elif payload.event_type == "video_recorded":
                msg = f"{payload.device_name} 完成长按录制视频替换"
            elif payload.event_type == "sync_status":
                msg = f"{payload.device_name} 同步状态：{payload.sync_status or 'ready'}"
            elif payload.event_type == "target_apps_updated":
                msg = f"{payload.device_name} 更新了目标 App 镜像列表"
            else:
                msg = f"{payload.device_name} 上报事件：{payload.event_type}"

        if payload.event_type != "ping":
            storage.record_event(
                "ios",
                payload.event_type,
                msg,
                {
                    "device_id": payload.device_id,
                    "photo_cursor": payload.photo_cursor,
                    "video_cursor": payload.video_cursor,
                    "sync_revision": payload.sync_revision,
                },
            )
        await _notify_ui_only()
        return {"ok": True}

    @app.post("/api/sync/device/event")
    async def post_device_event(
        payload: DeviceEventRequest, request: Request
    ) -> dict[str, Any]:
        _verify_token_value(_extract_token(request))
        client_ip = request.client.host if request.client else ""
        return await _apply_device_event(payload, client_ip=client_ip)

    @app.post("/api/system/shutdown")
    async def shutdown_server() -> JSONResponse:
        storage.record_event("pc", "system_shutdown", "用户关闭了桌面服务")

        def _exit_soon() -> None:
            time.sleep(0.25)
            os._exit(0)

        threading.Thread(target=_exit_soon, daemon=True).start()
        return JSONResponse({"ok": True})

    @app.websocket("/ws/ui")
    async def ws_ui(websocket: WebSocket) -> None:
        await websocket.accept()
        await hub.register_ui(websocket)
        try:
            await websocket.send_json(
                {"event": "state_updated", "state": await _build_full_state()}
            )
            while True:
                msg = await websocket.receive_json()
                if isinstance(msg, dict) and msg.get("type") == "ping":
                    await websocket.send_json({"event": "pong", "ts": time.time()})
        except WebSocketDisconnect:
            pass
        except Exception:
            pass
        finally:
            await hub.unregister_ui(websocket)

    @app.websocket("/ws/device")
    async def ws_device(websocket: WebSocket) -> None:
        token = websocket.query_params.get("token", "")
        expected = config_manager.get_config().pairing_token
        if not token or not hmac.compare_digest(token, expected):
            await websocket.close(code=4001)
            return

        device_id = websocket.query_params.get("device_id") or uuid.uuid4().hex[:8]
        device_name = websocket.query_params.get("device_name") or "iPhone"
        ios_version = websocket.query_params.get("ios_version") or "16.2"
        client_ip = websocket.client.host if websocket.client else ""

        await websocket.accept()
        await hub.register_device(
            device_id,
            websocket,
            device_name=device_name,
            ios_version=ios_version,
            ip=client_ip,
        )
        storage.record_event(
            "ios",
            "device_connected",
            f"{device_name} (iOS {ios_version}) 已连接到工作台",
            {"device_id": device_id, "ip": client_ip},
        )
        try:
            manifest = storage.build_manifest(config_manager.get_config())
            await websocket.send_json({"event": "manifest_updated", "manifest": manifest})
            await _notify_ui_only()

            while True:
                data = await websocket.receive_json()
                if not isinstance(data, dict):
                    continue
                msg_type = str(data.get("type") or data.get("event_type") or "ping")
                if msg_type == "ping":
                    await hub.update_device_state(device_id)
                    await websocket.send_json({"event": "pong", "ts": time.time()})
                    continue

                ev = DeviceEventRequest(
                    device_id=device_id,
                    device_name=str(data.get("device_name") or device_name),
                    ios_version=str(data.get("ios_version") or ios_version),
                    event_type=str(data.get("event_type") or msg_type),
                    product_id=data.get("product_id"),
                    photo_cursor=data.get("photo_cursor"),
                    video_cursor=data.get("video_cursor"),
                    sync_revision=data.get("sync_revision"),
                    sync_status=data.get("sync_status"),
                    target_apps=data.get("target_apps"),
                    message=str(data.get("message") or ""),
                    item_id=data.get("item_id"),
                )
                await _apply_device_event(ev, client_ip=client_ip)
        except WebSocketDisconnect:
            pass
        except Exception as exc:
            logger.debug("设备 WebSocket 连接断开 (%s): %s", device_id, exc)
        finally:
            await hub.unregister_device(device_id, websocket)
            storage.record_event("ios", "device_disconnected", f"{device_name} 已断开连接")
            await _notify_ui_only()

    return app


app = create_app()
