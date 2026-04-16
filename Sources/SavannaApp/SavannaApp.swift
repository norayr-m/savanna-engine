/// SavannaApp — Native macOS application for the Digital Serengeti.
///
/// Three windows:
///   1. Viewer — Full Metal rendering on external display (83" AirPlay)
///   2. Simulator — Start/stop, file I/O, telemetry, admin
///   3. DJ Panel — Parameter sliders for live tuning

import SwiftUI
import Savanna

@main
struct SavannaApp: App {
    @StateObject private var engine = SimulationEngine()

    var body: some Scene {
        // Window 1: Viewer — Metal rendering, fullscreen on external display
        Window("Savanna — Viewer", id: "viewer") {
            ViewerWindow(engine: engine)
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 900)

        // Window 2: Simulator — Controls, telemetry, file I/O
        Window("Savanna — Simulator", id: "simulator") {
            SimulatorWindow(engine: engine)
                .frame(minWidth: 400, minHeight: 600)
        }
        .defaultSize(width: 420, height: 700)
        .defaultPosition(.trailing)

        // Window 3: DJ Panel — Parameter sliders
        Window("Savanna — DJ", id: "dj") {
            DJWindow(engine: engine)
                .frame(minWidth: 380, minHeight: 700)
        }
        .defaultSize(width: 400, height: 800)
        .defaultPosition(.leading)
    }
}
