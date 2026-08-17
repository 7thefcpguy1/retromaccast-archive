import SwiftUI
import WebKit

/// An authentic 1997 QuickTime Player-style window: 19px pinstripe title bar with close/zoom
/// box, a 1px black border wrapping the whole thing, and a real 16px Standard Movie Controller
/// bar underneath -- all custom-drawn, not native controls, matching how every other piece of
/// chrome in this app works (the Finder-style windows, the scrollbar, the checkbox toggle).
/// Takes its own full frame (title bar + video + controller bar together) and subdivides
/// internally -- the caller just gives it a total box size, not a "video size" to add chrome
/// on top of.
struct QuickTimePlayerChrome: View {
    let title: String
    @ObservedObject var model: YouTubePlayerModel
    // Non-nil shows this bundled image instead of the live webview -- the "off-air" idle
    // state, before any video has been picked. The chrome itself (title bar + controller
    // bar) is unconditional either way, so the player window is always the tab's primary
    // surface, never a bare empty box waiting for a first selection.
    var placeholderImageName: String? = nil
    // Scoped strictly to the video viewport (applied to `content` only, below) -- not the
    // whole chrome. An earlier pass here deliberately covered the title bar and controller
    // bar too ("this whole object is a period display"), but per explicit direction this
    // round, the chrome must keep rendering normally; only the video canvas gets the 1-bit
    // treatment.
    var oneBit: Bool = false
    let onClose: () -> Void

    // Internal, not private -- VideosView.swift reads these to compute the total chrome
    // frame it hands in, so the two files' sizing math can't drift out of sync.
    static let titleBarHeight: CGFloat = 19
    static let controllerBarHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            content
            // Crisp divider separating the video viewport from the controller bar --
            // matches FinderWindowChrome's own title-bar/content divider technique.
            Rectangle().fill(Color.black).frame(height: 1)
            MovieControllerBar(model: model)
        }
        // Wraps title bar + video + controller bar as ONE continuous unit -- content butts
        // directly against this border and the title bar with no internal margin, per spec.
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let placeholderImageName {
                Image(placeholderImageName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                YouTubeWebView(model: model)
            }
        }
        .overlay {
            // Scoped to just this Group (the video canvas), not the outer VStack -- see
            // `oneBit`'s doc comment above.
            if oneBit {
                ScanlineOverlay()
            }
        }
    }

    private var titleBar: some View {
        ZStack {
            // A locally-scoped solid-black pinstripe, not the shared `PinstripeBackground`
            // (FinderWindowChrome.swift) -- that component is used by every other window in
            // the app at a soft 22%-opacity gray stripe, and changing it there would restyle
            // Museum/Emulators/Trivia's title bars too. A genuine 1-bit display has no
            // partial opacity at all, so this window's own title bar draws its alternating
            // 1px black/1px white rows at full solid black instead.
            QTPinstripeBackground()
            HStack(spacing: 0) {
                closeBox
                    .padding(.leading, 6)
                Spacer(minLength: 6)
                Text(title)
                    .font(.chicago(12))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white)
                Spacer(minLength: 6)
                zoomBox
                    .padding(.trailing, 6)
            }
        }
        .frame(height: Self.titleBarHeight)
    }

    private var closeBox: some View {
        Button(action: onClose) {
            ZStack {
                Rectangle().fill(Color.white)
                Rectangle().stroke(Color.black, lineWidth: 1)
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(CloseBoxButtonStyle())
        // A small solid-white halo so the pinstripe terminates cleanly at the box's edge
        // instead of its black rows visually running right up against the box's own border.
        .padding(2)
        .background(Color.white)
    }

    /// Monochrome, unlike FinderWindowChrome's periwinkle-accented zoom box -- this component's
    /// spec'd palette is strictly black/white/gray, matching an authentic 1-bit-era QuickTime
    /// window (no color accents existed on one back then). Purely decorative, same as the
    /// Finder chrome's own zoom box -- returning to the idle state is what the close box is for.
    private var zoomBox: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(Color.black, lineWidth: 1)
                .frame(width: 7, height: 7)
                .offset(x: 5, y: 5)
            Rectangle()
                .fill(Color.white)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                .frame(width: 6, height: 6)
        }
        .frame(width: 12, height: 12, alignment: .topLeading)
        // Same solid-white halo as closeBox -- the two overlapping squares don't fill their
        // whole 12x12 bounding box on their own, so without this the pinstripe shows through
        // the gaps between/around them instead of terminating cleanly at the widget's edge.
        .padding(2)
        .background(Color.white)
    }
}

/// Solid-black alternating 1px rows -- see `titleBar`'s doc comment for why this isn't the
/// shared `PinstripeBackground`.
private struct QTPinstripeBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black))
                y += 2
            }
        }
    }
}

