import RMCCore
import SwiftUI

/// Museum tab root: a list of product categories (Compact Macintosh, iMac, iPhone, ...).
/// Tapping one pushes MuseumCategoryView (chronological model list), which pushes
/// MuseumProductDetailView (the full page: photo, synopsis, real synthesized show-history
/// paragraph, real featured moments).
struct MuseumView: View {
    @EnvironmentObject private var appearance: AppearanceManager

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

    // Quick and mechanical, not springy -- matches the snap of the real System 7 zoom effect.
    private static let zoomAnimation = Animation.easeInOut(duration: 0.18)

    private func closeCategory() {
        selectedCategory = nil
        guard openCategory != nil else { return }
        withAnimation(Self.zoomAnimation) { openCategory = nil }
    }

    /// The cascade window isn't laid out yet at the moment a double-click fires, so there's
    /// no real frame to anchor against directly. It shares the root window's measured size
    /// though, just shifted by the fixed cascade offset -- close enough over a window this
    /// size, for an animation this quick, to compute where the clicked icon sits relative
    /// to it without waiting a frame for the cascade window to render.
    private static func zoomAnchor(forIcon iconId: String, iconFrames: [String: CGRect], windowFrame: CGRect) -> UnitPoint {
        guard let iconFrame = iconFrames[iconId], windowFrame.width > 0, windowFrame.height > 0 else { return .topLeading }
        let cascadeOrigin = CGPoint(x: windowFrame.minX + 28, y: windowFrame.minY + 28)
        return UnitPoint(
            x: (iconFrame.midX - cascadeOrigin.x) / windowFrame.width,
            y: (iconFrame.midY - cascadeOrigin.y) / windowFrame.height
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                appearance.theme.color.ignoresSafeArea()
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
                    MuseumCategoryView(category: openCategory, onClose: closeCategory)
                        .frame(maxWidth: 640)
                        .padding(24)
                        .offset(x: 28, y: 28)
                        // Classic Mac OS "zoom rectangles" close/open effect: the window
                        // balloons open from and shrinks back down toward whichever icon
                        // it cascades from (see zoomAnchor(forIcon:)), rather than a fixed
                        // corner.
                        .transition(.scale(scale: 0.05, anchor: zoomAnchor).combined(with: .opacity))
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
                        zoomAnchor = Self.zoomAnchor(forIcon: category.id, iconFrames: iconFrames, windowFrame: rootWindowFrame)
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

    let category: MuseumCategory
    /// Set only for the macOS cascaded-window presentation, where this view is embedded
    /// directly inside MuseumView's ZStack rather than pushed -- wires the close box to
    /// actually dismiss it. iOS always pushes via NavigationLink instead, so it's nil there.
    var onClose: (() -> Void)? = nil

    // macOS only -- same single-click-selects/double-click-opens pattern as the Museum
    // root, since a product icon here is exactly as "foldery" as a category icon there.
    @State private var selectedProduct: MuseumProduct?
    @State private var openProduct: MuseumProduct?

    var body: some View {
        #if os(macOS)
        // Same Finder-window chrome as the Museum root -- double-click a category "folder"
        // and you land in another Finder window full of icons, cascaded on top of the one
        // you came from, not a plain system list or a full-screen push.
        FinderWindowChrome(title: category.title, statusText: "\(category.products.count) models", isActive: true, onClose: onClose) {
            productGrid
        }
        .onTapGesture {
            selectedProduct = nil
        }
        #else
        ZStack {
            appearance.theme.color.ignoresSafeArea()
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
                    .onTapGesture(count: 2) {
                        selectedProduct = product
                        openProduct = product
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
        #if os(macOS)
        .navigationDestination(item: $openProduct) { product in
            MuseumProductDetailView(product: product)
        }
        #endif
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
                .foregroundStyle(.secondary)
        }
        .frame(width: 124)
    }
}

struct MuseumProductDetailView: View {
    @EnvironmentObject private var appearance: AppearanceManager
    let product: MuseumProduct
    @State private var featuredMoments: [Corpus.CollectionItemResult] = []
    @State private var onShowParagraph: String?
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private static let fallbackParagraph = "Not enough episodes have covered this one yet -- check back as the archive gets classified further."

    var body: some View {
        ZStack {
            appearance.theme.color.ignoresSafeArea()
            #if os(macOS)
            // Same Finder-window chrome as every other window -- the product name is the
            // title bar text instead of a separate inline heading, and the close box goes
            // back rather than closing a cascade, since this is a real NavigationStack push.
            FinderWindowChrome(title: product.name, onClose: { dismiss() }) {
                ClassicScrollView {
                    detailContent
                }
                .frame(minHeight: 480, maxHeight: .infinity)
            }
            // Capped (see SearchView's matching comment), not .infinity.
            .frame(maxWidth: 700, maxHeight: 780)
            .padding(24)
            #else
            ScrollView {
                detailContent
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
                            .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            header
            Text(product.synopsis)
                .font(.system(size: 14))
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
                .foregroundStyle(.secondary)
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
                        .lineLimit(1)
                    Text(item.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
