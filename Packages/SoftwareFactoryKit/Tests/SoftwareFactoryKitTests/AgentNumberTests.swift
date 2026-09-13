import Foundation
import Testing
@testable import SoftwareFactoryKit

/// A number belongs to one agent for the life of the factory. It is taken off a counter
/// on disk, not worked out from the agents still in the store, so deleting an agent never
/// frees its name and two registrations at once never come away with the same one.
@Suite struct AgentNumberTests {
    @Test func numbersComeOutInOrderAndAreNeverGivenTwice() throws {
        let store = try temporaryStore()
        let numbers = try store.agentNumbers()
        #expect(numbers.highest == 0)
        #expect(try store.takeAgentNumber() == 1)
        #expect(try store.takeAgentNumber() == 2)
        #expect(numbers.highest == 2)
        #expect(!numbers.claim(2))
        #expect(numbers.isSpent(1) && numbers.isSpent(2) && !numbers.isSpent(3))
    }

    @Test func aDeletedAgentDoesNotGiveItsNameBack() throws {
        let store = try temporaryStore()
        let number = try store.takeAgentNumber()
        let agent = Agents.reserve(number: number, projectID: nil, session: nil)
        try store.save(agent)
        try store.delete(agent)
        #expect(try store.load().agents.isEmpty)
        #expect(try store.takeAgentNumber() == number + 1)
    }

    @Test func aStoreFromBeforeTheCounterStartsAboveItsAgents() throws {
        let store = try temporaryStore()
        try store.save(Agent(number: 7, projectID: nil))
        #expect(try store.takeAgentNumber() == 8)
    }

    @Test func aNumberClaimedByHandIsSpent() throws {
        let store = try temporaryStore()
        let numbers = try store.agentNumbers()
        #expect(numbers.claim(12))
        #expect(!numbers.claim(12))
        #expect(try store.takeAgentNumber() == 13)
    }

    @Test func takingIsAtomicAcrossThreads() throws {
        let store = try temporaryStore()
        let taken = Mutex()
        DispatchQueue.concurrentPerform(iterations: 25) { _ in
            if let n = try? store.takeAgentNumber() { taken.add(n) }
        }
        #expect(taken.values.count == 25)
        #expect(Set(taken.values).count == 25)
    }

    // MARK: One terminal, one agent

    /// A shell that outlives its agent keeps SOFTWARE_FACTORY_SESSION exported, so the
    /// next agent started by hand in that window reports the same session. The window has
    /// one agent in it, and it is the newcomer. (Alex, 13 Sep 2026: I have seen two.)
    @Test func aSessionMovesToWhoeverIsActuallyInTheWindow() {
        let now = wholeSecond()
        var old = Agents.reserve(number: 1, projectID: nil, session: "sf-abcd", now: now.addingTimeInterval(-3600))
        old.lastSeen = now.addingTimeInterval(-3600)         // silent for an hour: gone
        let newcomer = Agents.reserve(number: 2, projectID: nil, session: nil, now: now)

        let claim = Agents.claimSession("sf-abcd", for: newcomer, in: [old], now: now)
        #expect(claim.session == "sf-abcd")
        #expect(claim.released.count == 1)
        #expect(claim.released[0].id == old.id && claim.released[0].session == nil)
    }

    /// An agent still working in that window keeps it, and the newcomer gets no session
    /// rather than a window that is not its own.
    @Test func aLiveSessionIsNotTakenFromTheAgentInIt() {
        let now = wholeSecond()
        var live = Agents.reserve(number: 1, projectID: nil, session: "sf-abcd", now: now)
        live.isConnected = true
        live.lastSeen = now
        let newcomer = Agents.reserve(number: 2, projectID: nil, session: nil, now: now)

        let claim = Agents.claimSession("sf-abcd", for: newcomer, in: [live], now: now)
        #expect(claim.session == nil)
        #expect(claim.released.isEmpty)
    }

    /// An agent saying its own session again changes nothing.
    @Test func anAgentKeepsItsOwnSession() {
        let now = wholeSecond()
        var mine = Agents.reserve(number: 1, projectID: nil, session: "sf-abcd", now: now)
        mine.isConnected = true
        let claim = Agents.claimSession("sf-abcd", for: mine, in: [mine], now: now)
        #expect(claim.session == "sf-abcd")
        #expect(claim.released.isEmpty)
    }

    /// An agent that has left is not in the way of the window it used to be in.
    @Test func aDeregisteredAgentDoesNotHoldItsWindow() {
        let now = wholeSecond()
        var gone = Agents.reserve(number: 1, projectID: nil, session: "sf-abcd", now: now)
        gone.isConnected = true
        gone.lastSeen = now
        gone.deregistered = now
        let newcomer = Agents.reserve(number: 2, projectID: nil, session: nil, now: now)
        let claim = Agents.claimSession("sf-abcd", for: newcomer, in: [gone], now: now)
        #expect(claim.session == "sf-abcd")
        #expect(claim.released.isEmpty)
    }

    final class Mutex: @unchecked Sendable {
        private let lock = NSLock()
        private var numbers: [Int] = []
        func add(_ n: Int) { lock.lock(); numbers.append(n); lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return numbers }
    }
}
