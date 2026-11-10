import CoreGraphics
import Foundation

/// Numbered things on screen the model can point at by id, instead of by a
/// fuzzy label or raw pixels. Controls from the accessibility tree are `C#`,
/// OCR text lines `L#` and the words inside them `W#`.
///
/// The approach (ids, OCR words, snapping the mouse to the smallest box under
/// it) comes from rbrown101010/bluey-by-riley, which is public domain. Unlike
/// Bluey there is no 0–1000 grid: every rect here is already in the shared,
/// global, top-left point space the rest of Clippy uses.
public struct ScreenTargets: Equatable, Sendable {
    public enum Kind: String, Sendable { case control, line, word }

    public struct Target: Equatable, Sendable {
        public let id: String
        public let kind: Kind
        public let text: String
        public let rect: CGRect
        public init(id: String, kind: Kind, text: String, rect: CGRect) {
            self.id = id
            self.kind = kind
            self.text = text
            self.rect = rect
        }
    }

    /// One OCR line with the words inside it, as plain values so tests can
    /// build them without Vision.
    public struct TextLine: Equatable, Sendable {
        public let text: String
        public let rect: CGRect
        public let words: [(text: String, rect: CGRect)]
        public init(text: String, rect: CGRect, words: [(text: String, rect: CGRect)]) {
            self.text = text
            self.rect = rect
            self.words = words
        }
        public static func == (lhs: TextLine, rhs: TextLine) -> Bool {
            lhs.text == rhs.text && lhs.rect == rhs.rect
                && lhs.words.map(\.text) == rhs.words.map(\.text)
                && lhs.words.map(\.rect) == rhs.words.map(\.rect)
        }
    }

    public static let maxLines = 300
    public static let maxWords = 500

    public private(set) var targets: [Target] = []
    /// Control lines exactly as the old "Visible actionable controls" list
    /// printed them, prefixed with their id, so state ([checked], = "…") is kept.
    private var controlLines: [String] = []
    /// Line id → word ids on that line, for rendering.
    private var wordsByLine: [String: [String]] = [:]
    public let mouse: CGPoint?

    public init(controls: [ScreenElementSummary], lines: [TextLine], mouse: CGPoint?) {
        self.mouse = mouse
        for (index, control) in controls.enumerated() {
            let id = "C\(index + 1)"
            targets.append(Target(id: id, kind: .control, text: control.label, rect: control.frame))
            let line = control.contextLine
            controlLines.append(line.hasPrefix("- ") ? "- \(id) " + line.dropFirst(2) : "- \(id) \(line)")
        }
        var wordCount = 0
        for (index, line) in lines.prefix(Self.maxLines).enumerated() {
            let lineID = "L\(index + 1)"
            targets.append(Target(id: lineID, kind: .line, text: line.text, rect: line.rect))
            // A one-word line is already as specific as it gets.
            guard line.words.count > 1 else { continue }
            var ids: [String] = []
            for word in line.words where wordCount < Self.maxWords {
                wordCount += 1
                let wordID = "W\(wordCount)"
                targets.append(Target(id: wordID, kind: .word, text: word.text, rect: word.rect))
                ids.append(wordID)
            }
            wordsByLine[lineID] = ids
        }
    }

    public subscript(id: String) -> Target? {
        let key = id.trimmingCharacters(in: .whitespaces).uppercased()
        return targets.first { $0.id == key }
    }

    /// What's under `point`: the smallest box within 6 pt of it, else the
    /// nearest box centre within 60 pt (Bluey's rule). Smallest wins so the
    /// mouse on a word picks the word, not its line or the window.
    public func target(near point: CGPoint) -> Target? {
        let containing = targets.filter { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }
        if let smallest = containing.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            return smallest
        }
        func distance(_ t: Target) -> CGFloat { hypot(t.rect.midX - point.x, t.rect.midY - point.y) }
        return targets
            .filter { distance($0) <= 60 }
            .min { distance($0) < distance($1) }
    }

    /// Where a click labelled `label` should really land. The model's
    /// coordinates for a plan step are often a row off in a dense list (aimed
    /// at "General", hit "Accessibility"), so prefer the box whose text *is*
    /// the label, nearest the requested point within 150 pt.
    /// With no `point`, any box with exactly that text (the first, in reading
    /// order) — for label-only steps the accessibility tree can't resolve.
    public func point(forLabel label: String, near point: CGPoint? = nil) -> CGPoint? {
        let wanted = label.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ").union(.whitespaces)).lowercased()
        guard !wanted.isEmpty else { return nil }
        func distance(_ t: Target) -> CGFloat {
            point.map { hypot(t.rect.midX - $0.x, t.rect.midY - $0.y) } ?? 0
        }
        return targets
            .filter { $0.text.trimmingCharacters(in: .whitespaces).lowercased() == wanted && distance($0) <= 150 }
            .min { distance($0) < distance($1) }
            .map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
    }

    /// Vision's normalized box (origin bottom-left, 0…1 of the image) to a
    /// global top-left point rect on the display the image was taken of.
    public static func rect(fromVision box: CGRect, displayFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + box.minX * frame.width,
            y: frame.minY + (1 - box.maxY) * frame.height,
            width: box.width * frame.width,
            height: box.height * frame.height
        )
    }

    /// The text block appended to the Screen Context file.
    public func render() -> String {
        var out = "Visible actionable controls (screen coordinates, in reading order). A control's current "
            + "contents appear after \"=\", and toggles show [checked]/[unchecked] — check these before "
            + "acting, so you don't retype a field that already holds the right text or click a switch "
            + "that is already on. Each starts with its pointing id:\n"
        out += controlLines.isEmpty ? "(none)" : controlLines.joined(separator: "\n")
        let lines = targets.filter { $0.kind == .line }
        if !lines.isEmpty {
            out += "\n\nText read off the active display (OCR), each with its pointing id and centre; "
                + "words inside a line are listed after \"|\":\n"
            out += lines.map { line in
                var row = "\(line.id) @\(Int(line.rect.midX)),\(Int(line.rect.midY)) \"\(line.text)\""
                if let ids = wordsByLine[line.id], !ids.isEmpty {
                    row += " | " + ids.compactMap { self[$0] }.map { "\($0.id)=\($0.text)" }.joined(separator: " ")
                }
                return row
            }.joined(separator: "\n")
        }
        if let mouse {
            out += "\n\nMouse is at @\(Int(mouse.x)),\(Int(mouse.y))"
            if let under = target(near: mouse) {
                out += ", on \(under.id) \"\(under.text)\" — \"this\"/\"that\" usually means \(under.id)"
            }
            out += "."
        }
        return out
    }
}
