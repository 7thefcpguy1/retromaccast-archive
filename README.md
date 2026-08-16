# RetroMacCast

An app for exploring 20 years of the [RetroMacCast](https://retromaccast.libsyn.com) podcast (James & John) — search, browse, relive every episode's transcript and show notes, and boot a real classic Mac, wrapped in a UI that pays homage to the classic Mac look. Being built with the intent to offer it to the hosts as the show's official app.

## Architecture

Three parts:

1. **Pipeline** (`pipeline/`, this repo) — a Swift CLI that crawls the full episode archive, transcribes every episode locally with whisper.cpp, and classifies/synthesizes it into a searchable SQLite corpus via the Claude API.
2. **App** (`App/`, Xcode project `RetroMacCast.xcodeproj`, generated via xcodegen from `App/project.yml`) — a SwiftUI client targeting iOS 18+ and macOS 15+ from one shared codebase (`App/RetroMacCast/Sources`).
3. **Weekly Sync** (`.github/workflows/weekly-sync.yml`) — a GitHub Actions job that re-runs the pipeline incrementally against new episodes and publishes the result as a GitHub Release asset. The app checks for and downloads updates on its own (see "Weekly sync + Settings" below) — nothing here runs on end users' devices, and no Claude API key ever ships in the app.

## Data sourcing — what we learned the hard way

- **Archive.org is a dead end.** Their mirror of the show (`podcasts_mirror_godane` collection) 401s on every audio file — access-restricted, likely after a rights complaint. Don't rely on it.
- **Libsyn is the single source of truth**, covering the entire history back to episode 1 (Dec 18, 2006) through the site's monthly archive pages (`retromaccast.libsyn.com/{year}/{month}`), not just the live RSS feed (which only goes back to ep. 360).
- **Audio URL resolution is fragile — read carefully:**
  - Each episode's embed page (`html5-player.libsyn.com/embed/episode/id/{id}/...`) has a `data-url` attribute that looks like the audio link but is **unreliable** — for many episodes it just points back at the episode's webpage, not the audio file.
  - The **actual** reliable source is a `playlistItem` JS object embedded in that same page, with a `media_url` field. Always use that.
  - Resolved URLs are **signed and expire in minutes** (~8 min observed). Never resolve in bulk ahead of time — resolve immediately before each download, in the same loop iteration.
- Swift's stdout is fully buffered when redirected to a file (as with `nohup ... > log.txt`), so tailing the log for progress is unreliable — use `rmc-pipeline stats` (reads the DB directly) instead.
- Downloaded audio isn't always `.m4a` — most episodes are, but a few resolve to `.mp3` URLs. Don't hardcode the extension on the saved file: ffmpeg's demuxer probing leans on it for ambiguous containers, and a real mp3 saved as `.m4a` fails with "moov atom not found" (it goes looking for an mp4 container that isn't there). Always derive the local filename's extension from the resolved URL's actual path extension.
- The resolved `media_url` comes back as plain `http://`, even though it immediately 301-redirects to `https://`. That's fine for the pipeline's own downloads (plain `URLSession`/curl follow the redirect without complaint), but the **app**'s `AVURLAsset` playback silently fails on it — App Transport Security blocks the insecure request before the redirect is ever followed, and the failure doesn't surface as a visible error since duration-loading is wrapped in `try?`. `PlayerViewModel` upgrades the scheme to `https://` before handing the URL to `AVURLAsset` rather than adding a blanket ATS exception.

## Pipeline usage

