import Foundation

/// Deepgram client. Phase 0: key validation.
/// Phase 1: two live-streaming WebSocket connections (mic + system audio).
enum TranscriptionService {
    enum ValidationResult: Equatable {
        case valid
        case invalidKey
        case failed(String)
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
