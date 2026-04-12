import Foundation
import Savanna

let width = 1024
let height = 1024
let dayLength = 10
let nightLength = 10
let totalTicks = Int.max  // run forever
let snapshotPath = "/tmp/savanna_state.bin"

// Time rubber banding: smooth logarithmic arc per day cycle
// 4 ticks per day (0,1=day  2,3=night). Night is slowest. Dawn/dusk transition smooth.
// Pattern over a full day (ticks 0-3):
//   tick 0 (morning):  medium  — dawn, waking up
//   tick 1 (afternoon): fast   — routine grazing
//   tick 2 (evening):  medium  — dusk, tension builds
//   tick 3 (night):    slow    — the hunt
// But we run many days, so use a continuous sine-like curve over the 4-tick cycle.
func sleepForTick(_ t: Int) -> UInt32 {
    let phase = t % 4  // 0,1 = day, 2,3 = night
    // Sine arc: min at phase 1 (midday), max at phase 3 (midnight)
    // sleep = base + amplitude * sin(phase * pi/2)
    let minSleep: Double = 30   // fastest (midday) — still visible, no flicker
    let maxSleep: Double = 200  // slowest (midnight hunt)
    let curve = sin(Double(phase) * .pi / 3.0)  // 0→0.87→0.87→0 roughly
    let sleep = minSleep + (maxSleep - minSleep) * curve
    return UInt32(sleep)
}
// Effective: tick0=30ms, tick1=~180ms, tick2=~180ms, tick3=30ms
// Day feels like: quick-slow-slow-quick, with the slow part at dusk+night

print("SavannaEngine — Swift + Metal")
print("Grid: \(width)×\(height) = \(width * height) nodes")
print()

// ── Build hex grid ──────────────────────────────────────
print("Building hex grid...")
let t0 = CFAbsoluteTimeGetCurrent()
let grid = HexGrid(width: width, height: height)
let t1 = CFAbsoluteTimeGetCurrent()
print("  Built in \(String(format: "%.2f", t1 - t0))s")
print("  Color groups: [\(grid.colorGroups.map { "\($0.count)" }.joined(separator: ", "))]")

// Verify coloring
let colorOK = grid.verifyColoring()
print("  4-coloring valid: \(colorOK)")

// Verify degrees
var deg6 = 0
for i in 0..<grid.nodeCount { if grid.degree(of: i) == 6 { deg6 += 1 } }
print("  Degree-6 nodes: \(deg6)/\(grid.nodeCount)")

// ── Init state ──────────────────────────────────────────
print("\nInitializing state...")
var state = SavannaState(width: width, height: height)
state.randomInit()
let c0 = state.census()
print("  Census: grass=\(c0.grass) zebra=\(c0.zebra) lion=\(c0.lion) energy=\(c0.totalEnergy)")

// ── Create Metal engine ─────────────────────────────────
print("\nCreating Metal engine...")
let engine: MetalEngine
do {
    engine = try MetalEngine(grid: grid, state: state)
    print("  Metal device: \(engine.device.name)")
} catch {
    print("  FATAL: \(error)")
    exit(1)
}

// ── Create recorder ────────────────────────────────────
let recorder = SimRecorder(device: engine.device, nodeCount: width * height, capacity: 50_000)
if let recorder = recorder {
    engine.recorder = recorder
    print("  Recorder: \(recorder.capacity) frames (\(recorder.capacity * width * height / 1_000_000) MB ring)")
} else {
    print("  WARNING: Recorder allocation failed")
}

// Verify initial census matches
let mc0 = engine.census()
print("  GPU census: grass=\(mc0.grass) zebra=\(mc0.zebra) lion=\(mc0.lion) energy=\(mc0.totalEnergy)")

// ── Run simulation ──────────────────────────────────────
print()
print(String(repeating: "─", count: 80))
print(String(format: "  %-8s %10s %8s %6s %10s %9s %5s", "TICK", "GRASS", "ZEBRA", "LION", "ENERGY", "ms/tick", "PHASE"))
print(String(repeating: "─", count: 80))
print(String(format: "  %-8d %10d %8d %6d %10d %9s %5s", 0, mc0.grass, mc0.zebra, mc0.lion, mc0.totalEnergy, "—", "INIT"))

let tSim0 = CFAbsoluteTimeGetCurrent()
var prevGrass = 0, prevZebra = 0, prevLion = 0
var dGrass = 0, dZebra = 0, dLion = 0

