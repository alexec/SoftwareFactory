import SwiftUI
import UIKit

struct PhoneSettingsView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingIntro = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("How it works") { showingIntro = true }
                }

                Section("Factory") {
                    switch model.link {
                    case .notYetAsked:
                        Text("Not looking yet.")
                    case .looking:
                        Text("Looking on this network.")
                    case .connected(let name):
                        LabeledContent("Connected to", value: name)
                    case .lost:
                        Text("The phone cannot reach the factory. If you said no to local network access, it can be turned on in the iOS Settings app.")
                            .foregroundStyle(.secondary)
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                Section("iCloud") {
                    LabeledContent("Sync", value: model.cloud.summary)
                    Text("Away from the Mac's network, questions arrive and answers go back through your own iCloud.")
                        .foregroundStyle(.secondary)
                }

                #if DEBUG
                Section("Developer") {
                    Button("Show the first-run sheet again") { model.hasSeenIntro = false }
                    Button("Forget the network priming") { model.hasPrimedNetwork = false }
                    if let error = model.lastError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                }
                #endif
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingIntro) { PhoneIntroSheet() }
    }
}
