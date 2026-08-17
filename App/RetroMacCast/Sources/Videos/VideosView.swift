import RMCCore
import SwiftUI

/// A retro "channel" jukebox for the show's YouTube footage, inspired by poolsuite.net's
/// compact player window (a dropdown "Channel:" selector, a small fixed-size video box, an
/// "off-air" static state) rather than a browsable grid -- with 252 real videos on the
/// channel, a dropdown that scans as text sidesteps the "too many thumbnails to browse"
/// problem a grid would have run into. `DitheredPattern` (built for the scrollbar) is reused
/// here; the video itself plays inside `QuickTimePlayerChrome`, an authentic 1997 QuickTime
/// Player-style window backed by `YouTubePlayerModel` (its own dedicated player, not the
/// simple page-navigation `WebViewModel` shared with Emulators -- real play/pause/scrub/
/// volume controls need actual two-way communication with the player, not just navigation).
struct VideosView: View {
    @EnvironmentObject private var appearance: AppearanceManager
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                appearance.theme.color
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

                // Same "tap anywhere else to collapse the inline player" catcher Home/Trivia
                // use -- a real Button behind everything, not .onTapGesture (proven unreliable
                // here in earlier debugging this session).
                if player.activeEpisodeId != nil {
                    Button {
                        withAnimation(.snappy) {
                            player.collapse()
                        }
                    } label: {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                }

                videosContent
            }
            .navigationTitle("Videos")
        }
    }

    // No outer FinderWindowChrome here -- the QuickTime-style player chrome inside
    // VideoJukeboxView IS the tab's primary window now, not a second one nested inside a
    // Finder-style frame.
    private var videosContent: some View {
        #if os(macOS)
        // No ClassicScrollView wrapper -- with nowPlayingPanel gone, this tab's content is
        // short enough to fit a normal window without scrolling, and the retro scrollbar
        // showing up here read as a stray extra element rather than a needed control.
        // Content just fits/clips to the available space instead of ever scrolling.
        VideoJukeboxView()
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
            .padding(24)
        #else
        ScrollView {
            VideoJukeboxView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

private struct VideoJukeboxView: View {
    @StateObject private var playerModel = YouTubePlayerModel()

    @State private var videos: [Corpus.VideoResult] = []
    @State private var selectedVideoId: String?
    @State private var selectedYear: String?
    @State private var oneBit = false
    @State private var captionsEnabled = false
    @State private var yearMenuOpen = false
    @State private var videoMenuOpen = false
    @State private var hoveredMenuKey: String?
    // Measured, not assumed -- an earlier fixed offset (guessing the button's height) had
    // the dropdown overlapping the button itself when that guess turned out wrong. This is
    // measured directly off the real button via .onGeometryChange below, so the dropdown's
    // position can't drift out of sync with the button's actual rendered size again. Two
    // separate vars (not one shared) so a measurement from one pop-up's trigger button can
    // never race with or clobber the other's.
    @State private var yearButtonHeight: CGFloat = 20
    @State private var videoButtonHeight: CGFloat = 20
    // Measured via .onGeometryChange below, not a GeometryReader wrapping the whole body --
    // a root-level GeometryReader inside a ScrollView reports the viewport's size in a way
    // that disrupts normal content-driven layout (same pitfall MuseumView.swift's cascade
    // -window positioning already worked around with this exact technique).
    @State private var availableWidth: CGFloat = 480

    private static let chromeOverhead = QuickTimePlayerChrome.titleBarHeight + QuickTimePlayerChrome.controllerBarHeight

    /// The player fills the available width (clamped to a sane range) instead of sitting in
    /// a small fixed box -- "make the player window the primary surface" means it should
    /// actually use the space it's given. 900 keeps it from getting absurdly huge on a
    /// maximized window; 480 is the floor below which the controller bar's fixed-width
    /// clusters (speaker/play/frame-step) would start crowding the scrubber. Used for BOTH
    /// normal and 1-bit mode now -- toggling the filter must never resize the player, only
    /// swap the look in place.
    private var boxSize: CGSize {
        #if os(macOS)
        let videoWidth = min(max(availableWidth, 480), 900)
        #else
        let videoWidth = min(max(availableWidth, 320), 480)
        #endif
        let videoHeight = videoWidth * 9 / 16
        return CGSize(width: videoWidth, height: videoHeight + Self.chromeOverhead)
    }

    /// An aggressive grayscale+contrast push -- the closest a CSS `filter` chain gets to a
    /// true binary black/white threshold on real video. Not a literal 1-bit dither (the
    /// embed is a cross-origin YouTube iframe, so there's no pixel-level access to it from
    /// outside -- see YouTubePlayerModel.applyCSSFilter), but combined with the heavier
    /// scanline/dither overlay below, reads as a convincing stand-in for a real 1-bit Mac
    /// display, matching the reference photo more closely than the old warm/sepia look did.
    private static let oneBitFilterCSS = "grayscale(1) contrast(3) brightness(1.05)"

    // publishedAt is a raw ISO8601 string (e.g. "2023-05-14T18:00:00Z") straight from the
    // YouTube API -- the year is always its first 4 characters, so a prefix is enough; no
    // need for DateFormatter/Calendar parsing just to extract it.
    private var videosByYear: [String: [Corpus.VideoResult]] {
        Dictionary(grouping: videos, by: { String($0.publishedAt.prefix(4)) })
    }
    private var availableYears: [String] {
        videosByYear.keys.sorted(by: >)
    }
    private var videosForSelectedYear: [Corpus.VideoResult] {
        guard let selectedYear else { return [] }
        return videosByYear[selectedYear] ?? []
    }
    private var episodeVideos: [Corpus.VideoResult] { videosForSelectedYear.filter { $0.episode != nil } }
    private var bonusVideos: [Corpus.VideoResult] { videosForSelectedYear.filter { $0.episode == nil } }
    private var selectedVideo: Corpus.VideoResult? {
        guard let selectedVideoId else { return nil }
        return videos.first { $0.id == selectedVideoId }
    }

    var body: some View {
        // Same rule as OnThisDayView/TriviaOfTheDayView: .onAppear lives on this
        // always-present VStack, never inside an `if` -- an if-gated container that starts
        // false produces no backing view, so its .onAppear would never fire.
        VStack(alignment: .leading, spacing: 14) {
            videoBox

            controlsRow
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            // Subtract this VStack's own horizontal padding (12 a side) so normalSize's
            // clamp is working with the actual space the player has to fill.
            availableWidth = newWidth - 24
        }
        .onAppear {
            if videos.isEmpty {
                videos = Corpus.shared.listVideos()
            }
        }
        .onDisappear {
            // YouTubePlayerModel's script-message-handler registration creates a reference
            // cycle that deinit alone can never break (see its teardown() doc comment) --
            // this is the explicit trigger.
            playerModel.teardown()
        }
        .onChange(of: selectedYear) { _, _ in
            // A video picked under a different year no longer belongs to the now-visible
            // list -- clearing it keeps the video pop-up's shown selection in sync with
            // what it's actually scoped to.
            selectedVideoId = nil
        }
        .onChange(of: selectedVideoId) { _, newValue in
            guard let newValue, let video = videos.first(where: { $0.id == newValue }) else { return }
            playerModel.loadVideo(id: video.id)
        }
        .onChange(of: oneBit) { _, isOn in
            playerModel.applyCSSFilter(isOn ? Self.oneBitFilterCSS : nil)
        }
        .onChange(of: captionsEnabled) { _, isOn in
            playerModel.setCaptionsEnabled(isOn)
        }
    }

    private var videoBox: some View {
        // Always the full QuickTime chrome (title bar + controller bar), even before a
        // video is picked -- "off-air" now means the placeholder image fills the content
        // area, not that the window itself is missing. QuickTimePlayerChrome supplies its
        // own square-cornered 1px border (a real QuickTime window has square corners,
        // matching FinderWindowChrome's "sharp square corners... not a soft floating card"
        // rule).
        //
        // `oneBit` is passed straight through and applied INSIDE QuickTimePlayerChrome, scoped
        // to just the video canvas -- not layered on as an overlay covering the whole chrome
        // here, per explicit direction: the title bar and controller bar must keep rendering
        // normally regardless of this toggle.
        QuickTimePlayerChrome(
            title: selectedVideo?.title ?? "RetroMacCast TV",
            model: playerModel,
            placeholderImageName: selectedVideo == nil ? "VideosPlaceholder" : nil,
            oneBit: oneBit,
            onClose: { selectedVideoId = nil }
        )
        .frame(width: boxSize.width, height: boxSize.height)
        .animation(.easeInOut(duration: 0.25), value: oneBit)
    }

    /// Square-cornered and recessed (etched into the surface), not a rounded white card --
    /// the classic Mac dialog "group box" look, via the same BevelBorder(inverted:) trench
    /// technique QuickTimePlayerChrome's scrubber groove uses, just framing this whole panel.
    private var controlsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                yearMenu
                videoMenu
            }
            // zIndex here, not just on the dropdown overlays' own content -- a zIndex set
            // deep inside an overlay doesn't hoist it above LATER SIBLINGS elsewhere in this
            // VStack (the checkbox row below paints after this row in document order
            // regardless of an overlay's own internal zIndex, confirmed empirically: the
            // checkbox row showed through on top of an open dropdown). Elevating this whole
            // row -- the one that actually owns both overlays -- against its true sibling
            // fixes it.
            .zIndex((yearMenuOpen || videoMenuOpen) ? 999 : 0)

            HStack(spacing: 16) {
                checkboxToggle("1-BIT VIDEO", isOn: oneBit) {
                    oneBit.toggle()
                }
                // Off by default (see YouTubePlayerModel.setCaptionsEnabled) -- this is the
                // user-facing control for turning them on, since cc_load_policy alone isn't
                // reliable enough to keep every video's captions off on its own.
                checkboxToggle("CAPTIONS", isOn: captionsEnabled) {
                    captionsEnabled.toggle()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white)
        // No border on this outer panel -- the box the pop-up buttons live in, as distinct
        // from the pop-up lists themselves (which keep theirs). Removed at the user's direct
        // request.
    }

    /// A sharp 12x12 square box (real System 7 checkboxes had no corner radius) with a
    /// hand-drawn X on check -- reuses CloseBoxX (FinderWindowChrome.swift, the exact same
    /// diagonal-cross shape already drawn for the window close box) at a heavier 2px stroke,
    /// rather than an SF Symbol checkmark glyph, which isn't a period-authentic mark at all.
    /// Shared by both the 1-bit and captions toggles rather than duplicated per-toggle.
    private func checkboxToggle(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2), action)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Rectangle().fill(Color.white)
                    Rectangle().stroke(Color.black, lineWidth: 1)
                    if isOn {
                        CloseBoxX()
                            .stroke(Color.black, lineWidth: 2)
                            .padding(2)
                    }
                }
                .frame(width: 12, height: 12)

                Text(label)
                    .font(.chicago(12))
                    .foregroundStyle(.black)
            }
        }
        .buttonStyle(.plain)
    }

    /// The year picker -- narrow, just needs to fit "2023". Chained to `videoMenu`: picking
    /// a year is what scopes/enables the video list next to it.
    private var yearMenu: some View {
        Button {
            yearMenuOpen.toggle()
        } label: {
            popUpButtonLabel(selectedYear ?? "Year")
        }
        .buttonStyle(.plain)
        .frame(width: 100, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            yearButtonHeight = newHeight
        }
        .overlay(alignment: .bottomLeading) {
            if yearMenuOpen {
                dropdownPopover(width: 100, height: 220) {
                    ForEach(availableYears, id: \.self) { year in
                        dropdownRow(title: year, key: "year-\(year)") {
                            selectedYear = year
                            yearMenuOpen = false
                        }
                    }
                }
                // Opens UPWARD, not down -- this row sits near the bottom of the tab's fixed,
                // non-scrolling content (VideosView deliberately has no outer ScrollView), so
                // there's rarely 220pt of room below the button before hitting the window's
                // bottom edge. A downward popover there got silently clipped by the window
                // itself, with no way to scroll to the hidden rows since they were never in
                // any hit-testable area at all. Anchoring bottomLeading and offsetting up by
                // the button's real measured height (not a guess) instead puts the popover
                // above the button, where the video box guarantees much more headroom.
                //
                // Just -yearButtonHeight, not -(yearButtonHeight + 2) -- dropdownPopover's own
                // reported size grew by 2pt (to give its drop-shadow room inside the frame
                // .compositingGroup() flattens), and .bottomLeading alignment measures from
                // that full grown size. The extra +2 here used to be the visual gap above the
                // button; now that same 2pt is already baked into the popover's own bottom
                // edge, so adding it again closed the gap to zero -- the popover's bottom sat
                // flush against the button, and the button's own top border showed right
                // through that seam as a line across the popover's last row.
                .offset(y: -yearButtonHeight)
                .zIndex(999)
            }
        }
    }

    /// A fully custom pop-up + popover, not SwiftUI's `Menu` -- the open list needs Chicago
    /// font on every row, a hard unblurred offset shadow, and inverted-black-bar hover
    /// highlighting, none of which a native `Menu` popover exposes (its rows use the system
    /// font and OS-drawn chrome). Also sidesteps the invisible-idle-text bug a native
    /// `Picker(.menu)` hit earlier this session, for the same reason a custom `Menu` label
    /// was already substituted then. `ScrollView` + `LazyVStack` stands in for the native
    /// menu's free built-in scrolling. Scoped to whichever year is picked in `yearMenu`, and
    /// disabled until one is -- there's nothing to list otherwise.
    private var videoMenu: some View {
        Button {
            videoMenuOpen.toggle()
        } label: {
            popUpButtonLabel(selectedVideo?.title ?? "— Select a video —")
        }
        .buttonStyle(.plain)
        .disabled(selectedYear == nil)
        .opacity(selectedYear == nil ? 0.4 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            videoButtonHeight = newHeight
        }
        .overlay(alignment: .bottomLeading) {
            if videoMenuOpen {
                dropdownPopover(width: 320, height: 220) {
                    dropdownRow(title: "— Select a video —", key: "none") {
                        selectedVideoId = nil
                        videoMenuOpen = false
                    }
                    if !episodeVideos.isEmpty {
                        dropdownSectionHeader("EPISODE RECORDINGS")
                        ForEach(episodeVideos) { video in
                            dropdownRow(title: video.title, key: video.id) {
                                selectedVideoId = video.id
                                videoMenuOpen = false
                            }
                        }
                    }
                    if !bonusVideos.isEmpty {
                        dropdownSectionHeader("BONUS & EXTRAS")
                        ForEach(bonusVideos) { video in
                            dropdownRow(title: video.title, key: video.id) {
                                selectedVideoId = video.id
                                videoMenuOpen = false
                            }
                        }
                    }
                }
                // Opens upward -- same reasoning as yearMenu just above, including the
                // -videoButtonHeight (not + 2) fix.
                .offset(y: -videoButtonHeight)
                .zIndex(999)
            }
        }
    }

    /// Shared closed-button chrome -- flat white box, 1px black border, Chicago text, a
    /// vertical divider, and the disclosure triangle. Identical for both pop-ups so they
    /// read as one family of control sitting side by side.
    private func popUpButtonLabel(_ text: String) -> some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.chicago(12))
                .foregroundStyle(.black)
                .lineLimit(1)
                .padding(.horizontal, 8)
            Spacer(minLength: 4)
            Rectangle().fill(Color.black.opacity(0.4)).frame(width: 1)
            PopUpTriangleGlyph()
                .fill(Color.black)
                .frame(width: 8, height: 5)
                .padding(.horizontal, 6)
        }
        .frame(height: 20)
        .background(Color.white)
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
    }

    /// Shared popover shell for both pop-ups -- solid white, 1px black border, hard unblurred
    /// offset shadow (a solid rectangle behind the white box, not SwiftUI's blurred
    /// `.shadow()`), matching the reference photo's crisp classic Mac drop shadow.
    private func dropdownPopover<Rows: View>(width: CGFloat, height: CGFloat, @ViewBuilder rows: () -> Rows) -> some View {
        // Everything -- the white box AND the shadow it casts -- now lives inside one ZStack
        // sized to the FULL (width+2, height+2) footprint, instead of the shadow rectangle
        // hanging 2pt outside a plain (width, height) frame via `.background()`. That overflow
        // is exactly what `.compositingGroup()` below was silently cropping: the group forces
        // an offscreen render pass sized to the view's own reported layout bounds, and
        // `.background()` content never expands that reported size, so the shadow -- and the
        // border stroke's own trailing 0.5pt, right at the same edge -- were being clipped
        // away the moment compositingGroup flattened everything. That's what was visible as
        // "no border on the right/bottom edges." Giving the ZStack the true full-size frame up
        // front means there's nothing left outside it for the group to cut off.
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black)
                .frame(width: width, height: height)
                .offset(x: 2, y: 2)

            ScrollView {
                // A plain VStack, not LazyVStack -- the trailing-spacer fix only ever addressed
                // the row that's last in the actual DATA, but the artifact kept reappearing on
                // whatever row was last WITHIN LAZYVSTACK'S CURRENT REALIZATION WINDOW at a
                // given scroll position (which, mid-scroll, is very often a row nowhere near
                // the true end of the list -- confirmed by reproducing it on "2011" while
                // 2009/2008/2007 were still further down, unscrolled-to). That's inherent to
                // how LazyVStack mounts/unmounts children as the viewport moves, not something
                // a spacer at the very end can reach. These lists top out around 250 rows of
                // plain text, cheap enough to render eagerly, which sidesteps the windowing
                // behavior -- and with it, every variant of this bug -- entirely rather than
                // chasing each new edge of it.
                VStack(alignment: .leading, spacing: 0) {
                    rows()
                }
            }
            // A fixed height, not maxHeight -- inside an .overlay() attached to a small
            // button, an ambiguous/flexible height leaves the ScrollView itself with no real
            // viewport to clip/scroll against.
            .frame(width: width, height: height)
            .background(Color.white)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
        }
        .frame(width: width + 2, height: height + 2, alignment: .topLeading)
        // Flattens the ENTIRE pop-up (every row, its white background, border, and shadow)
        // into one single opaque layer before it's composited against whatever sits behind
        // it in the app -- the pop-up opens upward, directly over the video box, which has
        // its own internal edges (the divider between the video area and the controller bar,
        // the controller bar's own dithered texture). Without this, those edges were bleeding
        // straight through the pop-up's "white" background wherever a row happened to overlap
        // one -- not a font artifact at all, a real opacity leak letting the actual app
        // content behind show through. Isolating the whole pop-up as one unit is what
        // guarantees nothing behind it can ever show through, regardless of what blending or
        // masking any individual row does internally.
        .compositingGroup()
    }

    /// A fixed height here too, same reasoning as `dropdownRow` -- this header used to size
    /// itself from padding alone, which (unlike the row fix) left ITS height non-integral.
    /// Since `LazyVStack` stacks children by cumulative offset, that fractional remainder
    /// carried forward into every row below it, reintroducing the exact hairline seam the
    /// row fix was supposed to kill -- just shifted to "wherever a header appears," which is
    /// exactly where the user kept spotting it (right at the top of BONUS & EXTRAS). A fixed
    /// height here closes that last non-integral gap in the stack.
    private func dropdownSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.chicago(10))
            .foregroundStyle(Retro.mutedText)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 20)
    }

    /// Shared row for both pop-ups -- `key` is the hover-highlight identity, kept separate
    /// from the displayed `title` so the year list ("year-2023") and video list (a video id,
    /// or "none" for the placeholder row) can never collide with each other.
    ///
    /// A fixed `.frame(height:)` rather than vertical padding around the text -- padding lets
    /// each row's actual height drift by sub-pixel rounding (font metrics at 12pt don't divide
    /// evenly), which was visible as a stray hairline seam cutting across the text wherever a
    /// black-hover row butted up against a white row. A shared exact height makes every row
    /// tile with its neighbors with no rounding drift to show through.
    ///
    /// Hover is a solid light-gray fill, not an inverted black-bar/white-text fill or a
    /// stroked outline. The inverted version went through several rounds -- a
    /// `ChicagoFLF`-specific artifact when asked to rasterize white fill, then a
    /// `.compositingGroup()`/blend-mode seam at the ScrollView's clip edge, then a `.mask()`
    /// rewrite, then a row-height `.clipped()` fix -- and a stray line kept reappearing
    /// somewhere new every time. Swapping in a stroked outline afterward didn't help either;
    /// `Rectangle().stroke()` elsewhere in this same component was independently confirmed to
    /// render with edges missing. A plain background color change is the one thing left that
    /// needs neither a border nor a blend/mask/composite operation -- nothing for either
    /// category of bug to attach to.
    private func dropdownRow(title: String, key: String, onSelect: @escaping () -> Void) -> some View {
        let isHovered = hoveredMenuKey == key
        return Button(action: onSelect) {
            Text(title)
                .font(.chicago(12))
                .foregroundStyle(Color.black)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 22)
                .background(isHovered ? Color.black.opacity(0.15) : Color.white)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering in
            hoveredMenuKey = hovering ? key : nil
        }
        #endif
    }
}

/// A small downward-pointing triangle, the pop-up menu's disclosure indicator.
private struct PopUpTriangleGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    VideosView()
        .environmentObject(PlayerViewModel())
        .environmentObject(AppearanceManager())
}
