/// DJWindow — Interactive ecosystem tuning panel.
/// Animal cards that expand when touched. Game-like. Child-friendly.
/// A child sees animals. A biologist sees parameters. Same interface.

import SwiftUI
import Savanna

struct DJWindow: View {
    @ObservedObject var engine: SimulationEngine
    @State private var expandedCard: String? = nil

    let bg = Color(red: 0.06, green: 0.05, blue: 0.03)
    let gold = Color(red: 0.77, green: 0.64, blue: 0.35)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Title bar — minimal
                HStack {
                    Text("🌍")
                        .font(.system(size: 28))
                    Text("ECOSYSTEM")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(gold)
                        .tracking(3)
                    Spacer()
                    if engine.isRunning {
                        Text("LIVE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Animal Cards
                AnimalCard(
                    emoji: "🦓",
                    name: "ZEBRA",
                    count: engine.zebra,
                    color: Color(red: 0.85, green: 0.83, blue: 0.80),
                    isExpanded: expandedCard == "zebra",
                    onTap: { withAnimation(.spring(response: 0.3)) { expandedCard = expandedCard == "zebra" ? nil : "zebra" } }
                ) {
                    ParamSlider(label: "Population", value: $engine.zebraFrac, range: 0...0.5, format: "%.1f%%", multiplier: 100, color: .white)
                    InfoRow(label: "Count", value: "\(engine.zebra.formatted())")
                    InfoRow(label: "Ratio to Lions", value: engine.lion > 0 ? "\(engine.zebra / max(1, engine.lion)):1" : "No lions")
                }

                AnimalCard(
                    emoji: "🦁",
                    name: "LION",
                    count: engine.lion,
                    color: Color(red: 0.85, green: 0.45, blue: 0.20),
                    isExpanded: expandedCard == "lion",
                    onTap: { withAnimation(.spring(response: 0.3)) { expandedCard = expandedCard == "lion" ? nil : "lion" } }
                ) {
                    ParamSlider(label: "Population", value: $engine.lionFrac, range: 0...0.05, format: "%.2f%%", multiplier: 100, color: Color(red: 0.85, green: 0.45, blue: 0.20))
                    InfoRow(label: "Prides", value: "\(engine.lion.formatted())")
                    InfoRow(label: "Each pride", value: "4 lionesses + cubs")
                }

                AnimalCard(
                    emoji: "🌿",
                    name: "GRASS",
                    count: engine.grass,
                    color: Color(red: 0.42, green: 0.65, blue: 0.23),
                    isExpanded: expandedCard == "grass",
                    onTap: { withAnimation(.spring(response: 0.3)) { expandedCard = expandedCard == "grass" ? nil : "grass" } }
                ) {
                    ParamSlider(label: "Coverage", value: $engine.grassFrac, range: 0.3...1.0, format: "%.0f%%", multiplier: 100, color: Color(red: 0.42, green: 0.65, blue: 0.23))
                    InfoRow(label: "Cells", value: "\(engine.grass.formatted())")
                    InfoRow(label: "Coverage", value: String(format: "%.1f%%", engine.cellCount > 0 ? Double(engine.grass) / Double(engine.cellCount) * 100 : 0))
                }

                // Wind Card — draggable compass
                WindCard(
                    direction: $engine.windDirection,
                    strength: $engine.windStrength,
                    enabled: $engine.windEnabled,
                    isExpanded: expandedCard == "wind",
                    onTap: { withAnimation(.spring(response: 0.3)) { expandedCard = expandedCard == "wind" ? nil : "wind" } }
                )

                // Apply button — appears when something changed
                Button(action: { engine.reset(); engine.start() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("RELEASE INTO THE WILD")
                    }
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(gold)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // Quick scenes — small pills
                HStack(spacing: 8) {
                    ScenePill("🔴 Haboob") { engine.zebraFrac = 0.286; engine.lionFrac = 0.00286; engine.windEnabled = true; engine.reset(); engine.start() }
                    ScenePill("🦴 Bone") { engine.zebraFrac = 0.35; engine.lionFrac = 0.015; engine.windEnabled = false; engine.reset(); engine.start() }
                    ScenePill("⬜ Fire") { engine.zebraFrac = 0.02; engine.lionFrac = 0.00025; engine.windEnabled = false; engine.reset(); engine.start() }
                    ScenePill("🎲 Random") {
                        engine.zebraFrac = Double.random(in: 0.01...0.4)
                        engine.lionFrac = Double.random(in: 0.0001...0.02)
                        engine.windEnabled = Bool.random()
                        engine.reset(); engine.start()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(bg)
    }
}

// MARK: - Animal Card

struct AnimalCard<Controls: View>: View {
    let emoji: String
    let name: String
    let count: Int
    let color: Color
    let isExpanded: Bool
    let onTap: () -> Void
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(spacing: 0) {
            // Collapsed: emoji + name + count
            Button(action: onTap) {
                HStack(spacing: 14) {
                    Text(emoji)
                        .font(.system(size: 40))
                        .shadow(color: color.opacity(0.4), radius: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(color)
                            .tracking(2)
                        Text("\(count.formatted())")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(color.opacity(0.5))
                        .font(.system(size: 14))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            // Expanded: controls slide in
            if isExpanded {
                VStack(spacing: 10) {
                    controls()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(isExpanded ? 0.04 : 0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(color.opacity(isExpanded ? 0.3 : 0.1), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Wind Card

struct WindCard: View {
    @Binding var direction: Double
    @Binding var strength: Double
    @Binding var enabled: Bool
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    Text("💨")
                        .font(.system(size: 40))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("WIND")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.40, green: 0.60, blue: 0.80))
                            .tracking(2)
                        Text(enabled ? compassLabel(direction) : "Calm")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(Color.blue.opacity(0.5))
                        .font(.system(size: 14))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 12) {
                    Toggle(isOn: $enabled) {
                        Text("Wind active")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .tint(Color(red: 0.40, green: 0.60, blue: 0.80))

                    // Interactive compass
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            .frame(width: 120, height: 120)

                        // Direction labels
                        ForEach(Array(["N","E","S","W"].enumerated()), id: \.offset) { idx, label in
                            let angle = Double(idx) * .pi / 2 - .pi / 2
                            Text(label)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.gray)
                                .offset(x: cos(angle) * 52, y: sin(angle) * 52)
                        }

                        // Arrow
                        let arrowAngle = direction - .pi / 2
                        Path { path in
                            path.move(to: CGPoint(x: 60, y: 60))
                            path.addLine(to: CGPoint(
                                x: 60 + cos(arrowAngle) * 45 * strength,
                                y: 60 + sin(arrowAngle) * 45 * strength
                            ))
                        }
                        .stroke(Color(red: 0.40, green: 0.60, blue: 0.80), lineWidth: 3)
                        .frame(width: 120, height: 120)

                        Circle()
                            .fill(Color(red: 0.40, green: 0.60, blue: 0.80))
                            .frame(width: 8, height: 8)
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let center = CGPoint(x: 60, y: 60)
                                let dx = value.location.x - center.x
                                let dy = value.location.y - center.y
                                direction = atan2(dy, dx) + .pi / 2
                                if direction < 0 { direction += 2 * .pi }
                                strength = min(1.0, sqrt(dx*dx + dy*dy) / 50)
                            }
                    )

                    ParamSlider(label: "Strength", value: $strength, range: 0...1.0, format: "%.0f%%", multiplier: 100, color: Color(red: 0.40, green: 0.60, blue: 0.80))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(isExpanded ? 0.04 : 0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.blue.opacity(isExpanded ? 0.3 : 0.1), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    func compassLabel(_ rad: Double) -> String {
        let deg = rad * 180 / .pi
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let idx = Int(round(deg / 45)) % 8
        return dirs[idx < 0 ? idx + 8 : idx]
    }
}

// MARK: - Reusable Components

struct ParamSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let multiplier: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
                Text(String(format: format, value * multiplier))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
            }
            Slider(value: $value, in: range)
                .tint(color)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color.gray.opacity(0.6))
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)
        }
    }
}

struct ScenePill: View {
    let label: String
    let action: () -> Void

    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.77, green: 0.64, blue: 0.35))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04))
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color(red: 0.77, green: 0.64, blue: 0.35).opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
