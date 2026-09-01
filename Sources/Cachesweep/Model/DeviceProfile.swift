import Foundation

/// What *this* Mac actually has installed.
///
/// `CleanTarget.all` is a catalogue, not a plan. On any given machine most of
/// it is absent — on the machine this was written for, 20 of 22 entries were
/// zero bytes, because the projects lived on an external disk — while the
/// things that really hold gigabytes (a spare Rust toolchain, an Android
/// system image, a JetBrains cache) differ from developer to developer. A
/// fixed list can't express that, so this probes the machine instead:
///
///   * catalogue entries are kept only where their paths exist;
///   * per-tool contents that no static path can name (which Rust toolchains
///     are spare, for instance) are enumerated live;
///   * places the user's own cleaning history proved worth checking are
///     re-offered directly, even if no scan rule would have found them.
///
/// That last part is the one that matters most: learning that only reweighs a
/// score can never surface something the scan doesn't already look at.
enum DeviceProfile {

    /// The seed set for this machine.
    static func seeds(knownPlaces: [String] = [],
                      probed: [CleanTarget] = []) -> [CleanTarget] {
        let present = CleanTarget.all.filter { target in
            // A target with no paths (nothing to probe) stays; one with paths
            // has to have at least one that exists here.
            target.rawPaths.isEmpty || target.expandedPaths.contains(where: isDirectory)
        }
        let deduped = dropNested(probed + present + rustToolchains() + volumeTrashes())
        let covered = Set(deduped.flatMap(\.expandedPaths))
        return deduped + learnedTargets(knownPlaces, covered: covered)
    }

    // MARK: Per-volume trash

    /// Every mounted volume keeps its own trash under `.Trashes/<uid>` —
    /// files deleted there never pass through `~/.Trash`, so the home seed
    /// misses them entirely. One aggregate row for all of them: it is all
    /// trash the user already threw away.
    static func volumeTrashes(volumesDir: String = "/Volumes") -> [CleanTarget] {
        let fm = FileManager.default
        guard let vols = try? fm.contentsOfDirectory(atPath: volumesDir) else { return [] }
        var paths: [String] = []
        var names: [String] = []
        for v in vols where !v.hasPrefix(".") {
            let volPath = volumesDir + "/" + v
            // The boot volume appears here as a symlink to "/" — its trash is
            // the home-folder seed's job.
            if (try? fm.destinationOfSymbolicLink(atPath: volPath)) != nil { continue }
            let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsReadOnlyKey]
            guard let rv = try? URL(fileURLWithPath: volPath).resourceValues(forKeys: keys),
                  rv.volumeIsLocal == true,           // never walk a network mount
                  rv.volumeIsReadOnly != true else { continue }
            let trash = volPath + "/.Trashes/\(getuid())"
            guard let contents = try? fm.contentsOfDirectory(atPath: trash),
                  !contents.isEmpty else { continue }
            paths.append(trash)
            names.append(v)
        }
        guard !paths.isEmpty else { return [] }
        return [CleanTarget(
            id: "volume-trashes",
            name: "seed.volumetrash",
            detail: names.sorted().joined(separator: ", "),
            symbol: "trash",
            rawPaths: paths.sorted(),
            safety: .safe,                  // already deleted by the user
            strategy: .contents,
            externalScope: true,            // outside every scan root by definition
            category: .other
        )]
    }

    /// Two seeds that overlap would count the same bytes twice and race two
    /// deletes against each other. The ancestor wins: it covers strictly more
    /// and both are caches either way.
    ///
    /// This is what lets a probe and the catalogue disagree harmlessly, in
    /// both directions. `uv cache dir` answers `~/.cache/uv`, which the
    /// `~/.cache` seed already contains, so the seed stands; `npm config get
    /// cache` answers `~/.npm`, which contains the `~/.npm/_cacache` seed, so
    /// the probe stands. Neither needed to know about the other.
    static func dropNested(_ targets: [CleanTarget]) -> [CleanTarget] {
        var keptPaths: [String] = []
        var kept: [CleanTarget] = []
        // Shallowest first, so an ancestor is always weighed before its
        // descendants — a descendant's path is necessarily the longer string.
        let ordered = targets.sorted {
            ($0.expandedPaths.first?.count ?? 0) < ($1.expandedPaths.first?.count ?? 0)
        }
        for target in ordered {
            guard !target.rawPaths.isEmpty else { kept.append(target); continue }
            let fresh = target.expandedPaths.filter { p in
                !keptPaths.contains { p == $0 || p.hasPrefix($0 + "/") }
            }
            guard !fresh.isEmpty else { continue }
            var copy = target
            copy.rawPaths = fresh          // keep only the parts nobody covers
            kept.append(copy)
            keptPaths += fresh
        }
        return kept
    }

    // MARK: Live per-tool detection

    /// Rust keeps every toolchain it has ever installed, about a gigabyte
    /// apiece. The default one is in use; the rest are one
    /// `rustup toolchain install` away from coming back. Which is which can
    /// only be answered by reading the machine, never by a fixed path.
    static func rustToolchains(root: String = NSHomeDirectory() + "/.rustup") -> [CleanTarget] {
        let dir = root + "/toolchains"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir),
              let settings = try? String(contentsOfFile: root + "/settings.toml", encoding: .utf8),
              // Without a parseable default we cannot tell the active toolchain
              // from the spares, and offering the active one would break Rust.
              let active = defaultToolchain(in: settings)
        else { return [] }

        let spare = names.filter { !$0.hasPrefix(".") && $0 != active }.sorted()
        guard !spare.isEmpty else { return [] }
        return [CleanTarget(
            id: "rustup-toolchains",
            name: "Rust Toolchains",
            detail: "~/.rustup/toolchains · " + spare.joined(separator: ", "),
            symbol: "shippingbox",
            rawPaths: spare.map { dir + "/" + $0 },
            safety: .caution,               // real toolchains, just re-installable
            strategy: .directory
        )]
    }

    /// Pull `default_toolchain = "stable-aarch64-apple-darwin"` out of
    /// rustup's settings.toml.
    static func defaultToolchain(in settings: String) -> String? {
        for line in settings.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "default_toolchain"
            else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: Learned places

    /// Locations the user has cleaned before, offered again directly.
    /// Skips anything the catalogue already covers, so nothing is counted twice.
    static func learnedTargets(_ paths: [String], covered: Set<String>) -> [CleanTarget] {
        paths.compactMap { path in
            guard isDirectory(path),
                  !covered.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
            else { return nil }
            let leaf = (path as NSString).lastPathComponent
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return CleanTarget(
                id: learnedPrefix + path,
                name: CleanTarget.displayName(leaf: leaf, parent: parent),
                detail: tildeAbbreviate(path),
                // Not "brain": that glyph is the AI-data category's. A learned
                // place is still a cache — the detail line says how we know it.
                symbol: "tray.full",
                rawPaths: [path],
                safety: .caution,           // learned, not proven — still opt-in
                strategy: .directory,
                isDiscovered: true,
                learned: true
            )
        }
    }

    static let learnedPrefix = "learned:"

    // MARK: Helpers

    private static func isDirectory(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    private static func tildeAbbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
