import SwiftUI

struct SettingsView: View {
    @State private var deepgramKey = ""
    @State private var anthropicKey = ""
    @State private var deepgramStatus: KeyStatus = .unknown
    @State private var anthropicStatus: KeyStatus = .unknown

    enum KeyStatus: Equatable {
        case unknown, checking, valid, invalid, error(String)

        var label: (text: String, color: Color)? {
            switch self {
            case .unknown: return nil
            case .checking: return ("Checking…", .secondary)
            case .valid: return ("Valid ✓", .green)
            case .invalid: return ("Invalid key", .red)
            case .error(let message): return ("Error: \(message)", .orange)
            }
        }
    }

    var body: some View {
        Form {
            Section("Deepgram (live transcription)") {
                keyRow(key: $deepgramKey, status: deepgramStatus) {
                    validateDeepgram()
                }
            }
            Section("Anthropic (AI notes & chat)") {
                keyRow(key: $anthropicKey, status: anthropicStatus) {
                    validateAnthropic()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear {
            deepgramKey = KeychainStore.get(.deepgram) ?? ""
            anthropicKey = KeychainStore.get(.anthropic) ?? ""
        }
    }

    @ViewBuilder
    private func keyRow(key: Binding<String>, status: KeyStatus, validate: @escaping () -> Void) -> some View {
        HStack {
            SecureField("API key", text: key)
                .textFieldStyle(.roundedBorder)
            Button("Save & Validate", action: validate)
                .disabled(key.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let label = status.label {
            Text(label.text)
                .font(.caption)
                .foregroundStyle(label.color)
        }
    }

    private func validateDeepgram() {
        KeychainStore.set(deepgramKey, for: .deepgram)
        deepgramStatus = .checking
        let key = deepgramKey
        Task {
            let result = await TranscriptionService.validateKey(key)
            await MainActor.run {
                switch result {
                case .valid: deepgramStatus = .valid
                case .invalidKey: deepgramStatus = .invalid
                case .failed(let message): deepgramStatus = .error(message)
                }
            }
        }
    }

    private func validateAnthropic() {
        KeychainStore.set(anthropicKey, for: .anthropic)
        anthropicStatus = .checking
        let key = anthropicKey
        Task {
            let result = await AIService.validateKey(key)
            await MainActor.run {
                switch result {
                case .valid: anthropicStatus = .valid
                case .invalidKey: anthropicStatus = .invalid
                case .failed(let message): anthropicStatus = .error(message)
                }
            }
        }
    }
}
