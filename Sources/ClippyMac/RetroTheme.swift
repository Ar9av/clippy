import SwiftUI

/// Windows 95/98 dialog chrome, for the windows where Clippy should look like
/// it came out of the same box it did.
///
/// The bevel values are the canonical ones: every raised control is a 2px
/// frame with white then light-grey on the top-left and black then mid-grey on
/// the bottom-right, and pressing it swaps the two pairs. Getting those four
/// colours in the right order is most of what makes the era read correctly —
/// a single-line border in the same palette just looks flat.
///
/// Everything here is a standard SwiftUI style (`GroupBoxStyle`,
/// `ButtonStyle`, `ToggleStyle`, `TextFieldStyle`), so a container applies the
/// whole look with `.retroDialog()` and the controls inside it need no
/// per-view changes.
enum RetroPalette {
    /// The dialog face — the colour everyone remembers.
    static let face = Color(red: 0.753, green: 0.753, blue: 0.753)      // #C0C0C0
    static let highlight = Color.white                                   // #FFFFFF
    static let light = Color(red: 0.874, green: 0.874, blue: 0.874)      // #DFDFDF
    static let shadow = Color(red: 0.502, green: 0.502, blue: 0.502)     // #808080
    static let darkShadow = Color(red: 0.039, green: 0.039, blue: 0.039) // #0A0A0A
    static let text = Color.black
    static let disabledText = Color(red: 0.502, green: 0.502, blue: 0.502)
    /// Maroon, not the modern warning orange — the era's error colour.
    static let errorText = Color(red: 0.502, green: 0.0, blue: 0.0)          // #800000
    static let fieldBackground = Color.white
    /// The title bar's blue, and the gradient it fades to.
    static let titleBar = Color(red: 0.0, green: 0.0, blue: 0.502)       // #000080
    static let titleBarTrailing = Color(red: 0.064, green: 0.518, blue: 0.816) // #1084D0
    static let selection = Color(red: 0.0, green: 0.0, blue: 0.502)

    /// Tahoma is the real thing and is present on any Mac that has ever had
    /// Office installed; Geneva is the closest thing macOS ships by default.
    /// Falling through to the system font keeps this safe on a bare install.
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        for name in ["Tahoma", "MS Sans Serif", "Geneva"] where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size).weight(bold ? .bold : .regular)
        }
        return .system(size: size, weight: bold ? .bold : .regular)
    }
}

// MARK: - Bevels

/// One arm of a bevel: the two edges meeting at a corner. Drawn as a path
/// rather than a full stroked rectangle because the whole effect depends on
/// the top-left and bottom-right edges being *different* colours.
private struct BevelArm: Shape {
    enum Corner { case topLeft, bottomRight }
    let corner: Corner

