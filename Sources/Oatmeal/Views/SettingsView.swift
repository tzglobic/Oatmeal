import SwiftUI
import AVFoundation
import CoreGraphics
import EventKit

/// One-glance health panel: are the permissions and keys this app needs in place?
struct PermissionsHealthView: View {
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var screenGranted = false
    @State private var calendarStatus: EKAuthorizationStatus = .notDetermined
    @State private var hasDeepgramKey = false
    @State private var hasAnthropicKey = false

    var body: some View {
        Section {
            statusRow(ok: micStatus == .authorized,
                      pending: micStatus == .notDetermined,
                      title: "Microphone",
                      detail: micStatus == .authorized ? "Granted"
                            : micStatus == .notDetermined ? "Not requested yet — press Record once"
                            : "Denied") {
                openPrivacyPane("Privacy_Microphone")
            }
            statusRow(ok: screenGranted,
                      pending: false,
                      title: "Screen & System Audio Recording",
                      detail: screenGranted ? "Granted"
                            : "Not granted — needed to capture meeting audio (no video is recorded)") {
                openPrivacyPane("Privacy_ScreenCapture")
            }
            statusRow(ok: calendarStatus == .fullAccess,
                      pending: calendarStatus == .notDetermined,
                      title: "Calendar (Outlook / Teams)",
                      detail: calendarStatus == .fullAccess
                            ? "Granted — Outlook events appear once the account is in System Settings → Internet Accounts"
                            : calendarStatus == .notDetermined ? "Not requested yet"
                            : "Denied — Up Next and auto-titling are off") {
                if calendarStatus == .notDetermined {
                    Task {
                        await CalendarService.shared.requestAccessAndStart()
                        refresh()
                    }
                } else {
                    openPrivacyPane("Privacy_Calendars")
                }
            }
            statusRow(ok: hasDeepgramKey, pending: false,
                      title: "Deepgram API key",
                      detail: hasDeepgramKey ? "Saved in Keychain" : "Missing — add it below", action: nil)
            statusRow(ok: hasAnthropicKey, pending: false,
                      title: "Anthropic API key",
                      detail: hasAnthropicKey ? "Saved in Keychain" : "Missing — add it below", action: nil)
        } header: {
            HStack {
                Text("Health")
                Spacer()
                Button("Refresh") { refresh() }
                    .font(.caption)
            }
        } footer: {
            Text("A Screen Recording grant only takes effect after relaunching Oatmeal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
    }

    @ViewBuilder
    private func statusRow(ok: Bool, pending: Bool, title: String, detail: String,
                           action: (() -> Void)?) -> some View {
        HStack {
            Circle()
                .fill(ok ? Color.green : pending ? Color.orange : Color.red)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok, let action {
                Button("Open Settings", action: action)
                    .font(.caption)
            }
        }
    }

    private func refresh() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        screenGranted = CGPreflightScreenCaptureAccess()
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        hasDeepgramKey = !(KeychainStore.get(.deepgram) ?? "").isEmpty
        hasAnthropicKey = !(KeychainStore.get(.anthropic) ?? "").isEmpty
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsView: View {
    @State private var deepgramKey = ""
    @State private var anthropicKey = ""
    @State private var deepgramStatus: KeyStatus = .unknown
    @State private var anthropicStatus: KeyStatus = .unknown
    /// Same key MeetingEndDetector reads, so the toggle is the single source of truth.
    @AppStorage("autoStopWhenMeetingEnds") private var autoStop = true

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
            PermissionsHealthView()
            Section("Recording") {
                Toggle("Ask before leaving a finished meeting recording", isOn: $autoStop)
                Text("""
                    When the calendar event has ended and nobody has spoken for a few minutes \
                    — or nobody has spoken at all for 15 — Oatmeal asks whether the meeting is \
                    over and stops after 60 seconds if you don't answer.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
