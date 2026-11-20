import AppKit
import Darwin

func fail(_ message: String) -> Never {
    fputs("tvtplay: \(message)\n", stderr)
    exit(EXIT_FAILURE)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print("Usage: tvtplay [--] [FILE.m2ts]")
    print("Run without a file to open the macOS file picker.")
    exit(EXIT_SUCCESS)
}

let paths = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
if paths.count > 1 || (arguments.first != "--" && paths.first?.hasPrefix("-") == true) {
    fail("Usage: tvtplay [--] [FILE.m2ts]")
}

let fileManager = FileManager.default
let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
    .split(separator: ":")
    .map(String.init)
let ffplay = (pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin"])
    .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("ffplay").path }
    .first { fileManager.isExecutableFile(atPath: $0) }
guard let ffplay else {
    fail("ffplay was not found. Install it with brew install ffmpeg.")
}

let inputURL: URL
if let path = paths.first {
    inputURL = URL(fileURLWithPath: path)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.title = "Open a recording"
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let selectedURL = panel.url else {
        exit(EXIT_SUCCESS)
    }
    inputURL = selectedURL
}

guard (try? inputURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
      fileManager.isReadableFile(atPath: inputURL.path) else {
    fail("Cannot read file: \(inputURL.path)")
}

let player = Process()
player.executableURL = URL(fileURLWithPath: ffplay)
player.arguments = [
    "-hide_banner", "-nostats", "-autoexit",
    "-vf", "bwdif=mode=send_field:deint=interlaced",
    "-window_title", "TvtPlay — \(inputURL.lastPathComponent)",
    "-i", inputURL.path,
]
do {
    try player.run()
} catch {
    fail("Could not start ffplay: \(error.localizedDescription)")
}
player.waitUntilExit()
exit(player.terminationReason == .uncaughtSignal ? 128 + player.terminationStatus : player.terminationStatus)
