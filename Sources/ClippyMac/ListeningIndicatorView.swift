import SwiftUI

/// Small equalizer-style bars that react to live microphone amplitude while
/// dictation is active. Runs a continuous idle wobble even when `level` is
/// flat so it never looks frozen between words, then leans into `level` for
/// louder speech. Used for both the Apple and local-Whisper dictation paths
/// (see `SpeechService.audioLevel`), since neither is inherently "the
/// listening one" from this view's perspective.
struct ListeningWaveform: View {
    var level: Float
    var barCount = 5
    var color = Color.red

    private let phases: [Double]

    init(level: Float, barCount: Int = 5, color: Color = .red) {
        self.level = level
        self.barCount = barCount
        self.color = color
        phases = (0..<barCount).map { Double($0) * 0.6 }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: 3, height: height(at: t, index: index))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func height(at t: TimeInterval, index: Int) -> CGFloat {
        let phase = phases[index]
        let idle = 0.16 + 0.10 * sin(t * 3 + phase)
        let driven = Double(level) * (0.55 + 0.45 * sin(t * 9 + phase * 1.7))
        let magnitude = max(0.1, min(1, idle + driven))
        return 4 + CGFloat(magnitude) * 18
    }
}

/// A soft ring that pulses outward from a view while `isActive`, meant to
/// wrap the dictation mic button so starting to listen reads as an obvious,
/// alive state rather than just a color change on the icon.
private struct ListeningPulse: ViewModifier {
    var isActive: Bool
    var color: Color

    @State private var expanded = false

    func body(content: Content) -> some View {
        content
            .overlay {
                Circle()
                    .stroke(color.opacity(isActive ? 0.55 : 0), lineWidth: 2)
                    .scaleEffect(expanded ? 1.7 : 1.0)
                    .opacity(expanded ? 0 : 0.8)
                    .animation(
                        isActive
                            ? .easeOut(duration: 1.2).repeatForever(autoreverses: false)
                            : .default,
                        value: expanded
                    )
            }
            .onAppear { expanded = isActive }
            .onChange(of: isActive) { _, newValue in
                // Toggling straight from true back to true would be a no-op
                // for `.animation(value:)` — flip through false first so a
                // fresh dictation session restarts the pulse from scratch.
                expanded = false
                if newValue {
                    DispatchQueue.main.async { expanded = true }
                }
            }
    }
}

extension View {
    func listeningPulse(isActive: Bool, color: Color = .red) -> some View {
        modifier(ListeningPulse(isActive: isActive, color: color))
    }
}
