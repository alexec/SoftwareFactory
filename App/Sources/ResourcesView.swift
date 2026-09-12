import SwiftUI
import SoftwareFactoryKit

/// Things agents share. Each has slots; an agent leases a slot for a while and gives it
/// back. A lease that runs out is simply over.
struct ResourcesView: View {
    @Environment(AppModel.self) private var model

    @State private var newName = ""
    @State private var newSlots = 1
    @State private var newMinutes = 60

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("Add a resource", text: $newName)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                    Stepper("\(newSlots) \(newSlots == 1 ? "slot" : "slots")", value: $newSlots, in: 1...32)
                        .fixedSize()
                    Stepper("up to \(newMinutes) min", value: $newMinutes, in: 5...720, step: 5)
                        .fixedSize()
                    Button("Add", action: add)
                        .buttonStyle(.glass)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.vertical, 4)
            }

            if model.dashboard.resources.isEmpty {
                EmptyLine(text: "No resources yet. A phone, a simulator, the browser, the whole Mac: anything only so many agents can use at once.", symbol: "lock.rectangle.stack")
            }

            ForEach(model.dashboard.resources) { status in
                ResourceRow(status: status)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func add() {
        model.addResource(name: newName, slots: newSlots, maxMinutes: newMinutes)
        newName = ""
    }
}

struct ResourceRow: View {
    @Environment(AppModel.self) private var model
    var status: Dashboard.ResourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(status.resource.name)
                    .font(.headline)
                Text("\(status.free) of \(status.resource.slots) free · leases up to \(Int(status.resource.maxLease / 60)) min")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<status.resource.slots, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i < status.held.count ? Color.orange : Color.secondary.opacity(0.18))
                            .frame(width: 12, height: 12)
                    }
                }
                Menu {
                    Button("Remove", role: .destructive) { model.remove(status.resource) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            ForEach(status.held) { holding in
                HStack(spacing: 8) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text(holding.agentName)
                        .font(.callout.weight(.medium))
                    if !holding.lease.why.isEmpty {
                        Text(holding.lease.why)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("until \(holding.lease.until, format: .dateTime.hour().minute())")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Take back") { model.end(holding.lease) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .help("End this lease now")
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
    }
}
