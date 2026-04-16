# Gemini Deep Think — Lion Drift Analysis (2026-04-15 Night)

## Two Mathematical Ghosts Found

### Ghost 1: LCG Parity Preservation (The Morton Ratchet)

`dir_offset = (node * 2654435761u ^ tick * 374761393u) % 6u`

Multiplying by odd prime preserves lowest bit. Morton code lowest bit = column parity.
Modulo 6 (even) also preserves parity. Result:
- Even columns ALWAYS check even directions first (0=NE, 2=NW, 4=S)
- Odd columns ALWAYS check odd directions first (1=N, 3=SW, 5=SE)

On zero scent (6-way tie), first evaluated direction wins → deterministic chiral ratchet → NW drift.

**Fix:** Murmur3 avalanche before modulo:
```metal
uint h = uint(node) ^ (tick * 374761393u);
h *= 0x85ebca6bu;
h ^= h >> 13;
h *= 0xc2b2ae35u;
h ^= h >> 16;
uint dir_offset = h % 6u;
```

### Ghost 2: Chromatic Advection (Gauss-Seidel Wind)

Colors processed 0→1→2→...→6 sequentially. Lion on Color 0 steps to Color 1 → processed AGAIN in same macroscopic tick. Lion on Color 6 steps to Color 0 → waits until next tick.

Color formula `(col + row + 4*(col&1)) % 7` creates geometric pattern. Information physically travels faster "up" the color gradient.

**Fix:** Shuffle dispatch order every tick:
```swift
let colors = [0, 1, 2, 3, 4, 5, 6].shuffled()
```

### Also: Fisher-KPP Wavefront Speed

$$c = \sqrt{ \frac{2\ln(2) \cdot (\text{KILL\_ENERGY} \times P_{success} - \text{BMR})}{\text{SPLIT\_ENERGY}} }$$

With our params (KILL=2000, SPLIT=6000, BMR=3, P=1.0):
c ≈ 0.68 hexes/tick = 11.3 hexes/day

### Also: Lotka-Volterra Stability

2% density → below site percolation threshold → metapopulation → spatial time delay τ → transforms ODEs to DDEs → out-of-phase local oscillators → globally stable limit cycle.

14-year extinction: the Atto-Fox Problem — discrete truncation at low N.

## Attribution
Analysis by Gemini Deep Think (Google), 2026-04-15 night session.
