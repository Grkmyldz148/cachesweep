<div align="center">

<img src="Resources/icon-1024.png" width="128" alt="Cachesweep icon" />

# Cachesweep

**The menu-bar disk cleaner that shows you what's eating your space — live.**

A fast, transparent, developer-focused cache cleaner for macOS. It finds
regenerable caches anywhere on your disk, watches what gets written where in
real time, learns from what you clean, and reclaims space in a single click.

[![Platform](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org)
[![Languages](https://img.shields.io/badge/languages-13-green)](#languages)
[![Auto-update](https://img.shields.io/badge/updates-Sparkle-blueviolet)](https://sparkle-project.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

## Why

You upgrade macOS, 70 GB frees up, and a week later it's gone again — without
installing anything. Caches from `npm`, `gradle`, `yarn`, Docker, Ollama,
DerivedData, simulators and a dozen other tools quietly refill the disk.
Cachesweep makes that **visible**, **explainable**, and **one-click reversible**.

## Features

- 🧹 **One-click cleanup** of dev & app caches — npm, Yarn, pnpm, Gradle,
  DerivedData, CocoaPods, pip, Homebrew, Ollama models, `~/.cache`, Trash…
- 🔭 **Smart discovery** — instead of a hardcoded list, it *finds* cache-like
  folders anywhere (via Spotlight: project manifests + `CACHEDIR.TAG`) and
  decides what's safe to remove with a signal-based classifier.
- 🟢 **Live tracking (FSEvents)** — see in real time *what is being written
  where*, with per-folder growth (▲ delta) and recency.
- 📈 **Growth history** — persistent size timeline per folder with sparklines
  ("this folder grew 4 GB this week"), across app restarts.
- 🧠 **Learning loop** — remembers what you clean and detects when a cache grows
  back, so trusted kinds auto-promote over time. The curated list is just a seed.
- 🟢🟠 **Safety by default** — only clearly-safe, regenerable, idle caches are
  pre-selected; "real data" or anything **in active use** is opt-in, never auto-picked.
- 📏 **Accurate sizing** — real on-disk allocation, so sparse files (like
  `Docker.raw`) are measured correctly, not by apparent size.
- 🌍 **13 languages** — follows your device language automatically, with a manual
  picker in Settings.
- 🪶 **Native & light** — a menu-bar `LSUIElement` SwiftUI app following Apple's
  Human Interface Guidelines (see [`docs/HIG-notes.md`](docs/HIG-notes.md)).
- 🔄 **Self-updating** — ships EdDSA-signed updates over [Sparkle](https://sparkle-project.org).

## Install

1. Download **`Cachesweep-x.y.z.dmg`** from the
   [latest release](https://github.com/Grkmyldz148/cachesweep/releases/latest).
2. Open it and drag **Cachesweep** onto **Applications**.
3. First launch: right-click the app → **Open** (ad-hoc signed build; one time only).
4. Grant **Full Disk Access** (System Settings → Privacy & Security) so it can
   scan `~/Library` fully.

A **✨** icon appears in the menu bar. Click it to scan and clean — after that
the app **updates itself** automatically.

> Prefer a zip? `Cachesweep-x.y.z.zip` is also attached (it's what Sparkle uses
> for auto-updates).

## How the smart scan decides

Every candidate folder gets two scores — *is this a cache?* and *is it safe to
delete?* — from a blend of signals:

| Signal | Meaning |
|---|---|
| `CACHEDIR.TAG` present | Definitive "I am a cache" marker (Cargo, etc.) |
| Excluded from Time Machine | The developer marked it expendable |
| Regenerable from a manifest | `package.json`→`node_modules`, `Cargo.toml`→`target`, `Podfile`→`Pods`… → safe |
| Location / name | Under `~/Library/Caches`, `~/.cache`; names like `node_modules`, `target`, `build` |
| **Staleness** (mtime) | Untouched for a week → safe; fresh → cautious |
| **In use** (live tracker) | Being written right now → never auto-selected |
| **Learned** | Past clean → regrew → trusted more next time |
| **Veto** | `Documents`, Photos, Mail, `.ssh`… are *never* offered |

High cache-score → shown; high safety-score → **pre-selected (green)**, otherwise
**opt-in (orange)**. Nothing is ever deleted without your click + confirmation,
and deletion is permanent (real reclaim) since these regenerate.

Default scan scope is your **home folder**; add external disks or exclude paths
in **Settings**.

## Languages

English · Türkçe · Deutsch · Français · Español · Italiano · Português (BR) ·
Nederlands · Русский · 日本語 · 한국어 · 简体中文 · العربية — auto-selected from the
device language, overridable in Settings. Adding a language is one
`Sources/Cachesweep/Resources/<lang>.lproj/Localizable.strings` file.

## Build from source

```bash
git clone https://github.com/Grkmyldz148/cachesweep.git
cd cachesweep
swift run                          # run the menu-bar app
bash Scripts/package.sh 0.2.0      # → dist/Cachesweep.app (signed bundle)
bash Scripts/make_dmg.sh 0.2.0     # → dist/Cachesweep-0.2.0.dmg
```

Requires macOS 15+ and a recent Swift 6 toolchain (Xcode).

## Architecture

```
Sources/Cachesweep/
├─ Model/
│  ├─ CleanTarget.swift          # curated seed list of known cache locations
│  ├─ Discovery.swift            # Spotlight discovery + signal-based classifier
│  ├─ Scanner.swift              # concurrent, allocation-aware sizing (sparse-correct)
│  ├─ Cleaner.swift              # permanent, space-reclaiming deletion
│  ├─ FileActivityMonitor.swift  # FSEvents wrapper (live-tracking engine)
│  ├─ Activity.swift             # buckets raw paths → known rule or discovery
│  ├─ ActivityHistory.swift      # persistent per-folder growth timeline
│  ├─ LearningStore.swift        # self-growing rules from clean/regrow feedback
│  ├─ Settings.swift             # scan roots, exclusions, language (persisted)
│  ├─ AppModel.swift             # @Observable state; parallel scan/clean/ingest
│  └─ AppUpdater.swift           # Sparkle auto-update
├─ Views/                        # HIG design system, menu, Settings, History
├─ Localization.swift            # device-language resolution + override
├─ Resources/<lang>.lproj/       # 13 Localizable.strings catalogs
└─ AppDelegate / main            # NSStatusItem + popover, accessory app
```

## Releasing (automated)

Pushing a `v*` tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml):

1. Builds and packages `Cachesweep.app` (with the localization bundle).
2. Zips it and **signs** the archive with the Sparkle EdDSA key.
3. Builds a drag-to-install **DMG**.
4. Generates `appcast.xml` and publishes the DMG + zip + appcast to a GitHub Release.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The app's `SUFeedURL` points at `releases/latest/download/appcast.xml`, so users
get new versions automatically. The signing private key lives in the
`SPARKLE_PRIVATE_KEY` repository secret (public key embedded in Info.plist).

> Builds are currently **ad-hoc signed** → first open needs right-click → Open.
> Developer ID signing + notarization is on the roadmap for frictionless installs.

## Roadmap

- [x] Smart discovery + signal classifier (Spotlight, staleness, in-use)
- [x] Learning loop (clean → regrow feedback)
- [x] Growth history with sparklines
- [x] 13-language localization + picker
- [x] DMG release
- [ ] Developer ID signing + notarization
- [ ] Full Disk Access onboarding
- [ ] Launch-at-login (`SMAppService`)
- [ ] Privileged helper for root-owned caches (`/var/root`, `/usr/local/share`)
- [ ] Liquid Glass polish (macOS 26 `.glassEffect`)

## License

MIT © 2026 Görkem YILDIZ — see [LICENSE](LICENSE).
