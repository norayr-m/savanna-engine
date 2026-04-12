/// SimRecorder — Ring buffer for simulation state recording + playback.
///
/// Records entity buffer snapshots at GPU speed via blit.
/// Supports forward/backward playback at any speed.
/// Archives to .savanna files on NVMe. Reloads via mmap.

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

    public var head: Int = 0          // next write slot
    public var frameCount: Int = 0    // valid frames in ring
    public var totalRecorded: Int = 0 // monotonic counter
    public var frameMeta: [FrameMeta]

    public var mode: RecorderMode = .live
    public var playbackHead: Int = 0
    public var playbackSpeed: Double = 1.0  // negative = reverse

    public init?(device: MTLDevice, nodeCount: Int, capacity: Int = 50_000) {
        // Start conservative: 50K frames × 1MB = 50GB (fits in 128GB with room for sim)
        self.capacity = capacity
        self.frameBytes = nodeCount  // 1 byte per entity
        let totalBytes = capacity * nodeCount
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

        // GPU blit: copy entity buffer into ring slot
        guard let blit = cmdBuf.makeBlitCommandEncoder() else { return }
        blit.copy(from: entityBuf, sourceOffset: 0,
                  to: ringBuffer, destinationOffset: offset,
                  size: frameBytes)
        blit.endEncoding()

        // Update metadata + head after GPU completes
        cmdBuf.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.frameMeta[slot] = FrameMeta(tick: tick, isDay: isDay)
            self.head = (slot + 1) % self.capacity
            self.frameCount = min(self.frameCount + 1, self.capacity)
            self.totalRecorded += 1
        }
    }

    /// Get pointer to a specific frame in the ring buffer.
    public func framePointer(at ringIndex: Int) -> UnsafeRawPointer {
        let offset = (ringIndex % capacity) * frameBytes
        return UnsafeRawPointer(ringBuffer.contents() + offset)
    }

    /// Get the most recent live frame pointer.
    public func currentLiveFrame() -> UnsafeRawPointer {
        let slot = (head - 1 + capacity) % capacity
        return framePointer(at: slot)
    }

    /// Get the current playback frame pointer.
    public func currentPlaybackFrame() -> UnsafeRawPointer {
        return framePointer(at: playbackHead)
    }

    /// Step playback forward or backward.
    public func step(by delta: Int) {
        let oldest = (head - frameCount + capacity) % capacity
        playbackHead = (playbackHead + delta + capacity) % capacity
        // Clamp to valid range
        // (simplified — full ring logic would check wrap-around)
    }

    /// Write current playback frame to snapshot file for HTML renderer.
    public func writePlaybackSnapshot(to path: String, width: Int, height: Int) {
        let ptr = currentPlaybackFrame()
        let meta = frameMeta[playbackHead % capacity]

        var w = UInt32(width), h = UInt32(height)
        var t = meta.tick
        var d: UInt32 = meta.isDay ? 1 : 0
        var data = Data()
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        data.append(Data(bytes: &t, count: 4))
        data.append(Data(bytes: &d, count: 4))
        data.append(Data(bytes: ptr, count: frameBytes))
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Write live frame to snapshot file (replaces MetalEngine+Export for recording mode).
    public func writeLiveSnapshot(to path: String, width: Int, height: Int, tick: Int, isDay: Bool) {
        guard frameCount > 0 else { return }
        let ptr = currentLiveFrame()
        var w = UInt32(width), h = UInt32(height)
        var t = UInt32(tick)
        var d: UInt32 = isDay ? 1 : 0
        var data = Data()
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        data.append(Data(bytes: &t, count: 4))
        data.append(Data(bytes: &d, count: 4))
        data.append(Data(bytes: ptr, count: frameBytes))
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
