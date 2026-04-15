/// GPUDecoder — Metal-accelerated Carlos Delta frame decode.
///
/// Phase 1: CPU decompresses zlib → GPU does XOR + de-Morton + LOD
/// Phase 2: sparse scatter format, zero CPU (future)
///
/// Pipeline: NVMe → [CPU: zlib inflate] → GPU: XOR → de-Morton → LOD → serve
/// On M-series unified memory: no copies between CPU/GPU.

import Metal
import Foundation
import Compression

public final class GPUDecoder {
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let xorPipeline: MTLComputePipelineState
    let demortPipeline: MTLComputePipelineState
    let lodPipeline: MTLComputePipelineState
    let scatterPipeline: MTLComputePipelineState

    // Buffers (persistent, reused per frame)
    let frameBuf: MTLBuffer       // current frame (Morton order)
    let deltaBuf: MTLBuffer       // decompressed delta (zlib mode)
    let rowMajorBuf: MTLBuffer    // de-Mortoned frame
    let displayBuf: MTLBuffer     // LOD output
    let mortonBuf: MTLBuffer      // mortonToNode mapping
    let sparseIdxBuf: MTLBuffer   // sparse indices (reusable)
    let sparseValBuf: MTLBuffer   // sparse values (reusable)

    public let width: Int
    public let height: Int
    public let cellCount: Int
    public let displayW: Int
    public let displayH: Int
    public let step: Int
    public let needsLOD: Bool

    // .savanna file data
    let data: Data
    let frameOffsets: [Int]
    public let frameCount: Int
    public let totalCells: UInt64
    public let keyframeInterval: Int
    public let isMorton: Bool
    public let format: CarlosDelta.Format
    var currentIndex: Int = -1