    func path(in rect: CGRect) -> Path {
        // Half-pixel inset so a 1pt stroke lands on the pixel rather than
        // straddling two and going soft.
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        switch corner {
        case .topLeft:
            path.move(to: CGPoint(x: r.minX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        case .bottomRight:
            path.move(to: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        return path
    }
}

struct RetroBevel {
    let outerTopLeft: Color
    let outerBottomRight: Color
    /// nil for the single-line bevels, which have no second ring.
    var innerTopLeft: Color?
    var innerBottomRight: Color?

    /// The 1px "static edge" Windows used around content that is neither a
    /// button nor an editable field. The full 2px sunken frame puts a hard
    /// black L against a large white panel, which at chat-bubble size reads as
    /// a printing error rather than an inset.
    static let staticEdge = RetroBevel(
        outerTopLeft: RetroPalette.shadow,
        outerBottomRight: RetroPalette.highlight
    )
    /// The 1px raised counterpart, for panels that should sit slightly proud.
    static let thinRaised = RetroBevel(
        outerTopLeft: RetroPalette.highlight,
        outerBottomRight: RetroPalette.shadow
    )
    /// No frame at all, so a view can choose between bevelled and flat without
    /// the call site branching on the modifier itself.
    static let none = RetroBevel(
        outerTopLeft: .clear,
        outerBottomRight: .clear
    )

    /// Buttons and panels at rest.
    static let raised = RetroBevel(
        outerTopLeft: RetroPalette.highlight,
        outerBottomRight: RetroPalette.darkShadow,
        innerTopLeft: RetroPalette.light,
        innerBottomRight: RetroPalette.shadow
    )
    /// The same button held down — the light and dark pairs trade places, so
    /// the control appears pushed into the dialog.
    static let pressed = RetroBevel(
        outerTopLeft: RetroPalette.darkShadow,
        outerBottomRight: RetroPalette.highlight,
        innerTopLeft: RetroPalette.shadow,
        innerBottomRight: RetroPalette.light
    )
    /// Text fields, list boxes, anything you type into.
    static let sunken = RetroBevel(
        outerTopLeft: RetroPalette.shadow,
        outerBottomRight: RetroPalette.highlight,
        innerTopLeft: RetroPalette.darkShadow,
        innerBottomRight: RetroPalette.light
    )
    /// The etched hairline around a group box.
    static let etched = RetroBevel(
        outerTopLeft: RetroPalette.shadow,
        outerBottomRight: RetroPalette.highlight,
        innerTopLeft: RetroPalette.highlight,
        innerBottomRight: RetroPalette.shadow
    )
}

private struct RetroBevelModifier: ViewModifier {
    let bevel: RetroBevel

    func body(content: Content) -> some View {
        content
            .overlay {
                if let innerTopLeft = bevel.innerTopLeft {
                    BevelArm(corner: .topLeft).stroke(innerTopLeft, lineWidth: 1).padding(1)
                }
            }
            .overlay {
                if let innerBottomRight = bevel.innerBottomRight {
                    BevelArm(corner: .bottomRight).stroke(innerBottomRight, lineWidth: 1).padding(1)
                }
            }
            .overlay(BevelArm(corner: .topLeft).stroke(bevel.outerTopLeft, lineWidth: 1))
            .overlay(BevelArm(corner: .bottomRight).stroke(bevel.outerBottomRight, lineWidth: 1))
    }
}

extension View {
    func retroBevel(_ bevel: RetroBevel) -> some View {
        modifier(RetroBevelModifier(bevel: bevel))
    }
}

/// A blur of whatever is *behind the window* — other apps, the desktop.
///
/// SwiftUI's `.ultraThinMaterial` is not this. Its blending is within-window,
/// so in a window whose own background is clear it has nothing to sample and
/// renders as a flat wash; tinting that produced a slab indistinguishable from
/// an opaque one. `NSVisualEffectView` with `.behindWindow` is the only way to
/// actually see through to another application.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        // Without `.active` the blur greys out whenever the window isn't key,
        // which for a floating assistant is most of the time.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The dialog face, but letting what's behind the window through.
///
/// Nothing in 1995 was translucent — this is deliberately the one modern note,
/// because a flat opaque slab of #C0C0C0 at this size reads as a screenshot
/// pasted over the desktop rather than a window sitting on it.
///
/// Use this for *every* surface of a translucent window. A region that keeps
/// an opaque `RetroPalette.face` instead won't match: the translucent areas
/// take on whatever is behind them, so the two tones diverge and the join
/// shows as a hard seam.
struct RetroFace: View {
    /// Enough tint to still read as the era's grey, little enough that the
    /// blurred backdrop comes through.
    static let opacity: Double = 0.55

    var body: some View {
        BehindWindowBlur()
            .overlay(RetroPalette.face.opacity(Self.opacity))
    }
}

// MARK: - Controls

struct RetroButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var minWidth: CGFloat = 75
    /// Tighter padding and height, for buttons that sit inside content rather
    /// than in a dialog's button row. At the standard 21pt height an in-line
    /// action reads as a stray dialog button dropped into the text.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RetroPalette.font(compact ? 10 : 11))
            .foregroundStyle(isEnabled ? RetroPalette.text : RetroPalette.disabledText)
            .padding(.horizontal, compact ? 5 : 10)
            .frame(minWidth: minWidth, minHeight: compact ? 16 : 21)
            .background(RetroPalette.face)
            .retroBevel(configuration.isPressed ? .pressed : .raised)
            // A held button's label shifts a pixel down and right with the
            // bevel; without it the button reads as merely recoloured.
            .offset(
                x: configuration.isPressed ? 1 : 0,
                y: configuration.isPressed ? 1 : 0
            )
            .contentShape(Rectangle())
    }
}

struct RetroTextFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(RetroPalette.font(11))
            .foregroundStyle(RetroPalette.text)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(RetroPalette.fieldBackground)
            .retroBevel(.sunken)
    }
}

