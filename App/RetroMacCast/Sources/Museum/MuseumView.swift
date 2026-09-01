import Observation
import RMCCore
import SwiftUI

/// The cascade window isn't laid out yet at the moment a double-click fires, so there's no
/// real frame to anchor against directly. It shares the parent window's measured size
/// though, just shifted by the fixed cascade offset -- close enough over a window this size,
/// for an animation this quick, to compute where the clicked icon sits relative to it
/// without waiting a frame for the cascade window to render. File-scope, not a method on
/// either view below -- both the Museum root (category cascade) and MuseumCategoryView
/// (product cascade) need the identical math against their own icon grid and window frame.
///
/// `targetSize` defaults to `windowFrame`'s own size (the root->category call sites, where
/// the target category window's real size genuinely isn't knowable in advance -- both it and
/// the root window are capped at the same 640pt width with broadly similar content density,
/// so approximating one with the other holds up reasonably well). The category->product call
/// sites pass it explicitly instead: unlike a category window (uncapped height, driven by
/// however many products it holds -- a low-count category like Newton's 3 products can be
/// much shorter than a typical one), MuseumProductDetailView's target size on the other end
/// IS knowable in advance, since MuseumCategoryView computes it deterministically from
/// `availableSize` before ever rendering it (see `productWindowSize`). Using the category
/// window's own (often much shorter) height as the divisor there instead of the product
/// window's real height was producing a UnitPoint far outside a sane range for low-count
/// categories, which visibly ballooned the zoom-open from the wrong place.
private func museumZoomAnchor(forIcon iconId: String, iconFrames: [String: CGRect], windowFrame: CGRect, targetSize: CGSize? = nil) -> UnitPoint {
    guard let iconFrame = iconFrames[iconId], windowFrame.width > 0, windowFrame.height > 0 else { return .topLeading }
    let size = targetSize ?? windowFrame.size
    guard size.width > 0, size.height > 0 else { return .topLeading }
    let cascadeOrigin = CGPoint(x: windowFrame.minX + 28, y: windowFrame.minY + 28)
    return UnitPoint(
        x: (iconFrame.midX - cascadeOrigin.x) / size.width,
        y: (iconFrame.midY - cascadeOrigin.y) / size.height
    )
}

/// A coordinate space shared across the whole Museum cascade (root, category, and product
/// windows), rooted at MuseumView's own outermost content -- lets any level measure its own
/// on-screen frame against the same reference the tab's total available size is measured in,
/// so a freshly-opened window can be pulled back into view if it would otherwise open with
/// part of itself off screen. Distinct from each view's own `zoomSpace`/`museumCategoryZoomSpace`
/// (used for the icon-zoom-open animation's anchor math, scoped locally to each window's own
/// icon grid) -- this one specifically spans every cascade level.
private let museumContentSpace = "museumContentSpace"

/// How far short of the literal top edge a dragged category/product window's title bar stops
/// -- the vertical axis's `leadingMargin` in every `MuseumCascadeState.windowOffset` call
/// site. The earlier version stopped exactly at the edge (frame.minY >= 0), which kept the
/// title bar technically on screen but let a window be pinned right against it; reported by
/// the user, with screenshots, that holding a window there could render its content visibly
/// duplicated/ghosted for some windows and not others. Larger than the plain 12pt margin
/// used on the other three edges for exactly that reason -- see `windowOffset`'s own doc
/// comment for the redesign that replaced the whole imperative-correction system this
/// constant used to be tangled up in (a positive-floor regression, then a "can barely drag
/// up at all" regression, both downstream of trying to enforce this margin reactively inside
/// a drag gesture instead of as part of one derived position calculation).
private let museumDragTopMargin: CGFloat = 12

/// Where a window's top-left corner should land along one axis so it's fully visible with a
/// comfortable margin on both sides -- or, when it's simply too big for the available room,
/// either centered (the unavoidable overflow split evenly between both edges) or pinned to
/// the leading edge (all the overflow dumped on the trailing edge only), per
/// `pinLeadingWhenOversized`. `leadingMargin`/`trailingMargin` are independent (not one shared
/// `margin`) so the vertical axis can ask for a bigger safety buffer on top than on bottom
/// (see `museumDragTopMargin`) while the horizontal axis uses a plain, symmetric one. Used by
/// `MuseumCascadeState.windowOffset` for both axes, at every cascade level.
///
/// `pinLeadingWhenOversized` matters specifically for the vertical axis: a window's title
/// bar -- its only drag handle, and where the close box lives -- sits at the LEADING (top)
/// edge, while the trailing (bottom) edge is just scrollable content (`ClassicScrollView`
/// already handles a product page taller than its window). Centered overflow would let the
/// title bar itself scroll off the top on a window that's simply too tall to ever fully fit
/// (confirmed live: at the app's own enforced minimum size, iMac G4's title bar -- and its
/// close box -- disappeared off the top edge entirely). Pinning the leading edge instead
/// means the controls that actually need to stay reachable always do, at the cost of more of
/// the (already-scrollable) content being cut off at the bottom. The horizontal axis doesn't
/// have this asymmetry -- the close box is at the title bar's leading corner and the zoom box
/// at its trailing corner, so centering (partially preserving both) is the better compromise
/// there, same as before.
private func fittedOrigin(current: CGFloat, extent: CGFloat, available: CGFloat, leadingMargin: CGFloat, trailingMargin: CGFloat, pinLeadingWhenOversized: Bool = false) -> CGFloat {
    let usable = available - leadingMargin - trailingMargin
    guard usable > 0 else { return leadingMargin }
    if extent > usable {
        return pinLeadingWhenOversized ? leadingMargin : leadingMargin - (extent - usable) / 2
    }
    return min(max(current, leadingMargin), available - trailingMargin - extent)
}

