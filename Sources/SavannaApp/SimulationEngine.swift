/// SimulationEngine — Observable model driving all three windows.
///
/// Owns the Metal engine, hex grid, and simulation state.
/// Published properties update SwiftUI views automatically.

import SwiftUI
import Metal
import Savanna

@MainActor
class SimulationEngine: ObservableObject {
    static let version = "0.5.0"  // bump on each build

    enum PlacementMode { case none, zebra, lion }
    @Published var placementMode: PlacementMode = .none

    // Zoom/Pan
    @Published var zoom: Double = 1.0
    @Published var panX: Float = 0
    @Published var panY: Float = 0

    // Time control
    static let speedTiers = ["1x", "2x", "4x", "10x", "32x", "100x", "MAX"]
    static let speedSleeps: [UInt32] = [50, 25, 12, 5, 2, 0, 0]
    @Published var speedTier: Int = 0
    @Published var speedLabel: String = "1x"
    @Published var showSpeedIndicator = false

    // Population history for graph
    struct PopSnapshot { var zebra: Int; var lion: Int; var grass: Int }
    @Published var populationHistory: [PopSnapshot] = []
    private let maxHistory = 600  // 10 minutes at 1 sample/sec

    // State
    @Published var isRunning = false
    @Published var tick: Int = 0
    @Published var simDay: Int = 0
    @Published var simYear: Double = 0
    @Published var tps: Double = 0
    @Published var gcups: Double = 0
    @Published var msPerTick: Double = 0

    // Census
    @Published var grass: Int = 0
    @Published var zebra: Int = 0
    @Published var lion: Int = 0
    @Published var water: Int = 0
    @Published var totalEnergy: Int = 0

    // Parameters (live-tunable from DJ panel)
    @Published var gridSize: Int = 1000
    @Published var cellCount: Int = 1_000_000
    @Published var windEnabled: Bool = true
    @Published var windDirection: Double = 0  // radians
    @Published var windStrength: Double = 0.5
    @Published var ghostWind: Bool = false  // use topology as wind (zero cost)
    @Published var ghostStrength: Double = 0.5  // 0=unbiased, 1=full ratchet
    @Published var zebraFrac: Double = 0.02
    @Published var lionFrac: Double = 0.00025
    @Published var grassFrac: Double = 0.80

    // Scenario
    @Published var currentScenario: String = "Default"
    @Published var scenarios: [ScenarioPreset] = []

    // Recording
    @Published var isRecording = false
    @Published var recordedFrames: Int = 0

    // Internal
    var metalEngine: MetalEngine?
    var grid: HexGrid?
    var mortonRankBuf: MTLBuffer?  // rowMajor→rank mapping for GPU rendering
    private var tickTimer: Timer?
    private var tickCount: Int = 0
    private var totalComputeTime: Double = 0

    // Day/night cycle
    let dayLength = 730
    let nightLength = 730

