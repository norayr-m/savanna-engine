#!/usr/bin/env python3
"""
tile_server.py — Tiled playback server for Savanna Engine recordings.

Serves viewport-sized tiles from Morton-ordered recording files.
Infinitely scalable: works for 1M, 1B, or 1T cells identically.

The browser NEVER sees the full grid. It requests rectangles.
The server extracts, downsamples, and serves PNG tiles.

Endpoints:
  GET /                     → viewer HTML
  GET /info                 → recording metadata (JSON)
  GET /tile?frame=N&x=X&y=Y&w=W&h=H&zoom=Z  → PNG tile
  GET /frame_count          → number of frames

Usage:
  # Record simulation:
  swift run -c release savanna-cli --grid 32768 --ticks 20 --record savanna_rec/

  # Serve playback:
  python3 tile_server.py savanna_rec/ --port 8800
"""

import os
import io
import json
import struct
import sys
import mmap
import numpy as np
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from pathlib import Path
from threading import Lock

# Entity colors (RGBA)
PALETTE = np.array([
    [20, 15, 10, 255],     # 0: empty (dark)
    [60, 120, 30, 255],    # 1: grass (green)
    [240, 240, 240, 255],  # 2: zebra (white)
    [200, 80, 40, 255],    # 3: lion (red-orange)
    [40, 100, 200, 255],   # 4: water (blue)
], dtype=np.uint8)


