import Foundation
import Testing
@testable import Core

/// Reading what the tools leave behind. The first cases are the
/// session-history script's own self-test, ported line for line.
struct AgentSessionTests {
    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    @Test("a Claude transcript's title is its first user message that is not a command, whitespace collapsed")
    func claudeScan() throws {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        let file = paths.sessions.appending(path: "-repo/c.jsonl")
        try write(try line(["type": "user", "message": ["role": "user", "content": "<command-name>/x</command-name>"],
                            "cwd": "/repo"])
                  + line(["type": "user", "message": ["role": "user",
                                                      "content": [["type": "text", "text": "hello  there"]]]]),
                  to: file)
        let sessions = AgentSession.list(paths)
        #expect(sessions.map(\.title) == ["hello there"])
        #expect(sessions.first?.cwd == "/repo")
        #expect(sessions.first?.id == "c")
        #expect(sessions.first?.resumeCommand == "claude --resume c")
    }

    @Test("a Codex transcript's directory comes from its session_meta and its title from the first input_text")
    func codexScan() throws {
        let paths = AgentPaths(.codex, home: try temporaryHome())
        let file = paths.sessions.appending(path: "2026/01/01/rollout-2026-01-01T00-00-00-abc.jsonl")
        try write(try line(["type": "session_meta", "payload": ["cwd": "/w"]])
                  + line(["payload": ["type": "message", "role": "user",
                                      "content": [["type": "input_text", "text": "hi"]]]]),
                  to: file)
        let sessions = AgentSession.list(paths)
        #expect(sessions.map(\.title) == ["hi"])
        #expect(sessions.first?.cwd == "/w")
    }