/// Bundles the per-cascade-level state and lifecycle logic MuseumView (root -> category) and
/// MuseumCategoryView (category -> product) each need one copy of -- both cascade levels use
/// the exact same "icon grid opens a cascaded Finder-style window, draggable back into view,
/// zoom-open/close animated from the clicked icon" machinery. They used to each carry their
/// own independent copy of seven near-identical `@State` vars plus three near-identical
/// methods -- exactly the shape of duplication that made this session's fixes something that
/// had to be kept in careful sync by hand across two copies rather than living in one place.
/// The SwiftUI view-tree code at each call site (transition/zIndex/onGeometryChange/
/// overlay sizing) stays separate below -- that part is genuinely different between the two
/// levels (different width caps, different container types).
///
/// **How positioning works, after a full redesign of this class:** every earlier version of
/// this tracked a window's position as a `dragOffset` delta on top of an *implicit* base
/// position, corrected back into view at specific imperative moments -- once at open time,
/// once (only for the top edge) inside the drag gesture, and (an attempt that was reverted)
/// once on resize. Each of those moments needed to independently stay in sync with the
/// others, and each round of live user feedback this session found a new way they didn't: a
/// visible snap once the zoom-open animation finished and a live measurement caught up; a
/// margin increase that made the drag-gesture floor go positive and yank a window downward
/// the instant a drag began; the fix for THAT freezing upward dragging entirely once a
/// window's resting position sat inside the (by then far larger) margin zone; and, worst,
/// resizing the app window after opening a window left its SIZE reactively updating while
/// its POSITION stayed frozen from whenever it was last corrected, producing exactly the
/// overflowing/fragmented rendering the user's most recent screenshots showed.
///
/// `windowOffset` below replaces all of that with one calculation: it's a pure function of
/// currently-known inputs (`dragOffset`, a size, and `availableSize`), computed fresh by
/// SwiftUI every single render -- open, drag, AND resize alike -- rather than a value stored
/// and corrected at specific moments. There is no longer a separate "when do I re-run this"
/// question for each trigger, because there's only one code path and it's always live.
@MainActor
@Observable
final class MuseumCascadeState<Item: Identifiable> where Item.ID == String {
    /// The cascaded window currently open on top of this level's icon grid, if any.
    var open: Item?
    /// Single-click selection (highlight only), distinct from `open` -- real Finder icons
    /// highlight on one click and only open on two, so a stray click doesn't blow a window
    /// open on top of you.
    var selected: Item?
    /// This level's own icon-grid window's on-screen frame, measured in its local zoomSpace --
    /// the zoom-open anchor's base origin (see `museumZoomAnchor`). Used ONLY for that
    /// animation-anchor math, never for positioning -- see `windowOffset`'s own doc comment
    /// for why conflating the two (feeding a local-zoomSpace frame into a museumContentSpace
    /// positioning calculation) was a real, confirmed-live bug.
    var containerFrame: CGRect = .zero
    /// Each icon's on-screen frame within `containerFrame`'s coordinate space, keyed by id.
    var iconFrames: [String: CGRect] = [:]
    var zoomAnchor: UnitPoint = .topLeading
    /// How far the user has manually dragged this window's title bar, on top of its fixed
    /// +28/+28 cascade step -- a plain, directly-mutable value written straight through by
    /// FinderWindowChrome's drag gesture (which no longer does any bounds-clamping of its
    /// own; see that type's own doc comment). Reset to zero every time `open` is newly set
    /// (not just cleared), so a freshly opened window always starts at its default cascade
    /// position, not wherever a previously closed one had been dragged to. This is
    /// deliberately NOT the window's final on-screen offset -- `windowOffset` below derives
    /// that fresh from this plus the window's current size and the available space.
    var dragOffset: CGSize = .zero
    /// This level's own window's natural (un-positioned) size -- for a category window, whose
    /// height is content-driven (however many products it holds), this needs one live
    /// measurement; for a product window, whose size is already computed analytically (see
    /// `MuseumCategoryView.productWindowSize`), it's never actually read. Measured via a
    /// plain `.onGeometryChange(for: CGSize.self) { proxy.size }` wherever it's needed -- a
    /// view's reported SIZE doesn't depend on which coordinate space you'd ask about, or
    /// indeed on any offset applied to it, so this measurement can't repeat the
    /// coordinate-space mix-up `windowOffset` replaced.
    var naturalSize: CGSize = .zero

    static var zoomAnimation: Animation { .easeInOut(duration: 0.18) }

    func close() {
        selected = nil
        guard open != nil else { return }
        withAnimation(Self.zoomAnimation) { open = nil }
    }

    /// Resets any leftover drag offset and opens `item` with the usual zoom animation.
    /// Nothing else to do here anymore -- unlike every earlier version of this method, there's
    /// no position to predict or correct after the fact, because `windowOffset` computes the
    /// right answer fresh on every render, including the very first one after `open` changes.
    func openAnimated(_ item: Item) {
        dragOffset = .zero
        withAnimation(Self.zoomAnimation) {
            open = item
        }
    }