/// The square tick box, not a switch — a switch is the single most modern
/// looking control there is and gives the whole dialog away.
struct RetroCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ZStack {
                    Rectangle()
                        .fill(isEnabled ? RetroPalette.fieldBackground : RetroPalette.face)
                        .frame(width: 13, height: 13)
                        .retroBevel(.sunken)
                    if configuration.isOn {
                        // Drawn rather than an SF Symbol: the system
                        // checkmark is rounded and obviously of this decade.
                        Path { path in
                            path.move(to: CGPoint(x: 2.5, y: 6.5))
                            path.addLine(to: CGPoint(x: 5, y: 9))
                            path.addLine(to: CGPoint(x: 10, y: 3.5))
                        }
                        .stroke(
                            isEnabled ? RetroPalette.text : RetroPalette.disabledText,
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .butt, lineJoin: .miter)
                        )
                        .frame(width: 13, height: 13)
                    }
                }
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }

                configuration.label
                    .font(RetroPalette.font(11))
                    .foregroundStyle(isEnabled ? RetroPalette.text : RetroPalette.disabledText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A radio group. Built out of buttons rather than styling `Picker`, because
/// macOS draws its radio buttons as filled blue circles no style can reach.
struct RetroRadioGroup<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(RetroPalette.fieldBackground)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle().stroke(RetroPalette.shadow, lineWidth: 1)
                                        .offset(x: -0.5, y: -0.5)
                                )
                                .overlay(
                                    Circle().stroke(RetroPalette.highlight, lineWidth: 1)
                                        .offset(x: 0.5, y: 0.5)
                                )
                            if selection == option.value {
                                Circle()
                                    .fill(RetroPalette.text)
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }

                        Text(option.title)
                            .font(RetroPalette.font(11))
                            .foregroundStyle(RetroPalette.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The chunked progress bar, drawn as discrete blocks with a gap between
/// them. A smooth continuous fill is the giveaway of a modern bar.
struct RetroProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            let blockWidth: CGFloat = 8
            let spacing: CGFloat = 2
            let total = max(1, Int((geometry.size.width - 4) / (blockWidth + spacing)))
            let filled = Int((Double(total) * min(max(value, 0), 1)).rounded())
            HStack(spacing: spacing) {
                ForEach(0..<total, id: \.self) { index in
                    Rectangle()
                        .fill(index < filled ? RetroPalette.titleBar : Color.clear)
                        .frame(width: blockWidth)
                }
                Spacer(minLength: 0)
            }
            .padding(2)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: 20)
        .background(RetroPalette.face)
        .retroBevel(.sunken)
    }
}

/// The scrollbar, which is most of what makes a list look like a Windows list:
/// arrow buttons at each end, a raised thumb, and the 50% checkerboard track
/// that the era drew by dithering white against the face colour.
///
/// SwiftUI's own indicator can't be restyled, so this replaces it. It reports
/// position rather than owning it: `fraction` and `visibleRatio` come from the
/// scroll view's measured geometry, and the callbacks ask the caller to move.
struct RetroScrollBar: View {
    /// 0...1, how far down the content is scrolled.
    let fraction: Double
    /// 0...1, the visible portion of the content — the thumb's size.
    let visibleRatio: Double
    let scrollTo: (Double) -> Void
    let step: (Int) -> Void

