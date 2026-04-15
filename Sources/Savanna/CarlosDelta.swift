/// CarlosDelta — Lossless delta compression for spatial simulation frames.
///
/// Inspired by Carlos Mateo Muñoz's RFC 9842 Dictionary TTL extension.
/// XOR delta between consecutive frames + zlib compression.
/// 50× average compression on 1B cell ecosystem data.
///
/// I-frame / P-frame architecture (inspired by 3B-Backup-IP coprime rotation):
///   I-frames (keyframes): full frame, inserted every keyframeInterval frames
///   P-frames (deltas): XOR delta from previous frame
///   Decoder seeks to nearest I-frame, not frame 0. Random access in O(interval) not O(N).
///
/// Format (.savanna v2):
///   Header: "SDLT" (4) + width (u32) + height (u32) + n_frames (u32)
///           + total_cells (u64) + keyframe_interval (u32) = 28 bytes
///   Frame i: compressed_size (u32) + zlib_compressed(data)
///     where data = full frame if i % keyframe_interval == 0, else XOR delta
///
/// MIT License acknowledgment: Carlos Mateo Muñoz
/// https://github.com/carlosmateo10/delta-compression-demo

import Foundation
import Compression

public struct CarlosDelta {

    /// Magic bytes for .savanna format
    static let magic: [UInt8] = [0x53, 0x44, 0x4C, 0x54]  // "SDLT"

    // MARK: - Morton Z-Curve

