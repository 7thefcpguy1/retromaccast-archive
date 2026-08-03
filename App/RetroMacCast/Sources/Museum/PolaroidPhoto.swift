import SwiftUI

/// Composites a product photo behind the polaroid.png frame's transparent photo window,
/// tilted slightly with a drop shadow -- gives every Museum product a consistent physical-media
/// look regardless of the source photo's own aspect ratio or licensing-driven crop.
struct PolaroidPhoto: View {
    let imageName: String
    var rotation: Angle = .degrees(-3)

    // Fractional insets of polaroid.png's transparent photo window, measured against its
    // full 1856x2272 canvas (via the alpha channel) -- lets the window position scale
    // correctly no matter what size this view is rendered at.
    private let leftInset: CGFloat = 324.0 / 1856.0
    private let rightInset: CGFloat = 318.0 / 1856.0
    private let topInset: CGFloat = 366.0 / 2272.0
    private let bottomInset: CGFloat = 653.0 / 2272.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let windowWidth = w * (1 - leftInset - rightInset)
            let windowHeight = h * (1 - topInset - bottomInset)

            ZStack {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: windowWidth, height: windowHeight)
                    .clipped()
                    .position(x: w * (leftInset + (1 - leftInset - rightInset) / 2),
                              y: h * (topInset + (1 - topInset - bottomInset) / 2))

                Image("PolaroidFrame")
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(1856.0 / 2272.0, contentMode: .fit)
        .rotationEffect(rotation)
        .shadow(color: .black.opacity(0.35), radius: 10, x: 4, y: 8)
    }
}

#Preview {
    PolaroidPhoto(imageName: "MuseumImacG3")
        .frame(width: 220)
        .padding(40)
}
