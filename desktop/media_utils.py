"""Media processing, EXIF orientation normalization, and MP4 atom parsing."""

from __future__ import annotations

import hashlib
import io
import re
import struct
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v"}


def natural_sort_key(text: str) -> list[tuple[int, int | str]]:
    """Return a sort key that orders embedded integers numerically."""
    parts = re.split(r"(\d+)", text)
    key: list[tuple[int, int | str]] = []
    for part in parts:
        if not part:
            continue
        if part.isdigit():
            key.append((0, int(part)))
        else:
            key.append((1, part.lower()))
    return key


def detect_media_kind(filename: str, content_type: str = "") -> str | None:
    """Return 'photo' or 'video' from extension or MIME type, or None if unsupported."""
    ext = Path(filename).suffix.lower()
    if ext in IMAGE_EXTS:
        return "photo"
    if ext in VIDEO_EXTS:
        return "video"
    ct = (content_type or "").lower()
    if ct.startswith("image/"):
        return "photo"
    if ct.startswith("video/"):
        return "video"
    return None


def compute_sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compute_sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fp:
        while True:
            chunk = fp.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def process_image_bytes(raw: bytes, dest_path: Path, thumb_path: Path) -> dict[str, Any]:
    """Normalize image orientation/colorspace to baseline JPEG and create a 360px thumbnail."""
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    thumb_path.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(io.BytesIO(raw)) as img:
        img = ImageOps.exif_transpose(img)
        if img.mode in ("RGBA", "LA", "PA") or (
            img.mode == "P" and "transparency" in img.info
        ):
            rgba = img.convert("RGBA")
            bg = Image.new("RGB", rgba.size, (255, 255, 255))
            bg.paste(rgba, mask=rgba.split()[3])
            rgb = bg
        else:
            rgb = img.convert("RGB")

        width, height = rgb.size
        buf = io.BytesIO()
        rgb.save(buf, format="JPEG", quality=92, subsampling=0, optimize=True)
        jpeg_bytes = buf.getvalue()

        thumb = rgb.copy()
        thumb.thumbnail((360, 360), Image.Resampling.LANCZOS)
        thumb_buf = io.BytesIO()
        thumb.save(thumb_buf, format="JPEG", quality=82, optimize=True)
        thumb_bytes = thumb_buf.getvalue()

    tmp_dest = dest_path.with_suffix(dest_path.suffix + ".tmp")
    tmp_dest.write_bytes(jpeg_bytes)
    tmp_dest.replace(dest_path)

    tmp_thumb = thumb_path.with_suffix(thumb_path.suffix + ".tmp")
    tmp_thumb.write_bytes(thumb_bytes)
    tmp_thumb.replace(thumb_path)

    return {
        "sha256": compute_sha256_bytes(jpeg_bytes),
        "size": len(jpeg_bytes),
        "width": width,
        "height": height,
        "duration": 0.0,
    }


def _iter_boxes(data: bytes, start: int, end: int):
    pos = start
    while pos + 8 <= end:
        size32 = struct.unpack(">I", data[pos : pos + 4])[0]
        box_type = data[pos + 4 : pos + 8]
        header_len = 8
        if size32 == 1:
            if pos + 16 > end:
                break
            box_size = struct.unpack(">Q", data[pos + 8 : pos + 16])[0]
            header_len = 16
        elif size32 == 0:
            box_size = end - pos
        else:
            box_size = size32
        if box_size < header_len or pos + box_size > end:
            break
        yield box_type, pos + header_len, pos + box_size
        pos += box_size


def parse_mp4_metadata(raw: bytes) -> dict[str, Any]:
    """Extract duration, width, height from ISO BMFF (MP4/MOV) headers in pure Python."""
    duration = 0.0
    width = 0
    height = 0

    try:
        for top_type, top_start, top_end in _iter_boxes(raw, 0, len(raw)):
            if top_type != b"moov":
                continue
            for sub_type, sub_start, sub_end in _iter_boxes(raw, top_start, top_end):
                if sub_type == b"mvhd" and sub_end - sub_start >= 24:
                    version = raw[sub_start]
                    if version == 0 and sub_end - sub_start >= 20:
                        timescale, raw_dur = struct.unpack(
                            ">II", raw[sub_start + 12 : sub_start + 20]
                        )
                        if timescale > 0:
                            duration = round(raw_dur / timescale, 3)
                    elif version == 1 and sub_end - sub_start >= 32:
                        timescale, raw_dur = struct.unpack(
                            ">IQ", raw[sub_start + 20 : sub_start + 32]
                        )
                        if timescale > 0:
                            duration = round(raw_dur / timescale, 3)
                elif sub_type == b"trak":
                    tk_w = 0
                    tk_h = 0
                    is_video = False
                    for t_type, t_start, t_end in _iter_boxes(raw, sub_start, sub_end):
                        if t_type == b"tkhd":
                            version = raw[t_start]
                            if version == 0 and t_end - t_start >= 84:
                                w_fp, h_fp = struct.unpack(
                                    ">II", raw[t_start + 76 : t_start + 84]
                                )
                                tk_w, tk_h = w_fp >> 16, h_fp >> 16
                            elif version == 1 and t_end - t_start >= 96:
                                w_fp, h_fp = struct.unpack(
                                    ">II", raw[t_start + 88 : t_start + 96]
                                )
                                tk_w, tk_h = w_fp >> 16, h_fp >> 16
                        elif t_type == b"mdia":
                            for m_type, m_start, m_end in _iter_boxes(raw, t_start, t_end):
                                if m_type == b"hdlr" and m_end - m_start >= 12:
                                    if raw[m_start + 8 : m_start + 12] == b"vide":
                                        is_video = True
                    if is_video or (tk_w > 0 and tk_h > 0 and width == 0):
                        if tk_w > 0 and tk_h > 0:
                            width = tk_w
                            height = tk_h
    except Exception:
        pass

    return {"duration": duration, "width": width, "height": height}


def process_video_bytes(raw: bytes, dest_path: Path) -> dict[str, Any]:
    """Save video file atomically and extract SHA-256 + basic MP4/MOV metadata."""
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_dest = dest_path.with_suffix(dest_path.suffix + ".tmp")
    tmp_dest.write_bytes(raw)
    tmp_dest.replace(dest_path)

    meta = parse_mp4_metadata(raw)
    return {
        "sha256": compute_sha256_bytes(raw),
        "size": len(raw),
        "width": int(meta["width"]),
        "height": int(meta["height"]),
        "duration": float(meta["duration"]),
    }