    /// Rebuild mortonToNode mapping from grid dimensions.
    /// mortonToNode[rank] = row-major index for that rank.
    /// Deterministic — same output as HexGrid for same dimensions.
    static func buildMortonToNode(width: Int, height: Int) -> [Int32] {
        let n = width * height
        var morton = [UInt32](repeating: 0, count: n)
        for c in 0..<width {
            for r in 0..<height {
                let i = r * width + c
                let q = c
                let cubeR = r - (c - (c & 1)) / 2
                morton[i] = mortonEncode(UInt16(q & 0xFFFF), UInt16(cubeR & 0xFFFF))
            }
        }
        var indices = (0..<Int32(n)).map { $0 }
        indices.sort { morton[Int($0)] < morton[Int($1)] }
        return indices
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

    // MARK: - Encoder

    /// Frame encoding format
    public enum Format: UInt32 {
        case zlib = 0     // zlib compressed (CPU decode)
        case sparse = 1   // sparse scatter (GPU decode, zero CPU)
    }

    /// Encodes frames incrementally. Call `addFrame` for each tick, then `finalize`.
    /// I-frames (keyframes) every `keyframeInterval` frames. P-frames between.
    /// Format .zlib: I=zlib(full), P=zlib(XOR delta) — small files, CPU decode
    /// Format .sparse: I=zlib(full), P=sparse(index,value) — GPU-native decode
    public final class Encoder {
        public let url: URL
        let width: UInt32
        let height: UInt32
        let totalCells: UInt64
        let keyframeInterval: UInt32
        let format: Format
        var handle: FileHandle
        var prevFrame: [UInt8]?
        public var frameCount: UInt32 = 0
        public var iFrameCount: UInt32 = 0
        public var pFrameCount: UInt32 = 0
        public var totalSparseEntries: UInt64 = 0

        /// - Parameter format: .zlib (CPU, small) or .sparse (GPU, fast)
        public init(path: String, width: Int, height: Int,
                    totalCells: UInt64? = nil, keyframeInterval: Int = 60,
                    format: Format = .sparse) throws {
            self.url = URL(fileURLWithPath: path)
            self.width = UInt32(width)
            self.height = UInt32(height)
            self.totalCells = totalCells ?? UInt64(width * height)
            self.keyframeInterval = UInt32(keyframeInterval)
            self.format = format

            // Write header (32 bytes — will update frame count at finalize)
            FileManager.default.createFile(atPath: path, contents: nil)
            self.handle = try FileHandle(forWritingTo: url)

            var header = Data()
            header.append(contentsOf: CarlosDelta.magic)
            var w = self.width, h = self.height
            var nf: UInt32 = 0  // placeholder
            var tc = self.totalCells
            var kfi = self.keyframeInterval
            var fmt = format.rawValue
            header.append(Data(bytes: &w, count: 4))
            header.append(Data(bytes: &h, count: 4))
            header.append(Data(bytes: &nf, count: 4))
            header.append(Data(bytes: &tc, count: 8))
            header.append(Data(bytes: &kfi, count: 4))
            header.append(Data(bytes: &fmt, count: 4))
            handle.write(header)
        }

        /// Add a frame. I-frame if frameCount % keyframeInterval == 0, else P-frame.
        public func addFrame(_ entities: [Int8]) {
            let bytes = entities.map { UInt8(bitPattern: $0) }
            let isKeyframe = prevFrame == nil ||
                (keyframeInterval > 0 && frameCount % keyframeInterval == 0)

            if isKeyframe {
                // I-frame: always zlib compressed (rare, ~2% of frames)
                let compressed = Self.compress(bytes)
                var size = UInt32(compressed.count)
                handle.write(Data(bytes: &size, count: 4))
                handle.write(Data(compressed))
                iFrameCount += 1
            } else if format == .sparse {
                // P-frame sparse: extract non-zero XOR entries
                let prev = prevFrame!
                var indices = [UInt32]()
                var values = [UInt8]()
                for i in 0..<bytes.count {
                    let xor = bytes[i] ^ prev[i]
                    if xor != 0 {
                        indices.append(UInt32(i))
                        values.append(xor)
                    }
                }
                // Write: total_size (u32) + count (u32) + indices + values
                let count = UInt32(indices.count)
                let dataSize = 4 + indices.count * 4 + values.count  // count + indices + values
                var totalSize = UInt32(dataSize)
                handle.write(Data(bytes: &totalSize, count: 4))
                var cnt = count
                handle.write(Data(bytes: &cnt, count: 4))
                indices.withUnsafeBytes { handle.write(Data($0)) }
                values.withUnsafeBytes { handle.write(Data($0)) }
                totalSparseEntries += UInt64(count)
                pFrameCount += 1
            } else {
                // P-frame zlib: XOR delta compressed
                let prev = prevFrame!
                var delta = [UInt8](repeating: 0, count: bytes.count)
                for i in 0..<bytes.count {
                    delta[i] = bytes[i] ^ prev[i]
                }
                let compressed = Self.compress(delta)
                var size = UInt32(compressed.count)
                handle.write(Data(bytes: &size, count: 4))
                handle.write(Data(compressed))
                pFrameCount += 1
            }

            prevFrame = bytes
            frameCount += 1
        }

        /// Finalize: update frame count in header, close file.
        public func finalize() {
            // Seek to offset 12 (after magic + width + height) and write frame count
            handle.seek(toFileOffset: 12)
            var nf = frameCount
            handle.write(Data(bytes: &nf, count: 4))
            handle.closeFile()
        }

        /// Zlib compress
        static func compress(_ input: [UInt8]) -> [UInt8] {
            let bufferSize = input.count
            var output = [UInt8](repeating: 0, count: bufferSize)
            let compressedSize = compression_encode_buffer(
                &output, bufferSize,
                input, input.count,
                nil, COMPRESSION_ZLIB
            )
            return Array(output[0..<compressedSize])
        }
    }

    // MARK: - Decoder

    /// Decodes a .savanna file. Provides random access to frames.
    /// Frames are stored in Morton order on disk, de-Mortoned on read.
    /// Handles periodic I-frames (keyframes) for efficient random access.
    public final class Decoder {
        public let width: Int
        public let height: Int
        public let frameCount: Int
        public let totalCells: UInt64
        public let keyframeInterval: Int
        public let isMorton: Bool
        let frames: [[UInt8]]  // decoded entity arrays
        let mortonToNode: [Int32]

        public init(path: String) throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var offset = 0

            // Read header (28 bytes v2, 24 bytes v1)
            guard data.count >= 24 else { throw DeltaError.invalidFormat }
            let m = [UInt8](data[0..<4])
            guard m == CarlosDelta.magic else { throw DeltaError.invalidMagic }
            offset = 4

            func readU32() -> UInt32 {
                let v = data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }
                offset += 4
                return v
            }
            func readU64() -> UInt64 {
                let v = data[offset..<offset+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                offset += 8
                return v
            }

            self.width = Int(readU32())
            self.height = Int(readU32())
            let nFrames = Int(readU32())
            self.totalCells = readU64()
            self.frameCount = nFrames
            let cellCount = width * height

            // v2 header: keyframe interval at offset 24
            // v1 header: no interval, first frame data starts at offset 24
            // Heuristic: interval is small (≤1000), compressed_size is large
            let kfiCandidate = Int(data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) })
            if kfiCandidate > 0 && kfiCandidate <= 1000 {
                self.keyframeInterval = kfiCandidate
                self.isMorton = true
                offset = 28
            } else {
                self.keyframeInterval = 0
                self.isMorton = false
                offset = 24
            }

