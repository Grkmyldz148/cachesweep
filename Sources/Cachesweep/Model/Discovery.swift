import Foundation
import AppKit

/// Smart discovery: find cache-like directories instead of listing them.
///
/// Sources, none of which needs to know what a given tool is called:
/// Spotlight (project manifests + `CACHEDIR.TAG`), the locations macOS
/// designates as caches (`~/Library/Caches`, container and Chromium profile
/// caches), and the `~/.<tool>/cache` convention. Each candidate is then
/// scored on signals — regenerability, backup-exclusion, name, location,
/// staleness, live activity, and what the user's own history says about the
/// kind.
///
/// `DeviceProfile` handles the complementary half (asking installed tools
/// where their caches actually are); `CleanTarget.all` is the fallback for
/// what neither mechanism can reach.
enum Discovery {

    // MARK: Knowledge

    /// manifest filename → regenerable sibling dirs (proof: the manifest can rebuild them).
    static let manifestMap: [String: [String]] = [
        "package.json":     ["node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit",
                             ".angular", ".vite", ".expo"],
        "Package.swift":    [".build"],
        "Gemfile":          ["vendor/bundle"],
        "requirements.txt": ["__pycache__", ".venv", "venv", ".pytest_cache"],
        "mix.exs":          ["_build", "deps"],
        "Cargo.toml":       ["target"],
        "Podfile":          ["Pods"],
        "pubspec.yaml":     [".dart_tool"],
        "build.gradle":     ["build", ".gradle"],
        "build.gradle.kts": ["build", ".gradle"],
        "pyproject.toml":   [".venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"],
        "composer.json":    ["vendor"],
    ]

    static let cacheNameTokens: Set<String> = [
        "cache", "caches", ".cache", "tmp", "temp", "build", "dist", "target",
        "node_modules", "deriveddata", "__pycache__", ".gradle", "pods",
        ".next", ".nuxt", ".turbo", ".venv", "vendor", "logs", "cacheddata",
        "code cache", "gpucache", "cachestorage", "shadercache", "cacheddata",
        "dawngraphitecache", "dawnwebgpucache", "venv", "_build", ".build",
    ]

    /// Chromium/Electron per-app cache folders inside Application Support —
    /// often the largest caches on a Mac, invisible to the Caches sweep.
    static let electronCacheDirs = [
        "Cache", "Code Cache", "GPUCache", "CacheStorage", "CachedData",
        "ShaderCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache",
    ]

    /// Subfolder names a CLI tool uses for its cache. Convention beats
    /// catalogue: a tool that keeps state in `~/.<tool>` almost always parks
    /// its throwaway data in a child that says so, which is how a tool nobody
    /// has ever heard of still gets found.
    static let conventionalCacheDirs: Set<String> = [
        "cache", "caches", ".cache", "_cacache", "cachedir", "cache_dir",
        "tmp", ".tmp", "temp",
    ]

    /// Installer downloads: not caches, but on a disk that is actually full
    /// they are routinely the single largest reclaimable item — two forgotten
    /// `.pkg` files can outweigh every cache on the machine. Only old, large,
    /// top-level files qualify, and they are always opt-in.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "iso", "ipa", "apk", "xip", "msi"]
    static let installerMinBytes: UInt64 = 200 * 1024 * 1024
    /// Two weeks: an installer nobody has touched since it finished
    /// downloading is done, and holding out for a month means the category
    /// stays empty on exactly the machines that need it most.
    static let installerMinAgeDays = 14

    /// A folder found only by its don't-back-this-up flag has to be at least
    /// this big to be worth a row — see the sweep for why.
    static let selfDeclaredMinBytes: UInt64 = 50 * 1024 * 1024

    /// Forgotten large files: on a disk that is actually full the answer is
    /// often not a cache at all — a VM disk, a raw video, an old backup.
    /// Spotlight answers the size question for free; only old, plainly
    /// visible files qualify, and they are always opt-in.
    static let largeFileMinBytes: UInt64 = 1_073_741_824
    static let largeFileMinAgeDays = 30
    static let largeFileCap = 8

    /// A superseded version folder has to be untouched this long before it
    /// counts as dead.
    static let versionStaleAgeDays = 30

    // MARK: Public entry

