/// MetalEngine — GPU compute with three senses + scent diffusion.
///
/// Per tick: 3 scent diffusions + 4 color phases + grass growth + census.
/// 8 kernel dispatches total per tick. All in one MTLCommandBuffer.

import Metal
import Foundation

public final class MetalEngine {
    public let device: MTLDevice
    public var recorder: SimRecorder?
    let queue: MTLCommandQueue
    let tickPipeline: MTLComputePipelineState
    let grassPipeline: MTLComputePipelineState
    let censusPipeline: MTLComputePipelineState
    let scentPipeline: MTLComputePipelineState

    // State buffers
    let entityBuf: MTLBuffer
    let energyBuf: MTLBuffer
    let ternaryBuf: MTLBuffer
    let gaugeBuf: MTLBuffer
    let orientationBuf: MTLBuffer
    let neighborsBuf: MTLBuffer
    let colorGroupBufs: [MTLBuffer]
    let colorGroupSizes: [Int]

    // Scent buffers (double-buffered: current + previous)
    let scentZebraBuf: MTLBuffer     // lions track this
    let scentZebraPrevBuf: MTLBuffer
    let scentGrassBuf: MTLBuffer     // zebras track this
    let scentGrassPrevBuf: MTLBuffer
    let scentLionBuf: MTLBuffer      // zebras flee this
    let scentLionPrevBuf: MTLBuffer
    let scentWaterBuf: MTLBuffer     // everyone needs water
    let scentWaterPrevBuf: MTLBuffer

    // Census output
    let censusGrass: MTLBuffer
    let censusZebra: MTLBuffer
    let censusLion: MTLBuffer
    let censusEnergy: MTLBuffer

    let nodeCount: Int

