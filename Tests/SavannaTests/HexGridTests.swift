import XCTest
@testable import Savanna

final class HexGridTests: XCTestCase {

    func testSmallGrid() {
        let grid = HexGrid(width: 8, height: 8)
        XCTAssertEqual(grid.nodeCount, 64)

        // Interior nodes should have degree 6
        // Node at (3, 3) = 3*8+3 = 27
        XCTAssertEqual(grid.degree(of: 27), 6)

        // Corner node at (0, 0) = 0 should have degree 3
        XCTAssertEqual(grid.degree(of: 0), 3)
    }

    func testBayerColoring() {
        let grid = HexGrid(width: 32, height: 32)
        XCTAssertTrue(grid.verifyColoring(), "4-coloring should be valid")

        // Each group should have roughly N/4 nodes
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
        // Check node (4, 4) and its neighbor (5, 4)
        let a = 4 * 16 + 4  // row 4, col 4
        let b = 4 * 16 + 5  // row 4, col 5

        let ma = grid.mortonOrder[a]
        let mb = grid.mortonOrder[b]

        // Morton codes should differ by a small amount (not guaranteed to be ±1,
        // but should be close for adjacent cells)
        let diff = ma > mb ? ma - mb : mb - ma
        XCTAssertLessThan(diff, 100, "Adjacent cells should have nearby Morton codes")
    }

    func testStateInit() {
        var state = SavannaState(width: 16, height: 16)
        state.randomInit()
        let c = state.census()

        XCTAssertEqual(c.empty + c.grass + c.zebra + c.lion, 256)
        XCTAssertGreaterThan(c.grass, 0)
        XCTAssertGreaterThan(c.zebra, 0)
        XCTAssertGreaterThan(c.lion, 0)
    }
}
