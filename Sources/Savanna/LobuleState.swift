/// LobuleState — Liver lobule initialization on hex grid.
///
/// A liver lobule IS hexagonal:
/// - Portal triads at 6 corners (blood in)
/// - Central vein at center (blood out)
/// - 3 metabolic zones (periportal → pericentral)
/// - ~5000 hepatocytes per lobule

import Foundation

extension SavannaState {

    /// Initialize as a single liver lobule.
    /// All array writes go through grid.mortonRank for Morton-ordered buffers.
    /// Reuses the existing entity/scent system:
    ///   WATER = blood vessel (portal at corners, central at center)
    ///   GRASS = oxygen (high near portal, low near central)
    ///   ZEBRA = hepatocyte (the cells we simulate)
    ///   LION  = drug molecule (injected at portal veins)
    ///   EMPTY = necrotic cell (dead hepatocyte)
    public mutating func lobuleInit(grid: HexGrid, seed: UInt64 = 42) {
        var rng = SplitMix64(seed: seed)
        let mr = grid.mortonRank

        let cx = width / 2
        let cy = height / 2
        let radius = min(width, height) / 2 - 2

        // Helper: (col, row) → Morton rank buffer index
        func mi(_ col: Int, _ row: Int) -> Int {
            return Int(mr[row * width + col])
        }

        for y in 0..<height {
            for x in 0..<width {
                let m = mi(x, y)
                let dx = Double(x - cx)
                let dy = Double(y - cy)
                let dist = sqrt(dx * dx + dy * dy)
                let relDist = dist / Double(radius)  // 0 = center, 1 = edge

                if relDist > 1.05 {
                    entity[m] = Entity.empty.rawValue
                    continue
                }

                // Central vein (center, radius ~3)
                if dist < 3.0 {
                    entity[m] = Entity.water.rawValue
                    continue
                }

                // Portal triads at 6 corners
                var isPortal = false
                for corner in 0..<6 {
                    let angle = Double.pi / 3.0 * Double(corner) + Double.pi / 6.0
                    let px = cx + Int(Double(radius) * cos(angle))
                    let py = cy + Int(Double(radius) * sin(angle))
                    let pdist = sqrt(Double((x - px) * (x - px) + (y - py) * (y - py)))
                    if pdist < 4.0 {
                        isPortal = true
                        break
                    }
                }

                if isPortal {
                    entity[m] = Entity.water.rawValue
                    continue
                }

                // Hepatocyte
                entity[m] = Entity.zebra.rawValue

                // Energy = initial health (255 = fully healthy)
                energy[m] = 255

                // Ternary = metabolic zone
                if relDist > 0.7 {
                    ternary[m] = 1   // Zone 1: periportal
                } else if relDist > 0.35 {
                    ternary[m] = 0   // Zone 2: mid
                } else {
                    ternary[m] = -1  // Zone 3: pericentral (DILI target)
                }

                // Gauge = CYP450 enzyme level (higher in Zone 3)
                let cyp = Int16(Double(255) * (1.0 - relDist))
                gauge[m] = cyp

                // Orientation = random
                orientation[m] = Int8(rng.next() % 6)
            }
        }
    }
}
