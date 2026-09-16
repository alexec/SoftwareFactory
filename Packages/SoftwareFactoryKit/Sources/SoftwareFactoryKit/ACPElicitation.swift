import Foundation

public extension ACP {
    /// The agent asking the person a question, `elicitation/create`.
    ///
    /// This is the same thing `escalation_raise` is, arriving down the other pipe, so it
    /// becomes an `Escalation` and everything downstream is unchanged: the Needs you
    /// strip, the banner, the phone, the Lock Screen. The factory's own question is the
    /// shape ACP describes rather than a second idea with the same job. (T373.)
    ///
    /// Only Claude Code sends these. Asked the same question with the capability
    /// declared, Copilot and Grok answer in prose and end the turn, which is a question
    /// the floor cannot see. So this is a better path where it exists and never the only
    /// one: `escalation_raise` stays, because three of four need it and an external agent
    /// has no pipe at all. (Measured 16 Sep 2026.)
    struct Elicitation: Sendable, Equatable {
        public var sessionID: String
        /// The question, in the agent's own words.
        public var message: String
        /// The field the answer goes back under, `question_0`.
        public var field: String
        /// What it is asking about, if it named it: the field's title.
        public var about: String?
        public var options: [Choice]
        /// The field for an answer in the person's own words, when the agent offered one.
        /// The factory has had this since 12 Sep and so, it turns out, has ACP.
        public var customField: String?
        /// Which tool call it belongs to, for the record.
        public var toolCallID: String?

        public init(sessionID: String, message: String, field: String, about: String? = nil,
                    options: [Choice], customField: String? = nil, toolCallID: String? = nil) {
            self.sessionID = sessionID
            self.message = message
            self.field = field
            self.about = about
            self.options = options
            self.customField = customField
            self.toolCallID = toolCallID
        }

        public struct Choice: Sendable, Equatable {
            /// What goes back on the wire.
            public var value: String
            /// What the person reads.
            public var title: String
            /// The line under it, when the agent gave a reason.
            public var detail: String

            public init(value: String, title: String, detail: String = "") {
                self.value = value
                self.title = title
                self.detail = detail
            }
        }

        /// Reads one, or nil for anything this factory cannot put in front of a person:
        /// a url-mode request, or a form with no choices in it. Refusing is better than
        /// showing a question with no answers on it.
        public static func read(_ params: [String: Any]) -> Elicitation? {
            guard (params["mode"] as? String ?? "form") == "form" else { return nil }
            guard let session = params["sessionId"] as? String,
                  let schema = params["requestedSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any]
            else { return nil }

            // The answerable field is the first one carrying choices. The others are the
            // free-text companions, which are marked and are not questions on their own.
            let names = properties.keys.sorted()
            var field: String?
            var choices: [Choice] = []
            var about: String?
            for name in names {
                guard let body = properties[name] as? [String: Any] else { continue }
                let listed = (body["oneOf"] as? [[String: Any]])
                    ?? ((body["items"] as? [String: Any])?["anyOf"] as? [[String: Any]])
                guard let listed, !listed.isEmpty else { continue }
                field = name
                about = body["title"] as? String
                choices = listed.compactMap { one in
                    guard let value = one["const"] as? String ?? one["title"] as? String
                    else { return nil }
                    return Choice(value: value,
                                  title: one["title"] as? String ?? value,
                                  detail: one["description"] as? String ?? "")
                }
                break
            }
            guard let field, !choices.isEmpty else { return nil }

            // The companion field for an answer in the person's own words. Named by a
            // `_meta` marker the agents share rather than by its name, which is theirs.
            let custom = names.first { name in
                guard name != field, let body = properties[name] as? [String: Any],
                      let meta = body["_meta"] as? [String: Any] else { return false }
                return meta.keys.contains { $0.lowercased().contains("customanswer") }
            }

            return Elicitation(
                sessionID: session,
                message: (params["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                field: field,
                about: about,
                options: choices,
                customField: custom,
                toolCallID: params["toolCallId"] as? String)
        }

        /// The question as the factory files it, so one record serves both ways of asking
        /// and every page already knows how to draw it.
        public func asEscalation(projectID: String, agentID: UUID?, raisedBy: String,
                                 reference: String) -> Escalation {
            var question = Escalation(
                projectID: projectID,
                question: message.isEmpty ? (about ?? "It wants your answer.") : message,
                context: "It is waiting on your answer and doing nothing until it has one.",
                options: options.map { Escalation.Option(title: $0.title, detail: $0.detail) },
                agentID: agentID,
                raisedBy: raisedBy)
            question.reference = reference
            return question
        }

        /// Our answer: the option they picked, or their own words in the field the agent
        /// offered for them. Words with no field to put them in go under the option, which
        /// is the closest thing to the truth available.
        public func answer(option: String?, words: String = "") -> [String: Any] {
            let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
            var content: [String: Any] = [:]
            if let option { content[field] = option }
            if !said.isEmpty {
                if let customField {
                    content[customField] = said
                } else if option == nil {
                    content[field] = said
                }
            }
            guard !content.isEmpty else { return declined }
            return ["action": "accept", "content": content]
        }

        /// Nobody is going to answer. The agent stops asking rather than waiting for ever.
        public var declined: [String: Any] { ["action": "decline"] }
    }

    /// What the factory tells an agent it can do. Elicitation is declared, so an agent
    /// that has a question can ask it: Claude Code's own question tool is switched off by
    /// its adapter unless a client says it can show a form, which means the factory was
    /// the reason it could not ask. (Measured 16 Sep 2026.)
    static var clientCapabilities: [String: Any] {
        [
            "fs": ["readTextFile": false, "writeTextFile": false],
            "terminal": false,
            "elicitation": ["form": [:]],
        ]
    }
}
