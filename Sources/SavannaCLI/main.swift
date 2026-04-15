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

// Time: 1 tick = 6 hours, 4 ticks/day, 1460 ticks/year
let ticksPerDay = 4
let hoursPerTick = 6

// Parse --days or --ticks
let maxTicks: Int
if args.contains("--days") {
    let days = Int(arg("days", default: "30"))!
    maxTicks = days * ticksPerDay
} else {
    maxTicks = Int(arg("ticks", default: "0"))!  // 0 = infinite
}
let ramGB = Int(arg("ram", default: "4"))!        // GB for ring buffer
let recordDir = args.contains("--record") ? arg("record", default: "savanna_rec") : nil
let checkpointInterval = Int(arg("checkpoint", default: "0"))!  // 0 = disabled
let useGpuInit = args.contains("--gpu-init")  // Gemini Optimization B
let snapshotPath = "savanna_state.bin"
let dayLength = 730    // 6 months of day (was 10 — caused strobe flicker)
let nightLength = 730  // 6 months of night

// Parse --cells (1M, 100M, 1B, 1T) or --grid (side length)
func parseCells(_ s: String) -> Int {
    let upper = s.uppercased().trimmingCharacters(in: .whitespaces)
    var num = upper
    var multiplier = 1
    if num.hasSuffix("T") { num = String(num.dropLast()); multiplier = 1_000_000_000_000 }
    else if num.hasSuffix("B") { num = String(num.dropLast()); multiplier = 1_000_000_000 }
    else if num.hasSuffix("M") { num = String(num.dropLast()); multiplier = 1_000_000 }
    else if num.hasSuffix("K") { num = String(num.dropLast()); multiplier = 1_000 }
    if let n = Double(num) { return Int(n * Double(multiplier)) }
    return 1_048_576  // default 1M
}

let gridSize: Int
if args.contains("--cells") {
    let cellStr = arg("cells", default: "1M")
    let totalCells = parseCells(cellStr)
    gridSize = Int(sqrt(Double(totalCells)))
    // Round to nearest power of 2 for hex grid efficiency
    let log2 = Int(log2(Double(gridSize)))
    let rounded = 1 << log2
    if abs(rounded * rounded - totalCells) < abs((rounded * 2) * (rounded * 2) - totalCells) {
        // rounded is closer
    }
    print("  --cells \(cellStr) → grid \(gridSize)×\(gridSize) = \(gridSize * gridSize) cells")
} else {
    gridSize = Int(arg("grid", default: "1024"))!
}

let width = gridSize
let height = gridSize
let totalCellCount = width * height

// ── Disk space estimation + confirmation ────────────
if let dir = recordDir, maxTicks > 0 {
    let rawPerFrame = totalCellCount  // 1 byte per cell
    let estimatedDeltaPerFrame = rawPerFrame / 50  // ~50× compression
    let estimatedKeyframe = rawPerFrame / 2  // first frame ~2× compressed
    let estimatedTotal = estimatedKeyframe + estimatedDeltaPerFrame * (maxTicks - 1)
    let rawTotal = rawPerFrame * maxTicks

    func humanSize(_ bytes: Int) -> String {
        if bytes >= 1_000_000_000_000 { return String(format: "%.1f TB", Double(bytes) / 1e12) }
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1e9) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1e6) }
        if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1e3) }
        return "\(bytes) B"
    }

    func humanCells(_ n: Int) -> String {
        if n >= 1_000_000_000_000 { return String(format: "%.1fT", Double(n) / 1e12) }
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return "\(n)"
    }

    let simDays = maxTicks / ticksPerDay
    let simYears = Double(simDays) / 365.0
    let playbackSec = Double(maxTicks) / 60.0
    let playbackStr = playbackSec < 60 ? String(format: "%.1fs", playbackSec)
                    : String(format: "%.1f min", playbackSec / 60.0)

    // Check available disk
    let diskFree = (try? FileManager.default.attributesOfFileSystem(
        forPath: dir)[.systemFreeSize] as? Int) ?? 0

    print()
    print("  ╔═══════════════════════════════════════════════╗")
    print("  ║         SAVANNA SIMULATION PLAN               ║")
    print("  ╠═══════════════════════════════════════════════╣")
    print("  ║  \(humanCells(totalCellCount)) cells × \(simDays) days (\(String(format: "%.1f", simYears)) years)".padding(toLength: 51, withPad: " ", startingAt: 0) + "║")
    print("  ║  1 tick = \(hoursPerTick) hours → \(maxTicks) ticks total".padding(toLength: 51, withPad: " ", startingAt: 0) + "║")
    print("  ╠═══════════════════════════════════════════════╣")
    print("  ║  Raw data:         \(humanSize(rawTotal))".padding(toLength: 51, withPad: " ", startingAt: 0) + "║")
    print("  ║  Carlos Deltas:    ~\(humanSize(estimatedTotal)) (est. 50×)".padding(toLength: 51, withPad: " ", startingAt: 0) + "║")
    print("  ║  Disk free:        \(humanSize(diskFree))".padding(toLength: 51, withPad: " ", startingAt: 0) + "║")
    print("  ╠═══════════════════════════════════════════════╣")
    print("  ║  Playback (1x 60fps): \(playbackStr)".padding(toLength: 51, withPad: " ", startingAt: 0) + "║")
    print("  ║  Output: \(dir)/recording.savanna".padding(toLength: 51, withPad: " ", startingAt: 0) + "║")
    print("  ╚═══════════════════════════════════════════════╝")

    if estimatedTotal > diskFree {
        print()
        print("  ⚠️  WARNING: Estimated size (\(humanSize(estimatedTotal))) exceeds free disk (\(humanSize(diskFree)))")
    }

    print()
    print("  Reserve \(humanSize(estimatedTotal)) on disk and start? [Y/n] ", terminator: "")
    fflush(stdout)
    if let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
       answer == "n" || answer == "no" {
        print("  Aborted.")
        exit(0)
    }
}

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

