import XCTest
@testable import Cachesweep

/// The guard stands between the scanner and every folder whose deletion costs
/// its owner a reinstall. A miss here is the bug that started it: the
/// `node_modules` of a project someone works in daily, listed green and
/// ticked for them.
final class ProjectGuardTests: XCTestCase {

    private var root: String = ""
    private let fm = FileManager()

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "pg-" + UUID().uuidString
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    // MARK: Fixtures

    /// A project folder with a manifest, an artifact and a chosen age.
    @discardableResult
    private func makeProject(_ name: String, manifest: String = "package.json",
                             artifact: String = "node_modules",
                             lockfile: String? = "package-lock.json",
                             sourceAgeDays: Int) throws -> String {
        let project = root + "/" + name
        try fm.createDirectory(atPath: project + "/" + artifact, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: project + "/src", withIntermediateDirectories: true)
        fm.createFile(atPath: project + "/" + manifest, contents: Data("{}".utf8))
        if let lockfile { fm.createFile(atPath: project + "/" + lockfile, contents: Data("{}".utf8)) }
        fm.createFile(atPath: project + "/src/index.js", contents: Data("x".utf8))
        fm.createFile(atPath: project + "/" + artifact + "/pkg", contents: Data("y".utf8))

        let old = Date().addingTimeInterval(-Double(sourceAgeDays) * 86_400)
        for path in [project, project + "/src", project + "/src/index.js",
                     project + "/" + manifest, project + "/" + (lockfile ?? manifest)] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        return project
    }

