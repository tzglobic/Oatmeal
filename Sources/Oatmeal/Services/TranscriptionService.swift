import Foundation

/// Deepgram client. Phase 0: key validation.
/// Phase 1: two live-streaming WebSocket connections (mic + system audio).
enum TranscriptionService {
    enum ValidationResult: Equatable {
        case valid
        case invalidKey
        case failed(String)
    }

    enum RetranscribeError: LocalizedError {
        case missingKey
        case noAudioFile
        case api(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add your Deepgram API key in Settings (⌘,) first."
            case .noAudioFile: return "This meeting has no audio recording to re-transcribe."
            case .api(let message): return "Re-transcription failed: \(message)"
            }
        }
    }

    struct Utterance {
        let channel: Int
        let speakerIndex: Int?
        let start: Double
        let end: Double
        let text: String
    }

    private struct PrerecordedResponse: Decodable {
        struct Results: Decodable {
            struct DGUtterance: Decodable {
                let start: Double
                let end: Double
                let transcript: String
                let channel: Int
                let speaker: Int?
            }
            let utterances: [DGUtterance]?
        }
        let results: Results?
    }

    /// Batch re-transcription of the per-meeting .m4a fallback recording
    /// (stereo: ch0 = mic, ch1 = system audio). Cheaper than live streaming and
    /// rescues meetings whose live connection dropped.
    static func retranscribe(fileURL: URL) async throws -> [Utterance] {
        guard let apiKey = KeychainStore.get(.deepgram), !apiKey.isEmpty else {
            throw RetranscribeError.missingKey
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RetranscribeError.noAudioFile
        }

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            .init(name: "model", value: "nova-3"),
            .init(name: "smart_format", value: "true"),
            .init(name: "multichannel", value: "true"),
            .init(name: "utterances", value: "true"),
            .init(name: "diarize", value: "true"),
            .init(name: "diarize_model", value: "latest"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw RetranscribeError.api("unexpected response")
        }
        guard http.statusCode == 200 else {
            throw RetranscribeError.api("HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(PrerecordedResponse.self, from: data)
        return (decoded.results?.utterances ?? []).compactMap { u in
            let text = u.transcript.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return Utterance(channel: u.channel, speakerIndex: u.speaker,
                             start: u.start, end: u.end, text: text)
        }
    }

    /// GET /v1/auth/token verifies the key without incurring usage.
    static func validateKey(_ key: String) async -> ValidationResult {
        var request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/auth/token")!)
        request.httpMethod = "GET"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Unexpected response")
            }
            switch http.statusCode {
            case 200: return .valid
            case 401, 403: return .invalidKey
            default: return .failed("HTTP \(http.statusCode)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
