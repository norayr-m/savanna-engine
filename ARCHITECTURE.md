# Architecture: Carlos Delta Codec — Full Pipeline

## The Pipeline (v3 — Sparse Scatter)

```
RECORD (forward):
  Metal Sim → entity buffer (VRAM, Morton order)
           → XOR with prev frame
           → extract non-zero entries → sparse (index, value) pairs
           → write to NVMe (.savanna file)

PLAY (reverse):
  NVMe → read sparse pairs → GPU buffer (unified memory)
       → Metal kernel: scatter XOR into frame buffer
       → Metal kernel: de-Morton → row-major
       → Metal kernel: LOD downsample → 2048²
       → serve to browser (WebGL)

CPU touches ZERO cell data in playback. Only orchestrates GPU dispatches.
```

## Two Binaries

### `savanna-cli` — Simulate + Record
- Metal GPU: 13 kernel dispatches per tick (7-coloring Gauss-Seidel)
- CarlosDelta.Encoder: extracts sparse XOR entries per frame
- I-frame every 60 frames (zlib-compressed keyframe)
- P-frames: sparse scatter (non-zero entries only)
- Output: `.savanna` file (SDLT v3 format)

### `savanna-play` — Decode + Serve
- GPUDecoder: Metal-accelerated decode (preferred)
  - Sparse P-frames: GPU scatter kernel, zero CPU
  - I-frames: zlib decompress (CPU, rare — 1 per 60 frames)
  - De-Morton + LOD: GPU kernels
- StreamingDecoder: CPU fallback if no Metal
- HTTP server: serves frames to WebGL viewer

## I-Frame / P-Frame Architecture

Inspired by 3B-Backup-IP coprime rotation (same author).

- **I-frame** (keyframe): full frame, zlib compressed. Every 60 frames.
- **P-frame** (delta): only changed cells. Sparse scatter format.

Decoder seeks to nearest I-frame, replays at most 60 P-frames.
Random access: O(60) not O(N).

```
Frame:  0    1    2   ...  59   60   61  ...  119  120
Type:   I    P    P   ...  P    I    P   ...   P    I
        ↑                       ↑                   ↑
     keyframe              keyframe             keyframe
```

Seek to frame 95: jump to I-frame 60, replay 35 P-frames. Not 95.

## .savanna Format (SDLT v3)

```
Header (32 bytes):
  "SDLT" (4 bytes)           — magic
  width (uint32)             — grid width
  height (uint32)            — grid height
  n_frames (uint32)          — frame count
  total_cells (uint64)       — real cell count
  keyframe_interval (uint32) — I-frame every N frames (0 = only frame 0)
  format (uint32)            — 0 = zlib, 1 = sparse scatter

I-Frame:
  compressed_size (uint32)
  zlib_compressed(full_frame)

P-Frame (format=zlib):
  compressed_size (uint32)
  zlib_compressed(XOR_delta)

P-Frame (format=sparse):
  total_size (uint32)        — size of remaining data
  count (uint32)             — number of non-zero entries
  indices (uint32 × count)   — Morton indices of changed cells
  values (uint8 × count)     — XOR values at those indices
```

### Backward Compatibility

| Version | Header | Format | Morton | Keyframes |
|---------|--------|--------|--------|-----------|
| v1 | 24 bytes | zlib | row-major | frame 0 only |
| v2 | 28 bytes | zlib | Morton | periodic |
| v3 | 32 bytes | sparse or zlib | Morton | periodic |

Decoder auto-detects version from header size and format flag.

## Morton Z-Curve (End-to-End)

GPU buffers are Morton-ordered. Disk is Morton-ordered. Only de-Morton at the browser boundary.

```
GPU (Morton) → Encoder (Morton, no conversion) → Disk (Morton)
Disk (Morton) → Decoder (Morton) → de-Morton at output → Browser (row-major)
```

The de-Morton is a GPU kernel (`delta_demorton`), not CPU.

### Why Morton?
- Spatial neighbors are close in memory → better cache locality
- XOR deltas of spatially clustered changes → longer zero runs
- GPU kernels read sequential memory, not strided rows

## GPU Decode Kernels (savanna.metal)

| Kernel | Purpose | Input | Output |
|--------|---------|-------|--------|
| `delta_xor` | XOR delta into frame | frame + delta | frame (modified) |
| `delta_demorton` | Morton → row-major | Morton frame + mapping | row-major frame |
| `delta_lod_downsample` | Majority vote + trophic boost | full-res frame | 2048² display |
| `delta_sparse_scatter` | Sparse P-frame decode | frame + indices + values | frame (modified) |

Phase 1: CPU decompresses zlib, GPU does XOR + de-Morton + LOD.
Phase 2: sparse P-frames, GPU scatter directly. CPU only decompresses I-frames (rare).

## Sparse vs Zlib: Why Sparse Wins

XOR deltas are ~98.7% zeros (only cells that changed are non-zero).

**zlib approach**: Compress all N bytes including zeros. CPU-bound.
- Good compression (50×) but CPU must decompress every frame.
- At 100M cells: ~1s per frame decode.

**Sparse approach**: Don't store zeros. Store only (index, value) pairs.
- ~1.3% of cells change → 1.3M entries × 5 bytes = 6.5MB per frame (100M cells)
- GPU scatter kernel: microseconds
- No compression, no decompression, no CPU

zlib tries to find patterns in the non-zero bytes. But XOR deltas of a predator-prey simulation are random entropy — lions eating zebras, births, deaths. zlib burns CPU on incompressible data. Sparse just skips it.

## Compression Results

| Scale | Cells | Sparsity | Sparse P-frame | Zlib P-frame |
|-------|-------|----------|----------------|--------------|
| 1M | 1,000,000 | 98.7% | ~65 KB | ~19 KB |
| 10M | 10,000,000 | 98.7% | ~650 KB | ~530 KB |
| 100M | 100,000,000 | 98.7% | ~6.5 MB | ~1.9 MB |
| 1B | 1,000,000,000 | 98.7% | ~65 MB | ~30 MB |

Sparse files are ~2-3× larger. But decode is 1000× faster. NVMe reads the difference in milliseconds.

## Measured Decode Performance

| Scale | CPU (zlib) | GPU Phase 1 (zlib+GPU) | GPU Phase 2 (sparse) |
|-------|-----------|----------------------|---------------------|
| 1M | 10ms | ~1ms | ~0.1ms |
| 10M | 95ms | ~5ms | ~0.5ms |
| 100M | 1000ms | ~15ms | ~1ms |
| 1B | 4600ms | ~50ms | ~5ms |

Phase 2 eliminates the zlib CPU bottleneck entirely.

## File Layout on Disk

```
recording.savanna (one file, all frames):
  [32-byte header]
  [I-frame 0: zlib compressed]
  [P-frame 1: sparse scatter]
  [P-frame 2: sparse scatter]
  ...
  [P-frame 59: sparse scatter]
  [I-frame 60: zlib compressed]    ← new keyframe
  [P-frame 61: sparse scatter]
  ...
```

## Attribution

- **Carlos Mateo Muñoz** — Delta compression architecture (MIT License)
- **Norayr Matevosyan** — Savanna Engine, Metal GPU compute, sparse scatter codec
- **Claude** (Anthropic) — Co-implementation
- **Gemini Deep Think** (Google) — Architectural review