// ── Build grid (cached — Gemini Optimization A: Immortal Grid) ──
let gridCachePath = "/tmp/savanna_hexgrid_\(width)x\(height).bin"
let t0 = CFAbsoluteTimeGetCurrent()
let grid: HexGrid
if let cached = HexGrid.load(from: gridCachePath) {
    grid = cached
    let t1 = CFAbsoluteTimeGetCurrent()
    print("  Loaded cached grid \(width)×\(height) in \(fmt(t1 - t0, 2))s")
} else {
    print("  Building hex grid...", terminator: "")
    fflush(stdout)
    grid = HexGrid(width: width, height: height)
    let t1 = CFAbsoluteTimeGetCurrent()
    print(" \(fmt(t1 - t0, 1))s")
    // Cache for next run
    do { try grid.save(to: gridCachePath); print("  Grid cached to \(gridCachePath)") }
    catch { print("  Warning: could not cache grid: \(error)") }
}
print("  7-colouring: [\(grid.colorGroups.map { "\($0.count)" }.joined(separator: ", "))]")

// ── Init state + Metal engine ────────────────────────────
let engine: MetalEngine
if useGpuInit {
    // Gemini B: GPU genesis — allocate empty state, init on GPU
    print("  GPU genesis init...", terminator: "")
    fflush(stdout)
    let state = SavannaState(width: width, height: height)  // empty arrays
    do { engine = try MetalEngine(grid: grid, state: state) }
    catch { print(" FATAL: \(error)"); exit(1) }
    let tGpu0 = CFAbsoluteTimeGetCurrent()
    engine.gpuInit(seed: UInt32.random(in: 0...UInt32.max))
    let tGpu1 = CFAbsoluteTimeGetCurrent()
    print(" \(fmt((tGpu1 - tGpu0) * 1000, 1))ms")
} else {
    // CPU init (original path)
    print("  Initialising state...", terminator: "")
    fflush(stdout)
    var state = SavannaState(width: width, height: height)
    state.randomInit(grid: grid)
    let c0 = state.census()
    print(" \(fmt(CFAbsoluteTimeGetCurrent() - t0, 1))s")
    print("  Census: grass=\(c0.grass) zebra=\(c0.zebra) lion=\(c0.lion)")
    print("  Creating Metal engine...", terminator: "")
    fflush(stdout)
    do { engine = try MetalEngine(grid: grid, state: state) }
    catch { print(" FATAL: \(error)"); exit(1) }
    print(" \(fmt(CFAbsoluteTimeGetCurrent() - t0, 1))s")
}
// Census from GPU buffers
let c0 = engine.census()
print("  Census: grass=\(c0.grass) zebra=\(c0.zebra) lion=\(c0.lion)")

// ── Recorder ─────────────────────────────────────────────
let frameBytes = width * height
let recorderCapacity = ramGB * 1_000_000_000 / frameBytes
let recorder = SimRecorder(device: device, grid: grid, capacity: min(recorderCapacity, 200_000))
if let rec = recorder, !benchMode && recordDir == nil {
    engine.recorder = rec
    print("  Recorder: \(rec.capacity) frames (\(rec.capacity * frameBytes / 1_000_000) MB)")
}

