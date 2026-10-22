# Zest

A clean-room macOS file-conversion toolkit — the "feature-rich, flaw-fixed"
reimagining of a zero-click converter, built from a behavioural/format/protocol
spec rather than from anyone else's code.

> **Clean-room notice.** Zest is an independent reimplementation. It contains no
> source, binaries, assets, build output, API keys, or catalog data from any
> other application. Where it uses the same upstream open-source engines that
> other converters also happen to use (ffmpeg, libwebp, Apache POI, …), it does
> so directly from those projects under their own licenses. See **Licensing**.

## Why it exists

The subject app is a thin, well-polished Swift shell that orchestrates
open-source engines, wrapped in a one-time-unlock paywall that meters free use
via a Keychain + UserDefaults counter, and it exposes **no** automation surface
(no CLI, URL scheme, Services, Shortcuts, or AppleScript). Zest keeps the good
idea — fast, local, drag-and-convert — and fixes the limitations:

| Subject app | Zest |
|---|---|
| No scripting of any kind | **CLI first** (this scaffold), then URL scheme + Shortcuts/AppIntents + Services |
| Free tier metered by a reinstall-proof counter | **No artificial metering** — one honest purchase or fully free |
| Ships a full JRE **twice** (arm64 + x86_64) in an arm64-only app | Native/arm64-first; heavy doc engines stay out of the hot path |
| Engine choices hidden behind the binary | Pluggable `Converter` backends, explicit and testable |
| Metadata handling implicit | Metadata stripped by default (privacy-first), opt-out with `--keep-metadata` |

## Architecture

```
          ┌──────────────┐     ConversionRequest      ┌───────────────────┐
  CLI ───▶ │ ConversionEngine │ ──────────────────────▶ │ Converter backend │ ──▶ ffmpeg / … 
  (GUI,    └──────────────┘   picks first backend that  └───────────────────┘
  URL,            │            supports (source → target)
  Shortcuts
  later)   ZestKit (library) — the engine is UI-agnostic; every front end is a thin client.
```

- **`MediaFormat` / `MediaCategory`** — the format catalog and extension/UTI mapping.
- **`Converter`** — the backend protocol: `supports(from:to:)` + `convert(_:progress:)`, `Sendable`, async.
- **`ConversionEngine`** — routes a `ConversionRequest` to the first capable backend.
- **`FFmpegBackend`** — audio/video via a system `ffmpeg`, including **target-size
  compression** (binary-searches the bitrate to hit a byte budget) — the feature
  the subject app paywalls, here free.
- **`ToolLocator` / `ProcessRunner`** — find external tools; run them deadlock-free.

Backends (same protocol): `FFmpegBackend`, `ImageBackend`, and `DocumentBackend`
ship today. Planned: `ArchiveBackend`.

- **`ImageBackend`** — HEIC/JPEG/PNG/TIFF/GIF/BMP via Apple's ImageIO, WebP via
  `cwebp`, orientation baked in, optional downscale. Pairs with `MetadataStripper`
  (see below).
- **`MetadataStripper`** — lossless metadata removal with no re-encode: JPEG
  segment removal (APP1/APP13/COM), PNG chunk removal (tEXt/iTXt/zTXt/eXIf/tIME),
  and an **offset-preserving in-place HEIC strip** — an ISO-BMFF box walk that
  zeroes the Exif/XMP item payloads while leaving every box size and `iloc` offset
  (and the whole `mdat`) untouched. A decode check gates the result; if the
  surgical strip can't be validated it falls back to a metadata-dropping re-encode.
- **`DocumentBackend`** — Office/PDF **without bundling a runtime**. Apple's
  `NSAttributedString` engine reads/writes docx · doc · rtf · rtfd · odt · html ·
  txt in-process and renders any of them to PDF (CoreText pagination); `PDFKit`
  does PDF→image, PDF→text, and image→PDF. Heavy formats (pptx · xlsx · ods)
  route to a **LibreOffice headless** binary located at runtime — optional, never
  bundled. See the evaluation below.

### Document conversion: native vs LibreOffice

