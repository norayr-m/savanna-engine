/// SimulatorWindow — Admin panel: start/stop, grid setup, telemetry, scenarios, recording.

import SwiftUI
import Savanna

struct SimulatorWindow: View {
    @ObservedObject var engine: SimulationEngine
    @State private var cellsText = "1M"
    @State private var showScenarios = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("SIMULATOR")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.77, green: 0.64, blue: 0.35))
                    Spacer()
                    Circle()
                        .fill(engine.isRunning ? Color.green : Color.red.opacity(0.5))
                        .frame(width: 10, height: 10)
                    Text(engine.isRunning ? "RUNNING" : "STOPPED")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(engine.isRunning ? .green : .gray)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider().background(Color.gray.opacity(0.3))

                // Grid Setup
                sectionHeader("GRID")
                HStack {
                    TextField("Cells", text: $cellsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .font(.system(.body, design: .monospaced))
                    Button("Setup") {
                        let cells = parseCells(cellsText)
                        engine.setup(cells: cells)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.77, green: 0.64, blue: 0.35))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                Text("\(engine.gridSize)×\(engine.gridSize) = \(engine.cellCount.formatted()) cells")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 20)

                // Controls
                sectionHeader("CONTROLS")
                HStack(spacing: 12) {
                    Button(engine.isRunning ? "Stop" : "Start") {
                        if engine.isRunning { engine.stop() } else { engine.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.isRunning ? .red : .green)

                    Button("Reset") { engine.reset() }
                        .buttonStyle(.bordered)

                    Button("Scenarios") { showScenarios.toggle() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                // Telemetry
                sectionHeader("TELEMETRY")
                telemetryGrid

                // Population
                sectionHeader("POPULATION")
                populationBars

                // Scenarios
                if showScenarios {
                    sectionHeader("SCENARIOS")
                    scenarioList
                }

                Spacer()
            }
        }
        .background(Color(red: 0.08, green: 0.07, blue: 0.05))
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(Color(red: 0.50, green: 0.42, blue: 0.28))
            .tracking(2)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    var telemetryGrid: some View {
        VStack(spacing: 4) {
            telemetryRow("Tick", "\(engine.tick)")
            telemetryRow("Day", "\(engine.simDay)")
            telemetryRow("Year", String(format: "%.1f", engine.simYear))
            telemetryRow("TPS", "\(Int(engine.tps))")
            telemetryRow("ms/tick", String(format: "%.2f", engine.msPerTick))
            telemetryRow("GCUPS", String(format: "%.1f", engine.gcups))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    func telemetryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(red: 0.77, green: 0.64, blue: 0.35))
        }
    }

    var populationBars: some View {
        VStack(spacing: 6) {
            popBar("Grass", engine.grass, engine.cellCount, Color(red: 0.42, green: 0.60, blue: 0.23))
            popBar("Zebra", engine.zebra, engine.cellCount, Color(red: 0.82, green: 0.80, blue: 0.77))
            popBar("Lion", engine.lion, engine.cellCount, Color(red: 0.75, green: 0.25, blue: 0.19))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    func popBar(_ name: String, _ count: Int, _ total: Int, _ color: Color) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 50, alignment: .trailing)
            GeometryReader { geo in
                let pct = total > 0 ? CGFloat(count) / CGFloat(total) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.05))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(2, geo.size.width * min(pct, 1)))
                }
            }
            .frame(height: 16)
            Text("\(count.formatted())")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 80, alignment: .trailing)
        }
    }

    var scenarioList: some View {
        VStack(spacing: 8) {
            ForEach(engine.scenarios) { s in
                Button(action: { engine.loadScenario(s) }) {
                    HStack {
                        Text(s.emoji)
                            .font(.system(size: 20))
                        VStack(alignment: .leading) {
                            Text(s.name)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(red: 0.77, green: 0.64, blue: 0.35))
                            Text(s.description)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    func parseCells(_ s: String) -> Int {
        let upper = s.uppercased().trimmingCharacters(in: .whitespaces)
        var num = upper
        var multiplier = 1
        if num.hasSuffix("T") { num = String(num.dropLast()); multiplier = 1_000_000_000_000 }
        else if num.hasSuffix("B") { num = String(num.dropLast()); multiplier = 1_000_000_000 }
        else if num.hasSuffix("M") { num = String(num.dropLast()); multiplier = 1_000_000 }
        else if num.hasSuffix("K") { num = String(num.dropLast()); multiplier = 1_000 }
        if let n = Double(num) { return Int(n * Double(multiplier)) }
        return 1_000_000
    }
}
