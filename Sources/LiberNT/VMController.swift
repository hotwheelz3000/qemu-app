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

    /// The machine this run uses (switching machines needs a restart: QEMU runs once per launch).
    let machine = Machine.current

    /// Settings (changed in Settings, used the next time the app opens).
    var ramMB: Int { Self.setting(Self.ramKey(machine), default: machine.defaultRAM) }
    var cores: Int { Self.setting("cores", default: 4) }

    static func ramKey(_ machine: Machine) -> String { "ramMB-\(machine.rawValue)" }

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
            if machine == .arm64 { try VMFiles.prepareVars() }
            let args = try QEMULauncher.arguments(machine: machine, disk: VMFiles.disk, vars: VMFiles.vars,
                                                  serialLog: VMFiles.serialLog, cd: CDStore.open(for: machine),
                                                  ramMB: ramMB, cores: cores)
            try QEMULauncher.start(machine: machine, arguments: args, log: VMFiles.qemuLog) { [weak self] status in
                DispatchQueue.main.async {
                    self?.vnc.stop()
                    self?.phase = .stopped(status == 0 ? "The machine shut down." : "QEMU stopped (code \(status)). See qemu-log.txt in Files › LiberNT.")
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

    /// Makes an empty disk (for installing from a CD), then starts.
    func createBlankDisk(gigabytes: Int) {
        setupError = nil
        do {
            try VMFiles.createBlankDisk(gigabytes: gigabytes)
            refresh()
        } catch {
            setupError = error.localizedDescription
        }
    }

    // MARK: CD

    @Published var cdName: String? = CDStore.name(for: Machine.current)

    /// Puts an ISO in the CD drive. If the machine is running, it's inserted right away.
    func insertCD(_ url: URL) {
        do {
            try CDStore.save(url, for: machine)
            cdName = CDStore.name(for: machine)
            if started, let open = CDStore.open(for: machine) {
                let path = open.path.replacingOccurrences(of: "\"", with: "\\\"")
                QEMULauncher.monitor("change cd0 \"\(path)\"")
            }
        } catch {
            setupError = error.localizedDescription
        }
    }

    func ejectCD() {
        CDStore.clear(for: machine)
        cdName = nil
        if started { QEMULauncher.monitor("eject -f cd0") }
    }

    /// Saves the machine choice and closes the app, since QEMU starts once per launch.
    func switchMachine(to newMachine: Machine) {
        Machine.current = newMachine
        if started { powerButton() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }

    // MARK: Controls

    func reset() { QEMULauncher.monitor("system_reset") }
    func powerButton() { QEMULauncher.monitor("system_powerdown") }
}