    @Test("a session's ID is the last five dash-parts of the file name")
    func sessionID() {
        #expect(AgentSession.sessionID(of: URL(fileURLWithPath:
            "/s/rollout-2026-09-10T20-53-48-01a08b61-aa62-7033-85ce-a51f3d02f605.jsonl"))
            == "01a08b61-aa62-7033-85ce-a51f3d02f605")
        #expect(AgentSession.sessionID(of: URL(fileURLWithPath: "/p/9a4b361f-a550-43cc-a895-1091406172b8.jsonl"))
                == "9a4b361f-a550-43cc-a895-1091406172b8")
    }

    @Test("cleaning drops the tools' own lines and cuts the rest")
    func clean() {
        #expect(AgentSession.clean("<system-reminder> x") == "")
        #expect(AgentSession.clean("Caveat: the messages below") == "")
        #expect(AgentSession.clean("<task-notification> <task-id>x</task-id>") == "")
        #expect(AgentSession.clean("[Image: original 2200x1440, displayed at 2000x1309.]") == "")
        #expect(AgentSession.clean("[Image #52] what is this") == "[Image #52] what is this")
        #expect(AgentSession.clean("  a\n\n b\tc  ") == "a b c")
        #expect(AgentSession.clean(String(repeating: "x", count: 150)).count == 100)
    }

    @Test("sessions Codex opened for itself -- a guardian review, a sub-agent -- are left out")
    func subagentsLeftOut() throws {
        let paths = AgentPaths(.codex, home: try temporaryHome())
        let folder = paths.sessions.appending(path: "2026/10/05")
        let user = try line(["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]])
        try write(try line(["type": "session_meta", "payload": ["cwd": "/a"]]) + user,
                  to: folder.appending(path: "rollout-2026-10-05T10-00-00-aaaa-b-c-d-e.jsonl"))
        try write(try line(["type": "session_meta", "payload": ["cwd": "/a", "parent_thread_id": "aaaa-b-c-d-e",
                                                            "source": ["subagent": ["other": "guardian"]],
                                                            "base_instructions": ["text": String(repeating: "x", count: 200_000)]]])
                  + user,
                  to: folder.appending(path: "rollout-2026-10-05T10-01-00-bbbb-b-c-d-e.jsonl"))
        try write(try line(["type": "session_meta", "payload": ["source": ["subagent": "review"]]]) + user,
                  to: folder.appending(path: "rollout-2026-10-05T10-02-00-cccc-b-c-d-e.jsonl"))
        #expect(AgentSession.list(paths).map(\.id) == ["aaaa-b-c-d-e"])
    }

    @Test("the list is newest first, Codex titles come from the index, and garbage lines are skipped")
    func listing() throws {
        let paths = AgentPaths(.codex, home: try temporaryHome())
        let old = paths.sessions.appending(path: "2026/01/01/rollout-2026-01-01T00-00-00-aaaa-b-c-d-e.jsonl")
        let new = paths.sessions.appending(path: "2026/02/01/rollout-2026-02-01T00-00-00-ffff-b-c-d-e.jsonl")
        try write("not json\n{\"payload\": 3}\n[1,2]\n"
                  + line(["payload": ["type": "message", "role": "user",
                                      "content": [["type": "input_text", "text": "old one"]]]])
                  + "{\"truncated\": ",
                  to: old)
        try write("\n" + line(["type": "session_meta", "payload": ["cwd": "/n"]]), to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)],
                                              ofItemAtPath: new.path)
        try write(line(["id": "ffff-b-c-d-e", "thread_name": "Named  thread", "updated_at": "x"])
                  + "garbage\n" + line(["id": "zzz"]),
                  to: paths.sessionIndex)

        let sessions = AgentSession.list(paths)
        #expect(sessions.map(\.title) == ["Named thread", "old one"])
        #expect(sessions.map(\.cwd) == ["/n", ""])
        #expect(sessions.first?.resumeCommand == "codex resume ffff-b-c-d-e")
        #expect(sessions.last?.size == 
                (try Data(contentsOf: old)).count)
    }

    @Test("a session with nothing to say is titled with a dash")
    func untitled() throws {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        try write("{}\n", to: paths.sessions.appending(path: "-p/u.jsonl"))
        // Not a session: the subdirectory beside it holds attachments.
        try write("{}\n", to: paths.sessions.appending(path: "-p/u/tool.jsonl"))
        #expect(AgentSession.list(paths).map(\.title) == ["\u{2014}"])
    }

    @Test("Claude tokens count each request once; Codex tokens are the last running total")
    func tokens() throws {
        let home = try temporaryHome()
        let claude = AgentPaths(.claude, home: home)
        let usage: [String: Any] = ["input_tokens": 2, "output_tokens": 10,
                                    "cache_read_input_tokens": 100, "cache_creation_input_tokens": 30]
        let response = ["type": "assistant", "requestId": "req_1",
                        "message": ["role": "assistant", "usage": usage, "content": [["type": "thinking"]]]] as [String: Any]
        var second = response
        second["requestId"] = "req_2"
        try write(try line(response) + line(response) + line(second)
                  + line(["type": "user", "message": ["role": "user", "content": "x", "usage": usage]]),
                  to: claude.sessions.appending(path: "-p/a.jsonl"))
        try write(try line(second), to: claude.sessions.appending(path: "-p/b.jsonl"))
        #expect(AgentSession.list(claude).reduce(TokenUsage()) { $0 + $1.tokens }
                == TokenUsage(input: 6, output: 30, cacheRead: 300, cacheWrite: 90))

        let codex = AgentPaths(.codex, home: home)
        func count(_ input: Int) throws -> String {
            try line(["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": input, "cached_input_tokens": 40, "output_tokens": 13,
                "reasoning_output_tokens": 0, "total_tokens": input + 13]]]])
        }
        try write(try count(100) + count(300), to: codex.sessions.appending(path: "2026/01/01/rollout-1-a-b-c-d-e.jsonl"))
        let session = try #require(AgentSession.list(codex).first)
        #expect(session.tokens == TokenUsage(input: 260, output: 13, cacheRead: 40))
        #expect(session.tokens.total == 313)
    }

    @Test("a preview keeps both sides of the conversation, cleaned, and leaves the boilerplate out")
    func transcript() throws {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        let file = paths.sessions.appending(path: "-p/t.jsonl")
        try write(try line(["type": "user", "cwd": "/p", "message": ["role": "user", "content": "<system-reminder>x"]])
                  + line(["type": "user", "message": ["role": "user", "content": "fix   the bug"]])
                  + line(["type": "assistant", "message": ["role": "assistant",
                                                           "content": [["type": "text", "text": "done"], ["type": "tool_use"]]]])
                  + line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "x"]]]]),
                  to: file)
        let session = try #require(AgentSession.list(paths).first)
        let turns = AgentSession.transcript(of: session)
        #expect(turns.map(\.role) == ["user", "assistant"])
        #expect(turns.map(\.text) == ["fix the bug", "done"])
    }

    @Test("a long session's preview is where it is now, not where it began")
    func transcriptTail() throws {
        let paths = AgentPaths(.claude, home: try temporaryHome())
        let file = paths.sessions.appending(path: "-p/t.jsonl")
        let turns = try (0..<700).map { try line(["type": "user", "message": ["role": "user", "content": "turn \($0)"]]) }
        try write(turns.joined(), to: file)
        let session = try #require(AgentSession.list(paths).first)
        let preview = AgentSession.transcript(of: session)
        #expect(preview.last?.text == "turn 699")
        #expect(preview.count == 600)
    }

    @Test("deleting a Codex session drops it from the title index too")
    func delete() throws {
        let paths = AgentPaths(.codex, home: try temporaryHome())
        let file = paths.sessions.appending(path: "2026/01/01/rollout-1-aaaa-b-c-d-e.jsonl")
        try write("{}\n", to: file)
        try write(line(["id": "aaaa-b-c-d-e", "thread_name": "gone"]) + line(["id": "keep-b-c-d-e", "thread_name": "stays"]),
                  to: paths.sessionIndex)
        let session = try #require(AgentSession.list(paths).first)
        try AgentSession.delete(session, paths: paths)
        #expect(AgentSession.list(paths).isEmpty)
        let index = try String(contentsOf: paths.sessionIndex, encoding: .utf8)
        #expect(index.contains("stays") && !index.contains("gone") && index.hasSuffix("\n"))
    }
}

