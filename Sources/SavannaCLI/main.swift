import Foundation
import Metal
import Savanna

// ══════════════════════════════════════════════════════════
// Savanna Engine CLI
// Usage: savanna-cli [--bench] [--ram 8] [--grid 1024] [--ticks 1000]
// ══════════════════════════════════════════════════════════

// ── Parse args ───────────────────────────────────────────

func fmt(_ v: Double, _ d: Int) -> String {
    let factor = pow(10.0, Double(d))
    return "\((v * factor).rounded() / factor)"
}

let args = CommandLine.arguments
func arg(_ name: String, default val: String) -> String {
    if let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count { return args[i + 1] }
    return val
}
let benchMode = args.contains("--bench")
let gridSize = Int(arg("grid", default: "1024"))!
let maxTicks = Int(arg("ticks", default: "0"))!  // 0 = infinite
let ramGB = Int(arg("ram", default: "4"))!        // GB for ring buffer
let snapshotPath = "/tmp/savanna_state.bin"
let dayLength = 10
let nightLength = 10

let width = gridSize
let height = gridSize

// ── Banner ───────────────────────────────────────────────
print()
print("══════════════════════════════════════════════════════════")
print("  SAVANNA ENGINE")
print("══════════════════════════════════════════════════════════")

// System info
let device = MTLCreateSystemDefaultDevice()!
print("  GPU:     \(device.name)")
print("  Grid:    \(width)×\(height) = \(width * height / 1_000_000)M cells")
print("  State:   \(width * height * 7 / 1_000_000) MB entities + \(width * height * 16 / 1_000_000) MB scent")
print("  RAM:     \(ramGB) GB ring buffer (\(ramGB * 1_000_000_000 / (width * height)) frames)")
if benchMode { print("  Mode:    BENCHMARK (no file I/O)") }
print("══════════════════════════════════════════════════════════")
print()

// ── Build grid ───────────────────────────────────────────
print("  Building hex grid...", terminator: "")
fflush(stdout)
let t0 = CFAbsoluteTimeGetCurrent()
let grid = HexGrid(width: width, height: height)
let t1 = CFAbsoluteTimeGetCurrent()
print(" \(fmt(t1 - t0, 1))s")
print("  7-colouring: [\(grid.colorGroups.map { "\($0.count)" }.joined(separator: ", "))]")

// ── Init state ───────────────────────────────────────────
print("  Initialising state...", terminator: "")
fflush(stdout)
var state = SavannaState(width: width, height: height)
state.randomInit()
let c0 = state.census()
let t2 = CFAbsoluteTimeGetCurrent()
print(" \(fmt(t2 - t1, 1))s")
print("  Census: grass=\(c0.grass) zebra=\(c0.zebra) lion=\(c0.lion)")

// ── Metal engine ─────────────────────────────────────────
print("  Creating Metal engine...", terminator: "")
fflush(stdout)
let engine: MetalEngine
do {
    engine = try MetalEngine(grid: grid, state: state)
} catch {
    print(" FATAL: \(error)")
    exit(1)
}
let t3 = CFAbsoluteTimeGetCurrent()
print(" \(fmt(t3 - t2, 1))s")

// ── Recorder ─────────────────────────────────────────────
let frameBytes = width * height
let recorderCapacity = ramGB * 1_000_000_000 / frameBytes
let recorder = SimRecorder(device: device, nodeCount: frameBytes, capacity: min(recorderCapacity, 200_000))
if let rec = recorder, !benchMode {
    engine.recorder = rec
    print("  Recorder: \(rec.capacity) frames (\(rec.capacity * frameBytes / 1_000_000) MB)")
}

print()

// ── Run ──────────────────────────────────────────────────
let tickLimit = maxTicks > 0 ? maxTicks : Int.max
var tickCount = 0
var totalComputeTime: Double = 0
let simStart = CFAbsoluteTimeGetCurrent()
var lastPrint = simStart

// Header
print("──────────────────────────────────────────────────────────────────────────")
print("  TICK       GRASS   ZEBRA  LION    ms/tick      TPS     GCUPS  PHASE")
print("──────────────────────────────────────────────────────────────────────────")