    /// Creating `ws/packages/ui` stamps `ws` with now. Anything building a
    /// nested fixture has to re-settle the ancestors afterwards.
    private func backdate(_ paths: [String], days: Int) throws {
        let old = Date().addingTimeInterval(-Double(days) * 86_400)
        for path in paths {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
    }

    private func guardUnder(_ days: Int = 30) -> ProjectGuard {
        ProjectGuard(idleThresholdDays: days)
    }

    // MARK: Liveness

    /// The bug, stated as a test. `node_modules` is stamped with the date of
    /// the last install, so on any project that installs once and is then
    /// worked on for months it reads as ancient — which is exactly when its
    /// owner least wants it deleted. Staleness has to come from the project.
    func testFreshProjectWithAncientArtifactIsRefused() throws {
        let project = try makeProject("hot", sourceAgeDays: 0)
        let artifact = project + "/node_modules"
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-300 * 86_400)],
                             ofItemAtPath: artifact)

        XCTAssertNil(guardUnder().evaluate(artifact: artifact, project: project),
                     "a project touched today must not be offered, whatever its node_modules says")
    }

    func testDormantProjectIsOffered() throws {
        let project = try makeProject("cold", sourceAgeDays: 120)
        let info = try XCTUnwrap(guardUnder().evaluate(artifact: project + "/node_modules",
                                                       project: project))
        XCTAssertGreaterThanOrEqual(info.idleDays, 119)
        XCTAssertEqual(info.restore, "npm install")
        XCTAssertTrue(info.reproducible)
    }

    /// A source file touched yesterday keeps the whole project alive even when
    /// the folder's own timestamp is old — the walk is the point.
    func testRecentSourceFileKeepsTheProjectAlive() throws {
        let project = try makeProject("editing", sourceAgeDays: 200)
        try fm.setAttributes([.modificationDate: Date()],
                             ofItemAtPath: project + "/src/index.js")
        XCTAssertNil(guardUnder().evaluate(artifact: project + "/node_modules", project: project))
    }

    /// `.git/index` moves on add, checkout and any status that refreshes stat
    /// data: the single best "someone is in here" signal a scanner can read
    /// without running git.
    func testGitIndexCountsAsActivity() throws {
        let project = try makeProject("gitwork", sourceAgeDays: 200)
        try fm.createDirectory(atPath: project + "/.git", withIntermediateDirectories: true)
        fm.createFile(atPath: project + "/.git/index", contents: Data("i".utf8))
        XCTAssertLessThan(ProjectGuard.computeIdleDays(project, fm: fm), 1)
    }

    /// The threshold is the user's, and raising it has to actually protect
    /// more projects.
    func testThresholdIsRespected() throws {
        let project = try makeProject("60days", sourceAgeDays: 60)
        XCTAssertNotNil(guardUnder(30).evaluate(artifact: project + "/node_modules", project: project))
        XCTAssertNil(guardUnder(180).evaluate(artifact: project + "/node_modules", project: project))
    }

    // MARK: Manifest ownership

    /// Name matching alone deletes a Go `vendor/`, which is checked-in source.
    /// Only a manifest that owns the folder makes it generated output.
    func testArtifactWithoutItsManifestIsRefused() throws {
        let project = root + "/goapp"
        try fm.createDirectory(atPath: project + "/vendor/pkg", withIntermediateDirectories: true)
        fm.createFile(atPath: project + "/go.mod", contents: Data("module x".utf8))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-400 * 86_400)],
                             ofItemAtPath: project)
        XCTAssertNil(guardUnder().evaluate(artifact: project + "/vendor", project: project),
                     "no composer.json, so this vendor/ is source, not output")
    }

    func testVendorWithComposerManifestIsOffered() throws {
        let project = try makeProject("phpapp", manifest: "composer.json", artifact: "vendor",
                                      lockfile: "composer.lock", sourceAgeDays: 120)
        let info = try XCTUnwrap(guardUnder().evaluate(artifact: project + "/vendor", project: project))
        XCTAssertEqual(info.restore, "composer install")
    }

    func testUnknownFolderNameIsRefused() throws {
        let project = try makeProject("misc", sourceAgeDays: 200)
        try fm.createDirectory(atPath: project + "/secrets", withIntermediateDirectories: true)
        XCTAssertNil(guardUnder().evaluate(artifact: project + "/secrets", project: project))
    }

    // MARK: Reproducibility

    /// Without a lockfile, reinstalling resolves whatever the registry serves
    /// today — a different tree, not the one that was deleted. Still offered,
    /// but it drops a tier and the row says so.
    func testMissingLockfileMarksTheTreeUnreproducible() throws {
        let project = try makeProject("nolock", lockfile: nil, sourceAgeDays: 120)
        let info = try XCTUnwrap(guardUnder().evaluate(artifact: project + "/node_modules",
                                                       project: project))
        XCTAssertFalse(info.reproducible)
    }

    /// Compiled output rebuilds from the source in the repo, so a lockfile has
    /// nothing to say about it.
    func testBuildOutputIsReproducibleWithoutALockfile() throws {
        let project = try makeProject("nextapp", artifact: ".next", lockfile: nil, sourceAgeDays: 120)
        let info = try XCTUnwrap(guardUnder().evaluate(artifact: project + "/.next", project: project))
        XCTAssertTrue(info.reproducible)
    }

    func testRestoreCommandFollowsTheLockfile() throws {
        let project = try makeProject("pnpmapp", lockfile: "pnpm-lock.yaml", sourceAgeDays: 120)
        let info = try XCTUnwrap(guardUnder().evaluate(artifact: project + "/node_modules",
                                                       project: project))
        XCTAssertEqual(info.restore, "pnpm install")
    }

    // MARK: Workspaces

    /// A monorepo package can sit untouched for a year while the repo around
    /// it ships daily — and pulling its `node_modules` breaks the workspace's
    /// symlink graph exactly as if it had been deleted from the root.
    func testPackageInsideALiveWorkspaceIsProtected() throws {
        let workspace = try makeProject("ws", sourceAgeDays: 0)
        let pkg = try makeProject("ws/packages/legacy", sourceAgeDays: 400)
        XCTAssertNil(guardUnder().evaluate(artifact: pkg + "/node_modules", project: pkg),
                     "the workspace was touched today, so nothing under it is dormant")
        XCTAssertTrue(FileManager().fileExists(atPath: workspace + "/package.json"))
    }

    /// And when the whole workspace really is dormant, every package answers
    /// to the same root, so they can be offered as one decision.
    func testDormantWorkspacePackagesShareARoot() throws {
        let workspace = try makeProject("cold-ws", sourceAgeDays: 300)
        let pkg = try makeProject("cold-ws/packages/ui", lockfile: nil, sourceAgeDays: 300)
        try backdate([workspace, workspace + "/packages"], days: 300)
        let a = try XCTUnwrap(guardUnder().evaluate(artifact: workspace + "/node_modules",
                                                    project: workspace))
        let b = try XCTUnwrap(guardUnder().evaluate(artifact: pkg + "/node_modules", project: pkg))
        XCTAssertEqual(a.root, workspace)
        XCTAssertEqual(b.root, workspace, "a package belongs to its workspace, not to itself")
    }

    /// A workspace pins its whole tree from one lockfile at the root. Looking
    /// only beside the package's own manifest marked every single package
    /// unreproducible and dropped it a tier.
    func testPackageInheritsTheWorkspaceLockfile() throws {
        let workspace = try makeProject("lock-ws", sourceAgeDays: 300)
        let pkg = try makeProject("lock-ws/packages/ui", lockfile: nil, sourceAgeDays: 300)
        try backdate([workspace, workspace + "/packages"], days: 300)
        let info = try XCTUnwrap(guardUnder().evaluate(artifact: pkg + "/node_modules", project: pkg))
        XCTAssertTrue(info.reproducible)
    }

    // MARK: git check-ignore

    /// The repo's own answer beats every heuristic: a committed artifact is
    /// somebody's source tree, whatever it is called.
    func testTrackedArtifactIsRefusedWhenGitSaysSo() throws {
        try XCTSkipIf(ProjectGuard.git == nil, "no usable git on this machine")
        let project = try makeProject("committed", sourceAgeDays: 120)
        try runGit(["init", "-q"], in: project)
        try backdateGit(project, days: 120)
        // No .gitignore at all: node_modules is tracked territory here.
        XCTAssertNil(guardUnder().evaluate(artifact: project + "/node_modules", project: project))
    }

    func testIgnoredArtifactPassesTheRepoCheck() throws {
        try XCTSkipIf(ProjectGuard.git == nil, "no usable git on this machine")
        let project = try makeProject("ignored", sourceAgeDays: 120)
        try runGit(["init", "-q"], in: project)
        fm.createFile(atPath: project + "/.gitignore", contents: Data("node_modules/\n".utf8))
        try backdateGit(project, days: 120)
        XCTAssertNotNil(guardUnder().evaluate(artifact: project + "/node_modules", project: project))
    }

    /// `git init` stamps `.git/HEAD` with now, and that is a liveness signal
    /// on purpose — so without this the two tests above would pass on the
    /// wrong rejection and never exercise `check-ignore` at all.
    private func backdateGit(_ project: String, days: Int) throws {
        let old = Date().addingTimeInterval(-Double(days) * 86_400)
        let en = fm.enumerator(atPath: project + "/.git")
        var paths = [project + "/.git", project]
        while let rel = en?.nextObject() as? String { paths.append(project + "/.git/" + rel) }
        for path in paths {
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
    }

    /// No repo means no answer, not a "no" — the manifest proof still stands.
    func testNonRepoProjectFallsBackToManifestProof() throws {
        let project = try makeProject("norepo", sourceAgeDays: 120)
        XCTAssertNotNil(guardUnder().evaluate(artifact: project + "/node_modules", project: project))
    }

    private func runGit(_ args: [String], in dir: String) throws {
        let git = try XCTUnwrap(ProjectGuard.git)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", dir] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }
}

/// The preselect rule is the last line of defence: whatever the scanner
/// decides, this is what actually ticks the box in front of the user.
final class PreselectionTests: XCTestCase {

    private func target(_ safety: Safety, learned: Bool = false,
                        inUse: Bool = false, boomerang: Bool = false) -> CleanTarget {
        CleanTarget(id: "t", name: "n", detail: "d", symbol: "s", rawPaths: ["/tmp/x"],
                    safety: safety, strategy: .directory, isDiscovered: true,
                    inUse: inUse, learned: learned, boomerang: boomerang)
    }

    func testPureCacheIsPreselected() {
        XCTAssertTrue(TargetState(target: target(.safe)).isSelected)
    }

    /// The regression this whole change exists for.
    func testRebuildableIsNeverPreselected() {
        XCTAssertFalse(TargetState(target: target(.rebuildable)).isSelected)
    }

    /// Cleaning a project's artifacts twice proves the user is willing to do
    /// it, not that they want it done for them.
    func testLearnedDoesNotPromoteARebuildable() {
        XCTAssertFalse(TargetState(target: target(.rebuildable, learned: true)).isSelected)
    }

    func testLearnedStillPromotesACautionCache() {
        XCTAssertTrue(TargetState(target: target(.caution, learned: true)).isSelected)
    }

    func testInUseIsNeverPreselected() {
        XCTAssertFalse(TargetState(target: target(.safe, inUse: true)).isSelected)
    }
}

/// `derived` used to be worth 0.7 safety on its own — one point over the gate,
/// which is how every manifest-derived folder in the app came out green.
final class DerivedSafetyTests: XCTestCase {

    func testRegenerableAloneNoLongerReachesSafe() {
        let v = Discovery.classify("/Users/x/proj/node_modules", derived: true, hasTag: false,
                                   designated: false, excludes: [], ageDays: 0,
                                   active: false, learnBoost: 0)
        XCTAssertNotEqual(v?.safety, .safe,
                          "regenerable is a claim about the folder, not about the user's time")
    }

    /// CACHEDIR.TAG is the tool itself saying "this is a cache" — that one
    /// still earns a preselected row.
    func testCacheDirTagStillClearsTheGate() {
        let v = Discovery.classify("/Users/x/proj/.cachedir", derived: true, hasTag: true,
                                   designated: false, excludes: [], ageDays: 30,
                                   active: false, learnBoost: 0)
        XCTAssertEqual(v?.safety, .safe)
    }
}


/// Two failures that only showed up against a real disk full of projects.
final class ProjectRowShapeTests: XCTestCase {

    /// The `-name package.json` query answers with one hit per *installed
    /// package* — hundreds of thousands of them. Capping the result before
    /// filtering spent the whole budget inside `node_modules` and dropped
    /// real project roots, so a workspace showed its packages and not itself.
    func testManifestsInsideArtifactsAreRecognised() {
        XCTAssertTrue(Discovery.insideArtifact("/p/node_modules/react/package.json"))
        XCTAssertTrue(Discovery.insideArtifact("/p/ios/Pods/Firebase/package.json"))
        XCTAssertTrue(Discovery.insideArtifact("/p/src-tauri/target/debug/Cargo.toml"))
        XCTAssertFalse(Discovery.insideArtifact("/p/packages/ui/package.json"))
        XCTAssertFalse(Discovery.insideArtifact("/p/package.json"))
    }

    /// One row can span a Rust `target`, an iOS `Pods` and a `node_modules`.
    /// Promising a single command there is picking one at random and calling
    /// it the answer.
    func testRestoreSummaryIsHonestAndStable() {
        XCTAssertNil(Discovery.restoreSummary([]))
        XCTAssertNil(Discovery.restoreSummary(["", ""]))
        XCTAssertEqual(Discovery.restoreSummary(["npm install", "npm install"]), "npm install")
        XCTAssertEqual(Discovery.restoreSummary(["pod install", "cargo build"]),
                       "cargo build + pod install", "sorted, so the row does not shuffle between scans")
        let three = Discovery.restoreSummary(["pod install", "cargo build", "npm install"])
        XCTAssertEqual(three, "cargo build + npm install …")
    }
}