```
cd pipeline
swift build -c release

# Walk every monthly archive page, upsert episode metadata (title, date, show notes, Libsyn item id)
.build/release/rmc-pipeline crawl-index

# Resolve + download + transcribe + store, one episode at a time (safe to re-run, only touches pending episodes)
.build/release/rmc-pipeline resolve-audio
.build/release/rmc-pipeline transcribe-batch [--limit N] [--model path/to/model.bin]

# Classify newly-transcribed episodes into curated collections (Claude API; upserts collections.json first)
.build/release/rmc-pipeline classify [--collections-file collections.json] [--limit N]

# Clear the synthesized paragraph for any collection touched by episodes classified since a
# given timestamp, so the next `synthesize` run regenerates just that paragraph instead of
# skipping it as already-done
.build/release/rmc-pipeline reset-stale-synthesis --since 2026-01-01T00:00:00Z

# Generate/refresh each collection's "ON RETROMACCAST" summary paragraph (Claude API; skips
# collections that already have one, which is why reset-stale-synthesis exists)
.build/release/rmc-pipeline synthesize [--limit N]

# Write corpus/manifest.json (episode count + latest episode) -- what the app's Settings
# window and the weekly-sync workflow both use as a cheap "did anything change" check
.build/release/rmc-pipeline export-manifest [--output corpus/manifest.json]

# Mine collection_items blurbs for standalone trivia facts (Claude API). Only sources from
# items with a resolved segmentId -- the only ones with a real timestamp -- so every fact
# with an episode link is guaranteed to jump to its actual moment, never just episode start.
# --since limits to episodes classified after a timestamp for cheap incremental top-ups;
# --limit-batches caps how many (50-episode) batches run, for a cheap test before the real one.
.build/release/rmc-pipeline generate-trivia [--batch-size 50] [--since <ISO8601>] [--limit-batches N]

# Check progress
.build/release/rmc-pipeline stats
```

Every subcommand takes `--db path/to/rmc.sqlite` (defaults to `corpus/rmc.sqlite`) and is safe to re-run — each only touches rows that haven't been processed yet (`transcriptText IS NULL`, `classifiedAt IS NULL`, `synthesizedParagraph IS NULL`), so incremental runs never re-transcribe or re-spend Claude tokens on episodes that are already done. `generate-trivia` is the one exception worth calling out: it's not part of the automated weekly run (see "Weekly sync + Settings" below) — run it manually/periodically instead, whenever there's a meaningful backlog of newly-classified episodes.

Whisper model: `models/ggml-small.en.bin` (chosen over base.en for accuracy on Apple/Mac proper nouns — base.en mangled things like "Woz" → "Waz", "MacWorld" → "Mackerel"). Batch run uses a custom `--prompt` of show-specific vocabulary to bias transcription further. `classify`/`synthesize`/`generate-trivia` all use `claude-opus-4-8` (see `ClaudeClassifier.swift`); a typical week of new-episode processing (transcription is free/local; only classify+synthesize hit the API) costs on the order of $0.15–0.25. A full `generate-trivia` bootstrap pass over the whole archive is a one-time ~$0.70–1.00; incremental `--since` top-ups afterward cost pennies.

Run the full backfill detached so it survives closing the terminal:
```
nohup caffeinate -s .build/release/rmc-pipeline transcribe-batch > logs/full-run.log 2>&1 < /dev/null &
disown
```

## Corpus schema (SQLite, `corpus/rmc.sqlite`)

- `episodes` — id (Libsyn item id), episode number, title, page URL, pub date, show notes HTML, audio URL, transcript status/text, `classifiedAt` (nil until the `classify` pass has run on this episode)
- `transcript_segments` — per-episode timestamped chunks (startMs/endMs/text) for jump-to-moment playback and search result snippets
- `episodes_fts` — FTS5 virtual table synchronized over title + show notes + transcript text
- `collections` — the Museum's curated taxonomy (product timelines like "iPad Air Series", recurring segments like eBay Finds), sourced from `pipeline/collections.json`; each row carries an optional `synthesizedParagraph` (the "ON RETROMACCAST" summary shown in the app)
- `collection_items` — one row per episode moment matched to a collection by `classify` (episode id, transcript segment id when a verbatim quote was locatable, a one-sentence blurb)
- `trivia_facts` — standalone facts mined by `generate-trivia` for the app's Trivia tab (fact text, optional episode/segment/timestamp link for "hear it here" playback, `NULL` for a genuine cross-episode aggregate fact rather than one tied to a single moment)

`pipeline/collections.json` is the taxonomy's source of truth — currently 10 top-level Museum categories (Compact Macintosh, Modular Macintosh, Power Mac/Mac Pro, iMac, Mac mini/Studio, Apple Laptops, Newton, iPod, iPhone, iPad) covering 61 individual product/segment collections. Editing it and re-running `classify` upserts titles/descriptions in place rather than duplicating rows.

## App structure

`App/RetroMacCast/Sources/`:

