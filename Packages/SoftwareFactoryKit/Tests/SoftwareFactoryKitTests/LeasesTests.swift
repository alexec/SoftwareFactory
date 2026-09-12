import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct LeasesTests {
    let now = Date(timeIntervalSince1970: 100_000)
    let phone = Resource(name: "iPhone", slots: 1, maxLease: 7200)
    let compile = Resource(name: "Compile", slots: 2, maxLease: 1800)
    let a = UUID(), b = UUID(), c = UUID()

    @Test func aFreeSlotIsLeasedAndCapped() throws {
        guard case .leased(let lease) = Leases.lease(phone, for: a, wanting: 99_999, why: "capture run", in: [], now: now) else {
            Issue.record("expected a lease"); return
        }
        #expect(lease.agentID == a)
        #expect(lease.until == now.addingTimeInterval(7200))
        #expect(lease.why == "capture run")
        #expect(Leases.freeSlots(of: phone, in: [lease], now: now) == 0)
    }

    @Test func aFullResourceSaysWhenItFrees() {
        let l1 = Lease(resourceID: compile.id, agentID: a, why: "", since: now, until: now.addingTimeInterval(600))
        let l2 = Lease(resourceID: compile.id, agentID: b, why: "", since: now, until: now.addingTimeInterval(300))
        guard case .full(let nextFree, let held) = Leases.lease(compile, for: c, wanting: 600, why: "", in: [l1, l2], now: now) else {
            Issue.record("expected full"); return
        }
        #expect(nextFree == l2.until)
        #expect(held.count == 2)
    }

    @Test func anExpiredLeaseFreesTheSlot() {
        let old = Lease(resourceID: phone.id, agentID: a, why: "", since: now.addingTimeInterval(-9000), until: now.addingTimeInterval(-1))
        #expect(Leases.freeSlots(of: phone, in: [old], now: now) == 1)
        guard case .leased = Leases.lease(phone, for: b, wanting: 60, why: "", in: [old], now: now) else {
            Issue.record("expected a lease"); return
        }
    }

    @Test func leasingAgainRenewsRatherThanDoubling() {
        let mine = Lease(resourceID: phone.id, agentID: a, why: "first", since: now, until: now.addingTimeInterval(100))
        guard case .leased(let again) = Leases.lease(phone, for: a, wanting: 600, why: "", in: [mine], now: now) else {
            Issue.record("expected a lease"); return
        }
        #expect(again.id == mine.id)
        #expect(again.until == now.addingTimeInterval(600))
        #expect(again.why == "first")
    }

    @Test func renewAndReleaseCheckTheHolder() throws {
        let mine = Lease(resourceID: phone.id, agentID: a, why: "", since: now, until: now.addingTimeInterval(100))
        let renewed = try Leases.renew(mine, of: phone, for: a, wanting: 60, now: now)
        #expect(renewed.until == now.addingTimeInterval(60))
        #expect(throws: Leases.LeaseError.notHeldByAgent) { try Leases.renew(mine, of: phone, for: b, wanting: 60, now: now) }
        let gone = Lease(resourceID: phone.id, agentID: a, why: "", since: now, until: now.addingTimeInterval(-5))
        #expect(throws: Leases.LeaseError.expired) { try Leases.renew(gone, of: phone, for: a, wanting: 60, now: now) }
        let released = try Leases.release(mine, for: a, now: now)
        #expect(!released.isActive(now: now))
        #expect(throws: Leases.LeaseError.notHeldByAgent) { try Leases.release(mine, for: b, now: now) }
    }

    @Test func heldByAndStale() {
        let live = Lease(resourceID: phone.id, agentID: a, why: "", since: now, until: now.addingTimeInterval(100))
        var old = Lease(resourceID: compile.id, agentID: a, why: "", since: now.addingTimeInterval(-200_000), until: now.addingTimeInterval(-190_000))
        let recent = Lease(resourceID: compile.id, agentID: b, why: "", since: now.addingTimeInterval(-100), until: now.addingTimeInterval(-10))
        #expect(Leases.heldBy(a, in: [live, old, recent], now: now).map(\.id) == [live.id])
        #expect(Leases.stale(in: [live, old, recent], now: now).map(\.id) == [old.id])
        old.released = now.addingTimeInterval(-10)
        #expect(Leases.stale(in: [old], now: now).isEmpty)
    }
}