    /// Where this window should actually render, as an offset relative to its natural SwiftUI
    /// layout position -- computed fresh from currently-known inputs every time this is
    /// called, not a value tracked and corrected at specific moments. This is what actually
    /// closes off the whole "when do I re-run the fit-into-view correction" class of bug: it's
    /// one calculation, and SwiftUI re-evaluates it automatically whenever `dragOffset`,
    /// `size`, or `availableSize` changes -- open, drag, or resize alike.
    ///
    /// `parentOrigin` is this window's cascade anchor's own CURRENT on-screen origin in
    /// `museumContentSpace` -- the root window's measured frame for a category window (root
    /// never moves, so this is a stable reference, not something that just changed out from
    /// under this calculation), or a category window's own already-computed origin (its
    /// parent's `windowOffset`, added to ITS parent's origin) for a product window. Used only
    /// to determine whether this window's raw, un-fitted position would overflow -- NOT folded
    /// into the returned offset itself. That's because this window renders as a NESTED overlay
    /// inside its own parent's view chain (`.overlay(alignment: .topLeading)`, both levels),
    /// so whatever offset the PARENT applies to itself is already automatically inherited by
    /// this window when SwiftUI renders the whole subtree together -- folding `parentOrigin`
    /// into the return value here too would double-count it.
    func windowOffset(parentOrigin: CGPoint, size: CGSize, availableSize: CGSize) -> CGSize {
        guard availableSize.width > 0, availableSize.height > 0 else {
            return CGSize(width: 28 + dragOffset.width, height: 28 + dragOffset.height)
        }
        let rawX = parentOrigin.x + 28 + dragOffset.width
        let rawY = parentOrigin.y + 28 + dragOffset.height
        let fittedX = fittedOrigin(current: rawX, extent: size.width, available: availableSize.width, leadingMargin: 12, trailingMargin: 12)
        let fittedY = fittedOrigin(current: rawY, extent: size.height, available: availableSize.height, leadingMargin: museumDragTopMargin, trailingMargin: 12, pinLeadingWhenOversized: true)
        return CGSize(width: fittedX - parentOrigin.x, height: fittedY - parentOrigin.y)
    }
}

/// Museum tab root: a list of product categories (Compact Macintosh, iMac, iPhone, ...).
/// Tapping one pushes MuseumCategoryView (chronological model list), which pushes
/// MuseumProductDetailView (the full page: photo, synopsis, real synthesized show-history
/// paragraph, real featured moments). Both steps -- root -> category and category -> product
/// -- use the same classic Mac OS "zoom rectangles" cascade-open/close transition on macOS,
/// not just the first one; that used to be where the effect quietly stopped, with the
/// category -> product step instead falling through to a plain NavigationStack push (a
/// horizontal slide, not a zoom), the one inconsistency in an otherwise fully cascaded
/// window hierarchy.
struct MuseumView: View {
    @EnvironmentObject private var appearance: AppearanceManager
    @EnvironmentObject private var navigator: AppNavigator

    // macOS only -- root -> category cascade state (open/selected category, root window +
    // icon frames, zoom anchor, drag offset, the open category window's own natural size).
    // See MuseumCascadeState's own doc comment for why this is one shared object instead of
    // seven separate @State vars. iOS keeps real NavigationLink push instead (see iconGrid
    // below), which needs none of this.
    @State private var cascade = MuseumCascadeState<MuseumCategory>()
    private static let zoomSpace = "museumZoomSpace"

    // The Museum tab's own total available size, measured in `museumContentSpace` -- fed into
    // `cascade.windowOffset` to keep a category window fully into view, continuously (open,
    // drag, AND resize alike -- see MuseumCascadeState's own doc comment), not just at open
    // time.
    @State private var availableSize: CGSize = .zero
    // The root window's own on-screen origin in `museumContentSpace` -- root never drags, so
    // this is a stable reference that only changes on an actual resize, not something that
    // just moved out from under a same-instant calculation. The one remaining live geometry
    // read feeding the whole cascade's positioning (everything below root derives its own
    // position from this, plus pure arithmetic -- see `cascade.windowOffset`).
    @State private var rootFrame: CGRect = .zero

    /// The open category window's own actual on-screen offset, relative to its natural
    /// `.overlay(alignment: .topLeading)` position (root's own corner) -- see
    /// `MuseumCascadeState.windowOffset`'s own doc comment for what this computes and why.
    private var categoryOffset: CGSize {
        cascade.windowOffset(parentOrigin: rootFrame.origin, size: cascade.naturalSize, availableSize: availableSize)
    }
    /// The open category window's own actual on-screen ORIGIN (not just its offset) -- root's
    /// origin plus `categoryOffset` above. Forwarded down to MuseumCategoryView as the anchor
    /// its own product-level `windowOffset` call cascades from; see that parameter's own doc
    /// comment on `MuseumCategoryView` for why this is the right value to pass (and why
    /// `categoryOffset` alone, without adding it to `rootFrame.origin`, would be wrong there).
    private var categoryOrigin: CGPoint {
        CGPoint(x: rootFrame.origin.x + categoryOffset.width, y: rootFrame.origin.y + categoryOffset.height)
    }

    private func closeCategory() {
        cascade.close()
    }

