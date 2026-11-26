import Foundation

/// The two computers the app can run. Each has its own disk and CD.
enum Machine: String, CaseIterable, Identifiable {
    case arm64
    case x86

    var id: String { rawValue }

    /// The machine chosen in Settings (used when the app starts).
    static var current: Machine {
        get { Machine(rawValue: UserDefaults.standard.string(forKey: "machine") ?? "") ?? .arm64 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "machine") }
    }

    var title: String {
        switch self {
        case .arm64: return "ARM64 (LiberNT)"
        case .x86: return "x86 PC"
        }
    }

    var detail: String {
        switch self {
        case .arm64: return "LiberNT, ARM64 Linux and other ARM64 systems (UEFI)."
        case .x86: return "Older PC systems: ReactOS, Windows 95–XP, DOS, x86 Linux (BIOS)."
        }
    }

    var frameworkName: String {
        switch self {
        case .arm64: return "qemu-aarch64-softmmu"
        case .x86: return "qemu-x86_64-softmmu"
        }
    }

    var executableName: String {
        switch self {
        case .arm64: return "qemu-system-aarch64"
        case .x86: return "qemu-system-x86_64"
        }
    }

    var diskFileName: String {
        switch self {
        case .arm64: return "LiberNT.img"
        case .x86: return "PC.img"
        }
    }

    var defaultRAM: Int {
        switch self {
        case .arm64: return 3072
        case .x86: return 1024
        }
    }
}

/// The CD for each machine: a bookmark to an ISO the user picked in Files. The ISO
/// stays where it is (no copy), and QEMU reads it through the bookmark.
enum CDStore {
    private static func key(_ machine: Machine) -> String { "cd-\(machine.rawValue)" }

    static func save(_ url: URL, for machine: Machine) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData()
        UserDefaults.standard.set(data, forKey: key(machine))
    }

    static func clear(for machine: Machine) {
        UserDefaults.standard.removeObject(forKey: key(machine))
    }

    static func name(for machine: Machine) -> String? {
        guard let data = UserDefaults.standard.data(forKey: key(machine)) else { return nil }
        var stale = false
        return (try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale))?.lastPathComponent
    }

    /// Resolves the ISO and keeps access open for as long as the app runs.
    static func open(for machine: Machine) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key(machine)) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale { try? save(url, for: machine) }
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }
}
