/// HexGrid — Morton Z-curve hex grid with 7-coloring.
///
/// Flat-top hex, odd-q offset. Neighbors stored as (N, 6) flat array.
/// Morton ordering: all index spaces (neighbors, colorGroups, colors) use Morton rank.
/// 7-coloring: (col + row + 4*(col&1)) mod 7 — distance-2 safe (Molloy & Salavatipour, 2005).

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

    /// (N, 6) neighbor indices in Morton-rank space, -1 padded.
    /// neighbors[mortonRank * 6 + dir] = Morton rank of neighbor (or -1).
    public let neighbors: [Int32]

    /// Morton Z-curve code for each row-major node. mortonOrder[rowMajor] = morton code.
    public let mortonOrder: [UInt32]

    /// Inverse: mortonToNode[rank] = row-major node index for rank-th Morton code.
    public let mortonToNode: [Int32]

    /// mortonRank[rowMajor] = Morton rank of that row-major node.
    /// This is the key mapping: (col,row) → row-major → mortonRank → buffer index.
    public let mortonRank: [Int32]

    /// Color groups in Morton-rank space. colorGroups[c] = array of Morton ranks with color c.
    public let colorGroups: [[Int32]]

    /// Color per Morton rank. colors[mortonRank] = 0..6.
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

        // --- Pass 1: Build row-major neighbor table and colors ---
        var nbRM = [Int32](repeating: -1, count: n * 6)
        var colRM = [UInt8](repeating: 0, count: n)
        var groupsRM: [[Int32]] = (0..<7).map { _ in [Int32]() }

        for c in 0..<width {
            let offsets = (c & 1 == 1) ? oddOffsets : evenOffsets
            for r in 0..<height {
                let i = r * width + c
                var k = 0
                for (dc, dr) in offsets {
                    let nc = c + dc
                    let nr = r + dr
                    if nc >= 0 && nc < width && nr >= 0 && nr < height {
                        nbRM[i * 6 + k] = Int32(nr * width + nc)
                    }
                    k += 1
                }
                // 7-coloring: (col + row + 4*(col&1)) mod 7
                let color = UInt8((c + r + 4 * (c & 1)) % 7)
                colRM[i] = color
                groupsRM[Int(color)].append(Int32(i))
            }
        }

        // --- Morton Z-curve via cube coordinates ---
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

        // Build mortonRank: inverse of mortonToNode
        var rank = [Int32](repeating: 0, count: n)
        for m in 0..<n {
            rank[Int(indices[m])] = Int32(m)
        }
        self.mortonRank = rank

        // --- Pass 2: Translate everything to Morton-rank space ---

        // Neighbor table: nbMorton[m * 6 + d] = Morton rank of neighbor
        var nbMorton = [Int32](repeating: -1, count: n * 6)
        for m in 0..<n {
            let i = Int(indices[m])  // row-major node at Morton rank m
            for d in 0..<6 {
                let nbIdx = nbRM[i * 6 + d]
                nbMorton[m * 6 + d] = nbIdx < 0 ? -1 : rank[Int(nbIdx)]
            }
        }
        self.neighbors = nbMorton

        // Color groups: translate row-major indices to Morton ranks
        self.colorGroups = groupsRM.map { group in group.map { rank[Int($0)] } }

        // Colors array: reindex so colors[m] = color of Morton rank m
        var colMorton = [UInt8](repeating: 0, count: n)
        for m in 0..<n {
            colMorton[m] = colRM[Int(indices[m])]
        }
        self.colors = colMorton
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

    /// Degree of a node (count of valid neighbors, 3-6). Takes Morton rank.
    public func degree(of node: Int) -> Int {
        var count = 0
        for d in 0..<6 {
            if neighbors[node * 6 + d] >= 0 { count += 1 }
        }
        return count
    }

    /// Verify 7-coloring: no two adjacent nodes share a color. Operates in Morton space.
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
