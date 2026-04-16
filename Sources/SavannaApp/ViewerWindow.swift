/// ViewerWindow — Full Metal rendering of the savanna.
/// Goes on the 83" AirPlay display. Pure visual. No controls.
/// Entity buffer → GPU fragment shader palette lookup. Zero CPU in render path.

import SwiftUI
import Metal
import MetalKit
import Savanna

struct ViewerWindow: View {
    @ObservedObject var engine: SimulationEngine

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.05, blue: 0.02)
                .ignoresSafeArea()

            if engine.metalEngine != nil {
                MetalView(engine: engine)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Text("SAVANNA")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.77, green: 0.64, blue: 0.35))
                    Text("No simulation running")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundColor(Color(red: 0.35, green: 0.29, blue: 0.16))
                    Text("Open Simulator window → Set grid size → Start")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Color(red: 0.25, green: 0.20, blue: 0.12))
                }
            }

            // HUD overlay
            VStack {
                HStack {
                    HStack(spacing: 16) {
                        Text("SAVANNA")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.77, green: 0.64, blue: 0.35))
                        Group {
                            Label("\(engine.grass)", systemImage: "leaf.fill")
                                .foregroundColor(Color(red: 0.42, green: 0.60, blue: 0.23))
                            Label("\(engine.zebra)", systemImage: "hare.fill")
                                .foregroundColor(Color(red: 0.91, green: 0.89, blue: 0.86))
                            Label("\(engine.lion)", systemImage: "pawprint.fill")
                                .foregroundColor(Color(red: 0.75, green: 0.25, blue: 0.19))
                        }
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Text("d\(engine.simDay)")
                        Text("y\(String(format: "%.1f", engine.simYear))")
                        Text("\(Int(engine.tps)) tps")
                        Text(String(format: "%.1f GCUPS", engine.gcups))
                        Text("v\(SimulationEngine.version)")
                            .foregroundColor(Color(red: 0.30, green: 0.25, blue: 0.15))
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color(red: 0.50, green: 0.42, blue: 0.28))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.6))

                Spacer()

                // Placement mode indicator
                if engine.placementMode != .none {
                    HStack {
                        Spacer()
                        Text(engine.placementMode == .zebra ? "🦓 CLICK TO PLACE ZEBRAS" : "🦁 CLICK TO PLACE LIONS")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(engine.placementMode == .zebra ? .white : Color(red: 0.85, green: 0.45, blue: 0.20))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                        Spacer()
                    }
                    .padding(.bottom, 40)
                }
            }
        }
    }
}

/// MetalView — MTKView wrapped for SwiftUI. Direct GPU rendering.
struct MetalView: NSViewRepresentable {
    @ObservedObject var engine: SimulationEngine

    func makeNSView(context: Context) -> MTKView {
        let view = ClickableMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.06, green: 0.05, blue: 0.02, alpha: 1)
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.engine = engine
    }

    func makeCoordinator() -> MetalViewCoordinator {
        MetalViewCoordinator(engine: engine)
    }
}

class MetalViewCoordinator: NSObject, MTKViewDelegate {
    var engine: SimulationEngine
    var pipelineState: MTLRenderPipelineState?
    var vertexBuffer: MTLBuffer?
    var commandQueue: MTLCommandQueue?

