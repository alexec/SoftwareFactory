import ActivityKit
import AppIntents
import Foundation

/// A question on the Lock Screen. The phone starts one Live Activity while a question is
/// open and ends it when the last is answered. Shared by the app and its widget extension.
struct FactoryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        struct Option: Codable, Hashable, Identifiable {
            var id: UUID
            var title: String
            var recommended: Bool
        }

        var escalationID: UUID
        var project: String
        var raisedBy: String
        var question: String
        var context: String
        var options: [Option]
        /// How many questions are open, this one included.
        var open: Int
    }

    /// One activity per phone; the state carries whichever question is oldest.
    var factory: String
}

/// Tapping an option on the Lock Screen. It runs inside the app, which answers through
/// the factory when it can reach it and through iCloud otherwise.
struct DecideIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer a question"
    static let isDiscoverable = false

    @Parameter(title: "Question") var escalationID: String
    @Parameter(title: "Option") var optionID: String

    init() {}

    init(escalationID: UUID, optionID: UUID) {
        self.escalationID = escalationID.uuidString
        self.optionID = optionID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let e = UUID(uuidString: escalationID), let o = UUID(uuidString: optionID) else { return .result() }
        await LockScreenDecider.decide(e, o)
        return .result()
    }
}

/// The app installs the hand that answers; the widget extension has none and never needs it.
enum LockScreenDecider {
    nonisolated(unsafe) static var handler: (@Sendable (UUID, UUID) async -> Void)?

    static func decide(_ escalationID: UUID, _ optionID: UUID) async {
        await handler?(escalationID, optionID)
    }
}