    /// Opens whichever category contains `navigator.pendingMuseumProductId`, if any --
    /// doesn't clear the pending id itself, since MuseumCategoryView still needs to read it
    /// to open the actual product once its own window exists. Called from both `.onAppear`
    /// (the tab's very first mount, before this specific `cascade.open` has ever "changed")
    /// and `.onChange(of: navigator.pendingMuseumProductId)` (every later jump, while the
    /// tab's already-mounted view sits alive in the background) -- `.onAppear` alone isn't
    /// enough here, for the exact reason `SearchView.HomeHeaderView`'s doc comment already
    /// covers: SwiftUI doesn't reliably re-fire it on a tab view that's already mounted.
    private func openPendingCategoryIfNeeded() {
        guard let productId = navigator.pendingMuseumProductId,
              let category = museumCategories.first(where: { cat in cat.products.contains { $0.id == productId } })
        else { return }
        // Same reasoning as MuseumCategoryView's matching addition to its own
        // openPendingProductIfNeeded -- see that one's doc comment.
        cascade.selected = category
        cascade.zoomAnchor = museumZoomAnchor(forIcon: category.id, iconFrames: cascade.iconFrames, windowFrame: cascade.containerFrame)
        cascade.openAnimated(category)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DesktopBackgroundView(theme: appearance.theme).ignoresSafeArea()
                #if os(macOS)
                // A decorative Finder-window panel floating on the app's beige "desktop" --
                // not a real window, just the classic System 7 chrome drawn around the grid.
                // Sized to its content (no ScrollView) so the window hugs the icon grid
                // instead of stretching down to fill whatever space is offered.
                FinderWindowChrome(title: "Museum", statusText: "\(museumCategories.count) categories", isActive: cascade.open == nil) {
                    iconGrid
                }
                .frame(maxWidth: 640)
                .padding(24)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.zoomSpace))
                } action: { newValue in
                    cascade.containerFrame = newValue
                }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(museumContentSpace))
                } action: { newValue in
                    rootFrame = newValue
                }
                .onTapGesture {
                    // Clicking the parent window while a folder is open closes it, like
                    // clicking away from a classic Mac OS window -- icon taps inside still
                    // win their own gesture, so this only fires on the surrounding chrome.
                    closeCategory()
                }
                // .overlay(alignment: .topLeading), not a sibling in the ZStack above -- a
                // bare ZStack centers each child independently based on its OWN size, so a
                // category window's "natural," pre-drag position wasn't deterministic once it
                // and the root window were different sizes (the exact problem
                // MuseumCategoryView's own product overlay, just below, already solved for
                // itself one cascade level down -- see its matching comment). `.overlay`
                // makes a category window's natural position exactly root's own top-leading
                // corner, by construction, which is what lets `cascade.windowOffset` treat
                // `rootFrame.origin` as a stable, known anchor instead of needing to
                // rediscover it.
                .overlay(alignment: .topLeading) {
                    if let openCategory = cascade.open {
                        // No .frame(maxWidth: 640) here anymore -- MuseumCategoryView can now
                        // itself nest a nested MuseumProductDetailView cascade, which wants up
                        // to 700pt for itself. Capping the WHOLE subtree at 640 from out here
                        // forced that wider product window (and, visibly, its category-window
                        // sibling too) into a losing width negotiation, which is what produced
                        // the collapsed/sliver rendering. MuseumCategoryView now sets its own
                        // 640 cap internally, on just its own FinderWindowChrome, the same way
                        // MuseumProductDetailView already governs its own 700 -- each window
                        // manages its own width instead of one constraint trying to cover a
                        // subtree with two different natural sizes.
                        MuseumCategoryView(
                            category: openCategory, onClose: closeCategory, dragOffset: $cascade.dragOffset,
                            availableSize: availableSize,
                            // This category window's own actual on-screen origin -- see that
                            // parameter's own doc comment on MuseumCategoryView.
                            windowOrigin: categoryOrigin
                        )
                            // Forces SwiftUI to treat a different category as a genuinely new
                            // view instance rather than reusing this one's -- without an
                            // explicit id, jumping straight from one open category window to a
                            // different one (double-clicking a still-visible sibling icon on
                            // the root grid while this one is open) left MuseumCategoryView's
                            // own `cascade` object (its open/selected product, drag offset,
                            // etc.) intact across the swap, so the new category's window could
                            // render with the OLD category's product-detail overlay still on
                            // top of it, and no zoom-open transition played for the swap since
                            // `cascade.open` never passed through nil.
                            .id(openCategory.id)
                            .padding(24)
                            // Plain SIZE only, not a frame in any coordinate space -- see
                            // MuseumCascadeState.naturalSize's own doc comment for why this
                            // measurement can't repeat the coordinate-space mistake the old
                            // position-tracking here was built on.
                            .onGeometryChange(for: CGSize.self) { proxy in
                                proxy.size
                            } action: { newSize in
                                cascade.naturalSize = newSize
                            }
                            // The window's actual on-screen offset -- computed fresh on every
                            // render (open, drag, or resize alike) by `cascade.windowOffset`,
                            // not a value corrected at specific moments. See
                            // MuseumCascadeState's own doc comment for the whole redesign this
                            // replaced.
                            .offset(categoryOffset)
                            // Classic Mac OS "zoom rectangles" close/open effect: the window
                            // balloons open from and shrinks back down toward whichever icon
                            // it cascades from (see zoomAnchor(forIcon:)), rather than a fixed
                            // corner.
                            .transition(.scale(scale: 0.05, anchor: cascade.zoomAnchor).combined(with: .opacity))
                            // Pins this view on top of the root window for the FULL duration
                            // of both the open AND close animation, not just steady state --
                            // without an explicit zIndex, SwiftUI's default declaration-order
                            // stacking can waver mid-transition (confirmed: reported as
                            // "closing has no animation" and, one level deeper, "briefly
                            // appears behind the underlying window" -- both are the same
                            // z-order issue, just more or less visually obvious depending on
                            // how much of the departing window is still on screen when it
                            // flips behind its sibling).
                            .zIndex(1)
                    }
                }
                #else
                // No fake title bar on iOS -- the real nav bar already reads "Museum" on a
                // full-screen phone view, so a second decorative one would be redundant.
                ScrollView {
                    iconGrid
                }
                #endif
            }
            #if os(macOS)
            .coordinateSpace(.named(Self.zoomSpace))
            .coordinateSpace(.named(museumContentSpace))
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newValue in
                availableSize = newValue
            }
            .onAppear { openPendingCategoryIfNeeded() }
            .onChange(of: navigator.pendingMuseumProductId) { _, _ in openPendingCategoryIfNeeded() }
            #endif
            .navigationTitle("Museum")
        }
    }

    private var iconGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 20) {
            ForEach(museumCategories) { category in
                #if os(macOS)
                // Single click selects (highlight only); double click opens -- matching
                // real Finder, where one click can never accidentally pop a window open.
                iconGridCell(category, isSelected: cascade.selected?.id == category.id)
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.zoomSpace))
                    } action: { newValue in
                        cascade.iconFrames[category.id] = newValue
                    }
                    .onTapGesture(count: 2) {
                        cascade.selected = category
                        cascade.zoomAnchor = museumZoomAnchor(forIcon: category.id, iconFrames: cascade.iconFrames, windowFrame: cascade.containerFrame)
                        cascade.openAnimated(category)
                    }
                    .onTapGesture(count: 1) {
                        cascade.selected = category
                    }
                    // The bespoke double-tap-to-open gesture above has no VoiceOver
                    // equivalent on its own -- confirmed via grep that this whole module had
                    // zero accessibility labels/actions anywhere, unlike iOS's NavigationLink
                    // branch just below, which gets real accessibility support for free. A
                    // direct accessibilityAction bypasses the tap-count gesture entirely
                    // rather than trying to simulate a double-tap through it.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(category.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        cascade.selected = category
                        cascade.zoomAnchor = museumZoomAnchor(forIcon: category.id, iconFrames: cascade.iconFrames, windowFrame: cascade.containerFrame)
                        cascade.openAnimated(category)
                    }
                #else
                NavigationLink {
                    MuseumCategoryView(category: category)
                } label: {
                    iconGridCell(category, isSelected: false)
                }
                .buttonStyle(.plain)
                #endif
            }
        }
        .padding(20)
    }

    private func iconGridCell(_ category: MuseumCategory, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            Image(category.iconAssetName)
                .resizable()
                .interpolation(.none) // keep the pixel art crisp, no smoothing
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .opacity(isSelected ? 0.55 : 1) // classic Mac dims a selected icon's glyph
            Text(category.title)
                .font(.chicago(11))
                .foregroundStyle(isSelected ? .white : .black)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(isSelected ? Color.black : Color.clear)
        }
        .frame(width: 92)
    }
}

