"""SQLite persistence for products, ordered photo/video queues, cursors, and activity logs."""

from __future__ import annotations

import contextlib
import json
import sqlite3
import threading
import time
import uuid
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from config import AppConfig


class StorageManager:
    """Thread-safe SQLite storage for VCam Sync Studio."""

    def __init__(self, data_dir: Path) -> None:
        self.data_dir = data_dir.resolve()
        self.media_dir = self.data_dir / "media"
        self.thumbs_dir = self.data_dir / "thumbs"
        self.db_path = self.data_dir / "studio.db"
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.media_dir.mkdir(parents=True, exist_ok=True)
        self.thumbs_dir.mkdir(parents=True, exist_ok=True)

        self._lock = threading.RLock()
        self._init_db()

    @contextlib.contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(str(self.db_path), timeout=15.0, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA foreign_keys=ON;")
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def _init_db(self) -> None:
        with self._lock, self._connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS products (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    note TEXT NOT NULL DEFAULT '',
                    active INTEGER NOT NULL DEFAULT 0,
                    photo_cursor INTEGER NOT NULL DEFAULT 0,
                    video_cursor INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS media_items (
                    id TEXT PRIMARY KEY,
                    product_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('photo', 'video')),
                    sort_order INTEGER NOT NULL,
                    filename TEXT NOT NULL,
                    thumb_filename TEXT NOT NULL DEFAULT '',
                    original_name TEXT NOT NULL,
                    sha256 TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    width INTEGER NOT NULL DEFAULT 0,
                    height INTEGER NOT NULL DEFAULT 0,
                    duration REAL NOT NULL DEFAULT 0.0,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(product_id) REFERENCES products(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_media_product_kind_order
                ON media_items(product_id, kind, sort_order);

                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL,
                    source TEXT NOT NULL,
                    event_type TEXT NOT NULL,
                    message TEXT NOT NULL,
                    detail_json TEXT NOT NULL DEFAULT '{}'
                );
                """
            )
            conn.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES('revision', '1')"
            )
            count = conn.execute("SELECT COUNT(*) FROM products").fetchone()[0]
            if count == 0:
                now = time.time()
                conn.execute(
                    """
                    INSERT INTO products(id, name, note, active, photo_cursor, video_cursor, created_at, updated_at)
                    VALUES(?, ?, ?, 1, 0, 0, ?, ?)
                    """,
                    (uuid.uuid4().hex[:12], "默认商品包", "点击上传图片和长按录制视频", now, now),
                )
            else:
                active_count = conn.execute(
                    "SELECT COUNT(*) FROM products WHERE active = 1"
                ).fetchone()[0]
                if active_count == 0:
                    first = conn.execute(
                        "SELECT id FROM products ORDER BY created_at ASC LIMIT 1"
                    ).fetchone()
                    if first:
                        conn.execute(
                            "UPDATE products SET active = 1 WHERE id = ?",
                            (first["id"],),
                        )

    def _bump_revision_tx(self, conn: sqlite3.Connection) -> int:
        row = conn.execute(
            "SELECT value FROM meta WHERE key = 'revision'"
        ).fetchone()
        rev = int(row["value"]) if row else 0
        rev += 1
        conn.execute(
            "INSERT OR REPLACE INTO meta(key, value) VALUES('revision', ?)",
            (str(rev),),
        )
        return rev

    def bump_revision(self) -> int:
        with self._lock, self._connect() as conn:
            return self._bump_revision_tx(conn)

    def get_revision(self) -> int:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT value FROM meta WHERE key = 'revision'"
            ).fetchone()
            return int(row["value"]) if row else 1

    def list_products(self) -> list[dict[str, Any]]:
        with self._lock, self._connect() as conn:
            rows = conn.execute(
                """
                SELECT p.*,
                    COALESCE((SELECT COUNT(*) FROM media_items m WHERE m.product_id = p.id AND m.kind = 'photo'), 0) AS photo_count,
                    COALESCE((SELECT COUNT(*) FROM media_items m WHERE m.product_id = p.id AND m.kind = 'video'), 0) AS video_count
                FROM products p
                ORDER BY p.created_at ASC
                """
            ).fetchall()
            return [dict(r) for r in rows]

    def get_product(self, product_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            return dict(row) if row else None

    def get_active_product(self) -> dict[str, Any]:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM products WHERE active = 1 LIMIT 1"
            ).fetchone()
            if row is None:
                row = conn.execute(
                    "SELECT * FROM products ORDER BY created_at ASC LIMIT 1"
                ).fetchone()
                if row is None:
                    now = time.time()
                    pid = uuid.uuid4().hex[:12]
                    conn.execute(
                        """
                        INSERT INTO products(id, name, note, active, photo_cursor, video_cursor, created_at, updated_at)
                        VALUES(?, ?, '', 1, 0, 0, ?, ?)
                        """,
                        (pid, "默认商品包", now, now),
                    )
                    row = conn.execute(
                        "SELECT * FROM products WHERE id = ?", (pid,)
                    ).fetchone()
                else:
                    conn.execute(
                        "UPDATE products SET active = 1 WHERE id = ?",
                        (row["id"],),
                    )
            return dict(row)

    def create_product(
        self, name: str, note: str = "", activate: bool = True
    ) -> dict[str, Any]:
        clean_name = (name or "").strip() or "未命名商品"
        clean_note = (note or "").strip()
        pid = uuid.uuid4().hex[:12]
        now = time.time()
        with self._lock, self._connect() as conn:
            if activate:
                conn.execute("UPDATE products SET active = 0")
            conn.execute(
                """
                INSERT INTO products(id, name, note, active, photo_cursor, video_cursor, created_at, updated_at)
                VALUES(?, ?, ?, ?, 0, 0, ?, ?)
                """,
                (pid, clean_name, clean_note, 1 if activate else 0, now, now),
            )
            if activate:
                self._bump_revision_tx(conn)
            row = conn.execute(
                "SELECT * FROM products WHERE id = ?", (pid,)
            ).fetchone()
            return dict(row)

    def update_product(
        self, product_id: str, name: str | None = None, note: str | None = None
    ) -> dict[str, Any] | None:
        with self._lock, self._connect() as conn:
            existing = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            if existing is None:
                return None
            new_name = (name.strip() if name is not None else existing["name"]) or existing["name"]
            new_note = note.strip() if note is not None else existing["note"]
            conn.execute(
                "UPDATE products SET name = ?, note = ?, updated_at = ? WHERE id = ?",
                (new_name, new_note, time.time(), product_id),
            )
            if existing["active"]:
                self._bump_revision_tx(conn)
            row = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            return dict(row)

    def activate_product(self, product_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect() as conn:
            existing = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            if existing is None:
                return None
            conn.execute("UPDATE products SET active = 0")
            conn.execute(
                "UPDATE products SET active = 1, updated_at = ? WHERE id = ?",
                (time.time(), product_id),
            )
            self._bump_revision_tx(conn)
            row = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            return dict(row)

    def delete_product(self, product_id: str) -> bool:
        files_to_remove: list[Path] = []
        with self._lock, self._connect() as conn:
            existing = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            if existing is None:
                return False
            media_rows = conn.execute(
                "SELECT filename, thumb_filename FROM media_items WHERE product_id = ?",
                (product_id,),
            ).fetchall()
            for r in media_rows:
                if r["filename"]:
                    files_to_remove.append(self.media_dir / r["filename"])
                if r["thumb_filename"]:
                    files_to_remove.append(self.thumbs_dir / r["thumb_filename"])

            conn.execute("DELETE FROM products WHERE id = ?", (product_id,))

            remaining = conn.execute(
                "SELECT id FROM products ORDER BY created_at ASC LIMIT 1"
            ).fetchone()
            if remaining is None:
                now = time.time()
                conn.execute(
                    """
                    INSERT INTO products(id, name, note, active, photo_cursor, video_cursor, created_at, updated_at)
                    VALUES(?, ?, '', 1, 0, 0, ?, ?)
                    """,
                    (uuid.uuid4().hex[:12], "默认商品包", now, now),
                )
            elif existing["active"]:
                conn.execute(
                    "UPDATE products SET active = 1 WHERE id = ?",
                    (remaining["id"],),
                )
            self._bump_revision_tx(conn)

        for path in files_to_remove:
            try:
                if path.exists():
                    path.unlink()
            except OSError:
                pass
        return True

    def list_media(
        self, product_id: str, kind: str | None = None
    ) -> list[dict[str, Any]]:
        with self._lock, self._connect() as conn:
            if kind:
                rows = conn.execute(
                    """
                    SELECT * FROM media_items
                    WHERE product_id = ? AND kind = ?
                    ORDER BY sort_order ASC, created_at ASC
                    """,
                    (product_id, kind),
                ).fetchall()
            else:
                rows = conn.execute(
                    """
                    SELECT * FROM media_items
                    WHERE product_id = ?
                    ORDER BY kind ASC, sort_order ASC, created_at ASC
                    """,
                    (product_id,),
                ).fetchall()
            return [dict(r) for r in rows]

    def get_media(self, media_id: str) -> dict[str, Any] | None:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM media_items WHERE id = ?", (media_id,)
            ).fetchone()
            return dict(row) if row else None

    def add_media(
        self,
        *,
        media_id: str,
        product_id: str,
        kind: str,
        filename: str,
        thumb_filename: str,
        original_name: str,
        sha256: str,
        size: int,
        width: int,
        height: int,
        duration: float,
    ) -> dict[str, Any]:
        now = time.time()
        with self._lock, self._connect() as conn:
            prod = conn.execute(
                "SELECT id, active FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            if prod is None:
                raise KeyError(f"Product not found: {product_id}")
            max_order_row = conn.execute(
                "SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM media_items WHERE product_id = ? AND kind = ?",
                (product_id, kind),
            ).fetchone()
            next_order = int(max_order_row["max_order"]) + 1
            conn.execute(
                """
                INSERT INTO media_items(
                    id, product_id, kind, sort_order, filename, thumb_filename,
                    original_name, sha256, size, width, height, duration, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    media_id,
                    product_id,
                    kind,
                    next_order,
                    filename,
                    thumb_filename,
                    original_name,
                    sha256,
                    size,
                    width,
                    height,
                    duration,
                    now,
                ),
            )
            conn.execute(
                "UPDATE products SET updated_at = ? WHERE id = ?",
                (now, product_id),
            )
            if prod["active"]:
                self._bump_revision_tx(conn)
            row = conn.execute(
                "SELECT * FROM media_items WHERE id = ?", (media_id,)
            ).fetchone()
            return dict(row)

    def reorder_media(
        self, product_id: str, kind: str, ordered_ids: list[str]
    ) -> list[dict[str, Any]]:
        with self._lock:
            with self._connect() as conn:
                prod = conn.execute(
                    "SELECT id, active FROM products WHERE id = ?", (product_id,)
                ).fetchone()
                if prod is None:
                    raise KeyError(f"Product not found: {product_id}")

                existing_rows = conn.execute(
                    """
                    SELECT id FROM media_items
                    WHERE product_id = ? AND kind = ?
                    ORDER BY sort_order ASC, created_at ASC
                    """,
                    (product_id, kind),
                ).fetchall()
                existing_ids = [r["id"] for r in existing_rows]
                existing_set = set(existing_ids)

                final_order: list[str] = []
                seen: set[str] = set()
                for mid in ordered_ids:
                    if mid in existing_set and mid not in seen:
                        final_order.append(mid)
                        seen.add(mid)
                for mid in existing_ids:
                    if mid not in seen:
                        final_order.append(mid)
                        seen.add(mid)

                for idx, mid in enumerate(final_order):
                    conn.execute(
                        "UPDATE media_items SET sort_order = ? WHERE id = ?",
                        (idx, mid),
                    )
                conn.execute(
                    "UPDATE products SET updated_at = ? WHERE id = ?",
                    (time.time(), product_id),
                )
                if prod["active"]:
                    self._bump_revision_tx(conn)

            return self.list_media(product_id, kind)

    def delete_media(self, media_id: str) -> bool:
        files_to_remove: list[Path] = []
        with self._lock, self._connect() as conn:
            item = conn.execute(
                "SELECT * FROM media_items WHERE id = ?", (media_id,)
            ).fetchone()
            if item is None:
                return False
            prod = conn.execute(
                "SELECT * FROM products WHERE id = ?", (item["product_id"],)
            ).fetchone()
            if item["filename"]:
                files_to_remove.append(self.media_dir / item["filename"])
            if item["thumb_filename"]:
                files_to_remove.append(self.thumbs_dir / item["thumb_filename"])

            conn.execute("DELETE FROM media_items WHERE id = ?", (media_id,))
            remaining = conn.execute(
                """
                SELECT id FROM media_items
                WHERE product_id = ? AND kind = ?
                ORDER BY sort_order ASC, created_at ASC
                """,
                (item["product_id"], item["kind"]),
            ).fetchall()
            for idx, r in enumerate(remaining):
                conn.execute(
                    "UPDATE media_items SET sort_order = ? WHERE id = ?",
                    (idx, r["id"]),
                )

            if prod is not None:
                cursor_col = "photo_cursor" if item["kind"] == "photo" else "video_cursor"
                cur = int(prod[cursor_col])
                if len(remaining) == 0:
                    cur = 0
                elif cur >= len(remaining):
                    cur = len(remaining) - 1
                conn.execute(
                    f"UPDATE products SET {cursor_col} = ?, updated_at = ? WHERE id = ?",
                    (cur, time.time(), prod["id"]),
                )
                if prod["active"]:
                    self._bump_revision_tx(conn)

        for path in files_to_remove:
            try:
                if path.exists():
                    path.unlink()
            except OSError:
                pass
        return True

    def set_cursors(
        self,
        product_id: str,
        *,
        photo_cursor: int | None = None,
        video_cursor: int | None = None,
        bump: bool = True,
    ) -> dict[str, Any] | None:
        with self._lock, self._connect() as conn:
            prod = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            if prod is None:
                return None

            new_photo = int(prod["photo_cursor"])
            new_video = int(prod["video_cursor"])

            if photo_cursor is not None:
                photo_count = conn.execute(
                    "SELECT COUNT(*) FROM media_items WHERE product_id = ? AND kind = 'photo'",
                    (product_id,),
                ).fetchone()[0]
                if photo_count <= 0:
                    new_photo = 0
                else:
                    new_photo = max(0, min(int(photo_cursor), photo_count - 1))

            if video_cursor is not None:
                video_count = conn.execute(
                    "SELECT COUNT(*) FROM media_items WHERE product_id = ? AND kind = 'video'",
                    (product_id,),
                ).fetchone()[0]
                if video_count <= 0:
                    new_video = 0
                else:
                    new_video = max(0, min(int(video_cursor), video_count - 1))

            conn.execute(
                "UPDATE products SET photo_cursor = ?, video_cursor = ?, updated_at = ? WHERE id = ?",
                (new_photo, new_video, time.time(), product_id),
            )
            if bump and prod["active"]:
                self._bump_revision_tx(conn)
            row = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            return dict(row)

    def step_cursor(
        self,
        product_id: str,
        kind: str,
        delta: int = 1,
        loop: bool = False,
        reset: bool = False,
    ) -> dict[str, Any] | None:
        with self._lock, self._connect() as conn:
            prod = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            if prod is None:
                return None

            count = conn.execute(
                "SELECT COUNT(*) FROM media_items WHERE product_id = ? AND kind = ?",
                (product_id, kind),
            ).fetchone()[0]
            cursor_col = "photo_cursor" if kind == "photo" else "video_cursor"
            cur = int(prod[cursor_col])

            if count <= 0 or reset:
                nxt = 0
            else:
                nxt = cur + delta
                if loop:
                    nxt = nxt % count
                else:
                    nxt = max(0, min(nxt, count - 1))

            conn.execute(
                f"UPDATE products SET {cursor_col} = ?, updated_at = ? WHERE id = ?",
                (nxt, time.time(), product_id),
            )
            if prod["active"]:
                self._bump_revision_tx(conn)
            row = conn.execute(
                "SELECT * FROM products WHERE id = ?", (product_id,)
            ).fetchone()
            return dict(row)

    def record_event(
        self,
        source: str,
        event_type: str,
        message: str,
        detail: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        ts = time.time()
        detail_str = json.dumps(detail or {}, ensure_ascii=False)
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                """
                INSERT INTO events(ts, source, event_type, message, detail_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                (ts, source, event_type, message, detail_str),
            )
            event_id = cur.lastrowid
            # Keep bounded event log
            conn.execute(
                """
                DELETE FROM events WHERE id NOT IN (
                    SELECT id FROM events ORDER BY id DESC LIMIT 200
                )
                """
            )
            return {
                "id": event_id,
                "ts": ts,
                "source": source,
                "event_type": event_type,
                "message": message,
                "detail": detail or {},
            }

    def list_events(self, limit: int = 50) -> list[dict[str, Any]]:
        with self._lock, self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,)
            ).fetchall()
            out: list[dict[str, Any]] = []
            for r in rows:
                try:
                    detail = json.loads(r["detail_json"])
                except Exception:
                    detail = {}
                out.append(
                    {
                        "id": r["id"],
                        "ts": r["ts"],
                        "source": r["source"],
                        "event_type": r["event_type"],
                        "message": r["message"],
                        "detail": detail,
                    }
                )
            return out

    def build_manifest(self, cfg: AppConfig) -> dict[str, Any]:
        """Build the canonical sync manifest matching VCamProtocol.h."""
        with self._lock:
            prod = self.get_active_product()
            photos_raw = self.list_media(prod["id"], "photo")
            videos_raw = self.list_media(prod["id"], "video")
            revision = self.get_revision()

            def fmt_item(item: dict[str, Any], idx: int) -> dict[str, Any]:
                return {
                    "id": item["id"],
                    "kind": item["kind"],
                    "order": idx,
                    "filename": item["filename"],
                    "original_name": item["original_name"],
                    "sha256": item["sha256"],
                    "size": item["size"],
                    "width": item["width"],
                    "height": item["height"],
                    "duration": item["duration"],
                    "url": f"/api/media/{item['id']}/file",
                    "thumb_url": (
                        f"/api/media/{item['id']}/thumb"
                        if item["thumb_filename"]
                        else ""
                    ),
                }

            photo_cursor = int(prod["photo_cursor"])
            if photos_raw:
                photo_cursor = max(0, min(photo_cursor, len(photos_raw) - 1))
            else:
                photo_cursor = 0

            video_cursor = int(prod["video_cursor"])
            if videos_raw:
                video_cursor = max(0, min(video_cursor, len(videos_raw) - 1))
            else:
                video_cursor = 0

            return {
                "version": 1,
                "revision": revision,
                "generated_at": time.time(),
                "enabled": cfg.enabled,
                "show_hud": cfg.show_hud,
                "fill_mode": cfg.fill_mode,
                "rotation": cfg.rotation,
                "mirror": cfg.mirror,
                "loop_photos": cfg.loop_photos,
                "loop_videos": cfg.loop_videos,
                "video_replace_mode": cfg.video_replace_mode,
                "product": {
                    "id": prod["id"],
                    "name": prod["name"],
                    "note": prod["note"],
                    "photo_cursor": photo_cursor,
                    "video_cursor": video_cursor,
                    "photos": [fmt_item(item, i) for i, item in enumerate(photos_raw)],
                    "videos": [fmt_item(item, i) for i, item in enumerate(videos_raw)],
                },
            }
