import Foundation

/// Detects "ghost" data under /Volumes: directories that are NOT mount points
/// (same device as /Volumes itself, i.e. the internal Data volume) but still
/// hold files. This happens when a program keeps writing to /Volumes/<disk>
/// after the disk is ejected: the path silently becomes a plain folder on the
/// internal disk, and once the disk is remounted the data hides underneath
/// the mount, invisible to Finder and to every per-user cache scan.
///
/// Shared by the app (sizing, osascript fallback) and the root helper
/// (authoritative deletion), so the helper never accepts caller-supplied
/// paths: it recomputes the set itself from this same logic.
public enum OrphanVolumes {

    public static let root = "/Volumes"

    /// Non-mount-point directories under /Volumes that contain entries,
    /// plus unreadable ones (as a normal user that usually means root-owned
    /// leftovers; the helper can see inside and report the real size).
    public static func orphanDirectories() -> [String] {
        let fm = FileManager.default
        guard let rootDev = device(of: root) else { return [] }
        var found: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let path = root + "/" + name
            guard isOrphan(path, rootDev: rootDev) else { continue }
            if let children = try? fm.contentsOfDirectory(atPath: path) {
                if !children.isEmpty { found.append(path) }   // empty stubs are normal
            } else {
                found.append(path)                            // unreadable: let root decide
            }
        }
        return found.sorted()
    }

    /// Re-check immediately before deletion: still a plain directory on the
    /// same device as /Volumes, i.e. the disk has not been mounted meanwhile.
    /// Only accepts direct children of /Volumes.
    public static func isStillOrphan(_ path: String) -> Bool {
        guard path.hasPrefix(root + "/"),
              !path.dropFirst(root.count + 1).contains("/"),
              !path.hasSuffix("/"),
              let rootDev = device(of: root) else { return false }
        return isOrphan(path, rootDev: rootDev)
    }

    private static func isOrphan(_ path: String, rootDev: dev_t) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        // Symlinks ("Macintosh HD" -> /) and files are not orphans; a
        // different device means a real mounted volume.
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return st.st_dev == rootDev
    }

    private static func device(of path: String) -> dev_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_dev
    }
}
