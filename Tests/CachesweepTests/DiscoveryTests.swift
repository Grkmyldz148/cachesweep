import XCTest
@testable import Cachesweep

/// The scoring gate decides what the app is even allowed to offer, so a
/// silent miss here shows up as "the cleaner found nothing".
final class DiscoveryClassifierTests: XCTestCase {

    private func classify(_ path: String, designated: Bool = false, derived: Bool = false,
                          hasTag: Bool = false, excludes: [String] = [],
                          ageDays: Int? = 30, active: Bool = false,
                          learnBoost: Double = 0) -> Discovery.Verdict? {
        Discovery.classify(path, derived: derived, hasTag: hasTag, designated: designated,
                           excludes: excludes, ageDays: ageDays, active: active,
                           learnBoost: learnBoost)
    }

    /// Regression: a folder in a location macOS designates as a cache used to
    /// score 0.6 against a 0.7 gate, so every one of the ~100 folders under
    /// ~/Library/Caches was dropped — several GB, the most reliable source of
    /// cleanable bytes on any Mac, invisible in full.
    func testDesignatedCacheLocationClearsTheGate() {
        let v = classify("/Users/x/Library/Caches/Google", designated: true)
        XCTAssertNotNil(v, "~/Library/Caches entries must be offered")
        XCTAssertEqual(v?.safety, .safe, "a stale cache folder is safe to preselect")
    }

    func testDesignatedCacheInUseIsNotPreselected() {
        let v = classify("/Users/x/Library/Caches/Google", designated: true, active: true)
        XCTAssertEqual(v?.safety, .caution, "something being written must stay opt-in")
    }

    func testFreshDesignatedCacheIsNotPreselected() {
        let v = classify("/Users/x/Library/Caches/Google", designated: true, ageDays: 0)
        XCTAssertEqual(v?.safety, .caution)
    }

    func testOrdinaryFolderIsStillRejected() {
        XCTAssertNil(classify("/Users/x/Documents/Taxes 2024", ageDays: 900),
                     "a plain folder must never be offered")
    }

    func testExclusionsWinOverEverySignal() {
        XCTAssertNil(classify("/Users/x/Library/Caches/Google", designated: true,
                              hasTag: true, excludes: ["/Users/x/Library/Caches"]))
    }
}

final class StaleInstallerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cachesweep-installers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `totalFileAllocatedSize` counts real blocks, so the fixture has to be
    /// written, not truncated — a sparse file allocates nothing.
    private func write(_ name: String, bytes: Int, ageDays: Int) throws {
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        let modified = Date().addingTimeInterval(-Double(ageDays) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: url.path)
    }

    func testCollectsOldLargeInstallers() throws {
        try write("Xcode.dmg", bytes: 40_000, ageDays: 90)
        try write("game.pkg", bytes: 40_000, ageDays: 45)

        let t = Discovery.staleInstallers(in: dir.path, excludes: [], minBytes: 20_000)
        XCTAssertEqual(t?.rawPaths.count, 2)
        XCTAssertEqual(t?.safety, .caution, "real downloads must never be preselected")
        XCTAssertEqual(t?.category, .other)
        XCTAssertEqual(t?.ageDays, 90, "the oldest file drives the staleness badge")
    }

    func testSkipsRecentSmallAndNonInstallerFiles() throws {
        try write("fresh.dmg", bytes: 40_000, ageDays: 2)     // too new
        try write("tiny.pkg", bytes: 100, ageDays: 400)       // too small
        try write("notes.txt", bytes: 40_000, ageDays: 400)   // not an installer

        XCTAssertNil(Discovery.staleInstallers(in: dir.path, excludes: [], minBytes: 20_000))
    }

    func testHonoursExclusions() throws {
        try write("old.dmg", bytes: 40_000, ageDays: 90)
        XCTAssertNil(Discovery.staleInstallers(in: dir.path, excludes: [dir.path],
                                               minBytes: 20_000))
    }
}

final class SimulatorRuntimeTests: XCTestCase {

    private let sample: [String: Any] = [
        "B20E049B": [
            "identifier": "B20E049B",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-3",
            "version": "18.3.1",
            "sizeBytes": NSNumber(value: 8_708_125_252 as UInt64),
            "deletable": true,
        ],
        "PINNED": [
            "identifier": "PINNED",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0",
            "version": "17.0",
            "sizeBytes": NSNumber(value: 6_000_000_000 as UInt64),
            "deletable": false,          // bundled with Xcode — not ours to remove
        ],
    ]

    func testParsesOnlyDeletableRuntimes() {
        let runtimes = SimulatorRuntimes.parse(sample)
        XCTAssertEqual(runtimes.map(\.id), ["B20E049B"])
        XCTAssertEqual(runtimes.first?.size, 8_708_125_252)
        XCTAssertEqual(runtimes.first?.label, "iOS 18.3.1")
    }

    func testLabelFallsBackWithoutAVersion() {
        XCTAssertEqual(
            SimulatorRuntimes.label(version: nil,
                                    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"),
            "watchOS")
        XCTAssertEqual(SimulatorRuntimes.label(version: "1.0", runtimeIdentifier: ""), "Simulator 1.0")
    }

    /// The bytes live in system asset storage, so the target carries no paths
    /// of its own: it must be opt-in, sized from simctl, and immune to the
    /// scan-root filter that would otherwise hide it.
    func testTargetIsPathlessOptInAndExternallyScoped() {
        let r = SimulatorRuntimes.parse(sample)[0]
        let t = SimulatorRuntimes.target(for: r)
        XCTAssertTrue(t.rawPaths.isEmpty)
        XCTAssertTrue(t.externalScope)
        XCTAssertEqual(t.knownSize, r.size)
        XCTAssertEqual(t.safety, .caution)
        guard case .simulatorRuntime(let id) = t.strategy else {
            return XCTFail("must clean through simctl, never rm")
        }
        XCTAssertEqual(id, r.id)
    }
}

final class DarwinUserCacheTests: XCTestCase {

    func testSeedTargetsTheDarwinCacheOutsideHome() throws {
        let seed = try XCTUnwrap(CleanTarget.all.first { $0.id == "darwin-cache" })
        XCTAssertTrue(seed.externalScope, "it is outside the home folder by definition")
        let path = try XCTUnwrap(seed.expandedPaths.first)
        XCTAssertTrue(path.hasSuffix("/C"), path)
        XCTAssertTrue(path.contains("/var/folders/"), path)
        XCTAssertFalse(path.hasPrefix(NSHomeDirectory()), path)
    }
}