The subject app ships a full **JRE 21 twice** (arm64 *and* x86_64) plus Apache POI
and PDFBox — roughly 59% of its download — just to convert Office files. Zest
rejects that trade and splits the problem:

| Need | Zest's path | Dependency |
|---|---|---|
| docx·doc·rtf·rtfd·odt·html·txt ↔ each other, and → PDF | `NSAttributedString` + CoreText, in-process | none (system framework) |
| PDF → PNG/JPG/TIFF, PDF → text, image → PDF | `PDFKit` + ImageIO | none (system framework) |
| pptx·xlsx·ods·xls·csv (full-fidelity office) | `soffice --headless --convert-to` | **LibreOffice, located at runtime — never bundled** |

So the common cases are native and weightless; the heavy formats are delegated to
a *system* LibreOffice when present (and reported as unavailable when not),
instead of shipping a private Java stack. Net: no bundled runtime, no duplicate
architecture slice, and the engine stays one `Converter`.

## Build & run

```bash
cd Zest
swift build
swift run ZestApp         # the menu-bar drop-wheel GUI (accessory app, no Dock icon)
swift run zest selftest   # dependency-free checks — works with Command Line Tools only
swift run ZestApp --selftest            # app-layer checks: wheel geometry, batch building
swift run ZestApp --snapshot snapshots  # render every surface/state, light + dark, to PNGs
swift test                # conventional XCTest suite — requires full Xcode

# Audio/video need ffmpeg on PATH (brew install ffmpeg) or ZEST_FFMPEG_PATH set.
swift run zest formats
swift run zest convert in.wav out.mp3 --quality 0.7
swift run zest convert in.mov out.mp4 --target-size 8MB
swift run zest convert photo.heic photo.jpg --quality 0.8   # ImageIO re-encode
swift run zest convert photo.png  photo.webp --quality 0.75 # cwebp
swift run zest convert report.docx report.pdf              # DocumentBackend (native, no JRE)
swift run zest convert photo.heic clean.heic                # lossless, offset-preserving metadata strip
swift run zest inspect clean.heic                           # report remaining metadata
swift run zest url "zest://convert?input=photo.heic&to=jpg&quality=0.8"   # URL-scheme automation
swift run zest download "https://youtu.be/aqz-KE-bpKQ"             # list what a link offers (needs yt-dlp)
swift run zest download "https://youtu.be/aqz-KE-bpKQ" --as mp3    # best · compatible · m4a · mp3 · wav · image

./Scripts/package-app.sh    # -> dist/Zest.app (universal); registers the zest:// scheme system-wide
./Scripts/make-dmg.sh       # -> dist/Zest-<version>.dmg to share: app + Applications link + "Read Me First.pdf"
```

Verified on this machine (Swift 6.4, Command Line Tools): `swift build` clean,
`zest selftest` 31/31, `ZestApp --selftest` 28/28, and real runs —
- `voice.aiff` (206 KB) → `voice.mp3` (93.6 KB); `--target-size 40kb`
  binary-searched the bitrate to land at 37.5 KB in 6 passes.
- `photo.heic` (5.6 MB) → `photo.jpg` with EXIF/GPS stripped; `photo.png` → WebP
  via cwebp (72 KB); and an in-place HEIC strip that zeroed the embedded 36-byte
  EXIF item while keeping the file byte-length and all `mdat` offsets identical
  (confirmed at the byte level).
- `note.txt → .rtf → .docx → .pdf → .txt` preserved the text (NSAttributedString
  + PDFKit, no bundled runtime); PDF→PNG and image→PDF produced valid output.

## Automation

Zest treats automation as first-class (the subject app has none). Every surface
drives the same `ConversionEngine.standard()`:

- **CLI:** `zest convert …`, and `zest url "zest://convert?input=…&to=…"`.
- **URL scheme:**
  `zest://convert?input=<path>&to=<fmt>&quality=<0..1>&target-size=<size>&max-dim=<px>&keep-metadata=1&output=<path>`
  — parsed by `ZestURL` and handled in the app's `application(_:open:)`. Only
  `input` and `to` are required. The parser + engine path is unit-tested and
  runnable today via `zest url …`; for Finder and other apps to route `zest://`
  links, the scheme must be declared in a packaged `.app` (below). The app also
  answers `zest://open?input=<path>[&input=<path>…]` (put files on the wheel),
  `zest://settings` and `zest://dropzone`.