// ── Frame recording to disk ──────────────────────────────
if let dir = recordDir {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // Write meta.json
    let meta = "{\"width\":\(width),\"height\":\(height),\"frame_count\":0,\"seed\":42}"
    try? meta.write(toFile: "\(dir)/meta.json", atomically: true, encoding: .utf8)
    print("  Recording to: \(dir)/")
}

if checkpointInterval > 0 {
    print("  Checkpointing every \(checkpointInterval) ticks")
}

print()

// ── Carlos Delta encoder (I-frame / P-frame, replaces raw frame writes) ────
import Dispatch
let asyncWriteQueue = DispatchQueue(label: "savanna.frame-writer", qos: .userInitiated)
let keyframeInterval = 60  // I-frame every 60 frames (15 sim-days)
var deltaEncoder: CarlosDelta.Encoder? = nil
if let dir = recordDir {
    let deltaPath: String
    if dir.hasSuffix(".savanna") {
        // Direct filename: --record my_recording.savanna
        deltaPath = dir
        let parent = (deltaPath as NSString).deletingLastPathComponent
        if !parent.isEmpty { try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) }
    } else {
        // Directory: --record savanna_rec → savanna_rec/recording.savanna
        deltaPath = "\(dir)/recording.savanna"
    }
    deltaEncoder = try? CarlosDelta.Encoder(path: deltaPath, width: width, height: height,
                                             keyframeInterval: keyframeInterval)
    if deltaEncoder != nil {
        print("  Carlos Delta encoder: \(deltaPath)")
        print("  I-frame interval: every \(keyframeInterval) frames")
    }
}

// ── Run ──────────────────────────────────────────────────
let tickLimit = maxTicks > 0 ? maxTicks : Int.max
var tickCount = 0
var simTick = 0  // resets on N key
var totalComputeTime: Double = 0
let simStart = CFAbsoluteTimeGetCurrent()
var lastPrint = simStart

// Header
print("──────────────────────────────────────────────────────────────────────────")
print("  TICK       GRASS   ZEBRA  LION    ms/tick      TPS     GCUPS  PHASE")
print("──────────────────────────────────────────────────────────────────────────")

