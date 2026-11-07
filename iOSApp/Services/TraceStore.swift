import Foundation
import WatchMagicKit

/// Files received from the watch: motion traces / diag logs (Sensor Probe)
/// in Documents/Traces/, and gesture-training CSVs (`train-<label>-….csv`)
/// in Documents/Training/, so they can be shared/exported from Settings.
@MainActor
final class TraceStore: ObservableObject {
    struct TraceFile: Identifiable, Hashable {
        let url: URL
        let size: Int64
        let date: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var traces: [TraceFile] = []
    @Published private(set) var training: [TraceFile] = []

    nonisolated static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Traces", isDirectory: true)
    }

    nonisolated static var trainingDirectory: URL {
        directory.deletingLastPathComponent().appendingPathComponent("Training", isDirectory: true)
    }

    init() { refresh() }

    func refresh() {
        traces = Self.list(Self.directory)
        training = Self.list(Self.trainingDirectory)
    }

    private static func list(_ dir: URL) -> [TraceFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return TraceFile(url: url, size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ files: [TraceFile]) {
        for f in files { try? FileManager.default.removeItem(at: f.url) }
        refresh()
    }

    /// Moves a received file into Traces/, keeping its name (a numeric suffix is
    /// added on collision). Must be called synchronously from
    /// `session(_:didReceive:)` — WatchConnectivity deletes the file afterwards.
    nonisolated static func importFile(at source: URL, preferredName: String?) throws -> URL {
        let fm = FileManager.default
        // Only the last path component is trusted (no directory traversal).
        var name = (preferredName.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
        if name.isEmpty || name == "." || name == ".." { name = source.lastPathComponent }
        if name.isEmpty { name = "trace-\(Int(Date().timeIntervalSince1970)).csv" }
        let directory = TrainingRecorder.isTrainingFile(name) ? trainingDirectory : directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var dest = directory.appendingPathComponent(name)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            dest = directory.appendingPathComponent(candidate)
            n += 1
        }
        try fm.moveItem(at: source, to: dest)
        return dest
    }
}
