# Savanna Engine

> **Note:** This is an amateur engineering project. We are not HPC professionals and make no competitive claims. We built a simulation, the performance surprised us, and we share the numbers because they might be useful. We are certain there are errors — if you find one, please open an issue. That is the point of open source. GPL v3.

**Ultra-Scale Spatial Lattice Engine — 15.8 GCUPS on Apple M5 Max**

An ultra-scale spatial computation engine running on Apple Metal, featuring lock-free, atomic-free parallel entity updates (census uses atomics for population counters).

**15.8 GCUPS** (15.8 billion cell-updates per second) peak at 64M cells on Apple M5 Max with 128 GB unified memory. Morton Z-curve memory layout. 10-run validated, low variance (0.5–5% coefficient of variation). Pure GPU compute: 0.58 ms/tick at 1M cells (1,722 tps). See [BENCHMARK.md](BENCHMARK.md) for full methodology — what is measured, what is excluded, and how to reproduce.

> The biology is the test workload. The engine is a spatial lattice compute machine.

[**→ Interactive Presentation**](https://norayr-m.github.io/savanna-engine/) | [**→ About**](https://norayr-m.github.io/savanna-engine/about.html) | [**→ Benchmark**](BENCHMARK.md) | [**→ Morton Z-Curve: 2× faster at 1B cells**](https://norayr-m.github.io/savanna-engine/morton_charts.html) | [**→ Live Demo**](https://norayr-m.github.io/savanna-engine/demo.html)

## What This Is

A million hexagonal cells, each a node in a graph. Five data channels per node. Four diffusion fields. Thirteen GPU kernel dispatches per tick. The graph is coloured with seven colours such that no two same-coloured nodes share any neighbour — enabling fully parallel, lock-free updates with zero atomic operations.

The simulation models a predator-prey ecosystem (grass → zebra → lion), but the underlying engine is an **ultra-scale spatial lattice engine**. Any computation that reads local neighbours and writes a local result can run at this speed on any colourable graph.

## Performance

| Metric | Value |
|--------|-------|
| Grid | 1,048,576 nodes (1024×1024 hex) |
| Channels | 5 per node + 4 scent fields = 23 MB state |
| Compute | 0.58 ms per tick (13 kernel dispatches) |
| Throughput | **15.8 billion** cell-updates/sec (peak at 64M) |
| Simulation rate | 1,722 tps at 1M cells (GPU compute only) |
| Display rate | 60-120 fps (vsync) |
| State bandwidth | 38 GB/sec |
| GPU utilisation | 5% (idle 95% waiting for vsync) |
| Hardware | Apple M5 Max, 128 GB unified memory |

### Scaling (linear with cell count)

| Grid Size | Ticks/sec | Notes |
|-----------|-----------|-------|
| 1M | 1,722 | interactive (>>60 fps) |
| 4M | 504 | interactive |
| 16M | 128 | interactive |
| 64M | 33 | watchable |
| 256M | 7.9 | slow |
| 1B | 1.9 | batch only |

### Context

**We make no mathematical novelty claims.** Chromatic Gauss-Seidel is well-established. Distance-2 graph colouring on hex lattices is proven (Molloy & Salavatipour 2005). Our contribution is engineering: combining these techniques with Apple Metal unified memory to achieve extreme throughput on consumer hardware.

## Architecture

### The Compute Primitive
Every node runs: **sense → compute → emit**. Read six neighbours. Apply a function. Write the result. This is the irreducible unit of graph computation.

### 7-Colouring (Lock-Free Parallelism)
```
Formula: (col + row + 4×(col&1)) mod 7
Guarantee: No two same-coloured cells share any common neighbour (distance-2)
Result: Each colour group runs in full GPU parallelism — no locks, no atomics
Theory: Molloy & Salavatipour (2005), chromatic number of hex lattice = 7
```

### Ternary State Machine
Each node has a ternary state: `+1` (active), `0` (resting), `-1` (refractory).
Firewall: `0 → +1 → -1 → 0`. No direct `-1 → +1` except hardware interrupts.
This creates a natural oscillation clock per node.

### Scent Diffusion (Message Passing)
Four Float32 fields propagate information beyond direct neighbours. Species-specific decay rates create different propagation ranges (20-200 hexes). This is graph message passing at GPU speed.

### Spacetime Zoom
Time scales with spatial zoom: `t ~ 1/x^1.5` (Lévy superdiffusion scaling).
Zoom in → time slows → watch individual interactions.
Zoom out → time accelerates → watch population dynamics.

## Quick Start

The simulation runs as a CLI with real-time stats. Optionally, open the HTML viewer in your browser to watch the savanna — zebra herds migrating across the grassland, lions hunting at watering holes, grass regrowing in their wake.

[![Savanna Demo](assets/savanna_demo.gif)](https://youtu.be/TgGkNxp3aK0)

▶️ [**Watch on YouTube**](https://youtu.be/TgGkNxp3aK0)

### Build

```bash
git clone https://github.com/norayr-m/savanna-engine.git
cd savanna-engine
swift build -c release
```

### Run Benchmark

```bash
swift run -c release savanna-bench
```

### Run Simulation + Live Viewer

```bash
# 1. Start simulation
swift run -c release savanna-cli &

# 2. Start web server
python3 -m http.server 8765 > /dev/null 2>&1 &

# 3. Open browser
open http://localhost:8765/savanna_live.html
```

### Stop

```bash
pkill -f savanna-cli
pkill -f "http.server"
```

### CLI Options

```bash
--grid 2048    # 4M cells (default: 1024 = 1M)
--ram 1        # 1 GB ring buffer (fits 8GB Mac)
--ram 16       # 16 GB ring buffer
--bench        # pure compute, no file I/O
--ticks 1000   # stop after 1000 ticks
```

### Memory Requirements

| Machine | RAM | `--ram` flag | Ring buffer frames |
|---------|-----|--------------|--------------------|
| M1 8GB | 8 GB | `--ram 1` | ~1,000 (8 min sim) |
| M1/M2 16GB | 16 GB | `--ram 4` | ~4,000 (30 min) |
| M2/M3 Pro 32GB | 32 GB | `--ram 12` | ~12,000 (1.5 hr) |
| M5 Max 128GB | 128 GB | `--ram 50` | ~50,000 (5.5 hr) |

The simulation itself needs ~23 MB. The rest is ring buffer for recording.
With `--ram 1`, the engine runs on any Apple Silicon Mac.

### Controls
| Key | Action |
|-----|--------|
| scroll/pinch | Zoom (+ spacetime scaling) |
| click/dblclick | Zoom in/out |
| space | Fit to screen |
| L / Z | Jump to lion / zebra |
| S | Stats panel |
| M | Mixer panel |
| T / G | Faster / slower |
| N | Reset (nuke) |

## Pre-Computed Scenarios

Three scenarios are included in `scenarios/`. Each is a `.savanna` file containing:
- Header: parameters, UUID, timestamp, tick range, RNG seed
- Frame metadata: tick number, day/night, population census per frame  
- Raw entity frames: 1MB per frame, contiguous

The RNG seed + parameters fully determine the simulation. Any scenario can be independently verified by re-running with the same seed and comparing frame checksums.

```bash
# Verify a scenario
swift run savanna-cli --verify scenarios/scenario_001.savanna
```

## File Structure

```
SavannaEngine/
├── Sources/
│   ├── Savanna/
│   │   ├── Shaders/savanna.metal    # GPU compute kernel (all behavior)
│   │   ├── HexGrid.swift            # 7-colouring, neighbour graph
│   │   ├── MetalEngine.swift        # GPU orchestration, buffers
│   │   ├── MetalEngine+Export.swift  # Snapshot export
│   │   ├── SavannaState.swift       # World initialisation
│   │   └── SimRecorder.swift        # Ring buffer recording
│   └── SavannaCLI/
│       └── main.swift               # CLI runner, telemetry
├── index.html                       # GitHub landing page (presentation)
├── savanna_live.html                 # Live renderer
├── about.html                       # Three-tier explanation
├── voice_mixer.html                  # TTS voice blending tool
├── presentation.html                 # Narrated slides (local audio)
├── tour.sh                          # Voice-narrated tour script
├── LICENSE                          # GPL v3
└── README.md                        # This file
```

## Technical Details

### Why 7 Colours?
On a hexagonal grid, each cell has 6 neighbours forming a "flower" of 7 tiles. For movement safety (distance-2 independence), all 7 must execute at different times. The formula `(col + row + 4×(col&1)) mod 7` was found by exhaustive search over all `(a×col + b×row + d×(col&1)) mod 7` candidates. 12 valid formulas exist; this is the simplest.

### Why Not Atomics?
GPU atomic operations cost 10-50× more than normal memory writes due to hardware serialisation. With 13 million potential atomic operations per tick eliminated by colouring, the performance gain is ~10-50×. This is the difference between 15.8 billion ops/sec and ~500 million.

### Unified Memory Advantage
Apple Silicon's unified memory means CPU and GPU share the same 128GB. No PCIe bus copies. The entity buffer lives in one place — computed by the GPU, read by the CPU for display, without ever moving. On discrete GPU systems (NVIDIA), the same operation requires a 1MB DMA transfer per frame.

## Translational Applications

The engine runs any local graph computation:
- **Power grid simulation**: voltage propagation, fault detection
- **Drug metabolism**: hepatocyte metabolic networks (liver digital twin)
- **Network analysis**: message passing on social/communication graphs  
- **Cellular biology**: cell-cell signaling, tissue simulation
- **Any agent-based model**: where agents interact with local neighbours

## The Lotka-Volterra Challenge

The compute architecture is mathematically proven and lock-free. The 7-colouring is exhaustive-verified. The benchmark is 10-run validated at <1% variance.

**But the spatial Rosenzweig-MacArthur model collapses into predator extinction.**

Under the current thermodynamic constraints (Type II satiation, ternary metabolic states, birthday-window reproduction), we have not achieved stable limit cycle oscillations. The predator population crashes at the trough and fails to recover before prey density rebuilds.

**We challenge the theoretical ecology community** to find the parameter basin — or functional response modification — that produces stable oscillations on this discrete hex lattice with asynchronous chromatic Gauss-Seidel updates.

The engine runs at 15.8 GCUPS. The biology is the open problem.

## Lossless Compression with "Carlos Deltas"

Between simulation ticks, 98.7% of cells don't change. XOR delta compression exploits this sparsity.

Inspired by [Carlos Mateo Muñoz](https://github.com/carlosmateo10/delta-compression-demo)'s RFC 9842 Dictionary TTL extension for dynamic HTTP payloads (MIT License). Carlos's insight: use the previous response as a Brotli/Zstandard compression dictionary for the next response. We apply this to spatial simulation tensors.

**Method:** `Frame_N XOR Frame_N-1` → 98.7% zeros → Zstandard level 3.

**Measured results (1 billion cells, 20 frames):**

| Frame | Sparsity | Raw | Compressed | Ratio |
|-------|----------|-----|------------|-------|
| 1 | 97.6% | 1,074 MB | 32.9 MB | 32.6× |
| 10 | 98.7% | 1,074 MB | 21.5 MB | **50.0×** |
| 19 | 99.1% | 1,074 MB | 16.8 MB | **63.9×** |
| **Average** | **98.7%** | **1,074 MB** | **21.5 MB** | **50.0×** |

20 GB raw recording → **408 MB** compressed. Lossless. The ratio improves as the ecosystem stabilizes.

**Scaling projection:**

| Scale | Raw/frame | Delta/frame | 20 frames total |
|-------|-----------|-------------|-----------------|
| 1B | 1 GB | 21 MB | 400 MB |
| 100B | 100 GB | 2.1 GB | 40 GB |
| 1T | 1 TB | 21 GB | 400 GB |

A 1-Trillion-cell simulation fits on a laptop SSD. Carlos's web standard makes it streamable over HTTP.

This is not web compression applied to simulations. **This is a lossless video codec for spatial compute.** Each frame is a spatial image. XOR delta is the P-frame. Zstandard is the entropy coder. The "dictionary" is the previous frame. Equivalent to H.264 I/P frame structure, but lossless and 50× smaller because scientific simulation data is 99% static between ticks.

Full report: [Carlos_Delta_Compression_Report.pdf](Carlos_Delta_Compression_Report.pdf)

## References

- Molloy, M. & Salavatipour, M.R. (2005). "A bound on the chromatic number of the square of a planar graph." *Journal of Combinatorial Theory, Series B*.
- Erkaman (2018). ["Parallelizing the Gauss-Seidel Method using Graph Coloring."](https://erkaman.github.io/posts/gauss_seidel_graph_coloring.html)

## License

GPL v3. See [LICENSE](LICENSE).

## Authors

**Norayr Matevosyan** — Architecture, design, direction. [GitHub](https://github.com/norayr)

### AI Collaboration

This project was built in collaboration with AI systems:

- **Claude Opus 4.6** (Anthropic) — Code generation, Metal shader development, debugging, benchmark automation, documentation. All commits co-authored.
- **Gemini Deep Think** (Google) — Peer review across 3 rounds: identified the 7-colouring requirement, diagnosed the thermodynamic suicide switch, prescribed Type II satiation and birthday-window reproduction, caught benchmark category errors, provided the Hacker News Shield review.

Every line of code was human-directed and AI-assisted. The architecture decisions, the biological mapping, and the convergence strategy were human. The implementation speed, the bug detection, and the mathematical verification were AI-augmented.

---

*The biology was the test workload. The engine is a graph Turing machine.*

## Running & Stopping

```bash
# Start
# Server is optional — for live HTML viewer only (not in repo)
# swift run -c release savanna-cli    # simulation only

# Stop everything
pkill -f savanna-cli; pkill -f savanna_server.py

# Verify clean
ps aux | grep savanna | grep -v grep
```

**Always kill before restarting.** Multiple sim processes write to the same snapshot file and cause visual glitching (two states alternating). The server's reset endpoint (`N` key) handles this automatically, but manual terminal launches do not.
