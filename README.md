# RetroMacCast

An app for exploring 20 years of the [RetroMacCast](https://retromaccast.libsyn.com) podcast (James & John) — search, browse, and ask questions across every episode's transcript and show notes, wrapped in a UI that pays homage to the classic Mac look. Being built with the intent to offer it to the hosts as the show's official app.

## Architecture

Two parts:

1. **Pipeline** (`pipeline/`, this repo) — a Swift CLI that crawls the full episode archive, transcribes every episode locally with whisper.cpp, and builds a searchable SQLite corpus. Runs on this Mac, not on end users' devices.
2. **App** (`App/`, Xcode project `RetroMacCast.xcodeproj`, generated via xcodegen from `App/project.yml`) — a SwiftUI client targeting iOS 17+ and macOS 14+ from one shared codebase (`App/RetroMacCast/Sources`). Currently bundles the corpus directly for local development; CloudKit-based sync/distribution is still planned for real users.

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
.build/release/rmc-pipeline transcribe-batch [--limit N] [--model path/to/model.bin]

# Check progress
.build/release/rmc-pipeline stats
```

Whisper model: `models/ggml-small.en.bin` (chosen over base.en for accuracy on Apple/Mac proper nouns — base.en mangled things like "Woz" → "Waz", "MacWorld" → "Mackerel"). Batch run uses a custom `--prompt` of show-specific vocabulary to bias transcription further.

Run the full backfill detached so it survives closing the terminal:
```
nohup caffeinate -s .build/release/rmc-pipeline transcribe-batch > logs/full-run.log 2>&1 < /dev/null &
disown
```

## Corpus schema (SQLite, `corpus/rmc.sqlite`)

- `episodes` — id (Libsyn item id), episode number, title, page URL, pub date, show notes HTML, audio URL, transcript status/text
- `transcript_segments` — per-episode timestamped chunks (startMs/endMs/text) for jump-to-moment playback and search result snippets
- `episodes_fts` — FTS5 virtual table synchronized over title + show notes + transcript text

## App feature plan (priority order)

1. **Search + Ask** — full-text search over transcripts/show notes; a RAG-style "ask the archive" chat that cites specific episodes/timestamps (Anthropic API). This is the foundation everything else sits on.
2. **Curated collections** — product-line timelines (every mention of a given Mac model across 20 years), recurring-segment collections (every eBay Find of the Week, etc.), "this day in Apple history." Mostly a tagging/classification pass over data we already have.
3. **Trivia & clip-sharing** — auto-generated trivia from transcript segments, shareable "quote card" deep links to a moment (not exported audio clips — avoids redistributing edited copies of the show's audio outside the app).
4. Ongoing ingestion: a small scheduled job re-runs `crawl-index` + `transcribe-batch` weekly to pick up new episodes as they publish; this stays on the pipeline side, never on listeners' devices.

## Playback & offline

- **Stream, don't embed.** The full archive is 25-30GB — too big to bundle, and can't be pre-resolved anyway since URLs expire in minutes. The app resolves a fresh streaming URL right when playback starts, same as the show's own website player.
- **Timestamp seeking** falls out of the corpus for free — segment start/end times are already stored, so tapping a search result just seeks the `AVPlayer`.
- **Offline**: manual per-episode download button (standard podcast-app pattern) plus auto-caching of recently-played episodes. Search/browsing always work offline since that's just the local SQLite corpus; only playback needs network.

## Visual direction

Skeuomorphic homage to classic Mac OS chrome — beige surfaces, chunky dark title bars, [ChicagoFLF](https://fontsarena.com/chicago-flf-by-robin-casady/) (free/public-domain recreation of the real Chicago system font, per its creator Robin Casady) for headers and chrome labels — but modern, accessible SwiftUI components underneath. Chicago-style bitmap font is for chrome/labels only, normal readable type for body/snippet text — the same split classic Mac OS used between Chicago and Geneva.

## Status

- Pipeline: complete. All 741 episodes transcribed, 0 failures.
- App: search works end-to-end (FTS5 across title/show notes/transcript, with timestamped snippets) on both iOS and macOS targets, styled with the retro chrome. No episode detail/playback view yet — tapping a result doesn't do anything.

## Open items

- **Reach out to James & John before going much further** — this is being built with the intent to offer it as the show's official app, not just a personal fan project, which raises the stakes on quality/reliability and makes their input on scope worth getting early rather than after the fact. Their own collection photos would also beat any stock/Wikimedia imagery for illustrating specific models.
- Decide on CloudKit vs. a simpler static-bundle distribution for syncing the corpus to app users.
- Font licensing check before shipping ChicagoFLF broadly (its embedded license text states public domain, but worth a final look).
