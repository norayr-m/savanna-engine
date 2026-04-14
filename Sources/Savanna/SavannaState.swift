/// SavannaState — All state arrays for the simulation.
/// Arrays are indexed by Morton rank (not row-major). See HexGrid.mortonRank.

import Foundation

public struct SavannaCensus {
    public let empty: Int
    public let grass: Int
    public let zebra: Int
    public let lion: Int
    public let totalEnergy: Int
}

public struct SavannaState {
    public let width: Int
    public let height: Int
    public var entity: [Int8]
    public var energy: [Int16]
    public var ternary: [Int8]
    public var gauge: [Int16]
    public var orientation: [Int8]  // 0-5: hex facing direction

    public var nodeCount: Int { width * height }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let n = width * height
        self.entity = [Int8](repeating: 0, count: n)
        self.energy = [Int16](repeating: 0, count: n)
        self.ternary = [Int8](repeating: 0, count: n)
        self.gauge = [Int16](repeating: 0, count: n)
        self.orientation = [Int8](repeating: 0, count: n)
    }

    /// Random initialization matching Python engine fractions.
    /// All array writes go through grid.mortonRank for Morton-ordered buffers.
    public mutating func randomInit(
        grid: HexGrid,
        grassFrac: Double = 0.80,
        zebraFrac: Double = 0.005,  // sparse — see dynamics not blobs
        lionFrac: Double = 0.00025,  // ~250 lions = ~62 prides
        seed: UInt64 = 42
    ) {
        var rng = SplitMix64(seed: seed)
        let n = nodeCount
        let mr = grid.mortonRank  // local ref for speed

        // Helper: (col, row) → Morton rank buffer index
        func mi(_ col: Int, _ row: Int) -> Int {
            return Int(mr[row * width + col])
        }

        // Neighbor offsets for even/odd columns (flat-top odd-q hex)
        let evenOff: [(Int,Int)] = [(1,-1),(0,-1),(-1,-1),(-1,0),(0,1),(1,0)]
        let oddOff:  [(Int,Int)] = [(1,0), (0,-1),(-1,0), (-1,1),(0,1),(1,1)]

        // ── Place water: flood-fill lakes from seed ──────────
        let numLakes = max(8, width * height / 80_000)
        var lakeCenters: [(Int, Int)] = []
        for _ in 0..<numLakes {
            let cx = Int(rng.next() % UInt64(width))
            let cy = Int(rng.next() % UInt64(height))
            lakeCenters.append((cx, cy))
            let lakeSize = 500 + Int(rng.next() % 1500)

            var frontier = [(cx, cy)]
            entity[mi(cx, cy)] = Entity.water.rawValue
            var placed = 1

            while placed < lakeSize && !frontier.isEmpty {
                let fi = Int(rng.next() % UInt64(frontier.count))
                let (fx, fy) = frontier[fi]
                let offsets = (fx & 1 == 1) ? oddOff : evenOff

                let startDir = Int(rng.next() % 6)
                var added = false
                for dd in 0..<6 {
                    let d = (startDir + dd) % 6
                    let nx = fx + offsets[d].0
                    let ny = fy + offsets[d].1
                    if nx >= 0 && nx < width && ny >= 0 && ny < height {
                        let m = mi(nx, ny)
                        if entity[m] != Entity.water.rawValue {
                            entity[m] = Entity.water.rawValue
                            frontier.append((nx, ny))
                            placed += 1
                            added = true
                            break
                        }
                    }
                }
                if !added {
                    frontier.swapAt(fi, frontier.count - 1)
                    frontier.removeLast()
                }
            }
        }

        // ── Place grass (skip water cells) ────────────────────
        for y in 0..<height {
            for x in 0..<width {
                let m = mi(x, y)
                if entity[m] == Entity.water.rawValue { continue }
                let r = Double(rng.next() & 0xFFFFFFFF) / Double(UInt32.max)
                if r < grassFrac {
                    entity[m] = Entity.grass.rawValue
                    gauge[m] = Int16.random(in: 0...255)
                }
            }
        }

        // ── Place zebras TOP-LEFT, lions BEHIND ────────────
        let zebraTotal = Int(Double(n) * zebraFrac)
        let cooldownZ = 365  // must match REPRO_COOLDOWN_ZEBRA in metal
        let reproAgeZ = 730  // must match REPRO_AGE_ZEBRA in metal
        let maxAgeZ   = 32000
        // Zebras: one massive herd, position varies by seed
        let zCx = width / 4 + Int(rng.next() % UInt64(width / 2))
        let zCy = height / 4 + Int(rng.next() % UInt64(height / 2))
        let spread = width / 4  // big spread

        for _ in 0..<zebraTotal {
            let dx = Int(rng.next() % UInt64(spread)) - spread/2
                   + Int(rng.next() % UInt64(spread)) - spread/2
            let dy = Int(rng.next() % UInt64(spread)) - spread/2
                   + Int(rng.next() % UInt64(spread)) - spread/2
            let x = min(max(0, zCx + dx), width - 1)
            let y = min(max(0, zCy + dy), height - 1)
            let m = mi(x, y)
            if entity[m] == Entity.empty.rawValue || entity[m] == Entity.grass.rawValue {
                entity[m] = Entity.zebra.rawValue
                energy[m] = Int16(150 + Int(rng.next() % 101))
                ternary[m] = Int8(rng.next() % 2)
                orientation[m] = Int8(rng.next() % 6)
                let age = reproAgeZ + Int(rng.next() % UInt64(maxAgeZ - reproAgeZ))
                let phase = Int(rng.next() % UInt64(cooldownZ))
                let adjustedAge = age - (age % cooldownZ) + phase
                gauge[m] = Int16(clamping: adjustedAge)
            }
        }

        // ── Place lions as SEPARATED PRIDES ──────────────
        // Each pride = 4 lions clustered tight. Prides spaced >50 hex apart
        // (outside scent cutoff ~30 hex). Distributed across grid.
        let lionTotal = Int(Double(n) * lionFrac)
        let cooldownL = 2920
        let reproAgeL = 2920
        let maxAgeL   = 18000
        let prideSize = 4
        let numPrides = max(1, lionTotal / prideSize)
        let prideSpacing = 50  // hex between pride centers (> scent range)

        // Grid of pride positions, evenly spaced
        let pridesPerSide = max(1, Int(sqrt(Double(numPrides))))
        let stepX = width / (pridesPerSide + 1)
        let stepY = height / (pridesPerSide + 1)
        // Zebra center for facing calculation
        let zCenterX = width * 3 / 8
        let zCenterY = height * 3 / 8

        // Angle to hex direction: 0=NE,1=N,2=NW,3=SW,4=S,5=SE
        func facingToward(_ fromX: Int, _ fromY: Int, _ toX: Int, _ toY: Int) -> Int8 {
            let dx = Double(toX - fromX)
            let dy = Double(toY - fromY)
            // atan2 gives angle, map to 6 hex dirs (y-down screen coords)
            let angle = atan2(dy, dx)  // radians, 0=east, pi/2=south
            // Hex dirs: 0=NE(~-30°), 1=N(-90°), 2=NW(~-150°), 3=SW(~150°), 4=S(90°), 5=SE(~30°)
            let deg = angle * 180.0 / .pi
            if deg >= -60 && deg < 0    { return 0 }  // NE
            if deg >= -120 && deg < -60 { return 1 }  // N
            if deg >= -180 && deg < -120 { return 2 } // NW
            if deg >= 120 && deg <= 180 { return 3 }  // SW
            if deg >= 60 && deg < 120   { return 4 }  // S
            return 5                                    // SE
        }

        var lionsPlaced = 0
        for pi in 0..<numPrides {
            if lionsPlaced >= lionTotal { break }
            let gridRow = pi / pridesPerSide
            let gridCol = pi % pridesPerSide
            let pcx = stepX * (gridCol + 1) + Int(rng.next() % UInt64(max(1, stepX/4))) - stepX/8
            let pcy = stepY * (gridRow + 1) + Int(rng.next() % UInt64(max(1, stepY/4))) - stepY/8
            let prideFacing = facingToward(pcx, pcy, zCenterX, zCenterY)

            // Place 4 lions in tight cluster (radius 2)
            for li in 0..<prideSize {
                if lionsPlaced >= lionTotal { break }
                let dx = Int(rng.next() % 5) - 2
                let dy = Int(rng.next() % 5) - 2
                let x = min(max(0, pcx + dx), width - 1)
                let y = min(max(0, pcy + dy), height - 1)
                let m = mi(x, y)
                if entity[m] == Entity.empty.rawValue || entity[m] == Entity.grass.rawValue {
                    entity[m] = Entity.lion.rawValue
                    energy[m] = Int16(200 + Int(rng.next() % 101))
                    ternary[m] = 1
                    orientation[m] = prideFacing  // face toward zebras
                    // Stagger ages within pride: lion 0=young, 1=mid-young, 2=mid-old, 3=old
                    let ageSlot = li  // 0,1,2,3
                    let slotSize = (maxAgeL - reproAgeL) / prideSize
                    let age = reproAgeL + ageSlot * slotSize + Int(rng.next() % UInt64(max(1, slotSize)))
                    // Spread repro phase within each slot
                    let phase = (ageSlot * cooldownL / prideSize) + Int(rng.next() % UInt64(max(1, cooldownL / prideSize)))
                    let adjustedAge = age - (age % cooldownL) + (phase % cooldownL)
                    gauge[m] = Int16(clamping: adjustedAge)
                    lionsPlaced += 1
                }
            }
        }
    }

    // ── Serialization for tiled simulation ────────────────

    /// Save state to binary file (row-major order).
    public func save(to path: String) throws {
        var data = Data()
        var w = UInt32(width), h = UInt32(height)
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        entity.withUnsafeBytes { data.append(Data($0)) }
        energy.withUnsafeBytes { data.append(Data($0)) }
        ternary.withUnsafeBytes { data.append(Data($0)) }
        gauge.withUnsafeBytes { data.append(Data($0)) }
        orientation.withUnsafeBytes { data.append(Data($0)) }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Load state from binary file.
    public static func load(from path: String) -> SavannaState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var offset = 0
        func read<T>(_ type: T.Type, count: Int) -> [T] {
            let size = count * MemoryLayout<T>.size
            guard offset + size <= data.count else { return [] }
            let result = data[offset..<offset+size].withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
            offset += size
            return result
        }
        guard let w = read(UInt32.self, count: 1).first,
              let h = read(UInt32.self, count: 1).first else { return nil }
        let width = Int(w), height = Int(h), n = width * height
        var state = SavannaState(width: width, height: height)
        state.entity = read(Int8.self, count: n)
        state.energy = read(Int16.self, count: n)
        state.ternary = read(Int8.self, count: n)
        state.gauge = read(Int16.self, count: n)
        state.orientation = read(Int8.self, count: n)
        guard state.entity.count == n else { return nil }
        return state
    }

    public func census() -> SavannaCensus {
        var e = 0, g = 0, z = 0, l = 0, te = 0
        for i in 0..<nodeCount {
            switch entity[i] {
            case Entity.empty.rawValue: e += 1
            case Entity.grass.rawValue: g += 1
            case Entity.zebra.rawValue: z += 1
            case Entity.lion.rawValue:  l += 1
            default: break
            }
            te += Int(energy[i])
        }
        return SavannaCensus(empty: e, grass: g, zebra: z, lion: l, totalEnergy: te)
    }
}

/// Simple deterministic RNG (SplitMix64) for reproducible init.
struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return z
    }
}
