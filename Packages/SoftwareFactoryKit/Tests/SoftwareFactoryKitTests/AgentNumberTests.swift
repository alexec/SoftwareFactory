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
        let agent = Agents.reserve(number: number, projectID: nil)
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

    final class Mutex: @unchecked Sendable {
        private let lock = NSLock()
        private var numbers: [Int] = []
        func add(_ n: Int) { lock.lock(); numbers.append(n); lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return numbers }
    }

    // Four tests stood here for the window two agents could land on: it moved to
    // whoever was actually in it, was not taken from one still working, stayed with its
    // own agent, and was let go by one that had deregistered. The terminal is named
    // after the agent now, so two of them cannot land on one and there is nothing left
    // to arbitrate. (T-session, 13 Sep 2026, settling T156 by construction.)
}