/// Dense horizontal scanlines plus a visible dithered grain (reusing `DitheredPattern` at a
/// much higher opacity than a first pass elsewhere used) -- the reference photo's dither is
/// dense and clearly visible, not a faint texture, so this isn't subtle. Moved here from
/// VideosView.swift (was `scanlineOverlay` there) so it applies only to `content` -- the video
/// canvas -- not the whole chrome; see `oneBit`'s doc comment above.
private struct ScanlineOverlay: View {
    var body: some View {
        ZStack {
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.28)))
                    y += 3
                }
            }
            DitheredPattern(background: .clear, tint: .black.opacity(0.14))
        }
        .allowsHitTesting(false)
        .blendMode(.multiply)
    }
}

#if os(macOS)
private struct YouTubeWebView: NSViewRepresentable {
    @ObservedObject var model: YouTubePlayerModel
    func makeNSView(context: Context) -> WKWebView { model.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct YouTubeWebView: UIViewRepresentable {
    @ObservedObject var model: YouTubePlayerModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// The Standard Movie Controller bar: speaker/volume, play/pause, a draggable scrubber, and
/// frame-step buttons, all custom-drawn against a dithered platinum background.
private struct MovieControllerBar: View {
    @ObservedObject var model: YouTubePlayerModel
    @State private var volumePopupOpen = false
    @State private var isDragging = false
    @State private var dragTime: Double = 0

    private static let barHeight: CGFloat = QuickTimePlayerChrome.controllerBarHeight

    var body: some View {
        // Five sections sitting directly adjacent, spacing: 0 -- each already draws its own
        // 1px black border, so touching edges read as one continuous line rather than a
        // double gap. No separate divider views between them anymore; the bar's own outer
        // frame (QuickTimePlayerChrome's .overlay) and the divider above it (against the
        // video) are the only borders this bar needs beyond each button's own.
        HStack(spacing: 0) {
            speakerButton
            playPauseButton
            scrubber
            frameStepButtons
            badgeButton
        }
        .frame(height: Self.barHeight)
        .background(
            // Flat white, not a checkerboard -- corrected against a direct read of the
            // reference photo: the dither belongs INSIDE the scrubber groove (the "played"
            // portion, handled in `scrubber` below), not smeared across the whole bar's
            // background. With buttons interlocked via spacing: 0, this background is only
            // ever visible in the scrubber's own 8pt insets, so it needs to read as plain
            // white there, matching the buttons either side of it.
            //
            // DitheredPattern at a near-zero tint, NOT a literal `Color.white` -- a single
            // opaque white fill this wide (854pt+) is exactly the shape of the bug bisected
            // earlier this session (a solid white `Shape`/`Canvas` fill silently fails to
            // render past ~400-500pt here). This is the same safe workaround already used for
            // the groove's "remaining" side.
            DitheredPattern(background: .white, tint: .black.opacity(0.05))
        )
    }

    private var speakerButton: some View {
        Button {
            volumePopupOpen.toggle()
        } label: {
            SpeakerGlyph()
                .frame(width: 14, height: 12)
        }
        .buttonStyle(.plain)
        .frame(width: 32)
        .buttonBoxBorder()
        .overlay(alignment: .top) {
            if volumePopupOpen {
                VolumeSlider(volume: Binding(get: { model.volume }, set: { model.setVolume($0) }))
                    .offset(y: -64)
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            model.togglePlayPause()
        } label: {
            Group {
                if model.isPlaying {
                    PauseGlyph()
                } else {
                    PlayGlyph()
                }
            }
            .frame(width: 10, height: 12)
        }
        .buttonStyle(.plain)
        .frame(width: 28)
        .buttonBoxBorder()
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let inset: CGFloat = 8
            let thumbWidth: CGFloat = 12
            let trackWidth = max(1, geo.size.width - inset * 2 - thumbWidth)
            let duration = max(model.duration, 0.001)
            let fraction = min(1, max(0, (isDragging ? dragTime : model.currentTime) / duration))
            let playheadX = inset + thumbWidth / 2 + CGFloat(fraction) * trackWidth
            let trackHeight: CGFloat = 10
            let thumbHeight: CGFloat = 14
            let grooveWidth = max(1, geo.size.width - inset * 2)
            // How far the "played" fill extends from the groove's own left edge -- a real
            // QuickTime scrubber (confirmed against a photo of one on a physical Mac) fills the
            // elapsed portion of the track with a dense textured block, thermometer-style, not
            // just a thin marker sitting on an otherwise uniform groove. Measured in the same
            // coordinate space as playheadX (both start from the groove's left edge at x=inset).
            let elapsedWidth = min(grooveWidth, max(0, thumbWidth / 2 + CGFloat(fraction) * trackWidth))

            ZStack(alignment: .topLeading) {
                // Two-tone groove: a dense-dither "elapsed" fill on the left, a near-white
                // "remaining" fill on the right, meeting at the playhead -- reusing
                // DitheredPattern for both (not a solid Color.white fill) because a single large
                // opaque white area was confirmed by direct bisection this session to silently
                // fail to render past roughly 400-500pt wide, while the exact same-size red
                // fills and DitheredPattern's own checkerboard (already used at ~850pt for the
                // bar's background) both render fine. The near-invisible tint on the remaining
                // side keeps the "flat white groove" look while sidestepping that bug entirely.
                HStack(spacing: 0) {
                    DitheredPattern(background: .white, tint: .black)
                        .frame(width: elapsedWidth, height: trackHeight)
                    DitheredPattern(background: .white, tint: .black.opacity(0.05))
                        .frame(width: max(0, grooveWidth - elapsedWidth), height: trackHeight)
                }
                .frame(width: grooveWidth, height: trackHeight)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)

                // A proper slider thumb -- a white box with its own black border and a few
                // vertical grip ridges, like a real scrubber handle -- not a bare bar or a
                // plain empty box.
                ScrubberThumb()
                    .frame(width: thumbWidth, height: thumbHeight)
                    .position(x: playheadX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                // Live position while dragging, seek fires once on release -- same shape as
                // InlinePlayer's scrubber (SearchView.swift), not a seek call per drag delta.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let clampedX = max(inset, min(geo.size.width - inset, value.location.x))
                        let frac = (clampedX - inset - thumbWidth / 2) / trackWidth
                        dragTime = max(0, Double(frac)) * model.duration
                    }
                    .onEnded { _ in
                        isDragging = false
                        model.seek(to: dragTime)
                    }
            )
        }
        .frame(maxWidth: .infinity)
    }

    /// Two independently-bordered buttons -- each its own white box, same as speaker/play/
    /// badge -- not one shared box with an internal divider.
    private var frameStepButtons: some View {
        HStack(spacing: 0) {
            Button { model.stepFrame(forward: false) } label: {
                StepGlyph(forward: false).frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .buttonBoxBorder()

            Button { model.stepFrame(forward: true) } label: {
                StepGlyph(forward: true).frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .buttonBoxBorder()
        }
    }

    /// Purely decorative, matching the small square icon at the far right of a real
    /// QuickTime controller bar in the reference photo.
    private var badgeButton: some View {
        BadgeGlyph()
            .frame(width: 12, height: 12)
            .frame(width: 24)
            .buttonBoxBorder()
    }
}

/// A vertical 7-level stepped volume slider -- click-to-open/click-again-to-close (the speaker
/// button toggles this), not true press-and-hold, per the confirmed simpler interaction.
private struct VolumeSlider: View {
    @Binding var volume: Double // 0-100
    private static let levels: [Double] = stride(from: 0.0, through: 100.0, by: 100.0 / 6).map { $0 }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Self.levels.reversed(), id: \.self) { level in
                Button {
                    volume = level
                } label: {
                    Rectangle()
                        .fill(volume >= level - 1 ? Color.black : Color(white: 0.85))
                        .frame(width: 14, height: 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white)
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
    }
}

// MARK: - Hand-drawn glyphs (no SF Symbols, matching this app's established chrome style)

/// Drawn at the exact coordinates of the reference spec's speaker SVG (viewBox 0 0 14 12) --
/// a solid cone (`M1 4H4L7 1V11L4 8H1V4Z`) plus two open sound-wave arcs drawn as cubic
/// curves (`M9 3C10.5 4.5 10.5 7.5 9 9` / `M11 1C13.5 3.5 13.5 8.5 11 11`), not an
/// approximated shape -- paired with a `.frame(width: 14, height: 12)` on the call site so
/// these coordinates map straight onto points, no scaling guesswork.
private struct SpeakerGlyph: View {
    var body: some View {
        Canvas { context, size in
            var cone = Path()
            cone.move(to: CGPoint(x: 1, y: 4))
            cone.addLine(to: CGPoint(x: 4, y: 4))
            cone.addLine(to: CGPoint(x: 7, y: 1))
            cone.addLine(to: CGPoint(x: 7, y: 11))
            cone.addLine(to: CGPoint(x: 4, y: 8))
            cone.addLine(to: CGPoint(x: 1, y: 8))
            cone.closeSubpath()
            context.fill(cone, with: .color(.black))

            var wave1 = Path()
            wave1.move(to: CGPoint(x: 9, y: 3))
            wave1.addCurve(to: CGPoint(x: 9, y: 9), control1: CGPoint(x: 10.5, y: 4.5), control2: CGPoint(x: 10.5, y: 7.5))
            context.stroke(wave1, with: .color(.black), lineWidth: 1.5)

            var wave2 = Path()
            wave2.move(to: CGPoint(x: 11, y: 1))
            wave2.addCurve(to: CGPoint(x: 11, y: 11), control1: CGPoint(x: 13.5, y: 3.5), control2: CGPoint(x: 13.5, y: 8.5))
            context.stroke(wave2, with: .color(.black), lineWidth: 1.5)
        }
    }
}

/// Exact spec coordinates (viewBox 0 0 10 12): `polygon points="1,1 9,6 1,11"`.
private struct PlayGlyph: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 9, y: 6))
            path.addLine(to: CGPoint(x: 1, y: 11))
            path.closeSubpath()
        }
        .fill(Color.black)
    }
}