    /// Discover and classify cache-like dirs across the user's chosen `roots`.
    /// `seedPaths` (curated list) and `excludes` (user opt-outs) are skipped.
    static func discover(roots: [String], excluding seedPaths: Set<String>,
                         excludes: [String], activePaths: Set<String>,
                         learn: [String: Double],
                         expect: [String: UInt64] = [:],
                         hotSpots: [String: Set<String>] = [:],
                         boomerang: Set<String> = []) async -> [CleanTarget] {
        await Task.detached(priority: .utility) {
            run(roots: roots, excluding: seedPaths, excludes: excludes,
                activePaths: activePaths, learn: learn, expect: expect,
                hotSpots: hotSpots, boomerang: boomerang)
        }.value
    }

    /// Where a candidate ranks when the cap has to drop something.
    ///
    /// `score` is confidence — how sure we are this is a cache — and it says
    /// nothing about how much space it holds, which is why a score-only cap
    /// used to discard a 2.6 GB folder in favour of an empty one. Bytes the
    /// user has actually reclaimed from this kind before are folded in here,
    /// log-scaled and capped, so size decides ties without ever deciding
    /// whether something counts as a cache.
    static func priority(score: Double, expectedBytes: UInt64) -> Double {
        guard expectedBytes > 0 else { return score }
        let gb = Double(expectedBytes) / 1_073_741_824
        return score + min(0.6, log10(1 + gb) * 0.6)
    }

    // MARK: Implementation