for t in 0..<tickLimit {
    let cyclePos = t % (dayLength + nightLength)
    let isDay = cyclePos < dayLength

    // Pure compute timing
    let tickStart = CFAbsoluteTimeGetCurrent()
    engine.tick(tickNumber: UInt32(t), isDay: isDay)
    let tickEnd = CFAbsoluteTimeGetCurrent()
    let tickMs = (tickEnd - tickStart) * 1000.0
    totalComputeTime += tickMs

    tickCount += 1

    // Snapshot for HTML viewer (skip in bench mode)
    if !benchMode {
        if let rec = recorder, rec.frameCount > 0 {
            rec.writeLiveSnapshot(to: snapshotPath, width: width, height: height, tick: t, isDay: isDay)
        } else {
            engine.writeSnapshot(to: snapshotPath, width: width, height: height, tick: t, isDay: isDay)
        }
    }

    // Speed control (skip in bench mode)
    if !benchMode {
        var sleepMs: UInt32 = 5
        if let s = try? String(contentsOfFile: "/tmp/savanna_sleep.txt").trimmingCharacters(in: .whitespacesAndNewlines),
           let ms = UInt32(s) { sleepMs = max(5, min(200, ms)) }
        usleep(sleepMs * 1000)
    }

    // Print stats every 100 ticks (or every 10 in bench mode)
    let interval = benchMode ? 10 : 100
    let now = CFAbsoluteTimeGetCurrent()
    if (t + 1) % interval == 0 || t == 0 {
        let c = engine.census()
        let avgMs = totalComputeTime / Double(tickCount)
        let tps = 1000.0 / avgMs
        let gcups = Double(width * height) * 7.0 * tps / 1_000_000_000.0
        let phase = isDay ? "DAY" : "NGT"

        print("  \(t+1)\t\(c.grass)\t\(c.zebra)\t\(c.lion)\t\(fmt(avgMs,2)) ms\t\(Int(tps))\t\(fmt(gcups,1)) B\t\(phase)")

        // Telemetry for HTML stats panel
        if !benchMode {
            let telemetry = """
            {"tick":\(t+1),"day":\((t+1)/4),"year":\(fmt(Double(t+1)/1460.0, 2)),\
            "ms":\(fmt(avgMs, 2)),"tps":\(Int(tps)),"speed":1,\
            "grass":\(c.grass),"zebra":\(c.zebra),"lion":\(c.lion),"energy":\(c.totalEnergy),\
            "dG":0,"dZ":0,"dL":0,\
            "ratio":\(fmt(c.zebra > 0 ? Double(c.zebra)/max(1,Double(c.lion)) : 0, 1)),\
            "grassPct":\(fmt(Double(c.grass)/Double(width*height)*100, 1)),\
            "nodes":\(width*height),"colors":7}
            """
            try? telemetry.write(toFile: "/tmp/savanna_telemetry.json", atomically: true, encoding: .utf8)
        }

        lastPrint = now
    }

    // Check for commands
    if !benchMode, let cmd = try? String(contentsOfFile: "/tmp/savanna_cmd.txt").trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
        if cmd.hasPrefix("archive") {
            let path = cmd.replacingOccurrences(of: "archive ", with: "")
            recorder?.archive(to: path, width: width, height: height)
        }
        try? "".write(toFile: "/tmp/savanna_cmd.txt", atomically: true, encoding: .utf8)
    }
}

// ── Summary ──────────────────────────────────────────────
let simEnd = CFAbsoluteTimeGetCurrent()
let wallTime = simEnd - simStart
let avgMs = totalComputeTime / Double(tickCount)
let avgTps = 1000.0 / avgMs
let gcups = Double(width * height) * 7.0 * avgTps / 1_000_000_000.0

print("──────────────────────────────────────────────────────────────────────────")
print()
print("  SUMMARY")
print("  Ticks:     \(tickCount)")
print("  Wall time: \(fmt(wallTime, 1))s")
print("  Compute:   \(fmt(avgMs, 2)) ms/tick (GPU only)")
print("  TPS:       \(Int(avgTps)) (GPU only)")
print("  GCUPS:     \(fmt(gcups, 1))")
print()
