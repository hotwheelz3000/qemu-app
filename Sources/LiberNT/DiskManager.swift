import Foundation

/// Where LiberNT's files live: On My iPhone > LiberNT.
enum VMFiles {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The disk. Raw or qcow2; QEMULauncher.diskFormat tells them apart.
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

enum DiskError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

/// Downloads LiberNT's disk as a qcow2 file (made by the "Publish LiberNT disk"
/// workflow) straight into place. QEMU reads qcow2 as is, so there's no unpacking.
final class DiskDownloader: NSObject, URLSessionDownloadDelegate {
    static let diskURL = URL(string: "https://github.com/hotwheelz3000/qemu-app/releases/download/disk-nt10.0-043-2555/LiberNT.qcow2")

    var onProgress: ((Double, String) -> Void)?
    var onFinish: ((Error?) -> Void)?

    private var finished = false

    func start() {
        guard let url = Self.diskURL else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        onProgress?(0, "Downloading…")
        session.downloadTask(with: url).resume()
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(fraction, "Downloading \(totalBytesWritten / 1_000_000) of \(totalBytesExpectedToWrite / 1_000_000) MB")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this returns, so move it now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw DiskError.message("Download failed (HTTP \(http.statusCode))")
            }
            VMFiles.deleteDisk()
            try FileManager.default.moveItem(at: location, to: VMFiles.disk)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error ?? (VMFiles.diskExists ? nil : DiskError.message("The download didn't finish. Try again.")))
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        onFinish?(error)
    }
}