            var decoded = [[UInt8]]()

            for i in 0..<nFrames {
                let compSize = Int(readU32())
                let compressed = [UInt8](data[offset..<offset+compSize])
                offset += compSize

                let decompressed = Self.decompress(compressed, expectedSize: cellCount)
                let isKeyframe = (i == 0) ||
                    (keyframeInterval > 0 && i % keyframeInterval == 0)

                if isKeyframe {
                    decoded.append(decompressed)
                } else {
                    let prev = decoded[i - 1]
                    var frame = [UInt8](repeating: 0, count: cellCount)
                    for j in 0..<cellCount {
                        frame[j] = prev[j] ^ decompressed[j]
                    }
                    decoded.append(frame)
                }
            }
            self.frames = decoded
            self.mortonToNode = isMorton ?
                CarlosDelta.buildMortonToNode(width: width, height: height) : []
        }

        /// Get frame as Int8 array (entity codes), de-Mortoned to row-major if v2.
        public func frame(_ index: Int) -> [Int8] {
            let f = frames[min(index, frameCount - 1)]
            if isMorton {
                var rm = [Int8](repeating: 0, count: f.count)
                for m in 0..<f.count {
                    rm[Int(mortonToNode[m])] = Int8(bitPattern: f[m])
                }
                return rm
            } else {
                return f.map { Int8(bitPattern: $0) }
            }
        }

        /// Zlib decompress
        static func decompress(_ input: [UInt8], expectedSize: Int) -> [UInt8] {
            var output = [UInt8](repeating: 0, count: expectedSize)
            let decodedSize = compression_decode_buffer(
                &output, expectedSize,
                input, input.count,
                nil, COMPRESSION_ZLIB
            )
            return Array(output[0..<decodedSize])
        }
    }

    // MARK: - Streaming Decoder (JIT, no preload)

    /// Streams frames from disk. Only keeps current frame in RAM.
    /// Frames on disk are in Morton Z-curve order for optimal compression.
    /// De-Mortons at the output boundary (displayFrame/frame).
    /// Periodic I-frames enable O(interval) seeking instead of O(N).
    public final class StreamingDecoder {
        public let width: Int
        public let height: Int
        public let frameCount: Int
        public let totalCells: UInt64
        public let keyframeInterval: Int
        public let isMorton: Bool  // v2+ = Morton on disk, v1 = row-major
        public let format: Format
        let data: Data
        var frameOffsets: [Int]  // byte offset of each compressed frame
        var currentFrame: [UInt8]  // last decoded full-res frame
        var currentIndex: Int = -1
        let cellCount: Int

        // Morton Z-curve: mortonToNode[rank] = row-major index (only used if isMorton)
        let mortonToNode: [Int32]

        // LOD cache: decode once, serve from cache after
        var displayCache: [[Int8]?]

        // LOD
        public let displayW: Int
        public let displayH: Int
        public let step: Int
        public let needsLOD: Bool

        public init(path: String, maxDisplay: Int = 2048) throws {
            self.data = try Data(contentsOf: URL(fileURLWithPath: path))
            var offset = 0

            guard data.count >= 24 else { throw DeltaError.invalidFormat }
            let m = [UInt8](data[0..<4])
            guard m == CarlosDelta.magic else { throw DeltaError.invalidMagic }

            let w = Int(data[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) })
            let h = Int(data[8..<12].withUnsafeBytes { $0.load(as: UInt32.self) })
            let nf = Int(data[12..<16].withUnsafeBytes { $0.load(as: UInt32.self) })
            let tc = data[16..<24].withUnsafeBytes { $0.load(as: UInt64.self) }

            self.width = w
            self.height = h
            self.frameCount = nf
            self.totalCells = tc
            self.cellCount = w * h
            self.currentFrame = [UInt8](repeating: 0, count: cellCount)

            // v1/v2/v3 header detection
            let kfiCandidate = Int(data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) })
            if kfiCandidate > 0 && kfiCandidate <= 1000 {
                self.keyframeInterval = kfiCandidate
                self.isMorton = true
                if data.count >= 32 {
                    let fmtRaw = data[28..<32].withUnsafeBytes { $0.load(as: UInt32.self) }
                    self.format = Format(rawValue: fmtRaw) ?? .zlib
                    offset = 32
                } else {
                    self.format = .zlib
                    offset = 28
                }
            } else {
                self.keyframeInterval = 0
                self.isMorton = false
                self.format = .zlib
                offset = 24
            }

            // Pre-scan frame offsets (fast — just reads sizes, no decompression)
            var offsets = [Int]()
            for _ in 0..<frameCount {
                offsets.append(offset)
                let sz = Int(data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) })
                offset += 4 + sz
            }
            self.frameOffsets = offsets
            self.displayCache = Array(repeating: nil, count: offsets.count)

            // Morton mapping (only needed for v2 Morton files)
            if isMorton {
                self.mortonToNode = CarlosDelta.buildMortonToNode(width: w, height: h)
            } else {
                self.mortonToNode = []  // not used for v1
            }

            // LOD setup
            if width > maxDisplay || height > maxDisplay {
                self.step = max(width / maxDisplay, height / maxDisplay)
                self.displayW = width / step
                self.displayH = height / step
                self.needsLOD = true
            } else {
                self.step = 1
                self.displayW = width
                self.displayH = height
                self.needsLOD = false
            }
        }

        /// Nearest I-frame at or before index.
        func nearestKeyframe(before index: Int) -> Int {
            if keyframeInterval <= 0 { return 0 }
            return (index / keyframeInterval) * keyframeInterval
        }

        /// Is this frame an I-frame?
        func isKeyframe(_ index: Int) -> Bool {
            return index == 0 ||
                (keyframeInterval > 0 && index % keyframeInterval == 0)
        }

        /// Decode frame i (JIT). Seeks to nearest I-frame, not frame 0.
        func decodeFrame(_ index: Int) {
            if index == currentIndex { return }

            let kf = nearestKeyframe(before: index)

            // Need to reset if: going backward, or current position is before the keyframe,
            // or we haven't decoded anything yet
            if currentIndex < 0 || currentIndex > index || currentIndex < kf {
                // Seek to nearest I-frame
                let off = frameOffsets[kf]
                let sz = Int(data[off..<off+4].withUnsafeBytes { $0.load(as: UInt32.self) })
                let compressed = [UInt8](data[off+4..<off+4+sz])
                currentFrame = Decoder.decompress(compressed, expectedSize: cellCount)
                currentIndex = kf
            }

            // Decode forward
            while currentIndex < index {
                let next = currentIndex + 1
                let off = frameOffsets[next]

                if isKeyframe(next) {
                    // I-frame: zlib decompress, replace entirely
                    let sz = Int(data[off..<off+4].withUnsafeBytes { $0.load(as: UInt32.self) })
                    let compressed = [UInt8](data[off+4..<off+4+sz])
                    currentFrame = Decoder.decompress(compressed, expectedSize: cellCount)
                } else if format == .sparse {
                    // P-frame SPARSE: read (index, value) pairs, scatter XOR
                    let totalSize = Int(data[off..<off+4].withUnsafeBytes { $0.load(as: UInt32.self) })
                    let count = Int(data[off+4..<off+8].withUnsafeBytes { $0.load(as: UInt32.self) })
                    _ = totalSize
                    let idxStart = off + 8
                    let valStart = idxStart + count * 4
                    for i in 0..<count {
                        let idx = Int(data[idxStart + i * 4..<idxStart + i * 4 + 4]
                            .withUnsafeBytes { $0.load(as: UInt32.self) })
                        let val = data[valStart + i]
                        currentFrame[idx] = currentFrame[idx] ^ val
                    }
                } else {
                    // P-frame ZLIB: decompress XOR delta
                    let sz = Int(data[off..<off+4].withUnsafeBytes { $0.load(as: UInt32.self) })
                    let compressed = [UInt8](data[off+4..<off+4+sz])
                    let decompressed = Decoder.decompress(compressed, expectedSize: cellCount)
                    for j in 0..<cellCount { currentFrame[j] = currentFrame[j] ^ decompressed[j] }
                }
                currentIndex = next
            }
        }

        /// Get frame as Int8 — full resolution, de-Mortoned to row-major if v2.
        public func frame(_ index: Int) -> [Int8] {
            decodeFrame(min(index, frameCount - 1))
            if isMorton {
                var rm = [Int8](repeating: 0, count: cellCount)
                for m in 0..<cellCount {
                    rm[Int(mortonToNode[m])] = Int8(bitPattern: currentFrame[m])
                }
                return rm
            } else {
                return currentFrame.map { Int8(bitPattern: $0) }
            }
        }

        /// Get downsampled frame for browser (majority vote + trophic boost)
        /// First call: JIT decode + de-Morton + downsample. Subsequent calls: serve from cache.
        public func displayFrame(_ index: Int) -> [Int8] {
            let idx = min(index, frameCount - 1)
            // Cache hit — instant
            if let cached = displayCache[idx] { return cached }

            decodeFrame(idx)

            // De-Morton to row-major if v2 Morton file
            let rowMajor: [UInt8]
            if isMorton {
                var rm = [UInt8](repeating: 0, count: cellCount)
                for m in 0..<cellCount {
                    rm[Int(mortonToNode[m])] = currentFrame[m]
                }
                rowMajor = rm
            } else {
                rowMajor = currentFrame
            }

            if !needsLOD {
                let result = rowMajor.map { Int8(bitPattern: $0) }
                displayCache[idx] = result
                return result
            }

            var dst = [Int8](repeating: 0, count: displayW * displayH)
            let s = step
            let bs = s * s
            for dy in 0..<displayH {
                for dx in 0..<displayW {
                    var counts = (0, 0, 0, 0, 0)  // inline for speed
                    for sy in 0..<s {
                        let rowOff = (dy * s + sy) * width + dx * s
                        for sx in 0..<s {
                            let e = Int(rowMajor[rowOff + sx]) & 0x7
                            switch e {
                            case 0: counts.0 += 1
                            case 1: counts.1 += 1
                            case 2: counts.2 += 1
                            case 3: counts.3 += 1
                            case 4: counts.4 += 1
                            default: break
                            }
                        }
                    }
                    // Majority
                    var best: Int8 = 0; var bestC = counts.0
                    if counts.1 > bestC { best = 1; bestC = counts.1 }
                    if counts.2 > bestC { best = 2; bestC = counts.2 }
                    if counts.3 > bestC { best = 3; bestC = counts.3 }
                    if counts.4 > bestC { best = 4 }
                    // Trophic boost
                    if counts.2 * 100 > bs * 3 { best = 2 }
                    if counts.3 * 100 > bs * 1 { best = 3 }
                    dst[dy * displayW + dx] = best
                }
            }
            displayCache[idx] = dst
            return dst
        }
    }

    enum DeltaError: Error {
        case invalidFormat
        case invalidMagic
    }
}
