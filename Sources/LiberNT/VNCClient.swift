import CoreGraphics
import Darwin
import Foundation

/// A blocking TCP connection to 127.0.0.1.
final class LoopbackSocket {
    private var fd: Int32
    private let writeLock = NSLock()

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            Darwin.close(fd)
            return nil
        }
    }

    /// Reads exactly `count` bytes into `buffer`. Returns false when the connection ends.
    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Bool {
        var done = 0
        while done < count {
            let got = recv(fd, buffer + done, count - done, 0)
            if got <= 0 { return false }
            done += got
        }
        return true
    }

    func read(_ count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return count == 0 }
            return read(into: base, count: count)
        }
        return ok ? data : nil
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var done = 0
            while done < data.count {
                let sent = Darwin.send(fd, base + done, data.count - done, 0)
                if sent <= 0 { return false }
                done += sent
            }
            return true
        }
    }

    func close() {
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// A small VNC (RFB 3.8) client for QEMU's built-in VNC server on 127.0.0.1.
/// Raw encoding only (it's all local), 32-bit BGRA pixels.
final class VNCClient {
    var onFrame: ((CGImage) -> Void)?
    var onDisconnect: (() -> Void)?

    private var socket: LoopbackSocket?
    private var width = 0
    private var height = 0
    private var pixels = [UInt8]()
    private var running = false

    var size: CGSize { CGSize(width: width, height: height) }

    /// Keeps trying to connect while QEMU starts, then runs the receive loop.
    func start(port: UInt16) {
        running = true
        let thread = Thread { [weak self] in
            while let self, self.running {
                if let sock = LoopbackSocket(port: port) {
                    self.socket = sock
                    if self.handshake(sock) {
                        self.receiveLoop(sock)
                    }
                    sock.close()
                    self.socket = nil
                    self.onDisconnect?()
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "VNC"
        thread.start()
    }

    func stop() {
        running = false
        socket?.close()
    }

    // MARK: Protocol

    private func handshake(_ sock: LoopbackSocket) -> Bool {
        guard let version = sock.read(12), version.starts(with: Data("RFB ".utf8)) else { return false }
        sock.send(Data("RFB 003.008\n".utf8))
        guard let countData = sock.read(1), let count = countData.first, count > 0,
              let types = sock.read(Int(count)), types.contains(1) else { return false }
        sock.send(Data([1]))
        guard let result = sock.read(4), result.allSatisfy({ $0 == 0 }) else { return false }
        sock.send(Data([1])) // ClientInit, shared

        guard let initData = sock.read(24) else { return false }
        width = Int(initData.u16(0))
        height = Int(initData.u16(2))
        let nameLength = Int(initData.u32(20))
        guard sock.read(nameLength) != nil else { return false }
        pixels = [UInt8](repeating: 0, count: width * height * 4)

        // SetPixelFormat: 32 bpp, depth 24, little endian, true colour, BGRA in memory.
        var format = Data([0, 0, 0, 0, 32, 24, 0, 1])
        format.append(be16(255)); format.append(be16(255)); format.append(be16(255))
        format.append(contentsOf: [16, 8, 0, 0, 0, 0])
        sock.send(format)

        // SetEncodings: raw (0), DesktopSize (-223).
        var encodings = Data([2, 0])
        encodings.append(be16(2))
        encodings.append(be32(0))
        encodings.append(be32(UInt32(bitPattern: -223)))
        sock.send(encodings)

        requestUpdate(incremental: false)
        return true
    }

    private func requestUpdate(incremental: Bool) {
        var msg = Data([3, incremental ? 1 : 0])
        msg.append(be16(0)); msg.append(be16(0))
        msg.append(be16(UInt16(width))); msg.append(be16(UInt16(height)))
        socket?.send(msg)
    }

    private func receiveLoop(_ sock: LoopbackSocket) {
        while running {
            guard let type = sock.read(1)?.first else { return }
            switch type {
            case 0:
                guard let header = sock.read(3) else { return }
                let rects = Int(header.u16(1))
                for _ in 0..<rects {
                    guard let r = sock.read(12) else { return }
                    let x = Int(r.u16(0)), y = Int(r.u16(2)), w = Int(r.u16(4)), h = Int(r.u16(6))
                    let encoding = Int32(bitPattern: r.u32(8))
                    if encoding == 0 {
                        guard readRaw(sock, x: x, y: y, w: w, h: h) else { return }
                    } else if encoding == -223 {
                        width = w
                        height = h
                        pixels = [UInt8](repeating: 0, count: w * h * 4)
                    } else {
                        return // unexpected encoding
                    }
                }
                publishFrame()
                requestUpdate(incremental: true)
            case 1:
                guard let head = sock.read(5) else { return }
                guard sock.read(Int(head.u16(3)) * 6) != nil else { return }
            case 2:
                continue
            case 3:
                guard let head = sock.read(7), sock.read(Int(head.u32(3))) != nil else { return }
            default:
                return
            }
        }
    }

    private func readRaw(_ sock: LoopbackSocket, x: Int, y: Int, w: Int, h: Int) -> Bool {
        guard w > 0, h > 0 else { return true }
        let rowBytes = w * 4
        if x == 0 && w == width && x + w <= width && y + h <= height {
            return pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return sock.read(into: base + y * width * 4, count: rowBytes * h)
            }
        }
        var row = [UInt8](repeating: 0, count: rowBytes)
        for line in 0..<h {
            let ok = row.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return sock.read(into: base, count: rowBytes)
            }
            guard ok else { return false }
            let destY = y + line
            guard destY < height, x < width else { continue }
            let copyBytes = min(rowBytes, (width - x) * 4)
            let start = (destY * width + x) * 4
            pixels.replaceSubrange(start..<(start + copyBytes), with: row[0..<copyBytes])
        }
        return true
    }

    private func publishFrame() {
        guard width > 0, height > 0 else { return }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        if let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            onFrame?(image)
        }
    }

    // MARK: Input

    /// Pointer position in framebuffer pixels. Mask bits: 1 left, 2 middle, 4 right, 8/16 wheel.
    func pointer(x: Int, y: Int, mask: UInt8) {
        var msg = Data([5, mask])
        msg.append(be16(UInt16(clamping: max(0, min(x, width - 1)))))
        msg.append(be16(UInt16(clamping: max(0, min(y, height - 1)))))
        socket?.send(msg)
    }

    func click(x: Int, y: Int, button: UInt8) {
        pointer(x: x, y: y, mask: 0)
        pointer(x: x, y: y, mask: button)
        pointer(x: x, y: y, mask: 0)
    }

    func scroll(x: Int, y: Int, up: Bool) {
        let wheel: UInt8 = up ? 8 : 16
        pointer(x: x, y: y, mask: wheel)
        pointer(x: x, y: y, mask: 0)
    }

    func key(_ keysym: UInt32, down: Bool) {
        var msg = Data([4, down ? 1 : 0, 0, 0])
        msg.append(be32(keysym))
        socket?.send(msg)
    }

    func tap(_ keysym: UInt32) {
        key(keysym, down: true)
        key(keysym, down: false)
    }

    /// Presses keys together, then releases them in reverse (for Ctrl+Alt+Del and the like).
    func chord(_ keysyms: [UInt32]) {
        keysyms.forEach { key($0, down: true) }
        keysyms.reversed().forEach { key($0, down: false) }
    }

    /// Types text from the iPhone keyboard (US layout keysyms).
    func type(_ text: String) {
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": tap(Keysym.enter)
            case "\t": tap(Keysym.tab)
            default:
                let value = scalar.value
                guard value >= 0x20 && value < 0x7f else { continue }
                if Keysym.needsShift(scalar) {
                    key(Keysym.shift, down: true)
                    tap(value)
                    key(Keysym.shift, down: false)
                } else {
                    tap(value)
                }
            }
        }
    }

    // MARK: Helpers

    private func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
    private func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]) }
}

enum Keysym {
    static let backspace: UInt32 = 0xff08
    static let tab: UInt32 = 0xff09
    static let enter: UInt32 = 0xff0d
    static let escape: UInt32 = 0xff1b
    static let delete: UInt32 = 0xffff
    static let shift: UInt32 = 0xffe1
    static let control: UInt32 = 0xffe3
    static let alt: UInt32 = 0xffe9
    static let windows: UInt32 = 0xffeb
    static let left: UInt32 = 0xff51
    static let up: UInt32 = 0xff52
    static let right: UInt32 = 0xff53
    static let down: UInt32 = 0xff54

    private static let shifted = Set("~!@#$%^&*()_+{}|:\"<>?".unicodeScalars)

    static func needsShift(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5a) || shifted.contains(scalar)
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func u32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
