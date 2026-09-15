import Foundation

/// The store as CloudKit sees it: one record per file, its JSON carried whole in one
/// field, so the cloud schema is a handful of record types with the same two fields and the
/// apps never have to agree on anything but the JSON they already share.
///
/// CloudKit itself lives in the apps; this is the part that can be tested.
public enum CloudRecords {
    public static let types = ["Project", "Task", "Escalation", "Artifact", "Agent"]

    public struct Encoded: Sendable, Equatable, Hashable {
        public var type: String
        public var name: String
        public var json: String
        public var updated: Date

        public init(type: String, name: String, json: String, updated: Date) {
            self.type = type
            self.name = name
            self.json = json
            self.updated = updated
        }

        /// The CloudKit record name. Types keep their own ids apart.
        public var recordName: String { "\(type)-\(name)" }
    }

    // MARK: Encoding

    public static func encode(_ snapshot: Snapshot) -> [Encoded] {
        var out: [Encoded] = []
        for p in snapshot.projects { out.append(encode("Project", FileStore.fileName(forProject: p.id), p, p.added)) }
        for t in snapshot.tasks { out.append(encode("Task", t.id.uuidString, t, t.updated)) }
        for e in snapshot.escalations { out.append(encode("Escalation", e.id.uuidString, e, e.decision?.at ?? e.raised)) }
        for d in snapshot.artifacts { out.append(encode("Artifact", d.id.uuidString, d, d.updated)) }
        for a in snapshot.agents { out.append(encode("Agent", a.id.uuidString, a, a.deregistered ?? a.lastSeen)) }
        return out
    }

    private static func encode<T: Encodable>(_ type: String, _ name: String, _ value: T, _ updated: Date) -> Encoded {
        let data = (try? FileStore.encoder.encode(value)) ?? Data()
        return Encoded(type: type, name: name, json: String(decoding: data, as: UTF8.self), updated: updated)
    }

    public static func decode(_ records: [Encoded]) -> Snapshot {
        var snapshot = Snapshot()
        for r in records {
            let data = Data(r.json.utf8)
            switch r.type {
            case "Project": if let v = try? FileStore.decoder.decode(Project.self, from: data) { snapshot.projects.append(v) }
            case "Task": if let v = try? FileStore.decoder.decode(FactoryTask.self, from: data) { snapshot.tasks.append(v) }
            case "Escalation": if let v = try? FileStore.decoder.decode(Escalation.self, from: data) { snapshot.escalations.append(v) }
            case "Artifact": if let v = try? FileStore.decoder.decode(Artifact.self, from: data) { snapshot.artifacts.append(v) }
            case "Agent": if let v = try? FileStore.decoder.decode(Agent.self, from: data) { snapshot.agents.append(v) }
            default: break
            }
        }
        return snapshot
    }

    // MARK: What to send

    public struct Diff: Sendable, Equatable {
        public var save: [Encoded]
        public var delete: [String]

        public var isEmpty: Bool { save.isEmpty && delete.isEmpty }
    }

    /// What changed since the last push: records whose JSON differs or are new, and the
    /// names of records that have gone.
    public static func diff(from old: [Encoded], to new: [Encoded]) -> Diff {
        let before = Dictionary(uniqueKeysWithValues: old.map { ($0.recordName, $0) })
        let after = Set(new.map(\.recordName))
        let save = new.filter { before[$0.recordName]?.json != $0.json }
        let delete = old.map(\.recordName).filter { !after.contains($0) }
        return Diff(save: save, delete: delete)
    }

    /// Decisions made on another device: cloud escalations that carry a decision where
    /// the local record is still open. The local record keeps everything else.
    public static func decisionsToAdopt(local: [Escalation], cloud: [Escalation]) -> [Escalation] {
        let byID = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        return local.compactMap { mine in
            guard mine.isOpen, let theirs = byID[mine.id], let decision = theirs.decision,
                  mine.options.contains(where: { $0.id == decision.optionID }) else { return nil }
            var adopted = mine
            adopted.decision = decision
            return adopted
        }
    }

    /// Tasks added on another device, away from the Mac: in the cloud but not here yet.
    public static func tasksToAdopt(local: [FactoryTask], cloud: [FactoryTask]) -> [FactoryTask] {
        let mine = Set(local.map(\.id))
        return cloud.filter { !mine.contains($0.id) }
    }

    /// Person-made changes on another device: the cloud record is newer. Title, note,
    /// work, rank, parking, and removal come across. In progress and done never do:
    /// those are an agent's to say. A done task stays done. (T172, 13 Sep 2026.)
    public static func taskChangesToAdopt(local: [FactoryTask], cloud: [FactoryTask]) -> [FactoryTask] {
        let byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        return cloud.compactMap { theirs in
            guard let mine = byID[theirs.id], theirs.updated > mine.updated else { return nil }
            if Backlog.personMaySet.contains(theirs.state), mine.state != .done {
                return theirs
            }
            var adopted = mine
            adopted.title = theirs.title
            adopted.note = theirs.note
            adopted.work = theirs.work
            adopted.rank = theirs.rank
            adopted.removed = theirs.removed
            adopted.updated = theirs.updated
            return adopted
        }
    }
}
