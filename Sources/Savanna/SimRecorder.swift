/// SimRecorder — Ring buffer for simulation state recording + playback.
///
/// Records entity buffer snapshots at GPU speed via blit.
/// Ring buffer is in Morton order (matches GPU buffers).
/// Snapshot files written to disk are de-Mortoned to row-major for HTML renderer.

import Metal
import Foundation

public struct FrameMeta {
    public var tick: UInt32
    public var isDay: Bool
    public var grass: UInt32
    public var zebra: UInt32
    public var lion: UInt32

    public init(tick: UInt32 = 0, isDay: Bool = true, grass: UInt32 = 0, zebra: UInt32 = 0, lion: UInt32 = 0) {
        self.tick = tick; self.isDay = isDay; self.grass = grass; self.zebra = zebra; self.lion = lion
    }
}

public enum RecorderMode {
    case live       // recording, renderer sees latest frame
    case playback   // frozen sim, walk ring at playbackSpeed
    case paused     // single frame inspection
}

public final class SimRecorder {
    public let ringBuffer: MTLBuffer
    public let capacity: Int
    public let frameBytes: Int

    /// Morton→row-major mapping for de-Morton on disk write.
    let mortonToNode: [Int32]

    public var head: Int = 0
    public var frameCount: Int = 0
    public var totalRecorded: Int = 0
    public var frameMeta: [FrameMeta]

    public var mode: RecorderMode = .live
    public var playbackHead: Int = 0
    public var playbackSpeed: Double = 1.0

    public init?(device: MTLDevice, grid: HexGrid, capacity: Int = 50_000) {
        self.capacity = capacity
        self.frameBytes = grid.nodeCount
        self.mortonToNode = grid.mortonToNode
        let totalBytes = capacity * grid.nodeCount
        guard let buf = device.makeBuffer(length: totalBytes, options: .storageModeShared) else {
            return nil
        }
        self.ringBuffer = buf
        self.frameMeta = [FrameMeta](repeating: FrameMeta(), count: capacity)
    }

    /// Record current entity buffer into ring. Call from tick's command buffer.
    public func encodeRecord(cmdBuf: MTLCommandBuffer, from entityBuf: MTLBuffer,
                              tick: UInt32, isDay: Bool) {
        guard mode == .live else { return }

        let slot = head
        let offset = slot * frameBytes

        guard let blit = cmdBuf.makeBlitCommandEncoder() else { return }
        blit.copy(from: entityBuf, sourceOffset: 0,
                  to: ringBuffer, destinationOffset: offset,
                  size: frameBytes)
        blit.endEncoding()

        cmdBuf.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.frameMeta[slot] = FrameMeta(tick: tick, isDay: isDay)
            self.head = (slot + 1) % self.capacity
            self.frameCount = min(self.frameCount + 1, self.capacity)
            self.totalRecorded += 1
        }
    }

    /// Get pointer to a specific frame in the ring buffer (Morton order).
    public func framePointer(at ringIndex: Int) -> UnsafeRawPointer {
        let offset = (ringIndex % capacity) * frameBytes
        return UnsafeRawPointer(ringBuffer.contents() + offset)
    }

    public func currentLiveFrame() -> UnsafeRawPointer {
        let slot = (head - 1 + capacity) % capacity
        return framePointer(at: slot)
    }

    public func currentPlaybackFrame() -> UnsafeRawPointer {
        return framePointer(at: playbackHead)
    }

    public func step(by delta: Int) {
        playbackHead = (playbackHead + delta + capacity) % capacity
    }

    /// De-Morton a frame from ring buffer to row-major Data for disk write.
    func deMortonFrame(ptr: UnsafeRawPointer) -> Data {
        let src = ptr.bindMemory(to: Int8.self, capacity: frameBytes)
        var rm = [Int8](repeating: 0, count: frameBytes)
        for m in 0..<frameBytes {
            rm[Int(mortonToNode[m])] = src[m]
        }
        return Data(bytes: rm, count: frameBytes)
    }

    /// Write current playback frame to snapshot file (row-major for HTML).
    public func writePlaybackSnapshot(to path: String, width: Int, height: Int) {
        let ptr = currentPlaybackFrame()
        let meta = frameMeta[playbackHead % capacity]
        let entityData = deMortonFrame(ptr: ptr)

        var w = UInt32(width), h = UInt32(height)
        var t = meta.tick
        var d: UInt32 = meta.isDay ? 1 : 0
        var data = Data()
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        data.append(Data(bytes: &t, count: 4))
        data.append(Data(bytes: &d, count: 4))
        data.append(entityData)
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Write live frame to snapshot file (row-major for HTML).
    public func writeLiveSnapshot(to path: String, width: Int, height: Int, tick: Int, isDay: Bool) {
        guard frameCount > 0 else { return }
        let ptr = currentLiveFrame()
        let entityData = deMortonFrame(ptr: ptr)

        var w = UInt32(width), h = UInt32(height)
        var t = UInt32(tick)
        var d: UInt32 = isDay ? 1 : 0
        var data = Data()
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        data.append(Data(bytes: &t, count: 4))
        data.append(Data(bytes: &d, count: 4))
        data.append(entityData)
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
