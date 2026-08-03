# RetroMacCast

An app for exploring 20 years of the [RetroMacCast](https://retromaccast.libsyn.com) podcast (James & John) — search, browse, and relive every episode's transcript and show notes, wrapped in a UI that pays homage to the classic Mac look. Being built with the intent to offer it to the hosts as the show's official app.

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

# Check progress
.build/release/rmc-pipeline stats
```

Every subcommand takes `--db path/to/rmc.sqlite` (defaults to `corpus/rmc.sqlite`) and is safe to re-run — each only touches rows that haven't been processed yet (`transcriptText IS NULL`, `classifiedAt IS NULL`, `synthesizedParagraph IS NULL`), so incremental runs never re-transcribe or re-spend Claude tokens on episodes that are already done.

Whisper model: `models/ggml-small.en.bin` (chosen over base.en for accuracy on Apple/Mac proper nouns — base.en mangled things like "Woz" → "Waz", "MacWorld" → "Mackerel"). Batch run uses a custom `--prompt` of show-specific vocabulary to bias transcription further. `classify`/`synthesize` use `claude-opus-4-8` (see `ClaudeClassifier.swift`); a typical week of new-episode processing (transcription is free/local; only classify+synthesize hit the API) costs on the order of $0.15–0.25.

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

`pipeline/collections.json` is the taxonomy's source of truth — currently 10 top-level Museum categories (Compact Macintosh, Modular Macintosh, Power Mac/Mac Pro, iMac, Mac mini/Studio, Apple Laptops, Newton, iPod, iPhone, iPad) covering 61 individual product/segment collections. Editing it and re-running `classify` upserts titles/descriptions in place rather than duplicating rows.

## App structure

`App/RetroMacCast/Sources/`:

- **`App/`** — `RetroMacCastApp.swift` (entry point, owns the shared `CorpusUpdateManager`), `RootTabView.swift` (the three-tab shell)
- **`Search/`** — the **Home** tab: full-text search (FTS5 across title/show notes/transcript, relevance/date sorting) with an empty-state landing view ("This Week in RetroMacCast History" — an on-this-day feature pulling from real episode air dates)
- **`Museum/`** — the **Museum** tab: the curated-collections taxonomy as a browsable product museum (category → product model → detail page with photo, synopsis, and real synthesized/quoted moments from the show), plus the shared classic Mac chrome components (see below) used across the whole app
- **`Emulator/`** — the **Emulator** tab: a `WKWebView` pointed at [Infinite Mac](https://infinitemac.org), letting you boot a real classic Mac OS instance inside the app. Deliberately just loads their hosted page rather than embedding an emulator core directly — Infinite Mac's own code is Apache-2.0, but the emulator cores it runs (Basilisk II, SheepShaver, Mini vMac) are GPL, and GPL + App Store distribution have a documented history of not getting along (see: VLC's years off the App Store). Loading a URL in a WebView ships none of that code in this app, sidestepping the question entirely — and it means we don't have to prompt users for a ROM dump either, since Infinite Mac already handles that.
- **`Settings/`** — the macOS-only Settings window and `CorpusUpdateManager` (see below)
- **`Data/`** — `Corpus.swift`, the GRDB wrapper every other tab queries

## Classic Mac visual chrome

Home, Museum, and the product detail pages share a custom System 7 look (`Museum/FinderWindowChrome.swift`, `Museum/ClassicScrollBar.swift`) rather than native platform chrome: a pinstripe title bar with functional close/zoom boxes, sharp square corners with no drop shadow (a real classic window sits flat on the desktop), and a hand-built scrollbar with a dithered checkerboard track and a fixed-size thumb textured with horizontal ridge lines — matching how the real thing worked (the thumb never stretched to represent scroll proportion the way modern scrollbars do). Museum category windows cascade open from the icon you double-click, complete with a System-7-style "zoom rectangles" open/close animation.

None of this was guessed from memory — every detail (the thumb's actual construction, the zoom box's "cascading rectangles" glyph, the arrow's flared-arrowhead-over-a-stem shape with its pixel-staircase edges, the blue/lavender accent tint) was checked directly against a real System 7.5.3 window rendered live by Infinite Mac in this app's own Emulator tab, or against high-resolution reference screenshots, through several rounds of pixel-level correction.

The Settings window deliberately does *not* use this chrome — it's a normal native `Form`/`Section`-based macOS Preferences pane, since a Settings window is expected to look and behave like every other Mac app's, not like retro content. iOS never gets the custom chrome either (native `NavigationStack`/`.searchable`), for the same "don't fight the platform's own conventions" reason.

## Weekly sync + Settings

New episodes flow into the app automatically, without any manual per-episode decision or expensive re-analysis of the whole archive:

1. **`.github/workflows/weekly-sync.yml`** runs every Monday (plus a manual `workflow_dispatch` trigger) on a `macos-latest` runner: downloads the most recently published corpus, runs `crawl-index` → `resolve-audio` → `transcribe-batch` → `classify` → `reset-stale-synthesis` → `synthesize` → `export-manifest`, and — only if the episode count actually changed — publishes a new GitHub Release tagged `corpus-YYYY-MM-DD` with `rmc.sqlite` and `manifest.json` as assets. The `ANTHROPIC_API_KEY` lives only as a repo secret; it never touches app code or a shipped binary.
2. **`CorpusUpdateManager`** (owned by `RetroMacCastApp`, shared between the main window and Settings) checks the repo's latest release once per launch — but only actually hits the network if 7+ days have passed since the last check, which is what makes "weekly" the default cadence without needing a real background-refresh scheduler. It downloads the new `rmc.sqlite` to a temp file, opens it read-only and runs a sanity query before committing to it (so a truncated download can't brick the app), then atomically swaps it into `~/Library/Application Support/RetroMacCast/` and calls `Corpus.reloadFromDisk()`.
3. **`Corpus.shared` is a `var`, not a `let`** — `reloadFromDisk()` just reassigns it, so every existing `Corpus.shared.search(...)`-style call site picks up the new data on its very next call. No dependency-injection rework needed anywhere else in the app.
4. **Settings → Updates** (macOS only, `Cmd+,`) shows the current archive's episode count and latest episode, when it last checked, and a manual "Check Now" button that bypasses the weekly gate.

## Status (as of this writing)

- **Pipeline**: complete and self-sustaining. 741 episodes transcribed, 0 failures, classified into 61 collections across 10 Museum categories; the weekly sync job keeps this current going forward without manual intervention.
- **App**: Home (search + on-this-day), Museum (full System 7-chrome browsing experience), and Emulator (real classic Mac OS via Infinite Mac) tabs are built and verified on both iOS and macOS. Settings/Updates is built and verified on macOS; the weekly-sync GitHub Actions workflow is written but not yet run for real (see Open Items).

## Open items

- **The GitHub repo itself doesn't exist yet.** `CorpusUpdateManager.swift` has placeholder `owner`/`repo` values (`YOUR_GITHUB_USERNAME` / `retromaccast-archive`) that need real values once the repo is created; the `ANTHROPIC_API_KEY` secret then needs to be added in that repo's Settings → Secrets and variables → Actions before `weekly-sync.yml` can run for real.
- **Reach out to James & John before going much further** — this is being built with the intent to offer it as the show's official app, not just a personal fan project, which raises the stakes on quality/reliability and makes their input on scope worth getting early rather than after the fact. Their own collection photos would also beat any stock/Wikimedia imagery for illustrating specific models.
- Font licensing check before shipping ChicagoFLF broadly (its embedded license text states public domain, but worth a final look).
- Trivia & clip-sharing (auto-generated trivia from transcript segments, shareable "quote card" deep links to a moment) is still just an idea, not started.