private struct PauseGlyph: View {
    var body: some View {
        HStack(spacing: 2) {
            Rectangle().fill(Color.black).frame(width: 3, height: 10)
            Rectangle().fill(Color.black).frame(width: 3, height: 10)
        }
    }
}

/// The scrubber's playhead -- a white box with a 1px black border and a few thin vertical
/// grip ridges down the middle, like a real drag handle, not a bare bar or an empty box.
private struct ScrubberThumb: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.white)
            Rectangle().stroke(Color.black, lineWidth: 1)
            HStack(spacing: 1.5) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(Color.black).frame(width: 1)
                }
            }
            .padding(.vertical, 3)
        }
    }
}

/// Exact spec coordinates (viewBox 0 0 10 10): step-back is `polygon points="6,1 1,5 6,9"`
/// plus `rect x="7" y="1" width="2" height="8"`; step-forward mirrors it, bar on the left.
/// Paired with a `.frame(width: 10, height: 10)` at the call site.
private struct StepGlyph: View {
    let forward: Bool
    var body: some View {
        Canvas { context, size in
            let bar = forward
                ? Path(CGRect(x: 1, y: 1, width: 2, height: 8))
                : Path(CGRect(x: 7, y: 1, width: 2, height: 8))
            context.fill(bar, with: .color(.black))

            var triangle = Path()
            if forward {
                triangle.move(to: CGPoint(x: 4, y: 1))
                triangle.addLine(to: CGPoint(x: 9, y: 5))
                triangle.addLine(to: CGPoint(x: 4, y: 9))
            } else {
                triangle.move(to: CGPoint(x: 6, y: 1))
                triangle.addLine(to: CGPoint(x: 1, y: 5))
                triangle.addLine(to: CGPoint(x: 6, y: 9))
            }
            triangle.closeSubpath()
            context.fill(triangle, with: .color(.black))
        }
    }
}

