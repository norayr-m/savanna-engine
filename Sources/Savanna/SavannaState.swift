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
        zebraFrac: Double = 0.02,
        lionFrac: Double = 0.0004,
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

        // ── Place zebras in HERDS ────────────────────
        let numHerds = max(5, Int(Double(n) * zebraFrac / 200))
        let zebraTotal = Int(Double(n) * zebraFrac)
        var zebrasPlaced = 0
        var herdCenters: [(Int, Int)] = []

        for _ in 0..<numHerds {
            let cx = Int(rng.next() % UInt64(width))
            let cy = Int(rng.next() % UInt64(height))
            herdCenters.append((cx, cy))
            let herdFacing = Int8(rng.next() % 6)
            let herdSize = zebraTotal / numHerds

            for _ in 0..<herdSize {
                let dx = Int(rng.next() % 21) - 10 + Int(rng.next() % 21) - 10
                let dy = Int(rng.next() % 21) - 10 + Int(rng.next() % 21) - 10
                let x = min(max(0, cx + dx), width - 1)
                let y = min(max(0, cy + dy), height - 1)
                let m = mi(x, y)
                if entity[m] == Entity.empty.rawValue || entity[m] == Entity.grass.rawValue {
                    entity[m] = Entity.zebra.rawValue
                    energy[m] = Int16.random(in: 100...250)
                    ternary[m] = Int8.random(in: 0...1)
                    orientation[m] = herdFacing
                    gauge[m] = Int16(rng.next() % UInt64(32000))
                    zebrasPlaced += 1
                }
            }
        }

        // ── Place lions DISPERSED ────────────────────
        let lionTotal = Int(Double(n) * lionFrac)
        for _ in 0..<lionTotal {
            let x = Int(rng.next() % UInt64(width))
            let y = Int(rng.next() % UInt64(height))
            let m = mi(x, y)
            if entity[m] == Entity.empty.rawValue || entity[m] == Entity.grass.rawValue {
                entity[m] = Entity.lion.rawValue
                energy[m] = Int16.random(in: 120...250)
                ternary[m] = 1
                orientation[m] = Int8(rng.next() % 6)
                gauge[m] = Int16(rng.next() % UInt64(18000))
            }
        }
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
