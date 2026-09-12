import CloudKit
import Foundation
import SoftwareFactoryKit

/// The store in the person's own iCloud, so the phone can read questions and answer
/// them away from the Mac's network. The Mac pushes every change and pulls decisions;
/// the phone pulls everything and pushes decisions. Nothing else writes.
///
/// One private database, four record types, two fields each (`json`, `updated`). The
/// JSON is the same record the file store holds, so the apps agree by construction.
@MainActor
final class CloudSync {
    static let containerID = "iCloud.com.alexecollins.softwarefactory"

    enum Standing: Equatable {
        case unknown
        case noAccount
        case unavailable(String)
        case ready
    }

    private(set) var standing: Standing = .unknown
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var recordCount = 0

    private let container = CKContainer(identifier: CloudSync.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private var lastPushed: [CloudRecords.Encoded] = []

    var isReady: Bool { standing == .ready }

    var summary: String {
        switch standing {
        case .unknown: return "Not asked yet."
        case .noAccount: return "Not signed in to iCloud on this device."
        case .unavailable(let why): return why
        case .ready:
            if let lastError { return lastError }
            guard let lastSync else { return "Signed in; nothing synced yet." }
            return "\(recordCount) records · \(lastSync.formatted(date: .omitted, time: .shortened))"
        }
    }

    /// Asks iCloud whether there is an account. Cheap; call it on launch and foreground.
    func prepare() async {
        do {
            switch try await container.accountStatus() {
            case .available: standing = .ready
            case .noAccount: standing = .noAccount
            case .restricted: standing = .unavailable("iCloud is switched off for this device.")
            default: standing = .unavailable("iCloud is not answering just now.")
            }
        } catch {
            standing = .unavailable(error.localizedDescription)
        }
    }

    // MARK: Pushing (the Mac, and the phone's decisions)

    /// Sends what changed since the last push. The first push sends everything.
    func push(_ snapshot: Snapshot) async {
        guard isReady else { return }
        let encoded = CloudRecords.encode(snapshot)
        let diff = CloudRecords.diff(from: lastPushed, to: encoded)
        guard !diff.isEmpty else { return }
        let records = diff.save.map(Self.record)
        let deletions = diff.delete.map { CKRecord.ID(recordName: $0) }
        do {
            let result = try await database.modifyRecords(saving: records, deleting: deletions, savePolicy: .allKeys)
            // A record that failed to save is not remembered as pushed, so it goes again.
            var pushed = Dictionary(uniqueKeysWithValues: lastPushed.map { ($0.recordName, $0) })
            for r in diff.save where (try? result.saveResults[CKRecord.ID(recordName: r.recordName)]?.get()) != nil {
                pushed[r.recordName] = r
            }
            for name in diff.delete { pushed[name] = nil }
            lastPushed = Array(pushed.values)
            recordCount = lastPushed.count
            lastSync = .now
            lastError = nil
        } catch {
            lastError = "Could not sync: \(error.localizedDescription)"
        }
    }

    /// Writes one escalation's decision. Reads the record first so nothing else on it is lost.
    func push(decision escalation: Escalation) async {
        await push(one: CloudRecords.encode(Snapshot(escalations: [escalation]))[0], what: "the decision")
    }

    /// Writes one project, for a note added on the phone.
    func push(project: Project) async {
        await push(one: CloudRecords.encode(Snapshot(projects: [project]))[0], what: "the note")
    }

    private func push(one encoded: CloudRecords.Encoded, what: String) async {
        guard isReady else { return }
        let id = CKRecord.ID(recordName: encoded.recordName)
        do {
            let record = (try? await database.record(for: id)) ?? CKRecord(recordType: encoded.type, recordID: id)
            record["json"] = encoded.json
            record["updated"] = encoded.updated
            _ = try await database.save(record)
            lastSync = .now
            lastError = nil
        } catch {
            lastError = "Could not send \(what): \(error.localizedDescription)"
        }
    }

    // MARK: Subscriptions (the phone)

    /// Asks iCloud for a silent push whenever a question, a task or a project changes,
    /// so the phone learns of news away from the Mac. Saving the same subscriptions
    /// again is harmless.
    func subscribe() async {
        guard isReady else { return }
        let subscriptions = ["Escalation", "Task", "Project"].map { type -> CKSubscription in
            let s = CKQuerySubscription(recordType: type, predicate: NSPredicate(value: true), subscriptionID: "\(type.lowercased())-changes",
                                        options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            s.notificationInfo = info
            return s
        }
        do {
            _ = try await database.modifySubscriptions(saving: subscriptions, deleting: [])
            subscribed = true
            lastError = nil
        } catch {
            lastError = "Could not subscribe for pushes: \(error.localizedDescription)"
        }
    }

    private(set) var subscribed = false

    func noteRegistrationFailure(_ error: Error) {
        lastError = "Pushes are not available: \(error.localizedDescription)"
    }

    // MARK: Pulling

    /// Everything in iCloud, as a snapshot. Empty when iCloud is not reachable.
    func pull() async -> Snapshot? {
        guard isReady else { return nil }
        var all: [CloudRecords.Encoded] = []
        for type in CloudRecords.types {
            do {
                all += try await fetchAll(type)
            } catch {
                lastError = "Could not read iCloud: \(error.localizedDescription)"
                return nil
            }
        }
        recordCount = all.count
        lastSync = .now
        lastError = nil
        return CloudRecords.decode(all)
    }

    /// The questions and the projects: what the Mac needs to learn of decisions made and
    /// notes written elsewhere.
    func pullEscalationsAndProjects() async -> (escalations: [Escalation], projects: [Project])? {
        guard isReady else { return nil }
        do {
            let decoded = CloudRecords.decode(try await fetchAll("Escalation") + (try await fetchAll("Project")))
            lastSync = .now
            lastError = nil
            return (decoded.escalations, decoded.projects)
        } catch {
            lastError = "Could not read iCloud: \(error.localizedDescription)"
            return nil
        }
    }

    /// Only the questions.
    func pullEscalations() async -> [Escalation]? {
        await pullEscalationsAndProjects()?.escalations
    }

    /// One project as iCloud has it, for adding a note to it from the phone.
    func pullProject(_ id: String) async -> Project? {
        guard isReady else { return nil }
        let name = CloudRecords.encode(Snapshot(projects: [Project(name: "", id: id)]))[0].recordName
        guard let record = try? await database.record(for: CKRecord.ID(recordName: name)), let encoded = Self.encoded(record) else { return nil }
        return CloudRecords.decode([encoded]).projects.first
    }

    private func fetchAll(_ type: String) async throws -> [CloudRecords.Encoded] {
        // `updated` is our own field, so its index exists wherever the record type does;
        // querying on nothing at all needs an index CloudKit does not make on its own.
        let query = CKQuery(recordType: type, predicate: NSPredicate(format: "updated > %@", Date.distantPast as NSDate))
        var out: [CloudRecords.Encoded] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let (matches, next) = cursor == nil
                ? try await database.records(matching: query, resultsLimit: 200)
                : try await database.records(continuingMatchFrom: cursor!, resultsLimit: 200)
            for (_, result) in matches {
                if let record = try? result.get(), let encoded = Self.encoded(record) { out.append(encoded) }
            }
            cursor = next
        } while cursor != nil
        return out
    }

    // MARK: Records

    private static func record(_ e: CloudRecords.Encoded) -> CKRecord {
        let record = CKRecord(recordType: e.type, recordID: CKRecord.ID(recordName: e.recordName))
        record["json"] = e.json
        record["updated"] = e.updated
        return record
    }

    private static func encoded(_ record: CKRecord) -> CloudRecords.Encoded? {
        guard let json = record["json"] as? String else { return nil }
        let prefix = record.recordType + "-"
        let name = record.recordID.recordName.hasPrefix(prefix)
            ? String(record.recordID.recordName.dropFirst(prefix.count)) : record.recordID.recordName
        return CloudRecords.Encoded(type: record.recordType, name: name, json: json,
                                    updated: record["updated"] as? Date ?? record.modificationDate ?? .distantPast)
    }
}
