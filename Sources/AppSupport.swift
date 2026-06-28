import Foundation

struct InstallerLaunchConfiguration {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

func installerLaunchConfiguration(installer: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> InstallerLaunchConfiguration {
    var env = environment
    let existingPath = env["PATH"] ?? ""
    let prefix = "/opt/homebrew/bin:/usr/local/bin"
    env["PATH"] = existingPath.isEmpty ? prefix : "\(prefix):\(existingPath)"
    return InstallerLaunchConfiguration(executablePath: "/usr/bin/env", arguments: ["node", installer], environment: env)
}

func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func appendPrivateLogLine(_ line: String, toPath path: String) {
    guard let data = line.data(using: .utf8) else { return }
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    if fm.fileExists(atPath: path) {
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } else {
        _ = fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
