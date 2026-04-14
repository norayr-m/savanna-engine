# Homogenization of Discrete Hex-Lattice Predator-Prey Systems with Lévy Diffusion and Free Boundary Grazing Fronts

**Status:** Working draft. Computational experiments complete (100B cells). PDE derivation in progress.

## Abstract

We derive the continuum limit of a discrete predator-prey ecosystem on a hexagonal lattice with Morton Z-curve spatial ordering. The microscopic model features autonomous agents with ternary metabolic states (active/resting/refractory), Lévy flight movement, pride aggregation dynamics, and three sensory modalities (hearing, sight, smell via scent diffusion fields). We show that the homogenized system is a coupled reaction-diffusion system with:

1. **Fractional Laplacian diffusion** (not classical) arising from Lévy flight statistics (α = 1.5)
2. **Free boundary grazing fronts** at the interface between grazed and ungrazed regions
3. **Ternary refractory dynamics** producing excitable medium behavior (BZ-reaction topology)
4. **Nonlocal aggregation terms** from pride cohesion/splitting mechanics

We present computational evidence from 107 billion cell simulations on a single Apple M5 Max laptop (15.8 GCUPS, Morton Z-curve memory layout) showing fractal grazing boundaries with DLA-like morphology, stable zebra carrying capacity with excitable wavefronts, and long-lived predator-prey coexistence under specific parameter regimes.

## The System

### Microscopic (GPU Kernel)

Each cell `i` on the hex lattice carries state `(e_i, E_i, τ_i, g_i, θ_i)`:
- `e_i ∈ {∅, G, Z, L, W}` — entity type (empty, grass, zebra, lion, water)
- `E_i ∈ [0, E_max]` — energy (E_max species-dependent: zebra 500, lion/pride 8000)
- `τ_i ∈ {-1, 0, +1}` — ternary metabolic state
- `g_i ∈ ℤ` — gauge (age / maturity / cooldown)
- `θ_i ∈ {0,...,5}` — orientation (hex facing direction)

Update rule per tick: **sense → compute → emit** (read 6 neighbors, apply function, write result). 7-coloring chromatic Gauss-Seidel ensures lock-free parallelism.

### Macroscopic (PDE System)

Define density fields on ℝ²:
- `z(x,t)` — zebra density
- `l(x,t)` — lion (pride) density  
- `g(x,t)` — grass density
- `w(x)` — water (static landscape)

**Proposed homogenized system:**

```
∂z/∂t = D_z (-Δ)^{α/2} z + r_z · z · g · (1 - z/K_z) - a(z,l) · z · l - μ_z · z

∂l/∂t = D_l (-Δ)^{α/2} l + η · a(z,l) · z · l - μ_l · l + J_pride[l]

∂g/∂t = D_g Δg + ρ · g · (1 - g) · (1 + β · w(x)) - c · z · g
```

Where:
- `(-Δ)^{α/2}` is the **fractional Laplacian** (α = 1.5, Lévy superdiffusion)
- `a(z,l) = a_0 · l / (l + l_h)` — **Type II functional response** (Holling, satiation)
- `J_pride[l]` — **nonlocal aggregation-splitting operator** (attract if local density < 8, repel if > 8)
- `K_z` — zebra carrying capacity (determined by grass regrowth rate)
- `β` — water proximity boost for grass growth
- `η` — conversion efficiency (kill energy / birth cost = 8 cubs per kill)

### The Free Boundary

The **grazing front** Γ(t) = ∂{g > 0} ∩ ∂{g = 0} is a free boundary separating grazed from ungrazed regions. The microscopic simulation produces fractal grazing boundaries with DLA (diffusion-limited aggregation) morphology.

**Conjecture:** Near the grazing front, the energy functional

```
Φ(r) = (1/r²) ∫_{B_r} |∇g|² dx · (1/r²) ∫_{B_r} z² dx
```

satisfies an **almost monotonicity formula** in the sense of Caffarelli-Jerison-Kenig, adapted for the fractional setting.

This connects directly to the almost monotonicity formulas for elliptic operators with variable coefficients (Matevosyan & Petrosyan, CPAM 2011).

## Open Questions

1. **Does the fractional Laplacian homogenization hold?** The Lévy flight in the discrete model is stateless (hash-based, not Markov). Does the continuum limit still converge to fractional diffusion?

2. **Regularity of the grazing front.** Is Γ(t) a C^{1,α} surface, or does it remain fractal at all scales? The DLA morphology suggests fractal, but the PDE structure may regularize it.

3. **Existence of limit cycles.** Under what conditions does the homogenized system admit stable periodic orbits in the (z, l) phase plane? The discrete simulation shows long transients but eventual predator extinction. Is this a property of the continuum limit or a finite-size effect?

4. **Role of the ternary firewall.** The constraint τ: 0 → +1 → -1 → 0 (no direct -1 → +1 except predation interrupt) introduces a refractory period. This makes the system an **excitable medium**. The continuum limit should include a refractory term similar to FitzHugh-Nagumo. What is the correct form?

5. **Morton ordering and numerical analysis.** Does the Morton Z-curve spatial ordering affect the numerical solution of the discrete system? The chromatic Gauss-Seidel update depends on traversal order. Is the homogenized PDE independent of the discrete coloring schedule?

## Computational Evidence

| Experiment | Cells | Result |
|---|---|---|
| Fractal grazing fronts | 1M | DLA-like boundaries, self-similar at all zoom levels |
| Excitable wavefronts | 1M | Zebra population waves (BZ reaction topology) |
| Pride dynamics | 1M | Cohesion/splitting at threshold 8, stable prides |
| 100B tiled simulation | 107B | Linear scaling, 73s/tile, 122 min total |
| Delta compression | 1B, 20 frames | 98.7% sparsity, 50× lossless (XOR + Zstd) |
| Long-run coexistence | 1M | Lions survive 20+ years (30,000+ ticks) with tuned parameters |

## Connection to Prior Work

- **Matevosyan & Petrosyan (2011)**, "Almost monotonicity formulas for elliptic and parabolic operators." *CPAM.* — The almost monotonicity formula for the grazing front energy functional.
- **Matevosyan & Petrosyan (2011)**, "Two-phase semilinear free boundary problem with a degenerate phase." *Calc. Var. PDE.* — The grass-empty free boundary with degenerate (zero-growth) phase.
- **Molloy & Salavatipour (2005)** — Distance-2 chromatic number of hex lattice = 7 (our GPU parallelism).
- **Rosenzweig & MacArthur (1963)** — Predator-prey with Type II functional response.
- **Caffarelli, Roquejoffre, Sire (2010)** — Fractional Laplacian free boundary problems.

## Files

- `derivation.tex` — formal PDE derivation (in progress)
- `numerics.py` — extract density fields from simulation frames, compare to PDE predictions
- `figures/` — grazing front morphology, phase portraits, power spectra

## Authors

**Norayr Matevosyan** — Mathematics (KTH, Vienna, Cambridge). Free boundary problems, fractional PDE.

Built with Claude (Anthropic), Gemini (Google), Qwen Coder Next (Alibaba). GPU compute on Apple M5 Max.
