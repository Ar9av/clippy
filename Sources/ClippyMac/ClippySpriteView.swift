import AppKit
import ImageIO
import SwiftUI

enum ClippyMood: Equatable {
    case idle
    case greeting
    case thinking
    case talking
    case listening
    case success
    case alert

    var animationNames: [String] {
        switch self {
        case .idle:
            ["Idle1_1", "IdleFingerTap", "IdleEyeBrowRaise", "IdleHeadScratch",
             "IdleSideToSide", "LookLeft", "LookRight", "RestPose"]
        case .greeting:
            ["Greeting", "Show", "Wave", "GetAttention"]
        case .thinking:
            ["Thinking", "Processing", "CheckingSomething", "Searching"]
        case .talking:
            ["Explain", "GetTechy", "GetAttention", "GestureRight", "GestureLeft"]
        case .listening:
            ["Hearing_1", "GetAttention", "LookUp"]
        case .success:
            ["Congratulate", "Wave", "GetArtsy"]
        case .alert:
            ["Alert", "GetAttention", "LookDown"]
        }
    }
}

private struct AgentAnimationData: Decodable {
    let framesize: [Int]
    let animations: [String: AgentAnimation]
}

private struct AgentAnimation: Decodable {
    let frames: [AgentFrame]
}

private struct AgentFrame: Decodable {
    let duration: Int
    let images: [[Int]]?
}

@MainActor
final class ClippyAnimationController: ObservableObject {
    @Published private(set) var frame: CGImage?
    @Published private(set) var currentAnimation = "RestPose"

    private var sheet: CGImage?
    private var data: AgentAnimationData?
    private var playbackTask: Task<Void, Never>?
    private var mood: ClippyMood = .idle

    init() {
        loadAssets()
    }

    deinit {
        playbackTask?.cancel()
    }

    func start() {
        play(.greeting, returnTo: .idle)
    }

    func setMood(_ newMood: ClippyMood) {
        guard newMood != mood else { return }
        mood = newMood
        play(newMood)
    }

    /// Decoding the 213 KB animation JSON and the 1.3 MB sprite sheet is
    /// identical work for every instance — `ClippyPortrait` alone creates
    /// one `ClippyAnimationController` per message bubble, so a 40-message
    /// transcript used to repeat this decode 20+ times. Cached once per
    /// process instead.
    private static var cachedAssets: (data: AgentAnimationData, sheet: CGImage)?

    /// The packaged .app (built via scripts/build-dmg.sh) copies these files
    /// directly into Contents/Resources, so `Bundle.main` finds them there.
    /// A plain `swift build`/`swift run` has no .app bundle at all — for
    /// that case SwiftPM generates a resource bundle for this target
    /// (`Bundle.module`), so fall back to it rather than silently rendering
    /// no sprite.
    private func loadAssets() {
        let decoded: AgentAnimationData
        let image: CGImage
        if let cached = Self.cachedAssets {
            decoded = cached.data
            image = cached.sheet
        } else {
            guard
                let jsonURL = Bundle.main.url(forResource: "ClippyAnimations", withExtension: "json")
                    ?? Bundle.module.url(forResource: "ClippyAnimations", withExtension: "json"),
                let spriteURL = Bundle.main.url(forResource: "ClippySprites", withExtension: "png")
                    ?? Bundle.module.url(forResource: "ClippySprites", withExtension: "png"),
                let json = try? Data(contentsOf: jsonURL),
                let loadedData = try? JSONDecoder().decode(AgentAnimationData.self, from: json),
                let source = CGImageSourceCreateWithURL(spriteURL as CFURL, nil),
                let loadedImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return
            }
            decoded = loadedData
            image = loadedImage
            Self.cachedAssets = (decoded, image)
        }

        data = decoded
        sheet = image
        if let rest = decoded.animations["RestPose"]?.frames.first {
            render(rest)
        }
    }

    private func play(_ requestedMood: ClippyMood, returnTo: ClippyMood? = nil) {
        playbackTask?.cancel()
        mood = requestedMood

        playbackTask = Task { [weak self] in
            guard let self else { return }
            var activeMood = requestedMood

            while !Task.isCancelled {
                guard let animation = self.pickAnimation(for: activeMood) else { return }
                self.currentAnimation = animation.name

                for frame in animation.value.frames {
                    guard !Task.isCancelled else { return }
                    self.render(frame)
                    let milliseconds = max(frame.duration, 16)
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                }
                // An animation with no frames (malformed data, or a mood
                // whose every candidate name is missing from the JSON) would
                // otherwise loop this outer `while` with no sleep at all —
                // a tight busy-spin pinning a core with nothing to show for it.
                if animation.value.frames.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                }

                if let returnTo {
                    activeMood = returnTo
                    self.mood = returnTo
                }
            }
        }
    }

    private func pickAnimation(for mood: ClippyMood) -> (name: String, value: AgentAnimation)? {
        guard let animations = data?.animations else { return nil }
        let available = mood.animationNames.filter { animations[$0] != nil }
        guard let name = available.randomElement(), let animation = animations[name] else {
            guard let fallback = animations["RestPose"] else { return nil }
            return ("RestPose", fallback)
        }
        return (name, animation)
    }

    private func render(_ animationFrame: AgentFrame) {
        guard
            let sheet,
            let data,
            data.framesize.count >= 2,
            let point = animationFrame.images?.first,
            point.count >= 2
        else { return }

        let width = data.framesize[0]
        let height = data.framesize[1]
        let rect = CGRect(x: point[0], y: point[1], width: width, height: height)
        frame = sheet.cropping(to: rect)
    }
}

struct AnimatedClippyView: View {
    let mood: ClippyMood
    var showsStatus = false

    @StateObject private var controller = ClippyAnimationController()

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let frame = controller.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                }
            }
            .accessibilityLabel("Animated Clippy")

            if showsStatus {
                Text(controller.currentAnimation)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onAppear { controller.start() }
        .onChange(of: mood) { _, newMood in
            controller.setMood(newMood)
        }
    }
}

struct ClippyPortrait: View {
    var body: some View {
        StaticClippyView()
            .frame(width: 34, height: 27)
    }
}

struct StaticClippyView: View {
    @StateObject private var controller = ClippyAnimationController()

    var body: some View {
        Group {
            if let frame = controller.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .accessibilityLabel("Clippy")
    }
}
