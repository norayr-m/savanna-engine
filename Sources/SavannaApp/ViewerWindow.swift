/// ViewerWindow — Full Metal rendering with zoom, pan, keyboard shortcuts, graph overlay.
/// Entity buffer → GPU fragment shader palette lookup. Zero CPU in render path.
///
/// Shortcuts:
///   Scroll/pinch: zoom    Drag: pan    Space: fit to window
///   T: time speed cycle   G: toggle graph overlay    S: toggle stats
///   N: nuke/reset         P: toggle scenarios (DJ panel)
///   Click: place zebras   Alt+click: place lions

import SwiftUI
import Metal
import MetalKit
import Savanna

struct ViewerWindow: View {
    @ObservedObject var engine: SimulationEngine
    @State private var showGraph = true
    @State private var showStats = true

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
                    Text("Open Simulator → Setup → Start")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(Color(red: 0.25, green: 0.20, blue: 0.12))
                }
            }

            // HUD overlay
            VStack(spacing: 0) {
                // Top bar
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
                    if showStats {
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
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.6))

                Spacer()

                // Graph overlay (bottom)
                if showGraph && engine.isRunning {
                    PopulationGraph(engine: engine)
                        .frame(height: 120)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                }

                // Bottom shortcut bar
                HStack(spacing: 16) {
                    shortcutLabel("scroll", "zoom")
                    shortcutLabel("drag", "pan")
                    shortcutLabel("space", "fit")
                    shortcutLabel("T", "speed")
                    shortcutLabel("G", "graph")
                    shortcutLabel("S", "stats")
                    shortcutLabel("N", "reset")
                    shortcutLabel("click", "zebra")
                    shortcutLabel("⌥click", "lion")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(red: 0.35, green: 0.29, blue: 0.16))
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.4))
            }

            // Placement indicator
            if engine.placementMode != .none {
                VStack {
                    Spacer()
                    Text(engine.placementMode == .zebra ? "🦓 PLACING ZEBRAS" : "🦁 PLACING LIONS")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(engine.placementMode == .zebra ? .white : Color(red: 0.85, green: 0.45, blue: 0.20))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                        .padding(.bottom, 50)
                }
            }

            // Neon cell counter — bottom center
            if engine.isRunning {
                VStack {
                    Spacer()
                    VStack(spacing: 2) {
                        Text("CELLS")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(neonColor(engine.cellCount).opacity(0.6))
                        Text(engine.cellCount.formatted())
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .foregroundColor(neonColor(engine.cellCount))
                            .shadow(color: neonColor(engine.cellCount).opacity(0.5), radius: 10)
                            .shadow(color: neonColor(engine.cellCount).opacity(0.3), radius: 30)
                    }
                    .padding(.bottom, showGraph ? 140 : 50)
                }
            }

            // Time speed indicator
            if engine.showSpeedIndicator {
                Text(engine.speedLabel)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.77, green: 0.64, blue: 0.35))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                    .transition(.opacity)
            }
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKey(event)
                return event
            }
        }
    }

    func handleKey(_ event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ":
            engine.zoom = 1.0; engine.panX = 0; engine.panY = 0
        case "t", "T":
            engine.cycleSpeed()
        case "g", "G":
            withAnimation { showGraph.toggle() }
        case "s", "S":
            withAnimation { showStats.toggle() }
        case "n", "N":
            engine.reset(); engine.start()
        default: break
        }
    }

    /// Neon color by cell count magnitude — silver→gold→orange→red→pink→purple
    func neonColor(_ count: Int) -> Color {
        let mag = log10(Double(max(1, count)))
        if mag < 4 { return Color(red: 0.75, green: 0.75, blue: 0.75) }       // <10K: silver
        if mag < 5 { return Color(red: 0.77, green: 0.64, blue: 0.35) }       // 10K-100K: gold
        if mag < 6 { return Color(red: 0.83, green: 0.52, blue: 0.23) }       // 100K-1M: orange
        if mag < 7 { return Color(red: 0.88, green: 0.24, blue: 0.19) }       // 1M-10M: red
        if mag < 8 { return Color(red: 0.88, green: 0.19, blue: 0.38) }       // 10M-100M: hot pink
        if mag < 9 { return Color(red: 0.88, green: 0.13, blue: 0.63) }       // 100M-1B: magenta
        if mag < 10 { return Color(red: 1.00, green: 0.00, blue: 1.00) }      // 1B-10B: neon
        return Color(red: 0.67, green: 0.00, blue: 1.00) }                    // 10B+: purple

    func shortcutLabel(_ key: String, _ action: String) -> some View {
        HStack(spacing: 3) {
            Text(key).foregroundColor(Color(red: 0.77, green: 0.64, blue: 0.35))
            Text(action)
        }
    }
}

