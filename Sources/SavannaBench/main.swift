import Foundation
import Savanna
import Metal

let device = MTLCreateSystemDefaultDevice()!

print("════════════════════════════════════════════════════════════")
print("  SAVANNA ENGINE — REPRODUCIBLE BENCHMARK")
print("  Date:  " + ISO8601DateFormatter().string(from: Date()))
print("  GPU:   " + device.name)
print("════════════════════════════════════════════════════════════")
print("")
print("  5-tick warmup. Pure GPU compute only.")
print("  GCUPS = cells x 12 dispatches x tps / 1e9")
print("")
print("  GRID      ms/tick        TPS       GCUPS")
print("  ──────────────────────────────────────────")

func fmt(_ v: Double, _ decimals: Int) -> String {
    let factor = pow(10.0, Double(decimals))
    let rounded = (v * factor).rounded() / factor
    return "\(rounded)"
}

func bench(_ w: Int, _ ticks: Int, _ label: String) {
    let grid = HexGrid(width: w, height: w)
    var state = SavannaState(width: w, height: w)
    state.randomInit()
    let engine = try! MetalEngine(grid: grid, state: state)
    for t in 0..<5 { engine.tick(tickNumber: UInt32(t), isDay: true) }
    let t0 = CFAbsoluteTimeGetCurrent()
    for t in 5..<(5+ticks) { engine.tick(tickNumber: UInt32(t), isDay: (t%20)<10) }
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    let ms = elapsed / Double(ticks) * 1000
    let tps = 1000.0 / ms
    let gcups = Double(w * w) * 12.0 * tps / 1e9
    print("  \(label)    \(fmt(ms, 2)) ms    \(Int(tps))     \(fmt(gcups, 1)) B")
}

bench(1024, 100, "1M  ")
bench(2048, 50,  "4M  ")
bench(4096, 20,  "16M ")

print("  ──────────────────────────────────────────")
print("")
print("  Reproduce: swift run -c release savanna-bench")
print("")
