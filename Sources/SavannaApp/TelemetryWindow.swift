/// TelemetryWindow — Population graphs as a standalone window.
/// Can float alongside the Viewer or go on a separate display.

import SwiftUI
import Savanna

struct TelemetryWindow: View {
    @ObservedObject var engine: SimulationEngine

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("TELEMETRY")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.77, green: 0.64, blue: 0.35))
                Spacer()
                Text("d\(engine.simDay) y\(String(format: "%.1f", engine.simYear))")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color(red: 0.50, green: 0.42, blue: 0.28))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Main graph
            Canvas { context, size in
                let history = engine.populationHistory
                guard history.count > 1 else { return }

                let w = size.width
                let h = size.height

                // Grid lines
                for i in 1..<4 {
                    let y = h * CGFloat(i) / 4
                    var gridLine = Path()
                    gridLine.move(to: CGPoint(x: 0, y: y))
                    gridLine.addLine(to: CGPoint(x: w, y: y))
                    context.stroke(gridLine, with: .color(Color.white.opacity(0.06)), lineWidth: 0.5)
                }

                // Find max for scaling (log scale option)
                let maxZebra = max(1, history.map(\.zebra).max() ?? 1)
                let maxLion = max(1, history.map(\.lion).max() ?? 1)
                let maxVal = max(maxZebra, maxLion)

                // Grass fill (subtle green area)
                let maxGrass = max(1, history.map(\.grass).max() ?? 1)
                var grassPath = Path()
                grassPath.move(to: CGPoint(x: 0, y: h))
                for (i, snap) in history.enumerated() {
                    let x = CGFloat(i) / CGFloat(history.count - 1) * w
                    let y = (1.0 - CGFloat(snap.grass) / CGFloat(maxGrass)) * h
                    grassPath.addLine(to: CGPoint(x: x, y: y))
                }
                grassPath.addLine(to: CGPoint(x: w, y: h))
                grassPath.closeSubpath()
                context.fill(grassPath, with: .color(Color(red: 0.15, green: 0.20, blue: 0.08).opacity(0.3)))

                // Zebra line
                var zebraPath = Path()
                for (i, snap) in history.enumerated() {
                    let x = CGFloat(i) / CGFloat(history.count - 1) * w
                    let y = (1.0 - CGFloat(snap.zebra) / CGFloat(maxVal)) * h
                    if i == 0 { zebraPath.move(to: CGPoint(x: x, y: y)) }
                    else { zebraPath.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(zebraPath, with: .color(Color(red: 0.85, green: 0.83, blue: 0.80)), lineWidth: 2)

                // Lion line
                var lionPath = Path()
                for (i, snap) in history.enumerated() {
                    let x = CGFloat(i) / CGFloat(history.count - 1) * w
                    let y = (1.0 - CGFloat(snap.lion) / CGFloat(maxVal)) * h
                    if i == 0 { lionPath.move(to: CGPoint(x: x, y: y)) }
                    else { lionPath.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(lionPath, with: .color(Color(red: 0.75, green: 0.25, blue: 0.19)), lineWidth: 2)

                // Labels
                let zebraLabel = "Zebra: \(history.last?.zebra ?? 0)"
                let lionLabel = "Lion: \(history.last?.lion ?? 0)"
                context.draw(Text(zebraLabel).font(.system(size: 11, design: .monospaced)).foregroundColor(Color(red: 0.85, green: 0.83, blue: 0.80)),
                             at: CGPoint(x: w - 60, y: 14))
                context.draw(Text(lionLabel).font(.system(size: 11, design: .monospaced)).foregroundColor(Color(red: 0.75, green: 0.25, blue: 0.19)),
                             at: CGPoint(x: w - 60, y: 28))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Stats bar
            HStack(spacing: 20) {
                statPill("🦓", "\(engine.zebra)", Color(red: 0.85, green: 0.83, blue: 0.80))
                statPill("🦁", "\(engine.lion)", Color(red: 0.75, green: 0.25, blue: 0.19))
                statPill("🌿", "\(engine.grass)", Color(red: 0.42, green: 0.60, blue: 0.23))
                Spacer()
                Text("\(Int(engine.tps)) tps")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0.50, green: 0.42, blue: 0.28))
                Text(String(format: "%.1f GCUPS", engine.gcups))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0.50, green: 0.42, blue: 0.28))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(red: 0.06, green: 0.05, blue: 0.02))
    }

    func statPill(_ emoji: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(emoji).font(.system(size: 14))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
    }
}
