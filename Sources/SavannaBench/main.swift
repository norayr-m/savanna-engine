import Foundation
import Savanna
import Metal

let device = MTLCreateSystemDefaultDevice()!

func fmt(_ v: Double, _ d: Int) -> String {
    let factor = pow(10.0, Double(d))
    return "\((v * factor).rounded() / factor)"
}

print("════════════════════════════════════════════════════════════")
print("  SAVANNA ENGINE — STATISTICAL BENCHMARK (Morton Z-curve)")
print("  Date:  " + ISO8601DateFormatter().string(from: Date()))
print("  GPU:   " + device.name)
print("  Method: 10 runs per grid, 5-tick warmup, interleaved")
print("════════════════════════════════════════════════════════════")
print("")

struct BenchResult {
    let grid: String
    let cells: Int
    let samples: [Double]  // ms/tick per run

    var mean: Double { samples.reduce(0, +) / Double(samples.count) }
    var std: Double {
        let m = mean
        let variance = samples.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(samples.count - 1)
        return sqrt(variance)
    }
    var min: Double { samples.min()! }
    var max: Double { samples.max()! }
    var ci95: Double { 2.0 * std / sqrt(Double(samples.count)) }  // 95% CI half-width
    var tps: Double { 1000.0 / mean }
    var gcups: Double { Double(cells) * 7.0 * tps / 1e9 }
}

func benchN(_ w: Int, _ ticksPerRun: Int, _ runs: Int, _ label: String) -> BenchResult {
    var samples: [Double] = []

    for run in 0..<runs {
        // Fresh grid + state each run (cold start)
        let grid = HexGrid(width: w, height: w)
        var state = SavannaState(width: w, height: w)
        state.randomInit(grid: grid, seed: UInt64(42 + run))  // Different seed per run
        let engine = try! MetalEngine(grid: grid, state: state)

        // 5-tick warmup
        for t in 0..<5 { engine.tick(tickNumber: UInt32(t), isDay: true) }

        // Measure
        let t0 = CFAbsoluteTimeGetCurrent()
        for t in 5..<(5 + ticksPerRun) {
            engine.tick(tickNumber: UInt32(t), isDay: (t % 20) < 10)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        let msPerTick = elapsed / Double(ticksPerRun) * 1000.0
        samples.append(msPerTick)

        // Progress
        print("  \(label) run \(run + 1)/\(runs): \(fmt(msPerTick, 2)) ms/tick")
    }

    return BenchResult(grid: label, cells: w * w, samples: samples)
}

// Run benchmarks — 10 runs each
let configs: [(Int, Int, String)] = [
    (1024,  100, "1M  "),
    (2048,  50,  "4M  "),
    (4096,  20,  "16M "),
    (8192,  10,  "64M "),
    (16384, 5,   "256M"),
    (32768, 3,   "1B  "),
]

var results: [BenchResult] = []
for (w, ticks, label) in configs {
    print("\n  ── \(label.trimmingCharacters(in: .whitespaces)) ──")
    let r = benchN(w, ticks, 10, label)
    results.append(r)
}

// Print results table
print("")
print("  ════════════════════════════════════════════════════════")
print("  RESULTS (10 runs per grid, mean ± 95% CI)")
print("  ════════════════════════════════════════════════════════")
print("")
print("  Grid    Cells    ms/tick (mean±CI)      TPS     GCUPS    min      max      std")
print("  ──────────────────────────────────────────────────────────────────────────────")

for r in results {
    let cellStr: String
    if r.cells >= 1_000_000_000 { cellStr = "\(r.cells / 1_000_000_000)B" }
    else if r.cells >= 1_000_000 { cellStr = "\(r.cells / 1_000_000)M" }
    else { cellStr = "\(r.cells / 1000)K" }

    print("  \(r.grid)  \(cellStr)\t\(fmt(r.mean, 2)) ± \(fmt(r.ci95, 2)) ms" +
          "\t\(Int(r.tps))\t\(fmt(r.gcups, 1)) B" +
          "\t\(fmt(r.min, 2))\t\(fmt(r.max, 2))\t\(fmt(r.std, 3))")
}

print("  ──────────────────────────────────────────────────────────────────────────────")
print("")
print("  Notes:")
print("  - CI = 95% confidence interval (mean ± 2σ/√10)")
print("  - Each run: fresh grid, fresh state, different seed, 5-tick warmup")
print("  - GCUPS = cells × 7 effective passes × TPS / 1e9")
print("  - Pure GPU compute only (no I/O, no rendering)")
print("")
print("  Reproduce: swift run -c release savanna-bench")
print("")

// Output as JSON for comparison
let jsonResults = results.map { r in
    [
        "grid": r.grid.trimmingCharacters(in: .whitespaces),
        "cells": "\(r.cells)",
        "mean_ms": fmt(r.mean, 3),
        "std_ms": fmt(r.std, 4),
        "ci95_ms": fmt(r.ci95, 3),
        "min_ms": fmt(r.min, 3),
        "max_ms": fmt(r.max, 3),
        "tps": "\(Int(r.tps))",
        "gcups": fmt(r.gcups, 2),
    ]
}
if let jsonData = try? JSONSerialization.data(withJSONObject: jsonResults, options: .prettyPrinted),
   let jsonStr = String(data: jsonData, encoding: .utf8) {
    try? jsonStr.write(toFile: "benchmark_morton_stats.json", atomically: true, encoding: .utf8)
    print("  Raw data: benchmark_morton_stats.json")
}
