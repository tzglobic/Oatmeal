import Foundation

/// Claude API client (raw URLSession — no official Swift SDK).
/// Phase 0: key validation. Phase 2+: note enhancement, chat, briefs, recipes.
enum AIService {
    /// Model used for note enhancement and chat, per the project plan ("claude-sonnet").
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

    static func request(path: String, body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(KeychainStore.get(.anthropic) ?? "", forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = body
        return request
    }
}