struct MuseumCategoryView: View {
    @EnvironmentObject private var appearance: AppearanceManager
    @EnvironmentObject private var navigator: AppNavigator

    let category: MuseumCategory
    /// Set only for the macOS cascaded-window presentation, where this view is embedded
    /// directly inside MuseumView's ZStack rather than pushed -- wires the close box to
    /// actually dismiss it. iOS always pushes via NavigationLink instead, so it's nil there.
    var onClose: (() -> Void)? = nil
    /// Forwarded straight through to this window's own FinderWindowChrome -- MuseumView
    /// (root) owns and applies the actual offset; see FinderWindowChrome.dragOffset's doc
    /// comment for why the caller has to own it rather than this view handling it internally.
    var dragOffset: Binding<CGSize>? = nil
    /// The Museum tab's total available size, forwarded from MuseumView (root) -- used the
    /// same way as there, to keep a product window fully into view via `cascade.windowOffset`.
    var availableSize: CGSize = .zero
    /// This category window's own actual on-screen ORIGIN in `museumContentSpace` -- MuseumView
    /// computes this as `rootFrame.origin + categoryOffset` (its own `cascade.windowOffset`
    /// result, already added to root's origin) and forwards it down, since that's the one
    /// piece MuseumCategoryView has no way to know on its own: `cascade.containerFrame` (this
    /// view's OWN state) measures the SAME window instead in `Self.zoomSpace`
    /// ("museumCategoryZoomSpace"), a coordinate space local to this category's own icon grid
    /// -- correct for the zoom-open anchor math it was built for, but NOT interchangeable with
    /// `museumContentSpace`, which is what `windowOffset`/`availableSize` are expressed in
    /// (confirmed live, with a screenshot, that feeding one into the other produced a
    /// plausible-looking but wrong position). Used as `parentOrigin` in this view's own product-
    /// level `cascade.windowOffset` call -- see that method's own doc comment for why passing
    /// this window's REAL current origin there (not root's raw one) is the right anchor.
    var windowOrigin: CGPoint = .zero

    // macOS only -- category -> product cascade state, same shape as MuseumView's own root ->
    // category `cascade` one level up. This view owns and applies it (rather than forwarding
    // a binding from further up) since it's the one embedding MuseumProductDetailView's
    // cascade. See MuseumCascadeState's own doc comment.
    @State private var cascade = MuseumCascadeState<MuseumProduct>()
    private static let zoomSpace = "museumCategoryZoomSpace"

    /// The product window's real target size, computed the exact same way `body`'s own
    /// `.frame(width:height:)` on MuseumProductDetailView computes it (factored out here so
    /// the two can never drift apart) -- used both as `museumZoomAnchor`'s `targetSize` (so
    /// the zoom-open anchor is computed against the product window's OWN real size rather than
    /// this often-much-shorter category window's size -- see `museumZoomAnchor`'s doc comment)
    /// and as the `size` fed into `cascade.windowOffset`, since a product window's size is
    /// already fully known analytically with no live measurement needed.
    private var productWindowSize: CGSize {
        CGSize(
            width: availableSize.width > 0 ? max(min(availableSize.width - 40, 700), 320) : 700,
            height: availableSize.height > 0 ? max(min(availableSize.height - 40, 600), 240) : 600
        )
    }

    /// The open product window's own actual on-screen offset, relative to its natural
    /// `.overlay(alignment: .topLeading)` position (this category window's own corner) -- see
    /// `MuseumCascadeState.windowOffset`'s own doc comment for what this computes and why.
    private var productOffset: CGSize {
        cascade.windowOffset(parentOrigin: windowOrigin, size: productWindowSize, availableSize: availableSize)
    }

    private func closeProduct() {
        cascade.close()
    }