    private static func run(roots: [String], excluding seedPaths: Set<String>,
                            excludes: [String], activePaths: Set<String>,
                            learn: [String: Double], expect: [String: UInt64],
                            hotSpots: [String: Set<String>],
                            boomerang: Set<String>) -> [CleanTarget] {
        let fm = FileManager()
        let home = NSHomeDirectory()
        var seen = Set<String>()
        // `capped` marks the one unbounded source (the Spotlight project
        // sweep). Everything else is bounded by the folder it enumerates.
        var scored: [(target: CleanTarget, rank: Double, capped: Bool)] = []

        func consider(_ path: String, derived: Bool, hasTag: Bool, designated: Bool,
                      selfDeclared: Bool = false, capped: Bool = false) {
            guard !seen.contains(path) else { return }
            // Skip anything a curated seed already covers (exact or nested),
            // otherwise its bytes would be counted and cleaned twice.
            guard !seedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
            guard isDir(path, fm) else { return }
            // An empty folder can never free a byte. One readdir here keeps
            // hundreds of empty per-profile cache dirs out of the list.
            guard let contents = try? fm.contentsOfDirectory(atPath: path),
                  !contents.isEmpty else { return }
            let age = ageInDays(path, fm)
            let active = isActive(path, activePaths)
            // Same signature the store records under — computing it a second
            // way here is how the two silently drift apart.
            let sig = LearningStore.signature(forPath: path)
            let learnBoost = learn[sig] ?? 0
            guard let v = classify(path, derived: derived, hasTag: hasTag, designated: designated,
                                   selfDeclared: selfDeclared, excludes: excludes,
                                   ageDays: age, active: active, learnBoost: learnBoost) else { return }
            seen.insert(path)
            // A proven boomerang stays offered (it is a cache) but sinks in
            // rank: its expected-bytes credit is exactly what should not
            // promote it, since those bytes come straight back.
            let isBoomerang = boomerang.contains(sig)
            scored.append((makeTarget(path, v, ageDays: age, inUse: active, learned: learnBoost > 0,
                                      boomerang: isBoomerang,
                                      category: designated ? .appCaches : .devCaches),
                           priority(score: v.score, expectedBytes: expect[sig] ?? 0)
                               - (isBoomerang ? 0.5 : 0),
                           capped))
        }

        for root in roots {
            // Ask Spotlight for every marker at once, then fall back to a
            // bounded walk if it answered nothing for this root. A stale or
            // absent index is silent in exactly the same way as an empty
            // disk, and it is external disks — where the projects usually
            // are — that go unindexed.
            let wanted = Set(manifestMap.keys).union(["CACHEDIR.TAG"])
            var markers: [String: [String]] = [:]
            for name in wanted {
                let hits = mdfind(["-onlyin", root, "-name", name]).prefix(6000)
                    .filter { ($0 as NSString).lastPathComponent == name }
                if !hits.isEmpty { markers[name] = hits }
            }
            if markers.isEmpty {
                markers = ManifestWalk.find(wanted, under: root)
                if !markers.isEmpty {
                    sweepDebug("🚶 \(root): Spotlight sessiz, yürüyerek \(markers.values.reduce(0) { $0 + $1.count }) işaret bulundu")
                }
            }

            // 1) CACHEDIR.TAG — the definitive "I am a cache" marker.
            for tag in markers["CACHEDIR.TAG"] ?? [] {
                consider((tag as NSString).deletingLastPathComponent,
                         derived: true, hasTag: true, designated: false, capped: true)
            }

            // 2) Manifest-derived: a manifest proves its sibling outputs are regenerable.
            for (manifest, derivedDirs) in manifestMap {
                for hit in markers[manifest] ?? [] {
                    let dir = (hit as NSString).deletingLastPathComponent
                    if dir.contains("/node_modules/") || dir.contains("/.build/")
                        || dir.contains("/vendor/") || dir.contains("/Pods/") { continue }
                    for d in derivedDirs {
                        consider(dir + "/" + d, derived: true, hasTag: false,
                                 designated: false, capped: true)
                    }
                }
            }
        }

        // 3) ~/Library/Caches/* — only when the home root is enabled.
        //    Version families first: "IntelliJIdea2023.1" beside a live
        //    2024.x is a superseded cache nobody will ever read again. The
        //    stale versions become one clean row, and whatever family member
        //    is current is offered on its own — never the vendor folder as a
        //    whole, which would count the same bytes twice.
        if roots.contains(home) {
            let cachesRoot = "\(home)/Library/Caches"
            if let subs = try? fm.contentsOfDirectory(atPath: cachesRoot) {
                var familyCovered = Set<String>()

                func emitFamilies(in dir: String) -> Bool {
                    var emitted = false
                    for fam in staleVersionFamilies(in: dir, fm: fm) {
                        let paths = fam.stalePaths.filter { p in
                            !seen.contains(p)
                                && !seedPaths.contains(where: { p == $0 || p.hasPrefix($0 + "/") })
                                && !denylisted(p, excludes: excludes)
                        }
                        guard !paths.isEmpty else { continue }
                        for p in paths { seen.insert(p); familyCovered.insert(p) }
                        scored.append((makeOldVersionsTarget(stem: fam.stem, dir: dir,
                                                             paths: paths, age: fam.staleAge),
                                       0.95, false))
                        emitted = true
                    }
                    return emitted
                }

                _ = emitFamilies(in: cachesRoot)
                for s in subs where !s.hasPrefix(".") {
                    let child = "\(cachesRoot)/\(s)"
                    // Already swept up into a family aggregate — offering it
                    // again as a plain folder would race two deletes.
                    guard !familyCovered.contains(child) else { continue }
                    if emitFamilies(in: child) {
                        // The vendor folder splits into per-version rows: the
                        // stale ones are aggregated above, the rest (current
                        // version, shared dirs) stand on their own.
                        for g in (try? fm.contentsOfDirectory(atPath: child)) ?? []
                        where !g.hasPrefix(".") && !familyCovered.contains("\(child)/\(g)") {
                            consider("\(child)/\(g)", derived: false, hasTag: false, designated: true)
                        }
                    } else {
                        consider(child, derived: false, hasTag: false, designated: true)
                    }
                }
            }
        }

        // 4) Electron/Chromium app caches + Group Container caches — big,
        //    common, and outside ~/Library/Caches.
        if roots.contains(home) {
            /// Chromium keeps the bulk of its cache *inside each profile*, so
            /// the flat sweep below only ever finds the small top-level copy.
            func considerProfiles(under dir: String) {
                for p in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where isChromiumProfile(p) {
                    for c in electronCacheDirs {
                        consider("\(dir)/\(p)/\(c)", derived: false, hasTag: false, designated: true)
                    }
                }
            }

            let appSupport = "\(home)/Library/Application Support"
            for app in (try? fm.contentsOfDirectory(atPath: appSupport)) ?? [] where !app.hasPrefix(".") {
                let appDir = "\(appSupport)/\(app)"
                for c in electronCacheDirs {
                    consider("\(appDir)/\(c)", derived: false, hasTag: false, designated: true)
                }
                // Profiles sit directly under the app dir (Electron apps) or a
                // level deeper for vendor-namespaced browsers (Google/Chrome).
                considerProfiles(under: appDir)
                for sub in (try? fm.contentsOfDirectory(atPath: appDir)) ?? [] where !sub.hasPrefix(".") {
                    considerProfiles(under: "\(appDir)/\(sub)")
                }
            }

            let groups = "\(home)/Library/Group Containers"
            for g in (try? fm.contentsOfDirectory(atPath: groups)) ?? [] where !g.hasPrefix(".") {
                consider("\(groups)/\(g)/Library/Caches", derived: false, hasTag: false, designated: true)
            }

            // Sandboxed apps keep their caches inside the container, where
            // neither the ~/Library/Caches sweep nor Finder ever reaches.
            let containers = "\(home)/Library/Containers"
            for c in (try? fm.contentsOfDirectory(atPath: containers)) ?? [] where !c.hasPrefix(".") {
                consider("\(containers)/\(c)/Data/Library/Caches",
                         derived: false, hasTag: false, designated: true)
            }
        }

        // 4b) Convention, not catalogue: every `~/.<tool>` and
        //     `~/.local/share/<tool>` gets checked for a conventionally-named
        //     cache child. This is what finds the tool nobody listed — the
        //     failure mode of a hardcoded table is silence, and silence here
        //     reads as "the disk is full and this app is useless".
        if roots.contains(home) {
            var toolDirs = ((try? fm.contentsOfDirectory(atPath: home)) ?? [])
                .filter { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
                .map { home + "/" + $0 }
            let xdg = "\(home)/.local/share"
            toolDirs += ((try? fm.contentsOfDirectory(atPath: xdg)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .map { xdg + "/" + $0 }

            for dir in toolDirs {
                for child in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                where conventionalCacheDirs.contains(child.lowercased()) {
                    consider("\(dir)/\(child)", derived: false, hasTag: false, designated: true)
                }
            }
        }

        // 4c) Self-declared: a folder flagged "don't back this up" is a tool
        //     saying its contents are expendable, in the one vocabulary every
        //     tool shares. No name to recognise, no catalogue to be in — this
        //     is the generic answer to "a tool nobody listed". Restricted to
        //     stale folders: a live data store gets written constantly, and
        //     some apps flag those too.
        if roots.contains(home) {
            // Measured on a real home folder this flag alone returns ~300
            // folders, nearly all of them small OS state (dictation models,
            // saved window positions). Weak evidence has to earn its row: it
            // is only worth offering if deleting it would actually help, so
            // the candidates get sized here — a bounded cost, since a noisy
            // hit is small by definition — and only the material ones stay.
            let flagged = backupExcludedDirectories(under: home, fm: fm)
                .filter { (ageInDays($0, fm) ?? 0) >= 30 }
                .map { (path: $0, size: Scanner.directorySize(atPath: $0)) }
                .filter { $0.size >= selfDeclaredMinBytes }
                .sorted { $0.size > $1.size }
                .prefix(25)
            for f in flagged {
                consider(f.path, derived: false, hasTag: false, designated: false,
                         selfDeclared: true)
            }
            sweepDebug("🏷️ kendi beyanı: \(flagged.count) klasör eşiği geçti")
        }

        // 4d) Learned by inference, not by memory: if two projects under a
        //     folder both had a `node_modules`, its other projects probably do
        //     too — and those have never been cleaned, may not be indexed, and
        //     nothing else here would ever look at them.
        for (container, kinds) in hotSpots {
            guard roots.contains(where: { container == $0 || container.hasPrefix($0 + "/") }) else { continue }
            let children = ((try? fm.contentsOfDirectory(atPath: container)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .prefix(400)
            for child in children {
                for kind in kinds {
                    consider("\(container)/\(child)/\(kind)",
                             derived: true, hasTag: false, designated: false)
                }
            }
        }

        // 5) Leftovers from uninstalled apps — the opaque bulk of "System Data".
        //    Bundle-id-named folders in Application Support / Containers whose
        //    app no longer exists anywhere on the system.
        if roots.contains(home) {
            let installed = installedBundleIDs()
            for base in ["\(home)/Library/Application Support", "\(home)/Library/Containers"] {
                guard let subs = try? fm.contentsOfDirectory(atPath: base) else { continue }
                var leftovers: [(path: String, age: Int?)] = []
                for s in subs where isBundleIDShaped(s) && !s.hasPrefix("com.apple.") {
                    let path = "\(base)/\(s)"
                    guard !seen.contains(path),
                          !seedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                          !denylisted(path, excludes: excludes),
                          isDir(path, fm),
                          !isInstalled(s, installed) else { continue }
                    leftovers.append((path, ageInDays(path, fm)))
                }
                // Stalest first; keep the list small — this is a hint, not a dragnet.
                for l in leftovers.sorted(by: { ($0.age ?? 0) > ($1.age ?? 0) }).prefix(12) {
                    seen.insert(l.path)
                    scored.append((makeLeftoverTarget(l.path, age: l.age), 0.75, false))
                }
            }
        }

        // 6) Old installer downloads — not a cache, but on a full disk it is
        //    usually the biggest thing the user can actually delete.
        if roots.contains(home),
           let installers = staleInstallers(in: "\(home)/Downloads", excludes: excludes) {
            scored.append((installers, 0.9, false))
        }

        // 7) Forgotten large files. Spotlight answers "which single files
        //    hold gigabytes" for free; the filter keeps only old, plainly
        //    visible ones — never anything inside Library, a hidden folder or
        //    an app bundle, where a big file is an app's live data store.
        var bigCandidates: [String] = []
        for root in roots {
            bigCandidates += mdfind(["-onlyin", root,
                                     "kMDItemFSSize >= \(largeFileMinBytes)"]).prefix(2000)
        }
        for t in largeFileTargets(from: bigCandidates, home: home,
                                  excludes: excludes, seedPaths: seedPaths) {
            scored.append((t, 0.85, false))
        }

        // Drop candidates nested inside a shallower candidate — the parent
        // already covers their bytes (prevents double counting and racing
        // deletes like `target` + `target/wasm32-unknown-unknown`).
        var kept: [(target: CleanTarget, rank: Double, capped: Bool)] = []
        for cand in scored.sorted(by: { $0.target.rawPaths[0].count < $1.target.rawPaths[0].count }) {
            let p = cand.target.rawPaths[0]
            if kept.contains(where: { p.hasPrefix($0.target.rawPaths[0] + "/") }) { continue }
            kept.append(cand)
        }

        // Only the Spotlight project sweep is unbounded, so only it gets
        // capped — and it is ranked by `priority`, which folds in the bytes
        // this kind has actually returned before. Capping everything by raw
        // score used to throw away the largest item on the disk.
        let bounded = kept.filter { !$0.capped }
        let sweep = kept.filter(\.capped).sorted { $0.rank > $1.rank }.prefix(120)
        return (bounded + sweep).sorted { $0.rank > $1.rank }.map(\.target)
    }

    /// Directories under `root` that carry `NSURLIsExcludedFromBackupKey`.
    ///
    /// Depth-limited and pruned: the flag is set on cache folders that sit
    /// near the top of a tool's own directory, never twelve levels down, and
    /// a full walk of a home folder is not something a menu-bar app gets to
    /// do on every scan.
    static func backupExcludedDirectories(under root: String, fm: FileManager,
                                          maxDepth: Int = 4, maxVisits: Int = 40_000) -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isExcludedFromBackupKey]
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                     includingPropertiesForKeys: Array(keys),
                                     options: [.skipsPackageDescendants],
                                     errorHandler: { _, _ in true }) else { return [] }
        var found: [String] = []
        var visits = 0
        for case let url as URL in en {
            visits += 1
            if visits > maxVisits { break }
            guard let v = try? url.resourceValues(forKeys: keys), v.isDirectory == true else {
                en.skipDescendants()
                continue
            }
            if v.isExcludedFromBackup == true {
                found.append(url.path)
                en.skipDescendants()          // the parent already covers it
                continue
            }
            // Never descend into somewhere the user's real data lives, and
            // stop before the walk turns into a full-disk crawl.
            if en.level >= maxDepth || neverDescend.contains(url.lastPathComponent) {
                en.skipDescendants()
            }
        }
        return found
    }

    /// Folders that are either the user's own data or already handled by a
    /// cheaper pass — walking into them is cost with no possible payoff.
    private static let neverDescend: Set<String> = [
        "Mail", "Messages", "Mobile Documents", "Photos", "Music", "Pictures",
        "Movies", "Documents", "Desktop", "node_modules", "Caches", ".Trash",
        // Hundreds of sandbox folders, every one of them flagged by macOS
        // itself and every one already covered by the container-cache pass.
        "Containers", "Group Containers", "Daemon Containers",
    ]

    /// Chromium profile folder names ("Default", "Profile 1", …).
    private static func isChromiumProfile(_ name: String) -> Bool {
        name == "Default" || name == "Guest Profile" || name == "System Profile"
            || name.hasPrefix("Profile ")
    }

    /// Large, old installer downloads, collected into one opt-in target.
    /// Only direct children of the folder — never a recursive sweep of the
    /// user's documents.
    static func staleInstallers(in dir: String, excludes: [String],
                                minBytes: UInt64 = installerMinBytes,
                                now: Date = Date()) -> CleanTarget? {
        let fm = FileManager()
        guard !denylisted(dir, excludes: excludes),
              let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey,
                                         .contentModificationDateKey]
        var files: [String] = []
        var oldest = 0
        for name in names {
            guard installerExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let path = dir + "/" + name
            guard !denylisted(path, excludes: excludes),
                  let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
                  v.isRegularFile == true,
                  let bytes = v.totalFileAllocatedSize, bytes >= Int(minBytes),
                  let modified = v.contentModificationDate else { continue }
            let age = Int(now.timeIntervalSince(modified) / 86_400)
            guard age >= installerMinAgeDays else { continue }
            files.append(path)
            oldest = max(oldest, age)
        }
        guard !files.isEmpty else { return nil }

        return CleanTarget(
            id: "installers:\(dir)",
            name: "seed.installers",
            detail: "\(tildeAbbreviate(dir)) · \(files.count)",
            symbol: "arrow.down.circle",
            rawPaths: files.sorted(),
            safety: .caution,           // real downloads — always opt-in
            strategy: .directory,
            isDiscovered: true,
            ageDays: oldest,
            category: .other
        )
    }

    // MARK: Version families

    struct VersionFamily {
        let stem: String          // display name ("IntelliJIdea"), never empty
        let stalePaths: [String]  // superseded versions, oldest activity ≥ threshold
        let staleAge: Int         // most recent activity among the stale ones
    }

    /// "Foo 2023.1" → ("Foo", [2023, 1]). Conservative: the name has to end
    /// in a plainly numeric version chunk; anything else is not a version.
    static func parseVersionedName(_ name: String) -> (stem: String, version: [Int])? {
        let chars = Array(name)
        var i = chars.count
        while i > 0, chars[i - 1].isNumber || chars[i - 1] == "." || chars[i - 1] == "_" {
            i -= 1
        }
        guard i < chars.count else { return nil }
        var versionPart = String(chars[i...])
        while let f = versionPart.first, !f.isNumber { versionPart.removeFirst() }
        let version = versionPart
            .split(whereSeparator: { $0 == "." || $0 == "_" })
            .compactMap { Int($0) }
        guard !version.isEmpty, versionPart.last?.isNumber == true else { return nil }
        var stem = String(chars[..<i])
        while let l = stem.last, l == " " || l == "." || l == "_" || l == "-" {
            stem.removeLast()
        }
        return (stem, version)
    }

    /// Sibling folders of one product that differ only by version, where the
    /// highest version supersedes the rest. Members other than the newest
    /// that nobody has touched in `staleAgeDays` are dead weight: the product
    /// reads its current version's folder and nothing ever migrates back.
    static func staleVersionFamilies(in dir: String, fm: FileManager,
                                     staleAgeDays: Int = versionStaleAgeDays) -> [VersionFamily] {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var groups: [String: [(name: String, version: [Int])]] = [:]
        for n in names where !n.hasPrefix(".") {
            guard let p = parseVersionedName(n), isDir("\(dir)/\(n)", fm) else { continue }
            groups[p.stem.lowercased(), default: []].append((n, p.version))
        }
        var out: [VersionFamily] = []
        for (key, members) in groups where members.count >= 2 {
            let sorted = members.sorted { $0.version.lexicographicallyPrecedes($1.version) }
            var staleAge = Int.max
            let stale = sorted.dropLast().compactMap { m -> String? in
                let p = "\(dir)/\(m.name)"
                guard let age = ageInDays(p, fm), age >= staleAgeDays else { return nil }
                staleAge = min(staleAge, age)
                return p
            }
            guard !stale.isEmpty else { continue }
            let stem = key.isEmpty ? (dir as NSString).lastPathComponent
                                   : parseVersionedName(sorted.last!.name)?.stem ?? key
            out.append(VersionFamily(stem: stem, stalePaths: stale, staleAge: staleAge))
        }
        return out.sorted { $0.stem < $1.stem }
    }

    private static func makeOldVersionsTarget(stem: String, dir: String,
                                              paths: [String], age: Int) -> CleanTarget {
        CleanTarget(
            id: "oldver:\(dir)/\(stem)",
            name: stem,
            detail: "\(tildeAbbreviate(dir)) · \(paths.count)",
            symbol: "clock.arrow.circlepath",
            rawPaths: paths.sorted(),
            safety: .safe,              // superseded cache versions under a Caches root
            strategy: .directory,
            isDiscovered: true,
            ageDays: age,
            isVersionFamily: true,
            category: .appCaches
        )
    }

    // MARK: Forgotten large files

    /// Filter Spotlight's size hits down to files worth a row: real files,
    /// verified big, untouched for a month, sitting in plain sight. Anything
    /// under a Library, a hidden folder or an app bundle is an app's problem,
    /// not the user's; installers in ~/Downloads belong to the installer row.
    static func largeFileTargets(from candidates: [String], home: String,
                                 excludes: [String], seedPaths: Set<String>,
                                 minBytes: UInt64 = largeFileMinBytes,
                                 minAgeDays: Int = largeFileMinAgeDays,
                                 cap: Int = largeFileCap,
                                 now: Date = Date()) -> [CleanTarget] {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey,
                                         .contentModificationDateKey]
        var picked: [(path: String, size: UInt64, age: Int)] = []
        var seenPaths = Set<String>()
        for path in candidates {
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            let comps = (path as NSString).pathComponents
            guard !comps.contains(where: {
                $0.hasPrefix(".") || $0 == "Library" || $0.hasSuffix(".app")
            }) else { continue }
            if denylisted(path, excludes: excludes) { continue }
            if seedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            let ext = (path as NSString).pathExtension.lowercased()
            if installerExtensions.contains(ext), path.hasPrefix(home + "/Downloads/") { continue }
            // Spotlight metadata can be stale — re-verify against the filesystem.
            guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
                  v.isRegularFile == true,
                  let bytes = v.totalFileAllocatedSize, UInt64(bytes) >= minBytes,
                  let modified = v.contentModificationDate else { continue }
            let age = Int(now.timeIntervalSince(modified) / 86_400)
            guard age >= minAgeDays else { continue }
            picked.append((path, UInt64(bytes), age))
        }
        return picked.sorted { $0.size > $1.size }.prefix(cap).map { f in
            CleanTarget(
                id: "bigfile:\(f.path)",
                name: (f.path as NSString).lastPathComponent,
                detail: tildeAbbreviate((f.path as NSString).deletingLastPathComponent),
                symbol: fileSymbol(for: (f.path as NSString).pathExtension.lowercased()),
                rawPaths: [f.path],
                safety: .caution,       // a real file — always the user's call
                strategy: .directory,
                isDiscovered: true,
                ageDays: f.age,
                category: .other
            )
        }
    }

