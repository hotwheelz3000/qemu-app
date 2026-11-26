import Compression
import Foundation

/// Where LiberNT's files live: On My iPhone > LiberNT.
enum VMFiles {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
    }

    static var disk: URL { folder.appendingPathComponent("LiberNT.img") }
    static var vars: URL { folder.appendingPathComponent("efi-vars.fd") }
    static var serialLog: URL { folder.appendingPathComponent("boot-log.txt") }
    static var qemuLog: URL { folder.appendingPathComponent("qemu-log.txt") }

    static var diskExists: Bool { FileManager.default.fileExists(atPath: disk.path) }

    /// The UEFI settings file starts as a copy of the template in the app.
    static func prepareVars() throws {
        guard !FileManager.default.fileExists(atPath: vars.path) else { return }
        guard let template = Bundle.main.resourceURL?.appendingPathComponent("qemu/AAVMF_VARS.fd") else {
            throw QEMULauncher.LaunchError.missing("qemu/AAVMF_VARS.fd")
        }
        try FileManager.default.copyItem(at: template, to: vars)
    }

    static func deleteDisk() {
        try? FileManager.default.removeItem(at: disk)
        try? FileManager.default.removeItem(at: vars)
    }
}

/// Downloads LiberNT's arm64 preinstalled disk from its GitHub release and unzips it.
final class DiskDownloader: NSObject, URLSessionDownloadDelegate {
    static let releaseURL = URL(string: "https://github.com/LiberNT/LiberNT/releases/download/nt10.0-043-2555-g8e478a22a1e/LiberNT-img-clang-arm64-Debug-target0xA00-8e478a22a1e.zip")

    var onProgress: ((Double, String) -> Void)?
    var onFinish: ((Error?) -> Void)?

    private var session: URLSession?

    func start() {
        guard let url = Self.releaseURL else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        onProgress?(0, "Downloading…")
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mb = totalBytesWritten / 1_000_000
        let total = totalBytesExpectedToWrite / 1_000_000
        onProgress?(fraction * 0.6, "Downloading \(mb) of \(total) MB")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this returns, so move it first.
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("libernt.zip")
        try? FileManager.default.removeItem(at: zip)
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw ZipError.message("Download failed (HTTP \(http.statusCode))")
            }
            try FileManager.default.moveItem(at: location, to: zip)
        } catch {
            onFinish?(error)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let partial = VMFiles.disk.appendingPathExtension("part")
                try ZipExtractor.extractFirstFile(from: zip, to: partial) { fraction in
                    self.onProgress?(0.6 + fraction * 0.4, "Unpacking disk…")
                }
                try? FileManager.default.removeItem(at: VMFiles.disk)
                try FileManager.default.moveItem(at: partial, to: VMFiles.disk)
                try? FileManager.default.removeItem(at: zip)
                self.onFinish?(nil)
            } catch {
                try? FileManager.default.removeItem(at: zip)
                self.onFinish?(error)
            }
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onFinish?(error)
            session.finishTasksAndInvalidate()
        }
    }
}

enum ZipError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// Unzips the first file of a zip archive (stored or deflated), streaming to disk.
enum ZipExtractor {
    static func extractFirstFile(from zip: URL, to destination: URL, progress: (Double) -> Void) throws {
        let input = try FileHandle(forReadingFrom: zip)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()

        // End of central directory record, in the last 64 KB.
        let tailLength = min(fileSize, 65_557)
        try input.seek(toOffset: fileSize - tailLength)
        guard let tail = try input.read(upToCount: Int(tailLength)) else { throw ZipError.message("Can't read the zip") }
        let tailBytes = [UInt8](tail)
        guard let eocd = stride(from: tailBytes.count - 22, through: 0, by: -1).first(where: {
            tailBytes[$0] == 0x50 && tailBytes[$0 + 1] == 0x4b && tailBytes[$0 + 2] == 0x05 && tailBytes[$0 + 3] == 0x06
        }) else { throw ZipError.message("Not a zip file") }
        let centralOffset = UInt64(le32(tailBytes, eocd + 16))

        try input.seek(toOffset: centralOffset)
        guard let centralData = try input.read(upToCount: 46) else { throw ZipError.message("Bad zip") }
        let central = [UInt8](centralData)
        guard le32(central, 0) == 0x0201_4b50 else { throw ZipError.message("Bad zip directory") }
        let method = le16(central, 10)
        let compressedSize = UInt64(le32(central, 20))
        let uncompressedSize = UInt64(le32(central, 24))
        let localOffset = UInt64(le32(central, 42))

        try input.seek(toOffset: localOffset)
        guard let localData = try input.read(upToCount: 30) else { throw ZipError.message("Bad zip") }
        let local = [UInt8](localData)
        guard le32(local, 0) == 0x0403_4b50 else { throw ZipError.message("Bad zip entry") }
        let dataStart = localOffset + 30 + UInt64(le16(local, 26)) + UInt64(le16(local, 28))
        try input.seek(toOffset: dataStart)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let chunk = 4 << 20
        var remaining = compressedSize

        if method == 0 {
            while remaining > 0 {
                guard let data = try input.read(upToCount: Int(min(UInt64(chunk), remaining))), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                remaining -= UInt64(data.count)
                progress(1 - Double(remaining) / Double(max(compressedSize, 1)))
            }
            return
        }
        guard method == 8 else { throw ZipError.message("Unsupported zip compression (\(method))") }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.message("Can't start unzip")
        }
        defer { compression_stream_destroy(streamPointer) }

        let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { outBuffer.deallocate() }
        var written: UInt64 = 0
        var finished = false

        while !finished {
            let inData = remaining > 0 ? (try input.read(upToCount: Int(min(UInt64(chunk), remaining))) ?? Data()) : Data()
            remaining -= UInt64(inData.count)
            let isLast = remaining == 0
            try inData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var stream = streamPointer.pointee
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(outBuffer)
                stream.src_size = inData.count
                repeat {
                    stream.dst_ptr = outBuffer
                    stream.dst_size = chunk
                    let status = compression_stream_process(&stream, isLast ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = chunk - stream.dst_size
                    if produced > 0 {
                        try output.write(contentsOf: Data(bytesNoCopy: outBuffer, count: produced, deallocator: .none))
                        written += UInt64(produced)
                    }
                    if status == COMPRESSION_STATUS_END {
                        finished = true
                        break
                    }
                    if status == COMPRESSION_STATUS_ERROR { throw ZipError.message("The disk download is damaged") }
                } while stream.src_size > 0 || stream.dst_size == 0
                streamPointer.pointee = stream
            }
            if uncompressedSize > 0 { progress(min(1, Double(written) / Double(uncompressedSize))) }
            if isLast && inData.isEmpty && !finished { throw ZipError.message("The disk download is incomplete") }
        }
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
