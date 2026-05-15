import Foundation
import AppKit

@MainActor
final class SelfUpdater: ObservableObject {
    @Published var updateAvailable = false
    @Published var isChecking = false
    @Published var isUpdating = false

    // Called on launch — quick check against local cache
    func checkSilent() async {
        let result = await brew(["outdated", "--cask", "clawdbar"])
        updateAvailable = result.output.lines.contains { $0.trimmingCharacters(in: .whitespaces) == "clawdbar" }
    }

    // Called when the user explicitly taps "Check for Updates"
    func check() async {
        isChecking = true
        defer { isChecking = false }
        await brew(["update"], timeout: 60)
        let result = await brew(["outdated", "--cask", "clawdbar"])
        updateAvailable = result.output.lines.contains { $0.trimmingCharacters(in: .whitespaces) == "clawdbar" }
    }

    func update() async {
        isUpdating = true
        let result = await brew(["upgrade", "--cask", "clawdbar"], timeout: 120)
        if result.exitCode == 0 {
            NSApp.terminate(nil)
        } else {
            isUpdating = false
        }
    }
}

private let brewPath: String = {
    ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/brew"
}()

private struct BrewResult { let output: String; let exitCode: Int32 }

private func brew(_ args: [String], timeout: TimeInterval = 30) async -> BrewResult {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        process.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            continuation.resume(returning: BrewResult(
                output: String(data: data, encoding: .utf8) ?? "",
                exitCode: p.terminationStatus
            ))
        }
        try? process.run()
    }
}

private extension String {
    var lines: [String] { split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
}
