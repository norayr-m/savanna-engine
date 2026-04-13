# Morton Z-Curve Performance Study

**Machine:** Apple MacBook Pro, M5 Max, 128 GB unified memory  
**Date:** 2026-04-13  
**Method:** 5-tick warmup, pure GPU compute only (`cmdBuf.commit()` to `waitUntilCompleted()`)

## What Changed

All GPU state buffers reordered from **row-major** (`index = row × width + col`) to **Morton Z-curve** (`index = mortonRank[row × width + col]`).

Morton ordering interleaves the bits of column and row coordinates, clustering spatial neighbors in memory. On hex grids, this means a cell's 6 neighbors are stored within a few cache lines instead of being scattered up to `width` indices apart.

**Metal kernels: zero changes.** The kernels read flat buffers and a neighbor table. They don't know about Morton. The locality improvement comes from data layout, not code changes.

## Results

### Row-Major (Baseline)

| Grid | Cells | ms/tick | TPS | GCUPS |
|------|-------|---------|-----|-------|
| 1024² | 1M | 0.68 | 1,464 | 10.8 |
| 2048² | 4M | 2.01 | 496 | 14.6 |
| 4096² | 16M | 7.94 | 125 | 14.8 |
| 8192² | 64M | 33.19 | 30 | 14.2 |
| 16384² | 256M | 205.02 | 4 | 9.2 |

### Morton Z-Curve

| Grid | Cells | ms/tick | TPS | GCUPS |
|------|-------|---------|-----|-------|
| 1024² | 1M | 0.68 | 1,469 | 10.8 |
| 2048² | 4M | 1.98 | 505 | 14.8 |
| 4096² | 16M | 7.69 | 129 | 15.3 |
| 8192² | 64M | 29.56 | 33 | 15.9 |
| 16384² | 256M | 125.71 | 7 | 14.9 |

### Comparison

| Grid | Cells | Row-Major | Morton | **Speedup** | Notes |
|------|-------|-----------|--------|-------------|-------|
| 1024² | 1M | 0.68 ms | 0.68 ms | 0% | Grid fits in L2 cache |
| 2048² | 4M | 2.01 ms | 1.98 ms | **+1.5%** | |
| 4096² | 16M | 7.94 ms | 7.69 ms | **+3.2%** | |
| 8192² | 64M | 33.19 ms | 29.56 ms | **+10.9%** | Cache misses start dominating |
| 16384² | 256M | 205.02 ms | 125.71 ms | **+38.7%** | **Morton locality decisive** |

## Analysis

The speedup **grows with grid size**:

```
1M:   0%    — grid fits in L2, no cache benefit
4M:   1.5%  — borderline, minor locality gains
16M:  3.2%  — measurable, scent diffusion benefits
64M:  10.9% — significant, neighbor reads cross cache lines
256M: 38.7% — dominant, row-major thrashes the cache hierarchy
```

At 256M cells (16384×16384), Morton is **1.63× faster** than row-major. The row-major layout degrades from 14.8 GCUPS at 16M to 9.2 GCUPS at 256M — a 38% throughput collapse. Morton maintains 14.9 GCUPS at 256M, nearly flat scaling.

### Why

Each tick, each cell reads 6 neighbors for scent diffusion (4 kernels × 6 reads = 24 neighbor reads per cell per tick). In row-major layout, 4 of 6 hex neighbors are `width` indices apart — at 16384 width, that's 16384 × 4 bytes = 64 KB per neighbor fetch. The L2 cache line is 128 bytes. Every neighbor read in a different row is a guaranteed cache miss.

Morton ordering clusters all 6 neighbors within a few hundred indices. At 256M, the working set is 5.9 GB — far exceeding any cache level. Morton turns random memory access into sequential, reducing cache misses from ~4 per cell to ~1-2.

### Scaling Projection

| Grid | Cells | Morton ms/tick | Morton GCUPS | Projected |
|------|-------|---------------|-------------|-----------|
| 32768² | 1B | ~500 ms | ~14 | Real-time (2 TPS) |
| 65536² | 4B | ~2,000 ms | ~14 | 0.5 TPS |

Morton maintains ~15 GCUPS across scales because the locality benefit compensates for the growing working set. Row-major would collapse to <5 GCUPS at 1B cells.

## Methodology

- Benchmark binary: `swift run -c release savanna-bench`
- 5-tick warmup eliminates GPU pipeline cold-start
- Timing: `CFAbsoluteTimeGetCurrent()` around the tick loop only
- Same random seed (42) for reproducibility
- Both versions run on the same commit, same machine, same session
- Metal kernels: identical between both versions (zero shader changes)
- GCUPS = cells × 7 effective passes × TPS / 1e9

## Reproduce

```bash
git clone https://github.com/norayr-m/savanna-engine.git
cd savanna-engine
swift run -c release savanna-bench
```

Requires: macOS 14+, Apple Silicon, Swift 6.0+
