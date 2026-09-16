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

                Section("Notifications") {
                    switch model.notifier.standing {
                    case .allowed:
                        Text("A banner arrives for each new question, with its options, wherever the phone is.")
                            .foregroundStyle(.secondary)
                    case .denied:
                        Text("Notifications are off for Taktu: Software Factory. They can be turned on in the iOS Settings app.")
                            .foregroundStyle(.secondary)
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    default:
                        Text("Not asked yet. The dashboard asks the first time.")
                            .foregroundStyle(.secondary)
                    }
                    #if DEBUG
                    Text(model.notifier.lastPost).font(.caption).foregroundStyle(.secondary)
                    #endif
                }

                Section("Lock Screen") {
                    Text("While a question is open, it sits on the Lock Screen with its options, so you answer without unlocking. It is kept current while Taktu: Software Factory is open.")
                        .foregroundStyle(.secondary)
                }

                Section("iCloud") {
                    LabeledContent("Sync", value: model.cloud.summary)
                    LabeledContent("Pushes", value: model.cloud.subscribed ? "On: iCloud wakes the app when the Mac writes" : "Not yet; they start once notifications are allowed")
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
            .scrollContentBackground(.hidden)
        .background(Color(.paper))
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
