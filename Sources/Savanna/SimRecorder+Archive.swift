/// SimRecorder+Archive — Save/load .savanna scenario files.

import Foundation
import Metal

extension SimRecorder {
    /// Archive recorded frames to a .savanna file.
    /// Header (256 bytes) + FrameMeta table + raw entity frames.
    public func archive(to path: String, width: Int, height: Int, seed: UInt64 = 42) {
        guard frameCount > 0 else { return }

        var file = Data()

        // ── Header (256 bytes) ──
        // Magic: "SAVANNA\0"
        file.append(contentsOf: [0x53, 0x41, 0x56, 0x41, 0x4E, 0x4E, 0x41, 0x00])
        // Version
        var version: UInt16 = 1
        file.append(Data(bytes: &version, count: 2))
        // Frame bytes
        var fb = UInt32(frameBytes)
        file.append(Data(bytes: &fb, count: 4))
        // Frame count
        var fc = UInt32(frameCount)
        file.append(Data(bytes: &fc, count: 4))
        // Width, height
        var w = UInt32(width), h = UInt32(height)
        file.append(Data(bytes: &w, count: 4))
        file.append(Data(bytes: &h, count: 4))
        // Seed
        var s = seed
        file.append(Data(bytes: &s, count: 8))
        // Timestamp
        var ts = Int64(Date().timeIntervalSince1970)
        file.append(Data(bytes: &ts, count: 8))
        // Tick range
        let oldest = (head - frameCount + capacity) % capacity
        var tickStart = frameMeta[oldest].tick
        var tickEnd = frameMeta[(head - 1 + capacity) % capacity].tick
        file.append(Data(bytes: &tickStart, count: 4))
        file.append(Data(bytes: &tickEnd, count: 4))
        // Pad to 256 bytes
        let headerSoFar = 8 + 2 + 4 + 4 + 4 + 4 + 8 + 8 + 4 + 4 // = 50
        file.append(Data(repeating: 0, count: 256 - headerSoFar))

        // ── Frame metadata table ──
        for i in 0..<frameCount {
            let idx = (oldest + i) % capacity
            let meta = frameMeta[idx]
            var tick = meta.tick
            var day: UInt8 = meta.isDay ? 1 : 0
            var g = meta.grass, z = meta.zebra, l = meta.lion
            file.append(Data(bytes: &tick, count: 4))
            file.append(Data(bytes: &day, count: 1))
            file.append(Data(repeating: 0, count: 3)) // padding to 8
            file.append(Data(bytes: &g, count: 4))
            file.append(Data(bytes: &z, count: 4))
            file.append(Data(bytes: &l, count: 4)) // 20 bytes... pad to 24
            file.append(Data(repeating: 0, count: 4))
        }

        // ── Raw entity frames (Morton order — matches GPU buffers) ──
        for i in 0..<frameCount {
            let idx = (oldest + i) % capacity
            let ptr = UnsafeRawPointer(ringBuffer.contents() + idx * frameBytes)
            file.append(Data(bytes: ptr, count: frameBytes))
        }

        // Write
        try? file.write(to: URL(fileURLWithPath: path))
        print("  Archived \(frameCount) frames to \(path) (\(file.count / 1_000_000) MB)")
    }

    /// Load a .savanna file for playback. Returns frame count.
    public func loadScenario(from path: String) -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return 0 }

        // Read header
        guard data.count >= 256 else { return 0 }
        let magic = String(data: data[0..<7], encoding: .ascii)
        guard magic == "SAVANNA" else { return 0 }

        let fc = data[14..<18].withUnsafeBytes { $0.load(as: UInt32.self) }
        let fb = data[10..<14].withUnsafeBytes { $0.load(as: UInt32.self) }
        let loadCount = min(Int(fc), capacity)

        // Read frames into ring buffer
        let metaOffset = 256
        let frameOffset = metaOffset + Int(fc) * 24

        for i in 0..<loadCount {
            // Metadata
            let mOff = metaOffset + i * 24
            if mOff + 24 <= data.count {
                let tick = data[mOff..<mOff+4].withUnsafeBytes { $0.load(as: UInt32.self) }
                let day = data[mOff+4] == 1
                let g = data[mOff+8..<mOff+12].withUnsafeBytes { $0.load(as: UInt32.self) }
                let z = data[mOff+12..<mOff+16].withUnsafeBytes { $0.load(as: UInt32.self) }
                let l = data[mOff+16..<mOff+20].withUnsafeBytes { $0.load(as: UInt32.self) }
                frameMeta[i] = FrameMeta(tick: tick, isDay: day, grass: g, zebra: z, lion: l)
            }

            // Frame data
            let fOff = frameOffset + i * Int(fb)
            if fOff + Int(fb) <= data.count {
                let dst = ringBuffer.contents() + i * frameBytes
                data[fOff..<fOff+Int(fb)].withUnsafeBytes { src in
                    memcpy(dst, src.baseAddress!, Int(fb))
                }
            }
        }

        head = loadCount % capacity
        frameCount = loadCount
        totalRecorded = loadCount
        mode = .playback
        playbackHead = 0
        return loadCount
    }
}
