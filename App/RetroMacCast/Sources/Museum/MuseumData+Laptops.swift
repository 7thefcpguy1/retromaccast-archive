let laptopModels: [MuseumProduct] = [
    MuseumProduct(
        id: "powerbook-100-series",
        name: "PowerBook 100 Series",
        dateRange: "1991–1997",
        imageAssetName: "MuseumPowerBook100",
        imageAttribution: nil,
        synopsis: "Launched in October 1991, the original PowerBook 100/140/170 lineup established the modern laptop layout almost overnight -- the keyboard pushed back, a palm rest up front, and a centered trackball below it, a design so effective that most laptops still copy its basic geometry today. Sony built the compact 100 while Apple's own factories handled the faster 140 and 170, and the trio's instant success set the template for every PowerBook that followed.",
        collectionSlug: "powerbook-100-series"
    ),
    MuseumProduct(
        id: "powerbook-500-1400-3400-g3-series",
        name: "PowerBook 500/1400/3400/G3 Series",
        dateRange: "1994–1999",
        imageAssetName: "MuseumPowerBook3400",
        imageAttribution: "Photo by Neale Monks, licensed CC BY-SA 3.0 / GFDL, via Wikimedia Commons",
        synopsis: "Through most of the 1990s Apple's mainstream laptop line moved fast -- the 500 series brought trackpads and stereo sound in 1994, the 3400c became the world's fastest laptop on release in 1997, and the PowerBook G3 that followed pushed PowerPC performance into a road warrior's bag. Across all these revisions the silhouette stayed recognizably the same: a dark, slightly wedge-shaped clamshell built for people who wanted their desktop Mac's power on a plane.",
        collectionSlug: "powerbook-500-1400-3400-g3-series"
    ),
    MuseumProduct(
        id: "ibook",
        name: "iBook",
        dateRange: "1999–2006",
        imageAssetName: "MuseumIBook",
        imageAttribution: "Photo by Carlos Vidal, licensed CC BY 2.0, via Wikimedia Commons",
        synopsis: "Steve Jobs introduced the first iBook in July 1999 as \"an iMac to go\" -- a curved, colorful clamshell in Blueberry or Tangerine that brought the consumer-friendly design language of the iMac to a laptop for the first time, complete with a built-in handle and one of the first laptop implementations of AirPort Wi-Fi. A more conventional white polycarbonate redesign followed in 2001, and the line carried Apple's consumer laptop banner until the MacBook replaced it in 2006.",
        collectionSlug: "ibook"
    ),
    MuseumProduct(
        id: "powerbook-g4",
        name: "PowerBook G4",
        dateRange: "2001–2006",
        imageAssetName: "MuseumPowerBookG4",
        imageAttribution: "Photo by Ashley Pomeroy, licensed CC BY-SA 4.0, via Wikimedia Commons",
        synopsis: "The PowerBook G4 debuted in January 2001 with a titanium case that was startlingly thin for the era, then moved to aluminum in 2003 across 12-, 15-, and 17-inch sizes. It was Apple's flagship professional laptop for the entire Mac OS X transition, and its unibody-preceding aluminum design set the visual language every MacBook Pro since has descended from.",
        collectionSlug: "powerbook-g4"
    ),
    MuseumProduct(
        id: "macbook-polycarbonate",
        name: "MacBook (Polycarbonate)",
        dateRange: "2006–2011",
        imageAssetName: "MuseumMacBookWhite",
        imageAttribution: "Photo by Jean-Pierre Louis, licensed CC BY 2.0, via Wikimedia Commons",
        synopsis: "Replacing the iBook in May 2006, the MacBook was the consumer laptop that completed Apple's switch to Intel processors, wrapped in a simple white (later also black) polycarbonate shell. A 2009 redesign moved to a single-piece polycarbonate unibody borrowed from the aluminum MacBook Pro's construction techniques, and the plain white MacBook remained a dorm-room and classroom staple for years after.",
        collectionSlug: "macbook-polycarbonate"
    ),
    MuseumProduct(
        id: "macbook-air",
        name: "MacBook Air",
        dateRange: "2008–Present",
        imageAssetName: "MuseumMacBookAir",
        imageAttribution: "Photo by Sam Lionheart, licensed CC BY-SA 3.0, via Wikimedia Commons",
        synopsis: "Steve Jobs pulled the first MacBook Air out of a manila envelope in January 2008 to show off just how thin \"the world's thinnest notebook\" really was, trading ports and an optical drive for a wedge-shaped aluminum unibody. A 2010 redesign added the tapered shape most people picture today, and the line has continued ever since as Apple's thinnest, lightest laptop -- eventually the one that introduced Apple Silicon to the wider public in 2020.",
        collectionSlug: "macbook-air"
    ),
    MuseumProduct(
        id: "macbook-pro-unibody",
        name: "MacBook Pro (Unibody)",
        dateRange: "2008–2012",
        imageAssetName: "MuseumMacBookProUnibody",
        imageAttribution: "Photo by Raimond Spekking, licensed CC BY-SA 4.0, via Wikimedia Commons",
        synopsis: "Introduced in October 2008 alongside the redesigned MacBook Air, the unibody MacBook Pro was machined from a single block of aluminum -- a manufacturing process Apple made a centerpiece of its marketing -- and added a large glass trackpad with no separate click button. This basic shape, refined generation after generation, carried Apple's professional laptop line for four years before the Retina display arrived.",
        collectionSlug: "macbook-pro-unibody"
    ),
    MuseumProduct(
        id: "macbook-pro-retina",
        name: "MacBook Pro (Retina)",
        dateRange: "2012–2016",
        imageAssetName: "MuseumMacBookProRetina",
        imageAttribution: "Photo by SimonWaldherr, licensed CC BY-SA 4.0, via Wikimedia Commons",
        synopsis: "Unveiled at WWDC 2012, the Retina MacBook Pro dropped the unibody's optical drive and Ethernet port in favor of a thinner all-flash design built around a high-density Retina display, first on the 15-inch and then the 13-inch the following year. It was the first MacBook Pro built without any traditional hard drive option, previewing where every later Mac laptop was headed.",
        collectionSlug: "macbook-pro-retina"
    ),
    MuseumProduct(
        id: "macbook-pro-touch-bar",
        name: "MacBook Pro (Touch Bar)",
        dateRange: "2016–2020",
        imageAssetName: "MuseumMacBookProTouchBar",
        imageAttribution: "Photo by IM3847, licensed CC BY-SA 4.0, via Wikimedia Commons",
        synopsis: "The October 2016 redesign replaced the function key row with a thin OLED Touch Bar and swapped in a wider glass trackpad and shallower, more clicky-sounding \"butterfly\" keyboard switches -- a keyboard mechanism that went on to become one of the most criticized parts in Mac history for its reliability problems. Apple spent the next several years quietly revising the keyboard before abandoning butterfly switches entirely in 2019–2020.",
        collectionSlug: "macbook-pro-touch-bar"
    ),
    MuseumProduct(
        id: "macbook-pro-apple-silicon",
        name: "MacBook Pro (Apple Silicon)",
        dateRange: "2020–Present",
        imageAssetName: "MuseumMacBookProM1",
        imageAttribution: "Photo by Premeditated, licensed CC BY-SA 4.0, via Wikimedia Commons",
        synopsis: "The M1 MacBook Pro launched in November 2020 as one of the first three Macs to carry Apple's own silicon, and a 2021 follow-up redesign brought back MagSafe charging, HDMI, and an SD card slot -- ports the Touch Bar era had removed -- alongside a notched high refresh-rate display and the return of a physical function key row. The move to Apple Silicon delivered the biggest single leap in battery life and performance-per-watt in the MacBook Pro's history.",
        collectionSlug: "macbook-pro-apple-silicon"
    ),
]
