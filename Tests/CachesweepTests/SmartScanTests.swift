import XCTest
@testable import Cachesweep

/// Version families: "IntelliJIdea2023.1" beside a live 2024.x is dead
/// weight, but the parse has to be conservative — a wrong grouping here
/// deletes somebody's current cache.
final class VersionFamilyTests: XCTestCase {

    func testParsesTrailingVersions() throws {
        let a = try XCTUnwrap(Discovery.parseVersionedName("IntelliJIdea2023.1"))
        XCTAssertEqual(a.stem, "IntelliJIdea")
        XCTAssertEqual(a.version, [2023, 1])

        let b = try XCTUnwrap(Discovery.parseVersionedName("Sublime Text 3"))
        XCTAssertEqual(b.stem, "Sublime Text")
        XCTAssertEqual(b.version, [3])

        let c = try XCTUnwrap(Discovery.parseVersionedName("Foo.2023.1"))
        XCTAssertEqual(c.stem, "Foo")
        XCTAssertEqual(c.version, [2023, 1])
    }

    func testRejectsNamesWithoutAVersionTail() {
        XCTAssertNil(Discovery.parseVersionedName("Safari"))
        XCTAssertNil(Discovery.parseVersionedName("1Password"),
                     "a leading digit is a name, not a version")
        XCTAssertNil(Discovery.parseVersionedName("Chrome 2 Beta"),
                     "the version chunk has to be the tail")
    }

    func testBundleIdWithTrailingDigitStillParses() throws {
        let p = try XCTUnwrap(Discovery.parseVersionedName("com.foo.bar2"))
        XCTAssertEqual(p.stem, "com.foo.bar")
        XCTAssertEqual(p.version, [2])
    }

    // MARK: On-disk family detection

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cachesweep-versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeDir(_ name: String, ageDays: Int) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let modified = Date().addingTimeInterval(-Double(ageDays) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: url.path)
    }

    func testOldVersionsAreCollectedAndTheNewestNever() throws {
        try makeDir("IntelliJIdea2023.1", ageDays: 200)
        try makeDir("IntelliJIdea2023.3", ageDays: 90)
        try makeDir("IntelliJIdea2024.2", ageDays: 400)   // newest by VERSION — immune

        let fams = Discovery.staleVersionFamilies(in: dir.path, fm: FileManager())
        XCTAssertEqual(fams.count, 1)
        XCTAssertEqual(fams.first?.stem, "IntelliJIdea")
        XCTAssertEqual(fams.first?.stalePaths.map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["IntelliJIdea2023.1", "IntelliJIdea2023.3"])
        XCTAssertEqual(fams.first?.staleAge, 90, "the freshest stale member drives the badge")
    }

    func testFreshOldVersionIsLeftAlone() throws {
        try makeDir("Tool 1.0", ageDays: 5)     // superseded but still warm
        try makeDir("Tool 2.0", ageDays: 0)

        XCTAssertTrue(Discovery.staleVersionFamilies(in: dir.path, fm: FileManager()).isEmpty)
    }

    func testSingleVersionIsNotAFamily() throws {
        try makeDir("Tool 1.0", ageDays: 400)
        XCTAssertTrue(Discovery.staleVersionFamilies(in: dir.path, fm: FileManager()).isEmpty)
    }
}