- **Finder ▸ Open With ▸ Zest** puts the files on the wheel (`CFBundleDocumentTypes`,
  "Alternate" rank — Zest never becomes the default app for anything).
- **Links:** `zest://download?url=<link>[&as=best|compatible|m4a|mp3|wav|image]`
  — without `as`, the wheel shows the choices — and `zest download <link> --as …`.

## Link downloads

Paste a link into the menu (or ⌘V in the drop zone, or drag it from the
browser onto the drop zone or the menu-bar icon): Zest reads it with
**yt-dlp** and the wheel offers what that link really has —

| Slice | What you get |
|---|---|
| **MP4 4K** (best) | Video with audio at the highest resolution. Above 1080p YouTube serves AV1 (plays in QuickTime on M3+ Macs) or VP9 (VLC/IINA). |
| **MP4 1080p** (compatible) | H.264 + AAC — plays everywhere. Shown only when it differs from Best. |
| **M4A** | The site's AAC audio stream, **untouched** (converted to AAC 256 only if the site has no AAC). |
| **MP3** | 320 kbps, converted from the site's audio. |
| **WAV** | Uncompressed, for editing. |
| **Image** | The full-size image of an image post (e.g. Pinterest). |

Honest quality: YouTube, Instagram, Facebook and Pinterest only keep
compressed audio (typically AAC/Opus at 128–160 kbps). M4A is that original;
MP3 320 and WAV can't add back what the site didn't keep — they're for
compatibility and editing. Volume-compressed "DRC" streams are skipped.

- **yt-dlp is located at runtime, never bundled** (`brew install yt-dlp`):
  it has to keep up with the sites, and Zest stays a converter rather than
  shipping a downloader. ffmpeg merges video/audio and converts audio.
- **Sign-in (opt-in):** Settings › Output › "Use sign-in from" lets yt-dlp
  read Safari/Chrome/Brave/Firefox/Edge cookies for private or sign-in-only
  posts. Off by default. Safari needs Full Disk Access for Zest.
- Downloads follow the destination setting ("next to the original" means
  ~/Downloads for a link), named after the title, never overwriting.
- Only download what you have the right to (your own uploads, Creative
  Commons, or with permission); the sites' terms apply.
- **Shortcuts / Spotlight (AppIntents):** `ConvertFileIntent` and `ZestShortcuts`
  expose a "Convert File" action on the same engine. It compiles and runs
  in-process; it surfaces in the Shortcuts app once shipped inside a real `.app`
  bundle, where the AppIntents metadata extractor runs.