    private static let width: CGFloat = 16
    private static let minimumThumb: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            arrow(pointingUp: true) { step(-1) }
            track
            arrow(pointingUp: false) { step(1) }
        }
        .frame(width: Self.width)
        .accessibilityHidden(true)
    }

    private var track: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let thumbHeight = max(Self.minimumThumb, height * min(max(visibleRatio, 0), 1))
            let travel = max(0, height - thumbHeight)

            ZStack(alignment: .top) {
                checkerboard
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        // Clicking the track pages toward the click, as it did.
                        scrollTo(travel > 0 ? (location.y - thumbHeight / 2) / travel : 0)
                    }

                Rectangle()
                    .fill(RetroPalette.face)
                    .retroBevel(.raised)
                    .frame(height: thumbHeight)
                    .offset(y: travel * min(max(fraction, 0), 1))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard travel > 0 else { return }
                                scrollTo((value.location.y - thumbHeight / 2) / travel)
                            }
                    )
            }
        }
    }

    /// White and face-grey alternating per pixel — the dither that stood in
    /// for a light grey before 24-bit colour was a safe assumption.
    private var checkerboard: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RetroPalette.face))
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = y.truncatingRemainder(dividingBy: 2) == 0 ? 0 : 1
                while x < size.width {
                    path.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                    x += 2
                }
                y += 1
            }
            context.fill(path, with: .color(RetroPalette.highlight))
        }
    }

    private func arrow(pointingUp: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Triangle(pointingUp: pointingUp)
                .fill(RetroPalette.text)
                .frame(width: 7, height: 4)
                .frame(width: Self.width, height: Self.width)
        }
        .buttonStyle(RetroButtonStyle(minWidth: Self.width, compact: true))
    }

    private struct Triangle: Shape {
        let pointingUp: Bool

        func path(in rect: CGRect) -> Path {
            var path = Path()
            if pointingUp {
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            } else {
                path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            }
            path.closeSubpath()
            return path
        }
    }
}

/// What a scroll view reports about itself, so a `RetroScrollBar` beside it
/// can show where you are.
struct RetroScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    /// 0...1 position, or 0 when everything already fits.
    var fraction: Double {
        let travel = contentHeight - viewportHeight
        guard travel > 1 else { return 0 }
        return Double(min(max(offset / travel, 0), 1))
    }

    var visibleRatio: Double {
        guard contentHeight > 1 else { return 1 }
        return Double(min(max(viewportHeight / contentHeight, 0), 1))
    }

    var needsScrollBar: Bool { contentHeight - viewportHeight > 1 }
}

struct RetroScrollMetricsKey: PreferenceKey {
    static let defaultValue = RetroScrollMetrics()

    static func reduce(value: inout RetroScrollMetrics, nextValue: () -> RetroScrollMetrics) {
        let next = nextValue()
        if next.contentHeight > 0 { value = next }
    }
}

/// A group box: an etched frame with its caption sitting on the frame line,
/// the background punched out behind the text so the line doesn't run through
/// it.
struct RetroGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(10)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .retroBevel(.etched)
            .overlay(alignment: .topLeading) {
                configuration.label
                    .font(RetroPalette.font(11))
                    .foregroundStyle(RetroPalette.text)
                    .padding(.horizontal, 4)
                    .background(RetroPalette.face)
                    .offset(x: 8, y: -7)
            }
            .padding(.top, 7)
    }
}

// MARK: - Window chrome

/// The glyphs inside the title-bar boxes. Drawn rather than typed: the
/// characters that look approximately right ("_", "□", "✕") sit on a text
/// baseline and centre badly, which is exactly the sort of near-miss that
/// makes a pastiche look wrong.
private struct TitleBarGlyph: View {
    enum Kind { case minimize, maximize, restore, close }
    let kind: Kind
    let color: Color

    var body: some View {
        // Composed from rectangles rather than one filled `Path`: a window
        // outline is a rect with a hole in it, and a single path of two
        // nested rects fills solid under the default non-zero winding rule.
        ZStack {
            switch kind {
            case .minimize:
                // A short bar resting on the bottom, not centred.
                bar(width: 7, height: 2)
                    .offset(y: 3.5)
            case .maximize:
                windowOutline(size: 9)
            case .restore:
                windowOutline(size: 7).offset(x: 1.5, y: 1.5)
                windowOutline(size: 7).offset(x: -1.5, y: -1.5)
            case .close:
                cross()
            }
        }
        .frame(width: 10, height: 10)
        .foregroundStyle(color)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        Rectangle().frame(width: width, height: height)
    }

