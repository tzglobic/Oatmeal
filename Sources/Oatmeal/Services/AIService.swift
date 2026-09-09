import Foundation

/// Claude API client (raw URLSession — no official Swift SDK).
/// Validates credentials and generates notes, titles, and speaker names.
enum AIService {
    /// Model used for note enhancement, title generation, and speaker identification.
    static let model = "claude-sonnet-5"

    private static let baseURL = URL(string: "https://api.anthropic.com/v1")!
    private static let apiVersion = "2023-06-01"

    enum ValidationResult: Equatable {
        case valid
        case invalidKey
        case failed(String)
    }

    /// Cheapest way to validate a key: GET /v1/models is free and returns
    /// 401 for a bad key, 200 for a good one.
    static func validateKey(_ key: String) async -> ValidationResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Unexpected response")
            }
            switch http.statusCode {
            case 200: return .valid
            case 401: return .invalidKey
            default: return .failed("HTTP \(http.statusCode)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Messages API

    enum AIError: LocalizedError {
        case missingKey
        case refused
        case empty
        case api(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add your Anthropic API key in Settings (⌘,) first."
            case .refused: return "The AI declined to process this content."
            case .empty: return "The AI returned an empty response."
            case .api(let message): return message
            }
        }
    }

    private struct MessagesRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Thinking: Encodable {
            let type: String
        }
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
        let thinking: Thinking?
    }

    private struct MessagesResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    private struct APIErrorResponse: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    /// One-shot completion against the Messages API.
    /// `disableThinking` suits tiny deterministic outputs (titles) where adaptive
    /// thinking would eat the token budget.
    static func complete(system: String, user: String, maxTokens: Int = 16_000,
                         disableThinking: Bool = false) async throws -> String {
        guard let key = KeychainStore.get(.anthropic), !key.isEmpty else {
            throw AIError.missingKey
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 300
        request.httpBody = try JSONEncoder().encode(MessagesRequest(
            model: model, max_tokens: maxTokens, system: system,
            messages: [.init(role: "user", content: user)],
            thinking: disableThinking ? .init(type: "disabled") : nil))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.api("Unexpected response")
        }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.message
            throw AIError.api(message ?? "HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        if decoded.stop_reason == "refusal" { throw AIError.refused }
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    /// Note enhancement: user's raw notes + transcript → polished notes.
    static func enhanceNotes(userNotes: String, transcript: String,
                             template: NoteTemplate) async throws -> String {
        let trimmedNotes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = """
            ## My raw notes
            \(trimmedNotes.isEmpty ? "(none — work from the transcript alone)" : trimmedNotes)

            ## Transcript
            \(transcript.isEmpty ? "(no transcript)" : transcript)
            """
        return try await complete(system: template.systemPrompt, user: input)
    }

    /// Infers real names for diarized "them*" speakers from the transcript
    /// (self-introductions, how participants address each other), preferring
    /// matches against the calendar attendee list. Returns speakerKey → name;
    /// uncertain speakers are omitted.
    static func identifySpeakers(transcript: String, attendees: [String]) async throws -> [String: String] {
        let attendeeLine = attendees.isEmpty
            ? "(no attendee list available)"
            : attendees.joined(separator: ", ")
        let input = """
            Attendees: \(attendeeLine)

            Transcript (each line is prefixed with its speaker key):
            \(String(transcript.prefix(24_000)))
            """
        let raw = try await complete(
            system: """
                You identify meeting speakers. The transcript labels each line with a \
                speaker key: "me" is the note-taker, and "them", "them0", "them1", … are \
                other participants. Infer the real name of each them-key from \
                self-introductions ("hi, it's Sarah"), how others address them \
                ("thanks, John"), and context. When an attendee list is provided, prefer \
                matching to those exact names. Output ONLY a JSON object mapping speaker \
                keys to names, e.g. {"them0": "Sarah Chen", "them1": "John Doe"}. \
                Include only speakers you are reasonably confident about — omit the \
                rest. If nothing can be inferred, output {}.
                """,
            user: input,
            maxTokens: 400,
            disableThinking: true)

        // Tolerate stray prose or code fences around the JSON object.
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return mapping
    }

    /// Short descriptive title for the sidebar, replacing "Meeting Jul 6, 2:14 PM".
    static func generateTitle(userNotes: String, transcript: String) async throws -> String {
        let input = String("\(userNotes)\n\(transcript)".prefix(6_000))
        let raw = try await complete(
            system: "Generate a concise 3-6 word title for this meeting based on its notes and transcript. Output only the title itself — no quotes, no trailing punctuation, no explanation.",
            user: input,
            maxTokens: 100,
            disableThinking: true)
        let title = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        return String(title.prefix(60))
    }
}
