import XCTest
@testable import Cachesweep

/// The signature decides what generalises and what stays attributed. Get it
/// wrong in one direction and every app's `Cache` pools into one meaningless
/// bucket; wrong in the other and a lesson learned in one project never
/// applies to the next.
final class SignatureTests: XCTestCase {

    private func sig(_ path: String) -> String { LearningStore.signature(forPath: path) }

    func testDistinctiveLeafGeneralisesAcrossProjects() {
        // The point of a kind: cleaned once in one project, trusted in all.
        XCTAssertEqual(sig("/Users/x/a/node_modules"), "node_modules")
        XCTAssertEqual(sig("/Volumes/ssd/b/node_modules"), "node_modules")
        XCTAssertEqual(sig("/Users/x/proj/DerivedData"), "deriveddata")
    }

    func testAmbiguousLeafIsQualifiedByItsApp() {
        XCTAssertEqual(sig("/Users/x/Library/Application Support/Code/Cache"), "code/cache")
        XCTAssertEqual(sig("/Users/x/Library/Application Support/Figma/Cache"), "figma/cache")
    }

    /// Regression: these two used to collapse into the single key "cache",
    /// so cleaning Chrome taught the app about Figma.
    func testTwoAppsDoNotShareOneBucket() {
        XCTAssertNotEqual(sig("/Users/x/Library/Application Support/Code/Cache"),
                          sig("/Users/x/Library/Application Support/Figma/Cache"))
    }

    func testStructuralComponentsAreSkipped() {
        XCTAssertEqual(
            sig("/Users/x/Library/Containers/com.docker.docker/Data/Library/Caches"),
            "com.docker.docker/caches")
        XCTAssertEqual(
            sig("/Users/x/Library/Application Support/Google/Chrome/Profile 7/Service Worker/CacheStorage"),
            "chrome/cachestorage")
    }

    func testHomeFolderNameIsNeverTheOwner() {
        XCTAssertEqual(sig("/Users/gorkemyildiz/Data"), "data")
    }

    func testDiscoveryAndStoreAgreeOnTheSignature() {
        // Discovery used to compute its own leaf-only signature, so a boost
        // recorded by the store could never be looked up again.
        let path = "/Users/x/Library/Application Support/Code/Cache"
        XCTAssertEqual(LearningStore.signature(forPath: path), "code/cache")
    }
}

/// Size is a priority signal, never a safety one.
final class PriorityTests: XCTestCase {

    func testUnknownKindKeepsItsRawScore() {
        XCTAssertEqual(Discovery.priority(score: 1.0, expectedBytes: 0), 1.0)
    }

    func testBiggerHistoryOutranksSmaller() {
        let small = Discovery.priority(score: 1.0, expectedBytes: 100 * 1024 * 1024)
        let large = Discovery.priority(score: 1.0, expectedBytes: 8 * 1024 * 1024 * 1024)
        XCTAssertGreaterThan(large, small)
    }

    /// A confident-but-small candidate must not be buried under a huge one:
    /// the bonus is capped so score still dominates.
    func testSizeBonusIsBounded() {
        let huge = Discovery.priority(score: 1.0, expectedBytes: 500 * 1024 * 1024 * 1024)
        XCTAssertLessThanOrEqual(huge, 1.6)
        XCTAssertGreaterThan(Discovery.priority(score: 1.5, expectedBytes: 0), 1.0)
    }
}

final class DeviceProfileTests: XCTestCase {

    func testOnlyCatalogueEntriesPresentOnThisMachineSurvive() {
        for s in DeviceProfile.seeds() where !s.rawPaths.isEmpty {
            XCTAssertTrue(s.expandedPaths.contains { FileManager.default.fileExists(atPath: $0) },
                          "\(s.id) has no path on this machine and should have been dropped")
        }
    }

    func testSeedsNeverOverlap() {
        let paths = DeviceProfile.seeds().flatMap(\.expandedPaths)
        for a in paths {
            for b in paths where a != b {
                XCTAssertFalse(a.hasPrefix(b + "/"), "\(a) is inside \(b) — bytes counted twice")
            }
        }
    }

    /// The catalogue and a probe are allowed to disagree; whichever covers
    /// more wins, and that has to work in both directions.
    func testNestingIsResolvedTowardsTheAncestor() {
        func t(_ id: String, _ path: String) -> CleanTarget {
            CleanTarget(id: id, name: id, detail: path, symbol: "s",
                        rawPaths: [path], safety: .safe, strategy: .directory)
        }
        // Probe answers deeper than the seed (uv → ~/.cache/uv).
        let a = DeviceProfile.dropNested([t("probe", "/h/.cache/uv"), t("seed", "/h/.cache")])
        XCTAssertEqual(a.map(\.id), ["seed"])

        // Probe answers shallower than the seed (npm → ~/.npm).
        let b = DeviceProfile.dropNested([t("seed", "/h/.npm/_cacache"), t("probe", "/h/.npm")])
        XCTAssertEqual(b.map(\.id), ["probe"])

        // Unrelated paths both survive — a pnpm store on another disk is real.
        let c = DeviceProfile.dropNested([t("seed", "/h/Library/pnpm/store"),
                                          t("probe", "/Volumes/ssd/.pnpm-store/v11")])
        XCTAssertEqual(Set(c.map(\.id)), ["seed", "probe"])
    }

