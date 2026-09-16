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
        #expect(Dashboard.activity(of: live, task: nil, hasOpenQuestion: false, now: now) == .working)

        // Same agent, same heartbeat a moment ago, but its process has gone.
        var dead = live
        dead.pid = 0x7FFF_FFFE
        #expect(Dashboard.activity(of: dead, task: nil, hasOpenQuestion: false, now: now) == .stopped)

        // An agent that never said what it runs in is not called stopped.
        var unknown = live
        unknown.pid = nil
        unknown.pidStartedAt = nil
        #expect(Dashboard.activity(of: unknown, task: nil, hasOpenQuestion: false, now: now) == .working)
    }

    /// Stopping an agent stops its process, and stops nothing else. A pid whose start
    /// time does not match is somebody else wearing a recycled number, and signalling it
    /// would kill a stranger's work. (T261.)
    @Test func stoppingSignalsOnlyTheProcessTheRecordNames() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(filePath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        let started = try #require(ProcessCheck.startTime(of: pid))
        #expect(ProcessCheck.isRunning(pid: pid, startedAt: started))

        // A start time that does not match: not this process, so nothing is sent.
        #expect(!ProcessCheck.stop(pid: pid, startedAt: started.addingTimeInterval(-3600)))
        #expect(ProcessCheck.isRunning(pid: pid, startedAt: started))
        // Nothing recorded at all: nothing to stop.
        #expect(!ProcessCheck.stop(pid: nil, startedAt: started))

        // The pair matches, so it goes.
        #expect(ProcessCheck.stop(pid: pid, startedAt: started))
        sleeper.waitUntilExit()
        #expect(!ProcessCheck.isRunning(pid: pid, startedAt: started))
        // And stopping one that has already gone is not an error, it is simply nothing.
        #expect(!ProcessCheck.stop(pid: pid, startedAt: started))
    }

    /// Start is the other half of Stop: offered for an agent the factory launched and
    /// then watched stop, never for one still running and never for one it never had a
    /// process for. The CLI that started it is written down, because its conversation is
    /// only in that one. (T262.)
    @Test func startIsOfferedForAnAgentTheFactoryWatchedStop() throws {
        let now = Date()
        let me = ProcessInfo.processInfo.processIdentifier
        var live = Agent(number: 1, projectID: "/w", registered: now.addingTimeInterval(-60))
        live.lastSeen = now
        live.pid = me
        live.pidStartedAt = try #require(ProcessCheck.startTime(of: me))
        live.launchedWith = LaunchAgent.claudeCode.rawValue
        #expect(!Agents.mayResume(live))

        var stopped = live
        stopped.pid = 0x7FFF_FFFE
        #expect(Agents.mayResume(stopped))
        #expect(Agents.mayStop(live) != Agents.mayResume(live))
        #expect(LaunchAgent(rawValue: stopped.launchedWith ?? "") == .claudeCode)

        // Nothing was ever launched here, so there is nothing to start.
        var external = stopped
        external.pid = nil
        external.pidStartedAt = nil
        #expect(!Agents.mayResume(external))

        var gone = stopped
        gone.deregistered = now
        #expect(!Agents.mayResume(gone))

        // An agent from before the CLI was written down still starts; it takes the last
        // one the person picked.
        var older = stopped
        older.launchedWith = nil
        #expect(Agents.mayResume(older))
        #expect(LaunchAgent.remembered(older.launchedWith) == .claudeCode)

        // And it survives a trip through the store's shape.
        let read = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(stopped))
        #expect(read.launchedWith == LaunchAgent.claudeCode.rawValue)
    }

    /// Stop is offered for a process the factory knows and can still reach. An agent
    /// that registered from somewhere else never told us one, and one whose process has
    /// already gone has nothing left to stop. (T261.)
    @Test func stopIsOfferedOnlyForAProcessTheFactoryKnows() throws {
        let now = Date()
        let me = ProcessInfo.processInfo.processIdentifier
        var live = Agent(number: 1, projectID: nil, registered: now.addingTimeInterval(-60))
        live.lastSeen = now
        live.pid = me
        live.pidStartedAt = try #require(ProcessCheck.startTime(of: me))
        #expect(Agents.mayStop(live))

        // Registered over MCP from wherever it already was: nothing here to stop.
        var external = live
        external.pid = nil
        external.pidStartedAt = nil
        #expect(!Agents.mayStop(external))

        // Its process has gone. Stop would be a button that does nothing.
        var dead = live
        dead.pid = 0x7FFF_FFFE
        #expect(!Agents.mayStop(dead))

        // And one that has left the factory.
        var gone = live
        gone.deregistered = now
        #expect(!Agents.mayStop(gone))

        // The floor asks the same question. A quiet agent can still be stopped: silence
        // is not an exit, and stopping a thinking agent is exactly what the button is
        // for.
        var quiet = live
        quiet.lastSeen = now.addingTimeInterval(-700)
        let snapshot = Snapshot(agents: [quiet])
        let status = Dashboard.make(snapshot: snapshot, now: now).agents[0]
        #expect(status.activity == .finished)
        #expect(status.canStop)
        #expect(!Dashboard.make(snapshot: Snapshot(agents: [external]), now: now).agents[0].canStop)
    }

    /// The session is the agent, so two agents cannot land on one terminal: there is no
    /// separate name to collide over. This is what T156 used to arbitrate, gone by
    /// construction rather than by a rule.
    @Test func aSessionIsOneAgentAndCannotBeShared() {
        let one = Agents.reserve(number: 1, projectID: "/p")
        let two = Agents.reserve(number: 2, projectID: "/p")
        #expect(one.id != two.id)
        // What the factory calls it, what the terminal is called, and what the agent
        // says on every call are all one string.
        #expect(one.label == "A1")
        #expect(!one.id.uuidString.isEmpty)
        // Reserved before it registers, and already itself: the record is the session.
        #expect(one.isRegistered && !one.isConnected)
    }
}

