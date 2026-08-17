import Foundation

/// Where the "missing" disk space lives: space no file scan can see because
/// it is not files on the Data volume. In an APFS container the Data volume
/// (the user's files) shares the disk with sibling volumes — VM (swap),
/// Preboot/Update (staged macOS updates), System/Recovery (the sealed OS) —
/// plus purgeable space macOS frees on demand. When the disk is full but the
/// cleanable categories don't add up to the gap, this report explains why.
struct InvisibleSpaceReport: Sendable {
    var containerTotal: UInt64 = 0   // APFS container capacity (the whole disk)
    var containerFree: UInt64 = 0    // unallocated space in the container
    var dataUsed: UInt64 = 0         // Data volume: the user's actual files
    var swapUsed: UInt64 = 0         // VM volume: swap files + sleepimage
    var bootUsed: UInt64 = 0         // Preboot + Update volumes
    var systemUsed: UInt64 = 0       // System + Recovery (sealed baseline)
    var purgeable: UInt64 = 0        // allocated space macOS frees on demand
    var osUpdateSnapshots = 0        // com.apple.os.update-* snapshots (not user-deletable)
    var pendingUpdate = false        // MSUPrepareUpdate present: staged, never-installed update

    /// Everything consumed outside the Data volume.
    var hiddenTotal: UInt64 { swapUsed + bootUsed + systemUsed }
}

enum InvisibleSpace {

    /// Assemble the full report. Returns nil when the boot container cannot
    /// be identified (diskutil unavailable or unparseable output).
    static func report() async -> InvisibleSpaceReport? {
        await Task.detached(priority: .utility) {
            guard let plist = run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
                  var r = parse(plist) else { return nil }
            let snaps = snapshotSummary(from: String(
                decoding: run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) ?? Data(),
                as: UTF8.self))
            r.osUpdateSnapshots = snaps.count
            r.pendingUpdate = snaps.pending
            r.purgeable = purgeableSpace()
            return r
        }.value
    }

    /// Pick the boot container out of `diskutil apfs list -plist` output and
    /// sum its volumes by role. The boot container is the one holding both a
    /// System-role and a Data-role volume — external disks and the iBoot
    /// container never have that pair.
    static func parse(_ plistData: Data) -> InvisibleSpaceReport? {
        guard let root = try? PropertyListSerialization
                .propertyList(from: plistData, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return nil }

        var best: InvisibleSpaceReport?
        for container in containers {
            guard let volumes = container["Volumes"] as? [[String: Any]] else { continue }
            var r = InvisibleSpaceReport()
            r.containerTotal = (container["CapacityCeiling"] as? NSNumber)?.uint64Value ?? 0
            r.containerFree = (container["CapacityFree"] as? NSNumber)?.uint64Value ?? 0
            var roles: Set<String> = []
            for volume in volumes {
                let used = (volume["CapacityInUse"] as? NSNumber)?.uint64Value ?? 0
                guard let role = (volume["Roles"] as? [String])?.first else { continue }
                roles.insert(role)
                switch role {
                case "Data":               r.dataUsed += used
                case "VM":                 r.swapUsed += used
                case "Preboot", "Update":  r.bootUsed += used
                case "System", "Recovery": r.systemUsed += used
                default: break
                }
            }
            guard roles.contains("Data"), roles.contains("System") else { continue }
            if r.containerTotal > (best?.containerTotal ?? 0) { best = r }
        }
        return best
    }

    /// Count sealed OS-update snapshots in `tmutil listlocalsnapshots` output
    /// and detect a staged-but-never-installed update (MSUPrepareUpdate).
    /// Time Machine snapshots are excluded — those are user-deletable and
    /// already handled by the system section.
    static func snapshotSummary(from output: String) -> (count: Int, pending: Bool) {
        let names = output.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("com.apple.os.update") }
        return (names.count, names.contains { $0.contains("MSUPrepareUpdate") })
    }

    /// Allocated-but-reclaimable space: the gap between what macOS reports as
    /// available "for important usage" (after purging) and what is free now.
    private static func purgeableSpace() -> UInt64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]), let plain = v.volumeAvailableCapacity,
            let important = v.volumeAvailableCapacityForImportantUsage else { return 0 }
        return UInt64(max(0, important - Int64(plain)))
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return data
    }
}