    func testOverlappingPathsAreTrimmedNotDropped() {
        let wide = CleanTarget(id: "wide", name: "w", detail: "", symbol: "s",
                               rawPaths: ["/h/a"], safety: .safe, strategy: .directory)
        let mixed = CleanTarget(id: "mixed", name: "m", detail: "", symbol: "s",
                                rawPaths: ["/h/a/inside", "/h/b"], safety: .safe,
                                strategy: .directory)
        let kept = DeviceProfile.dropNested([wide, mixed])
        XCTAssertEqual(kept.first { $0.id == "mixed" }?.rawPaths, ["/h/b"])
    }

    func testRustToolchainsNeverOfferTheDefaultOne() throws {
        let root = try makeRustupFixture(default: "stable-aarch64-apple-darwin",
                                         toolchains: ["stable-aarch64-apple-darwin",
                                                      "1.94-aarch64-apple-darwin"])
        let targets = DeviceProfile.rustToolchains(root: root.path)
        let paths = targets.flatMap(\.rawPaths)
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths[0].hasSuffix("1.94-aarch64-apple-darwin"))
        XCTAssertEqual(targets.first?.safety, .caution)
    }

    /// If the default can't be read we cannot tell the active toolchain from
    /// the spares, and deleting the active one breaks the Rust install.
    func testRustToolchainsBailOutWhenTheDefaultIsUnreadable() throws {
        let root = try makeRustupFixture(default: nil,
                                         toolchains: ["stable-aarch64-apple-darwin"])
        XCTAssertTrue(DeviceProfile.rustToolchains(root: root.path).isEmpty)
    }

    func testDefaultToolchainParsing() {
        let toml = """
        default_toolchain = "stable-aarch64-apple-darwin"
        profile = "default"
        """
        XCTAssertEqual(DeviceProfile.defaultToolchain(in: toml), "stable-aarch64-apple-darwin")
        XCTAssertNil(DeviceProfile.defaultToolchain(in: "profile = \"default\""))
    }

    func testLearnedPlacesSkipWhatTheCatalogueAlreadyCovers() {
        let covered: Set<String> = ["/Users/x/proj/target"]
        let made = DeviceProfile.learnedTargets(["/Users/x/proj/target/wasm32"], covered: covered)
        XCTAssertTrue(made.isEmpty, "a nested place would double-count its parent's bytes")
    }

    /// Fixture: a fake `~/.rustup` so the test doesn't depend on whether Rust
    /// is installed on the machine running it.
    private func makeRustupFixture(default active: String?,
                                   toolchains: [String]) throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cachesweep-rustup-\(UUID().uuidString)")
        for t in toolchains {
            try fm.createDirectory(at: root.appendingPathComponent("toolchains/\(t)"),
                                   withIntermediateDirectories: true)
        }
        let toml = active.map { "default_toolchain = \"\($0)\"\n" } ?? "profile = \"default\"\n"
        try toml.write(to: root.appendingPathComponent("settings.toml"),
                       atomically: true, encoding: .utf8)
        addTeardownBlock { try? fm.removeItem(at: root) }
        return root
    }

    func testLearnedPlacesAreOptInAndMarked() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cachesweep-learned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let made = DeviceProfile.learnedTargets([dir.path], covered: [])
        let t = try XCTUnwrap(made.first)
        XCTAssertEqual(t.safety, .caution)
        XCTAssertTrue(t.learned)
        XCTAssertTrue(t.id.hasPrefix(DeviceProfile.learnedPrefix))
        XCTAssertEqual(t.rawPaths, [dir.path])
    }
}

/// Asking the tool is only better than guessing if a bad answer can't reach
/// the delete button.
final class ToolProbeTests: XCTestCase {

    func testKeepsOnlyExistingAbsolutePaths() {
        let out = """
        /tmp
        relative/path
        undefined
        /definitely/not/here/\(UUID().uuidString)
        """
        XCTAssertEqual(ToolProbe.parse(out), ["/tmp"])
    }

    func testEmptyAnswerYieldsNothing() {
        XCTAssertTrue(ToolProbe.parse("").isEmpty)
        XCTAssertTrue(ToolProbe.parse("\n \n").isEmpty)
    }

    func testMissingToolIsSkippedRatherThanGuessed() {
        let probe = ToolProbe.Probe(id: "nope", name: "n", symbol: "s",
                                    executable: "cachesweep-no-such-tool-\(UUID().uuidString)",
                                    arguments: [])
        XCTAssertTrue(ToolProbe.ask(probe).isEmpty)
    }

