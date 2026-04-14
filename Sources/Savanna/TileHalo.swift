/// TileHalo — Halo Protocol for tiled simulation.
///
/// Each tile's 3-cell perimeter is saved to disk after simulation.
/// Adjacent tiles load these halos as read-only ghost zones so boundary
/// cells can sense neighbors across tile edges. Scent diffusion,
/// hearing, sight, and smell all work seamlessly across halos.
///
/// Halo cells are appended after the main tile's Morton-ordered buffers.
/// The Metal shader's `main_tile_n` guard prevents writing into halos.

import Foundation

/// Which edge of a tile the halo strip belongs to.
public enum HaloEdge: Int, CaseIterable {
    case north = 0, east = 1, south = 2, west = 3

    /// The opposite edge (what the neighbor tile calls this strip).
    var opposite: HaloEdge {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east:  return .west
        case .west:  return .east
        }
    }

    /// Tile offset: (dtx, dty) to reach the neighbor tile for this edge.
    var tileOffset: (Int, Int) {
        switch self {
        case .north: return (0, -1)
        case .south: return (0, 1)
        case .east:  return (1, 0)
        case .west:  return (-1, 0)
        }
    }
}

/// A strip of cells along one edge of a tile (3 cells deep).
public struct HaloStrip {
    public let edge: HaloEdge
    public let width: Int   // strip length (= tile edge length)
    public let depth: Int   // always 3
    public var entity: [Int8]
    public var energy: [Int16]
    public var ternary: [Int8]
    public var gauge: [Int16]
    public var orientation: [Int8]
    public var scentZebra: [Float]
    public var scentGrass: [Float]
    public var scentLion: [Float]
    public var scentWater: [Float]

    public var cellCount: Int { width * depth }

    /// Create an empty strip.
    public init(edge: HaloEdge, width: Int, depth: Int = 3) {
        self.edge = edge
        self.width = width
        self.depth = depth
        let n = width * depth
        self.entity = [Int8](repeating: 0, count: n)
        self.energy = [Int16](repeating: 0, count: n)
        self.ternary = [Int8](repeating: 0, count: n)
        self.gauge = [Int16](repeating: 0, count: n)
        self.orientation = [Int8](repeating: 0, count: n)
        self.scentZebra = [Float](repeating: 0, count: n)
        self.scentGrass = [Float](repeating: 0, count: n)
        self.scentLion = [Float](repeating: 0, count: n)
        self.scentWater = [Float](repeating: 0, count: n)
    }
}

public struct TileHalo {

    /// Standard halo depth (cells). Matches lion sight radius (3 hops).
    public static let depth = 3

    // MARK: - File paths

    public static func haloPath(dir: String, tx: Int, ty: Int) -> String {
        "\(dir)/tile_\(tx)_\(ty)_halo.bin"
    }

    public static func tileStatePath(dir: String, tx: Int, ty: Int) -> String {
        "\(dir)/tile_\(tx)_\(ty).bin"
    }

    // MARK: - Extract perimeter from a simulated tile

    /// Extract 3-cell-deep strip from the edge of a tile's state arrays.
    /// `state` is in row-major order (already de-Mortoned).
    public static func extractPerimeter(
        entity: [Int8], energy: [Int16], ternary: [Int8],
        gauge: [Int16], orientation: [Int8],
        scentZ: [Float], scentG: [Float], scentL: [Float], scentW: [Float],
        tileW: Int, tileH: Int, edge: HaloEdge
    ) -> HaloStrip {
        let d = depth
        var strip: HaloStrip

        switch edge {
        case .north:
            strip = HaloStrip(edge: edge, width: tileW, depth: d)
            for row in 0..<d {
                for col in 0..<tileW {
                    let si = row * tileW + col  // strip index
                    let ti = row * tileW + col  // tile index (top rows)
                    strip.entity[si] = entity[ti]
                    strip.energy[si] = energy[ti]
                    strip.ternary[si] = ternary[ti]
                    strip.gauge[si] = gauge[ti]
                    strip.orientation[si] = orientation[ti]
                    strip.scentZebra[si] = scentZ[ti]
                    strip.scentGrass[si] = scentG[ti]
                    strip.scentLion[si] = scentL[ti]
                    strip.scentWater[si] = scentW[ti]
                }
            }
        case .south:
            strip = HaloStrip(edge: edge, width: tileW, depth: d)
            for row in 0..<d {
                for col in 0..<tileW {
                    let si = row * tileW + col
                    let ti = (tileH - d + row) * tileW + col
                    strip.entity[si] = entity[ti]
                    strip.energy[si] = energy[ti]
                    strip.ternary[si] = ternary[ti]
                    strip.gauge[si] = gauge[ti]
                    strip.orientation[si] = orientation[ti]
                    strip.scentZebra[si] = scentZ[ti]
                    strip.scentGrass[si] = scentG[ti]
                    strip.scentLion[si] = scentL[ti]
                    strip.scentWater[si] = scentW[ti]
                }
            }
        case .west:
            strip = HaloStrip(edge: edge, width: tileH, depth: d)
            for col in 0..<d {
                for row in 0..<tileH {
                    let si = col * tileH + row  // strip: depth × height
                    let ti = row * tileW + col
                    strip.entity[si] = entity[ti]
                    strip.energy[si] = energy[ti]
                    strip.ternary[si] = ternary[ti]
                    strip.gauge[si] = gauge[ti]
                    strip.orientation[si] = orientation[ti]
                    strip.scentZebra[si] = scentZ[ti]
                    strip.scentGrass[si] = scentG[ti]
                    strip.scentLion[si] = scentL[ti]
                    strip.scentWater[si] = scentW[ti]
                }
            }
        case .east:
            strip = HaloStrip(edge: edge, width: tileH, depth: d)
            for col in 0..<d {
                for row in 0..<tileH {
                    let si = col * tileH + row
                    let ti = row * tileW + (tileW - d + col)
                    strip.entity[si] = entity[ti]
                    strip.energy[si] = energy[ti]
                    strip.ternary[si] = ternary[ti]
                    strip.gauge[si] = gauge[ti]
                    strip.orientation[si] = orientation[ti]
                    strip.scentZebra[si] = scentZ[ti]
                    strip.scentGrass[si] = scentG[ti]
                    strip.scentLion[si] = scentL[ti]
                    strip.scentWater[si] = scentW[ti]
                }
            }
        }
        return strip
    }

