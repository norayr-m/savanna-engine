/// MetalEngine export — read entity buffer back to CPU for rendering/export.

import Metal
import Foundation

extension MetalEngine {
    /// Read entity buffer back to CPU as [Int8].
    public func readEntities() -> [Int8] {
        let ptr = entityBuf.contents().bindMemory(to: Int8.self, capacity: nodeCount)
        return Array(UnsafeBufferPointer(start: ptr, count: nodeCount))
    }

    /// Write entity buffer as raw binary file for HTML renderer.
    public func writeSnapshot(to path: String, width: Int, height: Int, tick: Int, isDay: Bool) {
        let entities = readEntities()

        // Write raw bytes: 8-byte header (width, height as UInt32) + N bytes entity data
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
