import Foundation

/// A passage to be read aloud, and the recording of someone reading it.
///
/// Passages live on disk as plain text rather than in the binary so that anyone
/// can add their own. That is the point: the accent and vocabulary that break a
/// recogniser are specific to a speaker, so the harness ships neutral passages
/// and lets each user drop in the words that actually fail for them.
struct Passage {
    let id: String
    let text: String
    let recordingURL: URL

    var hasRecording: Bool { FileManager.default.fileExists(atPath: recordingURL.path) }
}

enum EvalPaths {

    /// Overridable so the harness can be pointed at a directory outside the
    /// repository — useful when the passages are personal enough that the user
    /// would rather they never sat in a checkout at all.
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["MASTERFUL_EVAL_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Eval", isDirectory: true)
    }

    static var passages: URL { root.appendingPathComponent("passages", isDirectory: true) }
    static var recordings: URL { root.appendingPathComponent("recordings", isDirectory: true) }

    static func ensureDirectories() throws {
        for directory in [passages, recordings] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
    }

    /// Every passage on disk, in filename order so runs are comparable.
    static func load() throws -> [Passage] {
        try ensureDirectories()
        let files = try FileManager.default
            .contentsOfDirectory(at: passages, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try files.map { file in
            let id = file.deletingPathExtension().lastPathComponent
            return Passage(
                id: id,
                text: try String(contentsOf: file, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                recordingURL: recordings.appendingPathComponent("\(id).wav")
            )
        }
    }
}
