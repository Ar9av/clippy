import Foundation

/// Every screenshot Clippy captures (`ScreenAwarenessService`), every pasted
/// image (`ChatViewModel`), and every resume launcher script
/// (`LocalActionService`) lands in `~/Library/Caches/Clippy/...` and was
/// never pruned — one full-resolution screenshot per screen-aware message,
/// forever. Run once per launch, off the main actor, to bound that growth.
enum CacheJanitor {
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let maxTotalBytes: Int = 200 * 1_024 * 1_024

    private static var directories: [String] {
        ["ScreenContext", "PastedAttachments", "Launchers"]
    }

    /// Deletes anything older than `maxAge` in each Clippy cache
    /// subdirectory, then — if the combined remainder still exceeds
    /// `maxTotalBytes` — deletes oldest-first until it's back under the cap.
    static func clean() {
        guard let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let clippyRoot = cachesRoot.appendingPathComponent("Clippy", isDirectory: true)
        let fileManager = FileManager.default
        let now = Date()

        var survivors: [(url: URL, size: Int, modified: Date)] = []

        for name in directories {
            let directory = clippyRoot.appendingPathComponent(name, isDirectory: true)
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }

            for url in contents {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modified = values?.contentModificationDate ?? .distantPast
                let size = values?.fileSize ?? 0
                if now.timeIntervalSince(modified) > maxAge {
                    try? fileManager.removeItem(at: url)
                } else {
                    survivors.append((url, size, modified))
                }
            }
        }

        var totalBytes = survivors.reduce(0) { $0 + $1.size }
        guard totalBytes > maxTotalBytes else { return }
        for entry in survivors.sorted(by: { $0.modified < $1.modified }) {
            guard totalBytes > maxTotalBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }
}
