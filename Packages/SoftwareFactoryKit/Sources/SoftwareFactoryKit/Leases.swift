import Foundation

/// The rules for sharing a resource. Pure functions, so the server and the app agree.
public enum Leases {
    public enum Answer: Equatable, Sendable {
        /// A slot was free; here is the lease.
        case leased(Lease)
        /// Every slot is held. The soonest one runs out at this time.
        case full(nextFree: Date, held: [Lease])
    }

    public enum LeaseError: Error, Equatable, Sendable {
        case notHeldByAgent
        case expired
    }

    /// Leases on a resource that still count.
    public static func active(for resourceID: UUID, in all: [Lease], now: Date) -> [Lease] {
        all.filter { $0.resourceID == resourceID && $0.isActive(now: now) }.sorted { $0.until < $1.until }
    }

    public static func freeSlots(of resource: Resource, in all: [Lease], now: Date) -> Int {
        max(0, resource.slots - active(for: resource.id, in: all, now: now).count)
    }

    /// Takes a slot for up to `wanted` seconds, capped by the resource's longest lease.
    /// An agent already holding a slot on this resource gets that lease back, renewed,
    /// rather than a second one.
    public static func lease(
        _ resource: Resource, for agentID: UUID, wanting wanted: TimeInterval, why: String,
        in all: [Lease], now: Date
    ) -> Answer {
        let held = active(for: resource.id, in: all, now: now)
        let length = min(max(60, wanted), resource.maxLease)
        if var mine = held.first(where: { $0.agentID == agentID }) {
            mine.until = now.addingTimeInterval(length)
            mine.why = why.isEmpty ? mine.why : why
            return .leased(mine)
        }
        guard held.count < resource.slots else {
            return .full(nextFree: held.first!.until, held: held)
        }
        return .leased(Lease(resourceID: resource.id, agentID: agentID, why: why, since: now, until: now.addingTimeInterval(length)))
    }

    /// More time on a lease the agent holds, again capped by the resource's longest lease.
    public static func renew(
        _ lease: Lease, of resource: Resource, for agentID: UUID, wanting wanted: TimeInterval, now: Date
    ) throws(LeaseError) -> Lease {
        guard lease.agentID == agentID else { throw .notHeldByAgent }
        guard lease.isActive(now: now) else { throw .expired }
        var renewed = lease
        renewed.until = now.addingTimeInterval(min(max(60, wanted), resource.maxLease))
        return renewed
    }

    public static func release(_ lease: Lease, for agentID: UUID, now: Date) throws(LeaseError) -> Lease {
        guard lease.agentID == agentID else { throw .notHeldByAgent }
        var released = lease
        released.released = now
        return released
    }

    /// Everything an agent holds, for when it leaves.
    public static func heldBy(_ agentID: UUID, in all: [Lease], now: Date) -> [Lease] {
        all.filter { $0.agentID == agentID && $0.isActive(now: now) }
    }

    /// Leases that are over and old enough to forget: released or expired more than a day ago.
    public static func stale(in all: [Lease], now: Date, after: TimeInterval = 86400) -> [Lease] {
        all.filter { !$0.isActive(now: now) && now.timeIntervalSince($0.released ?? $0.until) > after }
    }
}
