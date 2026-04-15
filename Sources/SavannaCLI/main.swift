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
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        deltaPath = "\(dir)/recording.savanna"
    }
    let encFormat: CarlosDelta.Format = args.contains("--zlib") ? .zlib : .sparse
    deltaEncoder = try? CarlosDelta.Encoder(path: deltaPath, width: width, height: height,
                                             keyframeInterval: keyframeInterval, format: encFormat)
    if deltaEncoder != nil {
        print("  Carlos Delta encoder: \(deltaPath)")
        print("  Format: \(encFormat == .sparse ? "sparse scatter (GPU-native)" : "zlib (CPU)")")
        print("  I-frame interval: every \(keyframeInterval) frames")
    }
}

// ── Built-in HTTP Server (replaces Python serve.py) ──────
import Darwin

let serverPort: UInt16 = {
    if let i = args.firstIndex(of: "--port"), i + 1 < args.count {
        return UInt16(args[i + 1]) ?? 8800
    }
    return 8800
}()

// Shared state for HTTP server (written by sim, read by server)
var latestTelemetry = ""
var pendingCommand = ""
let commandLock = NSLock()

// Snapshot buffer: written by sim thread, read by HTTP thread
var snapshotData = Data()
let snapshotLock = NSLock()

func buildSnapshot() {
    let entities = engine.readEntitiesRowMajor()
    var w = UInt32(width), h = UInt32(height)
    var t = UInt32(simTick), d: UInt32 = 1
    var data = Data()
    data.append(Data(bytes: &w, count: 4))
    data.append(Data(bytes: &h, count: 4))
    data.append(Data(bytes: &t, count: 4))
    data.append(Data(bytes: &d, count: 4))
    entities.withUnsafeBytes { data.append(Data($0)) }
    snapshotLock.lock()
    snapshotData = data
    snapshotLock.unlock()
}

func handleHTTPRequest(_ clientFd: Int32) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = read(clientFd, &buffer, buffer.count)
    guard n > 0 else { close(clientFd); return }

    let request = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
    let reqPath = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

    var responseBody = Data()
    var contentType = "text/plain"
    var statusLine = "HTTP/1.1 200 OK\r\n"

    if reqPath == "/info" || reqPath == "/info?" {
        contentType = "application/json"
        let info = "{\"width\":\(width),\"height\":\(height),\"frame_count\":0,\"cells\":\(width*height),\"total_cells\":\(width*height)}"
        responseBody = info.data(using: .utf8)!

    } else if reqPath.hasPrefix("/savanna_state.bin") {
        contentType = "application/octet-stream"
        snapshotLock.lock()
        responseBody = snapshotData
        snapshotLock.unlock()

    } else if reqPath == "/savanna_telemetry.json" {
        contentType = "application/json"
        responseBody = latestTelemetry.data(using: .utf8) ?? Data()

    } else if reqPath == "/reset" {
        commandLock.lock()
        pendingCommand = "reset"
        commandLock.unlock()
        responseBody = "ok".data(using: .utf8)!

    } else if reqPath == "/scenarios" {
        contentType = "application/json"
        var scenarios = [[String: Any]]()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: "scenarios") {
            for f in files.sorted() where f.hasSuffix(".json") {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: "scenarios/\(f)")),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    scenarios.append(obj)
                }
            }
        }
        if let json = try? JSONSerialization.data(withJSONObject: scenarios) {
            responseBody = json
        }

    } else if reqPath.hasPrefix("/load_scenario") {
        contentType = "application/json"
        let query = reqPath.split(separator: "?").dropFirst().first.map(String.init) ?? ""
        let name = query.replacingOccurrences(of: "name=", with: "").removingPercentEncoding ?? ""
        if let files = try? FileManager.default.contentsOfDirectory(atPath: "scenarios") {
            for f in files.sorted() where f.hasSuffix(".json") {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: "scenarios/\(f)")),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sName = obj["name"] as? String, sName == name,
                   let params = obj["params"] {
                    if let paramsData = try? JSONSerialization.data(withJSONObject: params) {
                        commandLock.lock()
                        pendingCommand = "scenario \(String(data: paramsData, encoding: .utf8) ?? "{}")"
                        commandLock.unlock()
                    }
                    responseBody = "{\"ok\":true}".data(using: .utf8)!
                    break
                }
            }
        }
        if responseBody.isEmpty { responseBody = "{\"ok\":false}".data(using: .utf8)! }

    } else if reqPath == "/set_speed" || reqPath.hasPrefix("/set_speed?") {
        responseBody = "ok".data(using: .utf8)!

    } else {
        // Static files from current directory
        let filename = String(reqPath.dropFirst())
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url) {
            responseBody = data
            if filename.hasSuffix(".html") { contentType = "text/html" }
            else if filename.hasSuffix(".js") { contentType = "application/javascript" }
            else if filename.hasSuffix(".css") { contentType = "text/css" }
            else { contentType = "application/octet-stream" }
        } else {
            statusLine = "HTTP/1.1 404 Not Found\r\n"
            responseBody = "404".data(using: .utf8)!
        }
    }

    let headers = "\(statusLine)Content-Type: \(contentType)\r\nContent-Length: \(responseBody.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
    let headerData = headers.data(using: .utf8)!
    headerData.withUnsafeBytes { _ = write(clientFd, $0.baseAddress!, headerData.count) }
    responseBody.withUnsafeBytes { _ = write(clientFd, $0.baseAddress!, responseBody.count) }
    close(clientFd)
}

