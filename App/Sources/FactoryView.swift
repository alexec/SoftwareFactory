import SwiftUI
import SoftwareFactoryKit

/// The factory's capacity: this Mac's own resources and anything else only so many agents
/// can share at once (a phone, a simulator, the browser), side by side as one set of cards.
struct FactoryView: View {
    @Environment(AppModel.self) private var model

    @State private var newName = ""
    @State private var newSlots = 1
    @State private var newMinutes = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let r = model.machine {
                    capacity(r)
                    GlassEffectContainer(spacing: 16) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                            systemCards(r)
                            ForEach(model.dashboard.resources) { status in
                                LeasableResourceCard(status: status)
                            }
                        }
                    }
                } else {
                    EmptyLine(text: "Reading the Mac.", symbol: "gauge.with.dots.needle.33percent")
                }
                addResource
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func systemCards(_ r: MachineReading) -> some View {
        let t = model.throttle
        ResourceCard(title: "Memory free", value: r.memoryFreeFraction, text: percent(r.memoryFreeFraction),
              tint: r.memoryFreeFraction <= t.memoryFloor ? .red : (r.memoryFreeFraction <= t.memoryFloor * 2 ? .orange : .green))
        ResourceCard(title: "Swap", value: r.swapFraction, text: "\(gigabytes(r.swapUsed)) of \(gigabytes(r.swapTotal))",
              tint: r.swapFraction >= t.swapCeiling ? .red : (r.swapFraction >= t.swapCeiling * 0.66 ? .orange : .green))
        ResourceCard(title: "Load", value: min(1, r.loadPerCore), text: "\(String(format: "%.1f", r.load)) on \(r.cores) cores",
              tint: r.loadPerCore >= 0.9 ? .orange : .green)
        ResourceCard(title: "Compiles", value: t.compileSlots == 0 ? 0 : Double(r.compiles) / Double(t.compileSlots),
              text: "\(r.compiles) of \(t.compileSlots) · \(r.simulators) \(r.simulators == 1 ? "simulator" : "simulators")",
              tint: r.compiles >= t.compileSlots ? .orange : .green)
    }

    /// What could start now. The verdict and the reason, then the room in numbers.
    private func capacity(_ r: MachineReading) -> some View {
        let t = model.throttle
        let v = Capacity.verdict(r, throttle: t)
        let h = Capacity.headroom(r, throttle: t)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(color(v)).frame(width: 10, height: 10)
                Text(word(v))
                    .font(.title2.weight(.semibold))
            }
            Text(Capacity.reason(r, throttle: t))
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Room(number: h.compiles, label: h.compiles == 1 ? "more compile" : "more compiles", ok: h.compiles > 0)
                Room(number: h.simulators, label: h.simulators == 1 ? "more simulator" : "more simulators", ok: h.simulators > 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gigabytes(h.memoryFree))
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("memory free").font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(gigabytes(h.swapFree))
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("swap free").font(.callout).foregroundStyle(.secondary)
                }
            }
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

    private var addResource: some View {
        HStack(spacing: 10) {
            TextField("Add a resource", text: $newName)
                .textFieldStyle(.plain)
                .onSubmit(addResourceNow)
            Stepper("\(newSlots) \(newSlots == 1 ? "slot" : "slots")", value: $newSlots, in: 1...32)
                .fixedSize()
            Stepper("up to \(newMinutes) min", value: $newMinutes, in: 5...720, step: 5)
                .fixedSize()
            Button("Add", action: addResourceNow)
                .buttonStyle(.glass)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func addResourceNow() {
        model.addResource(name: newName, slots: newSlots, maxMinutes: newMinutes)
        newName = ""
    }

    private func word(_ v: Capacity.Verdict) -> String {
        switch v {
        case .under: "Under capacity"
        case .tight: "Tight"
        case .over: "Over capacity"
        }
    }

    private func color(_ v: Capacity.Verdict) -> Color { CapacityDot.color(v) }

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

/// The Mac's verdict as a dot: green under capacity, orange tight, red over.
struct CapacityDot: View {
    var verdict: Capacity.Verdict?
    var reason: String?

    var body: some View {
        Circle()
            .fill(Self.color(verdict))
            .frame(width: 8, height: 8)
            .help(reason ?? "Reading the Mac")
    }

    static func color(_ verdict: Capacity.Verdict?) -> Color {
        switch verdict {
        case .under: .green
        case .tight: .orange
        case .over: .red
        case nil: .secondary.opacity(0.4)
        }
    }
}

private struct Room: View {
    var number: Int
    var label: String
    var ok: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(number, format: .number)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundStyle(ok ? Color.primary : Color.orange)
                .contentTransition(.numericText())
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The colored utilization line every resource card shares, system or leasable alike.
private struct UtilizationBar: View {
    var value: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 8)
    }
}

/// A reading on the Mac itself: a name, a number, and how full it is.
private struct ResourceCard: View {
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
            UtilizationBar(value: value, tint: tint)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// A resource you added, leased by agents: the same card as a system reading, its
/// utilization the slots in use, with who is holding it underneath.
private struct LeasableResourceCard: View {
    @Environment(AppModel.self) private var model
    var status: Dashboard.ResourceStatus

    private var value: Double {
        status.resource.slots == 0 ? 0 : Double(status.held.count) / Double(status.resource.slots)
    }
    private var tint: Color {
        if status.held.contains(where: \.isOverdue) { return .red }
        return status.held.isEmpty ? .green : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.resource.name).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(status.free) of \(status.resource.slots) free").font(.callout.weight(.medium)).monospacedDigit()
                Menu {
                    Button("Remove", role: .destructive) { model.remove(status.resource) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            UtilizationBar(value: value, tint: tint)
            ForEach(status.held) { holding in
                HStack(spacing: 6) {
                    Circle().fill(holding.isOverdue ? Color.red : Color.orange).frame(width: 6, height: 6)
                    Text(holding.agentName).font(.caption.weight(.medium))
                    Spacer()
                    Button("Take back") { model.end(holding.lease) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
