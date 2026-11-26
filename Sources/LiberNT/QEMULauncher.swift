import Darwin
import Foundation

/// Starts QEMU in this process. QEMU comes from UTM's iOS build: the workflow copies
/// qemu-aarch64-softmmu.framework and its libraries into the app's Frameworks folder,
/// and the UEFI firmware and keymaps into the app's "qemu" folder.
enum QEMULauncher {
    typealias InitFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    typealias MainLoopFn = @convention(c) () -> Int32
    typealias CleanupFn = @convention(c) (Int32) -> Void

    static let vncPort: UInt16 = 5900
    static let monitorPort: UInt16 = 4444

    enum LaunchError: LocalizedError {
        case missing(String)
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .missing(let what): return "Missing from the app: \(what)"
            case .loadFailed(let why): return "QEMU didn't load: \(why)"
            }
        }
    }

    /// The QEMU command line for LiberNT on the ARM64 "virt" machine. Tested with
    /// LiberNT nt10.0-043-2555 (arm64): AAVMF firmware, NVMe disk and ramfb display
    /// boot to the desktop. virtio-blk stops with 0x7B and virtio-gpu stays blank.
    static func arguments(disk: URL, vars: URL, serialLog: URL, ramMB: Int, cores: Int) throws -> [String] {
        guard let qemuDir = Bundle.main.resourceURL?.appendingPathComponent("qemu"),
              FileManager.default.fileExists(atPath: qemuDir.appendingPathComponent("AAVMF_CODE.fd").path)
        else { throw LaunchError.missing("qemu/AAVMF_CODE.fd") }
        let code = qemuDir.appendingPathComponent("AAVMF_CODE.fd").path
        let format = diskFormat(disk)
        return [
            "qemu-system-aarch64",
            "-L", qemuDir.path,
            "-machine", "virt",
            "-cpu", "max",
            "-smp", "\(cores)",
            "-m", "\(ramMB)",
            // split-wx=on: on iOS 26+ UTM's QEMU maps the JIT buffer read/write, then asks
            // StikDebug (brk #0x69, legacy.js) for an executable copy. Without it QEMU
            // tries MAP_JIT, which iOS refuses ("Operation not permitted").
            "-accel", "tcg,thread=multi,tb-size=256,split-wx=on",
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(code)",
            "-drive", "if=pflash,format=raw,unit=1,file=\(vars.path)",
            "-drive", "if=none,id=hd0,format=\(format),file=\(disk.path)",
            "-device", "nvme,drive=hd0,serial=libernt",
            "-device", "ramfb",
            "-device", "qemu-xhci",
            "-device", "usb-tablet",
            "-device", "usb-kbd",
            "-vnc", "127.0.0.1:\(vncPort - 5900)",
            "-monitor", "tcp:127.0.0.1:\(monitorPort),server=on,wait=off",
            "-serial", "file:\(serialLog.path)",
        ]
    }

    /// "qcow2" when the file starts with QEMU's qcow magic, otherwise "raw".
    static func diskFormat(_ disk: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: disk) else { return "raw" }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0x51, 0x46, 0x49, 0xfb]) ? "qcow2" : "raw"
    }

    /// Loads QEMU and runs it on its own thread. QEMU reports bad arguments by
    /// exiting the process, so its messages go to qemu.log in the app's Documents.
    static func start(arguments: [String], log: URL, onExit: @escaping (Int32) -> Void) throws {
        guard let frameworks = Bundle.main.privateFrameworksURL else {
            throw LaunchError.missing("Frameworks folder")
        }
        let binary = frameworks.appendingPathComponent("qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw LaunchError.missing("qemu-aarch64-softmmu.framework")
        }
        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_GLOBAL) else {
            throw LaunchError.loadFailed(dlerror().map { String(cString: $0) } ?? "unknown error")
        }
        guard let initSym = dlsym(handle, "qemu_init"),
              let loopSym = dlsym(handle, "qemu_main_loop"),
              let cleanupSym = dlsym(handle, "qemu_cleanup")
        else { throw LaunchError.loadFailed("entry points not found") }

        let qemuInit = unsafeBitCast(initSym, to: InitFn.self)
        let qemuLoop = unsafeBitCast(loopSym, to: MainLoopFn.self)
        let qemuCleanup = unsafeBitCast(cleanupSym, to: CleanupFn.self)

        _ = freopen(log.path, "w", stderr)
        setvbuf(stderr, nil, _IONBF, 0)
        FileHandle.standardError.write(Data((arguments.joined(separator: " ") + "\n\n").utf8))

        let thread = Thread {
            // argv lives for the whole run; QEMU keeps pointers into it.
            var cArgs: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
            cArgs.append(nil)
            var env: [UnsafeMutablePointer<CChar>?] = [nil]
            cArgs.withUnsafeMutableBufferPointer { argv in
                env.withUnsafeMutableBufferPointer { envp in
                    qemuInit(Int32(arguments.count), argv.baseAddress, envp.baseAddress)
                }
            }
            let status = qemuLoop()
            qemuCleanup(status)
            onExit(status)
        }
        thread.name = "QEMU"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Sends one command to the QEMU monitor (for example "system_reset").
    static func monitor(_ command: String) {
        DispatchQueue.global().async {
            guard let socket = LoopbackSocket(port: monitorPort) else { return }
            usleep(200_000)
            socket.send(Data((command + "\n").utf8))
            usleep(200_000)
            socket.close()
        }
    }
}

/// JIT is on when a debugger (StikDebug) has attached: the CS_DEBUGGED code-signing flag.
@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ nbytes: Int) -> Int32

enum JIT {
    static var isEnabled: Bool {
        var flags: UInt32 = 0
        guard csops(getpid(), 0, &flags, MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & 0x1000_0000 != 0
    }
}
