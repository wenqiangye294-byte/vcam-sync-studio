"""Pure-Python ISO/IEC 18004 QR Code encoder and SVG renderer (Versions 1-12, ECC M)."""

from __future__ import annotations

from html import escape

# (version, total_data_codewords, [(block_count, data_cw_per_block, ecc_cw_per_block), ...])
_VERSION_SPECS_M: list[tuple[int, int, list[tuple[int, int, int]]]] = [
    (1, 16, [(1, 16, 10)]),
    (2, 28, [(1, 28, 16)]),
    (3, 44, [(1, 44, 26)]),
    (4, 64, [(2, 32, 18)]),
    (5, 86, [(2, 43, 24)]),
    (6, 108, [(4, 27, 16)]),
    (7, 124, [(4, 31, 18)]),
    (8, 154, [(2, 38, 22), (2, 39, 22)]),
    (9, 182, [(3, 36, 22), (2, 37, 22)]),
    (10, 216, [(4, 43, 26), (1, 44, 26)]),
    (11, 254, [(1, 50, 30), (4, 51, 30)]),
    (12, 290, [(6, 36, 22), (2, 37, 22)]),
]

_ALIGNMENT_POSITIONS: dict[int, list[int]] = {
    1: [],
    2: [6, 18],
    3: [6, 22],
    4: [6, 26],
    5: [6, 30],
    6: [6, 34],
    7: [6, 22, 38],
    8: [6, 24, 42],
    9: [6, 26, 46],
    10: [6, 28, 50],
    11: [6, 30, 54],
    12: [6, 32, 58],
}

# GF(256) with primitive polynomial 0x11D
_GF_EXP = [0] * 512
_GF_LOG = [0] * 256
_x = 1
for _i in range(255):
    _GF_EXP[_i] = _x
    _GF_EXP[_i + 255] = _x
    _GF_LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D