// Start HTTP server on background thread
if !benchMode {
    let serverFd = socket(AF_INET, SOCK_STREAM, 0)
    var opt: Int32 = 1
    setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = serverPort.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY.bigEndian
    withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(serverFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    listen(serverFd, 10)
    print("  HTTP server: http://localhost:\(serverPort)/savanna_live.html")

    DispatchQueue.global(qos: .userInteractive).async {
        while true {
            let clientFd = accept(serverFd, nil, nil)
            if clientFd >= 0 {
                DispatchQueue.global(qos: .userInitiated).async {
                    handleHTTPRequest(clientFd)
                }
            }
        }
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

    // Build snapshot in memory for HTTP server (no disk write)
    if !benchMode && recordDir == nil {
        buildSnapshot()
    }

    // Frame recording — Carlos Delta encoding (XOR + zlib, Morton order on disk)
    if let enc = deltaEncoder {
        let entities = engine.readEntities()  // Morton order — no de-Morton, straight to disk
        asyncWriteQueue.async {
            enc.addFrame(entities)
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

        // Telemetry — in memory for HTTP server (no disk write)
        if !benchMode {
            latestTelemetry = """
            {"tick":\(simTick),"day":\(simTick/4),"year":\(fmt(Double(simTick)/1460.0, 2)),\
            "ms":\(fmt(avgMs, 2)),"tps":\(Int(tps)),"speed":1,\
            "grass":\(c.grass),"zebra":\(c.zebra),"lion":\(c.lion),"energy":\(c.totalEnergy),\
            "dG":0,"dZ":0,"dL":0,\
            "ratio":\(fmt(c.zebra > 0 ? Double(c.zebra)/max(1,Double(c.lion)) : 0, 1)),\
            "grassPct":\(fmt(Double(c.grass)/Double(width*height)*100, 1)),\
            "nodes":\(width*height),"colors":7}
            """
        }

        lastPrint = now
    }

    // Check for commands (in-memory from HTTP server, no disk polling)
    commandLock.lock()
    let cmd = pendingCommand
    pendingCommand = ""
    commandLock.unlock()
    if !cmd.isEmpty {
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
            // Immediately update snapshot + telemetry after reset
            buildSnapshot()
            let c = engine.census()
            latestTelemetry = """
            {"tick":0,"day":0,"year":0,"ms":0,"tps":0,"speed":1,\
            "grass":\(c.grass),"zebra":\(c.zebra),"lion":\(c.lion),"energy":0,\
            "dG":0,"dZ":0,"dL":0,"ratio":0,"grassPct":0,\
            "nodes":\(width*height),"colors":7}
            """
            print("  [RESET] grass=\(c.grass) zebra=\(c.zebra) lion=\(c.lion)")
        }
    }
}

// Flush async writes and finalize delta encoder
asyncWriteQueue.sync {}
if let enc = deltaEncoder {
    enc.finalize()
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: enc.url.path)[.size] as? Int) ?? 0
    let avgEntries = enc.pFrameCount > 0 ? enc.totalSparseEntries / UInt64(enc.pFrameCount) : 0
    let sparsePct = enc.pFrameCount > 0 && totalCellCount > 0 ?
        String(format: "%.1f", Double(avgEntries) / Double(totalCellCount) * 100) : "0"
    print("  Carlos Delta: \(enc.frameCount) frames (\(enc.iFrameCount) I + \(enc.pFrameCount) P), \(fileSize / 1_000_000) MB")
    if enc.totalSparseEntries > 0 {
        print("  Sparse: \(avgEntries) avg entries/frame (\(sparsePct)% change rate)")
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