    private static func fileSymbol(for ext: String) -> String {
        switch ext {
        case "mov", "mp4", "mkv", "avi", "webm":            return "film"
        case "zip", "tar", "gz", "tgz", "7z", "rar":        return "doc.zipper"
        case "dmg", "iso", "img", "raw", "vdi", "vmdk", "qcow2": return "externaldrive"
        default:                                            return "doc"
        }
    }

    // MARK: Classifier

    struct Verdict { let safety: Safety; let score: Double }

    static func classify(_ path: String, derived: Bool, hasTag: Bool, designated: Bool,
                         selfDeclared: Bool = false,
                         excludes: [String], ageDays: Int?, active: Bool, learnBoost: Double) -> Verdict? {
        if denylisted(path, excludes: excludes) { return nil }

        var cache = 0.0
        var safe = 0.0
        if hasTag                                     { cache += 1.0; safe += 0.6 }   // definitive
        if excludedFromBackup(path)                   { cache += 0.5; safe += 0.3 }   // dev said expendable
        // A folder that lives in a location macOS *designates* as a cache
        // (~/Library/Caches, a container's Caches, a Chromium cache dir) is
        // as definitive as CACHEDIR.TAG: the OS purges these itself under
        // disk pressure. Scoring this below the 0.7 gate dropped every single
        // entry under ~/Library/Caches — the largest reliable source there is.
        if designated                                { cache += 1.0; safe += 0.4 }
        if cacheNameTokens.contains(lastComp(path))   { cache += 0.4 }
        if derived                                    { cache += 0.5; safe += 0.7 }   // regenerable
        // Found *because* the folder carries the don't-back-this-up flag: the
        // tool declared it expendable itself — no name to recognise, no table
        // to be in. Enough to clear the gate together with the flag's own 0.5,
        // and deliberately no safety credit: some apps flag real data stores
        // too, so this may be offered but must never be preselected.
        if selfDeclared                               { cache += 0.3 }

        // Behavioral signals (Phase 2): staleness & live activity.
        if let ageDays {
            if ageDays >= 7      { safe += 0.3 }      // untouched for a week → safe to clear
            else if ageDays <= 1 { safe -= 0.2 }      // fresh → be cautious
        }
        if active { safe -= 0.6 }                     // being written right now → don't auto-select

        // Learned confidence (Phase 3): accumulated user/regeneration evidence.
        if learnBoost > 0 { cache += min(0.4, learnBoost); safe += learnBoost }
        else if learnBoost < 0 { safe += learnBoost }

        guard cache >= 0.7 else { return nil }
        return Verdict(safety: safe >= 0.6 ? .safe : .caution, score: cache)
    }