class Recording:
    """Manages access to recorded frames on disk.

    Supports two modes:
    1. Single-tile: rec_dir contains frame_*.bin files directly
    2. Multi-tile: rec_dir contains tile_X_Y/ subdirectories (100B mode)
       Virtual world = tiles_x * tile_w × tiles_y * tile_h
    """

    def __init__(self, rec_dir: str):
        self.rec_dir = Path(rec_dir)
        self.meta = self._load_meta()
        self.multi_tile = 'tiles_x' in self.meta

        if self.multi_tile:
            self.tiles_x = self.meta['tiles_x']
            self.tiles_y = self.meta['tiles_y']
            self.tile_w = self.meta['tile_width']
            self.tile_h = self.meta['tile_height']
            self.width = self.tiles_x * self.tile_w
            self.height = self.tiles_y * self.tile_h
            self.frame_count = self.meta.get('ticks_per_tile', 5)
        else:
            self.tiles_x = 1
            self.tiles_y = 1
            self.tile_w = self.meta['width']
            self.tile_h = self.meta['height']
            self.width = self.meta['width']
            self.height = self.meta['height']
            self.frame_count = self.meta['frame_count']

        self.frame_bytes = self.width * self.height
        self._tile_cache = {}
        self._lock = Lock()

        # Memory-map for single-tile mode
        frames_path = self.rec_dir / 'frames.bin'
        if not self.multi_tile and frames_path.exists():
            self._frames_file = open(frames_path, 'rb')
            self._frames_mmap = mmap.mmap(
                self._frames_file.fileno(), 0, access=mmap.ACCESS_READ
            )
        else:
            self._frames_mmap = None

    def _load_meta(self) -> dict:
        meta_path = self.rec_dir / 'meta.json'
        if meta_path.exists():
            return json.loads(meta_path.read_text())
        frames = sorted(self.rec_dir.glob('frame_*.bin'))
        if not frames:
            raise FileNotFoundError(f'No frames in {self.rec_dir}')
        size = frames[0].stat().st_size
        side = int(size ** 0.5)
        return {'width': side, 'height': side, 'frame_count': len(frames)}

    def _load_tile_frame(self, tx: int, ty: int, frame_idx: int) -> np.ndarray:
        """Load one tile's frame, with caching."""
        cache_key = (tx, ty, frame_idx)
        with self._lock:
            if cache_key in self._tile_cache:
                return self._tile_cache[cache_key]

        tile_dir = self.rec_dir / f'tile_{tx}_{ty}'
        path = tile_dir / f'frame_{frame_idx:06d}.bin'
        if not path.exists():
            arr = np.zeros((self.tile_h, self.tile_w), dtype=np.uint8)
        else:
            arr = np.fromfile(path, dtype=np.uint8).reshape(self.tile_h, self.tile_w)

        with self._lock:
            self._tile_cache[cache_key] = arr
            if len(self._tile_cache) > 10:
                oldest = min(self._tile_cache.keys())
                del self._tile_cache[oldest]
        return arr

    def get_frame(self, frame_idx: int) -> np.ndarray:
        """Load a frame as a 2D numpy array.

        For multi-tile: returns a downsampled composite (max 4096×4096).
        For single-tile: returns the frame directly.
        """
        frame_idx = max(0, min(frame_idx, self.frame_count - 1))

        if not self.multi_tile:
            with self._lock:
                if frame_idx in self._tile_cache:
                    return self._tile_cache[('single', 0, frame_idx)]

            if self._frames_mmap:
                offset = frame_idx * self.tile_w * self.tile_h
                data = self._frames_mmap[offset:offset + self.tile_w * self.tile_h]
                arr = np.frombuffer(data, dtype=np.uint8).reshape(self.tile_h, self.tile_w)
            else:
                path = self.rec_dir / f'frame_{frame_idx:06d}.bin'
                if not path.exists():
                    return np.zeros((self.tile_h, self.tile_w), dtype=np.uint8)
                arr = np.fromfile(path, dtype=np.uint8).reshape(self.tile_h, self.tile_w)
            return arr

        # Multi-tile: build downsampled composite
        # Target: max 4096×4096 for the full world view
        max_display = 4096
        step_x = max(1, self.width // max_display)
        step_y = max(1, self.height // max_display)
        dw = self.width // step_x
        dh = self.height // step_y

        # Trophic priority for max-pooling
        TROPHIC = np.array([0, 2, 4, 5, 3], dtype=np.uint8)
        INVERSE = np.array([0, 1, 4, 2, 3], dtype=np.uint8)

        result = np.zeros((dh, dw), dtype=np.uint8)

        tile_dw = self.tile_w // step_x
        tile_dh = self.tile_h // step_y

        for ty in range(self.tiles_y):
            for tx in range(self.tiles_x):
                tile = self._load_tile_frame(tx, ty, frame_idx)
                # Downsample this tile with trophic max-pooling
                prioritized = TROPHIC[np.clip(tile, 0, 4)]
                th = (self.tile_h // step_y) * step_y
                tw = (self.tile_w // step_x) * step_x
                blocks = prioritized[:th, :tw].reshape(
                    th // step_y, step_y, tw // step_x, step_x
                )
                pooled = blocks.max(axis=(1, 3))
                downsampled = INVERSE[np.clip(pooled, 0, 4)]

                # Place into result
                oy = ty * tile_dh
                ox = tx * tile_dw
                h = min(downsampled.shape[0], dh - oy)
                w = min(downsampled.shape[1], dw - ox)
                result[oy:oy+h, ox:ox+w] = downsampled[:h, :w]

        return result

    def get_tile(self, frame_idx: int, x: int, y: int,
                 w: int, h: int, zoom: float) -> bytes:
        """Extract a viewport tile as PNG bytes.

        x, y: top-left corner in grid coordinates
        w, h: viewport size in pixels
        zoom: scale factor (1.0 = 1 pixel per cell, 0.01 = 100 cells per pixel)
        """
        frame = self.get_frame(frame_idx)

        # Calculate source rectangle in grid space
        src_w = int(w / max(zoom, 0.001))
        src_h = int(h / max(zoom, 0.001))

        # Clamp to grid bounds
        x = max(0, min(x, self.width - 1))
        y = max(0, min(y, self.height - 1))
        x2 = min(x + src_w, self.width)
        y2 = min(y + src_h, self.height)

        # Extract region
        region = frame[y:y2, x:x2]

        if region.size == 0:
            region = np.zeros((1, 1), dtype=np.uint8)

        # Downsample if zoomed out — Trophic Max-Pooling
        # Gemini fix: max() of ecological hierarchy, not stride-skip or mean
        # LION(3)=5 > ZEBRA(2)=4 > WATER(4)=3 > GRASS(1)=2 > EMPTY(0)=1
        # Guarantees rare apex predators survive extreme spatial compression
        if region.shape[0] > h or region.shape[1] > w:
            step_y = max(1, region.shape[0] // h)
            step_x = max(1, region.shape[1] // w)
            # Map entity values to trophic priority
            TROPHIC = np.array([0, 2, 4, 5, 3], dtype=np.uint8)  # [empty, grass, zebra, lion, water]
            INVERSE = np.array([0, 1, 4, 2, 3], dtype=np.uint8)  # priority back to entity
            prioritized = TROPHIC[np.clip(region, 0, 4)]
            # Block max-pool
            th = (region.shape[0] // step_y) * step_y
            tw = (region.shape[1] // step_x) * step_x
            blocks = prioritized[:th, :tw].reshape(th // step_y, step_y, tw // step_x, step_x)
            pooled = blocks.max(axis=(1, 3))
            # Map back to entity values
            region = INVERSE[np.clip(pooled, 0, 4)]

        # Colorize
        rgba = PALETTE[np.clip(region, 0, 4)]

        # Encode as raw RGBA (simple, no PIL dependency)
        # Use BMP format — simpler than PNG, browser handles it
        return self._encode_bmp(rgba)

    def _encode_bmp(self, rgba: np.ndarray) -> bytes:
        """Encode RGBA array as BMP."""
        h, w = rgba.shape[:2]
        # Convert RGBA to BGR (BMP format) — flip rows (BMP is bottom-up)
        bgr = np.flip(rgba[:, :, :3][:, :, ::-1], axis=0)
        row_size = (w * 3 + 3) & ~3  # Pad rows to 4-byte boundary
        pixel_size = row_size * h
        file_size = 54 + pixel_size

        header = struct.pack('<2sIHHI', b'BM', file_size, 0, 0, 54)
        info = struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0,
                          pixel_size, 2835, 2835, 0, 0)

        # Pad rows
        padded = bytearray()
        pad = b'\x00' * (row_size - w * 3)
        for row in bgr:
            padded.extend(row.tobytes())
            padded.extend(pad)

        return header + info + bytes(padded)


class TileHandler(BaseHTTPRequestHandler):
    recording: Recording = None
    viewer_html: str = ''
    serve_dir: str = '.'  # directory containing savanna_live.html etc.
    current_frame: int = 0
    display_width: int = 4096  # downsample large grids to this for savanna_live.html
    display_height: int = 2048

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == '/' or path == '/index.html':
            self._serve_html()
        elif path == '/info':
            self._serve_info()
        elif path == '/tile':
            self._serve_tile(params)
        elif path == '/frame_count':
            self._serve_text(str(self.recording.frame_count))
        # ── Savanna Live HTML compatibility ──
        elif path == '/savanna_live.html':
            self._serve_file('savanna_live.html', 'text/html')
        elif path.startswith('/savanna_state.bin'):
            self._serve_savanna_snapshot(params)
        elif path == '/savanna_telemetry.json':
            self._serve_savanna_telemetry()
        elif path == '/savanna_cmd.txt':
            self._serve_text('')  # no commands
        elif path == '/savanna_sleep.txt':
            # Playback speed: spread frames across ~30 seconds
            ms_per_frame = max(100, 30000 // max(1, self.recording.frame_count))
            self._serve_text(str(ms_per_frame))
        elif path == '/reset':
            self._serve_text('ok')
        else:
            # Try serving static files from serve_dir
            self._serve_file(path.lstrip('/'), None)

    def _serve_html(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(self.viewer_html.encode())

    def _serve_info(self):
        rec = self.recording
        info = {
            'width': rec.width,
            'height': rec.height,
            'frame_count': rec.frame_count,
            'cells': rec.width * rec.height,
            'total_cells': rec.meta.get('total_cells', rec.width * rec.height),
        }
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(info).encode())

    def _serve_tile(self, params):
        frame = int(params.get('frame', ['0'])[0])
        x = int(params.get('x', ['0'])[0])
        y = int(params.get('y', ['0'])[0])
        w = int(params.get('w', ['1920'])[0])
        h = int(params.get('h', ['1080'])[0])
        zoom = float(params.get('zoom', ['1.0'])[0])

        bmp = self.recording.get_tile(frame, x, y, w, h, zoom)

        self.send_response(200)
        self.send_header('Content-Type', 'image/bmp')
        self.send_header('Content-Length', str(len(bmp)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'max-age=60')
        self.end_headers()
        self.wfile.write(bmp)

    def _serve_text(self, text):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(text.encode())

    def _serve_file(self, filename, content_type=None):
        """Serve a static file from serve_dir."""
        filepath = Path(self.serve_dir) / filename
        if not filepath.exists():
            self.send_error(404)
            return
        if content_type is None:
            ext = filepath.suffix.lower()
            content_type = {
                '.html': 'text/html', '.js': 'application/javascript',
                '.css': 'text/css', '.json': 'application/json',
                '.png': 'image/png', '.gif': 'image/gif',
                '.wav': 'audio/wav', '.bin': 'application/octet-stream',
            }.get(ext, 'application/octet-stream')
        data = filepath.read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _serve_savanna_snapshot(self, params):
        """Serve a frame in savanna_state.bin format (header + entity bytes).

        Downsamples large grids to display_width × display_height.
        savanna_live.html reads this format natively.
        """
        rec = self.recording
        # For multi-tile, serve pre-computed thumbnail (skip get_frame — too slow)
        if rec.multi_tile:
            cf = TileHandler.current_frame
            TileHandler.current_frame = (cf + 1) % rec.frame_count
            thumb_path = rec.rec_dir / f'thumbnail_frame_{cf:06d}.bin'
            if thumb_path.exists():
                payload = thumb_path.read_bytes()
            else:
                # Fallback: empty frame
                dw, dh = 1024, 1024
                header = struct.pack('<IIII', dw, dh, TileHandler.current_frame, 1)
                payload = header + b'\x00' * (dw * dh)
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(payload)
            return

        # Single-tile path
        frame = rec.get_frame(TileHandler.current_frame)
        TileHandler.current_frame = (TileHandler.current_frame + 1) % rec.frame_count
        # Downsample if grid is larger than display size
        dw = min(rec.width, self.display_width)
        dh = min(rec.height, self.display_height)
        if rec.width > dw or rec.height > dh:
            step_x = rec.width // dw
            step_y = rec.height // dh
            # Helicopter LOD: majority vote (most common entity per block)
            # Then overlay: any zebra >5% → zebra, any lion >2% → lion
            th = (rec.height // step_y) * step_y
            tw = (rec.width // step_x) * step_x
            blocks = frame[:th, :tw].reshape(th // step_y, step_y, tw // step_x, step_x)
            flat = blocks.transpose(0, 2, 1, 3).reshape(th // step_y, tw // step_x, step_y * step_x)
            # Majority vote via bincount
            bh, bw, bs = flat.shape
            downsampled = np.zeros((bh, bw), dtype=np.uint8)
            for by in range(bh):
                for bx in range(bw):
                    downsampled[by, bx] = np.bincount(flat[by, bx], minlength=5).argmax()
            # Overlay: zebra herds and lion prides visible even when not majority
            zebra_frac = np.sum(flat == 2, axis=2) / bs
            lion_frac = np.sum(flat == 3, axis=2) / bs
            downsampled[zebra_frac > 0.03] = 2  # 3%+ zebra → visible
            downsampled[lion_frac > 0.01] = 3    # 1%+ lion → visible
            downsampled = downsampled[:dh, :dw]
        else:
            downsampled = frame
            dw, dh = rec.width, rec.height

        # Build savanna_state.bin format: 16-byte header + entity bytes
        header = struct.pack('<IIII', dw, dh, TileHandler.current_frame, 1)
        payload = header + downsampled.tobytes()

        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(payload)

    def _serve_savanna_telemetry(self):
        """Serve telemetry JSON for savanna_live.html stats panel."""
        rec = self.recording
        frame = rec.get_frame(max(0, TileHandler.current_frame - 1))
        # Quick census
        unique, counts = np.unique(frame, return_counts=True)
        census = dict(zip(unique.tolist(), counts.tolist()))

        telemetry = {
            'tick': TileHandler.current_frame,
            'day': TileHandler.current_frame // 4,
            'year': round(TileHandler.current_frame / 1460.0, 2),
            'ms': 522.0,  # placeholder for 1B
            'tps': 1,
            'speed': 1,
            'grass': census.get(1, 0),
            'zebra': census.get(2, 0),
            'lion': census.get(3, 0),
            'energy': 0,
            'dG': 0, 'dZ': 0, 'dL': 0,
            'ratio': round(census.get(2, 0) / max(1, census.get(3, 1)), 1),
            'grassPct': round(census.get(1, 0) / max(1, rec.width * rec.height) * 100, 1),
            'nodes': rec.width * rec.height,
            'colors': 7,
        }

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(telemetry).encode())

    def log_message(self, fmt, *args):
        pass  # Quiet


VIEWER_HTML = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Savanna Engine — Tiled Playback</title>
<style>
* { margin:0; padding:0; box-sizing:border-box; }
body { background:#050508; overflow:hidden; font-family:'Courier New',monospace; color:#a08030; }
canvas { display:block; width:100vw; height:100vh; cursor:grab; image-rendering:pixelated; }
#hud {
  position:fixed; top:10px; left:10px; z-index:10;
  background:rgba(5,5,8,0.8); padding:10px 16px; border-radius:4px;
  border:1px solid rgba(160,128,48,0.2); font-size:12px;
}
#hud .val { color:#d0b060; font-weight:bold; }
#controls {
  position:fixed; bottom:20px; left:50%; transform:translateX(-50%); z-index:10;
  display:flex; gap:10px; align-items:center;
}
#controls button {
  background:rgba(10,10,15,0.85); border:1px solid rgba(160,128,48,0.3);
  color:#d0b060; padding:8px 16px; cursor:pointer; border-radius:4px;
  font-family:inherit; font-size:12px;
}
#timeline {
  width:400px; accent-color:#d0b060;
}
</style>
</head>
<body>
<canvas id="c"></canvas>
<div id="hud">
  <div>Grid: <span class="val" id="h-grid">—</span></div>
  <div>Cells: <span class="val" id="h-cells">—</span></div>
  <div>Frame: <span class="val" id="h-frame">0</span> / <span class="val" id="h-total">0</span></div>
  <div>Zoom: <span class="val" id="h-zoom">1.00</span>x</div>
  <div>Viewport: <span class="val" id="h-vp">—</span></div>
</div>
<div id="controls">
  <button onclick="step(-1)">◀</button>
  <button onclick="togglePlay()" id="btn-play">▶ Play</button>
  <button onclick="step(1)">▶</button>
  <input type="range" id="timeline" min="0" max="1" value="0" step="1">
  <button onclick="resetView()">⊞ Fit</button>
</div>

<script>
const canvas = document.getElementById('c');
const ctx = canvas.getContext('2d');
let W, H;

let gridW = 1, gridH = 1, totalFrames = 1;
let frame = 0, playing = false, playInterval = null;
let camX = 0, camY = 0, zoom = 0.001;  // start zoomed out

let dragging = false, dragX = 0, dragY = 0;
let tileImg = new Image();
let loading = false;

function resize() {
  W = canvas.width = innerWidth;
  H = canvas.height = innerHeight;
  requestTile();
}
addEventListener('resize', resize);

// Fetch grid info
fetch('/info').then(r => r.json()).then(info => {
  gridW = info.width; gridH = info.height;
  totalFrames = info.frame_count;
  document.getElementById('h-grid').textContent = gridW + ' × ' + gridH;
  document.getElementById('h-cells').textContent =
    gridW * gridH >= 1e12 ? (gridW*gridH/1e12).toFixed(1) + 'T' :
    gridW * gridH >= 1e9 ? (gridW*gridH/1e9).toFixed(1) + 'B' :
    gridW * gridH >= 1e6 ? (gridW*gridH/1e6).toFixed(0) + 'M' :
    (gridW*gridH/1e3).toFixed(0) + 'K';
  document.getElementById('h-total').textContent = totalFrames;
  document.getElementById('timeline').max = totalFrames - 1;

  // Fit view
  zoom = Math.min(W / gridW, H / gridH);
  camX = (W - gridW * zoom) / 2;
  camY = (H - gridH * zoom) / 2;
  resize();
});

function requestTile() {
  if (loading) return;

  // Grid coords of viewport
  const gx = Math.max(0, Math.floor(-camX / zoom));
  const gy = Math.max(0, Math.floor(-camY / zoom));
  const tw = Math.min(Math.ceil(W / zoom), gridW - gx);
  const th = Math.min(Math.ceil(H / zoom), gridH - gy);

  // Request tile — server downsamples
  const maxPx = 2048;  // max pixels to request
  const reqW = Math.min(tw, maxPx);
  const reqH = Math.min(th, maxPx);
  const tileZoom = Math.min(reqW / Math.max(tw, 1), reqH / Math.max(th, 1));

  loading = true;
  const url = `/tile?frame=${frame}&x=${gx}&y=${gy}&w=${reqW}&h=${reqH}&zoom=${tileZoom}`;
  tileImg = new Image();
  tileImg.onload = () => {
    loading = false;
    // Draw
    ctx.fillStyle = '#050508';
    ctx.fillRect(0, 0, W, H);
    ctx.imageSmoothingEnabled = zoom >= 2;

    // Map tile back to screen coords
    const sx = camX + gx * zoom;
    const sy = camY + gy * zoom;
    const sw = tw * zoom;
    const sh = th * zoom;
    ctx.drawImage(tileImg, sx, sy, sw, sh);

    updateHUD();
  };
  tileImg.onerror = () => { loading = false; };
  tileImg.src = url;
}

function updateHUD() {
  document.getElementById('h-frame').textContent = frame;
  document.getElementById('h-zoom').textContent = zoom < 0.01 ?
    (1/zoom).toFixed(0) + ':1' : zoom.toFixed(2);
  const vpW = Math.floor(W / zoom);
  const vpH = Math.floor(H / zoom);
  document.getElementById('h-vp').textContent =
    vpW >= 1e6 ? (vpW/1e6).toFixed(1)+'M' : vpW >= 1e3 ? (vpW/1e3).toFixed(0)+'K' : vpW;
}

// Zoom
canvas.addEventListener('wheel', e => {
  e.preventDefault();
  const factor = e.deltaY > 0 ? 0.85 : 1.18;
  const mx = e.clientX, my = e.clientY;
  // Zoom centered on cursor
  camX = mx - (mx - camX) * factor;
  camY = my - (my - camY) * factor;
  zoom *= factor;
  zoom = Math.max(0.00001, Math.min(50, zoom));
  requestTile();
});

// Pan
canvas.addEventListener('mousedown', e => { dragging = true; dragX = e.clientX - camX; dragY = e.clientY - camY; canvas.style.cursor = 'grabbing'; });
canvas.addEventListener('mousemove', e => { if (!dragging) return; camX = e.clientX - dragX; camY = e.clientY - dragY; requestTile(); });
canvas.addEventListener('mouseup', () => { dragging = false; canvas.style.cursor = 'grab'; });

// Timeline
document.getElementById('timeline').addEventListener('input', e => {
  frame = parseInt(e.target.value);
  requestTile();
});

// Playback
function step(d) { frame = Math.max(0, Math.min(totalFrames-1, frame + d)); document.getElementById('timeline').value = frame; requestTile(); }
function togglePlay() {
  playing = !playing;
  document.getElementById('btn-play').textContent = playing ? '⏸ Pause' : '▶ Play';
  if (playing) { playInterval = setInterval(() => { if (frame < totalFrames-1) step(1); else togglePlay(); }, 500); }
  else { clearInterval(playInterval); }
}
function resetView() {
  zoom = Math.min(W / gridW, H / gridH);
  camX = (W - gridW * zoom) / 2;
  camY = (H - gridH * zoom) / 2;
  requestTile();
}

// Keyboard
addEventListener('keydown', e => {
  if (e.code === 'Space') { e.preventDefault(); togglePlay(); }
  if (e.code === 'ArrowLeft') step(-1);
  if (e.code === 'ArrowRight') step(1);
  if (e.code === 'KeyF') resetView();
  if (e.code === 'Equal') { zoom *= 1.5; requestTile(); }
  if (e.code === 'Minus') { zoom *= 0.67; requestTile(); }
});
</script>
</body>
</html>'''


def main():
    import argparse
    from socketserver import ThreadingMixIn

    class ThreadedHTTP(ThreadingMixIn, HTTPServer):
        daemon_threads = True

    parser = argparse.ArgumentParser(description='Savanna Tile Server')
    parser.add_argument('recording', help='Path to recording directory')
    parser.add_argument('--port', type=int, default=8800)
    parser.add_argument('--serve-dir', default=None,
                        help='Directory with savanna_live.html (auto-detected)')
    parser.add_argument('--display', type=int, default=2048,
                        help='Downsample large grids to NxN for savanna_live.html')
    args = parser.parse_args()

    rec = Recording(args.recording)

    # Auto-detect serve-dir: look for savanna_live.html
    serve_dir = args.serve_dir
    if not serve_dir:
        for candidate in [
            Path(args.recording).parent,
            Path(args.recording),
            Path('.'),
            Path(__file__).parent,
        ]:
            if (candidate / 'savanna_live.html').exists():
                serve_dir = str(candidate)
                break
    if not serve_dir:
        serve_dir = str(Path(__file__).parent)

    cells = rec.width * rec.height
    if cells >= 1e12:
        cell_str = f'{cells/1e12:.1f}T'
    elif cells >= 1e9:
        cell_str = f'{cells/1e9:.1f}B'
    elif cells >= 1e6:
        cell_str = f'{cells/1e6:.0f}M'
    else:
        cell_str = f'{cells/1e3:.0f}K'

    print(f'  ══════════════════════════════════════')
    print(f'  SAVANNA TILE SERVER')
    print(f'  Grid:     {rec.width} × {rec.height} ({cell_str} cells)')
    print(f'  Frames:   {rec.frame_count}')
    print(f'  Display:  {args.display}×{args.display} (downsampled)')
    print(f'  Serve:    {serve_dir}')
    print(f'  ──────────────────────────────────────')
    print(f'  Tile viewer:    http://localhost:{args.port}/')
    print(f'  Savanna Live:   http://localhost:{args.port}/savanna_live.html')
    print(f'  ══════════════════════════════════════')

    TileHandler.recording = rec
    TileHandler.viewer_html = VIEWER_HTML
    TileHandler.serve_dir = serve_dir
    TileHandler.display_width = args.display
    TileHandler.display_height = args.display

    httpd = ThreadedHTTP(('localhost', args.port), TileHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
