/// MetalEngine export — read entity buffer back to CPU for rendering/export.
/// GPU buffers are in Morton order. Snapshot files are row-major for HTML renderer.

import Metal
import Foundation

extension MetalEngine {
    /// Read entity buffer as-is (Morton order).
    public func readEntities() -> [Int8] {
        let ptr = entityBuf.contents().bindMemory(to: Int8.self, capacity: nodeCount)
        return Array(UnsafeBufferPointer(start: ptr, count: nodeCount))
    }

    /// Read entity buffer, de-Morton to row-major for rendering.
    public func readEntitiesRowMajor() -> [Int8] {
        let ptr = entityBuf.contents().bindMemory(to: Int8.self, capacity: nodeCount)
        var rm = [Int8](repeating: 0, count: nodeCount)
        for m in 0..<nodeCount {
            rm[Int(grid.mortonToNode[m])] = ptr[m]
        }
        return rm
    }

    /// Write entity buffer as raw binary file for HTML renderer (row-major).
    public func writeSnapshot(to path: String, width: Int, height: Int, tick: Int, isDay: Bool) {
        let entities = readEntitiesRowMajor()

        var w = UInt32(width)
        var h = UInt32(height)
        var t = UInt32(tick)
        var d = UInt32(isDay ? 1 : 0)
        var data = Data()
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        data.append(Data(bytes: &t, count: 4))
        data.append(Data(bytes: &d, count: 4))
        data.append(Data(bytes: entities, count: entities.count))

        try? data.write(to: URL(fileURLWithPath: path))
    }
}