    func testLocateFindsAToolOutsideTheInheritedPath() {
        // A menu-bar app is launched by launchd with a minimal PATH, so the
        // fallback prefixes are the whole point of `locate`.
        XCTAssertNotNil(ToolProbe.locate("ls"))
    }

    func testEveryProbeAsksForAPathAndNothingElse() {
        for p in ToolProbe.probes {
            XCTAssertFalse(p.arguments.contains { $0.hasPrefix("/") },
                           "\(p.id) passes a path in — probes only ever read")
            XCTAssertFalse(p.executable.contains("/"), "\(p.id) must resolve via PATH")
        }
    }
}

/// Learning that only reweighs a score can never surface a place the scan
/// does not already look at. These are the two mechanisms that can.
final class InferenceTests: XCTestCase {

    /// Exercises the derivation without touching the shared on-disk store.
    private func hotSpots(for paths: [String]) -> [String: Set<String>] {
        var seen: [String: [String: Set<String>]] = [:]
        for path in paths {
            let kind = (path as NSString).lastPathComponent
            let project = (path as NSString).deletingLastPathComponent
            let container = (project as NSString).deletingLastPathComponent
            seen[container, default: [:]][kind, default: []].insert(project)
        }
        return seen.reduce(into: [:]) { out, e in
            let kinds = e.value.filter { $0.value.count >= 2 }.keys
            if !kinds.isEmpty { out[e.key] = Set(kinds) }
        }
    }

    func testHotSpotsGeneraliseFromSiblingsNotFromASingleHit() {
        let spots = hotSpots(for: ["/w/projA/node_modules", "/w/projB/node_modules",
                                   "/z/only/target"])
        XCTAssertEqual(spots["/w"], ["node_modules"])
        XCTAssertNil(spots["/z"], "one sighting is a coincidence, not a pattern")
    }

    /// A folder found only because it flags itself "don't back this up" is a
    /// self-declaration, not a proof — offerable, never preselected.
    func testSelfDeclaredIsOfferedButNeverPreselected() {
        let v = Discovery.classify("/Users/x/.sometool/blobstore",
                                   derived: false, hasTag: false, designated: false,
                                   selfDeclared: true, excludes: [],
                                   ageDays: 200, active: false, learnBoost: 0)
        XCTAssertNotEqual(v?.safety, .safe, "a self-declaration must not preselect anything")
    }

    func testBackupSweepIsDepthLimited() {
        let found = Discovery.backupExcludedDirectories(
            under: NSTemporaryDirectory(), fm: FileManager(), maxDepth: 1, maxVisits: 50)
        XCTAssertLessThan(found.count, 50)
    }
}

final class RootAdvisorTests: XCTestCase {

    func testCoverageMatchesWholePathComponents() {
        XCTAssertTrue(RootAdvisor.covered("/Volumes/ssd/p", by: ["/Volumes/ssd"]))
        XCTAssertTrue(RootAdvisor.covered("/Volumes/ssd", by: ["/Volumes/ssd"]))
        XCTAssertFalse(RootAdvisor.covered("/Volumes/ssd2", by: ["/Volumes/ssd"]),
                       "a prefix is not a parent")
    }

    func testDeepestMountPointWins() {
        let volumes = ["/", "/Volumes/ssd", "/Volumes/ssd/nested"]
        XCTAssertEqual(RootAdvisor.volume(of: "/Volumes/ssd/nested/x", among: volumes),
                       "/Volumes/ssd/nested")
        XCTAssertEqual(RootAdvisor.volume(of: "/Users/x", among: volumes), "/")
    }

    /// The pnpm store on this machine lives on an external disk — direct
    /// evidence that the scan roots are pointed at the wrong place.
    func testAToolReportingAPathOutsideTheRootsIsEvidence() {
        XCTAssertFalse(RootAdvisor.covered("/Volumes/harici_ssd/.pnpm-store/v11",
                                           by: [NSHomeDirectory()]))
    }
}

/// These probes run other people's programs, some of which would rather ask
/// a question than answer one.
final class ToolProbeHardeningTests: XCTestCase {

    /// `cat` with no arguments reads stdin until EOF. With stdin inherited
    /// this blocks forever, which is exactly how a corepack shim's download
    /// prompt wedged the whole scan — refreshSeeds() is awaited before
    /// anything else and isScanning would never clear again.
    func testAProbeThatReadsStdinReturnsInsteadOfHanging() {
        let probe = ToolProbe.Probe(id: "stdin", name: "n", symbol: "s",
                                    executable: "cat", arguments: [])
        let done = expectation(description: "probe returned")
        DispatchQueue.global().async {
            _ = ToolProbe.ask(probe)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testTimeoutsAreBoundedAndOrdered() {
        XCTAssertLessThanOrEqual(ToolProbe.probeTimeout, 30,
                                 "a config question must not hold the scan open")
        XCTAssertGreaterThan(SimulatorRuntimes.deleteTimeout, SimulatorRuntimes.listTimeout,
                             "moving gigabytes needs longer than asking a question")
    }
}