    init() {
        loadScenarios()
        // Auto-start with 1M Serengeti — no clicks needed
        zebraFrac = 0.04
        lionFrac = 0.002
        grassFrac = 0.85
        windEnabled = true
        // Delay to let SwiftUI/Metal view initialize first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setup(cells: 1_000_000)
            self?.start()
        }
    }

    func setup(cells: Int) {
        let side = Int(sqrt(Double(cells)))
        gridSize = side
        cellCount = side * side

        // Build or load cached grid
        let cachePath = "/tmp/savanna_hexgrid_\(side)x\(side).bin"
        if let cached = HexGrid.load(from: cachePath) {
            grid = cached
        } else {
            grid = HexGrid(width: side, height: side)
            try? grid?.save(to: cachePath)
        }

        // Init state
        guard let g = grid else { return }
        var state = SavannaState(width: side, height: side)
        state.randomInit(grid: g, grassFrac: grassFrac, zebraFrac: zebraFrac,
                         lionFrac: lionFrac, seed: UInt64.random(in: 0...UInt64.max),
                         bare: false)

        do {
            metalEngine = try MetalEngine(grid: g, state: state)
            // Push wind state immediately — before first tick
            metalEngine!.windActive = windEnabled
            metalEngine!.windOverride = windEnabled ?
                UInt32(round(windDirection / (2.0 * .pi) * 6.0)) % 6 : nil
            metalEngine!.windStrength = Float(windStrength)
            // Build mortonRank GPU buffer for direct rendering
            if let device = metalEngine?.device {
                mortonRankBuf = device.makeBuffer(
                    bytes: g.mortonRank,
                    length: g.mortonRank.count * 4,
                    options: .storageModeShared)
            }
            updateCensus()
        } catch {
            print("Metal init failed: \(error)")
        }
    }

    func start() {
        guard metalEngine != nil else { return }
        isRunning = true
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning, let engine = self.metalEngine else { return }

            // Pure GPU ticks — no @Published updates, no SwiftUI redraws
            let deadline = CFAbsoluteTimeGetCurrent() + 0.008
            while CFAbsoluteTimeGetCurrent() < deadline && self.isRunning {
                let cyclePos = self.tick % (self.dayLength + self.nightLength)
                let isDay = cyclePos < self.dayLength

                engine.windActive = self.windEnabled
                engine.ghostWindEnabled = self.ghostWind
                engine.ghostWindStrength = Float(self.ghostStrength)
                engine.windStrength = Float(self.windStrength)

                let t0 = CFAbsoluteTimeGetCurrent()
                engine.tick(tickNumber: UInt32(self.tick), isDay: isDay)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

                self.totalComputeTime += ms
                self.tickCount += 1
                self.tick += 1
            }

            // UI update once per frame (not per tick)
            self.simDay = self.tick / 4
            self.simYear = Double(self.tick) / 1460.0
            if self.tickCount > 0 {
                self.msPerTick = self.totalComputeTime / Double(self.tickCount)
                self.tps = 1000.0 / self.msPerTick
                self.gcups = Double(self.cellCount) * 7.0 * self.tps / 1_000_000_000.0
            }

            // Census + graph — every 0.5 seconds, not every tick
            if self.tick % max(1, Int(self.tps / 2)) == 0 {
                self.updateCensus()
                self.populationHistory.append(PopSnapshot(zebra: self.zebra, lion: self.lion, grass: self.grass))
                if self.populationHistory.count > self.maxHistory { self.populationHistory.removeFirst() }
            }
        }
    }

    func stop() {
        isRunning = false
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func reset() {
        stop()
        tick = 0
        tickCount = 0
        totalComputeTime = 0
        guard let g = grid else { return }
        var state = SavannaState(width: gridSize, height: gridSize)
        state.randomInit(grid: g, grassFrac: grassFrac, zebraFrac: zebraFrac,
                         lionFrac: lionFrac, seed: UInt64.random(in: 0...UInt64.max),
                         bare: false)
        let entities = state.entity
        let energies = state.energy
        let ternaries = state.ternary
        let gauges = state.gauge
        let orientations = state.orientation
        entities.withUnsafeBytes { metalEngine?.entityBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        energies.withUnsafeBytes { metalEngine?.energyBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        ternaries.withUnsafeBytes { metalEngine?.ternaryBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        gauges.withUnsafeBytes { metalEngine?.gaugeBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        orientations.withUnsafeBytes { metalEngine?.orientationBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        populationHistory.removeAll()
        metalEngine?.resetScent()
        metalEngine?.windActive = windEnabled
        metalEngine?.windOverride = windEnabled ? UInt32(round(windDirection / (2.0 * .pi) * 6.0)) % 6 : nil
        updateCensus()
    }

    private func simulateTick() {
        guard let engine = metalEngine, isRunning else { return }

        // Push wind settings to Metal engine EVERY tick
        engine.windActive = windEnabled
        // Convert compass radians to hex direction
        // Compass: 0=N, π/2=E, π=S, 3π/2=W (clockwise from north)
        // Hex dirs: 0=NE, 1=N, 2=NW, 3=SW, 4=S, 5=SE
        // Map: N→1, NE→0, E→5, SE→5, S→4, SW→3, W→2, NW→2
        var deg = windDirection * 180.0 / .pi
        if deg < 0 { deg += 360 }
        let hexDir: UInt32
        if deg < 30 || deg >= 330 { hexDir = 1 }       // N
        else if deg < 90 { hexDir = 0 }                  // NE
        else if deg < 150 { hexDir = 5 }                  // SE
        else if deg < 210 { hexDir = 4 }                  // S
        else if deg < 270 { hexDir = 3 }                  // SW
        else { hexDir = 2 }                                // NW
        engine.windOverride = windEnabled ? hexDir : nil
        engine.windStrength = Float(windStrength)

        // Ghost wind — topology as wind (zero cost)
        engine.ghostWindEnabled = ghostWind
        engine.ghostWindStrength = Float(ghostStrength)
        engine.ghostWindDirection = hexDir  // same compass direction

        let cyclePos = tick % (dayLength + nightLength)
        let isDay = cyclePos < dayLength

        let t0 = CFAbsoluteTimeGetCurrent()
        engine.tick(tickNumber: UInt32(tick), isDay: isDay)
        let t1 = CFAbsoluteTimeGetCurrent()
        let ms = (t1 - t0) * 1000

        totalComputeTime += ms
        tickCount += 1
        tick += 1
        simDay = tick / 4
        simYear = Double(tick) / 1460.0
        msPerTick = totalComputeTime / Double(tickCount)
        tps = 1000.0 / msPerTick
        gcups = Double(cellCount) * 7.0 * tps / 1_000_000_000.0

        // Update census every 100 ticks (was 20 — SwiftUI redraws are expensive)
        if tick % 100 == 0 {
            updateCensus()
        }

        // Sample population for graph every 200 ticks (slow — avoids array churn)
        if tick % 200 == 0 {
            populationHistory.append(PopSnapshot(zebra: zebra, lion: lion, grass: grass))
            if populationHistory.count > maxHistory {
                populationHistory.removeFirst()
            }
        }

        // Speed control handled by Timer batch size
    }

    private func updateCensus() {
        guard let engine = metalEngine else { return }
        let c = engine.census()
        grass = c.grass
        zebra = c.zebra
        lion = c.lion
        totalEnergy = c.totalEnergy
    }

    func loadScenarios() {
        scenarios = []
        let fm = FileManager.default
        let scenarioDir = "scenarios"
        guard let files = try? fm.contentsOfDirectory(atPath: scenarioDir) else { return }
        for f in files.sorted() where f.hasSuffix(".json") {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(scenarioDir)/\(f)")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["name"] as? String {
                let desc = obj["description"] as? String ?? ""
                let emoji = obj["emoji"] as? String ?? ""
                let voiceover = obj["voiceover"] as? String ?? ""
                scenarios.append(ScenarioPreset(name: name, description: desc, emoji: emoji, voiceover: voiceover, params: obj["params"] as? [String: Any] ?? [:]))
            }
        }
    }

    func loadScenario(_ preset: ScenarioPreset) {
        currentScenario = preset.name
        zebraFrac = preset.params["zebraFrac"] as? Double ?? zebraFrac
        lionFrac = preset.params["lionFrac"] as? Double ?? lionFrac
        grassFrac = preset.params["grassFrac"] as? Double ?? grassFrac
        reset()
        start()
    }

    /// Get entity buffer as row-major for rendering
    func getEntityBuffer() -> [Int8]? {
        return metalEngine?.readEntitiesRowMajor()
    }

    func cycleSpeed() {
        speedTier = (speedTier + 1) % Self.speedTiers.count
        speedLabel = Self.speedTiers[speedTier]
        showSpeedIndicator = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showSpeedIndicator = false
        }
    }

    /// Place animals at grid position (from click in viewer)
    /// Left click = 100 zebras tight. Alt+click = 10 lions diffuse.
    func placeCluster(col: Int, row: Int, isLion: Bool) {
        guard let engine = metalEngine, let g = grid else { return }

        let ptr = engine.entityBuf.contents().bindMemory(to: Int8.self, capacity: cellCount)
        let ePtr = engine.energyBuf.contents().bindMemory(to: Int16.self, capacity: cellCount)
        let oPtr = engine.orientationBuf.contents().bindMemory(to: Int8.self, capacity: cellCount)

        let entityType: Int8 = isLion ? 3 : 2
        let energyVal: Int16 = isLion ? 4000 : 200
        // Scale with grid size — 10M needs 10x more than 1M
        let scale = max(1, gridSize / 1000)
        let count = isLion ? 10 * scale : 1000 * scale
        let radius = isLion ? 15 * scale : 20 * scale

        var placed = 0
        for _ in 0..<count * 3 {  // oversample to handle occupied cells
            if placed >= count { break }
            let dx = Int.random(in: -radius...radius)
            let dy = Int.random(in: -radius...radius)
            if dx*dx + dy*dy > radius*radius { continue }
            let cx = col + dx, cy = row + dy
            if cx < 0 || cx >= gridSize || cy < 0 || cy >= gridSize { continue }
            let rm = cy * gridSize + cx
            let m = Int(g.mortonRank[rm])
            if ptr[m] == 0 || ptr[m] == 1 {  // empty or grass
                ptr[m] = entityType
                ePtr[m] = energyVal
                oPtr[m] = Int8.random(in: 0...5)
                placed += 1
            }
        }
    }
}

struct ScenarioPreset: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let emoji: String
    let voiceover: String
    let params: [String: Any]
}