**Packaging.** `Scripts/package-app.sh` builds release, assembles
`dist/Zest.app` (Info.plist with `LSUIElement` + `CFBundleURLTypes` for `zest`),
ad-hoc signs it, and registers it with Launch Services. After that,
`open "zest://convert?input=…&to=…"` routes to the app **system-wide** — verified:
a `zest://…&to=jpg` link produced the JPG with no terminal involved. The
AppIntents "Convert File" action additionally needs a full Xcode build (the
`appintentsmetadataprocessor` isn't in the Command Line Tools); the URL scheme
does not. The `zest` CLI ships inside the bundle at `Contents/Helpers/zest`;
put it on your PATH once with
`sudo mkdir -p /usr/local/bin && sudo ln -sf "/Applications/Zest.app/Contents/Helpers/zest" /usr/local/bin/zest`.

## Sharing with friends

`Scripts/make-dmg.sh` builds `dist/Zest-<version>.dmg`, ready to AirDrop:
the universal app (Apple silicon + Intel, macOS 13+), an Applications
shortcut, and **Read Me First.pdf**, a friendly guide rendered from
`Packaging/Guide/guide.html` (screenshots in `Packaging/Guide/img`, made with
`ZestApp --snapshot`). The app icon is drawn in code by
`Packaging/Icon/draw-icon.swift` and compiled into `Packaging/AppIcon.icns`.

The build is ad-hoc signed, not notarized, so on a friend's Mac Gatekeeper
blocks the first launch ("Apple could not verify…"). The guide walks them
through **System Settings › Privacy & Security › Open Anyway** (or
`xattr -dr com.apple.quarantine /Applications/Zest.app`). A Developer ID
certificate plus notarization removes that step.

## Licensing (must be honored before distribution)

Zest's own code here is yours to license as you choose. The engines it drives
are not, and "the subject app already ships them" is **not** a license:

- **ffmpeg / libmp3lame** — LGPL / version3 class. Link dynamically (or ship an
  unmodified signed `ffmpeg`), keep it non-GPL (no `--enable-gpl`), preserve
  notices and the exact `./configure` line, and publish the written source offer.
- **libwebp / cwebp** — BSD. Preserve notices.
- **yt-dlp** — Unlicense, but not bundled: located at runtime from the user's
  install. Keep it that way for distribution (it needs frequent updates, and
  shipping a site downloader inside the app invites takedown requests).
- **ExifTool** — Artistic/GPL. Ship unmodified; preserve notices.
- **Apache POI / PDFBox / xmlbeans** — Apache-2.0. Preserve `NOTICE`/`LICENSE`.
- **OpenJDK**, if bundled for document conversion — GPLv2 + Classpath Exception;
  prefer not bundling it twice, and consider LibreOffice-headless or a native
  path instead.

Distribution note: the Mac App Store sandbox and (L)GPL source-offer obligations
interact; a notarized direct build is the simpler home for the GPL/LGPL engines
and for dropping the sandbox to enable real automation.

## Status

Working:
- **`ZestKit`** — engine + three backends: `FFmpegBackend` (audio/video,
  single-pass and target-size), `ImageBackend` (ImageIO + cwebp + offset-preserving
  `MetadataStripper`), and `DocumentBackend` (native Office/PDF via
  NSAttributedString + PDFKit; LibreOffice optional). `swift run zest selftest` → 31/31.
- **`zest`** — the CLI: `formats · selftest · inspect · stripinfo · convert · url`.
- **`ZestApp`** — the menu-bar agent GUI (`AppKit` + `SwiftUI`) in the **Citrus**
  design language (warm cream, rounded type, light and dark):
  - **Drop zone → orange-slice wheel.** Drag files onto the floating panel and
    the wheel blooms *while you're still dragging*; release over a slice to
    convert. The slices are exactly the targets the engine can produce (up to
    ten, most useful first, the rest under "More"), plus **Strip** for a
    lossless metadata-only clean. Click, 1–9/0 or Return also pick a slice;
    Esc backs out. Drawing and drag hit-testing share one `WheelGeometry`.
  - **Batches.** Drop several files: the wheel offers formats they can all reach;
    files already in the chosen format are left alone and reported.
  - **Result card** with output size and savings, Show in Finder, and plain-
    language errors; empty placeholders are cleaned up on failure or cancel.
  - **Menu-bar panel** (left-click; right-click for a plain menu): Convert a
    file…, a paste-a-link field for downloads, recently squeezed files (click
    to reveal), Drop zone, Settings, Quit. Dropping a file or a link on the
    menu-bar icon opens the wheel.
  - **Link downloads** on the same wheel — see **Link downloads**.
  - **Settings:** output destination (next to the original, Downloads, ask),
    quality, longest side, metadata stripping, launch at login, reveal/sound
    when done, URL-scheme reference, and an Engines table (ffmpeg, cwebp,
    LibreOffice found/not found).
  Runs as an accessory app (no Dock icon); `swift run ZestApp`.
- **Automation** — a `zest://convert?…` URL scheme and an AppIntents/Shortcuts
  "Convert File" action, both on the shared engine (see **Automation**). The CLI
  `zest url …` drives the same path.

Next: the AppIntents action surfaced via an Xcode build, an app icon, an
optional global modifier-drag trigger, and an archive backend (zip/tar/gzip).