/// Exact spec coordinates (viewBox 0 0 12 12): two equal-sized 7x7 white-filled,
/// black-stroked squares offset diagonally and overlapping (`rect x="1" y="3" .../>`
/// then `rect x="4" y="1" .../>`, the second painted on top) -- not one glyph nested
/// diagonally inside a larger one.
private struct BadgeGlyph: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                .frame(width: 7, height: 7)
                .offset(x: 1, y: 3)
            Rectangle()
                .fill(Color.white)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                .frame(width: 7, height: 7)
                .offset(x: 4, y: 1)
        }
        .frame(width: 12, height: 12, alignment: .topLeading)
    }
}

// MARK: - Bevel border

/// A 1px two-tone bevel -- white top/left, `#888888`-ish bottom/right normally (a raised
/// look); swapped when `inverted` for a recessed look. Internal, not private -- also reused
/// by VideosView.swift for the pop-up menu's raised button frame and the controls panel's
/// etched/recessed group-box edge.
struct BevelBorder: ViewModifier {
    var inverted = false

    private var topLeftColor: Color { inverted ? Color(white: 0.53) : .white }
    private var bottomRightColor: Color { inverted ? .white : Color(white: 0.53) }

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    path.addLine(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width, y: 0))
                }
                .stroke(topLeftColor, lineWidth: 1)

                Path { path in
                    path.move(to: CGPoint(x: geo.size.width, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                }
                .stroke(bottomRightColor, lineWidth: 1)
            }
        )
    }
}

extension View {
    func bevelBorder(inverted: Bool = false) -> some View {
        modifier(BevelBorder(inverted: inverted))
    }

    /// A crisp, flat 1px black border over a solid white fill -- not a 3D bevel. Matches
    /// the reference photo's controller-bar buttons, which read as plain white boxes
    /// against the dithered field, not raised/beveled chrome. Used for the controller
    /// bar's buttons; BevelBorder is kept for the pop-up menu's raised frame elsewhere.
    func buttonBoxBorder() -> some View {
        self.background(Color.white).overlay(Rectangle().stroke(Color.black, lineWidth: 1))
    }
}

#Preview {
    QuickTimePlayerChrome(title: "RetroMacCast Episode 741", model: YouTubePlayerModel(), onClose: {})
        .frame(width: 480, height: 270)
        .padding()
}
