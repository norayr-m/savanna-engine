/// HexGrid — Morton Z-curve hex grid with Bayer 3-coloring.
///
/// Flat-top hex, odd-q offset. Neighbors stored as (N, 6) flat array.
/// Morton ordering via cube coordinates for cache-optimal memory layout.
/// Bayer 3-coloring: `(col - row) % 3` → three independent sets, zero adjacency within each.

import Foundation

/// Entity codes matching Python engine
public enum Entity: Int8 {
    case empty = 0
    case grass = 1
    case zebra = 2
    case lion  = 3
    case water = 4
}

public struct HexGrid {
    public let width: Int
    public let height: Int
    public let nodeCount: Int

    /// (N, 6) neighbor indices, -1 padded. Flat row-major: neighbors[node * 6 + dir]
    public let neighbors: [Int32]

    /// Morton Z-curve index for each node. mortonOrder[i] = morton code of node i.
    public let mortonOrder: [UInt32]

    /// Inverse: mortonToNode[rank] = original node index for rank-th Morton code.
    public let mortonToNode: [Int32]

    /// Four color groups (R/G/B/Q). colorGroups[c] = array of node indices with color c.
    /// 4-coloring required for odd-q flat-top hex (3-coloring insufficient).
    /// Matches Trisister 4-simplex: Red, Green, Blue, Queen.
    public let colorGroups: [[Int32]]

    /// Color assignment per node. colors[i] = 0, 1, 2, or 3.
    public let colors: [UInt8]

    /// Number of color groups (7 for distance-2 safe hex movement).
    /// Molloy & Salavatipour (2005): distance-2 chromatic number of hex lattice = 7.
    public static let colorCount = 7

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.nodeCount = width * height

        let n = nodeCount

        // Even/odd column hex neighbor offsets (dc, dr)
        // Consistent direction ordering across even/odd columns:
        //   Dir 0: NE (-30°)    Dir 3: SW (+150°)   — opposite pair
        //   Dir 1: N  (-90°)    Dir 4: S  (+90°)    — opposite pair
        //   Dir 2: NW (-150°)   Dir 5: SE (+30°)    — opposite pair
        // Three axes at 120° apart. (d+3)%6 = opposite direction.
        let evenOffsets: [(Int, Int)] = [(1,-1),(0,-1),(-1,-1),(-1,0),(0,1),(1,0)]
        let oddOffsets:  [(Int, Int)] = [(1,0), (0,-1),(-1,0), (-1,1),(0,1),(1,1)]

        // Build neighbor matrix + colors
        var nb = [Int32](repeating: -1, count: n * 6)
        var col = [UInt8](repeating: 0, count: n)
        var groups: [[Int32]] = (0..<7).map { _ in [Int32]() }

        for c in 0..<width {
            let offsets = (c & 1 == 1) ? oddOffsets : evenOffsets
            for r in 0..<height {
                let i = r * width + c
                var k = 0
                for (dc, dr) in offsets {
                    let nc = c + dc
                    let nr = r + dr
                    if nc >= 0 && nc < width && nr >= 0 && nr < height {
                        nb[i * 6 + k] = Int32(nr * width + nc)
                    }
                    k += 1
                }
                // 7-coloring: (col + row + 4*(col&1)) mod 7
                // Distance-2 safe: no two same-color nodes share any neighbor.
                // Exhaustive search on corrected hex grid: 12 valid formulas. This is simplest.
                let color = UInt8((c + r + 4 * (c & 1)) % 7)
                col[i] = color
                groups[Int(color)].append(Int32(i))
            }
        }

        self.neighbors = nb
        self.colors = col
        self.colorGroups = groups

        // Morton Z-curve via cube coordinates
        // Hex offset (col, row) → cube (q, r) where q = col, r = row - (col - (col & 1)) / 2
        // Then Morton = interleave(q, r)
        var morton = [UInt32](repeating: 0, count: n)
        for c in 0..<width {
            for r in 0..<height {
                let i = r * width + c
                let q = c
                let cubeR = r - (c - (c & 1)) / 2
                morton[i] = Self.mortonEncode(UInt16(q & 0xFFFF), UInt16(cubeR & 0xFFFF))
            }
        }
        self.mortonOrder = morton

        // Build inverse: sort by Morton code
        var indices = (0..<Int32(n)).map { $0 }
        indices.sort { morton[Int($0)] < morton[Int($1)] }
        self.mortonToNode = indices
    }

    /// Interleave bits of two 16-bit values into a 32-bit Morton code.
    static func mortonEncode(_ x: UInt16, _ y: UInt16) -> UInt32 {
        func spread(_ v: UInt16) -> UInt32 {
            var x = UInt32(v) & 0x0000FFFF
            x = (x | (x << 8)) & 0x00FF00FF
            x = (x | (x << 4)) & 0x0F0F0F0F
            x = (x | (x << 2)) & 0x33333333
            x = (x | (x << 1)) & 0x55555555
            return x
        }
        return spread(x) | (spread(y) << 1)
    }

    /// Degree of a node (count of valid neighbors, 3-6).
    public func degree(of node: Int) -> Int {
        var count = 0
        for d in 0..<6 {
            if neighbors[node * 6 + d] >= 0 { count += 1 }
        }
        return count
    }

    /// Verify 3-coloring: no two adjacent nodes share a color.
    public func verifyColoring() -> Bool {
        for i in 0..<nodeCount {
            let myColor = colors[i]
            for d in 0..<6 {
                let nb = neighbors[i * 6 + d]
                if nb >= 0 && colors[Int(nb)] == myColor {
                    return false
                }
            }
        }
        return true
    }
}