    /// A window: a one-pixel frame with the heavy top edge that stood in for
    /// a title bar.
    private func windowOutline(size: CGFloat) -> some View {
        Rectangle()
            .stroke(lineWidth: 1)
            .frame(width: size, height: size)
            .overlay(alignment: .top) {
                Rectangle().frame(height: 2)
            }
    }

    private func cross() -> some View {
        ZStack {
            Rectangle()
                .frame(width: 9, height: 1.4)
                .rotationEffect(.degrees(45))
            Rectangle()
                .frame(width: 9, height: 1.4)
                .rotationEffect(.degrees(-45))
        }
    }
}

/// The title bar: blue gradient, bold white caption, and the box buttons on
/// the right. Each button is wired to a closure; one that isn't supplied is
/// drawn disabled rather than omitted, so the bar keeps its shape.
struct RetroTitleBar: View {
    let title: String
    var onMinimize: (() -> Void)?
    var onMaximize: (() -> Void)?
    var isMaximized = false
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(RetroPalette.font(11, bold: true))
                .foregroundStyle(.white)
                .padding(.leading, 3)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                titleButton(.minimize, action: onMinimize)
                titleButton(isMaximized ? .restore : .maximize, action: onMaximize)
                // The close box sits slightly apart, as it did.
                titleButton(.close, action: onClose)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        // Height comes from the content, deliberately. A fixed `.frame(height:)`
        // here does not clip — anything taller spilled past it while the
        // gradient behind stayed 20pt, so the buttons showed as grey tabs
        // sticking up above the bar. Sizing to content makes that impossible
        // rather than merely unlikely.
        .background(
            LinearGradient(
                colors: [RetroPalette.titleBar, RetroPalette.titleBarTrailing],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        // Belt and braces: even a future glyph that overshoots its frame can
        // only be cut off, never drawn outside the bar.
        .clipped()
    }

    private func titleButton(_ kind: TitleBarGlyph.Kind, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            TitleBarGlyph(
                kind: kind,
                color: action == nil ? RetroPalette.disabledText : RetroPalette.text
            )
            .frame(width: 14, height: 12)
        }
        // Compact, because the standard button's 21pt minimum height does not
        // fit a 20pt title bar with 2pt padding — the buttons overflowed the
        // navy background and showed as grey tabs sticking out above it.
        .buttonStyle(RetroButtonStyle(minWidth: 16, compact: true))
        .disabled(action == nil)
        .accessibilityLabel(label(for: kind))
    }

    private func label(for kind: TitleBarGlyph.Kind) -> String {
        switch kind {
        case .minimize: "Minimise"
        case .maximize: "Maximise"
        case .restore: "Restore"
        case .close: "Close"
        }
    }
}

extension View {
    /// Applies the whole dialog look to a subtree: face colour, period font,
    /// and retro versions of every standard control inside it.
    ///
    /// Light mode is forced. These colours are fixed 1995 values with no dark
    /// variant, so on a Mac in dark mode the inherited label colour would come
    /// out white-on-grey and the dialog would be unreadable.
    func retroDialog() -> some View {
        self
            .font(RetroPalette.font(11))
            .foregroundStyle(RetroPalette.text)
            .tint(RetroPalette.titleBar)
            .groupBoxStyle(RetroGroupBoxStyle())
            .buttonStyle(RetroButtonStyle())
            .toggleStyle(RetroCheckboxStyle())
            .textFieldStyle(RetroTextFieldStyle())
            .environment(\.colorScheme, .light)
    }

    /// Wraps a view in the full window: raised outer frame, title bar, and a
    /// face-coloured body.
    func retroWindow(title: String, onClose: (() -> Void)? = nil) -> some View {
        VStack(spacing: 0) {
            RetroTitleBar(title: title, onClose: onClose)
                .padding(.horizontal, 3)
                .padding(.top, 3)
            self
        }
        .background(RetroPalette.face)
        .retroBevel(.raised)
        .environment(\.colorScheme, .light)
    }
}