- **`App/`** — `RetroMacCastApp.swift` (entry point, owns the shared `CorpusUpdateManager` and `AppearanceManager`), `RootTabView.swift` (the four-tab shell; also drives `.preferredColorScheme` from the selected desktop theme — see "Classic Mac visual chrome" below), `RMCBadge.swift` (an original circular podcast-badge illustration, inspired by the show's real logo composition but not a copy of it — see that section for why)
- **`Search/`** — the **Home** tab: full-text search (FTS5 across title/show notes/transcript, relevance/date sorting) with an empty-state landing view ("This Week in RetroMacCast History" — an on-this-day feature pulling from real episode air dates, plus `PlayerViewModel`, the shared AVPlayer-backed playback engine every tab uses)
- **`Museum/`** — the **Museum** tab: the curated-collections taxonomy as a browsable product museum (category → product model → detail page with photo, synopsis, and real synthesized/quoted moments from the show), plus the shared classic Mac chrome components (see below) used across the whole app
- **`Emulator/`** — the **Emulators** tab: a `WKWebView` pointed at [Infinite Mac](https://infinitemac.org), letting you boot a real classic Mac OS instance inside the app, with a small back/forward/home browser toolbar since the site itself links out to sub-pages (e.g. its LLM-driven "Infinite Monkey" mode). Deliberately just loads their hosted page rather than embedding an emulator core directly — Infinite Mac's own code is Apache-2.0, but the emulator cores it runs (Basilisk II, SheepShaver, Mini vMac) are GPL, and GPL + App Store distribution have a documented history of not getting along (see: VLC's years off the App Store). Loading a URL in a WebView ships none of that code in this app, sidestepping the question entirely — and it means we don't have to prompt users for a ROM dump either, since Infinite Mac already handles that.
- **`Trivia/`** — the **Trivia** tab: a featured "Did You Know?" fact plus a browsable list of others from `trivia_facts`, freshly randomized each app launch (and on demand via a "New Facts" button); tapping a fact tied to an episode moment jumps playback straight there.
- **`Settings/`** — the macOS-only Settings window (`Cmd+,`, three tabs — Updates, Background, About), `CorpusUpdateManager` (see below), `AppearanceManager` + `DesktopTheme` (the desktop background picker)
- **`Data/`** — `Corpus.swift`, the GRDB wrapper every other tab queries

## Classic Mac visual chrome

Home, Museum, Trivia, and the product detail pages share a custom System 7 look (`Museum/FinderWindowChrome.swift`, `Museum/ClassicScrollBar.swift`) rather than native platform chrome: a pinstripe title bar with functional close/zoom boxes, sharp square corners with no drop shadow (a real classic window sits flat on the desktop), and a hand-built scrollbar — a dithered checkerboard track with a navy/sky-blue thumb textured with horizontal ridge lines when there's content to scroll (the thumb is a fixed size, never stretching to represent scroll proportion the way modern scrollbars do), collapsing to a flat, undithered track with no thumb at all when the content already fits — matching how the real thing behaved in both states. Museum category windows cascade open from the icon you double-click, complete with a System-7-style "zoom rectangles" open/close animation. Each window's own content always renders in light appearance regardless of system Dark Mode or the selected desktop theme (see below) — a real Finder window didn't repaint itself for a color scheme, and it keeps every card legible no matter what's picked as a backdrop.

None of this was guessed from memory — every detail (the thumb's actual construction, the zoom box's "cascading rectangles" glyph, the arrow's plain-triangle shape with its pixel-staircase edges, the track's flat-vs-dithered states) was checked directly against a real System 7.5.3 window rendered live by Infinite Mac in this app's own Emulators tab, or pixel-sampled directly from authentic System 7.0 screenshots (the classic Open File dialog, the Software License install dialog), through several rounds of correction.

**Desktop backgrounds** (Settings → Background) let you swap the backdrop behind all of this chrome across 11 Apple-era options, from Apple II beige (1977) through the original Bondi Blue/fruit-colored iMac G3 lineup to Space Gray (Modern) — colors matched against real product photos, not invented. Picking Space Gray also switches the app's native title bar text to light-on-dark automatically (`DesktopTheme.isDark` drives `RootTabView`'s `.preferredColorScheme`), since that's the one theme dark enough that the default dark-on-light title text would otherwise be unreadable.

**The app's own mascot/badge** (`App/RMCBadge.swift`, shown in Settings → About) is an original SwiftUI illustration — a circular badge with hand-laid-out curved text wrapping a compact-Mac icon — deliberately built from scratch rather than using the show's actual copyrighted logo file, since that would need the hosts' sign-off first. Swapping in their real artwork once that's in hand is a one-line change.

The Settings window deliberately does *not* use this chrome — it's a normal native `Form`/`Section`-based macOS Preferences pane, since a Settings window is expected to look and behave like every other Mac app's, not like retro content (it does force light appearance too, for the same legibility reason as the FinderWindowChrome content above). iOS never gets the custom chrome either (native `NavigationStack`/`.searchable`), for the same "don't fight the platform's own conventions" reason.

## Weekly sync + Settings

New episodes flow into the app automatically, without any manual per-episode decision or expensive re-analysis of the whole archive:

1. **`.github/workflows/weekly-sync.yml`** runs every Monday (plus a manual `workflow_dispatch` trigger) on a `macos-latest` runner: downloads the most recently published corpus, runs `crawl-index` → `resolve-audio` → `transcribe-batch` → `classify` → `reset-stale-synthesis` → `synthesize` → `export-manifest`, and — only if the episode count actually changed — publishes a new GitHub Release tagged `corpus-YYYY-MM-DD` with `rmc.sqlite` and `manifest.json` as assets. The `ANTHROPIC_API_KEY` lives only as a repo secret; it never touches app code or a shipped binary.
2. **`CorpusUpdateManager`** (owned by `RetroMacCastApp`, shared between the main window and Settings) checks the repo's latest release once per launch — but only actually hits the network if 7+ days have passed since the last check, which is what makes "weekly" the default cadence without needing a real background-refresh scheduler. It downloads the new `rmc.sqlite` to a temp file, opens it read-only and runs a sanity query before committing to it (so a truncated download can't brick the app), then atomically swaps it into `~/Library/Application Support/RetroMacCast/` and calls `Corpus.reloadFromDisk()`.
3. **`Corpus.shared` is a `var`, not a `let`** — `reloadFromDisk()` just reassigns it, so every existing `Corpus.shared.search(...)`-style call site picks up the new data on its very next call. No dependency-injection rework needed anywhere else in the app.
4. **Settings → Updates** (macOS only, `Cmd+,`) shows the current archive's episode count and latest episode, when it last checked, and a manual "Check Now" button that bypasses the weekly gate. The other two Settings tabs, Background and About, are pure client-side preferences (desktop theme, show links) with nothing to sync.

