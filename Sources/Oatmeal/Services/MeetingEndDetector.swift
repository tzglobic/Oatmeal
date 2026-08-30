import Foundation

/// Notices when a meeting has probably ended so a recording doesn't run on for
/// hours after everyone has hung up.
///
/// No single signal is trustworthy on its own — a calendar block routinely
/// overruns, and a quiet stretch might just be everyone reading a shared
/// document — so an end is only inferred when silence coincides with the
/// calendar saying the event is over, or when the silence has run long enough
/// that no meeting explanation is plausible.
///
/// Inferring the end never stops the recording outright. It opens a
/// `reactionWindow` in which a notification and an in-app banner offer Keep
/// Recording; only when that window closes untouched does the recording stop.
/// Truncating a live meeting is much worse than leaving a few quiet minutes on
/// the end of the .m4a.
@MainActor
final class MeetingEndDetector: ObservableObject {
    /// Shared with the recorder, the banner, and the notification actions —
    /// they all have to be looking at the same countdown.
    static let shared = MeetingEndDetector()

    enum Trigger: Equatable {
        case calendarEndPlusSilence
        case prolongedSilence

        /// Reason shown to the user, phrased to finish "Oatmeal thinks the call
        /// is over — …".
        var summary: String {
            switch self {
            case .calendarEndPlusSilence:
                "the calendar event has ended and nobody has spoken since"
            case .prolongedSilence:
                "nobody has spoken for \(Int(MeetingEndDetector.prolongedSilence / 60)) minutes"
            }
        }
    }

    struct Pending: Equatable {
        let trigger: Trigger
        let deadline: Date
    }

    /// Non-nil while an end has been inferred and the reaction window is open.
    @Published private(set) var pending: Pending?

    /// Called when the reaction window closes untouched, or on Stop & Save.
    var onStop: (() -> Void)?

    // MARK: - Tuning

    /// Level below which a channel counts as quiet. `AudioPipeline` reports RMS
    /// scaled by 6 and clamped to 0…1, so 0.02 sits above room tone and fan
    /// noise and well below speech at any normal level.
    private static let silenceThreshold: Float = 0.02

    /// Silence required after the calendar event's end before inferring an end.
    private static let silenceAfterCalendarEnd: TimeInterval = 3 * 60

    /// Meetings routinely run a little over, so the calendar's end time alone
    /// means nothing until this much has passed.
    private static let calendarGrace: TimeInterval = 2 * 60

    /// Silence required when there is no calendar event to corroborate it.
    nonisolated static let prolongedSilence: TimeInterval = 15 * 60

    /// How long the user has to react before the recording actually stops.
    nonisolated static let reactionWindow: TimeInterval = 60

    /// After Keep Recording, stay quiet this long before inferring an end again
    /// — one dismissed banner shouldn't become a banner every minute.
    private static let snooze: TimeInterval = 10 * 60

    private static let enabledKey = "autoStopWhenMeetingEnds"

    /// On by default; the Settings toggle writes this.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: - State

    private var eventEnd: Date?
    private var lastSoundAt = Date()
    private var snoozedUntil: Date?
    private var isPaused = false
    private var evaluateTimer: Timer?
    private var countdownTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    /// Starts watching. `eventEnd` is the calendar event's end time when the
    /// recording is associated with one, which unlocks the earlier of the two
    /// triggers.
    func begin(eventEnd: Date?) {
        self.eventEnd = eventEnd
        lastSoundAt = Date()
        snoozedUntil = nil
        isPaused = false
        clearPending()

        evaluateTimer?.invalidate()
        evaluateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in MeetingEndDetector.shared.evaluate() }
        }
    }

    /// Stops watching — call whenever the recording ends, however it ended.
    func end() {
        evaluateTimer?.invalidate()
        evaluateTimer = nil
        eventEnd = nil
        clearPending()
    }

    /// Fed from `AudioPipeline.onLevels` (~10x/sec) on both channels.
    func noteLevels(mic: Float, system: Float) {
        if mic > Self.silenceThreshold || system > Self.silenceThreshold {
            lastSoundAt = Date()
            // Sound during the reaction window answers the question for us:
            // the meeting is clearly still going.
            if pending != nil { keepRecording() }
        }
    }

    /// A paused recording emits silence deliberately, so the silence clock has
    /// to stop with it.
    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused { clearPending() }
    }

    // MARK: - User responses

    /// Keep Recording — dismiss and don't ask again for `snooze`.
    func keepRecording() {
        clearPending()
        snoozedUntil = Date().addingTimeInterval(Self.snooze)
        lastSoundAt = Date()
    }

    /// Stop & Save — don't wait out the rest of the window.
    func stopNow() {
        clearPending()
        onStop?()
    }

    // MARK: - Detection

    private func evaluate() {
        guard Self.isEnabled, pending == nil else { return }

        let now = Date()
        // While paused or snoozed the silence clock is held at zero, so the
        // count starts fresh from the moment either state lifts.
        guard !isPaused else {
            lastSoundAt = now
            return
        }
        if let snoozedUntil, now < snoozedUntil {
            lastSoundAt = now
            return
        }

        let quietFor = now.timeIntervalSince(lastSoundAt)
        if let eventEnd, now >= eventEnd.addingTimeInterval(Self.calendarGrace),
           quietFor >= Self.silenceAfterCalendarEnd {
            propose(.calendarEndPlusSilence)
        } else if quietFor >= Self.prolongedSilence {
            propose(.prolongedSilence)
        }
    }

    private func propose(_ trigger: Trigger) {
        pending = Pending(trigger: trigger, deadline: Date().addingTimeInterval(Self.reactionWindow))
        MeetingNotifier.notifyMeetingEnded(trigger: trigger, within: Self.reactionWindow)

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(
            withTimeInterval: Self.reactionWindow, repeats: false) { _ in
                Task { @MainActor in MeetingEndDetector.shared.reactionWindowClosed() }
            }
    }

    private func reactionWindowClosed() {
        guard pending != nil else { return }
        clearPending()
        onStop?()
    }

    private func clearPending() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        if pending != nil {
            pending = nil
            MeetingNotifier.withdrawMeetingEnded()
        }
    }
}
