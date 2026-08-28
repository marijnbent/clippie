import Foundation
import OSLog

/// Writes low-overhead, content-free measurements for later performance review.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    static let enabledDefaultsKey = "diagnosticsEnabled"

    private static let maximumLogSize = 2_000_000

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Clippie",
        category: "Diagnostics"
    )
    private let queue = DispatchQueue(label: "com.clippie.diagnostics-log", qos: .utility)
    private let enabledLock = NSLock()
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var logSize = 0
    private var fileHandle: FileHandle?
    private var enabled: Bool
    let fileURL: URL

    var isEnabled: Bool {
        enabledLock.lock()
        defer { enabledLock.unlock() }
        return enabled
    }

    private init() {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("clippie", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clippie", isDirectory: true)

        fileURL = directory.appendingPathComponent("Diagnostics.log")
        enabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)

        if enabled {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded()
            logSize = Self.fileSize(at: fileURL)
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        enabledLock.lock()
        enabled = isEnabled
        enabledLock.unlock()

        queue.async {
            if isEnabled {
                Self.createLogFileIfNeeded(at: self.fileURL)
                self.rotateIfNeeded()
                self.logSize = Self.fileSize(at: self.fileURL)
            } else {
                try? self.fileHandle?.close()
                self.fileHandle = nil
            }
        }
    }

    func benchmark(
        _ name: String,
        durationMilliseconds: @autoclosure () -> Double,
        details: @autoclosure () -> String = ""
    ) {
        guard isEnabled else { return }
        let suffix = details()
        let detailText = suffix.isEmpty ? "" : " \(suffix)"
        info("benchmark.\(name) duration_ms=\(Self.format(durationMilliseconds()))\(detailText)")
    }

    func event(_ name: String, details: @autoclosure () -> String = "") {
        guard isEnabled else { return }
        let suffix = details()
        let detailText = suffix.isEmpty ? "" : " \(suffix)"
        info("benchmark.\(name)\(detailText)")
    }

    func info(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let message = message()
        logger.info("\(message, privacy: .public)")
        append(message)
    }

    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        milliseconds(from: start.duration(to: .now))
    }

    /// Flushes queued writes before Finder opens the file.
    func ensureFileExists() {
        let fileURL = fileURL
        queue.sync {
            Self.createLogFileIfNeeded(at: fileURL)
        }
    }

    private func append(_ message: String) {
        let fileURL = fileURL
        queue.async {
            let line = "\(self.timestampFormatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            do {
                if self.logSize + data.count > Self.maximumLogSize {
                    self.rotateLog()
                }
                Self.createLogFileIfNeeded(at: fileURL)
                let handle: FileHandle
                if let fileHandle = self.fileHandle {
                    handle = fileHandle
                } else {
                    let newHandle = try FileHandle(forWritingTo: fileURL)
                    try newHandle.seekToEnd()
                    self.fileHandle = newHandle
                    handle = newHandle
                }
                try handle.write(contentsOf: data)
                self.logSize += data.count
            } catch {
                self.logger.error("failed to write diagnostics log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rotateIfNeeded() {
        guard Self.fileSize(at: fileURL) >= Self.maximumLogSize else { return }
        rotateLog()
    }

    private func rotateLog() {
        try? fileHandle?.close()
        fileHandle = nil

        let previousURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Diagnostics.previous.log")
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousURL)
        logSize = 0
    }

    private static func createLogFileIfNeeded(at fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    private static func fileSize(at fileURL: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func milliseconds(from duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    static func format(_ milliseconds: Double) -> String {
        String(format: "%.2f", milliseconds)
    }
}
