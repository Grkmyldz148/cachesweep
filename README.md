<div align="center">

<img src="Resources/icon-1024.png" width="128" alt="Cachesweep icon" />

# Cachesweep

**The menu-bar disk cleaner that shows you what's eating your space — live.**

A fast, transparent, developer-focused cache cleaner for macOS. It watches what
gets written where in real time, knows your dev caches, and reclaims space in a
single click.

[![Platform](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org)
[![Auto-update](https://img.shields.io/badge/updates-Sparkle-blueviolet)](https://sparkle-project.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

## Why

You upgrade macOS, 70 GB frees up, and a week later it's gone again — without
installing anything. Caches from `npm`, `gradle`, `yarn`, Docker, Ollama,
DerivedData, simulators and a dozen other tools quietly refill the disk.
Cachesweep makes that **visible** and **one-click reversible**.

## Features

- 🧹 **One-click cleanup** of known dev caches — npm, Yarn, pnpm, Gradle,
  DerivedData, CocoaPods, pip, Homebrew, Ollama models, `~/.cache`, Trash…
- 🟢 **Live tracking (FSEvents)** — see in real time *what is being written
  where*, with per-folder growth (▲ delta) and recency.
- 🔍 **Auto-discovery** — when something writes to a new cache-like location
  (`node_modules`, `DerivedData`, `.gradle`, …) it surfaces automatically with
  a one-tap clean.
- 🟢🟠 **Safety levels** — pure caches are green and pre-selected; "real data"
  (model downloads, simulator runtimes) is orange and opt-in.
- 📏 **Accurate sizing** — reports real on-disk allocation, so sparse files
  (like `Docker.raw`) are measured correctly, not by apparent size.
- 🪶 **Native & light** — a menu-bar `LSUIElement` app built with SwiftUI,
  following Apple's Human Interface Guidelines (see [`docs/HIG-notes.md`](docs/HIG-notes.md)).
- 🔄 **Self-updating** — ships updates over [Sparkle](https://sparkle-project.org)
  with EdDSA-signed releases.

## Install

1. Download `Cachesweep-x.y.z.zip` from the [latest release](https://github.com/Grkmyldz148/cachesweep/releases/latest).
2. Unzip and drag **Cachesweep.app** to `/Applications`.
3. First launch: right-click → **Open** (unsigned build; one time only).
4. Grant **Full Disk Access** (System Settings → Privacy & Security) so it can
   scan `~/Library` fully.

A **✨** icon appears in the menu bar. Click it to scan and clean.
After that, the app **updates itself** automatically.

## Build from source

```bash
git clone https://github.com/Grkmyldz148/cachesweep.git
cd cachesweep
swift run            # runs the menu-bar app
# or build a distributable .app bundle:
bash Scripts/package.sh 0.1.0   # → dist/Cachesweep.app
```

Requires macOS 15+ and a recent Swift 6 toolchain (Xcode).

## How it works

```
Sources/Cachesweep/
├─ Model/
│  ├─ CleanTarget.swift         # curated rules database — the known cache locations
│  ├─ Scanner.swift             # concurrent, allocation-aware sizing (sparse-correct)
│  ├─ Cleaner.swift             # permanent, space-reclaiming deletion
│  ├─ FileActivityMonitor.swift # FSEvents wrapper (the live-tracking engine)
│  ├─ Activity.swift            # buckets raw paths → known rule or new discovery
│  ├─ AppModel.swift            # @Observable state; parallel scan/clean/ingest
│  └─ AppUpdater.swift          # Sparkle auto-update
├─ Views/                       # HIG design system + menu UI
└─ AppDelegate / main           # NSStatusItem + popover, accessory app
```

- **Rules** drive what's scanned; each has paths, a safety level and a clean
  strategy (delete folder vs. clear contents).
- **Live tracking** subscribes to FSEvents over the home directory; changed
  paths are bucketed to a known rule or an auto-discovered cache-like ancestor,
  then re-sized (debounced) to compute session growth.

## Releasing (automated)

Pushing a `v*` tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml):

1. Builds and packages `Cachesweep.app`.
2. Zips it and **signs** the archive with the Sparkle EdDSA key.
3. Generates `appcast.xml` and publishes both to a GitHub Release.

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The app's `SUFeedURL` points at `releases/latest/download/appcast.xml`, so users
get the new version automatically.

### One-time setup

The signing private key is stored as the `SPARKLE_PRIVATE_KEY` repository secret
(the matching public key is embedded in the app's Info.plist). Generate/rotate
with Sparkle's `generate_keys` tool.

> Note: builds are currently **ad-hoc signed**. For frictionless installs,
> add Apple Developer ID signing + notarization to `package.sh` (roadmap).

## Roadmap

- [ ] Persist discoveries & growth history ("this folder grew 4 GB this week")
- [ ] Liquid Glass polish (macOS 26 `.glassEffect`)
- [ ] Privileged helper for root-owned caches (`/var/root`, `/usr/local/share`)
- [ ] Launch-at-login (LaunchAgent)
- [ ] Developer ID signing + notarization

## License

MIT © 2026 Görkem YILDIZ — see [LICENSE](LICENSE).