for t in 0..<totalTicks {
    let tickStart = CFAbsoluteTimeGetCurrent()
    let cyclePos = t % (dayLength + nightLength)
    let isDay = cyclePos < dayLength

    engine.tick(tickNumber: UInt32(t), isDay: isDay)

    // Write snapshot for HTML renderer (from ring buffer if recording)
    if let rec = recorder, rec.frameCount > 0 {
        rec.writeLiveSnapshot(to: snapshotPath, width: width, height: height, tick: t, isDay: isDay)
    } else {
        engine.writeSnapshot(to: snapshotPath, width: width, height: height, tick: t, isDay: isDay)
    }

    // Spacetime zoom: speed and sleep from HTML zoom level
    // speed = ticks per frame (fast forward when zoomed out)
    // sleep = ms per frame (slow motion when zoomed in)
    var speedMultiplier = 1
    var sleepMs: UInt32 = 30
    if let speedStr = try? String(contentsOfFile: "/tmp/savanna_speed.txt").trimmingCharacters(in: .whitespacesAndNewlines),
       let level = Int(speedStr) {
        speedMultiplier = max(1, level)  // direct multiplier, not bit shift
    }
    if let sleepStr = try? String(contentsOfFile: "/tmp/savanna_sleep.txt").trimmingCharacters(in: .whitespacesAndNewlines),
       let ms = UInt32(sleepStr) {
        sleepMs = max(5, min(200, ms))
    }

    // Fast forward: run extra ticks without writing snapshot
    for _ in 1..<speedMultiplier {
        let extraT = t + 1
        let extraCycle = extraT % (dayLength + nightLength)
        let extraDay = extraCycle < dayLength
        engine.tick(tickNumber: UInt32(extraT), isDay: extraDay)
    }

    // Sleep: slow motion when zoomed in, fast when zoomed out
    usleep(sleepMs * 1000)

    // Telemetry: write sim stats for HTML overlay
    let tickEnd = CFAbsoluteTimeGetCurrent()
    let msThisTick = (tickEnd - tickStart) * 1000
    if (t + 1) % 10 == 0 {
        let c = engine.census()
        let tps = 1000.0 / max(0.01, msThisTick)
        dGrass = c.grass - prevGrass; dZebra = c.zebra - prevZebra; dLion = c.lion - prevLion
        prevGrass = c.grass; prevZebra = c.zebra; prevLion = c.lion
        let day = (t + 1) / 4
        let year = Double(t + 1) / 1460.0
        let ratio = c.zebra > 0 ? Double(c.zebra) / max(1.0, Double(c.lion)) : 0
        let grassPct = Double(c.grass) / Double(width * height) * 100
        let telemetry = """
        {"tick":\(t+1),"day":\(day),"year":\(String(format:"%.2f",year)),\
        "ms":\(String(format:"%.2f",msThisTick)),"tps":\(Int(tps)),"speed":\(speedMultiplier),\
        "grass":\(c.grass),"zebra":\(c.zebra),"lion":\(c.lion),"energy":\(c.totalEnergy),\
        "dG":\(dGrass),"dZ":\(dZebra),"dL":\(dLion),\
        "ratio":\(String(format:"%.1f",ratio)),"grassPct":\(String(format:"%.1f",grassPct)),\
        "nodes":\(width*height),"colors":7}
        """
        try? telemetry.write(toFile: "/tmp/savanna_telemetry.json", atomically: true, encoding: .utf8)
        // Update recorder frame meta with census
        if let rec = recorder, rec.frameCount > 0 {
            let slot = (rec.head - 1 + rec.capacity) % rec.capacity
            rec.frameMeta[slot] = FrameMeta(tick: UInt32(t+1), isDay: isDay,
                                             grass: UInt32(c.grass), zebra: UInt32(c.zebra), lion: UInt32(c.lion))
        }
    }

    // Check for archive command
    if let cmd = try? String(contentsOfFile: "/tmp/savanna_cmd.txt").trimmingCharacters(in: .whitespacesAndNewlines) {
        if cmd.hasPrefix("archive") {
            let path = cmd.replacingOccurrences(of: "archive ", with: "")
            recorder?.archive(to: path, width: width, height: height)
            try? "".write(toFile: "/tmp/savanna_cmd.txt", atomically: true, encoding: .utf8)
        }
    }

    // Print every 100 ticks
    if (t + 1) % 100 == 0 {
        let c = engine.census()
        let phase = isDay ? "DAY" : "NGT"
        print(String(format: "  %-8d %10d %8d %6d %10d %8.2fms %5s", t + 1, c.grass, c.zebra, c.lion, c.totalEnergy, msThisTick, phase))
    }
}

let tSim1 = CFAbsoluteTimeGetCurrent()
let simTime = tSim1 - tSim0
let msPerTick = simTime / Double(totalTicks) * 1000

let finalCensus = engine.census()

// ── Summary ─────────────────────────────────────────────
print()
print(String(repeating: "=", count: 60))
print("SIMULATION COMPLETE — \(totalTicks) ticks in \(String(format: "%.2f", simTime))s (\(String(format: "%.2f", msPerTick))ms/tick)")
print("  Grass:  \(mc0.grass) → \(finalCensus.grass) (\(finalCensus.grass - mc0.grass > 0 ? "+" : "")\(finalCensus.grass - mc0.grass))")
print("  Zebra:  \(mc0.zebra) → \(finalCensus.zebra) (\(finalCensus.zebra - mc0.zebra > 0 ? "+" : "")\(finalCensus.zebra - mc0.zebra))")
print("  Lion:   \(mc0.lion) → \(finalCensus.lion) (\(finalCensus.lion - mc0.lion > 0 ? "+" : "")\(finalCensus.lion - mc0.lion))")
print("  Energy: \(mc0.totalEnergy) → \(finalCensus.totalEnergy)")
print(String(repeating: "=", count: 60))

// ── Step status ─────────────────────────────────────────
print()
print("Phase 1: \(colorOK ? "PASS" : "FAIL") — Hex grid + 4-coloring")
print("Phase 2: \(finalCensus.grass + finalCensus.zebra + finalCensus.lion > 0 ? "PASS" : "FAIL") — Metal engine running")
print("Speed:   \(String(format: "%.2f", msPerTick))ms/tick (\(String(format: "%.0f", 1000.0/msPerTick)) fps)")