    /// The second half of the Home "Featured Collection" jump -- MuseumView already opened
    /// THIS category because it contains the pending product; this finishes the job by
    /// opening the product itself and, unlike MuseumView's own step, actually clearing
    /// `pendingMuseumProductId` now that it's been fully consumed.
    private func openPendingProductIfNeeded() {
        guard let productId = navigator.pendingMuseumProductId,
              let product = category.products.first(where: { $0.id == productId })
        else { return }
        // Same zoomAnchor computation the tap-gesture handler below does -- without this,
        // this Home "Featured Collection" deep-link path opened straight from
        // cascade.openAnimated, bypassing the only place zoomAnchor was otherwise ever set,
        // so the zoom-open animated from whatever zoomAnchor happened to be left over from
        // the last manual click (or its .topLeading default on a fresh launch) instead of
        // from the product's actual icon position -- visibly wrong specifically on the one
        // flow this doc-commented feature exists for.
        cascade.selected = product
        cascade.zoomAnchor = museumZoomAnchor(forIcon: product.id, iconFrames: cascade.iconFrames, windowFrame: cascade.containerFrame, targetSize: productWindowSize)
        cascade.openAnimated(product)
        navigator.pendingMuseumProductId = nil
    }

    var body: some View {
        #if os(macOS)
        // Same Finder-window chrome as the Museum root -- double-click a category "folder"
        // and you land in another Finder window full of icons, cascaded on top of the one
        // you came from, not a plain system list or a full-screen push. `isActive` dims this
        // window the same way the Museum root dims behind THIS window when it's open -- one
        // consistent rule at every cascade depth, not just the first one.
        //
        // .overlay(alignment: .topLeading), not a ZStack -- tried a ZStack(alignment:
        // .topLeading) first, which anchored both windows to a shared origin correctly, but
        // introduced a NEW bug: a ZStack's own reported size (to ITS parent, the Museum root)
        // is the union of all its children, so opening a product -- adding a ~700pt-wide
        // child -- grew this whole view's reported size, and since the Museum root centers
        // this whole subtree, growing it shifted where its own top-left corner (and hence
        // this category window, anchored there) actually landed on screen. Confirmed live:
        // the category window visibly moved every time a product was opened or closed.
        // `.overlay` is the right tool for "attach a possibly-larger sibling without it
        // affecting my own layout size" -- the product view now renders on top of
        // FinderWindowChrome using ITS frame for layout, but never contributes to what the
        // Museum root sees as this view's own size, so the category window's on-screen
        // position stays fixed regardless of whether a product is open.
        FinderWindowChrome(title: category.title, statusText: "\(category.products.count) models", isActive: cascade.open == nil, onClose: onClose, dragOffset: dragOffset) {
            productGrid
        }
        // This window's own width cap, not an external one applied to the whole
        // MuseumCategoryView subtree -- see MuseumView's matching comment on why that
        // used to conflict with a nested MuseumProductDetailView wanting up to 700pt.
        .frame(maxWidth: 640)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.zoomSpace))
        } action: { newValue in
            cascade.containerFrame = newValue
        }
        .onTapGesture {
            // Clicking this window while a product is open closes it, same "click away
            // from the window" rule the Museum root uses for an open category.
            closeProduct()
        }
        .overlay(alignment: .topLeading) {
            if let openProduct = cascade.open {
                MuseumProductDetailView(
                    product: openProduct, onClose: closeProduct, dragOffset: $cascade.dragOffset
                )
                    // Same reasoning as MuseumView's identical .id(category.id) one cascade
                    // level up -- without this, jumping directly from one open product's
                    // detail window to a different product's (double-clicking a different
                    // still-visible product icon while this one is open) left
                    // MuseumProductDetailView's own @State (featuredMoments/onShowParagraph,
                    // both only populated in .onAppear) holding the PREVIOUS product's data,
                    // so the Featured Moments list and "ON RETROMACCAST" paragraph silently
                    // kept describing the wrong product even though the title/photo/synopsis
                    // (plain `let product` fields) updated correctly.
                    .id(openProduct.id)
                    // Explicit size, not left to .overlay(alignment:)'s implicit size
                    // proposal -- .overlay proposes the BASE view's own rendered size to its
                    // content, which is this category window's 640pt cap, not the full
                    // available space. Without this, MuseumProductDetailView's own internal
                    // `.frame(maxWidth: 700, maxHeight: 600)` never got a chance to matter --
                    // a `maxWidth` only ever shrinks a proposal, it can't request MORE than
                    // what's already been proposed, so the product window was silently
                    // capped at category's own (often narrower) width instead of its own
                    // intended one. Confirmed live via a temporary debug overlay: the
                    // measured product frame was exactly 640pt wide, category's cap, not up
                    // to 700. Driven by `availableSize` (already tracked for `windowOffset`
                    // below) instead, with the same 700/600 ceiling MuseumProductDetailView's
                    // own internal frame already caps at, so it's sized correctly regardless
                    // of how narrow or short the category window it happens to be cascading
                    // from is.
                    // max(..., 320/240) guards against a negative frame -- `availableSize`
                    // is expected to comfortably clear 40pt in either dimension in practice
                    // (RootTabView enforces a 420x560 minimum app window on macOS), but an
                    // early, not-yet-settled geometry pass could transiently report something
                    // smaller, and `.frame(width: -20, ...)` is an invalid SwiftUI frame.
                    .frame(width: productWindowSize.width, height: productWindowSize.height)
                    // The window's actual on-screen offset -- computed fresh on every render
                    // (open, drag, or resize alike) by `cascade.windowOffset`, cascading from
                    // THIS category window's own real current origin (`windowOrigin`, passed
                    // in from MuseumView). See MuseumCascadeState's own doc comment for the
                    // whole redesign this replaced.
                    .offset(productOffset)
                    .transition(.scale(scale: 0.05, anchor: cascade.zoomAnchor).combined(with: .opacity))
                    // Same fix, same reasoning as MuseumView's matching zIndex on its own
                    // category overlay -- keeps this window pinned on top of its category
                    // sibling for the whole open/close animation instead of the two
                    // occasionally trading places mid-transition.
                    .zIndex(1)
            }
        }
        .coordinateSpace(.named(Self.zoomSpace))
        .onAppear { openPendingProductIfNeeded() }
        .onChange(of: navigator.pendingMuseumProductId) { _, _ in openPendingProductIfNeeded() }
        #else
        ZStack {
            DesktopBackgroundView(theme: appearance.theme).ignoresSafeArea()
            ScrollView {
                productGrid
            }
        }
        .navigationTitle(category.title)
        #endif
    }

    private var productGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 16)], spacing: 20) {
            ForEach(category.products) { product in
                #if os(macOS)
                productCell(product, isSelected: cascade.selected?.id == product.id)
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.zoomSpace))
                    } action: { newValue in
                        cascade.iconFrames[product.id] = newValue
                    }
                    .onTapGesture(count: 2) {
                        cascade.selected = product
                        cascade.zoomAnchor = museumZoomAnchor(forIcon: product.id, iconFrames: cascade.iconFrames, windowFrame: cascade.containerFrame, targetSize: productWindowSize)
                        cascade.openAnimated(product)
                    }
                    .onTapGesture(count: 1) {
                        cascade.selected = product
                    }
                    // Same fix, same reasoning as MuseumView's matching accessibility
                    // additions on its own category grid.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(product.name)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        cascade.selected = product
                        cascade.zoomAnchor = museumZoomAnchor(forIcon: product.id, iconFrames: cascade.iconFrames, windowFrame: cascade.containerFrame, targetSize: productWindowSize)
                        cascade.openAnimated(product)
                    }
                #else
                NavigationLink {
                    MuseumProductDetailView(product: product)
                } label: {
                    productCell(product, isSelected: false)
                }
                .buttonStyle(.plain)
                #endif
            }
        }
        .padding(20)
    }

    private func productCell(_ product: MuseumProduct, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            Image(product.imageAssetName)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Retro.cardBorder, lineWidth: 1))
                .opacity(isSelected ? 0.55 : 1)

            Text(product.name)
                .font(.chicago(11))
                .foregroundStyle(isSelected ? .white : .black)
                .multilineTextAlignment(.center)
                // A handful of names enumerate 3-4 slash-separated model numbers (e.g.
                // "PowerBook 500/1400/3400/G3 Series") that don't fit in 2 lines even at the
                // widened cell below -- lineLimit(3) plus a scale-down floor means those spill
                // to a third line or shrink slightly instead of ever silently truncating with
                // an ellipsis (which hides which models are actually in the entry).
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(isSelected ? Color.black : Color.clear)
            Text(product.dateRange)
                .font(.system(size: 10))
                // Explicit, fixed color, not semantic `.secondary` -- this cell sits on
                // FinderWindowChrome's permanently-white/cream card, but its own
                // .preferredColorScheme(.light) pin doesn't reliably override the real
                // window's dark appearance for descendant content on macOS (confirmed live:
                // a dark desktop theme like Circuit Board left `.secondary` text here
                // rendering near-white and effectively invisible). `Retro.mutedText` is a
                // fixed black-opacity color, immune to the scheme flip either way -- same
                // fix as MuseumMomentCard/MuseumProductDetailView below.
                .foregroundStyle(Retro.mutedText)
        }
        .frame(width: 124)
    }
}

