import RMCCore
import SwiftUI

/// The cascade window isn't laid out yet at the moment a double-click fires, so there's no
/// real frame to anchor against directly. It shares the parent window's measured size
/// though, just shifted by the fixed cascade offset -- close enough over a window this size,
/// for an animation this quick, to compute where the clicked icon sits relative to it
/// without waiting a frame for the cascade window to render. File-scope, not a method on
/// either view below -- both the Museum root (category cascade) and MuseumCategoryView
/// (product cascade) need the identical math against their own icon grid and window frame.
private func museumZoomAnchor(forIcon iconId: String, iconFrames: [String: CGRect], windowFrame: CGRect) -> UnitPoint {
    guard let iconFrame = iconFrames[iconId], windowFrame.width > 0, windowFrame.height > 0 else { return .topLeading }
    let cascadeOrigin = CGPoint(x: windowFrame.minX + 28, y: windowFrame.minY + 28)
    return UnitPoint(
        x: (iconFrame.midX - cascadeOrigin.x) / windowFrame.width,
        y: (iconFrame.midY - cascadeOrigin.y) / windowFrame.height
    )
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

    // macOS only -- which category "folder" is currently open in a cascaded window on top
    // of the root one. iOS keeps real NavigationLink push instead (see iconGrid below).
    @State private var openCategory: MuseumCategory?
    // macOS only -- single-click selection, distinct from opening. Real Finder icons
    // highlight on one click and only open on two, so a stray click doesn't blow a
    // window open on top of you.
    @State private var selectedCategory: MuseumCategory?

    // macOS only -- tracks where the root window and each icon actually land on screen, so
    // the cascade window's zoom transition can balloon out of the icon that was clicked
    // instead of a fixed corner. Read via onGeometryChange rather than a fixed layout
    // assumption, since the grid reflows with window width.
    @State private var rootWindowFrame: CGRect = .zero
    @State private var iconFrames: [String: CGRect] = [:]
    @State private var zoomAnchor: UnitPoint = .topLeading
    private static let zoomSpace = "museumZoomSpace"

    // Drag position for the open category window, on top of its base +28/+28 cascade
    // offset -- lets a window that would otherwise land off the bottom of a smaller app
    // window (reported by the user) just be dragged back into view, real-Finder style,
    // instead of chasing an exact size cap that fits every window size. Reset to zero
    // everywhere `openCategory` is newly set (not just cleared) so a freshly opened category
    // always starts at its default cascade position, not wherever a previously closed one
    // had been dragged to.
    @State private var categoryDragOffset: CGSize = .zero

    // Quick and mechanical, not springy -- matches the snap of the real System 7 zoom effect.
    private static let zoomAnimation = Animation.easeInOut(duration: 0.18)

    private func closeCategory() {
        selectedCategory = nil
        guard openCategory != nil else { return }
        withAnimation(Self.zoomAnimation) { openCategory = nil }
    }

    /// Opens whichever category contains `navigator.pendingMuseumProductId`, if any --
    /// doesn't clear the pending id itself, since MuseumCategoryView still needs to read it
    /// to open the actual product once its own window exists. Called from both `.onAppear`
    /// (the tab's very first mount, before this specific `openCategory` has ever "changed")
    /// and `.onChange(of: navigator.pendingMuseumProductId)` (every later jump, while the
    /// tab's already-mounted view sits alive in the background) -- `.onAppear` alone isn't
    /// enough here, for the exact reason `SearchView.HomeHeaderView`'s doc comment already
    /// covers: SwiftUI doesn't reliably re-fire it on a tab view that's already mounted.
    private func openPendingCategoryIfNeeded() {
        guard let productId = navigator.pendingMuseumProductId,
              let category = museumCategories.first(where: { cat in cat.products.contains { $0.id == productId } })
        else { return }
        categoryDragOffset = .zero
        withAnimation(Self.zoomAnimation) { openCategory = category }
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
                FinderWindowChrome(title: "Museum", statusText: "\(museumCategories.count) categories", isActive: openCategory == nil) {
                    iconGrid
                }
                .frame(maxWidth: 640)
                .padding(24)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.zoomSpace))
                } action: { newValue in
                    rootWindowFrame = newValue
                }
                .onTapGesture {
                    // Clicking the parent window while a folder is open closes it, like
                    // clicking away from a classic Mac OS window -- icon taps inside still
                    // win their own gesture, so this only fires on the surrounding chrome.
                    closeCategory()
                }

                if let openCategory {
                    // Cascaded on top and offset, like double-clicking a folder in real
                    // Finder -- the parent window stays put (now dimmed/inactive) behind it.
                    //
                    // No .frame(maxWidth: 640) here anymore -- MuseumCategoryView can now
                    // itself nest a nested MuseumProductDetailView cascade, which wants up to
                    // 700pt for itself. Capping the WHOLE subtree at 640 from out here forced
                    // that wider product window (and, visibly, its category-window sibling
                    // too) into a losing width negotiation inside one ZStack, which is what
                    // produced the collapsed/sliver rendering. MuseumCategoryView now sets its
                    // own 640 cap internally, on just its own FinderWindowChrome, the same way
                    // MuseumProductDetailView already governs its own 700 -- each window
                    // manages its own width instead of one constraint trying to cover a
                    // subtree with two different natural sizes.
                    MuseumCategoryView(category: openCategory, onClose: closeCategory, dragOffset: $categoryDragOffset)
                        .padding(24)
                        // Base cascade offset plus whatever the user has dragged this
                        // window by -- see categoryDragOffset's own doc comment.
                        .offset(x: 28 + categoryDragOffset.width, y: 28 + categoryDragOffset.height)
                        // Classic Mac OS "zoom rectangles" close/open effect: the window
                        // balloons open from and shrinks back down toward whichever icon
                        // it cascades from (see zoomAnchor(forIcon:)), rather than a fixed
                        // corner.
                        .transition(.scale(scale: 0.05, anchor: zoomAnchor).combined(with: .opacity))
                        // Pins this view on top of the root window for the FULL duration of
                        // both the open AND close animation, not just steady state -- without
                        // an explicit zIndex, SwiftUI's default declaration-order stacking can
                        // waver mid-transition (confirmed: reported as "closing has no
                        // animation" and, one level deeper, "briefly appears behind the
                        // underlying window" -- both are the same z-order issue, just more or
                        // less visually obvious depending on how much of the departing window
                        // is still on screen when it flips behind its sibling).
                        .zIndex(1)
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
                iconGridCell(category, isSelected: selectedCategory?.id == category.id)
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.zoomSpace))
                    } action: { newValue in
                        iconFrames[category.id] = newValue
                    }
                    .onTapGesture(count: 2) {
                        selectedCategory = category
                        zoomAnchor = museumZoomAnchor(forIcon: category.id, iconFrames: iconFrames, windowFrame: rootWindowFrame)
                        categoryDragOffset = .zero
                        withAnimation(Self.zoomAnimation) { openCategory = category }
                    }
                    .onTapGesture(count: 1) {
                        selectedCategory = category
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

    // macOS only -- same single-click-selects/double-click-opens pattern as the Museum
    // root, since a product icon here is exactly as "foldery" as a category icon there.
    @State private var selectedProduct: MuseumProduct?
    @State private var openProduct: MuseumProduct?
    // Same reasoning as MuseumView's categoryDragOffset, one cascade level down -- this
    // view owns and applies it (rather than forwarding a binding from further up) since it's
    // the one embedding MuseumProductDetailView's cascade.
    @State private var productDragOffset: CGSize = .zero

    // Same zoom-cascade machinery as MuseumView's own root -> category step (window frame,
    // per-icon frames, a zoom anchor, a quick mechanical animation), scoped to its own
    // coordinate space so a product zooms open from wherever its icon actually sits inside
    // THIS category window, not the outer Museum root's grid.
    @State private var windowFrame: CGRect = .zero
    @State private var iconFrames: [String: CGRect] = [:]
    @State private var zoomAnchor: UnitPoint = .topLeading
    private static let zoomSpace = "museumCategoryZoomSpace"
    private static let zoomAnimation = Animation.easeInOut(duration: 0.18)

    private func closeProduct() {
        selectedProduct = nil
        guard openProduct != nil else { return }
        withAnimation(Self.zoomAnimation) { openProduct = nil }
    }

    /// The second half of the Home "Featured Collection" jump -- MuseumView already opened
    /// THIS category because it contains the pending product; this finishes the job by
    /// opening the product itself and, unlike MuseumView's own step, actually clearing
    /// `pendingMuseumProductId` now that it's been fully consumed.
    private func openPendingProductIfNeeded() {
        guard let productId = navigator.pendingMuseumProductId,
              let product = category.products.first(where: { $0.id == productId })
        else { return }
        productDragOffset = .zero
        withAnimation(Self.zoomAnimation) { openProduct = product }
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
        FinderWindowChrome(title: category.title, statusText: "\(category.products.count) models", isActive: openProduct == nil, onClose: onClose, dragOffset: dragOffset) {
            productGrid
        }
        // This window's own width cap, not an external one applied to the whole
        // MuseumCategoryView subtree -- see MuseumView's matching comment on why that
        // used to conflict with a nested MuseumProductDetailView wanting up to 700pt.
        .frame(maxWidth: 640)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.zoomSpace))
        } action: { newValue in
            windowFrame = newValue
        }
        .onTapGesture {
            // Clicking this window while a product is open closes it, same "click away
            // from the window" rule the Museum root uses for an open category.
            closeProduct()
        }
        .overlay(alignment: .topLeading) {
            if let openProduct {
                MuseumProductDetailView(product: openProduct, onClose: closeProduct, dragOffset: $productDragOffset)
                    // Base cascade offset plus whatever the user has dragged this window
                    // by -- see MuseumView's matching categoryDragOffset comment.
                    .offset(x: 28 + productDragOffset.width, y: 28 + productDragOffset.height)
                    .transition(.scale(scale: 0.05, anchor: zoomAnchor).combined(with: .opacity))
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
                productCell(product, isSelected: selectedProduct?.id == product.id)
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.zoomSpace))
                    } action: { newValue in
                        iconFrames[product.id] = newValue
                    }
                    .onTapGesture(count: 2) {
                        selectedProduct = product
                        zoomAnchor = museumZoomAnchor(forIcon: product.id, iconFrames: iconFrames, windowFrame: windowFrame)
                        productDragOffset = .zero
                        withAnimation(Self.zoomAnimation) { openProduct = product }
                    }
                    .onTapGesture(count: 1) {
                        selectedProduct = product
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
            let collections = Corpus.shared.listCollections()
            guard let match = collections.first(where: { $0.slug == product.collectionSlug }), let id = match.id else { return }
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
