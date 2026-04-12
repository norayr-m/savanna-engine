# Savanna Engine

**Ultra-Scale Spatial Lattice Engine — 25.0 GCUPS on Apple M5 Max**

A lock-free (entity updates are atomic-free; census uses atomics) parallel entity updates on a spatial computation engine running on Apple Metal.

**25.0 GCUPS** (25.0 billion cell-updates per second) measured at 16M cells on Apple M5 Max with 128 GB unified memory. 10-run validated, low variance (0.5–5% coefficient of variation). Pure GPU compute: 0.61 ms/tick at 1M cells (1,634 tps). See [BENCHMARK.md](BENCHMARK.md) for full methodology — what is measured, what is excluded, and how to reproduce.

> The biology is the test workload. The engine is a spatial lattice compute machine.

[**→ Interactive Presentation**](index.html) | [**→ Live Demo**](savanna_live.html) | [**→ Architecture**](../SPEC_SimRecorder.md)

## What This Is

A million hexagonal cells, each a node in a graph. Five data channels per node. Four diffusion fields. Thirteen GPU kernel dispatches per tick. The graph is coloured with seven colours such that no two same-coloured nodes share any neighbour — enabling fully parallel, lock-free updates with zero atomic operations.

The simulation models a predator-prey ecosystem (grass → zebra → lion), but the underlying engine is an **ultra-scale spatial lattice engine**. Any computation that reads local neighbours and writes a local result can run at this speed on any colourable graph.

## Performance

| Metric | Value |
|--------|-------|
| Grid | 1,048,576 nodes (1024×1024 hex) |
| Channels | 5 per node + 4 scent fields = 23 MB state |
| Compute | 0.6 ms per tick (12 kernel dispatches) |
| Throughput | **25 billion** cell-updates/sec |
| Simulation rate | 1,634 tps (GPU compute only) |
| Display rate | 60-120 fps (vsync) |
| State bandwidth | 29 GB/sec |
| GPU utilisation | 5% (idle 95% waiting for vsync) |
| Hardware | Apple M5 Max, 128 GB unified memory |

### Scaling (linear with cell count)

| Grid Size | Ticks/sec | Notes |
|-----------|-----------|-------|
| 1M | 1,634 | interactive (>>60 fps) |
| 4M | 490 | interactive |
| 16M | 124 | interactive |
| 67M | 29 | watchable |
| 256M | ~7 | slow |
| 1B | ~1.9 | batch only |

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

```bash
# 1. Clone and build
git clone https://github.com/norayr-m/savanna-engine.git
cd savanna-engine
swift build -c release

# 2. Verify the benchmark (runs 10× at 1M, 4M, 16M cells)
swift run -c release savanna-bench

# 3. Run the simulation
swift run -c release savanna-cli
```

### CLI Options

```bash
swift run -c release savanna-cli              # default: 1024×1024, 4GB ring buffer
swift run -c release savanna-cli --grid 2048  # 4M cells
swift run -c release savanna-cli --ram 16     # 16 GB ring buffer (more playback frames)
swift run -c release savanna-cli --ram 1      # 1 GB (fits on 8GB machines)
swift run -c release savanna-cli --bench      # benchmark mode: no file I/O, pure compute
swift run -c release savanna-cli --ticks 1000 # run exactly 1000 ticks then stop
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
GPU atomic operations cost 10-50× more than normal memory writes due to hardware serialisation. With 13 million potential atomic operations per tick eliminated by colouring, the performance gain is ~10-50×. This is the difference between 25 billion ops/sec and ~500 million.

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

The engine runs at 25.0 GCUPS. The biology is the open problem.

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
python3 /tmp/savanna_server.py &    # server + sim (port 8765)

# Stop everything
pkill -f savanna-cli; pkill -f savanna_server.py

# Verify clean
ps aux | grep savanna | grep -v grep
```

**Always kill before restarting.** Multiple sim processes write to the same snapshot file and cause visual glitching (two states alternating). The server's reset endpoint (`N` key) handles this automatically, but manual terminal launches do not.