// MARK: - Population Graph Overlay

struct PopulationGraph: View {
    @ObservedObject var engine: SimulationEngine

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let history = engine.populationHistory
            guard history.count > 1 else { return }

            // Background
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color.black.opacity(0.6))
            )

            let maxPop = max(1, history.map { max($0.zebra, $0.lion) }.max() ?? 1)

            // Zebra line (white)
            var zebraPath = Path()
            for (i, h) in history.enumerated() {
                let x = CGFloat(i) / CGFloat(history.count - 1) * w
                let y = (1.0 - CGFloat(h.zebra) / CGFloat(maxPop)) * size.height
                if i == 0 { zebraPath.move(to: CGPoint(x: x, y: y)) }
                else { zebraPath.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(zebraPath, with: .color(Color(red: 0.85, green: 0.83, blue: 0.80)), lineWidth: 1.5)

            // Lion line (red)
            var lionPath = Path()
            for (i, h) in history.enumerated() {
                let x = CGFloat(i) / CGFloat(history.count - 1) * w
                let y = (1.0 - CGFloat(h.lion) / CGFloat(maxPop)) * size.height
                if i == 0 { lionPath.move(to: CGPoint(x: x, y: y)) }
                else { lionPath.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(lionPath, with: .color(Color(red: 0.75, green: 0.25, blue: 0.19)), lineWidth: 1.5)
        }
        .cornerRadius(8)
        .opacity(0.85)
    }
}

// MARK: - Metal View with Zoom/Pan

struct MetalView: NSViewRepresentable {
    @ObservedObject var engine: SimulationEngine

    func makeNSView(context: Context) -> ClickableMTKView {
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

    func updateNSView(_ nsView: ClickableMTKView, context: Context) {
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

        if commandQueue == nil { commandQueue = device.makeCommandQueue() }
        if pipelineState == nil { setupPipeline(device: device) }

        guard let ps = pipelineState,
              let vb = vertexBuffer,
              let queue = commandQueue,
              let commandBuffer = queue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        renderEncoder.setRenderPipelineState(ps)
        renderEncoder.setVertexBuffer(vb, offset: 0, index: 0)

        // Entity buffer — direct GPU read
        renderEncoder.setFragmentBuffer(metalEngine.entityBuf, offset: 0, index: 0)

        // Grid dimensions
        var gridW = UInt32(engine.gridSize)
        var gridH = UInt32(engine.gridSize)
        renderEncoder.setFragmentBytes(&gridW, length: 4, index: 1)
        renderEncoder.setFragmentBytes(&gridH, length: 4, index: 2)

        // Morton mapping
        if let mrBuf = engine.mortonRankBuf {
            renderEncoder.setFragmentBuffer(mrBuf, offset: 0, index: 3)
        }

        // Zoom/Pan uniforms
        var zoom = Float(engine.zoom)
        var panX = Float(engine.panX)
        var panY = Float(engine.panY)
        renderEncoder.setFragmentBytes(&zoom, length: 4, index: 4)
        renderEncoder.setFragmentBytes(&panX, length: 4, index: 5)
        renderEncoder.setFragmentBytes(&panY, length: 4, index: 6)

        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func setupPipeline(device: MTLDevice) {
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

        constant float3 palette[] = {
            float3(0.102, 0.078, 0.031),  // empty
            float3(0.227, 0.290, 0.094),  // grass
            float3(0.910, 0.894, 0.863),  // zebra
            float3(0.706, 0.157, 0.118),  // lion
            float3(0.157, 0.353, 0.627),  // water
        };

        fragment float4 fs(
            V2F in [[stage_in]],
            device const int8_t* entities [[buffer(0)]],
            constant uint32_t& gridW [[buffer(1)]],
            constant uint32_t& gridH [[buffer(2)]],
            device const int32_t* mortonRank [[buffer(3)]],
            constant float& zoom [[buffer(4)]],
            constant float& panX [[buffer(5)]],
            constant float& panY [[buffer(6)]]
        ) {
            // Apply zoom and pan: UV → grid coordinates
            float2 uv = in.uv;
            uv = (uv - 0.5) / zoom + 0.5;  // zoom around center
            uv.x -= panX / zoom;
            uv.y -= panY / zoom;

            // Out of bounds → background
            if (uv.x < 0 || uv.x >= 1 || uv.y < 0 || uv.y >= 1)
                return float4(0.06, 0.05, 0.02, 1);

            uint col = uint(uv.x * float(gridW));
            uint row = uint(uv.y * float(gridH));
            if (col >= gridW || row >= gridH) return float4(0.06, 0.05, 0.02, 1);

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

        let verts: [Float] = [
            -1, -1, 0, 1,   1, -1, 1, 1,  -1, 1, 0, 0,
             1, -1, 1, 1,   1,  1, 1, 0,  -1, 1, 0, 0,
        ]
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared)
    }
}

// MARK: - Clickable MTKView with zoom/pan/place

class ClickableMTKView: MTKView {
    weak var coordinator: MetalViewCoordinator?
    var placeTimer: Timer?
    var lastClickEvent: NSEvent?

    override func scrollWheel(with event: NSEvent) {
        guard let engine = coordinator?.engine else { return }
        Task { @MainActor in
            let isTrackpad = event.phase != [] || event.momentumPhase != []
            let shift = event.modifierFlags.contains(.shift)

            if isTrackpad && shift {
                // Shift + two finger = pan
                engine.panX += Float(event.scrollingDeltaX) * 0.003 / Float(engine.zoom)
                engine.panY += Float(event.scrollingDeltaY) * 0.003 / Float(engine.zoom)
            } else {
                // Normal scroll = zoom
                let zf = 1.0 + event.scrollingDeltaY * 0.01
                engine.zoom = max(0.1, min(50.0, engine.zoom * Double(zf)))
            }
        }
    }

    override func magnify(with event: NSEvent) {
        guard let engine = coordinator?.engine else { return }
        Task { @MainActor in
            engine.zoom = max(0.1, min(50.0, engine.zoom * (1.0 + Double(event.magnification))))
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastClickEvent = event
        doPlace(event)
        // Start repeat timer — inject every 0.3s while held
        placeTimer?.invalidate()
        placeTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            if let e = self?.lastClickEvent { self?.doPlace(e) }
        }
    }
    override func mouseUp(with event: NSEvent) {
        placeTimer?.invalidate()
        placeTimer = nil
    }
    override func mouseDragged(with event: NSEvent) {
        lastClickEvent = event
        if event.modifierFlags.contains(.command) {
            guard let engine = coordinator?.engine else { return }
            Task { @MainActor in
                engine.panX += Float(event.deltaX) * 0.002
                engine.panY -= Float(event.deltaY) * 0.002
            }
        } else {
            doPlace(event)
        }
    }

    private func doPlace(_ event: NSEvent) {
        guard let coord = coordinator else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let engine = coord.engine

        // Convert screen → UV → grid with zoom/pan
        var uvX = Float(loc.x / bounds.width)
        var uvY = Float(1.0 - loc.y / bounds.height)
        uvX = (uvX - 0.5) / Float(engine.zoom) + 0.5 - engine.panX / Float(engine.zoom)
        uvY = (uvY - 0.5) / Float(engine.zoom) + 0.5 - engine.panY / Float(engine.zoom)

        let col = Int(uvX * Float(engine.gridSize))
        let row = Int(uvY * Float(engine.gridSize))

        if col >= 0 && col < engine.gridSize && row >= 0 && row < engine.gridSize {
            let isAlt = event.modifierFlags.contains(.option)
            Task { @MainActor in
                coord.engine.placeCluster(col: col, row: row, isLion: isAlt)
            }
        }
    }
}
