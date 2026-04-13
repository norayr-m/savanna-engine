# SPEC: Billion to Trillion — Tiled Simulation + Playback

## Goal

Run simulations from 1 billion (32K×32K) to 1 trillion (1M×1M) cells on a single M5 Max laptop. Record to disk. Play back with smooth zoom across 6 orders of magnitude in a browser.

## Architecture

### Three Components

```
1. Simulator (Swift/Metal)     → writes frames to disk
2. Tile Server (Python)        → reads frames, serves viewport tiles
3. Viewer (HTML/JS)            → requests tiles, renders canvas
```

All three are scale-agnostic. Same code for 1M, 1B, 1T.

### Simulation (existing engine + tiling)

**1 Billion (fits in RAM):**
- Grid: 32768 × 32768 = 1,073,741,824 cells
- State: ~76 GB (fits in 128 GB)
- Speed: 522 ms/tick (14.4 GCUPS)
- Recording: write entity buffer to disk per tick (1 GB raw, ~70 MB compressed)

**1 Trillion (tiled, sequential):**
- Grid: 1,000,000 × 1,000,000
- Tile size: 32768 × 32768 (1B cells) — fits in RAM
- Tiles: ~1000 (31×31 arrangement)
- Per tick: load tile → simulate → write back → next tile
- Speed: ~9 min/tick (1000 tiles × 522 ms)
- Boundary exchange: 1-cell halo between adjacent tiles

### Recording Format

```
recording_dir/
  meta.json          — {width, height, frame_count, seed, tick_start, ...}
  frames.bin         — concatenated frames (width × height bytes each)
                       OR individual frame_NNNNNN.bin files
```

For 1B: each frame = 1 GB. Morton-ordered on disk for spatial locality.
For 1T: each frame = 1 TB → use delta + zstd compression.

### Tile Server (tile_server.py — built)

```
GET /info                                    → grid metadata
GET /tile?frame=N&x=X&y=Y&w=W&h=H&zoom=Z   → BMP tile (viewport-sized)
GET /                                        → viewer HTML
```

Server reads recording, extracts viewport rectangle, downsamples for zoom level, serves as BMP. Browser never sees full grid. Always ~2 MB per tile regardless of grid size.

Morton ordering enables contiguous disk reads for any spatial rectangle.

### Viewer (HTML — built, needs savanna styling)

- Zoom: scroll wheel, cursor-centered
- Pan: click + drag
- Timeline: slider + arrow keys + space for play/pause
- F: fit whole grid to screen
- HUD: grid size, cell count, frame, zoom level, viewport size
- Scale-agnostic: same code for 1M and 1T

**To add from savanna_live.html:**
- Spacetime zoom: t ~ 1/x^1.5 (Levy superdiffusion)
- Population graphs (if census data available in meta)
- Color palette matching savanna theme
- Stats panel

## Performance Budget

### 1 Billion

| Phase | Time |
|-------|------|
| Simulation (20 ticks) | 10.4 sec |
| Recording (20 frames × 1 GB) | 20 GB on disk |
| Tile server startup | < 1 sec |
| Tile request latency | < 50 ms |
| **Total: simulate + browse** | **~12 sec** |

### 1 Trillion

| Phase | Time |
|-------|------|
| Simulation (20 ticks) | 3 hours |
| Recording (20 frames, delta+zstd) | ~140 GB on disk |
| Tile server startup | < 1 sec |
| Tile request latency | < 100 ms |
| **Total: overnight simulate, morning browse** | **3 hours + instant playback** |

## Storage Budget (4 TB SSD)

| Recording | Size | Fits |
|-----------|------|------|
| 1B × 20 frames (raw) | 20 GB | ✓ |
| 1B × 60 frames (raw) | 60 GB | ✓ |
| 1T × 20 frames (delta+zstd) | 140 GB | ✓ |
| 1T × 60 frames (delta+zstd) | 420 GB | ✓ |
| Multiple runs + parameter sweeps | 1-2 TB | ✓ |
| **Remaining after cleanup** | **2 TB free** | ✓ |

## Steps

### Phase 1: 1 Billion (now)
1. ✅ Tile server built and tested
2. Run savanna-cli at --grid 32768 with frame recording
3. Serve recording through tile server
4. Screen record zoom in/out playback → YouTube
5. Push to GitHub (tile_server.py + SPEC)

### Phase 2: Savanna-style viewer
1. Port savanna_live.html styling to tile viewer
2. Add spacetime zoom scaling
3. Add population graphs (if census in meta)

### Phase 3: Trillion (overnight run)
1. Build tiled simulator (load tile, simulate, write, next)
2. Add halo exchange for boundary cells
3. Add delta compression for recording
4. Run overnight → 140 GB recording
5. Play back next morning → YouTube

### Phase 4: Beyond
- 700 trillion (ultimate goal)
- Cluster mode (4× Mac Studios)
- Alternative kernels (Navier-Stokes, financial, liver)

## Key Insight

Morton Z-curve does triple duty:
1. **GPU compute**: 2× faster (cache-optimal neighbor reads)
2. **Disk storage**: contiguous writes for spatial tiles
3. **Tile serving**: contiguous reads for any viewport rectangle

One data structure. Three performance wins. Scale-agnostic.