    public init(path: String, maxDisplay: Int = 2048) throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw GPUDecoderError.noGPU
        }
        self.device = dev
        guard let q = dev.makeCommandQueue() else {
            throw GPUDecoderError.noQueue
        }
        self.queue = q

        // Load .savanna file
        self.data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count >= 24 else { throw GPUDecoderError.invalidFormat }
        let magic = [UInt8](data[0..<4])
        guard magic == [0x53, 0x44, 0x4C, 0x54] else { throw GPUDecoderError.invalidMagic }

        let w = Int(data[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) })
        let h = Int(data[8..<12].withUnsafeBytes { $0.load(as: UInt32.self) })
        let nf = Int(data[12..<16].withUnsafeBytes { $0.load(as: UInt32.self) })
        let tc = data[16..<24].withUnsafeBytes { $0.load(as: UInt64.self) }

        self.width = w
        self.height = h
        self.frameCount = nf
        self.totalCells = tc
        self.cellCount = w * h

        // v1/v2/v3 detection
        // v1: 24-byte header, zlib, row-major
        // v2: 28-byte header, zlib, Morton, keyframe interval
        // v3: 32-byte header, sparse or zlib, Morton, keyframe interval, format flag
        let kfiCandidate = Int(data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) })
        var offset: Int
        if kfiCandidate > 0 && kfiCandidate <= 1000 {
            self.keyframeInterval = kfiCandidate
            self.isMorton = true
            // Check for v3 format flag at offset 28
            if data.count >= 32 {
                let fmtRaw = data[28..<32].withUnsafeBytes { $0.load(as: UInt32.self) }
                self.format = CarlosDelta.Format(rawValue: fmtRaw) ?? .zlib
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

        // Scan frame offsets
        var offsets = [Int]()
        for _ in 0..<nf {
            offsets.append(offset)
            let sz = Int(data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) })
            offset += 4 + sz
        }
        self.frameOffsets = offsets

        // LOD setup
        if w > maxDisplay || h > maxDisplay {
            self.step = max(w / maxDisplay, h / maxDisplay)
            self.displayW = w / step
            self.displayH = h / step
            self.needsLOD = true
        } else {
            self.step = 1
            self.displayW = w
            self.displayH = h
            self.needsLOD = false
        }

        // Allocate GPU buffers (shared memory — CPU and GPU see same bytes)
        let shared = MTLResourceOptions.storageModeShared
        self.frameBuf = dev.makeBuffer(length: cellCount, options: shared)!
        self.deltaBuf = dev.makeBuffer(length: cellCount, options: shared)!
        self.rowMajorBuf = dev.makeBuffer(length: cellCount, options: shared)!
        self.displayBuf = dev.makeBuffer(length: displayW * displayH, options: shared)!
        // Sparse buffers: sized for worst case (all cells change)
        self.sparseIdxBuf = dev.makeBuffer(length: cellCount * 4, options: shared)!
        self.sparseValBuf = dev.makeBuffer(length: cellCount, options: shared)!

        // Build Morton mapping and upload to GPU
        let mortonToNode = isMorton ?
            CarlosDelta.buildMortonToNode(width: w, height: h) : []
        if isMorton {
            self.mortonBuf = dev.makeBuffer(bytes: mortonToNode,
                                             length: mortonToNode.count * 4,
                                             options: shared)!
        } else {
            self.mortonBuf = dev.makeBuffer(length: 4, options: shared)!
        }

        // Load Metal library and create pipelines
        // Metal shaders are compiled from savanna.metal in the Savanna module
        let library: MTLLibrary
        if let defaultLib = dev.makeDefaultLibrary() {
            library = defaultLib
        } else {
            // Try loading from bundle or compiled metallib
            let metalPath = Bundle.main.path(forResource: "default", ofType: "metallib")
            if let p = metalPath {
                library = try dev.makeLibrary(URL: URL(fileURLWithPath: p))
            } else {
                throw GPUDecoderError.noLibrary
            }
        }

        self.xorPipeline = try dev.makeComputePipelineState(
            function: library.makeFunction(name: "delta_xor")!)
        self.demortPipeline = try dev.makeComputePipelineState(
            function: library.makeFunction(name: "delta_demorton")!)
        self.lodPipeline = try dev.makeComputePipelineState(
            function: library.makeFunction(name: "delta_lod_downsample")!)
        self.scatterPipeline = try dev.makeComputePipelineState(
            function: library.makeFunction(name: "delta_sparse_scatter")!)
    }

    /// Decompress a frame from disk (CPU — zlib only, ~10ms for 100M)
    func decompressFrame(at index: Int) -> UnsafeMutableRawPointer {
        let off = frameOffsets[index]
        let sz = Int(data[off..<off+4].withUnsafeBytes { $0.load(as: UInt32.self) })
        let compressed = [UInt8](data[off+4..<off+4+sz])

        // Decompress directly into deltaBuf (unified memory — GPU sees it immediately)
        let dst = deltaBuf.contents().bindMemory(to: UInt8.self, capacity: cellCount)
        let decodedSize = compression_decode_buffer(
            dst, cellCount,
            compressed, compressed.count,
            nil, COMPRESSION_ZLIB
        )
        _ = decodedSize  // should equal cellCount
        return deltaBuf.contents()
    }

    /// Is this frame an I-frame?
    func isKeyframe(_ index: Int) -> Bool {
        return index == 0 || (keyframeInterval > 0 && index % keyframeInterval == 0)
    }

    /// Nearest I-frame at or before index
    func nearestKeyframe(before index: Int) -> Int {
        if keyframeInterval <= 0 { return 0 }
        return (index / keyframeInterval) * keyframeInterval
    }

    /// Decode frame to GPU buffer. CPU does zlib only. GPU does XOR + de-Morton + LOD.
    public func decodeFrame(_ index: Int) {
        if index == currentIndex { return }

        let kf = nearestKeyframe(before: index)

        // Reset to keyframe if needed
        if currentIndex < 0 || currentIndex > index || currentIndex < kf {
            // Decompress keyframe directly into frameBuf
            let off = frameOffsets[kf]
            let sz = Int(data[off..<off+4].withUnsafeBytes { $0.load(as: UInt32.self) })
            let compressed = [UInt8](data[off+4..<off+4+sz])
            let dst = frameBuf.contents().bindMemory(to: UInt8.self, capacity: cellCount)
            compression_decode_buffer(dst, cellCount, compressed, compressed.count, nil, COMPRESSION_ZLIB)
            currentIndex = kf
        }

        // Decode forward
        while currentIndex < index {
            let next = currentIndex + 1

            if isKeyframe(next) {
                // I-frame: zlib decompress directly into frameBuf (CPU, rare)
                let off = frameOffsets[next]
                let sz = Int(data[off..<off+4].withUnsafeBytes { $0.load(as: UInt32.self) })
                let compressed = [UInt8](data[off+4..<off+4+sz])
                let dst = frameBuf.contents().bindMemory(to: UInt8.self, capacity: cellCount)
                compression_decode_buffer(dst, cellCount, compressed, compressed.count, nil, COMPRESSION_ZLIB)
            } else if format == .sparse {
                // P-frame SPARSE: read (index, value) pairs, GPU scatter XOR — ZERO CPU
                let off = frameOffsets[next]
                let totalSize = Int(data[off..<off+4].withUnsafeBytes { $0.load(as: UInt32.self) })
                let count = Int(data[off+4..<off+8].withUnsafeBytes { $0.load(as: UInt32.self) })
                _ = totalSize

                // Copy indices and values into GPU buffers (unified memory — just memcpy)
                let idxStart = off + 8
                let valStart = idxStart + count * 4
                let idxDst = sparseIdxBuf.contents().bindMemory(to: UInt8.self, capacity: count * 4)
                let valDst = sparseValBuf.contents().bindMemory(to: UInt8.self, capacity: count)
                data[idxStart..<idxStart + count * 4].withUnsafeBytes {
                    memcpy(idxDst, $0.baseAddress!, count * 4)
                }
                data[valStart..<valStart + count].withUnsafeBytes {
                    memcpy(valDst, $0.baseAddress!, count)
                }

                // GPU scatter: frame[indices[i]] ^= values[i]
                guard let cmdBuf = queue.makeCommandBuffer(),
                      let enc = cmdBuf.makeComputeCommandEncoder() else { break }

                enc.setComputePipelineState(scatterPipeline)
                enc.setBuffer(frameBuf, offset: 0, index: 0)
                enc.setBuffer(sparseIdxBuf, offset: 0, index: 1)
                enc.setBuffer(sparseValBuf, offset: 0, index: 2)
                var cnt = UInt32(count)
                enc.setBytes(&cnt, length: 4, index: 3)
                let tpg = scatterPipeline.maxTotalThreadsPerThreadgroup
                enc.dispatchThreadgroups(
                    MTLSize(width: (count + tpg - 1) / tpg, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
                enc.endEncoding()
                cmdBuf.commit()
                cmdBuf.waitUntilCompleted()
            } else {
                // P-frame ZLIB: decompress delta, GPU XOR
                _ = decompressFrame(at: next)

                guard let cmdBuf = queue.makeCommandBuffer(),
                      let enc = cmdBuf.makeComputeCommandEncoder() else { break }

                enc.setComputePipelineState(xorPipeline)
                enc.setBuffer(frameBuf, offset: 0, index: 0)
                enc.setBuffer(deltaBuf, offset: 0, index: 1)
                var count = UInt32(cellCount)
                enc.setBytes(&count, length: 4, index: 2)
                let tpg = xorPipeline.maxTotalThreadsPerThreadgroup
                enc.dispatchThreadgroups(
                    MTLSize(width: (cellCount + tpg - 1) / tpg, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
                enc.endEncoding()
                cmdBuf.commit()
                cmdBuf.waitUntilCompleted()
            }
            currentIndex = next
        }
    }

    /// Get display-ready frame. GPU does de-Morton + LOD.
    /// Returns pointer to displayBuf (or rowMajorBuf if no LOD).
    public func displayFrame(_ index: Int) -> [Int8] {
        decodeFrame(min(index, frameCount - 1))

        guard let cmdBuf = queue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            // Fallback: return raw frame
            let ptr = frameBuf.contents().bindMemory(to: Int8.self, capacity: cellCount)
            return Array(UnsafeBufferPointer(start: ptr, count: cellCount))
        }

        // Step 1: de-Morton (if v2 Morton file)
        let entitySource: MTLBuffer
        if isMorton {
            enc.setComputePipelineState(demortPipeline)
            enc.setBuffer(frameBuf, offset: 0, index: 0)
            enc.setBuffer(rowMajorBuf, offset: 0, index: 1)
            enc.setBuffer(mortonBuf, offset: 0, index: 2)
            var count = UInt32(cellCount)
            enc.setBytes(&count, length: 4, index: 3)
            let tpg = demortPipeline.maxTotalThreadsPerThreadgroup
            enc.dispatchThreadgroups(
                MTLSize(width: (cellCount + tpg - 1) / tpg, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            entitySource = rowMajorBuf
        } else {
            entitySource = frameBuf
        }

        // Step 2: LOD downsample (if needed)
        if needsLOD {
            enc.setComputePipelineState(lodPipeline)
            enc.setBuffer(entitySource, offset: 0, index: 0)
            enc.setBuffer(displayBuf, offset: 0, index: 1)
            var sw = UInt32(width), dw = UInt32(displayW), dh = UInt32(displayH), st = UInt32(step)
            enc.setBytes(&sw, length: 4, index: 2)
            enc.setBytes(&dw, length: 4, index: 3)
            enc.setBytes(&dh, length: 4, index: 4)
            enc.setBytes(&st, length: 4, index: 5)
            let n = displayW * displayH
            let tpg2 = lodPipeline.maxTotalThreadsPerThreadgroup
            enc.dispatchThreadgroups(
                MTLSize(width: (n + tpg2 - 1) / tpg2, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tpg2, height: 1, depth: 1))
            enc.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()

            let ptr = displayBuf.contents().bindMemory(to: Int8.self, capacity: n)
            return Array(UnsafeBufferPointer(start: ptr, count: n))
        } else {
            enc.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()

            let n = cellCount
            let ptr = entitySource.contents().bindMemory(to: Int8.self, capacity: n)
            return Array(UnsafeBufferPointer(start: ptr, count: n))
        }
    }

    enum GPUDecoderError: Error {
        case noGPU
        case noQueue
        case invalidFormat
        case invalidMagic
        case noLibrary
    }
}
