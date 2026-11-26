import Darwin
import Foundation

/// Starts QEMU in this process. QEMU comes from UTM's iOS build: the workflow copies
/// qemu-aarch64-softmmu and qemu-x86_64-softmmu (and their libraries) into the app's
/// Frameworks folder, and the firmware, ROMs and keymaps into the app's "qemu" folder.
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

    /// The QEMU command line for the chosen machine.
    ///
    /// ARM64 (LiberNT): tested with LiberNT nt10.0-043-2555 (arm64): AAVMF firmware,
    /// NVMe disk and ramfb display boot to the desktop (virtio-blk stops with 0x7B,
    /// virtio-gpu stays blank). The CD drive is on an AHCI controller; LiberNT still
    /// boots with it present. Boot order: CD first (when one is inserted), then disk.
    ///
    /// x86 PC: the classic i440FX PC with SeaBIOS, IDE disk and CD, standard VGA and
    /// an e1000 network card, which the widest range of older and newer systems know.
    static func arguments(machine: Machine, disk: URL, vars: URL, serialLog: URL, cd: URL?,
                          ramMB: Int, cores: Int) throws -> [String] {
        guard let qemuDir = Bundle.main.resourceURL?.appendingPathComponent("qemu") else {
            throw LaunchError.missing("qemu folder")
        }
        let format = diskFormat(disk)
        var args = [
            machine.executableName,
            "-L", qemuDir.path,
            "-smp", "\(cores)",
            "-m", "\(ramMB)",
            // split-wx=on: on iOS 26+ UTM's QEMU maps the JIT buffer read/write, then asks
            // StikDebug (brk #0x69, legacy.js) for an executable copy. Without it QEMU
            // tries MAP_JIT, which iOS refuses ("Operation not permitted").
            "-accel", "tcg,thread=multi,tb-size=256,split-wx=on",
        ]
        let cdFile = cd.map { ",file=\(escape($0.path))" } ?? ""

        switch machine {
        case .arm64:
            let code = qemuDir.appendingPathComponent("AAVMF_CODE.fd").path
            guard FileManager.default.fileExists(atPath: code) else { throw LaunchError.missing("qemu/AAVMF_CODE.fd") }
            args += [
                "-machine", "virt",
                "-cpu", "max",
                "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(code)",
                "-drive", "if=pflash,format=raw,unit=1,file=\(vars.path)",
                "-drive", "if=none,id=hd0,format=\(format),file=\(escape(disk.path))",
                "-device", "nvme,drive=hd0,serial=libernt,bootindex=1",
                "-device", "ich9-ahci,id=ahci",
                "-drive", "if=none,id=cd0,media=cdrom,readonly=on\(cdFile)",
                "-device", "ide-cd,drive=cd0,bus=ahci.0,bootindex=0",
                "-device", "ramfb",
                "-device", "qemu-xhci",
                "-device", "usb-tablet",
                "-device", "usb-kbd",
            ]
        case .x86:
            args += [
                "-machine", "pc",
                "-cpu", "max",
                "-drive", "if=ide,index=0,id=hd0,format=\(format),file=\(escape(disk.path))",
                "-drive", "if=ide,index=2,id=cd0,media=cdrom,readonly=on\(cdFile)",
                "-boot", "order=dc,menu=on",
                "-vga", "std",
                "-usb",
                "-device", "usb-tablet",
                "-nic", "user,model=e1000",
            ]
        }
        args += [
            "-vnc", "127.0.0.1:\(vncPort - 5900)",
            "-monitor", "tcp:127.0.0.1:\(monitorPort),server=on,wait=off",
            "-serial", "file:\(serialLog.path)",
        ]
        return args
    }

    /// QEMU option values use "," as a separator, so a comma in a file name is doubled.
    private static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: ",", with: ",,")
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
    static func start(machine: Machine, arguments: [String], log: URL, onExit: @escaping (Int32) -> Void) throws {
        guard let frameworks = Bundle.main.privateFrameworksURL else {
            throw LaunchError.missing("Frameworks folder")
        }
        let name = machine.frameworkName
        let binary = frameworks.appendingPathComponent("\(name).framework/\(name)")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw LaunchError.missing("\(name).framework")
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