struct MuseumProductDetailView: View {
    @EnvironmentObject private var appearance: AppearanceManager
    let product: MuseumProduct
    @State private var featuredMoments: [Corpus.CollectionItemResult] = []
    @State private var onShowParagraph: String?
    /// Set only for the macOS cascaded-window presentation (see MuseumCategoryView's own
    /// `onClose` for the same pattern) -- wires the close box to shrink the cascade back
    /// down to the icon it opened from, matching every other window in the Museum's
    /// zoom-open/zoom-closed hierarchy. iOS always pushes via NavigationLink and relies on
    /// the system nav bar's own back button instead, so it's nil there and unused.
    var onClose: (() -> Void)? = nil
    /// Forwarded straight through to this window's own FinderWindowChrome -- MuseumCategoryView
    /// owns and applies the actual offset; see FinderWindowChrome.dragOffset's doc comment.
    var dragOffset: Binding<CGSize>? = nil

    private static let fallbackParagraph = "Not enough episodes have covered this one yet -- check back as the archive gets classified further."

    var body: some View {
        // Group, not a bare #if/#else -- lets .navigationTitle/.onAppear below apply once,
        // uniformly, to whichever platform branch was actually chosen, since chaining a
        // modifier directly after a #endif isn't valid Swift the way it would be with a real
        // if/else expression.
        Group {
        #if os(macOS)
        // No enclosing ZStack + full-bleed DesktopBackgroundView().ignoresSafeArea() here on
        // macOS -- this view is *always* presented nested, as a cascaded overlay inside
        // MuseumCategoryView's own ZStack (never a standalone top-level scene on macOS, see
        // the comment below), which already sits on top of the Museum root's own full-bleed
        // background. Including a second one here made this view's own *reported size* to
        // its parent ZStack balloon to fill all available space (that's what
        // .ignoresSafeArea() does) instead of just hugging its ~700pt content -- which badly
        // corrupted the auto-centering math MuseumCategoryView's ZStack uses to place this
        // view relative to its category-window sibling. Confirmed live: with the background
        // included, the category window sat either fully hidden behind this one or badly
        // mispositioned/overlapping, depending on what else was tried to compensate for it;
        // removing it here (letting this view report only its actual FinderWindowChrome
        // size) fixed both.
        //
        // Same Finder-window chrome as every other window -- the product name is the
        // title bar text instead of a separate inline heading. The close box zooms the
        // cascade shut via `onClose` now, not a NavigationStack pop -- this is always
        // presented as a cascaded window over MuseumCategoryView on macOS, never pushed.
        FinderWindowChrome(title: product.name, onClose: onClose, dragOffset: dragOffset) {
            ClassicScrollView {
                detailContent
            }
            .frame(minHeight: 480, maxHeight: .infinity)
        }
        // Capped (see SearchView's matching comment), not .infinity. 780 -> 600: this
        // window is cascaded two levels deep now (root -> category -> product, +28pt
        // offset at each step), not just pushed full-screen the way it used to be before
        // the category -> product zoom animation was added -- reported extending off the
        // bottom of the screen at the old, taller cap on ordinary window sizes. Content
        // that doesn't fit still scrolls fine via the ClassicScrollView above; nothing is
        // hidden, the window is just shorter.
        .frame(maxWidth: 700, maxHeight: 600)
        .padding(24)
        #else
        ZStack {
            DesktopBackgroundView(theme: appearance.theme).ignoresSafeArea()
            ScrollView {
                detailContent
            }
        }
        #endif
        }
        .navigationTitle(product.name)
        .onAppear {
            guard let match = Corpus.shared.collection(bySlug: product.collectionSlug), let id = match.id else { return }
            featuredMoments = Corpus.shared.items(forCollection: id)
            onShowParagraph = match.synthesizedParagraph
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        #if os(macOS)
        // A narrower photo than before (220pt, was 420pt) so the two-column layout fits
        // inside the same ~700pt window width every other tab uses, instead of needing its
        // own extra-wide window just for this page.
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    Text(product.synopsis)
                        .font(.system(size: 14))
                        // Explicit .black, not implicit `.primary` -- see productCell's
                        // Retro.mutedText fix above for why: FinderWindowChrome's
                        // .preferredColorScheme(.light) pin doesn't reliably override the
                        // real window's dark appearance for descendant content on macOS, so
                        // `.primary` rendered near-white (invisible on this white card) under
                        // a dark desktop theme. Confirmed live.
                        .foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    // A plain embedded photo, not the Polaroid frame -- the tilted physical-media
                    // look clashed against the flat, sharp-cornered System 7 chrome everywhere
                    // else on this page. A fixed size (not just a fixed width) is what actually
                    // makes every product's photo the same size regardless of its own aspect
                    // ratio -- scaledToFill + clipped crops each one to fit rather than letting
                    // portrait/landscape/square sources render at different heights.
                    Image(product.imageAssetName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 220, height: 220)
                        .clipped()
                        .overlay(Rectangle().stroke(Color.black, lineWidth: 1.5))
                        .padding(.vertical, 12)
                    if let attribution = product.imageAttribution {
                        Text(attribution)
                            .font(.system(size: 9))
                            .foregroundStyle(Retro.mutedText)
                            .frame(width: 220, alignment: .trailing)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            onShowSection
            featuredMomentsSection
        }
        .padding(16)
        #else
        // Narrow screen: photo spans the width up top, everything else stacks below --
        // trying to fit a side-by-side layout here would squeeze both too much.
        VStack(alignment: .leading, spacing: 16) {
            PolaroidPhoto(imageName: product.imageAssetName)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            if let attribution = product.imageAttribution {
                Text(attribution)
                    .font(.system(size: 10))
                    .foregroundStyle(Retro.mutedText)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            header
            Text(product.synopsis)
                .font(.system(size: 14))
                // See the macOS branch's identical fix above -- same dark-theme
                // invisible-text bug applies here too.
                .foregroundStyle(.black)
            onShowSection
            featuredMomentsSection
        }
        .padding(16)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(product.dateRange)
                .font(.system(size: 13))
                .foregroundStyle(Retro.mutedText)
        }
    }

    // Redesigned from a bare italic gray paragraph floating on the page -- nothing set it apart
    // as commentary rather than filler text, and italic body copy at this length reads as
    // muted/apologetic rather than inviting. Now: a warm tinted card (echoing Retro.beige, the
    // app's own desktop-pattern color) with a quote glyph anchoring it as "what the show said"
    // -- distinct from the plain-white synopsis above it -- set in the same warm brown as the
    // header instead of desaturated `.secondary` gray, upright rather than italic.
    private var onShowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 11, weight: .semibold))
                Text("ON RETROMACCAST")
                    .font(.chicago(11))
            }
            .foregroundStyle(Retro.amberText)

            Text(onShowParagraph ?? Self.fallbackParagraph)
                .font(.system(size: 14))
                .foregroundStyle(Retro.amberText.opacity(0.85))
                .lineSpacing(5)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Retro.beige.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Retro.cardBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var featuredMomentsSection: some View {
        if !featuredMoments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("FEATURED MOMENTS")
                    .font(.chicago(11))
                    .foregroundStyle(Retro.amberText)
                ForEach(featuredMoments) { item in
                    MuseumMomentCard(item: item)
                }
            }
        }
    }
}

private struct MuseumMomentCard: View {
    let item: Corpus.CollectionItemResult
    @EnvironmentObject private var player: PlayerViewModel

    private var isActive: Bool { player.activeEpisodeId == item.episode.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) {
                    if isActive {
                        player.collapse()
                    } else {
                        player.playInContext(item)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.episode.title)
                        .font(.chicago(13))
                        // Explicit .black, not implicit `.primary` -- see MuseumProductDetailView's
                        // synopsis fix above for why (FinderWindowChrome's dark-theme-under-macOS
                        // gotcha). Confirmed live: this card rendered entirely blank under a dark
                        // desktop theme (Circuit Board) with no visible title or blurb at all.
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Text(item.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(Retro.mutedText)
                        .lineLimit(3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isActive {
                InlinePlayer()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(isActive ? Retro.amberText.opacity(0.4) : Retro.cardBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }
}

#Preview {
    MuseumView()
        .environmentObject(AppearanceManager())
}
