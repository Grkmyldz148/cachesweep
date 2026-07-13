import XCTest
import CachesweepCore
@testable import Cachesweep

final class BucketsTests: XCTestCase {
    func testKnownRootWins() {
        let roots = [(path: "/Users/x/.npm", name: "npm", symbol: "s")]
        let b = Buckets.classify("/Users/x/.npm/_cacache/foo", knownRoots: roots)
        XCTAssertEqual(b?.path, "/Users/x/.npm")
        XCTAssertEqual(b?.isKnown, true)
    }

    func testMarkerDiscoveryFindsCacheAncestor() {
        let b = Buckets.classify("/Users/x/proj/node_modules/pkg/index.js", knownRoots: [])
        XCTAssertEqual(b?.path, "/Users/x/proj/node_modules")
        XCTAssertEqual(b?.isKnown, false)
    }

    func testNonCachePathIsIgnored() {
        XCTAssertNil(Buckets.classify("/Users/x/Documents/report.pdf", knownRoots: []))
    }

    func testShortLabelAbbreviatesHome() {
        let home = NSHomeDirectory()
        XCTAssertEqual(Buckets.shortLabel(home + "/foo/bar"), "~/foo/bar")
        XCTAssertEqual(Buckets.shortLabel("/Volumes/x/foo"), "/Volumes/x/foo")
    }
}

final class CleanTargetTests: XCTestCase {
    func testSeedIDsAreUnique() {
        let ids = CleanTarget.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate seed ids")
    }

    func testSeedPathsDoNotOverlap() {
        // A seed nested inside another seed would double-count bytes.
        let paths = CleanTarget.all.flatMap(\.expandedPaths)
        for a in paths {
            for b in paths where a != b {
                XCTAssertFalse(a.hasPrefix(b + "/"), "\(a) is nested inside \(b)")
            }
        }
    }

    func testTildeExpansion() {
        let t = CleanTarget(id: "t", name: "n", detail: "d", symbol: "s",
                            rawPaths: ["~/x"], safety: .safe, strategy: .directory)
        XCTAssertEqual(t.expandedPaths, [NSHomeDirectory() + "/x"])
    }
}

final class RootCleanerTests: XCTestCase {
    func testAllowlistIsAbsoluteAndAdminGated() {
        XCTAssertFalse(RootCleaner.targets.isEmpty)
        for t in RootCleaner.targets {
            XCTAssertTrue(t.needsAdmin, "\(t.id) must be admin-gated")
            XCTAssertEqual(t.safety, .caution, "\(t.id) must be opt-in")
            for p in t.rawPaths {
                XCTAssertTrue(p.hasPrefix("/"), "\(p) must be absolute")
                XCTAssertFalse(p.contains(".."), "\(p) must not traverse")
                XCTAssertFalse(p.contains("'"), "\(p) would break shell quoting")
            }
        }
    }

    func testAllowlistNeverTouchesUserHome() {
        let home = NSHomeDirectory()
        for t in RootCleaner.targets {
            for p in t.rawPaths {
                XCTAssertFalse(p.hasPrefix(home), "system allowlist must not include \(p)")
            }
        }
    }
}

final class OrphanVolumesTests: XCTestCase {
    func testMountedVolumesAreNeverOrphans() {
        // Anything currently mounted must never be offered for deletion.
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []) ?? []
        let orphans = Set(OrphanVolumes.orphanDirectories())
        for url in mounted {
            XCTAssertFalse(orphans.contains(url.path), "\(url.path) is mounted")
        }
    }

    func testOrphansAreDirectChildrenOfVolumes() {
        for p in OrphanVolumes.orphanDirectories() {
            XCTAssertTrue(p.hasPrefix("/Volumes/"), p)
            XCTAssertFalse(p.dropFirst("/Volumes/".count).contains("/"), p)
        }
    }

    func testIsStillOrphanRejectsForeignPaths() {
        XCTAssertFalse(OrphanVolumes.isStillOrphan("/tmp"))
        XCTAssertFalse(OrphanVolumes.isStillOrphan("/Volumes"))
        XCTAssertFalse(OrphanVolumes.isStillOrphan("/Volumes/a/b"))
        XCTAssertFalse(OrphanVolumes.isStillOrphan(NSHomeDirectory()))
    }
}

final class LearningSignatureTests: XCTestCase {
    func testSignatureIsLowercasedLeaf() {
        XCTAssertEqual(LearningStore.signature(forPath: "/a/b/Node_Modules"), "node_modules")
        XCTAssertEqual(LearningStore.signature(forPath: "/x/DerivedData"), "deriveddata")
    }
}