@Suite("The floor in two groups")
struct FloorGroupingTests {
    /// The sidebar shows the agents that are running apart from the ones that have
    /// stopped. Both stay on the floor: a stopped agent can be started back up. (T268.)
    @Test func runningAndStoppedAreSeparate() {
        let now = Date()
        var running = Agent(id: UUID(), number: 1, projectID: nil, registered: now)
        running.lastSeen = now
        running.isConnected = true
        running.pid = ProcessInfo.processInfo.processIdentifier
        running.pidStartedAt = ProcessCheck.startTime(of: running.pid!)

        var stopped = Agent(id: UUID(), number: 2, projectID: nil, registered: now)
        stopped.lastSeen = now
        stopped.pid = 0x7FFF_FFFE
        stopped.pidStartedAt = now

        let dashboard = Dashboard.make(snapshot: Snapshot(agents: [running, stopped]), now: now)
        #expect(dashboard.agents.count == 2)
        #expect(dashboard.runningAgents.map(\.agent.number) == [1])
        #expect(dashboard.stoppedAgents.map(\.agent.number) == [2])
    }

    /// Nothing is lost between the two groups, whatever an agent is doing.
    @Test func everyAgentIsInOneGroup() {
        let now = Date()
        var quiet = Agent(id: UUID(), number: 3, projectID: nil, registered: now)
        quiet.lastSeen = now.addingTimeInterval(-700)
        let dashboard = Dashboard.make(snapshot: Snapshot(agents: [quiet]), now: now)
        #expect(dashboard.runningAgents.count + dashboard.stoppedAgents.count == dashboard.agents.count)
        #expect(dashboard.stoppedAgents.isEmpty)
    }
}

/// The factory's own process, and quitting it by pid rather than by name. (T271.)
@Suite("The app's own process")
struct FactoryProcessTests {
    @Test func currentIsThisProcessAndReadsAsRunning() {
        let me = FactoryProcess.current()
        #expect(me != nil)
        #expect(me?.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(me?.isRunning == true)
    }

    /// The pair is what makes it trustworthy: a record whose start time does not match
    /// the process now wearing that pid is a record about somebody else, and nothing is
    /// sent to it. This is the same rule `stop` follows, and it matters more here,
    /// because a quit event sent to a stranger closes their work.
    @Test func aMismatchedStartTimeIsNotThisProcess() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let wrong = FactoryProcess(pid: pid, startedAt: Date(timeIntervalSince1970: 1))
        #expect(!wrong.isRunning)
        #expect(!ProcessCheck.quit(pid: wrong.pid, startedAt: wrong.startedAt))
    }

    @Test func aPidNobodyIsUsingIsNotQuit() {
        #expect(!ProcessCheck.quit(pid: 0x7FFF_FFFE, startedAt: Date()))
        #expect(!ProcessCheck.quit(pid: nil, startedAt: nil))
    }

    /// It survives a write and a read, so the app can say which process it is and a
    /// shell can pick it up.
    @Test func itIsWrittenDownAndReadBack() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let store = try FileStore(root: root)
        #expect(store.factoryProcess() == nil)
        let me = try #require(FactoryProcess.current())
        try store.save(me)
        let read = try #require(store.factoryProcess())
        #expect(read.pid == me.pid)
        // The store writes dates as ISO 8601, which keeps whole seconds, so a start time
        // comes back up to a second early. That is why `isRunning` compares with a
        // second of slack rather than for equality, and why what matters here is that
        // the record still answers for the process it was written about.
        #expect(abs(read.startedAt.timeIntervalSince(me.startedAt)) < 1)
        #expect(read.isRunning)
        try? FileManager.default.removeItem(at: root)
    }
}
