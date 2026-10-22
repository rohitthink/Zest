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

Backends (same protocol): `FFmpegBackend` and `ImageBackend` ship today.
Planned: `DocumentBackend` (Office/PDF) and `ArchiveBackend`.

- **`ImageBackend`** — HEIC/JPEG/PNG/TIFF/GIF/BMP via Apple's ImageIO, WebP via
  `cwebp`, orientation baked in, optional downscale. Pairs with `MetadataStripper`
  (see below).
- **`MetadataStripper`** — lossless metadata removal with no re-encode: JPEG
  segment removal (APP1/APP13/COM), PNG chunk removal (tEXt/iTXt/zTXt/eXIf/tIME),
  and an **offset-preserving in-place HEIC strip** — an ISO-BMFF box walk that
  zeroes the Exif/XMP item payloads while leaving every box size and `iloc` offset
  (and the whole `mdat`) untouched. A decode check gates the result; if the
  surgical strip can't be validated it falls back to a metadata-dropping re-encode.

## Build & run

```bash
cd Zest
swift build
swift run ZestApp         # the menu-bar drop-wheel GUI (accessory app, no Dock icon)
swift run zest selftest   # dependency-free checks — works with Command Line Tools only
swift test                # conventional XCTest suite — requires full Xcode

# Audio/video need ffmpeg on PATH (brew install ffmpeg) or ZEST_FFMPEG_PATH set.
swift run zest formats
swift run zest convert in.wav out.mp3 --quality 0.7
swift run zest convert in.mov out.mp4 --target-size 8MB
swift run zest convert photo.heic photo.jpg --quality 0.8   # ImageIO re-encode
swift run zest convert photo.png  photo.webp --quality 0.75 # cwebp
swift run zest convert photo.heic clean.heic                # lossless, offset-preserving metadata strip
swift run zest inspect clean.heic                           # report remaining metadata
swift run zest url "zest://convert?input=photo.heic&to=jpg&quality=0.8"   # URL-scheme automation
```

Verified on this machine (Swift 6.4, Command Line Tools): `swift build` clean,
`zest selftest` 19/19, and real runs —
- `voice.aiff` (206 KB) → `voice.mp3` (93.6 KB); `--target-size 40kb`
  binary-searched the bitrate to land at 37.5 KB in 6 passes.
- `photo.heic` (5.6 MB) → `photo.jpg` with EXIF/GPS stripped; `photo.png` → WebP
  via cwebp (72 KB); and an in-place HEIC strip that zeroed the embedded 36-byte
  EXIF item while keeping the file byte-length and all `mdat` offsets identical
  (confirmed at the byte level).

## Automation

Zest treats automation as first-class (the subject app has none). Every surface
drives the same `ConversionEngine.standard()`:

- **CLI:** `zest convert …`, and `zest url "zest://convert?input=…&to=…"`.
- **URL scheme:**
  `zest://convert?input=<path>&to=<fmt>&quality=<0..1>&target-size=<size>&max-dim=<px>&keep-metadata=1&output=<path>`
  — parsed by `ZestURL` and handled in the app's `application(_:open:)`. Only
  `input` and `to` are required. The parser + engine path is unit-tested and
  runnable today via `zest url …`; for Finder and other apps to route `zest://`
  links, the scheme must be declared in a packaged `.app` (below).
- **Shortcuts / Spotlight (AppIntents):** `ConvertFileIntent` and `ZestShortcuts`
  expose a "Convert File" action on the same engine. It compiles and runs
  in-process; it surfaces in the Shortcuts app once shipped inside a real `.app`
  bundle, where the AppIntents metadata extractor runs.

**Packaging note.** A shipping build wraps `ZestApp` in a `.app` whose Info.plist
declares `LSUIElement`, `CFBundleURLTypes` (scheme `zest`), and the AppIntents
metadata — at which point the URL scheme and the Shortcuts action are live
system-wide. The engine, parser, and intents are all in place for that step.

## Licensing (must be honored before distribution)

Zest's own code here is yours to license as you choose. The engines it drives
are not, and "the subject app already ships them" is **not** a license:

- **ffmpeg / libmp3lame** — LGPL / version3 class. Link dynamically (or ship an
  unmodified signed `ffmpeg`), keep it non-GPL (no `--enable-gpl`), preserve
  notices and the exact `./configure` line, and publish the written source offer.
- **libwebp / cwebp** — BSD. Preserve notices.
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
- **`ZestKit`** — engine + two backends: `FFmpegBackend` (audio/video, single-pass
  and target-size) and `ImageBackend` (ImageIO + cwebp + offset-preserving
  `MetadataStripper`). `swift run zest selftest` → 19/19.
- **`zest`** — the CLI: `formats · selftest · inspect · stripinfo · convert · url`.
- **`ZestApp`** — the menu-bar agent GUI (`AppKit` + `SwiftUI`): a floating,
  borderless, translucent drop panel with a **radial format wheel** that offers
  exactly the targets the engine can produce for the dropped file, runs the
  conversion off the main actor, and writes the result beside the source. Runs as
  an accessory app (no Dock icon); `swift run ZestApp`.
- **Automation** — a `zest://convert?…` URL scheme and an AppIntents/Shortcuts
  "Convert File" action, both on the shared engine (see **Automation**). The CLI
  `zest url …` drives the same path.

Next: a packaged `.app` (to make the scheme + Shortcuts action live system-wide),
determinate progress in the wheel, an optional global modifier-drag trigger, and
a document backend (to replace the subject app's double-JRE Office path).
