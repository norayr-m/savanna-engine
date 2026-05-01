# Savanna Engine — Architecture, Build Approach, and Overcomes

> **Humble disclaimer.** Amateur engineering project. We are not HPC professionals and make no competitive claims. The numbers come from one M5 Max laptop, no controlled benchmark, no peer review. Errors are likely. The work is openly in progress; this paper is honest about what is solved, what is wired but not validated, and what was attempted and is not yet there.

GPLv3.

---

## Contents

- [What it is](#what-it-is)
- [Architecture](#architecture)
  - [Hex grid and 7-coloring](#hex-grid-and-7-coloring)
  - [Lock-free chromatic dispatch](#lock-free-chromatic-dispatch)
  - [Pipeline](#pipeline)
- [Build approach](#build-approach)
  - [Metal kernels per tick](#metal-kernels-per-tick)
  - [Morton Z-curve memory layout](#morton-z-curve-memory-layout)
  - [Lazy mipmap tiles for trillion-cell scale](#lazy-mipmap-tiles-for-trillion-cell-scale)
- [Overcomes](#overcomes)
  - [NW ghost wind — Murmur3 avalanche fix](#1-nw-ghost-wind--murmur3-avalanche-fix)
  - [Chromatic Gauss-Seidel wind — shuffled dispatch](#2-chromatic-gauss-seidel-wind--shuffled-dispatch)
  - [Predator death spiral — Type II satiation](#3-predator-death-spiral--type-ii-satiation)
  - [CFL violation — Nyquist clamp on dt-compression](#4-cfl-violation--nyquist-clamp-on-dt-compression)
  - [Trophic max-pooling — why mean and mode both fail](#5-trophic-max-pooling--why-mean-and-mode-both-fail)
  - [Atto-Fox — discrete truncation at low N](#6-atto-fox--discrete-truncation-at-low-n)
  - [Lévy α tunability — configurable diffusion exponent](#7-lévy-α-tunability--configurable-diffusion-exponent)
  - [Pride mitosis vs zebra birthday window](#8-pride-mitosis-vs-zebra-birthday-window)
- [References and acknowledgments](#references-and-acknowledgments)

---

## What it is

A million hexagonal cells, each a node in a graph. Five data channels per node. Four diffusion fields. Thirteen Metal compute-kernel dispatches per tick. Lock-free, atomic-free parallel updates of every entity in every cell, on every tick, on the GPU. The biology — grass, zebras, lions, watering holes — is the test workload. The engine underneath is a general spatial lattice computer.

The numbers, on a single Apple M5 Max laptop with 128 GB unified memory: 0.58 ms per tick at 1 M cells; 1,722 ticks per second of pure GPU compute at the same scale; peak throughput of 15.8 billion cell-updates per second at 64 M cells. Linear scaling beyond, validated to 64 M cells in interactive mode and to 100 B cells in playback. 10-run methodology, low variance (0.5–5 % coefficient of variation). Full reproducible procedure in [`BENCHMARK.md`](BENCHMARK.md).

This paper covers three things, in order: the architectural choices that make those numbers possible at all, the build moves that turned the architecture into runnable code, and the engineering overcomes — the bugs caught and fixed and the design errors avoided, named honestly.

---

## Architecture

### Hex grid and 7-coloring

Every cell has six neighbours, a hex-grid arrangement. The reason this matters is parallel update safety. If a kernel updates cell `c` while another kernel is reading or writing one of `c`'s neighbours, you have a data race — atomically resolved or you get garbage. The standard fix is locks or atomics; both are expensive on GPU.

The trick is graph coloring. Assign a colour to every cell so that no two cells of the same colour are adjacent (or even within a 2-distance neighbourhood, since one cell reads its own neighbours when computing). Then dispatch the kernel one colour at a time: every cell of colour 0 in parallel, then every cell of colour 1, and so on. Cells of the same colour never touch each other's data, so no atomics are needed.

For the hex lattice with the 2-distance safety condition, **seven colours suffice**. The proof goes via the chromatic-number bound for the square of a planar graph: by Molloy and Reed's local-bound results, refined by Salavatipour (2005) for planar graphs of bounded maximum degree, the chromatic index of the squared hex lattice is exactly 7. The colour formula in the engine is

```
color(col, row) = (col + row + 4·(col & 1)) % 7
```

which produces a clean, periodic 7-colouring with no boundary defects on a wrap-around torus. The 7-colouring is *topologically clean* — there are no jagged colour scars, no Euler-defect cells, no need for fix-ups at the boundary. That cleanness is what shows up in the macroscopic behaviour as perfect isotropy: when a wave of activity expands across the grid (described in the next section's pipeline), it expands as a smooth circular front, not as a jagged diamond. If the colouring had directional bias, the isotropy would break.

### Lock-free chromatic dispatch

Each tick is a sequence of seven colour-passes. Within a pass, the GPU runs every cell of that colour in parallel via a single Metal compute kernel dispatch. Because no two same-coloured cells share neighbours, the parallel writes never conflict. No atomics. No locks. The entire spatial update is `7 × (parallel kernel launch)`.

There is one place where atomics are unavoidable: the per-tick population census needs running counters, and that requires atomic increments because every colour pass might add to the same counter. The counters are isolated to a single page, and the atomic cost is paid once per cell, not once per update. The non-atomic property of the entity update itself is preserved.

### Pipeline

The full Savanna pipeline, end to end:

```
GPU Simulation → Carlos Delta Encoder → .savanna file → Carlos Delta Decoder → GPU LOD → Browser
     ↑                  ↑                    ↑                    ↑               ↑          ↑
  savanna-cli    XOR + zlib (50× lossless)  one file        XOR + inflate      downsample   WebGL
  (Metal GPU)         at runtime           on disk           at startup        at startup    60fps
```

The simulation runs entirely on the GPU; the encoder serializes per-tick deltas using XOR against the previous frame and compresses each frame with zlib (lossless, around 50× compression in practice for the biology workload); a single `.savanna` file holds the whole run; the decoder reverses the encoder; a level-of-detail pass downsamples for the chosen viewport; the browser renders 60 fps WebGL playback. The encoder is the [Carlos Delta](BENCHMARK.md) compression pattern — XOR-against-previous + standard compression, separately developed and credited.

---

## Build approach

### Metal kernels per tick

Each tick runs **13 Metal compute-kernel dispatches** in sequence:

- 1 dispatch for the per-cell environmental scent diffusion (4 fields)
- 7 dispatches, one per colour, for the cell-state update (entity logic)
- 1 dispatch for the population census (atomic counters)
- 1 dispatch for the per-cell entity birth/death finalize
- 1 dispatch for the spatial map render snapshot
- 2 dispatches for auxiliary buffer rotations

Total runtime at 1 M cells: 0.58 ms per tick measured end-to-end on the GPU (excluding host I/O). The GPU sits at around 5 % utilisation at the interactive grid sizes; the remaining 95 % is idle waiting for vsync. The headroom is what makes the bigger grids possible — at 64 M cells the GPU still delivers 60+ fps while saturating the kernel pipeline.

### Morton Z-curve memory layout

Adjacent cells in space need to be adjacent in memory, otherwise the L2 cache thrashes on every neighbour fetch. The standard 2D row-major layout puts horizontal neighbours close (`row[col]` and `row[col+1]` are one stride apart) but vertical neighbours far (one full row away — many cache lines for a wide grid). The hex grid has six neighbours, three of which fall into the "vertical" category in a row-major scheme.

The Morton Z-curve solves this by interleaving the bits of `(col, row)`. Two cells with addresses that differ by a small number of bit-positions are physically close in 2D space; equivalently, the 2D 8-neighbour Hamming ball maps to a small, contiguous index range in Morton order. The Morton-ordered layout puts hex neighbours into the same L2 cache line for the great majority of access patterns.

The benchmarked impact: a **2.11× speedup at 1 B cells**, holding the rest of the simulation fixed. That is pure computer-science speedup from spatial locality — no hardware change, no kernel change, just bit-interleaving the storage order. The flat scaling curve out to a billion cells is the secondary effect: the cache stays warm because the working set size scales with the *effective* working set (a small Hamming ball around the current cell) rather than with the *grid* size.

### Lazy mipmap tiles for trillion-cell scale

The 1 B cell run fits in 60 GB of disk after Carlos Delta compression, written in 90 seconds. The 1 T cell run does not fit in laptop RAM at all and would not fit in any contiguous on-disk layout for interactive playback.

The temptation, for a viewer, is to assemble per-frame: read one row from each of 1,000 tile files sequentially, paste them into a 1 TB monolithic frame, then downsample. That assembly costs **32,000 random I/O operations per frame** — a top-tier Apple SSD maxes at around a million random IOPS, so the budget burns on context-switch overhead before any compute happens.

The fix is the same one Google Earth uses: do not assemble. The tile files *are* the database. When the HTML viewer requests a viewport, the server calculates which 1–4 tile files intersect the box, `mmap`s only those files, and reads the contiguous Morton chunks. For deep zoom-outs the server cannot read 1,000 files on the fly, so during the overnight simulation the GPU computes downsampled macro-tiles (1/4, 1/16, 1/64 scale) at write-time and writes them to disk as an image pyramid alongside the full-resolution tiles. The viewer serves pre-computed overview chunks at deep zoom; assembly is never required.

This is the single architectural decision that makes the trillion-cell horizon viable on consumer hardware. The fix arrived early — credit to Gemini Deep Think for spotting the I/O-death-spiral category error at design time, before the wrong code was written.

---

## Overcomes

This is the engineering teardown — the bugs that were caught, the design choices that survived adversarial review, and the corrections folded back into the engine. They are listed in roughly the order in which they were found.

### 1. NW ghost wind — Murmur3 avalanche fix

**Symptom.** Lions, on aggregate, drift north-west across the grid over many ticks. Population centres-of-mass move on a chiral diagonal even when the underlying biology is rotationally symmetric.

**Diagnosis.** The direction-pick code used a multiplicative LCG hash:

```
dir_offset = (node × 2654435761u ^ tick × 374761393u) % 6u
```

Multiplying by an *odd* prime preserves the lowest bit of the input. The Morton code's lowest bit is *column parity*. Modulo 6 (even) also preserves parity. The result: even columns always evaluate even directions first (NE, NW, S), odd columns always evaluate odd directions first (N, SW, SE). On a six-way tie (zero scent gradient), the first-evaluated direction wins. That rule, applied across millions of ticks, manifests as a deterministic chiral ratchet — a slow, statistically reliable NW drift. The math sees through the pseudo-random hash.

**Fix.** Murmur3-style avalanche before the modulo, so the lowest bit no longer carries position information into the result:

```metal
uint h = uint(node) ^ (tick * 374761393u);
h *= 0x85ebca6bu;
h ^= h >> 13;
h *= 0xc2b2ae35u;
h ^= h >> 16;
uint dir_offset = h % 6u;
```

After the fix, the population centre-of-mass on long runs stays at the geometric centre of the grid (within statistical error), and the wave-front isotropy is visibly restored. Credit to Gemini Deep Think for the parity diagnosis.

### 2. Chromatic Gauss-Seidel wind — shuffled dispatch

**Symptom.** Even after the Murmur3 fix, a slower bias remained: information physically travelled faster "up" the colour gradient than down it. Wave-fronts had a subtle directional preference aligned with the colour formula's geometric pattern.

**Diagnosis.** Colours were dispatched in fixed order `0 → 1 → 2 → … → 6` every tick. A lion sitting on colour 0 that steps onto colour 1 during pass 0 then gets *processed again* during pass 1 of the same macroscopic tick — its decision is re-evaluated with up-to-date neighbours. A lion on colour 6 that steps onto colour 0 has to wait until the next tick for its decision to be re-evaluated. The colour formula `(col + row + 4·(col & 1)) % 7` makes "up the gradient" a real geometric direction. Information leaks faster that way; a kind of asynchronous Gauss-Seidel wind.

**Fix.** Shuffle dispatch order every tick:

```swift
let colors = [0, 1, 2, 3, 4, 5, 6].shuffled()
```

The directional bias averages out over runs of more than a few ticks. The lock-free safety guarantee is preserved (only same-colour cells are dispatched in parallel; the order between colours can vary freely). Credit to Gemini Deep Think for the chromatic-advection diagnosis.

### 3. Predator death spiral — Type II satiation

**Symptom.** With naive Lotka-Volterra dynamics — predation rate proportional to `prey × predator` density — the lion population blows up exponentially when prey is dense, then crashes to extinction when prey runs out, then never recovers. The predator–prey cycle is not a cycle; it is a one-shot collapse.

**Diagnosis.** The predation rate `α · zebra · lion` is unbounded in `zebra`. A single lion cannot eat a thousand zebras per tick even if a thousand are within reach; the lion fills up. The unbounded rate is what drives the runaway and the subsequent crash. This is the textbook reason classical Lotka-Volterra is structurally unstable for finite populations.

**Fix.** Holling Type II functional response:

```
predation_rate = α · zebra · lion / (1 + h · α · zebra)
```

Predation saturates at `1/h` per predator as prey density grows. The predator cannot eat more than its handling rate allows. The dynamics now have an equilibrium that the trajectory orbits rather than overshoots; the death spiral is broken. The Savanna implementation enforces this through per-pride caloric pools (`MAX_ENERGY_LION = 8000`) and `KILL_ENERGY = 2000` — a pride that has just eaten cannot feed again until its pool drains, which is the engine's discrete realization of the Type II saturation.

### 4. CFL violation — Nyquist clamp on dt-compression

**Symptom.** Temporal downsampling for deep zoom-outs produced apparent teleportation: a sprinting lion would skip across multiple macro-pixels between sampled frames, breaking spatial continuity in the visualization.

**Diagnosis.** The temporal compression `dt_compressed ~ 1 / zoom^1.5` makes time accelerate violently as the zoom factor grows. If the sampling frequency drops below the entity interaction frequency, the Courant–Friedrichs–Lewy condition is violated:

```
v_max · dt_compressed > 1 macro-pixel
```

This is exactly Nyquist–Shannon temporal aliasing — the fastest entities outrun the discrete frames that are supposed to sample them.

**Fix.** Clamp the temporal compression multiplier so that `v_max · dt_compressed ≤ 1` macro-pixel always. The clamp lives in the viewer's playback path. Continuity is preserved at every zoom level by capping how aggressively time can compress.

### 5. Trophic max-pooling — why mean and mode both fail

**Symptom.** During spatial downsampling, the obvious operators (arithmetic mean of cell values; mode of cell types) both produce wrong macroscopic views.

**Diagnosis.** Cell types are encoded as integers — say `EMPTY=0, GRASS=1, ZEBRA=2, LION=3`. Two failure modes:

- **Mean (the Frankenstein error).** Averaging a cell that is GRASS (1) with a cell that is LION (3) gives 2 — ZEBRA. The downsample literally hallucinates prey out of plants and predators. The integers were never meant to be averaged; they encode categories, not magnitudes.
- **Mode (the extinction error).** Taking the most common value: in a 64×64 macro-pixel with 4,000 grass cells, 95 zebras, and 1 lion, the mode is grass. As you zoom out, every apex predator vanishes from the macroscopic view, because they are inherently sparse. The thing the viewer most wants to see is what the mode operator throws away first.

**Fix. Trophic max-pooling.** Define an ecological priority ranking — `LION > ZEBRA > WATER > GRASS > EMPTY` — and use `max()` on that priority when collapsing a block. If even one lion existed in the sector during the time window, the macro-pixel renders as lion. Rare, high-energy entities survive arbitrary spatial and temporal compression. The downsample preserves the thing the viewer cares about. Credit to Gemini Deep Think for catching both failure modes before either was shipped.

### 6. Atto-Fox — discrete truncation at low N

**Symptom.** On long runs at moderate cell counts, populations occasionally went extinct and never recovered, even when the differential-equation model said the equilibrium should be stable.

**Diagnosis.** The classical Lotka-Volterra continuous model can have a population fall to `0.001` and recover. A discrete agent-based simulation cannot — `0.001` of a fox rounds to zero, and zero foxes do not breed back to one fox. This is the **Atto-Fox problem**: discrete truncation at low N produces extinctions that the continuous model would forbid. Once a species hits zero somewhere, its only path back into that region is migration from elsewhere — and at sparse densities, migration may not arrive in time.

**Fix in this engine.** Three mitigations operate together: (1) sufficient starting density at meaningful spatial separation so that local extinctions are recoverable through diffusion; (2) the Type II response above, which slows the boom-bust amplitude that drives populations toward zero in the first place; (3) the metapopulation effect — at the 2 % density used by default, the spatial system is below the site-percolation threshold, which transforms the ODE into a delay differential equation through spatial transport, producing out-of-phase local oscillators that globally average to a stable limit cycle.

The 14-year extinctions seen in the earliest runs were Atto-Fox events. They are now rare on the 1 M grid and are not observed at the larger scales where metapopulation effects dominate.

### 7. Lévy α tunability — configurable diffusion exponent

**Symptom.** The diffusion / scent / movement model used a fixed Lévy flight exponent `α = 1.5`, hard-coded in shader and configuration. For other workloads — particularly the upcoming Liver drug-diffusion experiments — the right exponent is `α = 2.0` (standard Gaussian diffusion). Hard-coding pins the engine to the specific savanna workload.

**Fix.** The Lévy α parameter is now configurable in the run-time `meta.json`. `α = 2.0` gives standard diffusion (Brownian / Gaussian). `α < 2.0` gives Lévy flights with heavy-tailed step distributions — the regime in which the savanna predator search behaves better than a pure random walk, because long jumps occasionally relocate predators across patchy prey landscapes. The engine is no longer pinned to a single biological assumption.

### 8. Pride mitosis vs zebra birthday window

**Symptom.** The first reproduction model treated lions and zebras the same way — both reproduced when their per-individual energy crossed a threshold. The result was unrealistic: lion populations grew smoothly, but zebra populations had no observable cohort structure (no birth pulse seasonality), and the per-cell counts never matched savanna observations.

**Fix.** Two distinct reproductive semantics, encoded in shader constants and called out in the source ([`savanna.metal`](Sources/Savanna/Shaders/savanna.metal) lines 41–47):

- **Pride mitosis (lions).** When a pride's caloric pool hits `SPLIT_ENERGY = 6000`, the cell *divides into two prides*; each daughter inherits half the energy. Natural territorial repulsion keeps them apart afterwards. There is no birthday window. The biological analog is the cooperative-hunting unit splitting; it happens whenever the energy budget allows.
- **Zebra reproduction (birthday window).** Standard threshold reproduction with `REPRO_ENERGY_ZEBRA = 120`, `BIRTH_ENERGY_ZEBRA = 50`, and `REPRO_THERMO_LOSS = 30`. Reproduction is a discrete event keyed to energy and a per-individual reproductive readiness window. The zebra cohort structure now matches expected herd dynamics.

This is one place where the abstraction "predator-prey on a hex lattice" breaks down: the two species need different breeding code, because cooperative-hunting predators and herd-grazers have different population-dynamics shapes. The engine encodes the asymmetry rather than papering over it.

---

## References and acknowledgments

- **Carlos Delta compression** — XOR-against-previous + standard compression at 50× ratio, separately developed by Carlos Mateo. [carlosmateo10/delta-compression-demo](https://github.com/carlosmateo10/delta-compression-demo), MIT License.
- **Molloy, M., & Reed, B. (2002).** *Graph Colouring and the Probabilistic Method.* Springer. The local-bound chromatic-number machinery underlying the 7-colourability claim.
- **Salavatipour, M. (2005).** *The chromatic number of the square of planar graphs.* The refinement that places the squared hex grid at exactly 7 colours.
- **Holling, C. S. (1959).** *Some characteristics of simple types of predation and parasitism.* The original formulation of the Type II functional response used in §3.
- **Courant, R., Friedrichs, K., & Lewy, H. (1928).** *Über die partiellen Differenzengleichungen der mathematischen Physik.* The CFL condition cited in §4.
- **Mollison, D. (1991).** *Dependence of epidemic and population velocities on basic parameters.* Source for the Atto-Fox phrasing in §6.
- **Gemini Deep Think (Google).** Macro-architectural review at three points in development: the trillion-cell I/O fix, the Voronoi/Fisher-KPP isotropy reading, and the lion drift parity diagnosis. Credit explicit at the cited overcomes.

Visualization and code co-authored with Claude (Anthropic).

---

> **Humble disclaimer.** Amateur engineering project. We are not HPC professionals and make no competitive claims. Numbers speak; ego doesn't. Errors likely.

GPLv3. See [`LICENSE`](LICENSE).