    init(engine: SimulationEngine) {
        self.engine = engine
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let metalEngine = engine.metalEngine,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let device = view.device else { return }

        // Lazy init
        if commandQueue == nil { commandQueue = device.makeCommandQueue() }
        if pipelineState == nil { setupPipeline(device: device) }

        guard let ps = pipelineState,
              let vb = vertexBuffer,
              let queue = commandQueue,
              let commandBuffer = queue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        renderEncoder.setRenderPipelineState(ps)
        renderEncoder.setVertexBuffer(vb, offset: 0, index: 0)

        // Pass entity buffer directly to fragment shader — NO CPU readback
        renderEncoder.setFragmentBuffer(metalEngine.entityBuf, offset: 0, index: 0)

        // Pass grid dimensions as uniforms
        var gridW = UInt32(engine.gridSize)
        var gridH = UInt32(engine.gridSize)
        renderEncoder.setFragmentBytes(&gridW, length: 4, index: 1)
        renderEncoder.setFragmentBytes(&gridH, length: 4, index: 2)

        // Pass mortonRank for GPU-side row-major → Morton rank lookup
        if let mrBuf = engine.mortonRankBuf {
            renderEncoder.setFragmentBuffer(mrBuf, offset: 0, index: 3)
        }

        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func setupPipeline(device: MTLDevice) {
        // Fragment shader reads entity buffer directly, does palette lookup on GPU
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;

        struct V2F {
            float4 pos [[position]];
            float2 uv;
        };

        vertex V2F vs(uint vid [[vertex_id]], constant float4 *verts [[buffer(0)]]) {
            V2F o;
            o.pos = float4(verts[vid].xy, 0, 1);
            o.uv = verts[vid].zw;
            return o;
        }

        // Palette: entity code → RGB color
        constant float3 palette[] = {
            float3(0.102, 0.078, 0.031),  // 0: empty (dark brown)
            float3(0.227, 0.290, 0.094),  // 1: grass (green)
            float3(0.910, 0.894, 0.863),  // 2: zebra (white)
            float3(0.706, 0.157, 0.118),  // 3: lion (red)
            float3(0.157, 0.353, 0.627),  // 4: water (blue)
        };

        fragment float4 fs(
            V2F in [[stage_in]],
            device const int8_t* entities [[buffer(0)]],
            constant uint32_t& gridW [[buffer(1)]],
            constant uint32_t& gridH [[buffer(2)]],
            device const int32_t* mortonRank [[buffer(3)]]
        ) {
            // Pixel position in grid
            uint col = uint(in.uv.x * float(gridW));
            uint row = uint(in.uv.y * float(gridH));
            if (col >= gridW || row >= gridH) return float4(0.06, 0.05, 0.02, 1);

            // Row-major → Morton rank → entity value
            // mortonRank[rowMajor] gives the Morton buffer index
            uint rowMajor = row * gridW + col;
            uint mRank = uint(mortonRank[rowMajor]);
            int8_t e = entities[mRank];

            uint code = uint(e) & 0x7;
            float3 col3 = code < 5 ? palette[code] : palette[0];
            return float4(col3, 1.0);
        }
        """
        let library = try? device.makeLibrary(source: shaderSrc, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library?.makeFunction(name: "vs")
        desc.fragmentFunction = library?.makeFunction(name: "fs")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try? device.makeRenderPipelineState(descriptor: desc)

        // Fullscreen quad: pos(xy) + uv(zw)
        let verts: [Float] = [
            -1, -1, 0, 1,   1, -1, 1, 1,  -1, 1, 0, 0,
             1, -1, 1, 1,   1,  1, 1, 0,  -1, 1, 0, 0,
        ]
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared)
    }
}

/// MTKView that handles clicks for animal placement
/// Left click = 100 zebras (tight cloud). Alt+click = 10 lions (diffuse cloud).
class ClickableMTKView: MTKView {
    weak var coordinator: MetalViewCoordinator?

    override func mouseDown(with event: NSEvent) {
        handleClick(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleClick(event)
    }

    private func handleClick(_ event: NSEvent) {
        guard let coord = coordinator else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let gridW = coord.engine.gridSize
        let gridH = coord.engine.gridSize
        let col = Int(loc.x / bounds.width * CGFloat(gridW))
        let row = Int((1.0 - loc.y / bounds.height) * CGFloat(gridH))

        if col >= 0 && col < gridW && row >= 0 && row < gridH {
            let isAlt = event.modifierFlags.contains(.option)
            Task { @MainActor in
                coord.engine.placeCluster(col: col, row: row, isLion: isAlt)
            }
        }
    }
}