for t in 0..<tickLimit {
    let cyclePos = simTick % (dayLength + nightLength)
    let isDay = cyclePos < dayLength

    // Pure compute timing
    let tickStart = CFAbsoluteTimeGetCurrent()
    engine.tick(tickNumber: UInt32(simTick), isDay: isDay)
    let tickEnd = CFAbsoluteTimeGetCurrent()
    let tickMs = (tickEnd - tickStart) * 1000.0
    totalComputeTime += tickMs

    tickCount += 1
    simTick += 1

    // Snapshot for HTML viewer (skip in bench mode and record mode)
    if !benchMode && recordDir == nil {
        if let rec = recorder, rec.frameCount > 0 {
            rec.writeLiveSnapshot(to: snapshotPath, width: width, height: height, tick: simTick, isDay: isDay)
        } else {
            engine.writeSnapshot(to: snapshotPath, width: width, height: height, tick: simTick, isDay: isDay)
        }
    }

    // Frame recording — Carlos Delta encoding (XOR + zlib, Morton order on disk)
    if let enc = deltaEncoder {
        let entities = engine.readEntities()  // Morton order — no de-Morton, straight to disk
        asyncWriteQueue.async {
            enc.addFrame(entities)
        }
    } else if let dir = recordDir {
        // Fallback: raw frame write (row-major for compatibility)
        let entities = engine.readEntitiesRowMajor()
        let framePath = "\(dir)/frame_\(String(format: "%06d", t)).bin"
        let frameNum = t + 1
        asyncWriteQueue.async {
            entities.withUnsafeBytes { ptr in
                let data = Data(bytes: ptr.baseAddress!, count: ptr.count)
                try? data.write(to: URL(fileURLWithPath: framePath))
            }
            let meta = "{\"width\":\(width),\"height\":\(height),\"frame_count\":\(frameNum),\"seed\":42}"
            try? meta.write(toFile: "\(dir)/meta.json", atomically: true, encoding: .utf8)
        }
    }

    // Checkpointing (save full state for resume)
    if checkpointInterval > 0 && (t + 1) % checkpointInterval == 0 {
        let cpDir = (recordDir ?? ".") + "/checkpoints"
        try? FileManager.default.createDirectory(atPath: cpDir, withIntermediateDirectories: true)
        let cpPath = "\(cpDir)/checkpoint_\(String(format: "%06d", t)).bin"
        // Write all state channels
        let ent = engine.readEntities()
        var cpData = Data()
        var w32 = UInt32(width), h32 = UInt32(height), tick32 = UInt32(t)
        cpData.append(Data(bytes: &w32, count: 4))
        cpData.append(Data(bytes: &h32, count: 4))
        cpData.append(Data(bytes: &tick32, count: 4))
        ent.withUnsafeBytes { cpData.append(Data(bytes: $0.baseAddress!, count: $0.count)) }
        try? cpData.write(to: URL(fileURLWithPath: cpPath))
        print("  [CHECKPOINT] \(cpPath) (\(cpData.count / 1_000_000) MB)")
    }

    // Speed control (skip in bench mode)
    if !benchMode {
        var sleepMs: UInt32 = 5
        if let s = try? String(contentsOfFile: "savanna_sleep.txt").trimmingCharacters(in: .whitespacesAndNewlines),
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

        print("  \(simTick)\t\(c.grass)\t\(c.zebra)\t\(c.lion)\t\(fmt(avgMs,2)) ms\t\(Int(tps))\t\(fmt(gcups,1)) B\t\(phase)")

        // Telemetry for HTML stats panel
        if !benchMode {
            let telemetry = """
            {"tick":\(simTick),"day":\(simTick/4),"year":\(fmt(Double(simTick)/1460.0, 2)),\
            "ms":\(fmt(avgMs, 2)),"tps":\(Int(tps)),"speed":1,\
            "grass":\(c.grass),"zebra":\(c.zebra),"lion":\(c.lion),"energy":\(c.totalEnergy),\
            "dG":0,"dZ":0,"dL":0,\
            "ratio":\(fmt(c.zebra > 0 ? Double(c.zebra)/max(1,Double(c.lion)) : 0, 1)),\
            "grassPct":\(fmt(Double(c.grass)/Double(width*height)*100, 1)),\
            "nodes":\(width*height),"colors":7}
            """
            try? telemetry.write(toFile: "savanna_telemetry.json", atomically: true, encoding: .utf8)
        }

        lastPrint = now
    }

    // Check for commands
    if !benchMode, let cmd = try? String(contentsOfFile: "savanna_cmd.txt").trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
        if cmd.hasPrefix("archive") {
            let path = cmd.replacingOccurrences(of: "archive ", with: "")
            recorder?.archive(to: path, width: width, height: height)
        } else if cmd == "reset" || cmd.hasPrefix("scenario ") {
            // Parse scenario params if present
            var zFrac = 0.286, lFrac = 0.00286, gFrac = 0.80
            if cmd.hasPrefix("scenario ") {
                let jsonStr = String(cmd.dropFirst("scenario ".count))
                if let data = jsonStr.data(using: .utf8),
                   let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    zFrac = params["zebraFrac"] as? Double ?? zFrac
                    lFrac = params["lionFrac"] as? Double ?? lFrac
                    gFrac = params["grassFrac"] as? Double ?? gFrac
                    print("  [SCENARIO] zebra=\(zFrac) lion=\(lFrac) grass=\(gFrac)")
                }
            }
            var newState = SavannaState(width: width, height: height)
            newState.randomInit(grid: grid, grassFrac: gFrac, zebraFrac: zFrac,
                                lionFrac: lFrac, seed: UInt64.random(in: 0...UInt64.max))
            let entities = newState.entity
            let energies = newState.energy
            let ternaries = newState.ternary
            let gauges = newState.gauge
            let orientations = newState.orientation
            entities.withUnsafeBytes { engine.entityBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: entities.count) }
            energies.withUnsafeBytes { engine.energyBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: energies.count * 2) }
            ternaries.withUnsafeBytes { engine.ternaryBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: ternaries.count) }
            gauges.withUnsafeBytes { engine.gaugeBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: gauges.count * 2) }
            orientations.withUnsafeBytes { engine.orientationBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: orientations.count) }
            totalComputeTime = 0; tickCount = 0; simTick = 0
        }
        try? "".write(toFile: "savanna_cmd.txt", atomically: true, encoding: .utf8)
    }
}

// Flush async writes and finalize delta encoder
asyncWriteQueue.sync {}
if let enc = deltaEncoder {
    enc.finalize()
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: enc.url.path)[.size] as? Int) ?? 0
    print("  Carlos Delta: \(enc.frameCount) frames (\(enc.iFrameCount) I + \(enc.pFrameCount) P), \(fileSize / 1_000_000) MB compressed")
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
