import Foundation

struct MuseumProduct: Identifiable, Hashable {
    let id: String // slug
    let name: String
    let dateRange: String
    let imageAssetName: String
    let imageAttribution: String? // nil when the image is public domain (no attribution required)
    let synopsis: String
    /// Slug of the Corpus collection supplying real featured moments + the synthesized
    /// "on the show" paragraph. Every product needs one -- there's no placeholder path anymore.
    let collectionSlug: String
}

struct MuseumCategory: Identifiable {
    let id: String // slug
    let title: String
    let iconAssetName: String
    let products: [MuseumProduct]
}

let museumCategories: [MuseumCategory] = [
    MuseumCategory(id: "compact-macintosh", title: "Compact Macintosh", iconAssetName: "MuseumCompactMacintoshIcon", products: compactMacintoshModels),
    MuseumCategory(id: "modular-macintosh", title: "Modular Macintosh", iconAssetName: "MuseumModularMacintoshIcon", products: modularMacintoshModels),
    MuseumCategory(id: "power-mac", title: "Power Mac / Mac Pro", iconAssetName: "MuseumPowerMacIcon", products: powerMacModels),
    MuseumCategory(id: "imac", title: "iMac", iconAssetName: "MuseumImacIcon", products: imacModels),
    MuseumCategory(id: "mac-mini-studio", title: "Mac mini / Mac Studio", iconAssetName: "MuseumMacMiniStudioIcon", products: macMiniStudioModels),
    MuseumCategory(id: "laptops", title: "Apple Laptops", iconAssetName: "MuseumLaptopsIcon", products: laptopModels),
    MuseumCategory(id: "newton", title: "Newton", iconAssetName: "MuseumNewtonIcon", products: newtonModels),
    MuseumCategory(id: "ipod", title: "iPod", iconAssetName: "MuseumIpodIcon", products: ipodModels),
    MuseumCategory(id: "iphone", title: "iPhone", iconAssetName: "MuseumIphoneIcon", products: iphoneModels),
    MuseumCategory(id: "ipad", title: "iPad", iconAssetName: "MuseumIpadIcon", products: ipadModels),
]
