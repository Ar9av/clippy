import AppKit
import Foundation

struct CodingSession: Identifiable, Equatable {
    enum Provider: String {
        case codex = "Codex"
        case claude = "Claude"
    }

    let id: String
    let provider: Provider
    let projectPath: String
    let modifiedAt: Date

    var projectName: String {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return name.isEmpty ? "Home" : name
    }

    var relativeDate: String {
        RelativeDateTimeFormatter().localizedString(for: modifiedAt, relativeTo: Date())
    }
}

enum LocalActionService {
    static func recentSessions(limit: Int = 12) -> [CodingSession] {
        let candidates = sessionFiles()
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(80)

        var seen = Set<String>()
        return candidates.compactMap { url, date in
            parseSession(url: url, modifiedAt: date)
        }
        .filter { seen.insert("\($0.provider.rawValue):\($0.id)").inserted }
        .prefix(limit)
        .map { $0 }
    }

    static func resume(_ session: CodingSession) throws {
        let executable = try executableURL(
            named: session.provider == .codex ? "codex" : "claude"
        )
        let command: String
        switch session.provider {
        case .codex:
            command = "exec \(shellQuote(executable.path)) resume -C \(shellQuote(session.projectPath)) \(shellQuote(session.id))"
        case .claude:
            command = "cd \(shellQuote(session.projectPath))\nexec \(shellQuote(executable.path)) --resume \(shellQuote(session.id))"
        }
        try launchTerminalCommand(
            command,
            name: "Resume-\(session.provider.rawValue)-\(session.id.prefix(8))"
        )
    }

    static func openApp(_ name: String) {
        let bundleIdentifiers: [String: String] = [
            "Finder": "com.apple.finder",
            "Terminal": "com.apple.Terminal",
            "Safari": "com.apple.Safari",
            "VS Code": "com.microsoft.VSCode",
            "Xcode": "com.apple.dt.Xcode"
        ]
        guard let identifier = bundleIdentifiers[name],
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return
        }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    static func openFolder(_ folder: FileManager.SearchPathDirectory) {
        guard let url = FileManager.default.urls(for: folder, in: .userDomainMask).first else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func sessionFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true)
        ].flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "jsonl" }
        }
    }

    private static func parseSession(url: URL, modifiedAt: Date) -> CodingSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 96_000)) ?? Data()
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        if url.path.contains("/.codex/") {
            for line in content.components(separatedBy: .newlines).prefix(8) {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "session_meta",
                      let payload = json["payload"] as? [String: Any],
                      let id = (payload["id"] ?? payload["session_id"]) as? String else {
                    continue
                }
                let cwd = payload["cwd"] as? String
                    ?? FileManager.default.homeDirectoryForCurrentUser.path
                return CodingSession(
                    id: id,
                    provider: .codex,
                    projectPath: cwd,
                    modifiedAt: modifiedAt
                )
            }
        }

        if url.path.contains("/.claude/") {
            var sessionID = url.deletingPathExtension().lastPathComponent
            var cwd = decodedClaudeProjectPath(from: url.deletingLastPathComponent().lastPathComponent)
            for line in content.components(separatedBy: .newlines).prefix(40) {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                sessionID = json["sessionId"] as? String ?? sessionID
                cwd = json["cwd"] as? String ?? cwd
            }
            return CodingSession(
                id: sessionID,
                provider: .claude,
                projectPath: cwd,
                modifiedAt: modifiedAt
            )
        }
        return nil
    }

    private static func decodedClaudeProjectPath(from directory: String) -> String {
        let candidate = "/" + directory.drop(while: { $0 == "-" })
            .replacingOccurrences(of: "-", with: "/")
        return FileManager.default.fileExists(atPath: candidate)
            ? candidate
            : FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func executableURL(named name: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]
        for directory in paths {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        throw ClippyError.missingCLI(name.capitalized)
    }

    private static func launchTerminalCommand(_ command: String, name: String) throws {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy/Launchers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("command")
        let script = "#!/bin/zsh\n\(command)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        NSWorkspace.shared.open(url)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
