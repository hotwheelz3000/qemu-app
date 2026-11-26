import CoreGraphics
import Foundation
import Combine

/// Runs the LiberNT virtual machine: checks the disk and JIT, starts QEMU, and
/// connects the screen.
final class VMController: ObservableObject {
    enum Phase: Equatable {
        case needsDisk
        case downloading(Double, String)
        case needsJIT
        case running
        case stopped(String)
    }

    @Published var phase: Phase = .needsDisk
    @Published var frame: CGImage?
    @Published var setupError: String?

    /// Settings (changed in Settings, used the next time the app opens).
    var ramMB: Int { Self.setting("ramMB", default: 3072) }
    var cores: Int { Self.setting("cores", default: 4) }

    static func setting(_ key: String, default value: Int) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? stored : value
    }

    let vnc = VNCClient()
    private var downloader: DiskDownloader?
    private var started = false
    private var framePending = false

    init() {
        refresh()
    }

    /// Picks the screen to show. Called at launch and whenever the app comes back.
    func refresh() {
        if started { return }
        if case .downloading = phase { return }
        if !VMFiles.diskExists {
            phase = .needsDisk
        } else if !JIT.isEnabled {
            phase = .needsJIT
        } else {
            start()
        }
    }

    private func start() {
        guard !started else { return }
        do {
            try VMFiles.prepareVars()
            let args = try QEMULauncher.arguments(disk: VMFiles.disk, vars: VMFiles.vars, serialLog: VMFiles.serialLog,
                                                  ramMB: ramMB, cores: cores)
            try QEMULauncher.start(arguments: args, log: VMFiles.qemuLog) { [weak self] status in
                DispatchQueue.main.async {
                    self?.vnc.stop()
                    self?.phase = .stopped(status == 0 ? "LiberNT shut down." : "QEMU stopped (code \(status)). See qemu-log.txt in Files › LiberNT.")
                }
            }
            started = true
            phase = .running
            vnc.onFrame = { [weak self] image in
                guard let self, !self.framePending else { return }
                self.framePending = true
                DispatchQueue.main.async {
                    self.frame = image
                    self.framePending = false
                }
            }
            vnc.start(port: QEMULauncher.vncPort)
        } catch {
            phase = .stopped(error.localizedDescription)
        }
    }

    // MARK: Disk

    func downloadDisk() {
        setupError = nil
        let downloader = DiskDownloader()
        self.downloader = downloader
        downloader.onProgress = { [weak self] fraction, text in
            DispatchQueue.main.async { self?.phase = .downloading(fraction, text) }
        }
        downloader.onFinish = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloader = nil
                if let error {
                    self.setupError = error.localizedDescription
                    self.phase = .needsDisk
                } else {
                    self.phase = .needsDisk
                    self.refresh()
                }
            }
        }
        downloader.start()
    }

    /// Copies a disk image the user picked in Files (raw .img or .qcow2).
    func importDisk(from url: URL) {
        setupError = nil
        phase = .downloading(0.5, "Copying disk…")
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let partial = VMFiles.disk.appendingPathExtension("part")
                try? FileManager.default.removeItem(at: partial)
                try FileManager.default.copyItem(at: url, to: partial)
                VMFiles.deleteDisk()
                try FileManager.default.moveItem(at: partial, to: VMFiles.disk)
                DispatchQueue.main.async {
                    self.phase = .needsDisk
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.setupError = error.localizedDescription
                    self.phase = .needsDisk
                }
            }
        }
    }

    // MARK: Controls

    func reset() { QEMULauncher.monitor("system_reset") }
    func powerButton() { QEMULauncher.monitor("system_powerdown") }
}
