import Foundation
import Testing
@testable import SoftwareFactoryKit

/// Whether an agent is running, asked of the kernel rather than inferred from silence.
@Suite struct ProcessCheckTests {
    @Test func aLiveProcessAnswersAndADeadOneDoesNot() {
        // This test is itself a process, so there is always one to ask about.
        let me = ProcessInfo.processInfo.processIdentifier
        let started = ProcessCheck.startTime(of: me)
        #expect(started != nil)
        // Started in the past, and not in another decade: the clock is the wall clock.
        if let started {
            #expect(started < Date())
            #expect(Date().timeIntervalSince(started) < 60 * 60 * 24 * 365)
        }
        // Nothing is using this, and a pid nobody holds must not answer.
        #expect(ProcessCheck.startTime(of: 0x7FFF_FFFE) == nil)
        #expect(ProcessCheck.startTime(of: 0) == nil)
        #expect(ProcessCheck.startTime(of: -1) == nil)
    }

    /// The pair is the point. A pid on its own is recycled, so a process wearing a dead
    /// agent's number would read as that agent still working.
    @Test func aRecycledPidIsNotTheSameAgent() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let started = try #require(ProcessCheck.startTime(of: me))
        #expect(ProcessCheck.isRunning(pid: me, startedAt: started))
        // Same pid, a process that started at a different moment: somebody else.
        #expect(!ProcessCheck.isRunning(pid: me, startedAt: started.addingTimeInterval(-3600)))
        // Nothing recorded is not the same as gone, and must not read as running.
        #expect(!ProcessCheck.isRunning(pid: nil, startedAt: started))
        #expect(!ProcessCheck.isRunning(pid: me, startedAt: nil))
    }

    /// An agent that never said what it runs in is not dead; the factory simply cannot
    /// speak for it, and must not put a stopped mark on a working agent.
    @Test func anAgentThatNeverReportedAPidIsNotCalledDead() throws {
        var quiet = Agent(number: 1, projectID: nil)
        #expect(!quiet.knowsItsProcess)
        #expect(!quiet.hasExited)

        let me = ProcessInfo.processInfo.processIdentifier
        quiet.pid = me
        quiet.pidStartedAt = try #require(ProcessCheck.startTime(of: me))
        #expect(quiet.knowsItsProcess)
        #expect(quiet.isProcessRunning)
        #expect(!quiet.hasExited)

        // The process it named has gone.
        quiet.pid = 0x7FFF_FFFE
        #expect(quiet.hasExited)

        // And an agent that said goodbye is gone, not exited: it left on purpose.
        quiet.deregistered = .now
        #expect(!quiet.hasExited)
    }

    /// A record written before any of this decodes, and reads as an agent whose running
    /// the factory cannot speak for.
    @Test func aRecordFromBeforeThisHasNoPid() throws {
        var agent = Agent(number: 4, projectID: nil)
        agent.pid = 123
        agent.pidStartedAt = .now
        var json = try #require(try JSONSerialization.jsonObject(with: FileStore.encoder.encode(agent)) as? [String: Any])
        json.removeValue(forKey: "pid")
        json.removeValue(forKey: "pidStartedAt")
        let decoded = try FileStore.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.pid == nil && decoded.pidStartedAt == nil)
        #expect(!decoded.knowsItsProcess && !decoded.hasExited)
    }

    /// The floor reads it. A crashed agent is stopped, not waiting and not merely quiet,
    /// and it says so however recently it last spoke.
    @Test func anAgentWhoseProcessHasGoneReadsStopped() throws {
        let now = Date()
        let me = ProcessInfo.processInfo.processIdentifier
        var live = Agent(number: 1, projectID: nil, registered: now.addingTimeInterval(-60))
        live.lastSeen = now
        live.pid = me
        live.pidStartedAt = try #require(ProcessCheck.startTime(of: me))
        #expect(Dashboard.activity(of: live, task: nil, hasOpenQuestion: false, now: now) == .waiting)

        // Same agent, same heartbeat a moment ago, but its process has gone.
        var dead = live
        dead.pid = 0x7FFF_FFFE
        #expect(Dashboard.activity(of: dead, task: nil, hasOpenQuestion: false, now: now) == .stopped)

        // An agent that never said what it runs in is not called stopped.
        var unknown = live
        unknown.pid = nil
        unknown.pidStartedAt = nil
        #expect(Dashboard.activity(of: unknown, task: nil, hasOpenQuestion: false, now: now) == .waiting)
    }
}
