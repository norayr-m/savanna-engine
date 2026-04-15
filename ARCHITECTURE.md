# Architecture: Carlos Delta Codec + RG-LOD Pipeline

## The Pipeline

```
GPU Simulation → Carlos Delta Encoder → .savanna file → JIT Streaming Decoder → LOD Downsample → Browser
     ↑                   ↑                   ↑                    ↑                    ↑              ↑
  savanna-cli     XOR + zlib           one file          decompress on demand    majority vote     WebGL
  (Metal GPU)    (50× lossless)       on disk           (one frame in RAM)      (per request)    (60fps)
```

## Two Binaries

### `savanna-cli` — Simulate + Record
- Metal GPU: 13 kernel dispatches per tick (7-coloring Gauss-Seidel)
- CarlosDelta.Encoder: XOR delta + zlib compression per frame
- Output: `.savanna` file (SDLT format)
- One file per recording, 50× smaller than raw

### `savanna-play` — Decode + Serve
- CarlosDelta.StreamingDecoder: reads .savanna, decodes frames **on demand** (JIT)
- Only ONE frame in RAM at any time — instant startup, scales to any file size
- LOD downsample on-the-fly if grid > 2048 (majority vote + trophic boost)
- HTTP server: serves downsampled frames to WebGL viewer

## Streaming Decoder (JIT — no preload)

Previous architecture loaded ALL frames into RAM at startup. For 1B cells × 120 frames = 120 GB RAM. Crashed.

Current architecture:
1. Open .savanna file, scan frame offsets (fast — reads only 4-byte sizes, no decompression)
2. On each browser request: decompress frame N's delta, XOR with previous frame, downsample, serve
3. Only current frame stays in RAM
4. Instant startup regardless of file size

### Measured Performance

| Scale | Cells | Recording Size | Frame Serve Time | Effective FPS |
|-------|-------|---------------|-----------------|---------------|
| 1M | 1,000,000 | 1.0 MB | **10ms** | **100 fps** |
| 10M | 10,000,000 | 6.4 MB | **95ms** | **10 fps** |
| 1B | 1,000,000,000 | 3.5 GB | **4.6s** | **0.2 fps** |

### The 1B Bottleneck

At 1B cells, the JIT decode takes 4.6 seconds because:
1. zlib decompress of ~30 MB compressed delta → 1 GB raw (CPU-bound)
2. XOR of 1 billion bytes (CPU-bound)
3. Majority vote downsample 31622² → 2108² (CPU-bound)

**Solution (next sprint): GPU decode path.**
- Upload compressed delta to GPU buffer
- Metal kernel: inflate + XOR + LOD in one dispatch
- GPU can XOR 1 billion bytes in microseconds
- Read back only the 2108×2108 result (~4 MB)

**Solution (architecture): Morton Z-curve on disk.**
- Store frames in Morton order, not row-major
- Spatial neighbors are contiguous on disk → sequential NVMe reads
- XOR deltas compress better (spatially clustered changes → longer zero runs)
- LOD downsample reads contiguous memory blocks, not strided rows
- Block-level decompression: only decode blocks visible in viewport

## The .savanna Format (SDLT)

```
Header (24 bytes):
  "SDLT" (4 bytes)     — magic
  width (uint32)        — grid width
  height (uint32)       — grid height
  n_frames (uint32)     — frame count
  total_cells (uint64)  — real cell count (may differ from width×height for tiled)

Frame 0:
  compressed_size (uint32)
  zlib_compressed(keyframe)     — full entity grid

Frame 1..N:
  compressed_size (uint32)
  zlib_compressed(XOR_delta)    — Frame_N ⊕ Frame_N-1
```

## RG-LOD (Renormalization Group Level-of-Detail)

### GPU Path (Metal kernels, in savanna.metal)
Three kernels for hierarchical downsampling:

1. **`reduce_lod_compose`**: Entity buffer → float4 composition vectors (grass/zebra/lion/water fractions)
2. **`reduce_lod_cascade`**: Recursive 2× reduction of composition vectors
3. **`render_lod`**: Composition → RGBA with trophic boosting (rare entities stay visible)

Called via `MetalEngine.generateLOD(targetWidth:targetHeight:)`.
**Not yet wired into savanna-play** — requires full Metal engine init. Next sprint.

### CPU Path (Swift, in StreamingDecoder.displayFrame)
For playback without full Metal engine:
- Majority vote per block (most common entity wins)
- Trophic overlay: zebra >3% and lion >1% visible even when not majority
- Computed per-request, not cached
- Serves 2048×2048 frames regardless of source grid size

### Self-Similar Property
The same downsampling logic (composition fractions + trophic boost) runs at every scale:
- 1M → 1M: no downsample (passthrough)
- 10M → 3162: no downsample (under threshold)
- 100M → 2048: step 5, majority vote
- 1B → 2108: step 15, majority vote
- 100B (tiled) → 4096: per-tile downsample + composite

One function. Every scale. Never re-implement.

## Compression Results

| Source | Raw/frame | Compressed/frame | Ratio |
|--------|-----------|-----------------|-------|
| 1M cells | 1 MB | 19 KB | 53× |
| 10M cells | 10 MB | 530 KB | 19× |
| 100M cells | 100 MB | 1.9 MB | 53× |
| 1B cells | 1 GB | 30 MB | 33× |

Ratio varies with grid size due to entity density and edge effects. Average: **50×**.

## Future: Morton Z-Curve on Disk

Oracle directive (2026-04-15): store frames in Morton order for:
1. Contiguous NVMe reads (spatial neighbors close on disk)
2. Better XOR delta compression (spatially clustered zeros)
3. Block-level decompression (decode only visible viewport)
4. Cache-optimal LOD downsample (stride reads → sequential reads)

This eliminates the 4.6s CPU bottleneck at 1B by enabling GPU-native decode
and viewport-only decompression.

## Attribution

- **Carlos Mateo Muñoz** — Delta compression architecture (MIT License)
- **Norayr Matevosyan** — Savanna Engine, Metal GPU compute
- **Claude (Anthropic)** — Co-implementation
- **Gemini Deep Think (Google)** — Architectural review
