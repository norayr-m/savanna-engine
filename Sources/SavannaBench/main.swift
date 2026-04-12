import Foundation
import Savanna
import Metal

// ══════════════════════════════════════════════════════════
// SAVANNA ENGINE — REPRODUCIBLE BENCHMARK
// Pure GPU compute time. No file I/O. No rendering. No sleep.
// ══════════════════════════════════════════════════════════

func benchOnce(w: Int, h: Int, ticks: Int) -> (ms: Double, tps: Double, gcups: Double) {
    let grid = HexGrid(width: w, height: h)
    var state = SavannaState(width: w, height: h)
    state.randomInit()
    let engine = try! MetalEngine(grid: grid, state: state)
    // Warmup
    for t in 0..<5 { engine.tick(tickNumber: UInt32(t), isDay: true) }
    // Measure
    let t0 = CFAbsoluteTimeGetCurrent()
    for t in 5..<(5 + ticks) { engine.tick(tickNumber: UInt32(t), isDay: (t % 20) < 10) }
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    let ms = elapsed / Double(ticks) * 1000.0
    let tps = Double(ticks) / elapsed
    let gcups = Double(w * h) * 12.0 * tps / 1e9
    return (ms, tps, gcups)
}

// ── System info ──────────────────────────────────────────
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal GPU") }

print("════════════════════════════════════════════════════════════")
print("  SAVANNA ENGINE — REPRODUCIBLE BENCHMARK")
print("  Date:    \(ISO8601DateFormatter().string(from: Date()))")
print("  GPU:     \(device.name)")
print("════════════════════════════════════════════════════════════")
print()
print("  10 runs per grid size. 5-tick warmup. Pure GPU compute.")
print("  GCUPS = cells × 12 dispatches × tps / 1e9")
print()
print("──────────────────────────────────────────────────────────────")
print(String(format: "  %-6s  %16s  %14s  %16s", "GRID", "ms/tick", "TPS", "GCUPS"))
print("──────────────────────────────────────────────────────────────")

let configs: [(Int, Int, Int, String)] = [
    (1024, 1024, 100, "1M"),
    (2048, 2048, 50,  "4M"),
    (4096, 4096, 20,  "16M"),
]

for (w, h, ticks, label) in configs {
    var msAll = [Double](), tpsAll = [Double](), gcupsAll = [Double]()
    for _ in 1...10 {
        let r = benchOnce(w: w, h: h, ticks: ticks)
        msAll.append(r.ms); tpsAll.append(r.tps); gcupsAll.append(r.gcups)
    }
    let n = Double(msAll.count)
    let msMean = msAll.reduce(0,+)/n
    let msStd = sqrt(msAll.map{($0-msMean)*($0-msMean)}.reduce(0,+)/n)
    let tpsMean = tpsAll.reduce(0,+)/n
    let tpsStd = sqrt(tpsAll.map{($0-tpsMean)*($0-tpsMean)}.reduce(0,+)/n)
    let gcupsMean = gcupsAll.reduce(0,+)/n
    let gcupsStd = sqrt(gcupsAll.map{($0-gcupsMean)*($0-gcupsMean)}.reduce(0,+)/n)

    print(String(format: "  %-6s  %6.2f ± %4.2f ms  %6.0f ± %4.0f  %6.1f ± %3.1f B",
                 label, msMean, msStd, tpsMean, tpsStd, gcupsMean, gcupsStd))
}

print("──────────────────────────────────────────────────────────────")
print()
print("  To reproduce: swift run -c release savanna-bench")
print()
