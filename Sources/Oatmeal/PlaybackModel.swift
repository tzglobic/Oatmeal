import Foundation
import AVFoundation

/// Plays a meeting's .m4a recording with seek support. Transcript timestamps and
/// file offsets share the same clock (both start at recording start), so a
/// segment's startTime maps directly to a file position.
@MainActor
final class PlaybackModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    var available: Bool { player != nil }
    var duration: Double { player?.duration ?? 0 }

    init(path: String?) {
        load(path: path)
    }

    /// (Re)open the audio file. Needed after a recording stops: the .m4a isn't
    /// finalized until then, so a player created mid-recording is nil or stale.
    func load(path: String?) {
        pause()
        player = nil
        currentTime = 0
        if let path, FileManager.default.fileExists(atPath: path),
           let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) {
            player.prepareToPlay()
            self.player = player
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        currentTime = player?.currentTime ?? currentTime
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration - 0.1))
        currentTime = player.currentTime
        if !isPlaying { play() }
    }

    func isCurrent(start: Double, end: Double) -> Bool {
        isPlaying && currentTime >= start && currentTime < max(end, start + 1)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying && self.isPlaying {
                    // Reached the end.
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
