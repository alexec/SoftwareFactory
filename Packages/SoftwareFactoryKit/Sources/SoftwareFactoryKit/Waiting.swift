import Foundation

/// What the factory is holding that has not reached anybody yet: documents nobody has
/// opened, and messages still queued for a terminal.
///
/// Both are quiet by nature. A document arrives on a project page you are not looking at
/// and a message waits in a mailbox for an agent whose terminal is not on screen, so
/// neither has anywhere to say so. The counts go beside the factory's own name, which is
/// the one thing on screen whatever page is open. (T373.)
///
/// Only live things count. A document on a removed project and a message to an agent
/// that has been deleted are never going to be read by anyone, and a number that can
/// only go up is a number people learn to ignore.
public enum Waiting {
    /// Documents filed and not yet opened, on projects that are still here.
    public static func unreadDocuments(_ artifacts: [Artifact], on projects: [Project]) -> Int {
        let live = Set(projects.filter { $0.removed == nil }.map(\.id))
        return artifacts.filter { $0.removed == nil && !$0.isRead && live.contains($0.projectID) }.count
    }

    /// Messages the app has not typed into a terminal yet, for agents still on the floor.
    /// A nudge is a message like any other, so it counts like one.
    public static func messages(_ messages: [AgentMessage], to agents: [Agent]) -> Int {
        let live = Set(agents.filter { $0.deregistered == nil }.map(\.id))
        return Mailbox.waiting(messages).filter { live.contains($0.recipientID) }.count
    }
}
