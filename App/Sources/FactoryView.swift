import SwiftUI
import SoftwareFactoryKit

/// The factory is this Mac. What it is under, the verdict agents get when they ask, and
/// the throttle only you set.
struct FactoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let r = model.machine {
                    gauges(r)
                    verdict(r)
                    throttle
                } else {
                    EmptyLine(text: "Reading the Mac.", symbol: "gauge.with.dots.needle.33percent")
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gauges(_ r: MachineReading) -> some View {
        let t = model.throttle
        return GlassEffectContainer(spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                Gauge(title: "Memory free", value: r.memoryFreeFraction, text: percent(r.memoryFreeFraction),
                      tint: r.memoryFreeFraction <= t.memoryFloor ? .red : (r.memoryFreeFraction <= t.memoryFloor * 2 ? .orange : .green))
                Gauge(title: "Swap", value: r.swapFraction, text: "\(gigabytes(r.swapUsed)) of \(gigabytes(r.swapTotal))",
                      tint: r.swapFraction >= t.swapCeiling ? .red : (r.swapFraction >= t.swapCeiling * 0.66 ? .orange : .green))
                Gauge(title: "Load", value: min(1, r.loadPerCore), text: "\(String(format: "%.1f", r.load)) on \(r.cores) cores",
                      tint: r.loadPerCore >= 0.9 ? .orange : .green)
                Gauge(title: "Compiles", value: t.compileSlots == 0 ? 0 : Double(r.compiles) / Double(t.compileSlots),
                      text: "\(r.compiles) of \(t.compileSlots) · \(r.simulators) \(r.simulators == 1 ? "simulator" : "simulators")",
                      tint: r.compiles >= t.compileSlots ? .orange : .green)
            }
        }
    }

    private func verdict(_ r: MachineReading) -> some View {
        let t = model.throttle
        let v = Capacity.verdict(r, throttle: t)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(color(v)).frame(width: 10, height: 10)
                Text(word(v))
                    .font(.title2.weight(.semibold))
            }
            Text(Capacity.reason(r, throttle: t))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(Capacity.Work.allCases, id: \.self) { work in
                    let a = Capacity.ask(work, r, throttle: t)
                    Label(work.rawValue.capitalized, systemImage: symbol(a))
                        .foregroundStyle(a == .yes ? Color.green : Color.orange)
                        .help(a.text)
                }
            }
            .font(.callout)
            Text("What an agent is told when it asks to start one.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(color(v).opacity(0.10)), in: .rect(cornerRadius: 18))
    }

    private var throttle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Throttle")
                .font(.title2.weight(.semibold))
            Text("Only you set these. An agent that asks gets yes, wait or no from them.")
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(model.throttle.compileSlots) }, set: { v in model.setThrottle { $0.compileSlots = Int(v) } }),
                   in: 1...12, step: 1) { Text("Compiles at once: \(model.throttle.compileSlots)") }
            Slider(value: Binding(get: { Double(model.throttle.simulatorSlots) }, set: { v in model.setThrottle { $0.simulatorSlots = Int(v) } }),
                   in: 1...8, step: 1) { Text("Simulators at once: \(model.throttle.simulatorSlots)") }
            Slider(value: Binding(get: { model.throttle.swapCeiling }, set: { v in model.setThrottle { $0.swapCeiling = v } }),
                   in: 0.3...0.95, step: 0.05) { Text("Hold new work when swap is above \(percent(model.throttle.swapCeiling))") }
            Slider(value: Binding(get: { model.throttle.memoryFloor }, set: { v in model.setThrottle { $0.memoryFloor = v } }),
                   in: 0.05...0.4, step: 0.05) { Text("Hold new work when memory free is below \(percent(model.throttle.memoryFloor))") }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func word(_ v: Capacity.Verdict) -> String {
        switch v {
        case .under: "Under capacity"
        case .tight: "Tight"
        case .over: "Over capacity"
        }
    }

    private func color(_ v: Capacity.Verdict) -> Color {
        switch v {
        case .under: .green
        case .tight: .orange
        case .over: .red
        }
    }

    private func symbol(_ a: Capacity.Answer) -> String {
        switch a {
        case .yes: "checkmark.circle"
        case .wait: "clock"
        case .no: "xmark.circle"
        }
    }

    private func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
    private func gigabytes(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
}

private struct Gauge: View {
    var title: String
    var value: Double
    var text: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.callout.weight(.medium)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint).frame(width: max(0, min(1, value)) * geo.size.width)
                }
            }
            .frame(height: 8)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
