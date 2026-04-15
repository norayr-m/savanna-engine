# Architecture: Carlos Delta Codec + RG-LOD Pipeline

## The Pipeline

```
GPU Simulation → Carlos Delta Encoder → .savanna file → Carlos Delta Decoder → GPU LOD → Browser
     ↑                   ↑                   ↑                    ↑              ↑          ↑
  savanna-cli     XOR + zlib           one file          XOR + inflate     downsample    WebGL
  (Metal GPU)    (50× lossless)       on disk           (at startup)     (at startup)   (60fps)
```

## Two Binaries

### `savanna-cli` — Simulate + Record
- Metal GPU: 13 kernel dispatches per tick
- CarlosDelta.Encoder: XOR delta + zlib compression per frame
- Output: `.savanna` file (SDLT format)
- One file per recording, 50× smaller than raw

### `savanna-play` — Decode + Serve
- CarlosDelta.Decoder: reads .savanna, decompresses all frames at startup
- **LOD Downsample**: if grid > 2048, pre-downsamples all frames (majority vote)
- HTTP server: serves downsampled frames to WebGL viewer
- 60fps playback at any source grid size

## The .savanna Format (SDLT)

```
Header (24 bytes):
  "SDLT" (4 bytes)     — magic
  width (uint32)        — grid width
  height (uint32)       — grid height
  n_frames (uint32)     — frame count
  total_cells (uint64)  — real cell count (may differ from width*height for tiled)

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

### CPU Path (Swift, in savanna-play)
For playback without full Metal engine:
- Majority vote per block (most common entity wins)
- Trophic overlay: zebra >3% and lion >1% visible even when not majority
- Pre-computed at startup, cached in RAM
- Serves 2048×2048 frames regardless of source grid size

### Self-Similar Property
The same downsampling logic (composition fractions + trophic boost) runs at every scale:
- 100M → 2048: same code
- 1B → 2048: same code
- 100B (tiled) → 4096: same code per tile, composited

One function. Every scale. Never re-implement.

## Compression Results

| Source | Raw/frame | Compressed/frame | Ratio |
|--------|-----------|-----------------|-------|
| 1M cells | 1 MB | 19 KB | 53× |
| 10M cells | 10 MB | 190 KB | 53× |
| 100M cells | 100 MB | 1.9 MB | 53× |
| 1B cells | 1 GB | 21 MB | 50× |

Ratio is consistent across scales because sparsity (98.7%) is a property of the ecosystem dynamics, not the grid size.

## Attribution

- **Carlos Mateo Muñoz** — Delta compression architecture (MIT License)
- **Norayr Matevosyan** — Savanna Engine, Metal GPU compute
- **Claude (Anthropic)** — Co-implementation
- **Gemini Deep Think (Google)** — Architectural review
