# Honest Status: What Is Established vs What Is Speculation

## ESTABLISHED in the literature:

1. **Homogenization of lattice systems → PDEs**: Yes, well-studied. Interacting particle systems on lattices converge to reaction-diffusion PDEs in the hydrodynamic limit (De Masi & Presutti, 1991; Kipnis & Landim, 1999). This is standard for symmetric exclusion processes, voter models, contact processes.

2. **Lévy flights → fractional Laplacian**: Yes, established. The generator of a Lévy process with stability index α is the fractional Laplacian (-Δ)^{α/2}. This is a theorem (Applebaum, 2009). If agents do Lévy flights, the continuum limit diffusion operator is fractional.

3. **Spatial Lotka-Volterra → reaction-diffusion PDEs**: Yes, classical. Spatial predator-prey with random walks → reaction-diffusion system with classical Laplacian (Murray, Mathematical Biology, 2003). With Type II functional response → Rosenzweig-MacArthur reaction-diffusion.

4. **Excitable media on lattices → FitzHugh-Nagumo type PDEs**: Yes. Discrete excitable systems (BZ reaction, cardiac tissue) homogenize to FitzHugh-Nagumo or Barkley models (Keener & Sneyd, Mathematical Physiology).

5. **Fractional Laplacian free boundary problems**: Yes, studied. Caffarelli, Roquejoffre & Sire (2010), Caffarelli & Vasseur (2010). These are PDE theory papers, NOT ecology papers.

## NOT ESTABLISHED (my speculation):

6. **Grazing front as a free boundary in PDE sense**: ⚠️ NOT ESTABLISHED. I have not found any paper that formally identifies the grazed/ungrazed interface in a spatial ecology model as a free boundary problem. The visual analogy is suggestive but NOT proven. The grazing front moves, yes, but it may not satisfy the regularity or energy conditions required for free boundary theory.

7. **Almost monotonicity at the grazing front**: ⚠️ PURE SPECULATION. I projected Matevosyan & Petrosyan's tool onto this system because it's the author's prior work. There is NO paper connecting almost monotonicity formulas to ecological interfaces. The energy functional I wrote down (Φ(r) = ...) is not derived — it's invented by analogy.

8. **DLA morphology of grazing fronts**: ⚠️ OBSERVED but not characterized. The fractal boundaries are visually similar to DLA, but I have not measured the fractal dimension or compared to DLA universality class. Could be a different universality class entirely.

9. **Ternary states → excitable medium in the PDE limit**: PLAUSIBLE but not derived. The ternary firewall (0→+1→-1→0) is topologically identical to excitable media. But deriving the exact FitzHugh-Nagumo coefficients from the discrete Metal kernel parameters has not been done.

10. **Morton ordering affecting the PDE limit**: ⚠️ UNKNOWN. The chromatic Gauss-Seidel with Morton ordering introduces a specific update schedule. Whether this converges to the same PDE as a random-order update is an open question. For symmetric systems it shouldn't matter (ergodic theorem). For our asymmetric system with directed movement, it might.

## What IS novel (potentially):

- **Combining ALL of these**: fractional diffusion + free boundary + excitable medium + nonlocal aggregation in ONE system. Each ingredient exists in the literature separately. The combination does not, as far as I know.
- **Computational scale**: 100 billion cells is unprecedented for an agent-based ecological model. Most papers use 10^4 to 10^6.
- **The question itself**: "What PDE do you get when you homogenize a hex-lattice predator-prey system with Lévy flights and ternary states?" — this specific question may not have been asked before.

## The honest paper:

The paper should NOT claim to prove a free boundary result or an almost monotonicity formula. It should:
1. Derive the formal continuum limit (straightforward, using standard homogenization)
2. Identify the fractional Laplacian from the Lévy flights (theorem, not conjecture)
3. OBSERVE that the grazing front has properties suggestive of a free boundary
4. POSE the question: does almost monotonicity hold here?
5. Present the computational evidence at 100B scale
6. Leave the regularity theory as an open problem

That's honest. That's a real paper. Not inflated.