    /// Never offer these — sensitive or real user data, plus user exclusions.
    private static func denylisted(_ path: String, excludes: [String]) -> Bool {
        let home = NSHomeDirectory()
        let blocked = [
            "\(home)/Library/Mobile Documents",   // iCloud Drive
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Keychains",
            "\(home)/.ssh",
            "\(home)/.gnupg",
            "\(home)/.config",                    // config ≠ cache
        ]
        if blocked.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        if excludes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        if path.contains(".photoslibrary") || path.contains(".sparsebundle") { return true }
        return false
    }

    private static func excludedFromBackup(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    // MARK: Helpers

    private static func makeTarget(_ path: String, _ v: Verdict, ageDays: Int?, inUse: Bool,
                                   learned: Bool, boomerang: Bool,
                                   category: TargetCategory) -> CleanTarget {
        let leaf = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return CleanTarget(
            id: "disc:\(path)",
            name: CleanTarget.displayName(leaf: leaf, parent: parent),
            detail: tildeAbbreviate(path),
            symbol: symbol(for: leaf),
            rawPaths: [path],
            safety: v.safety,
            strategy: .directory,
            isDiscovered: true,
            ageDays: ageDays,
            inUse: inUse,
            learned: learned,
            boomerang: boomerang,
            category: category
        )
    }

    private static func symbol(for name: String) -> String {
        switch name.lowercased() {
        case "node_modules", "pods", "vendor":               return "shippingbox"
        case "target", "build", ".gradle", ".build":         return "hammer"
        case "deriveddata":                                  return "hammer.fill"
        case ".venv", "__pycache__", ".pytest_cache":        return "ladybug"
        default:                                             return "tray.full"
        }
    }

    private static func lastComp(_ path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }

    private static func tildeAbbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func isDir(_ path: String, _ fm: FileManager) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    // MARK: Uninstalled-app leftovers

    /// "com.vendor.App"-shaped names only — matching by display name is too risky.
    private static func isBundleIDShaped(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        return parts.count >= 3 && !name.contains(" ")
    }

    /// Is an app with this bundle id (or a parent of it) present on the system?
    /// LaunchServices lookup catches apps anywhere; the prefix check keeps
    /// helper folders like com.microsoft.VSCode.ShipIt tied to their app.
    private static func isInstalled(_ id: String, _ installed: Set<String>) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return true }
        return installed.contains { id == $0 || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }
    }

    /// Bundle ids of everything in the standard app folders.
    private static func installedBundleIDs() -> Set<String> {
        let fm = FileManager()
        var ids = Set<String>()
        let dirs = ["/Applications", "/Applications/Utilities",
                    "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            guard let apps = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for app in apps where app.hasSuffix(".app") {
                if let d = NSDictionary(contentsOfFile: "\(dir)/\(app)/Contents/Info.plist"),
                   let id = d["CFBundleIdentifier"] as? String {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    private static func makeLeftoverTarget(_ path: String, age: Int?) -> CleanTarget {
        // "com.brawersoftware.QuickLook-Thumbnail" → show "QuickLook-Thumbnail";
        // the full bundle id stays readable in the detail path (marquee).
        let bundleID = (path as NSString).lastPathComponent
        let readable = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return CleanTarget(
            id: "left:\(path)",
            name: readable,
            detail: tildeAbbreviate(path),
            symbol: "archivebox",
            rawPaths: [path],
            safety: .caution,           // may hold licenses/data — always opt-in
            strategy: .directory,
            isDiscovered: true,
            ageDays: age,
            isLeftover: true,
            category: .leftovers
        )
    }

    /// Days since the directory was last modified (cheap staleness proxy).
    private static func ageInDays(_ path: String, _ fm: FileManager) -> Int? {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else { return nil }
        return max(0, Int(Date().timeIntervalSince(mod) / 86_400))
    }

    /// Is this path (or an ancestor/descendant) currently being written?
    private static func isActive(_ path: String, _ active: Set<String>) -> Bool {
        active.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
    }

    /// Run `mdfind` and return the matched paths (Spotlight, near-instant).
    private static func mdfind(_ args: [String]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }
}
