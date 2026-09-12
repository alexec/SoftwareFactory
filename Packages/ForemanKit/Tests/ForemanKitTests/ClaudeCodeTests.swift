import Foundation
import Testing
@testable import ForemanKit

@Suite struct ClaudeCodeTests {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
        let live = root.appending(path: "projects/-Users-alex-Where")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)

        // A running session whose transcript started in a scratch folder and moved.
        try Data("""
        {"pid":4242,"sessionId":"live-1","cwd":"/Users/alex/Where","startedAt":1789228319747,"name":"where-12"}
        """.utf8).write(to: root.appending(path: "sessions/4242.json"))
        try Data("""
        {"type":"user","cwd":"/Users/alex/scratch-workspaces/x","message":{"role":"user","content":"<system-reminder>\\nignore me\\n</system-reminder>\\n\\nWork in /Users/alex/Where. Fix the rooms."},"timestamp":"2026-09-11T23:09:43.735Z"}
        {"type":"assistant","cwd":"/Users/alex/Where","message":{"role":"assistant","content":[{"type":"text","text":"Sure"}]}}
        {"type":"user","cwd":"/Users/alex/Where","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
        {"type":"user","isMeta":true,"cwd":"/Users/alex/Where","message":{"role":"user","content":"a hook"}}
        {"type":"last-prompt","sessionId":"live-1"}
        """.utf8).write(to: live.appending(path: "live-1.jsonl"))

        // A session with no registry entry: ended.
        try Data("""
        {"type":"user","cwd":"/Users/alex/Packed","message":{"role":"user","content":"Make the weather bigger\\nand bluer"},"timestamp":"2026-09-11T23:09:43.735Z"}
        """.utf8).write(to: live.appending(path: "old-2.jsonl"))

        // A registry entry whose process is gone.
        try Data("""
        {"pid":1,"sessionId":"dead-3","cwd":"/Users/alex/Daily","startedAt":1789228319747}
        """.utf8).write(to: root.appending(path: "sessions/1.json"))
        return root
    }

    @Test func findsLiveEndedAndDeadSessions() throws {
        let root = try fixture()
        let scanner = ClaudeCodeScanner(root: root, isProcessAlive: { $0 == 4242 })
        let sessions = try scanner.scan(now: .now)
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        let live = try #require(byID["live-1"])
        #expect(live.isLive)
        #expect(live.pid == 4242)
        #expect(live.cwd == "/Users/alex/Where")
        #expect(live.name == "where-12")
        #expect(live.lastPrompt == "Work in /Users/alex/Where. Fix the rooms.")

        let old = try #require(byID["old-2"])
        #expect(!old.isLive)
        #expect(old.cwd == "/Users/alex/Packed")
        #expect(old.lastPrompt == "Make the weather bigger")

        let dead = try #require(byID["dead-3"])
        #expect(!dead.isLive)
    }

    @Test func activityFollowsTheTranscriptClock() {
        let now = Date()
        let fresh = AgentSession(id: "a", cwd: "/a", lastActivity: now.addingTimeInterval(-30), isLive: true)
        let quiet = AgentSession(id: "b", cwd: "/b", lastActivity: now.addingTimeInterval(-300), isLive: true)
        let gone = AgentSession(id: "c", cwd: "/c", lastActivity: now, isLive: false)
        #expect(fresh.activity(now: now) == .working)
        #expect(quiet.activity(now: now) == .waiting)
        #expect(gone.activity(now: now) == .ended)
    }

    @Test func tailReadingDropsThePartialFirstLine() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString).jsonl")
        var text = ""
        for n in 0..<2000 { text += "{\"type\":\"user\",\"cwd\":\"/n/\(n)\",\"message\":{\"role\":\"user\",\"content\":\"p\(n)\"}}\n" }
        try Data(text.utf8).write(to: url)
        let scanner = ClaudeCodeScanner(root: url, tailBytes: 500)
        let tail = ClaudeCodeScanner.parseTail(scanner.readTail(of: url))
        #expect(tail.cwd == "/n/1999")
        #expect(tail.lastPrompt == "p1999")
    }

    @Test func promptsThatAreNotAPersonAreSkipped() {
        #expect(ClaudeCodeScanner.humanPrompt(["type": "user", "message": ["content": "<command-name>/foo</command-name>"]]) == nil)
        #expect(ClaudeCodeScanner.humanPrompt(["type": "assistant", "message": ["content": "x"]]) == nil)
        #expect(ClaudeCodeScanner.humanPrompt(["type": "user", "isSidechain": true, "message": ["content": "x"]]) == nil)
        let long = String(repeating: "a", count: 300)
        #expect(ClaudeCodeScanner.humanPrompt(["type": "user", "message": ["content": long]])?.count == 161)
    }

    @Test func theCurrentProcessExists() {
        #expect(ClaudeCodeScanner.processExists(ProcessInfo.processInfo.processIdentifier))
        #expect(!ClaudeCodeScanner.processExists(2_000_000))
    }
}