    public init(grid: HexGrid, state: SavannaState) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw MetalError.noDevice
        }
        self.device = device
        self.queue = queue
        self.nodeCount = grid.nodeCount
        let n = nodeCount

        // Compile shaders from source
        let bundle = Bundle.module
        let shaderURL = bundle.url(forResource: "savanna", withExtension: "metal")!
        let source = try String(contentsOf: shaderURL)
        let library = try device.makeLibrary(source: source, options: nil)

        self.tickPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "tick_phase")!)
        self.grassPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "grow_grass")!)
        self.censusPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "census_reduce")!)
        self.scentPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "diffuse_scent")!)

        // State buffers
        let shared = MTLResourceOptions.storageModeShared
        self.entityBuf = device.makeBuffer(bytes: state.entity, length: n * 1, options: shared)!
        self.energyBuf = device.makeBuffer(bytes: state.energy, length: n * 2, options: shared)!
        self.ternaryBuf = device.makeBuffer(bytes: state.ternary, length: n * 1, options: shared)!
        self.gaugeBuf = device.makeBuffer(bytes: state.gauge, length: n * 2, options: shared)!
        self.orientationBuf = device.makeBuffer(bytes: state.orientation, length: n * 1, options: shared)!
        self.neighborsBuf = device.makeBuffer(bytes: grid.neighbors, length: grid.neighbors.count * 4, options: shared)!

        // Color groups
        var groupBufs: [MTLBuffer] = []
        var groupSizes: [Int] = []
        for i in 0..<HexGrid.colorCount {
            let g = grid.colorGroups[i].map { UInt32($0) }
            groupBufs.append(device.makeBuffer(bytes: g, length: g.count * 4, options: shared)!)
            groupSizes.append(g.count)
        }
        self.colorGroupBufs = groupBufs
        self.colorGroupSizes = groupSizes

        // Scent buffers (float32, zero-initialized)
        self.scentZebraBuf = device.makeBuffer(length: n * 4, options: shared)!
        self.scentZebraPrevBuf = device.makeBuffer(length: n * 4, options: shared)!
        self.scentGrassBuf = device.makeBuffer(length: n * 4, options: shared)!
        self.scentGrassPrevBuf = device.makeBuffer(length: n * 4, options: shared)!
        self.scentLionBuf = device.makeBuffer(length: n * 4, options: shared)!
        self.scentLionPrevBuf = device.makeBuffer(length: n * 4, options: shared)!
        self.scentWaterBuf = device.makeBuffer(length: n * 4, options: shared)!
        self.scentWaterPrevBuf = device.makeBuffer(length: n * 4, options: shared)!

        // Census
        self.censusGrass = device.makeBuffer(length: 4, options: shared)!
        self.censusZebra = device.makeBuffer(length: 4, options: shared)!
        self.censusLion = device.makeBuffer(length: 4, options: shared)!
        self.censusEnergy = device.makeBuffer(length: 4, options: shared)!
    }

    /// Dispatch a scent diffusion pass.
    private func encodeScent(cmdBuf: MTLCommandBuffer, scent: MTLBuffer, prev: MTLBuffer,
                             sourceType: Int8, emitStr: Float) {
        // Copy current → prev
        guard let blit = cmdBuf.makeBlitCommandEncoder() else { return }
        blit.copy(from: scent, sourceOffset: 0, to: prev, destinationOffset: 0, size: nodeCount * 4)
        blit.endEncoding()

        guard let enc = cmdBuf.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(scentPipeline)
        enc.setBuffer(scent, offset: 0, index: 0)
        enc.setBuffer(prev, offset: 0, index: 1)
        enc.setBuffer(entityBuf, offset: 0, index: 2)
        enc.setBuffer(neighborsBuf, offset: 0, index: 3)
        var st = sourceType
        enc.setBytes(&st, length: 1, index: 4)
        var es = emitStr
        enc.setBytes(&es, length: 4, index: 5)
        var nc = UInt32(nodeCount)
        enc.setBytes(&nc, length: 4, index: 6)

        let tpg = scentPipeline.maxTotalThreadsPerThreadgroup
        enc.dispatchThreadgroups(MTLSize(width: (nodeCount + tpg - 1) / tpg, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        enc.endEncoding()
    }

    public func tick(tickNumber: UInt32, isDay: Bool) {
        guard let cmdBuf = queue.makeCommandBuffer() else { return }

        // 1. Scent diffusion (3 passes)
        encodeScent(cmdBuf: cmdBuf, scent: scentZebraBuf, prev: scentZebraPrevBuf,
                    sourceType: 2, emitStr: 1.0)    // zebras emit
        encodeScent(cmdBuf: cmdBuf, scent: scentGrassBuf, prev: scentGrassPrevBuf,
                    sourceType: 1, emitStr: 0.5)     // grass emits
        encodeScent(cmdBuf: cmdBuf, scent: scentLionBuf, prev: scentLionPrevBuf,
                    sourceType: 3, emitStr: 0.8)     // lions emit
        encodeScent(cmdBuf: cmdBuf, scent: scentWaterBuf, prev: scentWaterPrevBuf,
                    sourceType: 4, emitStr: 15.0)    // water refugia — survival hubs

        var tick = tickNumber
        var day: UInt32 = isDay ? 1 : 0

        // 2. Four color-group tick phases
        for phase in 0..<HexGrid.colorCount {
            guard let enc = cmdBuf.makeComputeCommandEncoder() else { continue }
            enc.setComputePipelineState(tickPipeline)
            enc.setBuffer(entityBuf, offset: 0, index: 0)
            enc.setBuffer(energyBuf, offset: 0, index: 1)
            enc.setBuffer(ternaryBuf, offset: 0, index: 2)
            enc.setBuffer(gaugeBuf, offset: 0, index: 3)
            enc.setBuffer(orientationBuf, offset: 0, index: 4)
            enc.setBuffer(neighborsBuf, offset: 0, index: 5)
            enc.setBuffer(colorGroupBufs[phase], offset: 0, index: 6)
            enc.setBuffer(scentZebraBuf, offset: 0, index: 7)
            enc.setBuffer(scentGrassBuf, offset: 0, index: 8)
            enc.setBuffer(scentLionBuf, offset: 0, index: 9)
            enc.setBuffer(scentWaterBuf, offset: 0, index: 10)
            enc.setBytes(&tick, length: 4, index: 11)
            enc.setBytes(&day, length: 4, index: 12)
            var size = UInt32(colorGroupSizes[phase])
            enc.setBytes(&size, length: 4, index: 13)

            let tpg = tickPipeline.maxTotalThreadsPerThreadgroup
            enc.dispatchThreadgroups(
                MTLSize(width: (colorGroupSizes[phase] + tpg - 1) / tpg, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            enc.endEncoding()
        }

        // 3. Grass growth (day only)
        if isDay {
            guard let enc = cmdBuf.makeComputeCommandEncoder() else { cmdBuf.commit(); return }
            enc.setComputePipelineState(grassPipeline)
            enc.setBuffer(entityBuf, offset: 0, index: 0)
            enc.setBuffer(gaugeBuf, offset: 0, index: 1)
            enc.setBuffer(neighborsBuf, offset: 0, index: 2)
            enc.setBytes(&tick, length: 4, index: 3)
            var nc = UInt32(nodeCount)
            enc.setBytes(&nc, length: 4, index: 4)
            enc.setBuffer(scentWaterBuf, offset: 0, index: 5)
            let tpg = grassPipeline.maxTotalThreadsPerThreadgroup
            enc.dispatchThreadgroups(MTLSize(width: (nodeCount + tpg - 1) / tpg, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            enc.endEncoding()
        }

        // Record entity buffer into ring (GPU blit, zero CPU cost)
        recorder?.encodeRecord(cmdBuf: cmdBuf, from: entityBuf,
                                tick: tick, isDay: isDay)

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    public func census() -> SavannaCensus {
        memset(censusGrass.contents(), 0, 4)
        memset(censusZebra.contents(), 0, 4)
        memset(censusLion.contents(), 0, 4)
        memset(censusEnergy.contents(), 0, 4)

        guard let cmdBuf = queue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            return SavannaCensus(empty: 0, grass: 0, zebra: 0, lion: 0, totalEnergy: 0)
        }
        enc.setComputePipelineState(censusPipeline)
        enc.setBuffer(entityBuf, offset: 0, index: 0)
        enc.setBuffer(censusGrass, offset: 0, index: 1)
        enc.setBuffer(censusZebra, offset: 0, index: 2)
        enc.setBuffer(censusLion, offset: 0, index: 3)
        enc.setBuffer(censusEnergy, offset: 0, index: 4)
        enc.setBuffer(energyBuf, offset: 0, index: 5)
        var nc = UInt32(nodeCount)
        enc.setBytes(&nc, length: 4, index: 6)
        let tpg = censusPipeline.maxTotalThreadsPerThreadgroup
        enc.dispatchThreadgroups(MTLSize(width: (nodeCount + tpg - 1) / tpg, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let g = censusGrass.contents().load(as: UInt32.self)
        let z = censusZebra.contents().load(as: UInt32.self)
        let l = censusLion.contents().load(as: UInt32.self)
        let e = censusEnergy.contents().load(as: UInt32.self)
        return SavannaCensus(empty: nodeCount - Int(g) - Int(z) - Int(l),
                             grass: Int(g), zebra: Int(z), lion: Int(l), totalEnergy: Int(e))
    }
}

enum MetalError: Error {
    case noDevice
    case noQueue
}