/// The large-file pass offers real files — every filter here is a promise
/// about what the app will never put a checkbox next to.
final class LargeFileTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cachesweep-bigfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func write(_ rel: String, bytes: Int, ageDays: Int) throws -> String {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        let modified = Date().addingTimeInterval(-Double(ageDays) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: url.path)
        return url.path
    }

    private func targets(_ candidates: [String], minBytes: UInt64 = 20_000,
                         seedPaths: Set<String> = []) -> [CleanTarget] {
        Discovery.largeFileTargets(from: candidates, home: home.path, excludes: [],
                                   seedPaths: seedPaths, minBytes: minBytes)
    }

    func testFindsOldBigFilesSortedBySize() throws {
        let a = try write("Movies-raw/shoot.mov", bytes: 40_000, ageDays: 60)
        let b = try write("backup.tar", bytes: 80_000, ageDays: 90)

        let out = targets([a, b])
        XCTAssertEqual(out.map(\.rawPaths), [[b], [a]], "biggest first")
        XCTAssertEqual(out.first?.safety, .caution, "a real file is always the user's call")
        XCTAssertEqual(out.first?.category, .other)
        XCTAssertEqual(out.first?.symbol, "doc.zipper")
    }

    func testNeverOffersHiddenLibraryOrAppBundlePaths() throws {
        let hidden = try write(".docker/disk.raw", bytes: 40_000, ageDays: 60)
        let library = try write("Library/Mail/huge.mbox", bytes: 40_000, ageDays: 60)
        let bundle = try write("Apps/Foo.app/big.bin", bytes: 40_000, ageDays: 60)

        XCTAssertTrue(targets([hidden, library, bundle]).isEmpty)
    }

    func testSkipsFreshFilesAndSeedCoveredPaths() throws {
        let fresh = try write("render.mov", bytes: 40_000, ageDays: 2)
        let covered = try write("ollama/model.bin", bytes: 40_000, ageDays: 60)

        XCTAssertTrue(targets([fresh, covered],
                              seedPaths: [home.appendingPathComponent("ollama").path]).isEmpty)
    }

    func testInstallersInDownloadsBelongToTheInstallerRow() throws {
        let dmg = try write("Downloads/Xcode.dmg", bytes: 40_000, ageDays: 60)
        let elsewhere = try write("Archive/old.dmg", bytes: 40_000, ageDays: 60)

        let out = targets([dmg, elsewhere])
        XCTAssertEqual(out.map(\.rawPaths), [[elsewhere]],
                       "~/Downloads installers are the installer target's job")
    }

    func testCapKeepsTheBiggest() throws {
        var paths: [String] = []
        for i in 0..<5 {
            // Steps larger than the 4 kB allocation block, so sizes stay distinct.
            paths.append(try write("f\(i).bin", bytes: 20_000 + i * 8_192, ageDays: 60))
        }
        let out = Discovery.largeFileTargets(from: paths, home: home.path, excludes: [],
                                             seedPaths: [], minBytes: 20_000, cap: 2)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first?.rawPaths, [paths[4]])
    }
}

/// Per-volume trash: deleted files that never passed through ~/.Trash.
final class VolumeTrashTests: XCTestCase {

    private var volumes: URL!

    override func setUpWithError() throws {
        volumes = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cachesweep-volumes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: volumes)
    }

    func testCollectsNonEmptyTrashesAndSkipsSymlinksAndEmpties() throws {
        let fm = FileManager.default
        // A disk with trash in it.
        let full = volumes.appendingPathComponent("ssd/.Trashes/\(getuid())")
        try fm.createDirectory(at: full, withIntermediateDirectories: true)
        try Data(count: 10).write(to: full.appendingPathComponent("old.txt"))
        // A disk whose trash is empty.
        let empty = volumes.appendingPathComponent("backup/.Trashes/\(getuid())")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        // The boot volume's symlink.
        try fm.createSymbolicLink(atPath: volumes.appendingPathComponent("Macintosh HD").path,
                                  withDestinationPath: "/")

        let out = DeviceProfile.volumeTrashes(volumesDir: volumes.path)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.rawPaths, [full.path])
        XCTAssertEqual(out.first?.detail, "ssd")
        XCTAssertEqual(out.first?.safety, .safe, "it is already-deleted data")
        XCTAssertTrue(out.first?.externalScope == true,
                      "outside every scan root — the root filter must not hide it")
    }

    func testNoVolumesNoTarget() {
        XCTAssertTrue(DeviceProfile.volumeTrashes(volumesDir: volumes.path + "/none").isEmpty)
    }
}

/// The boomerang verdict: refilled-right-away caches are churn, not wins.
final class BoomerangTests: XCTestCase {

    func testRefillInsideTheWindowIsABoomerang() {
        let verdict = LearningStore.refillVerdict(
            freed: 1_000_000_000, measured: 700_000_000,
            cleanedAt: Date().addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(verdict, true)
    }

    func testPartialRefillKeepsWatching() {
        let verdict = LearningStore.refillVerdict(
            freed: 1_000_000_000, measured: 100_000_000,
            cleanedAt: Date().addingTimeInterval(-2 * 86_400))
        XCTAssertNil(verdict, "the window is still open — no verdict yet")
    }

    func testExpiredWindowMeansTheCleanStuck() {
        let verdict = LearningStore.refillVerdict(
            freed: 1_000_000_000, measured: 900_000_000,
            cleanedAt: Date().addingTimeInterval(-10 * 86_400))
        XCTAssertEqual(verdict, false,
                       "a slow refill is a working cache, not a boomerang")
    }
}