def _gf_mul(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return _GF_EXP[_GF_LOG[a] + _GF_LOG[b]]


def _rs_generator(degree: int) -> list[int]:
    poly = [1]
    for i in range(degree):
        root = _GF_EXP[i]
        nxt = [0] * (len(poly) + 1)
        for j, coef in enumerate(poly):
            nxt[j] ^= coef
            nxt[j + 1] ^= _gf_mul(coef, root)
        poly = nxt
    return poly


def _rs_remainder(data: list[int], ecc_len: int) -> list[int]:
    gen = _rs_generator(ecc_len)
    rem = list(data) + [0] * ecc_len
    for i in range(len(data)):
        factor = rem[i]
        if factor != 0:
            for j in range(1, len(gen)):
                rem[i + j] ^= _gf_mul(gen[j], factor)
    return rem[len(data) :]


def _select_version(payload_len: int) -> tuple[int, int, list[tuple[int, int, int]]]:
    for version, total_data_cw, blocks in _VERSION_SPECS_M:
        char_count_bits = 8 if version <= 9 else 16
        capacity_bytes = (total_data_cw * 8 - 4 - char_count_bits) // 8
        if payload_len <= capacity_bytes:
            return version, total_data_cw, blocks
    raise ValueError(f"QR payload too long ({payload_len} bytes; max supported 287 bytes)")


def _encode_data_codewords(payload: bytes, version: int, total_data_cw: int) -> list[int]:
    bits: list[int] = []

    def append_bits(value: int, width: int) -> None:
        for shift in range(width - 1, -1, -1):
            bits.append((value >> shift) & 1)

    append_bits(0b0100, 4)  # Byte mode
    append_bits(len(payload), 8 if version <= 9 else 16)
    for b in payload:
        append_bits(b, 8)

    max_bits = total_data_cw * 8
    terminator_len = min(4, max_bits - len(bits))
    bits.extend([0] * terminator_len)

    while len(bits) % 8 != 0:
        bits.append(0)

    codewords: list[int] = []
    for i in range(0, len(bits), 8):
        val = 0
        for j in range(8):
            val = (val << 1) | bits[i + j]
        codewords.append(val)

    pad_bytes = (0xEC, 0x11)
    pad_idx = 0
    while len(codewords) < total_data_cw:
        codewords.append(pad_bytes[pad_idx % 2])
        pad_idx += 1

    return codewords


def _interleave_blocks(
    data_cw: list[int], blocks_spec: list[tuple[int, int, int]]
) -> list[int]:
    data_blocks: list[list[int]] = []
    ecc_blocks: list[list[int]] = []
    offset = 0
    for count, data_len, ecc_len in blocks_spec:
        for _ in range(count):
            blk = data_cw[offset : offset + data_len]
            offset += data_len
            data_blocks.append(blk)
            ecc_blocks.append(_rs_remainder(blk, ecc_len))

    result: list[int] = []
    max_data = max(len(b) for b in data_blocks)
    for col in range(max_data):
        for blk in data_blocks:
            if col < len(blk):
                result.append(blk[col])

    max_ecc = max(len(b) for b in ecc_blocks)
    for col in range(max_ecc):
        for blk in ecc_blocks:
            if col < len(blk):
                result.append(blk[col])
    return result


def _bch_format_bits(mask_id: int) -> int:
    # ECC M = 0b00
    data = (0b00 << 3) | (mask_id & 0b111)
    rem = data << 10
    for shift in range(14, 9, -1):
        if rem & (1 << shift):
            rem ^= 0x537 << (shift - 10)
    return ((data << 10) | rem) ^ 0x5412


def _golay_version_bits(version: int) -> int:
    rem = version << 12
    for shift in range(17, 11, -1):
        if rem & (1 << shift):
            rem ^= 0x1F25 << (shift - 12)
    return (version << 12) | rem


def _build_base_matrix(version: int) -> tuple[list[list[bool]], list[list[bool]]]:
    n = 17 + 4 * version
    modules = [[False] * n for _ in range(n)]
    reserved = [[False] * n for _ in range(n)]

    def set_fn(r: int, c: int, dark: bool) -> None:
        if 0 <= r < n and 0 <= c < n:
            modules[r][c] = dark
            reserved[r][c] = True

    def place_finder(top: int, left: int) -> None:
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                r, c = top + dr, left + dc
                if not (0 <= r < n and 0 <= c < n):
                    continue
                if dr in (-1, 7) or dc in (-1, 7):
                    set_fn(r, c, False)
                else:
                    dark = (
                        dr in (0, 6)
                        or dc in (0, 6)
                        or (2 <= dr <= 4 and 2 <= dc <= 4)
                    )
                    set_fn(r, c, dark)

    place_finder(0, 0)
    place_finder(0, n - 7)
    place_finder(n - 7, 0)

    # Timing patterns
    for i in range(8, n - 8):
        dark = i % 2 == 0
        set_fn(6, i, dark)
        set_fn(i, 6, dark)

    # Alignment patterns
    centers = _ALIGNMENT_POSITIONS[version]
    for r_c in centers:
        for c_c in centers:
            if (
                (r_c <= 8 and c_c <= 8)
                or (r_c <= 8 and c_c >= n - 9)
                or (r_c >= n - 9 and c_c <= 8)
            ):
                continue
            for dr in range(-2, 3):
                for dc in range(-2, 3):
                    dark = max(abs(dr), abs(dc)) != 1
                    set_fn(r_c + dr, c_c + dc, dark)

    # Dark module
    set_fn(4 * version + 9, 8, True)

    # Reserve format info cells (values applied per mask candidate)
    for i in range(9):
        if i != 6:
            reserved[8][i] = True
            reserved[i][8] = True
    for i in range(n - 8, n):
        reserved[8][i] = True
    for i in range(n - 7, n):
        reserved[i][8] = True

    # Version info for V7+
    if version >= 7:
        ver_bits = _golay_version_bits(version)
        for i in range(18):
            dark = bool((ver_bits >> i) & 1)
            a = n - 11 + (i % 3)
            b = i // 3
            set_fn(a, b, dark)
            set_fn(b, a, dark)

    return modules, reserved


def _apply_format_info(modules: list[list[bool]], mask_id: int) -> None:
    n = len(modules)
    fmt = _bch_format_bits(mask_id)
    # Bits 0..14
    for i in range(15):
        dark = bool((fmt >> i) & 1)
        # Copy 1: top-left (MSB 14 at (8,0) .. LSB 0 at (0,8))
        if i < 6:
            modules[i][8] = dark
        elif i < 8:
            modules[i + 1][8] = dark
        elif i == 8:
            modules[8][7] = dark
        else:
            modules[8][14 - i] = dark

        # Copy 2: bottom-left (MSB 14..8) & top-right (7..0)
        if i < 8:
            modules[8][n - 1 - i] = dark
        else:
            modules[n - 15 + i][8] = dark


def _mask_condition(mask_id: int, r: int, c: int) -> bool:
    if mask_id == 0:
        return (r + c) % 2 == 0
    if mask_id == 1:
        return r % 2 == 0
    if mask_id == 2:
        return c % 3 == 0
    if mask_id == 3:
        return (r + c) % 3 == 0
    if mask_id == 4:
        return ((r // 2) + (c // 3)) % 2 == 0
    if mask_id == 5:
        return ((r * c) % 2) + ((r * c) % 3) == 0
    if mask_id == 6:
        return (((r * c) % 2) + ((r * c) % 3)) % 2 == 0
    return (((r + c) % 2) + ((r * c) % 3)) % 2 == 0


def _penalty_score(modules: list[list[bool]]) -> int:
    n = len(modules)
    score = 0

    # Rule 1: 5+ consecutive same-color modules in rows/cols
    for is_row in (True, False):
        for i in range(n):
            run_color = None
            run_len = 0
            for j in range(n):
                val = modules[i][j] if is_row else modules[j][i]
                if val == run_color:
                    run_len += 1
                else:
                    if run_len >= 5:
                        score += 3 + (run_len - 5)
                    run_color = val
                    run_len = 1
            if run_len >= 5:
                score += 3 + (run_len - 5)

    # Rule 2: 2x2 blocks
    for r in range(n - 1):
        for c in range(n - 1):
            v = modules[r][c]
            if v == modules[r][c + 1] == modules[r + 1][c] == modules[r + 1][c + 1]:
                score += 3

    # Rule 3: 1:1:3:1:1 finder-like pattern with 4 light modules on either side
    pat1 = (True, False, True, True, True, False, True, False, False, False, False)
    pat2 = (False, False, False, False, True, False, True, True, True, False, True)
    for r in range(n):
        row = modules[r]
        for c in range(n - 10):
            seg = tuple(row[c : c + 11])
            if seg == pat1 or seg == pat2:
                score += 40
    for c in range(n):
        for r in range(n - 10):
            seg = tuple(modules[r + k][c] for k in range(11))
            if seg == pat1 or seg == pat2:
                score += 40

    # Rule 4: dark ratio deviation from 50%
    dark_count = sum(1 for row in modules for v in row if v)
    percent = (dark_count * 100) // (n * n)
    prev_mult5 = abs((percent // 5) * 5 - 50) // 5
    next_mult5 = abs(((percent // 5) * 5 + 5) - 50) // 5
    score += min(prev_mult5, next_mult5) * 10
    return score


def encode_qr_matrix(data: str) -> list[list[bool]]:
    """Encode a UTF-8 string into an ISO/IEC 18004 QR boolean matrix (True = dark)."""
    payload = data.encode("utf-8")
    version, total_data_cw, blocks_spec = _select_version(len(payload))
    data_cw = _encode_data_codewords(payload, version, total_data_cw)
    all_cw = _interleave_blocks(data_cw, blocks_spec)

    bit_stream: list[bool] = []
    for cw in all_cw:
        for shift in range(7, -1, -1):
            bit_stream.append(bool((cw >> shift) & 1))

    base_modules, reserved = _build_base_matrix(version)
    n = len(base_modules)

    # Place data bits in zigzag upward/downward two-column strips skipping col 6
    placed = [row[:] for row in base_modules]
    bit_idx = 0
    upward = True
    col = n - 1
    while col > 0:
        if col == 6:
            col -= 1
        rows = range(n - 1, -1, -1) if upward else range(n)
        for r in rows:
            for dc in (0, -1):
                c = col + dc
                if not reserved[r][c]:
                    if bit_idx < len(bit_stream):
                        placed[r][c] = bit_stream[bit_idx]
                        bit_idx += 1
                    else:
                        placed[r][c] = False
        upward = not upward
        col -= 2

    best_matrix: list[list[bool]] | None = None
    best_penalty = 1 << 30
    for mask_id in range(8):
        cand = [row[:] for row in placed]
        for r in range(n):
            for c in range(n):
                if not reserved[r][c] and _mask_condition(mask_id, r, c):
                    cand[r][c] = not cand[r][c]
        _apply_format_info(cand, mask_id)
        pen = _penalty_score(cand)
        if pen < best_penalty:
            best_penalty = pen
            best_matrix = cand

    assert best_matrix is not None
    return best_matrix


def generate_qr_svg(data: str, box_size: int = 8, border: int = 3) -> str:
    """Render an inline SVG QR code for the given payload."""
    matrix = encode_qr_matrix(data)
    n = len(matrix)
    dim = (n + border * 2) * box_size
    parts: list[str] = []
    for r, row in enumerate(matrix):
        for c, dark in enumerate(row):
            if dark:
                x = (c + border) * box_size
                y = (r + border) * box_size
                parts.append(f"M{x},{y}h{box_size}v{box_size}h-{box_size}z")
    path_d = "".join(parts)
    title = escape(data)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {dim} {dim}" '
        f'width="100%" height="100%" shape-rendering="crispEdges" role="img" '
        f'aria-label="{title}">'
        f'<rect width="{dim}" height="{dim}" fill="#ffffff"/>'
        f'<path d="{path_d}" fill="#111827"/>'
        f"</svg>"
    )
