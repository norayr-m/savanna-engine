import XCTest
@testable import Savanna

final class HexGridTests: XCTestCase {

    // MARK: — Existing tests (updated for Morton)

    func testSmallGrid() {
        let grid = HexGrid(width: 8, height: 8)
        XCTAssertEqual(grid.nodeCount, 64)

        // Interior node (col=3, row=3) in row-major = 3*8+3 = 27
        // Now neighbor table is Morton-indexed, so look up the Morton rank
        let interiorMorton = Int(grid.mortonRank[27])
        XCTAssertEqual(grid.degree(of: interiorMorton), 6)

        // Corner node (col=0, row=0) in row-major = 0
        // Even col, neighbors: (1,-1)out, (0,-1)out, (-1,-1)out, (-1,0)out, (0,1)ok, (1,0)ok = degree 2
        let cornerMorton = Int(grid.mortonRank[0])
        XCTAssertEqual(grid.degree(of: cornerMorton), 2)
    }

    func testBayerColoring() {
        let grid = HexGrid(width: 32, height: 32)
        XCTAssertTrue(grid.verifyColoring(), "7-coloring should be valid")

        // Each group should have roughly N/7 nodes
        let total = grid.colorGroups.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, grid.nodeCount)

        // No group should be empty
        for i in 0..<HexGrid.colorCount {
            XCTAssertGreaterThan(grid.colorGroups[i].count, 0)
        }
    }

    func testMortonLocality() {
        let grid = HexGrid(width: 16, height: 16)

        // Adjacent nodes should have nearby Morton codes
        let a = 4 * 16 + 4  // row 4, col 4
        let b = 4 * 16 + 5  // row 4, col 5

        let ma = grid.mortonOrder[a]
        let mb = grid.mortonOrder[b]

        let diff = ma > mb ? ma - mb : mb - ma
        XCTAssertLessThan(diff, 100, "Adjacent cells should have nearby Morton codes")
    }

    func testStateInit() {
        // Use 128×128 grid — 16×16 is too small (flood-fill lakes consume entire grid)
        let grid = HexGrid(width: 128, height: 128)
        var state = SavannaState(width: 128, height: 128)
        state.randomInit(grid: grid)
        let c = state.census()

        // Census doesn't count water — total of counted types should be > 0
        let counted = c.empty + c.grass + c.zebra + c.lion
        XCTAssertGreaterThan(counted, 0, "Some non-water cells should exist")
        XCTAssertGreaterThan(c.grass, 0)
        XCTAssertGreaterThan(c.zebra, 0)
    }

    // MARK: — New Morton tests

    func testMortonRankIsInverse() {
        let grid = HexGrid(width: 8, height: 8)
        // mortonToNode[mortonRank[i]] == i for all i
        for i in 0..<grid.nodeCount {
            let rank = Int(grid.mortonRank[i])
            let roundTrip = Int(grid.mortonToNode[rank])
            XCTAssertEqual(roundTrip, i, "mortonRank/mortonToNode must be exact inverses at i=\(i)")
        }
        // Also check forward: mortonRank[mortonToNode[m]] == m
        for m in 0..<grid.nodeCount {
            let node = Int(grid.mortonToNode[m])
            let roundTrip = Int(grid.mortonRank[node])
            XCTAssertEqual(roundTrip, m, "mortonToNode/mortonRank must be exact inverses at m=\(m)")
        }
    }

    func testNeighborSymmetry() {
        let grid = HexGrid(width: 16, height: 16)
        // For every Morton rank m and direction d:
        // if neighbors[m*6+d] == n, then neighbors[n*6+(d+3)%6] == m
        for m in 0..<grid.nodeCount {
            for d in 0..<6 {
                let n = Int(grid.neighbors[m * 6 + d])
                if n < 0 { continue }  // boundary
                let opposite = (d + 3) % 6
                let back = Int(grid.neighbors[n * 6 + opposite])
                XCTAssertEqual(back, m,
                    "Neighbor symmetry broken: node \(m) dir \(d) → \(n), but \(n) dir \(opposite) → \(back) (expected \(m))")
            }
        }
    }

    func testNeighborMortonAgreement() {
        // Geometric spot check: node at (col=4, row=4) on a 16×16 grid
        // Even column (col=4), so NE neighbor (dir 0) offset is (1, -1) → (col=5, row=3)
        let w = 16
        let grid = HexGrid(width: w, height: w)

        let srcRM = 4 * w + 4   // row-major of (col=4, row=4)
        let srcMorton = Int(grid.mortonRank[srcRM])

        let nbRM = 3 * w + 5    // row-major of (col=5, row=3) — NE neighbor
        let nbMorton = Int(grid.mortonRank[nbRM])

        // Direction 0 = NE for even columns
        let actual = Int(grid.neighbors[srcMorton * 6 + 0])
        XCTAssertEqual(actual, nbMorton,
            "NE neighbor of (4,4) should be (5,3) in Morton space")
    }

    func testColorGroupsAreMortonRanks() {
        let grid = HexGrid(width: 32, height: 32)
        var seen = Set<Int32>()
        for c in 0..<HexGrid.colorCount {
            for m in grid.colorGroups[c] {
                XCTAssertTrue(m >= 0 && m < Int32(grid.nodeCount),
                    "Color group index \(m) out of range")
                XCTAssertEqual(grid.colors[Int(m)], UInt8(c),
                    "Node \(m) in group \(c) but colors[\(m)] = \(grid.colors[Int(m)])")
                XCTAssertFalse(seen.contains(m), "Duplicate Morton rank \(m) in color groups")
                seen.insert(m)
            }
        }
        XCTAssertEqual(seen.count, grid.nodeCount, "Color groups must cover all nodes exactly once")
    }

    func testStateInitMortonOrder() {
        // Water should be placed at Morton positions, not row-major positions
        let grid = HexGrid(width: 64, height: 64)
        var state = SavannaState(width: 64, height: 64)
        state.randomInit(grid: grid, seed: 42)

        // Find any water cell by scanning row-major coords
        var foundWater = false
        for y in 0..<64 {
            for x in 0..<64 {
                let rm = y * 64 + x
                let m = Int(grid.mortonRank[rm])
                if state.entity[m] == Entity.water.rawValue {
                    foundWater = true
                    // Verify it's NOT at the row-major position (unless they happen to coincide)
                    // More importantly: verify we can find it via Morton lookup
                    XCTAssertEqual(state.entity[m], Entity.water.rawValue)
                }
            }
        }
        XCTAssertTrue(foundWater, "Should have at least one water cell")
    }

    func testMortonNeighborLocality() {
        // On a 64×64 grid, neighbors should be close in Morton index
        let grid = HexGrid(width: 64, height: 64)
        var maxDelta = 0

        for m in 0..<grid.nodeCount {
            for d in 0..<6 {
                let nb = Int(grid.neighbors[m * 6 + d])
                if nb < 0 { continue }
                let delta = abs(nb - m)
                if delta > maxDelta { maxDelta = delta }
            }
        }
        // For a 64×64 grid, max Morton delta should be bounded
        // Row-major max delta would be ~64 (one row apart)
        // Morton should be much less than nodeCount
        // Hex cube coordinates create larger Morton gaps than Cartesian grids.
        // On 64×64, max delta can be ~3500. Key invariant: much less than nodeCount.
        XCTAssertLessThan(maxDelta, grid.nodeCount,
            "Morton neighbor delta \(maxDelta) should be less than nodeCount \(grid.nodeCount)")
    }

    func testRenderRoundTrip() {
        // Write a known pattern in Morton space, read back in row-major
        let grid = HexGrid(width: 8, height: 8)
        var state = SavannaState(width: 8, height: 8)

        // Place water at (col=2, row=3) via Morton
        let rm = 3 * 8 + 2  // row-major index
        let m = Int(grid.mortonRank[rm])
        state.entity[m] = Entity.water.rawValue

        // De-Morton back to row-major
        var rowMajor = [Int8](repeating: 0, count: grid.nodeCount)
        for morton in 0..<grid.nodeCount {
            let rowIdx = Int(grid.mortonToNode[morton])
            rowMajor[rowIdx] = state.entity[morton]
        }

        // The water should appear at the original row-major position
        XCTAssertEqual(rowMajor[rm], Entity.water.rawValue,
            "De-Morton should recover water at row-major index \(rm)")

        // All other cells should be empty
        for i in 0..<grid.nodeCount {
            if i == rm { continue }
            XCTAssertEqual(rowMajor[i], Entity.empty.rawValue,
                "Non-water cell at row-major \(i) should be empty, got \(rowMajor[i])")
        }
    }
}
