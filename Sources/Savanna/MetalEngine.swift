/// MetalEngine — GPU compute with three senses + scent diffusion.
///
/// Per tick: 3 scent diffusions + 4 color phases + grass growth + census.
/// 8 kernel dispatches total per tick. All in one MTLCommandBuffer.

import Metal
import Foundation

public final class MetalEngine {
    public let device: MTLDevice
    public let grid: HexGrid
    public var recorder: SimRecorder?
    let queue: MTLCommandQueue
    let tickPipeline: MTLComputePipelineState
    let grassPipeline: MTLComputePipelineState
    let censusPipeline: MTLComputePipelineState
    let scentPipeline: MTLComputePipelineState
    let genesisPipeline: MTLComputePipelineState
    let lodComposePipeline: MTLComputePipelineState
    let lodCascadePipeline: MTLComputePipelineState
    let lodRenderPipeline: MTLComputePipelineState

    // State buffers
    public let entityBuf: MTLBuffer
    public let energyBuf: MTLBuffer
    public let ternaryBuf: MTLBuffer
    public let gaugeBuf: MTLBuffer
    public let orientationBuf: MTLBuffer
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
    let mainTileN: UInt32  // Halo Protocol: cells in main tile (halo starts after this)

    public init(grid: HexGrid, state: SavannaState) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw MetalError.noDevice
        }
        self.device = device
        self.grid = grid
        self.queue = queue
        self.nodeCount = grid.nodeCount
        self.mainTileN = UInt32(grid.nodeCount)  // no halo by default; TiledSimulator overrides
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
        self.genesisPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "genesis")!)
        self.lodComposePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "reduce_lod_compose")!)
        self.lodCascadePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "reduce_lod_cascade")!)
        self.lodRenderPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "render_lod")!)

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

    /// GPU-initialize state (Gemini Optimization B: genesis.metal).
    /// Replaces CPU randomInit — runs in <10ms on GPU for 1B cells.
    public func gpuInit(seed: UInt32 = 42,
                        grassFrac: Float = 0.80,
                        zebraFrac: Float = 0.02,
                        lionFrac: Float = 0.00025,
                        waterThresh: Float = 0.92) {
        guard let cmdBuf = queue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else { return }

        enc.setComputePipelineState(genesisPipeline)
        enc.setBuffer(entityBuf, offset: 0, index: 0)
        enc.setBuffer(energyBuf, offset: 0, index: 1)
        enc.setBuffer(ternaryBuf, offset: 0, index: 2)
        enc.setBuffer(gaugeBuf, offset: 0, index: 3)
        enc.setBuffer(orientationBuf, offset: 0, index: 4)
        var w = UInt32(grid.width), h = UInt32(grid.height)
        var s = seed
        var gf = grassFrac, zf = zebraFrac, lf = lionFrac, wt = waterThresh
        enc.setBytes(&w, length: 4, index: 5)
        enc.setBytes(&h, length: 4, index: 6)
        enc.setBytes(&s, length: 4, index: 7)
        enc.setBytes(&gf, length: 4, index: 8)
        enc.setBytes(&zf, length: 4, index: 9)
        enc.setBytes(&lf, length: 4, index: 10)
        enc.setBytes(&wt, length: 4, index: 11)
        // mortonRank buffer for row-major → Morton mapping
        let mrBuf = device.makeBuffer(bytes: grid.mortonRank,
                                       length: grid.mortonRank.count * 4,
                                       options: .storageModeShared)!
        enc.setBuffer(mrBuf, offset: 0, index: 12)

        let tpg = genesisPipeline.maxTotalThreadsPerThreadgroup
        let n = grid.nodeCount
        enc.dispatchThreadgroups(
            MTLSize(width: (n + tpg - 1) / tpg, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    /// Generate RG-LOD pyramid and render to RGBA at target resolution.
    /// Cascade: entity → compose(half) → cascade(quarter) → ... → render(RGBA)
    public func generateLOD(targetWidth: Int, targetHeight: Int) -> Data? {
        let w = grid.width
        let h = grid.height
        // How many 2× reductions to reach target
        let levels = max(1, Int(log2(Double(w) / Double(targetWidth))))
        let shared = MTLResourceOptions.storageModeShared

        guard let cmdBuf = queue.makeCommandBuffer() else { return nil }

        // Level 0: entity → composition (half res)
        var curW = UInt32(w / 2), curH = UInt32(h / 2)
        var curN = Int(curW * curH)
        let comp0 = device.makeBuffer(length: curN * 16, options: shared)!  // float4 = 16 bytes
        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(lodComposePipeline)
            enc.setBuffer(entityBuf, offset: 0, index: 0)
            enc.setBuffer(comp0, offset: 0, index: 1)
            var srcW = UInt32(w), srcH = UInt32(h)
            enc.setBytes(&srcW, length: 4, index: 2)
            enc.setBytes(&srcH, length: 4, index: 3)
            let tpg = lodComposePipeline.maxTotalThreadsPerThreadgroup
            enc.dispatchThreadgroups(
                MTLSize(width: (curN + tpg - 1) / tpg, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            enc.endEncoding()
        }

        // Cascade reductions
        var prevBuf = comp0
        for _ in 1..<levels {
            let nextW = curW / 2, nextH = curH / 2
            let nextN = Int(nextW * nextH)
            if nextN <= 0 { break }
            let nextBuf = device.makeBuffer(length: nextN * 16, options: shared)!
            if let enc = cmdBuf.makeComputeCommandEncoder() {
                enc.setComputePipelineState(lodCascadePipeline)
                enc.setBuffer(prevBuf, offset: 0, index: 0)
                enc.setBuffer(nextBuf, offset: 0, index: 1)
                enc.setBytes(&curW, length: 4, index: 2)
                enc.setBytes(&curH, length: 4, index: 3)
                let tpg = lodCascadePipeline.maxTotalThreadsPerThreadgroup
                enc.dispatchThreadgroups(
                    MTLSize(width: (nextN + tpg - 1) / tpg, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
                enc.endEncoding()
            }
            curW = nextW; curH = nextH; curN = nextN
            prevBuf = nextBuf
        }

        // Render composition to RGBA
        let pixelBuf = device.makeBuffer(length: curN * 4, options: shared)!  // RGBA
        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(lodRenderPipeline)
            enc.setBuffer(prevBuf, offset: 0, index: 0)
            enc.setBuffer(pixelBuf, offset: 0, index: 1)
            var pc = UInt32(curN)
            enc.setBytes(&pc, length: 4, index: 2)
            let tpg = lodRenderPipeline.maxTotalThreadsPerThreadgroup
            enc.dispatchThreadgroups(
                MTLSize(width: (curN + tpg - 1) / tpg, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
            enc.endEncoding()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Read RGBA pixels
        let ptr = pixelBuf.contents().bindMemory(to: UInt8.self, capacity: curN * 4)
        return Data(bytes: ptr, count: curN * 4)
    }

    /// Dispatch a scent diffusion pass.
    /// Serengeti wind direction from tick number (real seasonal meteorology)
    /// NE monsoon (Nov-Mar, dirs 0), SE trades (May-Oct, dir 5)
    static func serengetiWind(tick: UInt32) -> UInt32 {
        let yearTick = tick % 1460  // 1460 ticks = 1 year
        let month = yearTick / 122  // ~122 ticks per month
        // Jan-Mar: NE(0), Apr: transition(1), May-Oct: SE(5), Nov-Dec: NE(0)
        switch month {
        case 0...2: return 0   // Jan-Mar: NE monsoon
        case 3:     return 1   // Apr: transition N
        case 4...9: return 5   // May-Oct: SE trades
        case 10:    return 0   // Nov: NE returns
        default:    return 0   // Dec: NE monsoon
        }
    }

    /// Wind strength (0 = isotropic, 1 = fully directional). Set by DJ panel.
    public var windStrength: Float = 0.6

    private func encodeScent(cmdBuf: MTLCommandBuffer, scent: MTLBuffer, prev: MTLBuffer,
                             sourceType: Int8, emitStr: Float, windDir: UInt32) {
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
        var wd = windDir
        enc.setBytes(&wd, length: 4, index: 7)  // wind direction
        var ws = windStrength
        enc.setBytes(&ws, length: 4, index: 8)  // wind strength

        let tpg = scentPipeline.maxTotalThreadsPerThreadgroup
        enc.dispatchThreadgroups(MTLSize(width: (nodeCount + tpg - 1) / tpg, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        enc.endEncoding()
    }

    /// Wind override: nil = use seasonal Serengeti wind, non-nil = fixed direction (0-5)
    public var windOverride: UInt32? = nil
    /// Wind enabled: false = direction 6 (no wind bias in scent kernel)
    public var windActive: Bool = true
    private var lastWindActive: Bool = true

    /// Clear all scent fields (call when wind changes to reset accumulated bias)
    public func resetScent() {
        let n = nodeCount * 4
        memset(scentZebraBuf.contents(), 0, n)
        memset(scentZebraPrevBuf.contents(), 0, n)
        memset(scentGrassBuf.contents(), 0, n)
        memset(scentGrassPrevBuf.contents(), 0, n)
        memset(scentLionBuf.contents(), 0, n)
        memset(scentLionPrevBuf.contents(), 0, n)
        memset(scentWaterBuf.contents(), 0, n)
        memset(scentWaterPrevBuf.contents(), 0, n)
    }

    public func tick(tickNumber: UInt32, isDay: Bool) {
        guard let cmdBuf = queue.makeCommandBuffer() else { return }

        // 1. Scent diffusion with wind
        // Reset scent when wind toggles to clear accumulated bias
        if windActive != lastWindActive {
            resetScent()
            lastWindActive = windActive
        }
        let wind: UInt32
        if !windActive {
            wind = 6  // 6 = no wind (scent kernel treats dir >= 6 as uniform diffusion)
        } else if let override = windOverride {
            wind = override
        } else {
            wind = MetalEngine.serengetiWind(tick: tickNumber)
        }
        encodeScent(cmdBuf: cmdBuf, scent: scentZebraBuf, prev: scentZebraPrevBuf,
                    sourceType: 2, emitStr: 1.0, windDir: wind)
        encodeScent(cmdBuf: cmdBuf, scent: scentGrassBuf, prev: scentGrassPrevBuf,
                    sourceType: 1, emitStr: 0.5, windDir: wind)
        encodeScent(cmdBuf: cmdBuf, scent: scentLionBuf, prev: scentLionPrevBuf,
                    sourceType: 3, emitStr: 0.8, windDir: wind)
        encodeScent(cmdBuf: cmdBuf, scent: scentWaterBuf, prev: scentWaterPrevBuf,
                    sourceType: 4, emitStr: 15.0, windDir: wind)

        var tick = tickNumber
        var day: UInt32 = isDay ? 1 : 0

        // 2. Seven color-group tick phases — SHUFFLED every tick
        // Without shuffling, Color 0→1 steps process twice per tick,
        // Color 6→0 steps wait. Creates phantom "chromatic advection" —
        // information flows faster along the color gradient.
        // Fix by Gemini Deep Think, 2026-04-15
        var colorOrder = Array(0..<HexGrid.colorCount)
        // Fisher-Yates shuffle using tick as seed
        var shuffleSeed = tickNumber &* 2654435761
        for i in stride(from: colorOrder.count - 1, through: 1, by: -1) {
            shuffleSeed = shuffleSeed &* 1103515245 &+ 12345
            let j = Int(shuffleSeed >> 16) % (i + 1)
            colorOrder.swapAt(i, j)
        }
        for phase in colorOrder {
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
            var mtn = mainTileN
            enc.setBytes(&mtn, length: 4, index: 14)  // Halo Protocol

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