    // MARK: - Disk I/O

    /// Write all 4 edge halos for a tile.
    public static func writeHalos(_ strips: [HaloStrip], to path: String) throws {
        var data = Data()
        var count = UInt32(strips.count)
        data.append(Data(bytes: &count, count: 4))
        for s in strips {
            var edge = UInt32(s.edge.rawValue)
            var w = UInt32(s.width)
            var d = UInt32(s.depth)
            data.append(Data(bytes: &edge, count: 4))
            data.append(Data(bytes: &w, count: 4))
            data.append(Data(bytes: &d, count: 4))
            s.entity.withUnsafeBytes { data.append(Data($0)) }
            s.energy.withUnsafeBytes { data.append(Data($0)) }
            s.ternary.withUnsafeBytes { data.append(Data($0)) }
            s.gauge.withUnsafeBytes { data.append(Data($0)) }
            s.orientation.withUnsafeBytes { data.append(Data($0)) }
            s.scentZebra.withUnsafeBytes { data.append(Data($0)) }
            s.scentGrass.withUnsafeBytes { data.append(Data($0)) }
            s.scentLion.withUnsafeBytes { data.append(Data($0)) }
            s.scentWater.withUnsafeBytes { data.append(Data($0)) }
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Read halos from a neighbor tile's file. Returns nil if file missing (tick 0).
    public static func readHalos(from path: String) -> [HaloStrip]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var offset = 0
        func readBytes<T>(_ type: T.Type, count: Int) -> [T] {
            let size = count * MemoryLayout<T>.size
            guard offset + size <= data.count else { return [] }
            let result = data[offset..<offset+size].withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
            offset += size
            return result
        }
        guard let numStrips = readBytes(UInt32.self, count: 1).first else { return nil }
        var strips = [HaloStrip]()
        for _ in 0..<numStrips {
            guard let edgeVal = readBytes(UInt32.self, count: 1).first,
                  let w = readBytes(UInt32.self, count: 1).first,
                  let d = readBytes(UInt32.self, count: 1).first,
                  let edge = HaloEdge(rawValue: Int(edgeVal)) else { return nil }
            let n = Int(w) * Int(d)
            var strip = HaloStrip(edge: edge, width: Int(w), depth: Int(d))
            strip.entity = readBytes(Int8.self, count: n)
            strip.energy = readBytes(Int16.self, count: n)
            strip.ternary = readBytes(Int8.self, count: n)
            strip.gauge = readBytes(Int16.self, count: n)
            strip.orientation = readBytes(Int8.self, count: n)
            strip.scentZebra = readBytes(Float.self, count: n)
            strip.scentGrass = readBytes(Float.self, count: n)
            strip.scentLion = readBytes(Float.self, count: n)
            strip.scentWater = readBytes(Float.self, count: n)
            strips.append(strip)
        }
        return strips
    }

    // MARK: - Load adjacent halos

    /// Load halos from up to 4 adjacent tiles. Returns edge→strip mapping.
    /// Missing tiles (edge of world, tick 0) return empty strips.
    public static func loadAdjacentHalos(
        dir: String, tx: Int, ty: Int,
        nTilesX: Int, nTilesY: Int,
        tileW: Int, tileH: Int
    ) -> [HaloEdge: HaloStrip] {
        var result = [HaloEdge: HaloStrip]()
        for edge in HaloEdge.allCases {
            let (dtx, dty) = edge.tileOffset
            let ntx = tx + dtx, nty = ty + dty
            if ntx < 0 || ntx >= nTilesX || nty < 0 || nty >= nTilesY {
                // World boundary — empty strip
                let w = (edge == .north || edge == .south) ? tileW : tileH
                result[edge] = HaloStrip(edge: edge, width: w)
                continue
            }
            let path = haloPath(dir: dir, tx: ntx, ty: nty)
            if let strips = readHalos(from: path) {
                // Find the strip from the opposite edge of the neighbor
                if let strip = strips.first(where: { $0.edge == edge.opposite }) {
                    result[edge] = strip
                } else {
                    let w = (edge == .north || edge == .south) ? tileW : tileH
                    result[edge] = HaloStrip(edge: edge, width: w)
                }
            } else {
                let w = (edge == .north || edge == .south) ? tileW : tileH
                result[edge] = HaloStrip(edge: edge, width: w)
            }
        }
        return result
    }
}