@Test("Claude Code's own title names a session, and one with no word in it is empty")
func claudeTitlesAndEmptySessions() throws {
    let paths = AgentPaths(.claude, home: try temporaryHome())
    let project = paths.sessions.appending(path: "-Users-me-work", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try """
    {"type":"user","message":{"role":"user","content":"first words"},"cwd":"/Users/me/work"}
    {"type":"ai-title","aiTitle":"Old name"}
    {"type":"assistant","requestId":"r1","message":{"role":"assistant","usage":{"input_tokens":5,"output_tokens":2}}}
    {"type":"ai-title","aiTitle":"Final name"}
    """.write(to: project.appending(path: "11111111-1111-1111-1111-111111111111.jsonl"), atomically: true, encoding: .utf8)
    try """
    {"type":"mode","cwd":"/Users/me/work"}
    {"type":"cost-state"}
    """.write(to: project.appending(path: "22222222-2222-2222-2222-222222222222.jsonl"), atomically: true, encoding: .utf8)

    let sessions = AgentSession.list(paths)
    #expect(sessions.count == 2)
    let named = try #require(sessions.first { $0.id.hasPrefix("1111") })
    #expect(named.title == "Final name" && !named.isStale)
    let silent = try #require(sessions.first { $0.id.hasPrefix("2222") })
    #expect(silent.title == "\u{2014}" && silent.isStale)

    // Resumed: a new file beginning with the old one's messages, and more.
    // The old one is stale; the new one, and an unrelated one, are not.
    try """
    {"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"first words"},"cwd":"/Users/me/work"}
    {"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","message":{"role":"assistant","usage":{"input_tokens":5,"output_tokens":2}}}
    {"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":"more"}}
    """.write(to: project.appending(path: "33333333-3333-3333-3333-333333333333.jsonl"), atomically: true, encoding: .utf8)
    try """
    {"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"first words"},"cwd":"/Users/me/work"}
    {"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","message":{"role":"assistant","usage":{"input_tokens":5,"output_tokens":2}}}
    """.write(to: project.appending(path: "44444444-4444-4444-4444-444444444444.jsonl"), atomically: true, encoding: .utf8)
    let again = AgentSession.list(paths)
    #expect(again.first { $0.id.hasPrefix("4444") }?.isStale == true)
    #expect(again.first { $0.id.hasPrefix("3333") }?.isStale == false)
    #expect(again.first { $0.id.hasPrefix("1111") }?.isStale == false)
}
