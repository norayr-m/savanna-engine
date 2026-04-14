# Performance Benchmark

**Machine:** Apple MacBook Pro, M5 Max, 128 GB unified memory
**Date:** 2026-04-13 (updated with Morton Z-curve layout)
**Method:** 10 runs per grid size, 5-tick warmup, mean ± standard deviation

## What Is Measured

**ms/tick = pure GPU compute time only.** This is the time for 13 Metal
kernel dispatches to complete (`cmdBuf.commit()` to `waitUntilCompleted()`).

It does NOT include:
- Grid construction (CPU-bound, one-time)
- State initialisation
- Snapshot file writes
- HTTP serving, telemetry, sleep delays
- Display/rendering

The wall-clock per tick in the full application loop is ~25-35ms
(dominated by file I/O and sleep for spacetime zoom).

## Methodology

Each tick = 13 Metal compute kernel dispatches:
- 4× scent diffusion (Float32 fields, all cells)
- 7× entity update (one per colour group, ~1/7 of cells each)
- 1× grass growth (all cells)
- 1× census (all cells, atomic counters)

**GCUPS** = cells × 7 effective passes (4 scent + 1 entity + 1 grass + 1 census) × ticks/sec.

10 runs per grid size. 5-tick warmup per run (eliminates GPU pipeline
stall on first dispatch). Mean ± standard deviation reported.

## Results

| Grid | Cells | ms/tick (mean±std) | TPS (mean±std) | GCUPS |
|------|-------|--------------------|----------------|-------|
| 1024² | 1M | 0.58 ± 0.02 | 1,722 ± 59 | 12.6 |
| 2048² | 4M | 1.98 ± 0.01 | 504 ± 2 | 14.8 |
| 4096² | 16M | 7.78 ± 0.03 | 128 ± 0 | **15.1** |
| 8192² | 64M | 29.77 ± 0.12 | 33 ± 0 | 15.8 |

Variance <1% standard deviation at all scales. Morton Z-curve memory layout.

Peak throughput: **15.8 GCUPS** at 64M cells. See [BENCHMARK_MORTON.md](BENCHMARK_MORTON.md) for full comparison.

## Scaling

Compute scales linearly with cell count:

| Grid | Cells | ms/tick | TPS | GCUPS |
|------|-------|---------|-----|-------|
| 16384² | 256M | 126.9 | 7.9 | 14.8 |
| 32768² | 1B | 522.8 | 1.9 | 14.4 |

Measured (10 runs, Morton Z-curve). GCUPS stays flat at scale — see [BENCHMARK_MORTON.md](BENCHMARK_MORTON.md).

## Notes

- All measurements on bare metal, no virtualisation
- GPU utilisation ~5% at 1M cells (vsync-bound at 60fps)
- Apple Silicon unified memory eliminates PCIe DMA transfers
- 7-colouring provides lock-free parallelism (zero atomic operations)
- Results are deterministic (seeded PRNG) and reproducible
- Raw output: [BENCHMARK_RAW.txt](BENCHMARK_RAW.txt)