## Status (as of this writing)

- **Pipeline**: complete and self-sustaining. 742 episodes transcribed, 0 failures, classified into 61 collections across 10 Museum categories, 94 trivia facts mined (every episode-linked one anchored to a real moment); the weekly sync job keeps this current going forward without manual intervention.
- **App**: Home (search + on-this-day), Museum (full System 7-chrome browsing experience), Emulators (real classic Mac OS via Infinite Mac), and Trivia (rotating facts with jump-to-moment playback) tabs are built and verified on both iOS and macOS. Settings (Updates, Background theme picker, About) is built and verified on macOS.
- **Weekly sync**: live. Repo is [7thefcpguy1/retromaccast-archive](https://github.com/7thefcpguy1/retromaccast-archive) (public), `ANTHROPIC_API_KEY` is configured as a repo secret, a baseline release (`corpus-2026-08-05`, the current 742-episode corpus) has been published so future runs only ever process new episodes incrementally, and the workflow has been triggered manually to confirm it runs end-to-end.

## Open items

- **Reach out to James & John before going much further** — this is being built with the intent to offer it as the show's official app, not just a personal fan project, which raises the stakes on quality/reliability and makes their input on scope worth getting early rather than after the fact. Their own collection photos would also beat any stock/Wikimedia imagery for illustrating specific models, and their actual logo file — once they're comfortable sharing it — should replace `RMCBadge.swift`'s original placeholder illustration.
- Font licensing check before shipping ChicagoFLF broadly (its embedded license text states public domain, but worth a final look).
- A handful of `.secondary`/`.primary` SwiftUI text colors rendered fully invisible in two specific spots (Home's "Also From This Day" list, Trivia's "More From the Archive" list) despite working everywhere else in the app; fixed with explicit colors (`Retro.mutedText` in `RetroStyle.swift`) but the actual root cause was never pinned down. Worth a closer look if it recurs in a new inline conditional list.
- `TriviaHeroCard`/`TriviaCompactRow` (`Trivia/TriviaView.swift`) duplicate `OnThisDayHeroCard`/`OnThisDayCompactRow` (`Search/SearchView.swift`) almost entirely — worth extracting into one shared "playable moment card" component so a future style fix doesn't need to land in both places.
- Clip-sharing (shareable "quote card" deep links to a specific trivia/search moment) is still just an idea, not started.
