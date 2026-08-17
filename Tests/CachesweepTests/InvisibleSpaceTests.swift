import XCTest
@testable import Cachesweep

final class InvisibleSpaceTests: XCTestCase {

    /// Two containers: an external disk (no System+Data pair, must be
    /// ignored) and a boot container with one volume per role.
    private static let samplePlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Containers</key>
      <array>
        <dict>
          <key>CapacityCeiling</key><integer>500107821056</integer>
          <key>CapacityFree</key><integer>216982216704</integer>
          <key>Volumes</key>
          <array>
            <dict>
              <key>CapacityInUse</key><integer>282964746240</integer>
              <key>Roles</key><array/>
            </dict>
          </array>
        </dict>
        <dict>
          <key>CapacityCeiling</key><integer>245107195904</integer>
          <key>CapacityFree</key><integer>9275871232</integer>
          <key>Volumes</key>
          <array>
            <dict>
              <key>CapacityInUse</key><integer>13507796992</integer>
              <key>Roles</key><array><string>System</string></array>
            </dict>
            <dict>
              <key>CapacityInUse</key><integer>17939181568</integer>
              <key>Roles</key><array><string>Preboot</string></array>
            </dict>
            <dict>
              <key>CapacityInUse</key><integer>2608046080</integer>
              <key>Roles</key><array><string>Recovery</string></array>
            </dict>
            <dict>
              <key>CapacityInUse</key><integer>801812480</integer>
              <key>Roles</key><array><string>Update</string></array>
            </dict>
            <dict>
              <key>CapacityInUse</key><integer>177174085632</integer>
              <key>Roles</key><array><string>Data</string></array>
            </dict>
            <dict>
              <key>CapacityInUse</key><integer>23663112192</integer>
              <key>Roles</key><array><string>VM</string></array>
            </dict>
          </array>
        </dict>
      </array>
    </dict>
    </plist>
    """

    func testParsePicksBootContainerAndSumsRoles() throws {
        let r = try XCTUnwrap(InvisibleSpace.parse(Data(Self.samplePlist.utf8)))
        XCTAssertEqual(r.containerTotal, 245_107_195_904)
        XCTAssertEqual(r.containerFree, 9_275_871_232)
        XCTAssertEqual(r.dataUsed, 177_174_085_632)
        XCTAssertEqual(r.swapUsed, 23_663_112_192)
        XCTAssertEqual(r.bootUsed, 17_939_181_568 + 801_812_480)
        XCTAssertEqual(r.systemUsed, 13_507_796_992 + 2_608_046_080)
        XCTAssertEqual(r.hiddenTotal, r.swapUsed + r.bootUsed + r.systemUsed)
    }

    func testParseIgnoresExternalOnlyContainers() {
        // Strip the boot container: no container qualifies, parse must fail
        // rather than report the external disk.
        let externalOnly = Self.samplePlist.replacingOccurrences(of: "System", with: "Sys?")
        XCTAssertNil(InvisibleSpace.parse(Data(externalOnly.utf8)))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(InvisibleSpace.parse(Data("not a plist".utf8)))
        XCTAssertNil(InvisibleSpace.parse(Data()))
    }

    func testSnapshotSummaryCountsOSUpdateOnly() {
        let out = """
        Snapshots for volume group containing disk /:
        com.apple.os.update-C3A34363
        com.apple.os.update-E6650886
        com.apple.TimeMachine.2026-07-17-120000.local
        """
        let s = InvisibleSpace.snapshotSummary(from: out)
        XCTAssertEqual(s.count, 2)
        XCTAssertFalse(s.pending)
    }

    func testSnapshotSummaryDetectsStagedUpdate() {
        let out = """
        com.apple.os.update-E6650886
        com.apple.os.update-MSUPrepareUpdate
        """
        let s = InvisibleSpace.snapshotSummary(from: out)
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s.pending)
    }

    func testSnapshotSummaryEmptyOutput() {
        let s = InvisibleSpace.snapshotSummary(from: "")
        XCTAssertEqual(s.count, 0)
        XCTAssertFalse(s.pending)
    }
}
